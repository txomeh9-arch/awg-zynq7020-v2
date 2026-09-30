#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "awg_device.h"
#include "platform.h"
#include "platform_config.h"
#include "xil_printf.h"
#include "xuartps_hw.h"
#include "lwip/init.h"
#include "lwip/ip_addr.h"
#include "lwip/tcp.h"
#include "netif/xadapter.h"

#define UART0_BASE 0xE0000000u
#define TCP_PORT 5000u
#define PARTIAL_TIMEOUT_MS 1000u

extern volatile int TcpFastTmrFlag;
extern volatile int TcpSlowTmrFlag;
static AwgDevice device;
static struct netif netif_instance;
struct netif *echo_netif = &netif_instance; /* Xilinx platform timer expects this name. */
static struct tcp_pcb *client_pcb;
static uint8_t answer[AWG_FRAME_MAX];

typedef struct {
    uint8_t bytes[AWG_FRAME_MAX];
    uint32_t used, expected, last_ms;
    uintptr_t session;
} FrameStream;
static FrameStream tcp_stream, uart_stream;

static uint32_t le32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void uart_send(const uint8_t *bytes, size_t length)
{
    for (size_t i = 0; i < length; ++i)
        XUartPs_SendByte(UART0_BASE, bytes[i]);
}

static void consume_frame(FrameStream *stream, struct tcp_pcb *pcb)
{
    size_t length = awg_device_process(&device, stream->session,
                                       stream->bytes, stream->expected,
                                       answer, sizeof(answer));
    if (length) {
        if (pcb) {
            if (tcp_sndbuf(pcb) >= length &&
                tcp_write(pcb, answer, (u16_t)length, TCP_WRITE_FLAG_COPY) == ERR_OK)
                tcp_output(pcb);
        } else uart_send(answer, length);
    }
    stream->used = 0;
    stream->expected = 0;
}

static void feed_stream(FrameStream *stream, struct tcp_pcb *pcb,
                        const uint8_t *bytes, size_t length)
{
    uint32_t now = sys_now();
    if (stream->used && now - stream->last_ms > PARTIAL_TIMEOUT_MS) {
        stream->used = 0; stream->expected = 0;
    }
    stream->last_ms = now;
    for (size_t i = 0; i < length; ++i) {
        if (stream->used == 0 && bytes[i] != 'A') continue;
        stream->bytes[stream->used++] = bytes[i];
        if (stream->used <= 4 &&
            memcmp(stream->bytes, "AWG2", stream->used) != 0) {
            stream->used = 0; stream->expected = 0;
            continue;
        }
        if (stream->used == 20) {
            uint32_t payload = le32(stream->bytes + 12);
            if (payload > 32768u) {
                stream->used = 0; stream->expected = 0;
                continue;
            }
            stream->expected = 20u + payload;
        }
        if (stream->expected && stream->used == stream->expected)
            consume_frame(stream, pcb);
    }
}

static err_t tcp_receive(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t err)
{
    (void)arg;
    if (!p || err != ERR_OK) {
        if (p) pbuf_free(p);
        awg_device_release(&device, (uintptr_t)pcb);
        tcp_stream.used = 0; tcp_stream.expected = 0;
        client_pcb = NULL;
        tcp_recv(pcb, NULL);
        tcp_close(pcb);
        return ERR_OK;
    }
    for (struct pbuf *part = p; part; part = part->next)
        feed_stream(&tcp_stream, pcb, (const uint8_t *)part->payload, part->len);
    tcp_recved(pcb, p->tot_len);
    pbuf_free(p);
    return ERR_OK;
}

static void tcp_failed(void *arg, err_t err)
{
    (void)arg; (void)err;
    if (client_pcb) awg_device_release(&device, (uintptr_t)client_pcb);
    client_pcb = NULL;
    tcp_stream.used = 0; tcp_stream.expected = 0;
}

static err_t tcp_connected(void *arg, struct tcp_pcb *pcb, err_t err)
{
    (void)arg; (void)err;
    if (client_pcb) {
        tcp_abort(pcb);
        return ERR_ABRT;
    }
    client_pcb = pcb;
    memset(&tcp_stream, 0, sizeof(tcp_stream));
    tcp_stream.session = (uintptr_t)pcb;
    tcp_recv(pcb, tcp_receive);
    tcp_err(pcb, tcp_failed);
    return ERR_OK;
}

static int start_server(void)
{
    struct tcp_pcb *pcb = tcp_new_ip_type(IPADDR_TYPE_V4);
    if (!pcb) return -1;
    if (tcp_bind(pcb, IP_ANY_TYPE, TCP_PORT) != ERR_OK) {
        tcp_close(pcb); return -1;
    }
    pcb = tcp_listen(pcb);
    if (!pcb) return -1;
    tcp_accept(pcb, tcp_connected);
    return 0;
}

int main(void)
{
    ip_addr_t address, mask, gateway;
    unsigned char mac[] = {0x02, 0x50, 0x41, 0x57, 0x47, 0x02};
    init_platform();
    awg_device_init(&device);
    if (awg_hw_init() || awg_hw_memory_test()) {
        xil_printf("AWG V2: PL clock or reserved DDR self-test failed\r\n");
        for (;;) { }
    }
    uart_stream.session = 1;
    IP4_ADDR(&address, 192, 168, 10, 10);
    IP4_ADDR(&mask, 255, 255, 255, 0);
    IP4_ADDR(&gateway, 192, 168, 10, 1);
    lwip_init();
    if (!xemac_add(echo_netif, &address, &mask, &gateway, mac,
                   PLATFORM_EMAC_BASEADDR)) {
        xil_printf("AWG V2: GEM0/Realtek PHY initialization failed\r\n");
        for (;;) { }
    }
    netif_set_default(echo_netif);
    platform_enable_interrupts();
    netif_set_up(echo_netif);
    if (start_server()) {
        xil_printf("AWG V2: TCP port 5000 unavailable\r\n");
        for (;;) { }
    }
    xil_printf("AWG V2 ready: 192.168.10.10:5000 / UART0 115200\r\n");
    for (;;) {
        if (TcpFastTmrFlag) { tcp_fasttmr(); TcpFastTmrFlag = 0; }
        if (TcpSlowTmrFlag) { tcp_slowtmr(); TcpSlowTmrFlag = 0; }
        xemacif_input(echo_netif);
        while (XUartPs_IsReceiveData(UART0_BASE)) {
            uint8_t byte = (uint8_t)XUartPs_ReadReg(UART0_BASE, XUARTPS_FIFO_OFFSET);
            feed_stream(&uart_stream, NULL, &byte, 1);
        }
        awg_device_poll(&device);
    }
}
