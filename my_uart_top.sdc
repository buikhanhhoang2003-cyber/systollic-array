create_clock -name clk_50mhz -period 20.000 [get_ports {clk_50mhz}]
derive_clock_uncertainty

# These inputs are asynchronous; the RTL synchronizes their release/sampling.
set_false_path -from [get_ports {reset_n key_n[*] gpio}]

# UART and the static LED display have no external synchronous capture clock.
set_false_path -to [get_ports {uart_tx led_n[*] seg_n[*] digit_n[*]}]
