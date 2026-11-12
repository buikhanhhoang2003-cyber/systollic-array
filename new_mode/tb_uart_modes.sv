`timescale 1ns/1ps
module tb_uart_modes;
    // Shortened timing for simulation only; project hardware defaults remain 50 MHz.
    localparam integer BIT_CYCLES = 16;
    localparam integer BIT_NS = BIT_CYCLES * 20;
    reg clk = 0;
    always #10 clk = ~clk;
    reg reset_n = 0;
    reg mode_sw_n = 1;
    reg uart_rx = 1;
    wire uart_tx;
    wire [3:0] led_n, digit_n;
    wire [7:0] seg_n;
    integer failures = 0;
    integer k;
    reg [7:0] received;
    uart_modes #(
        .CLK_HZ(160000), .BAUD(10000),
        .DEBOUNCE_CYCLES(8), .SCAN_CYCLES(16)
    ) dut (
        .clk_50mhz(clk), .reset_n(reset_n), .mode_sw_n(mode_sw_n),
        .uart_rx(uart_rx), .uart_tx(uart_tx), .led_n(led_n),
        .digit_n(digit_n), .seg_n(seg_n)
    );

    task send_byte;
        input [7:0] value;
        integer b;
        begin
            @(negedge clk);
            uart_rx = 0;
            #(BIT_NS);
            for (b=0; b<8; b=b+1) begin
                uart_rx = value[b];
                #(BIT_NS);
            end
            uart_rx = 1;
            #(BIT_NS);
        end
    endtask

    task check_number;
        input [15:0] expected;
        begin
            repeat (4) @(negedge clk);
            if (dut.number_bcd !== expected) begin
                $display("FAIL number: expected %h, got %h", expected, dut.number_bcd);
                failures = failures + 1;
            end
        end
    endtask

    initial begin
        #200;
        @(negedge clk) reset_n = 1;
        repeat (32) @(negedge clk);
        if (led_n !== 4'b1101 || uart_tx !== 1) failures = failures + 1;
        send_byte("1"); send_byte("2"); send_byte("3"); send_byte("4");
        check_number(16'h1234);
        send_byte("5"); check_number(16'h2345);
        send_byte(8'h08); check_number(16'h0234);
        send_byte("x"); check_number(16'h0234);
        send_byte(8'h0D); send_byte(8'h0A);
        send_byte("9"); check_number(16'h0009);
        send_byte("8"); send_byte("7"); send_byte("6");
        check_number(16'h9876);

        // Verify all four physical digit selects and their segment patterns.
        for (k=0; k<4; k=k+1) begin
            wait (digit_n == ~(4'b0001 << k));
            #1;
            case (k)
                0: if (seg_n !== 8'h90) failures = failures + 1; // 9
                1: if (seg_n !== 8'h80) failures = failures + 1; // 8
                2: if (seg_n !== 8'hF8) failures = failures + 1; // 7
                3: if (seg_n !== 8'h82) failures = failures + 1; // 6
            endcase
        end

        // A short DIP pulse must not change modes.
        @(negedge clk) mode_sw_n = 0;
        repeat (3) @(negedge clk);
        mode_sw_n = 1;
        repeat (20) @(negedge clk);
        if (led_n !== 4'b1101) failures = failures + 1;

        @(negedge clk) mode_sw_n = 0;
        wait (led_n == 4'b1110);
        // Decode two consecutive TX frames on the actual output wire.
        repeat (2) begin
            @(negedge uart_tx);
            #(BIT_NS/2);
            if (uart_tx !== 0) failures = failures + 1;
            for (k=0; k<8; k=k+1) begin
                #(BIT_NS);
                received[k] = uart_tx;
            end
            #(BIT_NS);
            if (uart_tx !== 1 || received !== 8'h41) failures = failures + 1;
        end
        if (digit_n !== 4'b1111) failures = failures + 1;
        send_byte("3"); check_number(16'h0000);

        @(negedge clk) mode_sw_n = 1;
        repeat (32) @(negedge clk);
        if (led_n !== 4'b1101 || uart_tx !== 1) failures = failures + 1;
        send_byte("4"); send_byte("2"); check_number(16'h0042);
        @(negedge clk) reset_n = 0;
        repeat (4) @(negedge clk);
        reset_n = 1;
        repeat (32) @(negedge clk);
        check_number(16'h0000);
        if (failures == 0) $display("PASS: UART modes, numeric input, scan, debounce, reset");
        else $display("FAIL: %0d checks", failures);
        $finish;
    end
    initial begin
        #1000000;
        $display("FAIL: simulation timeout");
        $finish;
    end
endmodule
