`timescale 1ns / 1ps

module uart_switch_demo_tb;
localparam integer BIT_NS = 5208 * 20;
localparam [79:0] DIGIT_SEGMENTS = 80'h90_80_f8_82_92_99_b0_a4_f9_c0;

reg clk = 1'b0;
reg reset_n = 1'b1;
reg [1:0] key_n = 2'b11;
reg uart_rx = 1'b1;
reg expect_tx_idle = 1'b1;
wire uart_tx;
wire [3:0] led_n;
wire [7:0] seg_n;
wire [3:0] digit_n;
integer i;

always #10 clk = !clk;

uart_switch_demo dut(
    .clk_50mhz(clk), .reset_n(reset_n), .key_n(key_n),
    .uart_rx(uart_rx), .uart_tx(uart_tx), .led_n(led_n),
    .seg_n(seg_n), .digit_n(digit_n)
);

always @(negedge uart_tx)
    if (reset_n && expect_tx_idle)
        $fatal(1, "UART transmitted while switch 1 was off");

always @(negedge clk) begin
    if (led_n[3:2] !== 2'b11)
        $fatal(1, "LED3/LED4 must stay off, got %b", led_n);
    if (!reset_n && led_n !== 4'b1111)
        $fatal(1, "Reset must turn all four LEDs off");
end

task send_frame;
    input [7:0] data;
    input stop_bit;
    integer bit_index;
    begin
        uart_rx = 1'b0;
        #(BIT_NS);
        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
            uart_rx = data[bit_index];
            #(BIT_NS);
        end
        uart_rx = stop_bit;
        #(BIT_NS);
        uart_rx = 1'b1;
    end
endtask

task check_display;
    input [7:0] segments;
    begin
        if (digit_n !== 4'b1110 || seg_n !== segments)
            $fatal(1, "Display: digits=%b segments=%h, expected DIG1 / %h",
                   digit_n, seg_n, segments);
    end
endtask

task check_blank;
    begin
        if (digit_n !== 4'b1111)
            $fatal(1, "Display must be blank, got digit enables %b", digit_n);
    end
endtask

task check_leds;
    input [3:0] expected;
    begin
        if (led_n !== expected)
            $fatal(1, "LEDs: got %b, expected %b (active low)", led_n, expected);
    end
endtask

task read_a;
    input switch_off;
    reg [7:0] data;
    integer bit_index;
    begin
        @(negedge uart_tx);
        #(BIT_NS / 2);
        if (uart_tx !== 1'b0)
            $fatal(1, "TX start bit too short");
        if (switch_off)
            key_n[0] = 1'b1;
        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
            #(BIT_NS);
            data[bit_index] = uart_tx;
        end
        #(BIT_NS);
        if (data !== 8'h41 || uart_tx !== 1'b1)
            $fatal(1, "Expected A with a valid stop bit, got %h", data);
        #(BIT_NS / 2 - 1);
        if (uart_tx !== 1'b1)
            $fatal(1, "TX stop bit too short");
    end
endtask

initial begin
    // Power-up reset also works without pressing the reset button.
    #1;
    check_leds(4'b1111);
    repeat (4) begin
        @(posedge clk);
        #1;
        check_leds(4'b1111);
    end
    #400;
    check_blank;
    check_leds(4'b1111);
    if (uart_tx !== 1'b1)
        $fatal(1, "Power-up must leave TX idle");
    send_frame(8'h35, 1'b1);
    check_blank;

    key_n[1] = 1'b0;
    #200;
    check_leds(4'b1101);
    check_blank;

    // Non-clock-aligned, back-to-back frames with one stop bit each.
    #137;
    for (i = 0; i < 10; i = i + 1) begin
        send_frame(8'h30 + i, 1'b1);
        check_display(DIGIT_SEGMENTS[i*8 +: 8]);
    end
    send_frame(8'h41, 1'b1);
    send_frame(8'h09, 1'b1);
    send_frame(8'h0d, 1'b1);
    send_frame(8'h0a, 1'b1);
    check_display(8'h90);

    send_frame(8'h36, 1'b0);
    #(BIT_NS);
    check_display(8'h90);
    uart_rx = 1'b0;
    #(BIT_NS / 4);
    uart_rx = 1'b1;
    #(BIT_NS);
    check_display(8'h90);
    send_frame(8'h32, 1'b1);
    check_display(8'ha4);

    // Disabling reception during a byte discards that byte and clears DIG1.
    fork
        send_frame(8'h33, 1'b1);
        begin
            #(BIT_NS * 3);
            key_n[1] = 1'b1;
        end
    join
    check_blank;
    check_leds(4'b1111);
    key_n[1] = 1'b0;
    #200;
    check_blank;
    send_frame(8'h34, 1'b1);
    check_display(8'h99);

    // Both switches ON: transmit and receive independently at the same time.
    expect_tx_idle = 1'b0;
    key_n[0] = 1'b0;
    #200;
    check_leds(4'b1100);
    fork
        begin
            read_a(1'b0);
            read_a(1'b0);
            // Switching off mid-frame must still finish this A.
            read_a(1'b1);
        end
        begin
            send_frame(8'h37, 1'b1);
            check_display(8'hf8);
            send_frame(8'h38, 1'b1);
            check_display(8'h80);
        end
    join
    expect_tx_idle = 1'b1;
    #(BIT_NS * 2);
    check_leds(4'b1101);
    check_display(8'h80);

    // Switch 1 alone transmits; incoming digits cannot enable the display.
    expect_tx_idle = 1'b0;
    key_n = 2'b10;
    #200;
    check_leds(4'b1110);
    fork
        read_a(1'b1);
        send_frame(8'h39, 1'b1);
    join
    expect_tx_idle = 1'b1;
    #(BIT_NS * 2);
    check_blank;
    check_leds(4'b1111);

    // Reset during TX immediately returns all outputs to their idle state.
    expect_tx_idle = 1'b0;
    key_n = 2'b00;
    @(negedge uart_tx);
    #(BIT_NS * 2);
    reset_n = 1'b0;
    key_n = 2'b11;
    #100;
    if (uart_tx !== 1'b1)
        $fatal(1, "Reset failed during transmission");
    check_blank;
    check_leds(4'b1111);
    reset_n = 1'b1;
    #200;
    expect_tx_idle = 1'b1;

    // Reset during RX must not display the interrupted character.
    key_n[1] = 1'b0;
    #200;
    fork
        send_frame(8'h36, 1'b1);
        begin
            #(BIT_NS * 3);
            reset_n = 1'b0;
        end
    join
    #100;
    reset_n = 1'b1;
    #200;
    check_blank;
    send_frame(8'h34, 1'b1);
    check_display(8'h99);

    $display("PASS: LEDs off from startup, LED3/LED4 always off, all switch/LED combinations, digits 0-9, simultaneous TX/RX, invalid frames and reset");
    $finish;
end

initial begin
    #(BIT_NS * 1000);
    $fatal(1, "Simulation timed out");
end
endmodule

