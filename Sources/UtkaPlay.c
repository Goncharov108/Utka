#include "UtkaPlay.h"
#include "../AudioDriver/UtkaRing.h"

#include <CoreAudio/AudioHardware.h>
#include <math.h>
#include <os/log.h>
#include <string.h>

/// Читает общее кольцо и пишет его в железо одним колбэком часов этого устройства.

static UtkaRing *gRing = NULL;
static AudioDeviceID gDevice = 0;
static AudioDeviceIOProcID gProc = NULL;
static double gRead = 0;
static double gOutRate = UTKA_RING_RATE;
static int gPrimed = 0;
static uint32_t gEpochSeen = 0;

typedef struct PlayLayout {
    UInt32 channels;
    UInt32 bytesPerSample;
    UInt32 bits;
    int isFloat;
    int nonInterleaved;
} PlayLayout;

static PlayLayout gLayout;

/// Формат выбранного выхода: частота для шага ленты и раскладка кадров.
static int rememberLayout(AudioDeviceID device) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyStreamFormat,
        kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    UInt32 size = sizeof(format);
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &format) != noErr) return 1;
    if (format.mSampleRate < 1 || format.mChannelsPerFrame == 0) return 1;
    int nonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 bytes = nonInterleaved ? format.mBytesPerFrame : format.mBytesPerFrame / format.mChannelsPerFrame;
    if (bytes != 2 && bytes != 4) {
        os_log_error(OS_LOG_DEFAULT, "utka output format unsupported bits %u", (unsigned)format.mBitsPerChannel);
        return 1;
    }
    gOutRate = format.mSampleRate;
    gLayout.channels = format.mChannelsPerFrame;
    gLayout.bytesPerSample = bytes;
    gLayout.bits = format.mBitsPerChannel;
    gLayout.isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    gLayout.nonInterleaved = nonInterleaved;
    return 0;
}

static AudioDeviceID deviceForUID(const char *uid) {
    CFStringRef name = CFStringCreateWithCString(NULL, uid, kCFStringEncodingUTF8);
    if (name == NULL) return 0;
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyTranslateUIDToDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectID id = 0;
    UInt32 size = sizeof(id);
    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, sizeof(name), &name, &size, &id);
    CFRelease(name);
    if (status != noErr) return 0;
    return id;
}

/// Сэмпл в формат выхода. 24 бита в слове — старшие разряды, как ждёт CoreAudio.
static void putSample(void *base, UInt32 index, float sample) {
    if (sample > 1.f) sample = 1.f;
    if (sample < -1.f) sample = -1.f;
    if (gLayout.isFloat) {
        ((float *)base)[index] = sample;
        return;
    }
    if (gLayout.bytesPerSample == 2) {
        ((int16_t *)base)[index] = (int16_t)lrintf(sample * 32767.f);
        return;
    }
    float scale = gLayout.bits == 24 ? 8388607.f : 2147483647.f;
    int32_t wide = (int32_t)lrintf(sample * scale);
    if (gLayout.bits == 24) wide <<= 8;
    ((int32_t *)base)[index] = wide;
}

/// Каналы лежат отдельными буферами, а не подряд в одном.
static int buffersAreSplit(const AudioBufferList *list) {
    if (list == NULL || list->mNumberBuffers == 0) return 0;
    if (list->mNumberBuffers > 1) return 1;
    return gLayout.nonInterleaved && list->mBuffers[0].mNumberChannels <= 1;
}

/// Кладёт стерео в кадр: лишние каналы остаются тишиной, моно — среднее.
static void writeFrameSample(AudioBufferList *list, UInt32 frame, float left, float right) {
    UInt32 buffers = list->mNumberBuffers;
    if (buffers == 0) return;
    if (buffersAreSplit(list)) {
        for (UInt32 channel = 0; channel < buffers; channel++) {
            AudioBuffer *buf = &list->mBuffers[channel];
            if (buf->mData == NULL) continue;
            float sample = 0;
            if (buffers == 1) sample = 0.5f * (left + right);
            else if (channel == 0) sample = left;
            else if (channel == 1) sample = right;
            putSample(buf->mData, frame, sample);
        }
        return;
    }
    AudioBuffer *buf = &list->mBuffers[0];
    if (buf->mData == NULL || buf->mNumberChannels == 0) return;
    UInt32 channels = buf->mNumberChannels;
    for (UInt32 channel = 0; channel < channels; channel++) {
        float sample = 0;
        if (channels == 1) sample = 0.5f * (left + right);
        else if (channel == 0) sample = left;
        else if (channel == 1) sample = right;
        putSample(buf->mData, frame * channels + channel, sample);
    }
}

/// Сколько кадров просит железо в этом колбэке.
static UInt32 frameCount(const AudioBufferList *list) {
    if (list == NULL || list->mNumberBuffers == 0) return 0;
    const AudioBuffer *buf = &list->mBuffers[0];
    UInt32 channels = buffersAreSplit(list) ? 1 : buf->mNumberChannels;
    if (channels == 0) channels = 1;
    UInt32 bytes = gLayout.bytesPerSample * channels;
    if (bytes == 0 || buf->mData == NULL || buf->mDataByteSize < bytes) return 0;
    return buf->mDataByteSize / bytes;
}

/// Читает ленту с запасом. Уход часов подтягивает шаг, позицию не отбрасывает.
static void renderStereo(float *dst, UInt32 frames) {
    memset(dst, 0, (size_t)frames * 2u * sizeof(float));
    if (gRing == NULL || frames == 0) return;
    uint32_t epoch = atomic_load_explicit(&gRing->epoch, memory_order_acquire);
    uint64_t write = atomic_load_explicit(&gRing->writeFrame, memory_order_acquire);
    if (epoch != gEpochSeen) {
        gEpochSeen = epoch;
        gPrimed = 0;
    }
    if (!gPrimed) {
        if (write < UTKA_RING_TARGET) return;
        gRead = (double)(write - UTKA_RING_TARGET);
        gPrimed = 1;
    }
    if ((double)write > gRead && (double)write - gRead > (double)UTKA_RING_FRAMES) {
        gRead = (double)(write - UTKA_RING_TARGET);
    }
    if (gRead > (double)write) gRead = (double)write;
    double error = ((double)write - gRead) - (double)UTKA_RING_TARGET;
    double trim = error / ((double)UTKA_RING_RATE * 0.5);
    if (trim > 0.002) trim = 0.002;
    if (trim < -0.002) trim = -0.002;
    double rate = gOutRate < 1 ? (double)UTKA_RING_RATE : gOutRate;
    double step = ((double)UTKA_RING_RATE / rate) * (1.0 + trim);
    uint32_t mask = UTKA_RING_FRAMES - 1u;
    for (UInt32 i = 0; i < frames; i++) {
        if (gRead + 1.0 >= (double)write) break;
        uint64_t i0 = (uint64_t)gRead;
        float frac = (float)(gRead - (double)i0);
        uint32_t a = (uint32_t)i0 & mask;
        uint32_t b = (uint32_t)(i0 + 1u) & mask;
        float left0 = gRing->samples[a * 2u];
        float left1 = gRing->samples[b * 2u];
        float right0 = gRing->samples[a * 2u + 1u];
        float right1 = gRing->samples[b * 2u + 1u];
        dst[i * 2u] = left0 + (left1 - left0) * frac;
        dst[i * 2u + 1u] = right0 + (right1 - right0) * frac;
        gRead += step;
    }
    if (gRead > (double)write) gRead = (double)write;
}

/// Колбэк железа: забирает ленту и заполняет его буфер.
static OSStatus playIO(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *inputData, const AudioTimeStamp *inputTime, AudioBufferList *outputData, const AudioTimeStamp *outputTime, void *client) {
    (void)device; (void)now; (void)inputData; (void)inputTime; (void)outputTime; (void)client;
    UInt32 frames = frameCount(outputData);
    if (frames == 0) return noErr;
    UInt32 done = 0;
    while (done < frames) {
        UInt32 chunk = frames - done;
        if (chunk > 1024) chunk = 1024;
        float stereo[1024 * 2];
        renderStereo(stereo, chunk);
        for (UInt32 i = 0; i < chunk; i++) writeFrameSample(outputData, done + i, stereo[i * 2u], stereo[i * 2u + 1u]);
        done += chunk;
    }
    return noErr;
}

int UtkaPlayOpen(void) {
    if (gRing == NULL) gRing = utkaRingMap(NULL);
    if (gRing == NULL || gRing->magic != UTKA_RING_MAGIC || gRing->version != UTKA_RING_VERSION) return 0;
    return deviceForUID(UTKA_DEVICE_UID) != 0;
}

static void stopProc(void) {
    if (gProc == NULL || gDevice == 0) {
        gProc = NULL;
        gDevice = 0;
        gPrimed = 0;
        return;
    }
    AudioDeviceStop(gDevice, gProc);
    AudioDeviceDestroyIOProcID(gDevice, gProc);
    gProc = NULL;
    gDevice = 0;
    gPrimed = 0;
}

/// Вешает колбэк на устройство. Частоту железа не меняет: шаг ленты подстраивается сам.
static int startPair(AudioDeviceID deviceID) {
    if (gRing == NULL || rememberLayout(deviceID) != 0) return 1;
    gPrimed = 0;
    AudioDeviceIOProcID proc = NULL;
    OSStatus status = AudioDeviceCreateIOProcID(deviceID, playIO, NULL, &proc);
    if (status != noErr || proc == NULL) {
        os_log_error(OS_LOG_DEFAULT, "utka io create failed %d", (int)status);
        return 1;
    }
    status = AudioDeviceStart(deviceID, proc);
    if (status != noErr) {
        AudioDeviceDestroyIOProcID(deviceID, proc);
        os_log_error(OS_LOG_DEFAULT, "utka io start failed %d", (int)status);
        return 1;
    }
    gProc = proc;
    gDevice = deviceID;
    return 0;
}

void UtkaPlayStop(void) {
    stopProc();
}

int UtkaPlayStart(uint32_t deviceID) {
    if (deviceID == 0) return 1;
    AudioDeviceID source = deviceForUID(UTKA_DEVICE_UID);
    if (source == 0 || source == deviceID) return 1;
    if (gDevice == deviceID && gProc != NULL) return 0;
    AudioDeviceID previous = gDevice;
    UtkaPlayStop();
    if (startPair(deviceID) == 0) return 0;
    if (previous != 0 && previous != deviceID) startPair(previous);
    return 1;
}

void UtkaPlayClose(void) {
    UtkaPlayStop();
}

uint32_t UtkaPlayDevice(void) {
    return gDevice;
}
