#include <stdint.h>
#include <string.h>
#include "awg_hw.h"

static uint16_t wave[2][2][AWG_MAX_POINTS];
static uint16_t bram[2][2][AWG_BRAM_POINTS];
static uint32_t status = 1u << 11;
static uint32_t command_count;

int usleep(unsigned long microseconds) { (void)microseconds; return 0; }
int awg_hw_init(void) { return 0; }
int awg_hw_memory_test(void) { return 0; }
uint16_t *awg_hw_buffer(unsigned ch, unsigned bank) { return wave[ch][bank]; }
void awg_hw_flush_buffer(const void *address, size_t size)
{ (void)address; (void)size; }
uint32_t awg_hw_status(void) { return status; }
uint32_t awg_hw_dma_error(unsigned ch) { (void)ch; return 0; }
int awg_hw_rate(unsigned rate_id) { (void)rate_id; return 0; }
int awg_hw_configure(unsigned ch, const AwgHwConfig *cfg)
{ (void)ch; (void)cfg; return 0; }
int awg_hw_start_dma(unsigned ch, unsigned bank, unsigned length)
{ (void)ch; (void)bank; (void)length; status |= 0x60u; return 0; }
void awg_hw_stop_dma(unsigned ch) { (void)ch; }
int awg_hw_bram_write(unsigned ch, unsigned bank, unsigned address, unsigned code)
{ bram[ch][bank][address] = (uint16_t)code; return 0; }
int awg_hw_command(uint8_t op, uint8_t ch, uint16_t value)
{
    (void)ch;
    ++command_count;
    if (op == 0x80) {
        status &= ~((uint32_t)(value & 3u) << 1);
        status &= ~((uint32_t)(value & 3u) << 7);
    }
    if (op == 0x81) status |= (uint32_t)(value & 3u) << 7;
    if (op == 0x82) {
        status |= (uint32_t)(value & 3u) << 1;
        status &= ~((uint32_t)(value & 3u) << 7);
    }
    return 0;
}
uint16_t stub_bram(unsigned ch, unsigned bank, unsigned address)
{ return bram[ch][bank][address]; }
uint32_t stub_status(void) { return status; }
void stub_set_status(uint32_t value) { status = value; }
uint32_t stub_command_count(void) { return command_count; }
uint16_t stub_wave(unsigned ch, unsigned bank, unsigned address)
{ return wave[ch][bank][address]; }
