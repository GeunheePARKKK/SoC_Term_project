/*
 * Stage 5-A : AI scanner - object detection + TFT bounding box (+ capture kept for the CNN)
 *
 *  capture IP @ 0x43C0_0000  (see stage3)  : 128x128 RGB frame for the CNN / dataset
 *  objdet  IP @ 0x43C2_0000                : background subtraction + bounding box
 *    0x00 CTRL   bit0 learn (W1), bit1 overlay enable, bit2 auto (draw only when present)
 *    0x04 STATUS bit0 present, bit1 bg valid, bit2 learning, [31:16] frames
 *    0x08 THRESH 0x0C MINBLK 0x10 BOX_X {x1,x0} 0x14 BOX_Y {y1,y0} 0x18 COUNT 0x1C COLOR 0x20 ID
 *
 *  UART1 460800 bps. Commands:
 *    b : learn background (keep the tray EMPTY)      s : status
 *    + / - : threshold up / down                     ] / [ : min blocks up / down
 *    g / r / y : box color green / red / yellow       o : toggle auto / always
 *    c : capture a 128x128 frame (binary, for tools/capture_to_png.py)
 *    i : capture IP status
 *  The board prints "OBJECT ..." / "EMPTY" whenever the detection state changes.
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
#define IMG_W           128
#define IMG_H           128

#define OD_BASE         0x43C20000u
#define OD_CTRL         (OD_BASE + 0x00u)
#define OD_STATUS       (OD_BASE + 0x04u)
#define OD_THRESH       (OD_BASE + 0x08u)
#define OD_MINBLK       (OD_BASE + 0x0Cu)
#define OD_BOX_X        (OD_BASE + 0x10u)
#define OD_BOX_Y        (OD_BASE + 0x14u)
#define OD_COUNT        (OD_BASE + 0x18u)
#define OD_COLOR        (OD_BASE + 0x1Cu)
#define OD_ID           (OD_BASE + 0x20u)

#define OD_CTRL_LEARN   0x1u
#define OD_CTRL_ENABLE  0x2u
#define OD_CTRL_AUTO    0x4u

/* TFT RGB565 used by the overlay: R = [4:0], G = [10:5], B = [15:11] */
#define TFT_GREEN       0x07E0u
#define TFT_RED         0x001Fu
#define TFT_YELLOW      0x07FFu

#define UART_CD         31u     /* 100 MHz / (31 * 7) = 460,829 bps */
#define UART_BDIV       6u

/*------------------------------------------------------------------ UART */
static void uart_init_fast(void)
{
    XUartPs_WriteReg(UART_BASE, XUARTPS_CR_OFFSET, XUARTPS_CR_TX_DIS | XUARTPS_CR_RX_DIS);
    XUartPs_WriteReg(UART_BASE, XUARTPS_BAUDGEN_OFFSET, UART_CD);
    XUartPs_WriteReg(UART_BASE, XUARTPS_BAUDDIV_OFFSET, UART_BDIV);
    XUartPs_WriteReg(UART_BASE, XUARTPS_MR_OFFSET,
                     XUARTPS_MR_CHMODE_NORM | XUARTPS_MR_STOPMODE_1_BIT |
                     XUARTPS_MR_PARITY_NONE | XUARTPS_MR_CHARLEN_8_BIT);
    XUartPs_WriteReg(UART_BASE, XUARTPS_CR_OFFSET, XUARTPS_CR_TXRST | XUARTPS_CR_RXRST);
    XUartPs_WriteReg(UART_BASE, XUARTPS_CR_OFFSET, XUARTPS_CR_TX_EN | XUARTPS_CR_RX_EN);
}
static void put_c(char c)        { XUartPs_SendByte(UART_BASE, (u8)c); }
static void put_s(const char *s) { while (*s) put_c(*s++); }
static void put_hex(u32 v, int d) { static const char h[] = "0123456789ABCDEF"; while (d--) put_c(h[(v >> (4 * d)) & 0xF]); }
static void put_dec(u32 v)
{
    char b[11]; int n = 0;
    if (v == 0) { put_c('0'); return; }
    while (v && n < 10) { b[n++] = (char)('0' + v % 10); v /= 10; }
    while (n) put_c(b[--n]);
}
static int uart_has_data(void) { return XUartPs_IsReceiveData(UART_BASE); }

static void delay_ms(u32 ms)
{
    volatile u32 i;
    while (ms--) for (i = 0; i < 100000u; i++) ;   /* roughly 1 ms at 667 MHz, no cache tuning */
}

/*------------------------------------------------------------------ capture (stage 3) */
static int capture_frame(void)
{
    volatile u32 t = 0;
    Xil_Out32(CAP_CTRL, 1u);
    while ((Xil_In32(CAP_CTRL) & 1u) == 0u) { if (++t > 200000000u) return -1; }
    return 0;
}
static void send_frame(void)
{
    u32 i, p;
    put_s("FRAME "); put_dec(Xil_In32(CAP_CTRL) >> 16);
    put_c(' '); put_dec(IMG_W); put_c(' '); put_dec(IMG_H); put_s("\r\n");
    for (i = 0; i < (u32)(IMG_W * IMG_H); i++) {
        p = Xil_In32(CAP_PIXEL(i));
        put_c((char)((p >> 16) & 0xFF)); put_c((char)((p >> 8) & 0xFF)); put_c((char)(p & 0xFF));
    }
    put_s("END\r\n");
}

/*------------------------------------------------------------------ objdet */
static u32 od_ctrl = OD_CTRL_ENABLE | OD_CTRL_AUTO;

static void od_print_status(void)
{
    u32 st = Xil_In32(OD_STATUS), bx = Xil_In32(OD_BOX_X), by = Xil_In32(OD_BOX_Y);
    put_s("[objdet] present="); put_c((st & 1) ? '1' : '0');
    put_s(" bg=");       put_c((st & 2) ? '1' : '0');
    put_s(" learning="); put_c((st & 4) ? '1' : '0');
    put_s(" blocks=");   put_dec(Xil_In32(OD_COUNT));
    put_s(" box x ");    put_dec(bx & 0xFFFF); put_s(".."); put_dec(bx >> 16);
    put_s(" y ");        put_dec(by & 0xFFFF); put_s(".."); put_dec(by >> 16);
    put_s(" thresh=");   put_dec(Xil_In32(OD_THRESH));
    put_s(" minblk=");   put_dec(Xil_In32(OD_MINBLK));
    put_s(" mode=");     put_s((od_ctrl & OD_CTRL_AUTO) ? "auto" : "always");
    put_s(" frames=");   put_dec(st >> 16);
    put_s("\r\n");
}

static void od_learn(void)
{
    u32 t = 0;
    put_s("[objdet] learning background - keep the tray empty...\r\n");
    Xil_Out32(OD_CTRL, od_ctrl | OD_CTRL_LEARN);
    delay_ms(50);
    while ((Xil_In32(OD_STATUS) & 4u) && t < 100) { delay_ms(20); t++; }   /* wait until learned */
    put_s("[objdet] background ready\r\n");
}

static void od_set(u32 reg, u32 v) { Xil_Out32(reg, v); }

/*------------------------------------------------------------------ main */
int main(void)
{
    u32 last_present = 0, last_frames = 0, tick = 0;

    uart_init_fast();
    put_s("\r\n=== STAGE5 SCANNER (A: object box)  UART 460800 ===\r\n");
    put_s("capture ID="); put_hex(Xil_In32(CAP_ID), 8);
    put_s("  objdet ID="); put_hex(Xil_In32(OD_ID), 8); put_s("\r\n");
    put_s("keys: b=learn bg  s=status  +/- thresh  ]/[ minblk  g/r/y color  o=auto/always  c=capture\r\n");

    od_set(OD_COLOR, TFT_GREEN);
    Xil_Out32(OD_CTRL, od_ctrl);
    delay_ms(500);                       /* camera settles */
    od_learn();
    od_print_status();

    while (1) {
        /*-------------------------------- commands */
        if (uart_has_data()) {
            char c = (char)XUartPs_RecvByte(UART_BASE);
            u32 v;
            switch (c) {
            case 'b': case 'B': od_learn(); od_print_status(); break;
            case 's': case 'S': od_print_status(); break;
            case '+': v = Xil_In32(OD_THRESH) + 10; od_set(OD_THRESH, v); od_print_status(); break;
            case '-': v = Xil_In32(OD_THRESH); v = (v > 10) ? v - 10 : 1; od_set(OD_THRESH, v); od_print_status(); break;
            case ']': v = Xil_In32(OD_MINBLK) + 1; od_set(OD_MINBLK, v); od_print_status(); break;
            case '[': v = Xil_In32(OD_MINBLK); v = (v > 1) ? v - 1 : 1; od_set(OD_MINBLK, v); od_print_status(); break;
            case 'g': od_set(OD_COLOR, TFT_GREEN);  put_s("[objdet] color green\r\n");  break;
            case 'r': od_set(OD_COLOR, TFT_RED);    put_s("[objdet] color red\r\n");    break;
            case 'y': od_set(OD_COLOR, TFT_YELLOW); put_s("[objdet] color yellow\r\n"); break;
            case 'o': od_ctrl ^= OD_CTRL_AUTO; Xil_Out32(OD_CTRL, od_ctrl); od_print_status(); break;
            case 'c': case 'C':
                if (capture_frame() == 0) send_frame(); else put_s("ERR timeout (camera not streaming?)\r\n");
                break;
            case 'i': case 'I':
                put_s("capture CTRL="); put_hex(Xil_In32(CAP_CTRL), 8); put_s("\r\n");
                break;
            default: break;
            }
        }

        /*-------------------------------- report detection changes */
        {
            u32 st = Xil_In32(OD_STATUS);
            u32 present = st & 1u, frames = st >> 16;
            if (frames != last_frames) {
                last_frames = frames;
                if (present != last_present) {
                    last_present = present;
                    if (present) { put_s("OBJECT  "); od_print_status(); }
                    else         { put_s("EMPTY\r\n"); }
                }
            }
        }
        if (++tick == 0) { /* keep loop alive */ }
    }
    return 0;
}
