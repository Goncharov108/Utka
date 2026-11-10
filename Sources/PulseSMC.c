#include "PulseSMC.h"

#include <IOKit/IOKitLib.h>
#include <string.h>

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_READ_KEYINFO 9

typedef struct {
    char major;
    char minor;
    char build;
    char reserved[1];
    UInt16 release;
} SMCKeyData_vers_t;

typedef struct {
    UInt16 version;
    UInt16 length;
    UInt32 cpuPLimit;
    UInt32 gpuPLimit;
    UInt32 memPLimit;
} SMCKeyData_pLimitData_t;

typedef struct {
    UInt32 dataSize;
    UInt32 dataType;
    char dataAttributes;
} SMCKeyData_keyInfo_t;

typedef char SMCBytes_t[32];

typedef struct {
    UInt32 key;
    SMCKeyData_vers_t vers;
    SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t keyInfo;
    char result;
    char status;
    char data8;
    UInt32 data32;
    SMCBytes_t bytes;
} SMCKeyData_t;

static UInt32 pulse_smc_key(const char *s) {
    return ((UInt32)(unsigned char)s[0] << 24)
        | ((UInt32)(unsigned char)s[1] << 16)
        | ((UInt32)(unsigned char)s[2] << 8)
        | (UInt32)(unsigned char)s[3];
}

static kern_return_t pulse_smc_call(io_connect_t conn, SMCKeyData_t *input, SMCKeyData_t *output) {
    size_t outSize = sizeof(SMCKeyData_t);
    return IOConnectCallStructMethod(
        conn,
        KERNEL_INDEX_SMC,
        input,
        sizeof(SMCKeyData_t),
        output,
        &outSize
    );
}

/// Один ключ SMC в градусах Цельсия. < 0 — нет значения.
static double pulse_smc_read_key(io_connect_t conn, const char *key) {
    SMCKeyData_t input;
    SMCKeyData_t output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    input.key = pulse_smc_key(key);
    input.data8 = SMC_CMD_READ_KEYINFO;
    if (pulse_smc_call(conn, &input, &output) != KERN_SUCCESS) {
        return -1;
    }
    UInt32 size = output.keyInfo.dataSize;
    UInt32 type = output.keyInfo.dataType;
    if (size == 0 || size > 32) {
        return -1;
    }
    char typeName[5] = {0};
    typeName[0] = (char)((type >> 24) & 0xff);
    typeName[1] = (char)((type >> 16) & 0xff);
    typeName[2] = (char)((type >> 8) & 0xff);
    typeName[3] = (char)(type & 0xff);

    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    input.key = pulse_smc_key(key);
    input.keyInfo.dataSize = size;
    input.data8 = SMC_CMD_READ_BYTES;
    if (pulse_smc_call(conn, &input, &output) != KERN_SUCCESS) {
        return -1;
    }

    if (strncmp(typeName, "sp78", 4) == 0) {
        return (double)((signed char)output.bytes[0]) + ((unsigned char)output.bytes[1]) / 256.0;
    }
    if (strncmp(typeName, "flt", 3) == 0) {
        float value = 0;
        memcpy(&value, output.bytes, sizeof(float));
        return (double)value;
    }
    return -1;
}

int PulseSMCReadCelsius(double *celsius) {
    if (celsius == NULL) {
        return 0;
    }
    *celsius = 0;

    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &iterator) != KERN_SUCCESS) {
        return 0;
    }
    io_object_t device = IOIteratorNext(iterator);
    IOObjectRelease(iterator);
    if (device == 0) {
        return 0;
    }

    io_connect_t conn = 0;
    kern_return_t open = IOServiceOpen(device, mach_task_self(), 0, &conn);
    IOObjectRelease(device);
    if (open != KERN_SUCCESS || conn == 0) {
        return 0;
    }

    // Ближайшие к чипу датчики. Берём максимум из тех, что ответили.
    static const char *keys[] = {
        "TC0P", "TC0E", "TC0F", "TCGC", "TW0P", NULL
    };
    double best = -1;
    for (int i = 0; keys[i] != NULL; i++) {
        double value = pulse_smc_read_key(conn, keys[i]);
        if (value > 1.0 && value < 120.0 && value > best) {
            best = value;
        }
    }
    IOServiceClose(conn);
    if (best < 0) {
        return 0;
    }
    *celsius = best;
    return 1;
}
