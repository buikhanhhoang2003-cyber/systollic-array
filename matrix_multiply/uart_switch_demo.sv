`timescale 1ns / 1ps

// 50 MHz, 9600 baud, 8 data bits, no parity, one stop bit.
// DIP1 enables continuous A transmission; DIP2 enables ASCII digit reception.
module uart_switch_demo(
    input clk_50mhz,
    input reset_n,
    input [1:0] key_n,
    input uart_rx,
    output uart_tx,
    output reg [3:0] led_n = 4'b1111,
    output reg [7:0] seg_n,
    output [3:0] digit_n
);

reg [1:0] reset_sync = 2'b00;
reg [1:0] key_meta = 2'b11;
reg [1:0] key_sync = 2'b11;
wire reset_ready = reset_sync[1];
wire tx_enable = !key_sync[0];
wire rx_enable = !key_sync[1];

// The schematic ties LED anodes to 3.3 V; initialize cathode outputs high.
always @(posedge clk_50mhz or negedge reset_ready) begin
    if (!reset_ready)
        led_n <= 4'b1111;
    else
        led_n <= {2'b11, key_sync};
end

// Assert reset immediately, release it and sample the switch synchronously.
always @(posedge clk_50mhz or negedge reset_n) begin
    if (!reset_n) begin
        reset_sync <= 2'b00;
        key_meta <= 2'b11;
        key_sync <= 2'b11;
    end else begin
        reset_sync <= {reset_sync[0], 1'b1};
        key_meta <= key_n;
        key_sync <= key_meta;
    end
end

wire rx_bps_start, tx_bps_start;
wire rx_clk_bps, tx_clk_bps;
wire [7:0] rx_data;
wire rx_valid;

speed_select speed_rx(
    .clk(clk_50mhz), .rst_n(reset_ready),
    .bps_start(rx_bps_start), .clk_bps(rx_clk_bps)
);

my_uart_rx receiver(
    .clk(clk_50mhz), .rst_n(reset_ready), .rx_enable(rx_enable),
    .rs232_rx(uart_rx), .rx_data(rx_data), .rx_valid(rx_valid),
    .clk_bps(rx_clk_bps), .bps_start(rx_bps_start)
);

speed_select speed_tx(
    .clk(clk_50mhz), .rst_n(reset_ready),
    .bps_start(tx_bps_start), .clk_bps(tx_clk_bps)
);

my_uart_tx transmitter(
    .clk(clk_50mhz), .rst_n(reset_ready),
    .tx_data(8'h41), .tx_start(tx_enable), .rs232_tx(uart_tx),
    .clk_bps(tx_clk_bps), .bps_start(tx_bps_start)
);

reg [3:0] digit;
reg digit_valid;
always @(posedge clk_50mhz or negedge reset_ready) begin
    if (!reset_ready) begin
        digit <= 4'd0;
        digit_valid <= 1'b0;
    end else if (!rx_enable) begin
        digit_valid <= 1'b0;
    end else if (rx_valid && rx_data >= 8'h30 && rx_data <= 8'h39) begin
        digit <= rx_data[3:0];
        digit_valid <= 1'b1;
    end
end

// Only DIG1 is enabled; all segments and digit selects are active low.
assign digit_n = (reset_ready && digit_valid && rx_enable) ? 4'b1110 : 4'b1111;
always @* begin
    case (digit)
        4'd0: seg_n = 8'hc0;
        4'd1: seg_n = 8'hf9;
        4'd2: seg_n = 8'ha4;
        4'd3: seg_n = 8'hb0;
        4'd4: seg_n = 8'h99;
        4'd5: seg_n = 8'h92;
        4'd6: seg_n = 8'h82;
        4'd7: seg_n = 8'hf8;
        4'd8: seg_n = 8'h80;
        4'd9: seg_n = 8'h90;
        default: seg_n = 8'hff;
    endcase
end

endmodule

