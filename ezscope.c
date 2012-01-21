/*
    ezscope.c

	giftware, as is, no warranty, restricted to hobby use
	you cannot use this software for commercial gains w/o my permission

	if u are building software releasing it based on this,
	u should retain this message in your source and cite it's origin
	otherwise just take whatever code snipplets you need

	credits
	i had used information and/or code snipplets from these sources

	simpleavr@gmail.com
	www.simpleavr.com

	Dec 2010 c chung

          MSP430F2012
  
         +--------------+
         |              |
         | P1.6    P1.5 |          
         | P1.7    P1.4 |         === 
         | IO      P1.3 |---------===--- Gnd
         | Clk     P1.2 |--< RXD ---
         | P2.7    P1.1 |--- TXD -->
         | P2.6    P1.0 |-----|>---+
         | Gnd      Vcc |          |
         |              |         Gnd
         +--------------+
*/


//#define F_CPU 8000000UL
#define F_CPU 16000000UL
#include <io.h>
#include <signal.h>
#include "msp430x20x2.h"

#include <stdint.h>
#include <stdlib.h>

#define TXD BIT1 // TXD on P1.1
#define RXD BIT2 // RXD on P1.2

#define BAUDRATE 9600

#define BIT_TIME        (F_CPU / BAUDRATE)
#define HALF_BIT_TIME   (BIT_TIME / 2)

#define USEC			(F_CPU/1000000)

typedef unsigned char	uint8_t;
typedef unsigned int	uint16_t;
//______________________________________________________________________
static void __inline__ brief_pause(register uint16_t n) {
    __asm__ __volatile__ (
                "1: \n"
                " dec      %[n] \n"
                " jne      1b \n"
        : [n] "+r"(n));

} 

static volatile uint8_t  bitCount;			// Bit count, used when transmitting byte
static volatile uint16_t tx_byte;			// Value sent over UART when uart_putc() is called
static volatile uint16_t rx_byte;			// Value recieved once hasRecieved is set

static volatile uint8_t isReceiving = 0;	// Status for when the device is receiving
static volatile uint8_t hasReceived = 0;	// Lets the program know when a byte is received

#define uart_in()	(hasReceived)
//______________________________________________________________________
void uart_init(void) {
    P1SEL |= TXD;
    P1DIR |= TXD;
    P1IES |= RXD;	// RXD Hi/lo edge interrupt
    P1IFG &= ~RXD;	// Clear RXD (flag) before enabling interrupt
    P1IE  |= RXD;	// Enable RXD interrupt
}

//______________________________________________________________________
uint8_t uart_getc() {
	hasReceived = 0;
	return rx_byte;
}

//______________________________________________________________________
void uart_putc(uint8_t c) {
    tx_byte = c;

    while (isReceiving);			// Wait for RX completion

    CCTL0 = OUT;					// TXD Idle as Mark
    TACTL = TASSEL_2 + MC_2;		// SMCLK, continuous mode

    bitCount = 10;					// Load Bit counter, 8 bits + ST/SP

    CCR0 = TAR;						// Initialize compare register
    CCR0 += BIT_TIME;				// Set time till first bit

    tx_byte |= 0x100;				// Add stop bit to tx_byte (which is logical 1)
    tx_byte = tx_byte << 1;			// Add start bit (which is logical 0)
    CCTL0 = CCIS0 + OUTMOD0 + CCIE;	// set signal, intial value, enable interrupts

    while (CCTL0 & CCIE);			// Wait for completion
}
//______________________________________________________________________
#ifdef MSP430
interrupt(PORT1_VECTOR) PORT1_ISR(void) {
#else
#pragma vector=PORT1_VECTOR
__interrupt void Port1_Vector(void)
#endif
    isReceiving = 1;

    P1IE &= ~RXD;	// Disable RXD interrupt
    P1IFG &= ~RXD;	// Clear RXD IFG (interrupt flag)

    TACTL = TASSEL_2 + MC_2;	// SMCLK, continuous mode
    CCR0 = TAR;					// Initialize compare register
    //CCR0 += HALF_BIT_TIME;	// Set time till first bit, not working for me
    CCR0 += BIT_TIME;			// this works better for me
    CCTL0 = OUTMOD1 + CCIE;		// Disable TX and enable interrupts

    rx_byte = 0;				// Initialize rx_byte
    bitCount = 9;				// Load Bit counter, 8 bits + start bit
}

//______________________________________________________________________
#ifdef MSP430
interrupt(TIMERA0_VECTOR) TIMERA0_ISR(void) {
#else
#pragma vector=TIMERA0_VECTOR
__interrupt void Timer_A(void)
#endif
	CCR0 += BIT_TIME;
    if (!isReceiving) {
        if (bitCount == 0) {
            //TACTL = TASSEL_2;	// SMCLK, timer off (for power consumption)
            CCTL0 &= ~CCIE ;	// Disable interrupt
        }//if
        else {
			if (bitCount < 6) CCR0 -= 12;
            CCTL0 |= OUTMOD2;	// Set TX bit to 0
            if (tx_byte & 0x01)
                CCTL0 &= ~OUTMOD2;
            tx_byte = tx_byte >> 1;
            bitCount--;
        }//else
    }//if
    else {
        if (bitCount == 0) {
            TACTL = TASSEL_2;	// SMCLK, timer off (for power consumption)
            CCTL0 &= ~CCIE ;	// Disable interrupt

            isReceiving = 0;

            P1IFG &= ~RXD;		// clear RXD IFG (interrupt flag)
            P1IE |= RXD;		// enabled RXD interrupt

            if ((rx_byte & 0x201) == 0x200) {
				// the start and stop bits are correct
                rx_byte >>= 1; 		// Remove start bit
                rx_byte &= 0xff;	// Remove stop bit
                hasReceived = 1;
            }//if
        }//if
        else {
            if ((P1IN & RXD) == RXD)	// If bit is set?
                rx_byte |= 0x400;		// Set the value in the rx_byte
            rx_byte = rx_byte >> 1;		// Shift the bits down
            bitCount--;
        }//else
    }//else
}

//______________________________________________________________________
#ifdef MSP430
interrupt(ADC10_VECTOR) ADC10_ISR(void) {
#else
#pragma vector=ADC10_VECTOR
__interrupt void Adc10_Vector(void)
#endif
	__bic_SR_register_on_exit(CPUOFF);	// Clear CPUOFF bit from 0(SR)
}

#define S_SEND		(1<<0)
#define S_PWM 		(1<<1)

//______________________________________________________________________
void sample() {

	uint8_t logic=0, pin;

	/*
	for (pin=4;pin<8;pin++) {
		ADC10CTL1  = (pin<<12) + ADC10DIV_3;
		ADC10AE0  |= (1<<pin);				// probe pin in adc
		ADC10CTL0 |= ENC + ADC10SC;         // enable, start adc conversion
		__bis_SR_register(CPUOFF | GIE);    // enter lpm0 sleep for adc read
		ADC10AE0 &= ~pin;					// adc done, turn off probe pin as adc
		uint8_t adc = ADC10MEM>>2;			// we only need 8 bit
		if ((adc) < 0x30 || (adc) >= 0xd0)	// that's what we consider non-floating
			logic |= (1<<pin);
	}//for
	*/

	uint16_t samples[48];
	uint8_t i;
	for (i=0;i<48;i++) samples[i] = 0;

	P1DIR &= ~0xf0;
	P1OUT &= ~0xf0;
	P1REN &= ~0xf0;

	uint16_t tar = TAR;
	TACTL = TASSEL_2|MC__UP|TACLR;
	for (i=0;i<(12*16);i++) {
		samples[i/4] <<= 4;
		samples[i/4] |= P1IN>>4;
	}//for
	tar = TAR - tar;
	uart_putc(tar&0xff);
	uart_putc(tar>>8);

	for (i=0;i<48;i++) {
		uart_putc(samples[i]>>8);
		uart_putc(samples[i]&0xff);
	}//for
	uart_putc(0x34);
	uart_putc(0x12);

}

volatile uint8_t ticks=0, tacs=0;
//______________________________________________________________________
int main (void) {

    //WDTCTL = WDTPW + WDTHOLD; 
    WDTCTL = WDT_MDLY_8;			// wdt timer mode at 8ms (3ms w/ vlo)
	//BCSCTL1 = 0x8d;			// around 8Mhz
    //DCOCTL  = (3<<5)|22;
	BCSCTL1 = CALBC1_16MHZ;
    DCOCTL  = CALDCO_16MHZ;

	//________________ we need wdt to control led brightness
	BCSCTL3 |= LFXT1S_2;            // use vlo as aclK, ~12Khz
	IE1 |= WDTIE;					// enable wdt interrupt

	P1SEL = P2SEL = 0x00;
	P1DIR = BIT0;
	P1REN = BIT3;
	P1OUT = BIT3;
	P2DIR = BIT6;
	P2OUT = BIT6;

	uart_init();
	_BIS_SR(GIE);

	P1OUT ^= BIT0; while (!tacs); P1OUT ^= BIT0;

	ADC10CTL0 = ADC10SHT_2 + ADC10ON + ADC10IE; // adc setup

	uint8_t test_ccr0 = 0;
	uint8_t state = 0;

	while (1) {
		if (!(state&S_PWM) && uart_in()) {
			uint8_t cmd = uart_getc();
			uint8_t parm = cmd & 0x0f;
			cmd >>= 4;
			switch (cmd) {
				// we can add commands here in the future
				case 0:	// turn on/off data streaming
					state ^= S_SEND;
					break;
				/*
				case 2:	// steps to skip, 16 is typical
					skip = 1<<parm;
					break;
				case 3:	// open
				*/
				default: break;
			}//switch
			//_________ acknowledge command by blinking
			P1OUT |= BIT0; 
			ticks = 0;
			while (ticks<200); 
			P1OUT &= ~BIT0;
		}//if
		//_____________ check button
		if (!(P1IN & BIT3)) {		// key pressed wait for release
			ticks = tacs = 0;
			while (!(P1IN & BIT3));
			if (ticks > 10) {
				if (tacs>1) {
					state ^= S_PWM;
					if (state & S_PWM) {
						P1OUT |= BIT0;
						P1DIR |= (BIT6|BIT7);
						P1SEL |= BIT6;
						state &= ~S_SEND;		// not sampling to pc
						test_ccr0 = 0;
					}//if
					else {
						P1OUT &= ~BIT0;
						TACTL = 0;
						P1DIR &= ~(BIT6|BIT7);
						P1SEL &= ~BIT6;
					}//else
				}//if
				else {
					test_ccr0++;
					test_ccr0 &= 0x07;
				}//else
				if (state & S_PWM) {		// adjust pwm output
					uint16_t use_ccr = 32000;		// 500Hz
					uint8_t idx = test_ccr0;
					switch (idx) {
						case 1: use_ccr = 16000; break;	// 1KHz
						case 2: use_ccr = 3200; break;	// 5Khz
						case 3: use_ccr = 1600; break;	// 10Khz
						case 4: use_ccr = 320; break;	// 50Khz
						case 5: use_ccr = 160; break;	// 10Khz
						case 6: use_ccr = 32; break;	// 500Khz
						case 7: use_ccr = 16; break;	// 1Mhz
						default: break;
					}//switch
					//use_ccr -= (use_ccr/10);
					TACTL = 0;
					CCR0 = use_ccr;
					CCR1 = use_ccr>>2;		// 25% duty cycle
					TACTL = TASSEL_2 + MC__UP;
					CCTL1 = OUT|OUTMOD_7;
				}//if
			}//if
		}//if

		if ((state&S_PWM) && !(tacs&0x07)) {	// bursts
			switch (ticks>>4) {
				case 0x06: P1OUT |= BIT7; break;
				default:
				case 0x07: P1OUT &=~BIT7; break;
			}//switch
		}//if

		if (state & S_SEND) {
			//______________ turn off wdt when we take samples
			//WDTCTL = WDTPW + WDTHOLD; 
			sample();
			//WDTCTL = WDT_MDLY_8;
			ticks = tacs = 0;
			while (!tacs);
		}//if
	}//while
}

//______________________________________________________________________
#ifdef MSP430
interrupt(WDT_VECTOR) WDT_ISR(void) {
#else
#pragma vector=WDT_VECTOR
__interrupt void Wdt_Vector(void) {
#endif
	//___________ wdt interrupts at about 3ms (vlo clock)
	//            it's used to control led brightness as we don't have resistor
	//            for most leds
	ticks++;
	if (!ticks) tacs++;
}

