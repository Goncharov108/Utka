#pragma once

#include <stdatomic.h>
#include <stdint.h>

/// Общее кольцо между плагином и Уткой. Раскладка одна на оба файла.
#define UTKA_RING_NAME "/utka-audio-ring"
#define UTKA_RING_MAGIC 0x55544B41u
#define UTKA_RING_VERSION 1u
#define UTKA_RING_FRAMES 16384u
#define UTKA_RING_CHANNELS 2u
#define UTKA_RING_RATE 48000u
#define UTKA_RING_TARGET 2048u
#define UTKA_DEVICE_UID "dev.goncharov.utka.output"

typedef struct UtkaRing {
    uint32_t magic;
    uint32_t version;
    uint32_t sampleRate;
    uint32_t channels;
    uint32_t frameCapacity;
    uint32_t active;
    _Atomic uint32_t writeFrame;
    _Atomic uint32_t volumeBits;
    _Atomic uint32_t muted;
    float samples[UTKA_RING_FRAMES * UTKA_RING_CHANNELS];
} UtkaRing;
