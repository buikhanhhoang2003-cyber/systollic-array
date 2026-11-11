`timescale 1ns / 1ps

module speed_select #(
    parameter int CLKS_PER_BIT = 5208
)(
    input logic clk,
    input logic rst_n,
    input logic bps_start,
    output logic clk_bps
);

logic [12:0] count;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        count <= 0;
        clk_bps <= 0;
    end else begin
        if (!bps_start || count == CLKS_PER_BIT - 1)
            count <= 0;
        else
            count <= count + 1'b1;
        clk_bps <= bps_start && count == (CLKS_PER_BIT / 2) - 1;
    end
end

endmodule
