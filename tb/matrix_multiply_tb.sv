`timescale 1ns / 1ps

module matrix_multiply_tb;
logic clk = 0;
always #10 clk = !clk;
logic rst_n = 0, load_we = 0, load_b = 0, start = 0;
logic [5:0] load_addr = 0, read_addr = 0;
logic [1:0] read_matrix = 0;
logic signed [15:0] load_data = 0;
logic busy, done;
logic signed [34:0] read_data;
logic signed [15:0] a [0:63], b [0:63];
longint signed expected [0:63];
int row, col, k, i, test_case, cycles, seed = 71;

matrix_multiply dut(.*);

task load_matrices;
    begin
        for (int matrix_b = 0; matrix_b < 2; matrix_b++) begin
            for (int address = 0; address < 64; address++) begin
                @(negedge clk);
                load_we = 1;
                load_b = matrix_b;
                load_addr = address;
                load_data = matrix_b ? b[address] : a[address];
            end
        end
        @(negedge clk);
        load_we = 0;
    end
endtask

task check_input_readback;
    longint signed value;
    begin
        for (int matrix_id = 1; matrix_id <= 2; matrix_id++) begin
            @(negedge clk);
            read_matrix = matrix_id;
            for (int address = 0; address < 64; address++) begin
                @(negedge clk);
                read_addr = address;
                @(negedge clk);
                value = matrix_id == 1 ? longint'(a[address]) : longint'(b[address]);
                if (longint'(read_data) !== value)
                    $fatal(1, "Input matrix %0d address %0d readback mismatch", matrix_id, address);
            end
        end
    end
endtask

task multiply_and_check;
    begin
        for (row = 0; row < 8; row++) begin
            for (col = 0; col < 8; col++) begin
                expected[row*8+col] = 0;
                for (k = 0; k < 8; k++)
                    expected[row*8+col] = expected[row*8+col] +
                        longint'(a[row*8+k]) * longint'(b[k*8+col]);
            end
        end
        @(negedge clk);
        read_matrix = 0;
        start = 1;
        @(negedge clk);
        start = 0;
        if (!busy) $fatal(1, "Core did not accept start");

        // A write during computation must not corrupt the loaded operands.
        load_we = 1;
        load_b = 0;
        load_addr = 0;
        load_data = 123;
        @(negedge clk);
        load_we = 0;
        cycles = 1;
        while (!done && cycles < 1200) begin
            @(negedge clk);
            cycles++;
        end
        if (!done || busy) $fatal(1, "Core timeout/busy error");
        for (i = 0; i < 64; i++) begin
            @(negedge clk);
            read_addr = i;
            @(negedge clk);
            if (longint'(read_data) !== expected[i])
                $fatal(1, "Case %0d C[%0d]: got %0d expected %0d",
                       test_case, i, $signed(read_data), expected[i]);
        end
        if (done) $fatal(1, "done must be a single-cycle pulse");
    end
endtask

initial begin
    repeat (3) @(negedge clk);
    rst_n = 1;
    for (test_case = 0; test_case < 7; test_case++) begin
        for (i = 0; i < 64; i++) begin
            case (test_case)
                0: begin a[i] = 0; b[i] = i - 32; end
                1: begin a[i] = (i/8 == i%8); b[i] = i*3 - 67; end
                2: begin a[i] = 32767; b[i] = 32767; end
                3: begin a[i] = -32768; b[i] = -32768; end
                4: begin a[i] = -32768; b[i] = 32767; end
                5: begin a[i] = i - 32; b[i] = ((i/8*3+i%8*5)%11)-5; end
                6: begin a[i] = $random(seed); b[i] = $random(seed); end
            endcase
        end
        load_matrices();
        check_input_readback();
        multiply_and_check();
        // A second start reuses the same memories and clears all accumulators.
        multiply_and_check();
    end

    @(negedge clk);
    start = 1;
    @(negedge clk);
    start = 0;
    repeat (12) @(negedge clk);
    rst_n = 0;
    @(negedge clk);
    if (busy || done) $fatal(1, "Reset did not abort computation");
    rst_n = 1;
    load_matrices();
    multiply_and_check();
    $display("PASS: traditional multiplication, input readback, signed extremes, random, repeated start and reset");
    $finish;
end

initial begin
    #10000000;
    $fatal(1, "Core test timed out");
end
endmodule
