#pragma once

#include <fcntl.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

/// Общее кольцо между плагином и Уткой. Раскладка одна на оба файла.
#define UTKA_RING_NAME "/utka-audio-ring"
#define UTKA_RING_MAGIC 0x55544B41u
#define UTKA_RING_VERSION 2u
#define UTKA_RING_FRAMES 16384u
#define UTKA_RING_CHANNELS 2u
#define UTKA_RING_RATE 48000u
#define UTKA_RING_TARGET 2048u
#define UTKA_DEVICE_UID "dev.goncharov.utka.output"

_Static_assert((UTKA_RING_FRAMES & (UTKA_RING_FRAMES - 1u)) == 0u, "ёмкость кольца должна быть степенью двух");

typedef struct UtkaRing {
    uint32_t magic;
    uint32_t version;
    uint32_t sampleRate;
    uint32_t channels;
    uint32_t frameCapacity;
    uint32_t active;
    /// Следующий кадр ленты, который ещё не записан. Индекс в кольце — номер по маске.
    _Atomic uint64_t writeFrame;
    /// Растёт, когда лента времени начинается заново.
    _Atomic uint32_t epoch;
    _Atomic uint32_t volumeBits;
    _Atomic uint32_t muted;
    float samples[UTKA_RING_FRAMES * UTKA_RING_CHANNELS];
} UtkaRing;

/// Биты скаляра 0.25: стартовая громкость, пока ползунок ещё не двинули.
static inline uint32_t utkaDefaultVolumeBits(void) {
    float quarter = 0.25f;
    uint32_t bits = 0;
    memcpy(&bits, &quarter, sizeof(bits));
    return bits;
}

/// Кольцо должно читать и приложение, не только процесс системного звука.
static inline int ringShared(int fd) {
    struct stat info;
    if (fstat(fd, &info) != 0) return 0;
    return (info.st_mode & S_IROTH) != 0 && (info.st_mode & S_IWOTH) != 0;
}

/// Создаёт объект с маской 0, иначе демон оставляет его только себе.
static inline int openRingFd(void) {
    int fd = shm_open(UTKA_RING_NAME, O_RDWR, 0666);
    if (fd >= 0 && ringShared(fd)) return fd;
    if (fd >= 0) {
        if (fchmod(fd, 0666) == 0 && ringShared(fd)) return fd;
        close(fd);
        if (shm_unlink(UTKA_RING_NAME) != 0) return -1;
    }
    mode_t previous = umask(0);
    fd = shm_open(UTKA_RING_NAME, O_CREAT | O_RDWR, 0666);
    umask(previous);
    if (fd >= 0) (void)fchmod(fd, 0666);
    return fd;
}

/// Открывает общую память кольца. При несовпадении версии обнуляет шапку.
static inline UtkaRing *utkaRingMap(int *created) {
    if (created) *created = 0;
    int fd = openRingFd();
    int writable = 1;
    if (fd < 0 && created == NULL) {
        writable = 0;
        fd = shm_open(UTKA_RING_NAME, O_RDONLY, 0444);
    }
    if (fd < 0) return NULL;
    struct stat info;
    if (fstat(fd, &info) != 0) {
        close(fd);
        return NULL;
    }
    if (info.st_size < (off_t)sizeof(UtkaRing)) {
        if (ftruncate(fd, (off_t)sizeof(UtkaRing)) != 0) {
            close(fd);
            return NULL;
        }
    }
    void *memory = MAP_FAILED;
    if (writable) memory = mmap(NULL, sizeof(UtkaRing), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (memory == MAP_FAILED) {
        writable = 0;
        memory = mmap(NULL, sizeof(UtkaRing), PROT_READ, MAP_SHARED, fd, 0);
    }
    close(fd);
    if (memory == MAP_FAILED) return NULL;
    UtkaRing *ring = memory;
    if (ring->magic == UTKA_RING_MAGIC && ring->version == UTKA_RING_VERSION && ring->frameCapacity == UTKA_RING_FRAMES) {
        return ring;
    }
    if (!writable) {
        munmap(memory, sizeof(UtkaRing));
        return NULL;
    }
    memset(ring, 0, sizeof(UtkaRing));
    ring->sampleRate = UTKA_RING_RATE;
    ring->channels = UTKA_RING_CHANNELS;
    ring->frameCapacity = UTKA_RING_FRAMES;
    atomic_store_explicit(&ring->writeFrame, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->epoch, 1, memory_order_relaxed);
    atomic_store_explicit(&ring->volumeBits, utkaDefaultVolumeBits(), memory_order_relaxed);
    ring->magic = UTKA_RING_MAGIC;
    ring->version = UTKA_RING_VERSION;
    if (created) *created = 1;
    return ring;
}
