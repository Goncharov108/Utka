#include "UtkaRing.h"

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <os/lock.h>
#include <stdlib.h>
#include <math.h>
#include <stddef.h>
#include <string.h>
#include <stdio.h>

/// Виртуальный выход: принимает смесь и кладёт её в кольцо. В монитор пишет уже само приложение.

static const AudioObjectID kDeviceID = 2;
static const AudioObjectID kStreamID = 3;
static const AudioObjectID kInputStreamID = 6;
static const AudioObjectID kVolumeID = 4;
static const AudioObjectID kMuteID = 5;
static const UInt32 kClockPeriod = 16384;

static AudioServerPlugInHostRef gHost = NULL;
static UtkaRing *gRing = NULL;
static _Atomic uint32_t gVolumeBits = 0;
static _Atomic uint32_t gMuted = 0;
static _Atomic int32_t gIOCount = 0;
static Float64 gTicksPerFrame = 0;
static UInt64 gAnchorHost = 0;
static UInt64 gClockSeed = 1;

/// Сумма всех клиентов одного такта. Следующий такт публикует её, и каждый слушатель получает одно и то же.
static float gBuild[UTKA_RING_FRAMES * 2];
static float gLive[UTKA_RING_FRAMES * 2];
static UInt32 gBuildFrames = 0;
static UInt32 gLiveFrames = 0;
static Float64 gBuildTime = 0;
static UInt64 gBuildCycle = 0;
static int gBuildOpen = 0;
static os_unfair_lock gMixLock = OS_UNFAIR_LOCK_INIT;

static AudioServerPlugInDriverInterface gInterface;
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;

static Float32 bitsToFloat(uint32_t bits) {
    Float32 value = 0;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static uint32_t floatToBits(Float32 value) {
    uint32_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static Float32 currentVolume(void) {
    if (atomic_load_explicit(&gMuted, memory_order_relaxed)) return 0;
    Float32 value = bitsToFloat(atomic_load_explicit(&gVolumeBits, memory_order_relaxed));
    if (value < 0) return 0;
    if (value > 1) return 1;
    return value;
}

static void storeVolume(Float32 value) {
    if (value < 0) value = 0;
    if (value > 1) value = 1;
    uint32_t bits = floatToBits(value);
    atomic_store_explicit(&gVolumeBits, bits, memory_order_relaxed);
    if (gRing) atomic_store_explicit(&gRing->volumeBits, bits, memory_order_relaxed);
}

/// Кольцо внутри плагина. Наружу звук отдаёт вход того же устройства, не общая память.
static void createRing(void) {
    if (gRing) return;
    gRing = calloc(1, sizeof(UtkaRing));
    if (gRing == NULL) {
        os_log_error(OS_LOG_DEFAULT, "utka ring alloc failed");
        return;
    }
    gRing->magic = UTKA_RING_MAGIC;
    gRing->version = UTKA_RING_VERSION;
    gRing->sampleRate = UTKA_RING_RATE;
    gRing->channels = UTKA_RING_CHANNELS;
    gRing->frameCapacity = UTKA_RING_FRAMES;
    storeVolume(0.25f);
}

static void prepareClock(void) {
    if (gTicksPerFrame != 0) return;
    struct mach_timebase_info info;
    mach_timebase_info(&info);
    double ticksPerSecond = 1e9 * (double)info.denom / (double)info.numer;
    gTicksPerFrame = ticksPerSecond / (double)UTKA_RING_RATE;
}

static AudioStreamBasicDescription streamFormat(void) {
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    format.mSampleRate = UTKA_RING_RATE;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format.mBitsPerChannel = 32;
    format.mChannelsPerFrame = UTKA_RING_CHANNELS;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = 8;
    format.mBytesPerPacket = 8;
    return format;
}

static bool isVolume(const AudioObjectPropertyAddress *address) {
    if (address->mSelector != kAudioDevicePropertyVolumeScalar) return false;
    if (address->mScope != kAudioObjectPropertyScopeOutput && address->mScope != kAudioObjectPropertyScopeGlobal) return false;
    return address->mElement == kAudioObjectPropertyElementMain;
}

static bool isMute(const AudioObjectPropertyAddress *address) {
    if (address->mSelector != kAudioDevicePropertyMute) return false;
    if (address->mScope != kAudioObjectPropertyScopeOutput && address->mScope != kAudioObjectPropertyScopeGlobal) return false;
    return address->mElement == kAudioObjectPropertyElementMain;
}

/// Скаляр 0…1 в децибелы. Ноль — это тишина, не минус бесконечность.
static Float32 scalarToDb(Float32 scalar) {
    if (scalar <= 0.0000158489f) return -96.0f;
    return 20.0f * log10f(scalar);
}

/// Децибелы обратно в скаляр ползунка.
static Float32 dbToScalar(Float32 db) {
    if (db <= -96.0f) return 0;
    if (db >= 0) return 1;
    return powf(10.0f, db / 20.0f);
}

/// Класс объекта подходит под запрошенный: он сам или его предок.
static bool classMatches(AudioClassID objectClass, AudioClassID wanted) {
    if (wanted == kAudioObjectClassIDWildcard || wanted == kAudioObjectClassID || wanted == objectClass) return true;
    if (objectClass == kAudioVolumeControlClassID) {
        return wanted == kAudioLevelControlClassID || wanted == kAudioControlClassID;
    }
    if (objectClass == kAudioMuteControlClassID) {
        return wanted == kAudioBooleanControlClassID || wanted == kAudioControlClassID;
    }
    return false;
}

/// Квалификатор списка — массив классов. Пустой список значит «все объекты».
static bool qualifierAccepts(UInt32 size, const void *data, AudioClassID objectClass) {
    if (data == NULL || size < sizeof(AudioClassID)) return true;
    const AudioClassID *ids = data;
    UInt32 count = size / (UInt32)sizeof(AudioClassID);
    for (UInt32 i = 0; i < count; i++) {
        if (classMatches(objectClass, ids[i])) return true;
    }
    return false;
}

/// Поток и регуляторы, которые принадлежат устройству или самому плагину.
static bool isStream(AudioObjectID objectID) {
    return objectID == kStreamID || objectID == kInputStreamID;
}

static UInt32 collectOwned(AudioObjectID objectID, UInt32 qualSize, const void *qual, AudioObjectID *out, UInt32 cap) {
    AudioObjectID ids[4];
    AudioClassID classes[4];
    UInt32 total = 0;
    if (objectID == kAudioObjectPlugInObject) {
        ids[0] = kDeviceID;
        classes[0] = kAudioDeviceClassID;
        total = 1;
    } else if (objectID == kDeviceID) {
        ids[0] = kStreamID;
        classes[0] = kAudioStreamClassID;
        ids[1] = kInputStreamID;
        classes[1] = kAudioStreamClassID;
        ids[2] = kVolumeID;
        classes[2] = kAudioVolumeControlClassID;
        ids[3] = kMuteID;
        classes[3] = kAudioMuteControlClassID;
        total = 4;
    }
    UInt32 count = 0;
    for (UInt32 i = 0; i < total; i++) {
        if (!qualifierAccepts(qualSize, qual, classes[i])) continue;
        if (out != NULL && count < cap) out[count] = ids[i];
        count++;
    }
    return count;
}

static OSStatus writeBytes(UInt32 inSize, UInt32 *outSize, void *outData, const void *src, UInt32 srcSize) {
    if (outSize) *outSize = srcSize;
    if (srcSize == 0) return noErr;
    if (inSize < srcSize || outData == NULL) return kAudioHardwareBadPropertySizeError;
    memcpy(outData, src, srcSize);
    return noErr;
}

static OSStatus writeString(UInt32 inSize, UInt32 *outSize, void *outData, const char *text) {
    UInt32 need = (UInt32)sizeof(CFStringRef);
    if (outSize) *outSize = need;
    if (inSize < need || outData == NULL) return kAudioHardwareBadPropertySizeError;
    CFStringRef string = CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
    if (string == NULL) return kAudioHardwareUnspecifiedError;
    *(CFStringRef *)outData = string;
    return noErr;
}

static UInt32 stringSize(void) {
    return (UInt32)sizeof(CFStringRef);
}

static void notifyLevel(AudioObjectID objectID, AudioObjectPropertySelector selector) {
    if (gHost == NULL || gHost->PropertiesChanged == NULL) return;
    AudioObjectPropertyAddress address = { selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    gHost->PropertiesChanged(gHost, objectID, 1, &address);
}

static void notifyDevice(AudioObjectPropertySelector selector, AudioObjectPropertyScope scope) {
    if (gHost == NULL || gHost->PropertiesChanged == NULL) return;
    AudioObjectPropertyAddress address = { selector, scope, kAudioObjectPropertyElementMain };
    gHost->PropertiesChanged(gHost, kDeviceID, 1, &address);
}

/// Публикует сумму такта. Громкость уже учтена, здесь только ограничение, чтобы сумма клиентов не клипповала в бесконечность.
static void publishBuild(void) {
    UInt32 frames = gBuildFrames;
    if (frames > UTKA_RING_FRAMES) frames = UTKA_RING_FRAMES;
    for (UInt32 i = 0; i < frames * 2; i++) {
        float sample = gBuild[i];
        if (sample > 1) sample = 1;
        if (sample < -1) sample = -1;
        gLive[i] = sample;
    }
    gLiveFrames = frames;
}

/// Складывает вклад клиента в текущий такт. Новый момент времени публикует предыдущую сумму.
static void writeMix(float *samples, UInt32 frames, const AudioServerPlugInIOCycleInfo *info) {
    if (samples == NULL || frames == 0) return;
    if (frames > UTKA_RING_FRAMES) frames = UTKA_RING_FRAMES;
    Float32 volume = currentVolume();
    int timeValid = info != NULL && (info->mOutputTime.mFlags & kAudioTimeStampSampleTimeValid) != 0;
    Float64 time = timeValid ? info->mOutputTime.mSampleTime : 0;
    UInt64 cycle = info != NULL ? info->mIOCycleCounter : 0;
    os_unfair_lock_lock(&gMixLock);
    int newPeriod = !gBuildOpen;
    if (gBuildOpen) {
        if (timeValid) newPeriod = fabs(time - gBuildTime) > 0.5;
        else newPeriod = cycle != gBuildCycle;
    }
    if (newPeriod) {
        if (gBuildOpen) publishBuild();
        memset(gBuild, 0, (size_t)frames * 2 * sizeof(float));
        gBuildFrames = frames;
        gBuildTime = time;
        gBuildCycle = cycle;
        gBuildOpen = 1;
    } else if (frames > gBuildFrames) {
        memset(gBuild + gBuildFrames * 2, 0, (size_t)(frames - gBuildFrames) * 2 * sizeof(float));
        gBuildFrames = frames;
    }
    for (UInt32 i = 0; i < frames; i++) {
        gBuild[i * 2] += samples[i * 2] * volume;
        gBuild[i * 2 + 1] += samples[i * 2 + 1] * volume;
    }
    os_unfair_lock_unlock(&gMixLock);
}

/// Отдаёт уже собранный такт. Все слушатели читают одну сумму, а не последнего, кто успел записать.
static void readInput(float *samples, UInt32 frames) {
    if (samples == NULL || frames == 0) return;
    memset(samples, 0, (size_t)frames * 2 * sizeof(float));
    if (frames > UTKA_RING_FRAMES) frames = UTKA_RING_FRAMES;
    os_unfair_lock_lock(&gMixLock);
    UInt32 count = frames < gLiveFrames ? frames : gLiveFrames;
    if (count > 0) memcpy(samples, gLive, (size_t)count * 2 * sizeof(float));
    os_unfair_lock_unlock(&gMixLock);
}

static Boolean sameUUID(CFUUIDBytes iid, CFUUIDRef uuid) {
    CFUUIDBytes bytes = CFUUIDGetUUIDBytes(uuid);
    return memcmp(&iid, &bytes, sizeof(bytes)) == 0;
}

static HRESULT Utka_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (outInterface == NULL) return E_POINTER;
    if (sameUUID(inUUID, IUnknownUUID) || sameUUID(inUUID, kAudioServerPlugInDriverInterfaceUUID)) {
        *outInterface = inDriver;
        return S_OK;
    }
    *outInterface = NULL;
    return E_NOINTERFACE;
}

static ULONG Utka_AddRef(void *inDriver) {
    (void)inDriver;
    return 1;
}

static ULONG Utka_Release(void *inDriver) {
    (void)inDriver;
    return 1;
}

static OSStatus Utka_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    (void)inDriver;
    gHost = inHost;
    createRing();
    prepareClock();
    os_log(OS_LOG_DEFAULT, "utka audio plugin ready");
    return noErr;
}

static OSStatus Utka_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID) {
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Utka_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Utka_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return noErr;
}

static OSStatus Utka_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return noErr;
}

static OSStatus Utka_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return noErr;
}

static OSStatus Utka_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return noErr;
}

static Boolean Utka_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress) {
    (void)inDriver; (void)inClientProcessID;
    if (inAddress == NULL) return false;
    AudioObjectPropertySelector selector = inAddress->mSelector;
    if (inObjectID == kAudioObjectPlugInObject) {
        switch (selector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyManufacturer:
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyBundleID:
            case kAudioPlugInPropertyDeviceList:
            case kAudioPlugInPropertyTranslateUIDToDevice:
            case kAudioPlugInPropertyBoxList:
            case kAudioPlugInPropertyClockDeviceList:
                return true;
            default:
                return false;
        }
    }
    if (inObjectID == kDeviceID) {
        if (isVolume(inAddress) || isMute(inAddress)) return true;
        if (selector == kAudioStreamPropertyVirtualFormat || selector == kAudioStreamPropertyPhysicalFormat) return true;
        switch (selector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyManufacturer:
            case kAudioObjectPropertyModelName:
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceIsRunning:
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertyStreams:
            case kAudioObjectPropertyControlList:
            case kAudioDevicePropertyRelatedDevices:
            case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertySafetyOffset:
            case kAudioDevicePropertyNominalSampleRate:
            case kAudioDevicePropertyAvailableNominalSampleRates:
            case kAudioDevicePropertyIsHidden:
            case kAudioDevicePropertyPreferredChannelsForStereo:
            case kAudioDevicePropertyZeroTimeStampPeriod:
            case kAudioDevicePropertyClockAlgorithm:
            case kAudioDevicePropertyClockIsStable:
            case kAudioDevicePropertyStreamConfiguration:
                return true;
            default:
                return false;
        }
    }
    if (isStream(inObjectID)) {
        switch (selector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyName:
            case kAudioStreamPropertyIsActive:
            case kAudioStreamPropertyDirection:
            case kAudioStreamPropertyTerminalType:
            case kAudioStreamPropertyStartingChannel:
            case kAudioStreamPropertyLatency:
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats:
                return true;
            default:
                return false;
        }
    }
    if (inObjectID == kVolumeID || inObjectID == kMuteID) {
        switch (selector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyName:
            case kAudioControlPropertyScope:
            case kAudioControlPropertyElement:
                return true;
            case kAudioLevelControlPropertyScalarValue:
            case kAudioLevelControlPropertyDecibelValue:
            case kAudioLevelControlPropertyDecibelRange:
            case kAudioLevelControlPropertyConvertScalarToDecibels:
            case kAudioLevelControlPropertyConvertDecibelsToScalar:
                return inObjectID == kVolumeID;
            case kAudioBooleanControlPropertyValue:
                return inObjectID == kMuteID;
            default:
                return false;
        }
    }
    return false;
}

static OSStatus Utka_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable) {
    (void)inClientProcessID;
    if (outIsSettable == NULL || inAddress == NULL) return kAudioHardwareIllegalOperationError;
    if (!Utka_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) return kAudioHardwareUnknownPropertyError;
    Boolean settable = 0;
    if (inObjectID == kDeviceID && (isVolume(inAddress) || isMute(inAddress))) settable = 1;
    if (inObjectID == kVolumeID && (inAddress->mSelector == kAudioLevelControlPropertyScalarValue || inAddress->mSelector == kAudioLevelControlPropertyDecibelValue)) settable = 1;
    if (inObjectID == kMuteID && inAddress->mSelector == kAudioBooleanControlPropertyValue) settable = 1;
    *outIsSettable = settable;
    return noErr;
}

static UInt32 propertySize(AudioObjectID objectID, const AudioObjectPropertyAddress *address, UInt32 qualSize, const void *qual) {
    AudioObjectPropertySelector selector = address->mSelector;
    if (selector == kAudioObjectPropertyName || selector == kAudioObjectPropertyManufacturer || selector == kAudioObjectPropertyModelName || selector == kAudioDevicePropertyDeviceUID || selector == kAudioPlugInPropertyBundleID) {
        return stringSize();
    }
    if (selector == kAudioPlugInPropertyTranslateUIDToDevice) return sizeof(AudioObjectID);
    if (selector == kAudioPlugInPropertyDeviceList) {
        return objectID == kAudioObjectPlugInObject ? (UInt32)sizeof(AudioObjectID) : 0;
    }
    if (selector == kAudioObjectPropertyOwnedObjects) {
        return collectOwned(objectID, qualSize, qual, NULL, 0) * (UInt32)sizeof(AudioObjectID);
    }
    if (selector == kAudioPlugInPropertyBoxList || selector == kAudioPlugInPropertyClockDeviceList || selector == kAudioDevicePropertyRelatedDevices) return 0;
    if (selector == kAudioObjectPropertyControlList) {
        if (address->mScope == kAudioObjectPropertyScopeInput) return 0;
        return 2 * (UInt32)sizeof(AudioObjectID);
    }
    if (selector == kAudioDevicePropertyStreams) {
        UInt32 count = address->mScope == kAudioObjectPropertyScopeGlobal ? 2 : 1;
        return count * (UInt32)sizeof(AudioObjectID);
    }
    if (selector == kAudioDevicePropertyAvailableNominalSampleRates || selector == kAudioLevelControlPropertyDecibelRange) return (UInt32)sizeof(AudioValueRange);
    if (selector == kAudioDevicePropertyPreferredChannelsForStereo) return (UInt32)(sizeof(UInt32) * 2);
    if (selector == kAudioStreamPropertyAvailableVirtualFormats || selector == kAudioStreamPropertyAvailablePhysicalFormats) {
        return (UInt32)sizeof(AudioStreamRangedDescription);
    }
    if (selector == kAudioStreamPropertyVirtualFormat || selector == kAudioStreamPropertyPhysicalFormat) {
        return (UInt32)sizeof(AudioStreamBasicDescription);
    }
    if (selector == kAudioDevicePropertyStreamConfiguration) return (UInt32)sizeof(AudioBufferList);
    if (selector == kAudioDevicePropertyNominalSampleRate) return (UInt32)sizeof(Float64);
    if (selector == kAudioLevelControlPropertyScalarValue || selector == kAudioLevelControlPropertyDecibelValue || selector == kAudioLevelControlPropertyConvertScalarToDecibels || selector == kAudioLevelControlPropertyConvertDecibelsToScalar) {
        return (UInt32)sizeof(Float32);
    }
    return (UInt32)sizeof(UInt32);
}

static OSStatus Utka_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize) {
    (void)inQualifierDataSize; (void)inQualifierData;
    if (outDataSize == NULL || inAddress == NULL) return kAudioHardwareIllegalOperationError;
    if (!Utka_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) return kAudioHardwareUnknownPropertyError;
    *outDataSize = propertySize(inObjectID, inAddress, inQualifierDataSize, inQualifierData);
    return noErr;
}

static OSStatus Utka_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    (void)inClientProcessID;
    if (inAddress == NULL) return kAudioHardwareIllegalOperationError;
    if (!Utka_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) return kAudioHardwareUnknownPropertyError;
    AudioObjectPropertySelector selector = inAddress->mSelector;

    if (inObjectID == kAudioObjectPlugInObject && selector == kAudioPlugInPropertyTranslateUIDToDevice) {
        AudioObjectID found = kAudioObjectUnknown;
        if (inQualifierData != NULL && inQualifierDataSize >= sizeof(CFStringRef)) {
            CFStringRef uid = *(CFStringRef *)inQualifierData;
            if (uid != NULL && CFGetTypeID(uid) == CFStringGetTypeID()) {
                CFStringRef ours = CFStringCreateWithCString(NULL, UTKA_DEVICE_UID, kCFStringEncodingUTF8);
                if (ours != NULL) {
                    if (CFEqual(uid, ours)) found = kDeviceID;
                    CFRelease(ours);
                }
            }
        }
        return writeBytes(inDataSize, outDataSize, outData, &found, sizeof(found));
    }

    if (selector == kAudioObjectPropertyName) {
        const char *name = "Утка звук";
        if (inObjectID == kStreamID) name = "Выход";
        else if (inObjectID == kInputStreamID) name = "Петля";
        else if (inObjectID == kVolumeID) name = "Громкость";
        else if (inObjectID == kMuteID) name = "Без звука";
        return writeString(inDataSize, outDataSize, outData, name);
    }
    if (selector == kAudioObjectPropertyManufacturer) return writeString(inDataSize, outDataSize, outData, "Утка");
    if (selector == kAudioObjectPropertyModelName) return writeString(inDataSize, outDataSize, outData, "Звук");
    if (selector == kAudioDevicePropertyDeviceUID || selector == kAudioPlugInPropertyBundleID) {
        const char *text = selector == kAudioPlugInPropertyBundleID ? "dev.goncharov.utka.audio" : UTKA_DEVICE_UID;
        return writeString(inDataSize, outDataSize, outData, text);
    }

    if (selector == kAudioObjectPropertyBaseClass) {
        AudioClassID value = kAudioObjectClassID;
        if (inObjectID == kVolumeID) value = kAudioLevelControlClassID;
        if (inObjectID == kMuteID) value = kAudioBooleanControlClassID;
        return writeBytes(inDataSize, outDataSize, outData, &value, sizeof(value));
    }
    if (selector == kAudioObjectPropertyClass) {
        AudioClassID value = kAudioStreamClassID;
        if (inObjectID == kAudioObjectPlugInObject) value = kAudioPlugInClassID;
        else if (inObjectID == kDeviceID) value = kAudioDeviceClassID;
        else if (inObjectID == kVolumeID) value = kAudioVolumeControlClassID;
        else if (inObjectID == kMuteID) value = kAudioMuteControlClassID;
        return writeBytes(inDataSize, outDataSize, outData, &value, sizeof(value));
    }
    if (selector == kAudioObjectPropertyOwner) {
        AudioObjectID value = kAudioObjectUnknown;
        if (inObjectID == kDeviceID) value = kAudioObjectPlugInObject;
        if (isStream(inObjectID) || inObjectID == kVolumeID || inObjectID == kMuteID) value = kDeviceID;
        return writeBytes(inDataSize, outDataSize, outData, &value, sizeof(value));
    }
    if (selector == kAudioPlugInPropertyDeviceList) {
        if (inObjectID != kAudioObjectPlugInObject) {
            if (outDataSize) *outDataSize = 0;
            return noErr;
        }
        AudioObjectID value = kDeviceID;
        return writeBytes(inDataSize, outDataSize, outData, &value, sizeof(value));
    }
    if (selector == kAudioObjectPropertyOwnedObjects) {
        AudioObjectID values[4];
        UInt32 count = collectOwned(inObjectID, inQualifierDataSize, inQualifierData, values, 4);
        return writeBytes(inDataSize, outDataSize, outData, values, count * (UInt32)sizeof(AudioObjectID));
    }
    if (selector == kAudioPlugInPropertyBoxList || selector == kAudioPlugInPropertyClockDeviceList) {
        if (outDataSize) *outDataSize = 0;
        return noErr;
    }
    if (selector == kAudioDevicePropertyRelatedDevices) {
        if (outDataSize) *outDataSize = 0;
        return noErr;
    }
    if (selector == kAudioDevicePropertyClockDomain) {
        UInt32 value = 0;
        return writeBytes(inDataSize, outDataSize, outData, &value, sizeof(value));
    }
    if (selector == kAudioObjectPropertyControlList) {
        if (inAddress->mScope == kAudioObjectPropertyScopeInput) {
            if (outDataSize) *outDataSize = 0;
            return noErr;
        }
        AudioObjectID values[2] = { kVolumeID, kMuteID };
        return writeBytes(inDataSize, outDataSize, outData, values, sizeof(values));
    }
    if (selector == kAudioControlPropertyScope) {
        AudioObjectPropertyScope value = kAudioObjectPropertyScopeOutput;
        return writeBytes(inDataSize, outDataSize, outData, &value, sizeof(value));
    }
    if (selector == kAudioControlPropertyElement) {
        AudioObjectPropertyElement value = kAudioObjectPropertyElementMain;
        return writeBytes(inDataSize, outDataSize, outData, &value, sizeof(value));
    }
    if (selector == kAudioLevelControlPropertyScalarValue) {
        Float32 value = bitsToFloat(atomic_load_explicit(&gVolumeBits, memory_order_relaxed));
        return writeBytes(inDataSize, outDataSize, outData, &value, sizeof(value));
    }
    if (selector == kAudioLevelControlPropertyDecibelValue) {
        Float32 value = scalarToDb(bitsToFloat(atomic_load_explicit(&gVolumeBits, memory_order_relaxed)));
        return writeBytes(inDataSize, outDataSize, outData, &value, sizeof(value));
    }
    if (selector == kAudioLevelControlPropertyDecibelRange) {
        AudioValueRange value = { -96.0, 0.0 };
        return writeBytes(inDataSize, outDataSize, outData, &value, sizeof(value));
    }
    if (selector == kAudioLevelControlPropertyConvertScalarToDecibels || selector == kAudioLevelControlPropertyConvertDecibelsToScalar) {
        if (inDataSize < sizeof(Float32) || outData == NULL) return kAudioHardwareBadPropertySizeError;
        Float32 input = *(Float32 *)outData;
        Float32 value = selector == kAudioLevelControlPropertyConvertScalarToDecibels ? scalarToDb(input) : dbToScalar(input);
        return writeBytes(inDataSize, outDataSize, outData, &value, sizeof(value));
    }
    if (selector == kAudioBooleanControlPropertyValue) {
        UInt32 value = atomic_load_explicit(&gMuted, memory_order_relaxed) ? 1 : 0;
        return writeBytes(inDataSize, outDataSize, outData, &value, sizeof(value));
    }
    if (selector == kAudioDevicePropertyTransportType) {
        UInt32 value = kAudioDeviceTransportTypeVirtual;
        return writeBytes(inDataSize, outDataSize, outData, &value, sizeof(value));
    }
    if (selector == kAudioDevicePropertyDeviceIsAlive || selector == kAudioDevicePropertyIsHidden || selector == kAudioDevicePropertyClockIsStable) {
        UInt32 value = selector == kAudioDevicePropertyIsHidden ? 0 : 1;
        return writeBytes(inDataSize, outDataSize, outData, &value, sizeof(value));
    }
    if (selector == kAudioDevicePropertyDeviceIsRunning || selector == kAudioStreamPropertyIsActive) {
        UInt32 value = atomic_load_explicit(&gIOCount, memory_order_relaxed) > 0 ? 1 : 0;
        return writeBytes(inDataSize, outDataSize, outData, &value, sizeof(value));
    }
    if (selector == kAudioDevicePropertyDeviceCanBeDefaultDevice || selector == kAudioDevicePropertyDeviceCanBeDefaultSystemDevice) {
        UInt32 value = inAddress->mScope == kAudioObjectPropertyScopeInput ? 0 : 1;
        return writeBytes(inDataSize, outDataSize, outData, &value, sizeof(value));
    }
    if (selector == kAudioDevicePropertyLatency || selector == kAudioDevicePropertySafetyOffset || selector == kAudioStreamPropertyLatency) {
        UInt32 value = 0;
        return writeBytes(inDataSize, outDataSize, outData, &value, sizeof(value));
    }
    if (selector == kAudioDevicePropertyStreams) {
        AudioObjectID values[2];
        UInt32 count = 0;
        if (inAddress->mScope != kAudioObjectPropertyScopeInput) values[count++] = kStreamID;
        if (inAddress->mScope != kAudioObjectPropertyScopeOutput) values[count++] = kInputStreamID;
        return writeBytes(inDataSize, outDataSize, outData, values, count * (UInt32)sizeof(AudioObjectID));
    }
    if (selector == kAudioDevicePropertyNominalSampleRate) {
        Float64 value = UTKA_RING_RATE;
        return writeBytes(inDataSize, outDataSize, outData, &value, sizeof(value));
    }
    if (selector == kAudioDevicePropertyAvailableNominalSampleRates) {
        AudioValueRange value = { UTKA_RING_RATE, UTKA_RING_RATE };
        return writeBytes(inDataSize, outDataSize, outData, &value, sizeof(value));
    }
    if (selector == kAudioDevicePropertyPreferredChannelsForStereo) {
        UInt32 value[2] = { 1, 2 };
        return writeBytes(inDataSize, outDataSize, outData, value, sizeof(value));
    }
    if (selector == kAudioDevicePropertyZeroTimeStampPeriod) {
        UInt32 value = kClockPeriod;
        return writeBytes(inDataSize, outDataSize, outData, &value, sizeof(value));
    }
    if (selector == kAudioDevicePropertyClockAlgorithm) {
        UInt32 value = kAudioDeviceClockAlgorithmRaw;
        return writeBytes(inDataSize, outDataSize, outData, &value, sizeof(value));
    }
    if (selector == kAudioStreamPropertyDirection) {
        UInt32 value = inObjectID == kInputStreamID ? 1 : 0;
        return writeBytes(inDataSize, outDataSize, outData, &value, sizeof(value));
    }
    if (selector == kAudioStreamPropertyTerminalType) {
        UInt32 value = inObjectID == kInputStreamID ? kAudioStreamTerminalTypeLine : kAudioStreamTerminalTypeSpeaker;
        return writeBytes(inDataSize, outDataSize, outData, &value, sizeof(value));
    }
    if (selector == kAudioStreamPropertyStartingChannel) {
        UInt32 value = 1;
        return writeBytes(inDataSize, outDataSize, outData, &value, sizeof(value));
    }
    if (selector == kAudioStreamPropertyVirtualFormat || selector == kAudioStreamPropertyPhysicalFormat) {
        AudioStreamBasicDescription value = streamFormat();
        return writeBytes(inDataSize, outDataSize, outData, &value, sizeof(value));
    }
    if (selector == kAudioStreamPropertyAvailableVirtualFormats || selector == kAudioStreamPropertyAvailablePhysicalFormats) {
        AudioStreamRangedDescription value;
        memset(&value, 0, sizeof(value));
        value.mFormat = streamFormat();
        value.mSampleRateRange.mMinimum = UTKA_RING_RATE;
        value.mSampleRateRange.mMaximum = UTKA_RING_RATE;
        return writeBytes(inDataSize, outDataSize, outData, &value, sizeof(value));
    }
    if (selector == kAudioDevicePropertyStreamConfiguration) {
        AudioBufferList value;
        memset(&value, 0, sizeof(value));
        value.mNumberBuffers = 1;
        value.mBuffers[0].mNumberChannels = UTKA_RING_CHANNELS;
        return writeBytes(inDataSize, outDataSize, outData, &value, sizeof(value));
    }
    if (isVolume(inAddress)) {
        Float32 value = bitsToFloat(atomic_load_explicit(&gVolumeBits, memory_order_relaxed));
        return writeBytes(inDataSize, outDataSize, outData, &value, sizeof(value));
    }
    if (isMute(inAddress)) {
        UInt32 value = atomic_load_explicit(&gMuted, memory_order_relaxed) ? 1 : 0;
        return writeBytes(inDataSize, outDataSize, outData, &value, sizeof(value));
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus Utka_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData) {
    (void)inDriver; (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inAddress == NULL || inData == NULL) return kAudioHardwareIllegalOperationError;
    if (inObjectID == kVolumeID || (inObjectID == kDeviceID && isVolume(inAddress))) {
        if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
        Float32 scalar = *(const Float32 *)inData;
        if (inAddress->mSelector == kAudioLevelControlPropertyDecibelValue) scalar = dbToScalar(scalar);
        storeVolume(scalar);
        notifyDevice(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput);
        notifyLevel(kVolumeID, kAudioLevelControlPropertyScalarValue);
        return noErr;
    }
    if (inObjectID == kMuteID || (inObjectID == kDeviceID && isMute(inAddress))) {
        if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        uint32_t muted = *(const UInt32 *)inData ? 1 : 0;
        atomic_store_explicit(&gMuted, muted, memory_order_relaxed);
        if (gRing) atomic_store_explicit(&gRing->muted, muted, memory_order_relaxed);
        notifyDevice(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput);
        notifyLevel(kMuteID, kAudioBooleanControlPropertyValue);
        return noErr;
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus Utka_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    int32_t count = atomic_fetch_add_explicit(&gIOCount, 1, memory_order_relaxed);
    if (count == 0) {
        prepareClock();
        gAnchorHost = mach_absolute_time();
        gClockSeed += 1;
        if (gRing) gRing->active = 1;
    }
    return noErr;
}

static OSStatus Utka_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    int32_t count = atomic_load_explicit(&gIOCount, memory_order_relaxed);
    if (count > 0) count = atomic_fetch_sub_explicit(&gIOCount, 1, memory_order_relaxed) - 1;
    if (count <= 0 && gRing) gRing->active = 0;
    return noErr;
}

static OSStatus Utka_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    if (outSampleTime == NULL || outHostTime == NULL || outSeed == NULL) return kAudioHardwareIllegalOperationError;
    if (atomic_load_explicit(&gIOCount, memory_order_relaxed) <= 0 || gTicksPerFrame == 0) return kAudioHardwareNotRunningError;
    UInt64 now = mach_absolute_time();
    if (now < gAnchorHost) now = gAnchorHost;
    double frames = (double)(now - gAnchorHost) / gTicksPerFrame;
    UInt64 periods = (UInt64)(frames / (double)kClockPeriod);
    *outSampleTime = (Float64)(periods * kClockPeriod);
    *outHostTime = gAnchorHost + (UInt64)((double)(periods * kClockPeriod) * gTicksPerFrame);
    *outSeed = gClockSeed;
    return noErr;
}

static OSStatus Utka_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    if (outWillDo == NULL || outWillDoInPlace == NULL) return kAudioHardwareIllegalOperationError;
    *outWillDo = inOperationID == kAudioServerPlugInIOOperationWriteMix || inOperationID == kAudioServerPlugInIOOperationReadInput;
    *outWillDoInPlace = true;
    return noErr;
}

static OSStatus Utka_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return noErr;
}

static OSStatus Utka_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer) {
    (void)inDriver; (void)inDeviceObjectID; (void)inStreamObjectID; (void)inClientID; (void)ioSecondaryBuffer;
    if (inOperationID == kAudioServerPlugInIOOperationWriteMix) writeMix(ioMainBuffer, inIOBufferFrameSize, inIOCycleInfo);
    if (inOperationID == kAudioServerPlugInIOOperationReadInput) readInput(ioMainBuffer, inIOBufferFrameSize);
    return noErr;
}

static OSStatus Utka_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return noErr;
}

void *Utka_Create(CFAllocatorRef allocator, CFUUIDRef typeUUID) {
    (void)allocator;
    if (typeUUID != NULL && CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        return &gInterfacePtr;
    }
    return NULL;
}

__attribute__((constructor))
static void utkaFillInterface(void) {
    AudioServerPlugInDriverInterface interface = {
        NULL,
        Utka_QueryInterface,
        Utka_AddRef,
        Utka_Release,
        Utka_Initialize,
        Utka_CreateDevice,
        Utka_DestroyDevice,
        Utka_AddDeviceClient,
        Utka_RemoveDeviceClient,
        Utka_PerformDeviceConfigurationChange,
        Utka_AbortDeviceConfigurationChange,
        Utka_HasProperty,
        Utka_IsPropertySettable,
        Utka_GetPropertyDataSize,
        Utka_GetPropertyData,
        Utka_SetPropertyData,
        Utka_StartIO,
        Utka_StopIO,
        Utka_GetZeroTimeStamp,
        Utka_WillDoIOOperation,
        Utka_BeginIOOperation,
        Utka_DoIOOperation,
        Utka_EndIOOperation
    };
    gInterface = interface;
}
