create_clock -name clk_50mhz -period 20.000 [get_ports {clk_50mhz}]
derive_clock_uncertainty

# Asynchronous inputs are handled by synchronizers in the HDL.
set_false_path -from [get_ports {reset_n mode_sw_n uart_rx}]
# UART TX and multiplexed LEDs have no external synchronous capture clock.
set_false_path -to [get_ports {uart_tx led_n[*] digit_n[*] seg_n[*]}]
