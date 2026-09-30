#ifndef AWG_DEVICE_H
#define AWG_DEVICE_H

#include <stddef.h>
#include <stdint.h>
#include "awg_hw.h"

#define AWG_FRAME_MAX 32788u

typedef struct {
    AwgHwConfig shadow, active;
    uint32_t active_length, ready_length;
    uint8_t active_bank, ready_bank;
    uint8_t active_valid, ready_valid;
    uint8_t shadow_valid;
} AwgChannel;

typedef struct {
    uint32_t token, length, offset, crc;
    uint8_t channel, bank, active, complete;
} AwgUpload;

typedef struct {
    AwgChannel channel[2];
    AwgUpload upload;
    uint32_t sample_rate, next_token;
    uint32_t underruns[2];
    uint8_t fault, old_under, armed_external;
    uintptr_t owner;
    uintptr_t previous_session;
    uint32_t previous_id, previous_hash;
    uint8_t previous_op, cache_valid;
    size_t previous_response_len;
    uint8_t previous_response[AWG_FRAME_MAX];
} AwgDevice;

void awg_device_init(AwgDevice *dev);
void awg_device_poll(AwgDevice *dev);
void awg_device_release(AwgDevice *dev, uintptr_t session);
size_t awg_device_process(AwgDevice *dev, uintptr_t session,
                          const uint8_t *request, size_t length,
                          uint8_t *response, size_t response_capacity);

#endif
