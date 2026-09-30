#include "awg_device.h"
#include <string.h>
#include "sleep.h"

#define OP_INFO 0x01u
#define OP_STATUS 0x02u
#define OP_CONFIG 0x03u
#define OP_APPLY 0x04u
#define OP_RATE 0x05u
#define OP_BEGIN 0x10u
#define OP_DATA 0x11u
#define OP_END 0x12u
#define OP_COMMIT 0x13u
#define OP_QUERY 0x14u
#define OP_ARM 0x20u
#define OP_START 0x21u
#define OP_STOP 0x22u
#define OP_CLEAR 0x23u
#define E_CRC 1u
#define E_LENGTH 2u
#define E_VALUE 3u
#define E_STATE 4u
#define E_UPLOAD 5u
#define E_OWNER 6u
#define E_HARDWARE 7u
#define E_UNKNOWN 8u

static uint32_t table[256];
static uint8_t table_ready;
static void crc_init(void)
{
    if (table_ready) return;
    for (uint32_t i = 0; i < 256u; ++i) {
        uint32_t value = i;
        for (unsigned bit = 0; bit < 8u; ++bit)
            value = (value >> 1) ^ ((value & 1u) ? 0xedb88320u : 0u);
        table[i] = value;
    }
    table_ready = 1;
}
static uint32_t crc_step(uint32_t crc, const uint8_t *data, size_t length)
{
    for (size_t i = 0; i < length; ++i)
        crc = table[(crc ^ data[i]) & 255u] ^ (crc >> 8);
    return crc;
}
static uint32_t crc32_bytes(const uint8_t *data, size_t length)
{
    return ~crc_step(~0u, data, length);
}
static uint16_t rd16(const uint8_t *p)
{
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}
static uint32_t rd32(const uint8_t *p)
{
    return (uint32_t)rd16(p) | ((uint32_t)rd16(p + 2) << 16);
}
static uint64_t rd64(const uint8_t *p)
{
    return (uint64_t)rd32(p) | ((uint64_t)rd32(p + 4) << 32);
}
static void wr16(uint8_t *p, uint16_t value)
{
    p[0] = (uint8_t)value; p[1] = (uint8_t)(value >> 8);
}
static void wr32(uint8_t *p, uint32_t value)
{
    wr16(p, (uint16_t)value); wr16(p + 2, (uint16_t)(value >> 16));
}

void awg_device_init(AwgDevice *dev)
{
    memset(dev, 0, sizeof(*dev));
    crc_init();
    dev->next_token = 1;
    dev->sample_rate = 10000000u;
    for (unsigned ch = 0; ch < 2; ++ch) {
        dev->channel[ch].active.gain = 32768;
        dev->channel[ch].active.divider = 1;
        dev->channel[ch].active.length = 1;
        dev->channel[ch].active.idle_code = 8192;
    }
}

void awg_device_poll(AwgDevice *dev)
{
    uint32_t status = awg_hw_status();
    uint8_t under = (uint8_t)((status >> 3) & 3u);
    for (unsigned ch = 0; ch < 2; ++ch)
        if ((under & (1u << ch)) && !(dev->old_under & (1u << ch)))
            ++dev->underruns[ch];
    dev->old_under = under;
    if (under) dev->fault |= 1u;
    if (!(status & (1u << 11))) {
        /* Loss of MMCM lock asynchronously resets the PL to its idle code.
         * Its command FIFO cannot acknowledge requests until lock returns. */
        dev->fault |= 4u;
    }
    if (awg_hw_dma_error(0) || awg_hw_dma_error(1)) {
        uint8_t first_dma_fault = !(dev->fault & 2u);
        dev->fault |= 2u;
        if (first_dma_fault && (status & (1u << 11)))
            awg_hw_command(0x80, 0, 3);
    }
}

void awg_device_release(AwgDevice *dev, uintptr_t session)
{
    if (dev->owner == session) dev->owner = 0;
    if (dev->previous_session == session) dev->cache_valid = 0;
}

static int fade_stop(AwgDevice *dev, uint8_t mask)
{
    uint8_t running = (uint8_t)((awg_hw_status() >> 1) & 3u) & mask;
    if (running) {
        for (unsigned ch = 0; ch < 2; ++ch) if (running & (1u << ch)) {
            AwgHwConfig fade = dev->channel[ch].active;
            fade.gain = 0;
            fade.offset = (int16_t)((int32_t)fade.idle_code - 8192);
            if (awg_hw_configure(ch, &fade)) return -1;
        }
        if (awg_hw_command(0x70, 0, running)) return -1;
        usleep(1100);
    }
    if (awg_hw_command(0x80, 0, mask)) return -1;
    for (unsigned ch = 0; ch < 2; ++ch)
        if (mask & (1u << ch)) awg_hw_stop_dma(ch);
    return 0;
}

static uint16_t configure_active(uint8_t mask,
                                 const AwgHwConfig replacement[2])
{
    for (unsigned ch = 0; ch < 2; ++ch)
        if ((mask & (1u << ch)) && awg_hw_configure(ch, &replacement[ch]))
            return E_HARDWARE;
    return awg_hw_command(0x70, 0, mask) ? E_HARDWARE : 0;
}

static uint8_t finite_running(const AwgDevice *dev, uint8_t mask)
{
    uint8_t running = (uint8_t)((awg_hw_status() >> 1) & 3u) & mask;
    for (unsigned ch = 0; ch < 2; ++ch)
        if ((running & (1u << ch)) && dev->channel[ch].active.cycles)
            return 1;
    return 0;
}

static uint16_t process_op(AwgDevice *dev, uintptr_t session,
                           uint8_t op, const uint8_t *p, uint32_t n,
                           uint8_t *out, uint32_t *out_len)
{
    uint8_t mask;
    if (op == OP_INFO && n == 0) {
        out[0] = 2; wr32(out + 1, 2); wr32(out + 5, dev->sample_rate);
        wr32(out + 9, AWG_MAX_POINTS); *out_len = 13; return 0;
    }
    if (op == OP_STATUS && n == 0) {
        awg_device_poll(dev);
        out[0] = (uint8_t)((awg_hw_status() >> 1) & 3u);
        out[1] = dev->fault;
        wr32(out + 2, dev->underruns[0]); wr32(out + 6, dev->underruns[1]);
        *out_len = 10; return 0;
    }
    if (op == OP_STOP && n == 1 && p[0] > 0 && p[0] < 4) {
        dev->armed_external = 0;
        return fade_stop(dev, p[0]) ? E_HARDWARE : 0;
    }
    if (op == OP_CLEAR && n == 0) {
        if (awg_hw_status() & 0x6u) return E_STATE;
        awg_hw_stop_dma(0);
        awg_hw_stop_dma(1);
        if (awg_hw_command(0x83, 0, 0)) return E_HARDWARE;
        dev->fault = 0; dev->old_under = 0; return 0;
    }
    if (dev->owner && dev->owner != session) {
        /* A new TCP session may resume an interrupted upload. */
        if (!(op == OP_BEGIN && n == 9 && dev->upload.active &&
              p[0] == dev->upload.channel + 1u &&
              rd32(p + 1) == dev->upload.length &&
              rd32(p + 5) == dev->upload.crc) &&
            !(op == OP_QUERY && n == 4 &&
              rd32(p) == dev->upload.token)) return E_OWNER;
    }
    dev->owner = session;
    if (op == OP_RATE && n == 4) {
        uint32_t rate = rd32(p);
        unsigned rate_id = rate == 10000000u ? 0 :
                           rate == 25000000u ? 1 :
                           rate == 50000000u ? 2 : 3;
        if (rate_id == 3) return E_VALUE;
        if (finite_running(dev, 3)) return E_STATE;
        if (fade_stop(dev, 3) || awg_hw_command(0x84, 0, 3) ||
            awg_hw_rate(rate_id)) return E_HARDWARE;
        dev->armed_external = 0;
        dev->sample_rate = rate;
        return 0;
    }
    if (op == OP_CONFIG && n == 29) {
        unsigned ch = p[0] - 1u;
        if (p[0] < 1 || p[0] > 2 || p[1] > 1 || p[2] > 3) return E_VALUE;
        if (finite_running(dev, (uint8_t)(1u << ch))) return E_STATE;
        AwgHwConfig c = dev->channel[ch].shadow_valid ?
                        dev->channel[ch].shadow : dev->channel[ch].active;
        c.source = p[1]; c.shape = p[2]; c.gain = rd16(p + 3);
        c.offset = (int16_t)rd16(p + 5);
        c.step = rd64(p + 7); c.phase = rd64(p + 15);
        c.divider = rd32(p + 23); c.idle_code = rd16(p + 27);
        if (c.gain > 32768 || c.offset < -8192 || c.offset > 8191 ||
            c.step >> 48 || c.phase >> 48 || !c.divider || c.idle_code > 16383)
            return E_VALUE;
        dev->channel[ch].shadow = c;
        dev->channel[ch].shadow_valid = 1;
        return 0;
    }
    if (op == OP_APPLY && n == 1) {
        mask = p[0];
        if (!mask || mask > 3) return E_VALUE;
        if (finite_running(dev, mask)) return E_STATE;
        AwgHwConfig replacement[2];
        uint8_t source_change = 0;
        for (unsigned ch = 0; ch < 2; ++ch) if (mask & (1u << ch)) {
            AwgChannel *channel = &dev->channel[ch];
            if (!channel->shadow_valid) return E_STATE;
            replacement[ch] = channel->shadow;
            if (replacement[ch].source) {
                if (!channel->active_valid) return E_STATE;
                replacement[ch].source = channel->active_length <= AWG_BRAM_POINTS ? 1 : 2;
                replacement[ch].length = channel->active_length;
                replacement[ch].bank = channel->active_bank;
            } else replacement[ch].length = 1;
            if (replacement[ch].source != channel->active.source ||
                replacement[ch].shape != channel->active.shape)
                source_change |= (1u << ch);
        }
        uint8_t restart = (uint8_t)((awg_hw_status() >> 1) & 3u) & source_change;
        if (source_change && fade_stop(dev, source_change)) return E_HARDWARE;
        if (configure_active(mask, replacement)) return E_HARDWARE;
        for (unsigned ch = 0; ch < 2; ++ch) if (mask & (1u << ch)) {
            dev->channel[ch].active = replacement[ch];
            dev->channel[ch].shadow_valid = 0;
        }
        if (restart) {
            uint8_t payload[4] = {restart, 0, 0, 0};
            uint32_t ignored = 0;
            if (process_op(dev, session, OP_ARM, payload, 4, out, &ignored) ||
                process_op(dev, session, OP_START, &restart, 1, out, &ignored))
                return E_HARDWARE;
        }
        return 0;
    }
    if (op == OP_BEGIN && n == 9) {
        unsigned ch = p[0] - 1u;
        uint32_t length = rd32(p + 1), digest = rd32(p + 5);
        if (p[0] < 1 || p[0] > 2 || length < 1 || length > AWG_MAX_POINTS)
            return E_VALUE;
        AwgUpload *u = &dev->upload;
        if (u->active && u->channel == ch && u->length == length &&
            u->crc == digest && !u->complete) {
            wr32(out, u->token); wr32(out + 4, u->offset);
            *out_len = 8; return 0;
        }
        u->token = dev->next_token++;
        u->channel = (uint8_t)ch;
        u->bank = dev->channel[ch].active_bank ^ 1u;
        u->length = length; u->crc = digest; u->offset = 0;
        u->active = 1; u->complete = 0;
        dev->channel[ch].ready_valid = 0;
        wr32(out, u->token); wr32(out + 4, 0); *out_len = 8;
        return 0;
    }
    if (op == OP_DATA && n >= 10 && ((n - 8u) & 1u) == 0) {
        AwgUpload *u = &dev->upload;
        uint32_t token = rd32(p), offset = rd32(p + 4);
        uint32_t points = (n - 8u) / 2u;
        if (!u->active || u->complete || token != u->token || !points ||
            offset > u->length || points > u->length - offset) return E_UPLOAD;
        uint16_t *target = awg_hw_buffer(u->channel, u->bank);
        if (offset == u->offset) {
            for (uint32_t i = 0; i < points; ++i) {
                uint16_t code = rd16(p + 8u + 2u * i);
                if (code > 16383) return E_VALUE;
            }
            for (uint32_t i = 0; i < points; ++i)
                target[offset + i] = rd16(p + 8u + 2u * i);
            u->offset += points;
        } else if (offset < u->offset) {
            for (uint32_t i = 0; i < points; ++i)
                if (target[offset + i] != rd16(p + 8u + 2u * i)) return E_UPLOAD;
        } else return E_UPLOAD;
        wr32(out, u->offset); *out_len = 4; return 0;
    }
    if (op == OP_QUERY && n == 4) {
        if (!dev->upload.active || rd32(p) != dev->upload.token) return E_UPLOAD;
        wr32(out, dev->upload.offset); *out_len = 4; return 0;
    }
    if (op == OP_END && n == 4) {
        AwgUpload *u = &dev->upload;
        if (!u->active || rd32(p) != u->token || u->offset != u->length)
            return E_UPLOAD;
        uint16_t *buffer = awg_hw_buffer(u->channel, u->bank);
        if (crc32_bytes((const uint8_t *)buffer, 2u * u->length) != u->crc) {
            /* A complete but corrupt standby upload must be restartable with
             * the same metadata.  The committed active bank is untouched. */
            u->active = 0;
            u->complete = 0;
            u->offset = 0;
            return E_CRC;
        }
        u->complete = 1;
        AwgChannel *c = &dev->channel[u->channel];
        c->ready_length = u->length;
        c->ready_bank = u->bank;
        c->ready_valid = 1;
        return 0;
    }
    if (op == OP_COMMIT && n == 1) {
        mask = p[0];
        if (!mask || mask > 3) return E_VALUE;
        if (finite_running(dev, mask)) return E_STATE;
        for (unsigned ch = 0; ch < 2; ++ch)
            if ((mask & (1u << ch)) && !dev->channel[ch].ready_valid)
                return E_STATE;
        uint8_t restart = (uint8_t)((awg_hw_status() >> 1) & 3u) & mask;
        if (fade_stop(dev, mask)) return E_HARDWARE;
        AwgHwConfig replacement[2];
        for (unsigned ch = 0; ch < 2; ++ch) if (mask & (1u << ch)) {
            AwgChannel *c = &dev->channel[ch];
            if (c->ready_length <= AWG_BRAM_POINTS) {
                const uint16_t *buffer = awg_hw_buffer(ch, c->ready_bank);
                for (uint32_t i = 0; i < c->ready_length; ++i)
                    if (awg_hw_bram_write(ch, c->ready_bank, i, buffer[i]))
                        return E_HARDWARE;
            }
            replacement[ch] = c->shadow_valid ? c->shadow : c->active;
            replacement[ch].source = c->ready_length <= AWG_BRAM_POINTS ? 1 : 2;
            replacement[ch].length = c->ready_length;
            replacement[ch].bank = c->ready_bank;
        }
        if (configure_active(mask, replacement)) return E_HARDWARE;
        for (unsigned ch = 0; ch < 2; ++ch) if (mask & (1u << ch)) {
            AwgChannel *c = &dev->channel[ch];
            c->active = replacement[ch];
            c->active_length = c->ready_length;
            c->active_bank = c->ready_bank;
            c->active_valid = 1;
            c->ready_valid = 0;
            c->shadow_valid = 0;
        }
        if (restart) {
            /* Continuous playback resumes only after every DMA FIFO is ready. */
            uint8_t payload[4] = {restart, 0, 0, 0};
            uint32_t ignored = 0;
            if (process_op(dev, session, OP_ARM, payload, 4, out, &ignored) ||
                process_op(dev, session, OP_START, &restart, 1, out, &ignored))
                return E_HARDWARE;
        }
        return 0;
    }
    if (op == OP_ARM && n == 4) {
        mask = p[0]; uint16_t cycles = rd16(p + 1);
        uint32_t status = awg_hw_status();
        if (!mask || mask > 3 || p[3] > 1 ||
            ((status >> 1) & mask) || dev->fault || !(status & (1u << 11)))
            return E_STATE;
        for (unsigned ch = 0; ch < 2; ++ch) if (mask & (1u << ch)) {
            AwgHwConfig cfg = dev->channel[ch].active;
            cfg.cycles = cycles;
            if (cfg.source && !dev->channel[ch].active_valid) return E_STATE;
            if (cfg.source == 2) {
                awg_hw_stop_dma(ch);
                if (awg_hw_command(0x84, 0, 1u << ch)) return E_HARDWARE;
                usleep(20);
                if (awg_hw_start_dma(ch, cfg.bank, cfg.length)) return E_HARDWARE;
            }
            if (awg_hw_configure(ch, &cfg)) return E_HARDWARE;
            dev->channel[ch].active.cycles = cycles;
        }
        if (awg_hw_command(0x70, 0, mask)) return E_HARDWARE;
        for (volatile unsigned spin = 0; spin < 2000000u; ++spin) {
            uint32_t status = awg_hw_status();
            uint8_t ready = (uint8_t)((status >> 5) & 3u);
            uint8_t needed = 0;
            for (unsigned ch = 0; ch < 2; ++ch)
                if ((mask & (1u << ch)) && dev->channel[ch].active.source == 2)
                    needed |= (1u << ch);
            if ((ready & needed) == needed) break;
            if (spin == 1999999u) return E_HARDWARE;
        }
        if (awg_hw_command(0x81, 0, mask | (p[3] ? 4u : 0u))) return E_HARDWARE;
        dev->armed_external = p[3];
        return 0;
    }
    if (op == OP_START && n == 1 && p[0] > 0 && p[0] < 4) {
        if (dev->fault || dev->armed_external ||
            (((awg_hw_status() >> 7) & p[0]) != p[0]))
            return E_STATE;
        if (awg_hw_command(0x82, 0, p[0])) return E_HARDWARE;
        dev->armed_external = 0;
        return 0;
    }
    return E_UNKNOWN;
}

size_t awg_device_process(AwgDevice *dev, uintptr_t session,
                          const uint8_t *request, size_t length,
                          uint8_t *response, size_t response_capacity)
{
    if (!dev || !request || !response || length < 20 || length > AWG_FRAME_MAX ||
        response_capacity < AWG_FRAME_MAX || memcmp(request, "AWG2", 4)) return 0;
    uint8_t op = request[4];
    uint32_t id = rd32(request + 8), size = rd32(request + 12);
    if (size > 32768u || length != 20u + size) return 0;
    uint32_t crc = ~crc_step(crc_step(~0u, request, 16), request + 20, size);
    if (crc != rd32(request + 16) || rd16(request + 6) != 0) return 0;
    uint32_t hash = crc32_bytes(request, length);
    if (dev->cache_valid && session == dev->previous_session &&
        id == dev->previous_id) {
        if (hash != dev->previous_hash || op != dev->previous_op) return 0;
        memcpy(response, dev->previous_response, dev->previous_response_len);
        return dev->previous_response_len;
    }
    uint32_t out_len = 0;
    uint16_t status = process_op(dev, session, op, request + 20, size,
                                 response + 20, &out_len);
    memcpy(response, "AWG2", 4);
    response[4] = op | 0x80u; response[5] = 0;
    wr16(response + 6, status);
    wr32(response + 8, id); wr32(response + 12, out_len);
    uint32_t answer_crc = ~crc_step(crc_step(~0u, response, 16),
                                     response + 20, out_len);
    wr32(response + 16, answer_crc);
    dev->previous_session = session;
    dev->previous_id = id; dev->previous_hash = hash;
    dev->previous_op = op; dev->cache_valid = 1;
    dev->previous_response_len = 20u + out_len;
    memcpy(dev->previous_response, response, dev->previous_response_len);
    return dev->previous_response_len;
}
