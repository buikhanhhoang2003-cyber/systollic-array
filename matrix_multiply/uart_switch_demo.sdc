create_clock -name clk_50mhz -period 20.000 [get_ports {clk_50mhz}]
derive_clock_uncertainty

# Asynchronous inputs are synchronized in the RTL.
set_false_path -from [get_ports {reset_n key_n[*] uart_rx}]

# UART, LEDs and the static display have no synchronous external receiver.
set_false_path -to [get_ports {uart_tx led_n[*] seg_n[*] digit_n[*]}]
