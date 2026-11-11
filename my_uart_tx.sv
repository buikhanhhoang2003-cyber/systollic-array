`timescale 1ns / 1ps

module my_uart_tx(
    input logic clk,
    input logic rst_n,
    input logic [7:0] tx_data,
    input logic tx_start,
    output logic rs232_tx,
    input logic clk_bps,
    output logic bps_start
);

logic [7:0] data;
logic [3:0] num;

// Accept requests only while idle, so changing mode cannot truncate a frame.
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        bps_start <= 1'b0;
        rs232_tx <= 1'b1;
        data <= 8'd0;
        num <= 4'd0;
    end else if (!bps_start) begin
        if (tx_start) begin
            data <= tx_data;
            num <= 4'd0;
            bps_start <= 1'b1;
        end
    end else if (clk_bps) begin
        num <= num + 1'b1;
        case (num)
            4'd0: rs232_tx <= 1'b0;
            4'd1: rs232_tx <= data[0];
            4'd2: rs232_tx <= data[1];
            4'd3: rs232_tx <= data[2];
            4'd4: rs232_tx <= data[3];
            4'd5: rs232_tx <= data[4];
            4'd6: rs232_tx <= data[5];
            4'd7: rs232_tx <= data[6];
            4'd8: rs232_tx <= data[7];
            4'd9: rs232_tx <= 1'b1;
            default: begin
                rs232_tx <= 1'b1;
                bps_start <= 1'b0;
            end
        endcase
    end
end

endmodule
