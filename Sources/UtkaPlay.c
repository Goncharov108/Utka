#include "UtkaPlay.h"
#include "../AudioDriver/UtkaRing.h"

#include <CoreAudio/AudioHardware.h>
#include <AudioToolbox/AudioQueue.h>
#include <os/log.h>
#include <string.h>
#include <math.h>

/// Слушает вход «Утка звук» и пишет его в настоящий выход.

static UtkaRing gLocal;
static UtkaRing *gRing = &gLocal;
static AudioDeviceID gDevice = 0;
static AudioQueueRef gQueue = NULL;
static AudioQueueRef gInputQueue = NULL;
static double gPhase = 0;
static int gPrimed = 0;
static double gOutRate = UTKA_RING_RATE;

static float sampleAt(uint32_t frame, int channel) {
    uint32_t index = frame & (UTKA_RING_FRAMES - 1);
    return gRing->samples[index * 2 + (uint32_t)channel];
}

/// Кладёт стерео float из входной очереди в локальное кольцо.
static void pushSamples(const float *interleaved, UInt32 frames) {
    if (interleaved == NULL || frames == 0) return;
    uint32_t start = atomic_load_explicit(&gRing->writeFrame, memory_order_relaxed);
    uint32_t mask = UTKA_RING_FRAMES - 1;
    for (UInt32 i = 0; i < frames; i++) {
        uint32_t index = (start + i) & mask;
        gRing->samples[index * 2] = interleaved[i * 2];
        gRing->samples[index * 2 + 1] = interleaved[i * 2 + 1];
    }
    atomic_store_explicit(&gRing->writeFrame, start + frames, memory_order_release);
}

/// Забирает петлю «Утка звук». Очередь только читает, поэтому система не глушит её как эхо.
static void inputQueueCallback(void *user, AudioQueueRef queue, AudioQueueBufferRef buffer, const AudioTimeStamp *startTime, UInt32 packets, const AudioStreamPacketDescription *desc) {
    (void)user; (void)startTime; (void)packets; (void)desc;
    UInt32 frames = buffer->mAudioDataByteSize / (UInt32)(sizeof(float) * 2);
    pushSamples(buffer->mAudioData, frames);
    AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
}

/// Кладёт кадры кольца в стерео float подряд.
static void fillInterleaved(float *data, UInt32 frames) {
    memset(data, 0, (size_t)frames * 2 * sizeof(float));
    uint32_t write = atomic_load_explicit(&gRing->writeFrame, memory_order_acquire);
    if (!gPrimed) {
        if (write - (uint32_t)gPhase < UTKA_RING_TARGET) return;
        gPhase = (double)(write - UTKA_RING_TARGET);
        gPrimed = 1;
    }
    if ((uint32_t)(write - (uint32_t)gPhase) > UTKA_RING_FRAMES) {
        gPhase = (double)(write - UTKA_RING_TARGET);
    }
    double step = (double)UTKA_RING_RATE / gOutRate;
    for (uint32_t i = 0; i < frames; i++) {
        uint32_t i0 = (uint32_t)gPhase;
        if ((uint32_t)(write - (i0 + 1)) > UTKA_RING_FRAMES) break;
        float frac = (float)(gPhase - (double)i0);
        float left = sampleAt(i0, 0) + (sampleAt(i0 + 1, 0) - sampleAt(i0, 0)) * frac;
        float right = sampleAt(i0, 1) + (sampleAt(i0 + 1, 1) - sampleAt(i0, 1)) * frac;
        data[i * 2] = left;
        data[i * 2 + 1] = right;
        gPhase += step;
    }
}

/// Очередь AudioQueue просит следующий кусок для выбранного железа.
static void queueCallback(void *user, AudioQueueRef queue, AudioQueueBufferRef buffer) {
    (void)user;
    UInt32 frames = buffer->mAudioDataBytesCapacity / (UInt32)(sizeof(float) * 2);
    if (frames == 0) frames = 1;
    fillInterleaved(buffer->mAudioData, frames);
    buffer->mAudioDataByteSize = frames * (UInt32)(sizeof(float) * 2);
    AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
}

static Float64 nominalRate(AudioDeviceID device) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    Float64 rate = 0;
    UInt32 size = sizeof(rate);
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &rate) != noErr) return UTKA_RING_RATE;
    return rate;
}

static void preferRingRate(AudioDeviceID device) {
    if (fabs(nominalRate(device) - (Float64)UTKA_RING_RATE) < 1) return;
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    Float64 rate = UTKA_RING_RATE;
    AudioObjectSetPropertyData(device, &address, 0, NULL, sizeof(rate), &rate);
}

static void rememberLayout(AudioDeviceID device) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyStreamFormat,
        kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    UInt32 size = sizeof(format);
    gOutRate = nominalRate(device);
    if (gOutRate < 1) gOutRate = UTKA_RING_RATE;
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &format) != noErr) return;
    if (format.mSampleRate > 1) gOutRate = format.mSampleRate;
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

int UtkaPlayOpen(void) {
    if (gRing->magic != UTKA_RING_MAGIC) {
        memset(&gLocal, 0, sizeof(gLocal));
        gRing->magic = UTKA_RING_MAGIC;
        gRing->version = UTKA_RING_VERSION;
        gRing->frameCapacity = UTKA_RING_FRAMES;
        gRing->active = 1;
    }
    return deviceForUID(UTKA_DEVICE_UID) != 0;
}

/// Останавливает очередь и отпускает её.
static void disposeQueue(AudioQueueRef *queue) {
    if (queue == NULL || *queue == NULL) return;
    AudioQueueStop(*queue, true);
    AudioQueueDispose(*queue, true);
    *queue = NULL;
}

/// Три тихих буфера, чтобы очередь стартовала сразу.
static int primeQueue(AudioQueueRef queue) {
    UInt32 bytes = 512 * 8;
    for (int i = 0; i < 3; i++) {
        AudioQueueBufferRef buffer = NULL;
        OSStatus status = AudioQueueAllocateBuffer(queue, bytes, &buffer);
        if (status != noErr || buffer == NULL) return 1;
        memset(buffer->mAudioData, 0, bytes);
        buffer->mAudioDataByteSize = bytes;
        AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
    }
    return 0;
}

/// Постоянный идентификатор устройства, чтобы очередь играла именно в него.
static CFStringRef copyDeviceUID(AudioDeviceID device) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyDeviceUID,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    CFStringRef uid = NULL;
    UInt32 size = sizeof(uid);
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &uid) != noErr) return NULL;
    return uid;
}

/// Открывает очередь на выбранное железо. Три буфера по 512 кадров.
static int startQueue(AudioDeviceID deviceID) {
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    format.mSampleRate = gOutRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format.mBitsPerChannel = 32;
    format.mChannelsPerFrame = 2;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = 8;
    format.mBytesPerPacket = 8;
    AudioQueueRef queue = NULL;
    OSStatus status = AudioQueueNewOutput(&format, queueCallback, NULL, NULL, NULL, 0, &queue);
    if (status != noErr || queue == NULL) {
        os_log_error(OS_LOG_DEFAULT, "utka queue create failed %d", (int)status);
        return 1;
    }
    CFStringRef uid = copyDeviceUID(deviceID);
    if (uid == NULL) {
        AudioQueueDispose(queue, true);
        return 1;
    }
    status = AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, &uid, sizeof(uid));
    CFRelease(uid);
    if (status != noErr) {
        AudioQueueDispose(queue, true);
        os_log_error(OS_LOG_DEFAULT, "utka queue device failed %d", (int)status);
        return 1;
    }
    if (primeQueue(queue) != 0) {
        AudioQueueDispose(queue, true);
        os_log_error(OS_LOG_DEFAULT, "utka queue buffer failed");
        return 1;
    }
    status = AudioQueueStart(queue, NULL);
    if (status != noErr) {
        AudioQueueDispose(queue, true);
        os_log_error(OS_LOG_DEFAULT, "utka queue start failed %d", (int)status);
        return 1;
    }
    gQueue = queue;
    return 0;
}

/// Слушает «Утка звук» отдельной входной очередью, не колбэком устройства.
static int startInputQueue(void) {
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    format.mSampleRate = UTKA_RING_RATE;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format.mBitsPerChannel = 32;
    format.mChannelsPerFrame = 2;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = 8;
    format.mBytesPerPacket = 8;
    AudioQueueRef queue = NULL;
    OSStatus status = AudioQueueNewInput(&format, inputQueueCallback, NULL, NULL, NULL, 0, &queue);
    if (status != noErr || queue == NULL) {
        os_log_error(OS_LOG_DEFAULT, "utka input create failed %d", (int)status);
        return 1;
    }
    CFStringRef uid = CFStringCreateWithCString(NULL, UTKA_DEVICE_UID, kCFStringEncodingUTF8);
    if (uid == NULL) {
        AudioQueueDispose(queue, true);
        return 1;
    }
    status = AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, &uid, sizeof(uid));
    CFRelease(uid);
    if (status != noErr || primeQueue(queue) != 0) {
        AudioQueueDispose(queue, true);
        os_log_error(OS_LOG_DEFAULT, "utka input device failed %d", (int)status);
        return 1;
    }
    status = AudioQueueStart(queue, NULL);
    if (status != noErr) {
        AudioQueueDispose(queue, true);
        os_log_error(OS_LOG_DEFAULT, "utka input start failed %d", (int)status);
        return 1;
    }
    gInputQueue = queue;
    return 0;
}

void UtkaPlayStop(void) {
    disposeQueue(&gQueue);
    disposeQueue(&gInputQueue);
    gDevice = 0;
    gPrimed = 0;
}

/// Открывает вход виртуального устройства и очередь на железо. При ошибке оба закрывает.
static int startPair(AudioDeviceID deviceID) {
    preferRingRate(deviceID);
    rememberLayout(deviceID);
    uint32_t write = atomic_load_explicit(&gRing->writeFrame, memory_order_acquire);
    gPhase = write;
    gPrimed = 0;
    if (startInputQueue() != 0) return 1;
    if (startQueue(deviceID) != 0) {
        disposeQueue(&gInputQueue);
        return 1;
    }
    gDevice = deviceID;
    return 0;
}

int UtkaPlayStart(uint32_t deviceID) {
    if (deviceID == 0) return 1;
    AudioDeviceID source = deviceForUID(UTKA_DEVICE_UID);
    if (source == 0 || source == deviceID) return 1;
    if (gDevice == deviceID && gQueue != NULL && gInputQueue != NULL) return 0;
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
