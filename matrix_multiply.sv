`timescale 1ns / 1ps

// Row-by-column multiplication: C[row,col] = sum(A[row,k] * B[k,col]).
module matrix_multiply(
    input logic clk,
    input logic rst_n,
    input logic load_we,
    input logic load_b,
    input logic [5:0] load_addr,
    input logic signed [15:0] load_data,
    input logic start,
    output logic busy,
    output logic done,
    input logic [1:0] read_matrix,
    input logic [5:0] read_addr,
    output logic signed [34:0] read_data
);

localparam IDLE = 2'd0, READ = 2'd1, MAC = 2'd2, STORE = 2'd3;
logic [1:0] state;
logic [2:0] row, col, k;
logic signed [34:0] sum;
assign busy = state != IDLE;

(* ramstyle = "M9K" *) logic signed [15:0] matrix_a [0:63];
(* ramstyle = "M9K" *) logic signed [15:0] matrix_b [0:63];
(* ramstyle = "M9K" *) logic signed [34:0] matrix_c [0:63];
logic signed [15:0] a_data, b_data;
logic signed [34:0] c_data;
logic [1:0] read_matrix_q;
logic [5:0] a_addr;
assign a_addr = busy ? {row, k} : read_addr;
logic [5:0] b_addr;
assign b_addr = busy ? {k, col} : read_addr;
logic signed [31:0] product;
assign product = a_data * b_data;

// Keep RAM outside the reset process so Quartus can use embedded memories.
always_ff @(posedge clk) begin
    if (load_we && !busy) begin
        if (load_b) matrix_b[load_addr] <= load_data;
        else matrix_a[load_addr] <= load_data;
    end
    a_data <= matrix_a[a_addr];
    b_data <= matrix_b[b_addr];
    if (state == STORE) matrix_c[{row, col}] <= sum;
    c_data <= matrix_c[read_addr];
    read_matrix_q <= read_matrix;
end

always_comb begin
    case (read_matrix_q)
        2'd1: read_data = a_data;
        2'd2: read_data = b_data;
        default: read_data = c_data;
    endcase
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= IDLE;
        row <= 0;
        col <= 0;
        k <= 0;
        sum <= 0;
        done <= 0;
    end else begin
        done <= 0;
        case (state)
            IDLE: if (start) begin
                row <= 0;
                col <= 0;
                k <= 0;
                sum <= 0;
                state <= READ;
            end
            READ: state <= MAC;
            MAC: begin
                sum <= sum + product;
                if (k == 7) state <= STORE;
                else begin
                    k <= k + 1'b1;
                    state <= READ;
                end
            end
            STORE: begin
                sum <= 0;
                k <= 0;
                if (col == 7) begin
                    col <= 0;
                    if (row == 7) begin
                        done <= 1;
                        state <= IDLE;
                    end else begin
                        row <= row + 1'b1;
                        state <= READ;
                    end
                end else begin
                    col <= col + 1'b1;
                    state <= READ;
                end
            end
            default: state <= IDLE;
        endcase
    end
end

endmodule
