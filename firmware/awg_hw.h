#ifndef AWG_HW_H
#define AWG_HW_H

#include <stddef.h>
#include <stdint.h>

#define AWG_MAX_POINTS 1048576u
#define AWG_BRAM_POINTS 16384u
#define AWG_SAMPLE_BYTES (2u * AWG_MAX_POINTS)
#define AWG_WAVE_BASE 0x18000000u
#define AWG_DESC_A 0x18800000u
#define AWG_DESC_B 0x18810000u

typedef struct {
    uint8_t source;
    uint8_t shape;
    uint64_t step;
    uint64_t phase;
    uint16_t gain;
    int16_t offset;
    uint32_t divider;
    uint32_t length;
    uint16_t cycles;
    uint16_t idle_code;
    uint8_t bank;
} AwgHwConfig;

int awg_hw_init(void);
int awg_hw_memory_test(void);
int awg_hw_command(uint8_t op, uint8_t channel, uint16_t value);
int awg_hw_configure(unsigned channel, const AwgHwConfig *cfg);
int awg_hw_bram_write(unsigned channel, unsigned bank, unsigned addr, unsigned code);
int awg_hw_rate(unsigned rate_id);
int awg_hw_start_dma(unsigned channel, unsigned bank, unsigned length);
void awg_hw_stop_dma(unsigned channel);
uint32_t awg_hw_status(void);
uint32_t awg_hw_dma_error(unsigned channel);
uint16_t *awg_hw_buffer(unsigned channel, unsigned bank);
void awg_hw_flush_buffer(const void *address, size_t size);

#endif
