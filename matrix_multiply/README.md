# Cyclone IV UART switch demo

Quartus project for the Cyclone IV V3.0 board with an **EP4CE6E22C8** FPGA
and a **50 MHz** oscillator. Open `uart_switch_demo.qpf`.

| DIP switch 1 | DIP switch 2 | Behavior |
| --- | --- | --- |
| OFF | OFF | LEDs off, UART TX idle, display blank |
| ON | OFF | LED1 on; continuously transmit ASCII `A` |
| OFF | ON | LED2 on; receive ASCII `0`–`9` and show the latest digit on DIG1 |
| ON | ON | LED1 and LED2 on; transmit `A` and receive/display digits simultaneously |

Switches and LEDs are **active low**: ON reads as `0`. The corresponding
pushbuttons share the DIP switch pins, so pressing KEY1/KEY2 also enables
the function. LED3/LED4 and DIG2–DIG4 stay off.

The display starts blank and stays blank until a valid digit arrives.
Other characters (including Enter/CR/LF), short start glitches and bytes
with an invalid stop bit are ignored. Turning switch 2 off clears the
display; turn it on and send a new digit. Turning switch 1 off lets the
current UART character finish before TX goes idle. Reset clears the display
and UART state. A short internal reset runs automatically after configuration;
the RESET button can also be used at any time.
The switch synchronizer registers initialize to OFF. All four LED outputs
are registered and initialize to `1111` (off); LED3/LED4 remain high throughout
operation. These startup assignments apply after the FPGA enters user mode.

## UART wiring

Configure the PC terminal for **9600 baud, 8 data bits, no parity, 1 stop bit,
no flow control**. Send ordinary ASCII characters, not numeric binary bytes.
At 50 MHz, each bit lasts 5208 clocks (approximately 104.16 microseconds).

For the external USB-to-TTL connection used in `FPGA-UART-TX`:

| FPGA board signal | USB-to-TTL adapter |
| --- | --- |
| UART TX, FPGA pin **114** | RXD |
| UART RX, FPGA pin **115** | TXD |
| GND | GND |

Use **3.3 V logic**. Power the board normally; do not connect the adapter's
VCC pin. Do not connect RS-232 voltage levels to the FPGA pins.

The supplied V2.1 schematic connects pin 115 directly to the onboard
MAX3232 receiver output; it shows no isolation jumper. For reception on
an unmodified board matching that schematic, use the DB9 connector with
a USB-to-RS-232 adapter. Connecting a TTL adapter's TXD to pin 115 requires
electrically isolating the MAX3232 receiver output first. Check your PCB
revision: two push-pull outputs must not drive pin 115 together. The original
TX-only wiring (pin 114 to the adapter's RXD, plus GND) does not have this conflict.

The alternative DB9 connection uses the onboard MAX3232 for level conversion;
it needs an RS-232 adapter and suitable TX/RX/GND cable wiring. Choose one
UART connection method.

## Pins

`uart_switch_demo.qsf` contains only the assignments used by this design,
selected from `cyclone_iv_board_v3.qsf`. The clock, switch, LED and TX pins
also agree with `../FPGA-UART-TX/UART_TX.qsf`.

| HDL port | FPGA pin(s) |
| --- | --- |
| `clk_50mhz` | 23 |
| `reset_n` | 25 |
| `key_n[0]`, `key_n[1]` (DIP1, DIP2) | 88, 89 |
| `led_n[0..3]` (LED1–LED4) | 87, 86, 85, 84 |
| `uart_tx`, `uart_rx` | 114, 115 |
| `digit_n[0..3]` (DIG1–DIG4) | 133, 135, 136, 137 |
| `seg_n[0..7]` (a, b, c, d, e, f, g, dp) | 128, 121, 125, 129, 132, 126, 124, 127 |

All I/O uses 3.3-V LVTTL; unused pins remain inputs in high impedance.
The seven-segment display is common anode with active-low segments and
digit enables. Only DIG1 is driven, so no multiplexing is necessary.
In the V2.1 schematic, LED anodes connect to 3.3 V, so the FPGA must drive
high to turn them off. The component marked LED1 connects through R30 to
the net named LED4 (pin 87); the net labels run in the opposite order to
the physical LEDs. This project follows the vendor pin table's physical
LED1 = pin 87 convention. KEY1/KEY2 have external pull-ups and close to
GND, so DIP OFF reads high and DIP ON reads low.

## Build and try it

1. Use Quartus Prime Lite with Cyclone IV device support installed.
2. Open `uart_switch_demo.qpf`. The top-level entity is `uart_switch_demo`.
3. Run **Processing > Start Compilation**.
4. Open **Tools > Programmer**, select the USB-Blaster, and select
   `output_files/uart_switch_demo.sof`. Enable **Program/Configure**, then **Start**.
5. Open the serial terminal with the settings above. Turn DIP1 ON: LED1
   lights and `AAAA...` appears. Turn DIP1 OFF to stop the stream.
6. Turn DIP2 ON: LED2 lights. Type `0` through `9`; DIG1 shows the last
   digit sent. No Enter key is required. Both switches may be ON together.

After changing any HDL or QSF file, compile again and explicitly reload
the newly generated `output_files/uart_switch_demo.sof` in Programmer.
Check its path and modification time, then confirm Program/Configure succeeds.
With all DIP positions OFF and no buttons pressed, the four user LEDs
must be off. The separate power/configuration indicators are not user LEDs.
Editing source files alone does not change the program running on the FPGA;
after a power cycle the configuration flash can reload an older program.

Command-line compilation, when Quartus is on PATH:

```sh
quartus_sh --flow compile uart_switch_demo
```

The `.sof` programs volatile FPGA SRAM. Power cycling requires programming
again; persistent EPCS flash programming is a separate step.

## Simulation

With Icarus Verilog (`iverilog` and `vvp`) installed, run from this directory:

```sh
iverilog -g2012 -Wall -s uart_switch_demo_tb -o /tmp/uart_switch_demo_tb.vvp \
  uart_switch_demo.v my_uart_rx.v my_uart_tx.v speed_select.v uart_switch_demo_tb.v
vvp /tmp/uart_switch_demo_tb.vvp
```

The self-checking testbench uses the real 50 MHz/9600-baud timing. It checks
LEDs off from the first simulation instant without a button press, LED3/LED4
off throughout the run, all four switch/LED combinations, digits
0–9 with back-to-back frames, concurrent transmit/receive, ignored non-digits,
invalid stop/start bits, switching off mid-frame, and reset during TX/RX.
It passes with Icarus Verilog 11.0; the synthesizable RTL also compiles in
Verilog-2005 mode without warnings.

`my_uart_rx.v`, `my_uart_tx.v` and `speed_select.v` are reused unchanged from
the local `Altera-Cyclone-IV-board-V3.0/Example code/Peripheral control 08
RS232 serial/uart` example. The top-level adapts that example to two independent
switches and LEDs. The SDC constrains the 50 MHz clock; asynchronous inputs
are synchronized and asynchronous outputs have no external capture clock.

Quartus compilation, timing closure and physical board behavior still need
verification on the actual hardware.
