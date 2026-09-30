#include "awg_hw.h"
#include "xil_cache.h"
#include "xil_io.h"

/* These addresses are fixed by scripts/create_project.tcl and checked against
 * build/vivado/.../hw_handoff/awg_system.hwh before building firmware. */
#define GPIO_CMD 0x41200000u
#define GPIO_STATUS 0x41210000u
#define DMA_A 0x40400000u
#define DMA_B 0x40410000u
#define DMA_CR 0x00u
#define DMA_SR 0x04u
#define DMA_CURDESC 0x08u
#define DMA_TAILDESC 0x10u
#define DMA_RESET 0x04u
#define DMA_CYCLIC 0x10u
#define DMA_RUN 0x01u
#define DMA_ERRORS 0x770u
#define BD_SIZE 64u
#define BD_CHUNK_BYTES 8192u

static uint32_t dma_base(unsigned ch) { return ch == 0 ? DMA_A : DMA_B; }

uint16_t *awg_hw_buffer(unsigned ch, unsigned bank)
{
    if (ch > 1 || bank > 1) return 0;
    return (uint16_t *)(uintptr_t)(AWG_WAVE_BASE +
                                     (ch * 2u + bank) * AWG_SAMPLE_BYTES);
}

void awg_hw_flush_buffer(const void *address, size_t size)
{
    Xil_DCacheFlushRange((UINTPTR)address, (uint32_t)size);
}

uint32_t awg_hw_status(void) { return Xil_In32(GPIO_STATUS); }

int awg_hw_command(uint8_t op, uint8_t channel, uint16_t value)
{
    uint32_t expected = (awg_hw_status() ^ 1u) & 1u;
    Xil_Out32(GPIO_CMD, ((uint32_t)op << 24) |
                           ((uint32_t)channel << 16) | value);
    Xil_Out32(GPIO_CMD + 8u, expected);
    for (volatile unsigned spin = 0; spin < 2000000u; ++spin) {
        if ((awg_hw_status() & 1u) == expected) return 0;
    }
    return -1;
}

int awg_hw_init(void)
{
    Xil_Out32(GPIO_CMD + 4u, 0u);  /* GPIO channel 1 output */
    Xil_Out32(GPIO_CMD + 12u, 0u); /* GPIO channel 2 output */
    Xil_Out32(GPIO_STATUS + 4u, 0xffffffffu);
    for (volatile unsigned spin = 0; spin < 2000000u; ++spin)
        if (awg_hw_status() & (1u << 11)) return 0;
    return -1;
}

int awg_hw_memory_test(void)
{
    /* Test reserved waveform DDR, never the running ELF/stack. */
    volatile uint32_t *p = (volatile uint32_t *)(uintptr_t)AWG_WAVE_BASE;
    unsigned words = (4u * AWG_SAMPLE_BYTES) / sizeof(uint32_t);
    for (unsigned i = 0; i < words; ++i) p[i] = 0xa5a50000u ^ (i * 0x1021u);
    Xil_DCacheFlushRange((UINTPTR)p, words * sizeof(uint32_t));
    Xil_DCacheInvalidateRange((UINTPTR)p, words * sizeof(uint32_t));
    for (unsigned i = 0; i < words; ++i)
        if (p[i] != (0xa5a50000u ^ (i * 0x1021u))) return -1;
    return 0;
}

int awg_hw_configure(unsigned ch, const AwgHwConfig *c)
{
    if (ch > 1 || !c || c->source > 2 || c->shape > 3 ||
        c->step >> 48 || c->phase >> 48 || c->gain > 32768 ||
        !c->divider || !c->length || c->length > AWG_MAX_POINTS ||
        (c->source == 1 && c->length > AWG_BRAM_POINTS) ||
        c->idle_code > 16383 || c->bank > 1) return -1;
    uint16_t values[] = {
        c->source, c->shape, (uint16_t)c->step,
        (uint16_t)(c->step >> 16), (uint16_t)(c->step >> 32),
        (uint16_t)c->phase, (uint16_t)(c->phase >> 16),
        (uint16_t)(c->phase >> 32), c->gain, (uint16_t)c->offset,
        (uint16_t)c->divider, (uint16_t)(c->divider >> 16),
        (uint16_t)c->length, (uint16_t)(c->length >> 16),
        c->cycles, c->idle_code, c->bank
    };
    for (unsigned i = 0; i < sizeof(values)/sizeof(values[0]); ++i)
        if (awg_hw_command((uint8_t)(i + 1u), (uint8_t)ch, values[i])) return -1;
    return 0;
}

int awg_hw_bram_write(unsigned ch, unsigned bank, unsigned addr, unsigned code)
{
    if (ch > 1 || bank > 1 || addr >= AWG_BRAM_POINTS || code > 16383) return -1;
    if (awg_hw_command(0x30, 0, (uint16_t)addr) ||
        awg_hw_command(0x31, 0, (uint16_t)code) ||
        awg_hw_command(0x32, (uint8_t)ch, (uint16_t)bank)) return -1;
    return 0;
}

int awg_hw_rate(unsigned rate_id)
{
    if (rate_id > 2 || (awg_hw_status() & 0x6u)) return -1;
    return awg_hw_command(0x71, 0, (uint16_t)rate_id);
}

void awg_hw_stop_dma(unsigned ch)
{
    uint32_t base = dma_base(ch);
    Xil_Out32(base + DMA_CR, DMA_RESET);
    for (volatile unsigned spin = 0; spin < 2000000u; ++spin)
        if (!(Xil_In32(base + DMA_CR) & DMA_RESET)) break;
}

uint32_t awg_hw_dma_error(unsigned ch)
{
    if (ch > 1) return DMA_ERRORS;
    return Xil_In32(dma_base(ch) + DMA_SR) & DMA_ERRORS;
}

int awg_hw_start_dma(unsigned ch, unsigned bank, unsigned length)
{
    if (ch > 1 || bank > 1 || length <= AWG_BRAM_POINTS || length > AWG_MAX_POINTS)
        return -1;
    uint32_t base = dma_base(ch);
    uint32_t desc_base = ch ? AWG_DESC_B : AWG_DESC_A;
    uint32_t sample_base = AWG_WAVE_BASE + (ch * 2u + bank) * AWG_SAMPLE_BYTES;
    uint32_t bytes = 2u * length;
    uint32_t count = (bytes + BD_CHUNK_BYTES - 1u) / BD_CHUNK_BYTES;
    if (!count || count > 256u) return -1;
    awg_hw_stop_dma(ch);
    for (uint32_t i = 0, offset = 0; i < count; ++i) {
        volatile uint32_t *bd = (volatile uint32_t *)(uintptr_t)(desc_base + i * BD_SIZE);
        uint32_t chunk = bytes - offset;
        if (chunk > BD_CHUNK_BYTES) chunk = BD_CHUNK_BYTES;
        for (unsigned word = 0; word < BD_SIZE / 4u; ++word) bd[word] = 0;
        bd[0] = desc_base + ((i + 1u) % count) * BD_SIZE;
        bd[2] = sample_base + offset;
        bd[6] = chunk | (i == 0 ? 0x08000000u : 0) |
                (i == count - 1u ? 0x04000000u : 0);
        offset += chunk;
    }
    Xil_DCacheFlushRange((UINTPTR)sample_base, bytes);
    Xil_DCacheFlushRange((UINTPTR)desc_base, count * BD_SIZE);
    Xil_Out32(base + DMA_CURDESC, desc_base);
    Xil_Out32(base + DMA_CR, DMA_CYCLIC | DMA_RUN);
    Xil_Out32(base + DMA_TAILDESC, desc_base + (count - 1u) * BD_SIZE);
    return awg_hw_dma_error(ch) ? -1 : 0;
}
