/*
 * Stage 3 : camera frame capture over AXI4-Lite -> UART dump (128 x 128 RGB)
 *
 *  capture IP (PL) @ 0x43C0_0000
 *    0x00000 CTRL  W: bit0 = start   R: bit0 = done, bit1 = busy, [31:16] = count
 *    0x00004 ID    R: 0xCA910002
 *    0x00008 INFO  R: {width, height} = {128, 128}
 *    0x10000 + 4*i R: pixel i (128x128, row-major) = 0x00RRGGBB
 *
 *  UART1 runs at 921600 bps (8N1), switched at start-up
 *    commands from the PC:
 *      'c' : capture one frame and send it (binary)
 *      'i' : print IP status (text)
 *
 *  Binary frame format:
 *    "FRAME <count> <w> <h>\r\n"
 *    w*h*3 bytes : R,G,B per pixel, row-major
 *    "END\r\n"
 */
#include "xparameters.h"
#include "xil_io.h"
#include "xuartps_hw.h"

#define UART_BASE       XPAR_PS7_UART_1_BASEADDR
#define CAP_BASE        0x43C00000u
#define CAP_CTRL        (CAP_BASE + 0x00000u)
#define CAP_ID          (CAP_BASE + 0x00004u)
#define CAP_INFO        (CAP_BASE + 0x00008u)
#define CAP_PIXEL(i)    (CAP_BASE + 0x10000u + 4u * (u32)(i))

#define IMG_W   128
#define IMG_H   128

/* UART reference clock 100 MHz:  baud = 100e6 / (CD * (BDIV + 1))
 * CD = 18, BDIV = 5  ->  925,926 bps  (921,600 + 0.5 %)                     */
#define UART_CD     18u
#define UART_BDIV   5u

static void uart_init_fast(void)
{
    /* disable, set baud rate, reset FIFOs, 8N1, enable */
    XUartPs_WriteReg(UART_BASE, XUARTPS_CR_OFFSET, XUARTPS_CR_TX_DIS | XUARTPS_CR_RX_DIS);
    XUartPs_WriteReg(UART_BASE, XUARTPS_BAUDGEN_OFFSET, UART_CD);
    XUartPs_WriteReg(UART_BASE, XUARTPS_BAUDDIV_OFFSET, UART_BDIV);
    XUartPs_WriteReg(UART_BASE, XUARTPS_MR_OFFSET,
                     XUARTPS_MR_CHMODE_NORM | XUARTPS_MR_STOPMODE_1_BIT |
                     XUARTPS_MR_PARITY_NONE | XUARTPS_MR_CHARLEN_8_BIT);
    XUartPs_WriteReg(UART_BASE, XUARTPS_CR_OFFSET, XUARTPS_CR_TXRST | XUARTPS_CR_RXRST);
    XUartPs_WriteReg(UART_BASE, XUARTPS_CR_OFFSET, XUARTPS_CR_TX_EN | XUARTPS_CR_RX_EN);
}

static void put_c(char c)            { XUartPs_SendByte(UART_BASE, (u8)c); }
static void put_s(const char *s)     { while (*s) put_c(*s++); }

static void put_hex(u32 v, int digits)
{
    static const char hx[] = "0123456789ABCDEF";
    int i;
    for (i = digits - 1; i >= 0; i--) put_c(hx[(v >> (4 * i)) & 0xF]);
}

static void put_dec(u32 v)
{
    char buf[11];
    int n = 0;
    if (v == 0) { put_c('0'); return; }
    while (v && n < 10) { buf[n++] = (char)('0' + v % 10); v /= 10; }
    while (n) put_c(buf[--n]);
}

static void print_status(void)
{
    u32 ctrl = Xil_In32(CAP_CTRL);
    u32 info = Xil_In32(CAP_INFO);
    put_s("ID=");     put_hex(Xil_In32(CAP_ID), 8);
    put_s(" SIZE=");  put_dec(info >> 16); put_c('x'); put_dec(info & 0xFFFF);
    put_s(" done=");  put_c((ctrl & 1) ? '1' : '0');
    put_s(" busy=");  put_c((ctrl & 2) ? '1' : '0');
    put_s(" count="); put_dec(ctrl >> 16);
    put_s("\r\n");
}

/* returns 0 on success, -1 on timeout */
static int capture_frame(void)
{
    volatile u32 t = 0;
    Xil_Out32(CAP_CTRL, 1u);                    /* request: next full frame */
    while ((Xil_In32(CAP_CTRL) & 1u) == 0u) {   /* wait for done */
        if (++t > 200000000u) return -1;        /* a few seconds */
    }
    return 0;
}

static void send_frame(void)
{
    u32 i, p;
    u32 ctrl = Xil_In32(CAP_CTRL);
    put_s("FRAME "); put_dec(ctrl >> 16);
    put_c(' ');      put_dec(IMG_W);
    put_c(' ');      put_dec(IMG_H);
    put_s("\r\n");
    for (i = 0; i < (u32)(IMG_W * IMG_H); i++) {
        p = Xil_In32(CAP_PIXEL(i));
        put_c((char)((p >> 16) & 0xFF));   /* R */
        put_c((char)((p >> 8)  & 0xFF));   /* G */
        put_c((char)( p        & 0xFF));   /* B */
    }
    put_s("END\r\n");
}

int main(void)
{
    uart_init_fast();
    put_s("\r\nSTAGE3 CAPTURE READY 128x128 @921600  ('c' = capture, 'i' = status)\r\n");
    print_status();

    while (1) {
        char c = (char)XUartPs_RecvByte(UART_BASE);   /* blocks until a key */
        if (c == 'c' || c == 'C') {
            if (capture_frame() == 0) send_frame();
            else { put_s("ERR timeout (camera not streaming?)\r\n"); print_status(); }
        } else if (c == 'i' || c == 'I') {
            print_status();
        }
    }
    return 0;
}
