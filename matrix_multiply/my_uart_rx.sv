`timescale 1ns / 1ps

module my_uart_rx(
    input clk,
    input rst_n,
    input rx_enable,
    input rs232_rx,
    output reg [7:0] rx_data,
    output reg rx_valid,
    input clk_bps,
    output reg bps_start
);

reg [2:0] rx_sync;
reg [7:0] data;
reg [3:0] num;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        rx_sync <= 3'b111;
    else
        rx_sync <= {rx_sync[1:0], rs232_rx};
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        bps_start <= 1'b0;
        rx_data <= 8'd0;
        rx_valid <= 1'b0;
        data <= 8'd0;
        num <= 4'd0;
    end else begin
        rx_valid <= 1'b0;
        if (!rx_enable) begin
            bps_start <= 1'b0;
            num <= 4'd0;
        end else if (!bps_start) begin
            num <= 4'd0;
            if (rx_sync[2] && !rx_sync[1])
                bps_start <= 1'b1;
        end else if (clk_bps) begin
            if (num == 4'd0) begin
                // Confirm the start bit at its midpoint to reject short glitches.
                if (rx_sync[1])
                    bps_start <= 1'b0;
                else
                    num <= 4'd1;
            end else if (num <= 4'd8) begin
                data[num - 1'b1] <= rx_sync[1];
                num <= num + 1'b1;
            end else begin
                // Finish at the stop-bit midpoint to accept back-to-back 8N1.
                bps_start <= 1'b0;
                if (rx_sync[1]) begin
                    rx_data <= data;
                    rx_valid <= 1'b1;
                end
            end
        end
    end
end

endmodule
