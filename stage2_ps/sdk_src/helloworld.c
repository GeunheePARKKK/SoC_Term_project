/*
 * Stage 2 check: Hello World over PS UART1 (MIO 48/49), runs forever.
 * UART TX/RX is enabled explicitly (same as the 9/28 lab main.c) because
 * nothing else configures it when the program is loaded over JTAG.
 */
#include "xparameters.h"
#include "xuartps_hw.h"
#include "xil_printf.h"
#include "platform.h"

static void delay(volatile unsigned int n) { while (n--) ; }

int main()
{
    u32 cr;
    unsigned int count = 0;

    init_platform();

    /* enable UART1 TX and RX */
    cr = XUartPs_ReadReg(XPAR_PS7_UART_1_BASEADDR, XUARTPS_CR_OFFSET);
    XUartPs_WriteReg(XPAR_PS7_UART_1_BASEADDR, XUARTPS_CR_OFFSET,
                     ((cr & ~XUARTPS_CR_EN_DIS_MASK) | XUARTPS_CR_TX_EN | XUARTPS_CR_RX_EN));

    while (1) {
        xil_printf("Hello World %d\r\n", count++);
        delay(50000000);    /* roughly 0.5 ~ 1 s at 667 MHz */
    }

    return 0;
}
