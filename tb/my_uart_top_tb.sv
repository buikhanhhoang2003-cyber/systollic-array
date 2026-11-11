`timescale 1ns / 1ps

module my_uart_top_tb;
localparam int CLKS_PER_BIT = 32;
localparam int BIT_NS = CLKS_PER_BIT * 20;
logic clk = 0;
always #10 clk = !clk;
logic reset_n = 0;
logic [3:0] key_n = 4'hf;
logic gpio = 1;
logic uart_tx;
logic [7:0] seg_n;
logic [3:0] digit_n;
logic [3:0] led_n;
logic [2:0] ready_flags = 0;
logic signed [15:0] a [0:63], b [0:63];
longint signed expected [0:63];
logic [7:0] received [0:19999];
int received_count = 0, consumed_count = 0;
int row, col, k, i, test_case, before_count;

my_uart_top #(.CLKS_PER_BIT(CLKS_PER_BIT), .DEBOUNCE_CYCLES(4)) dut(
    .clk_50mhz(clk), .reset_n(reset_n), .key_n(key_n), .gpio(gpio),
    .uart_tx(uart_tx), .led_n(led_n), .seg_n(seg_n), .digit_n(digit_n)
);

// Decode the physical TX logic independently of the transmitter internals.
initial forever begin : uart_monitor
    logic [7:0] data;
    @(negedge uart_tx);
    #(BIT_NS / 2);
    if (uart_tx !== 0) $fatal(1, "Invalid TX start bit");
    for (int bit_index = 0; bit_index < 8; bit_index++) begin
        #(BIT_NS);
        data[bit_index] = uart_tx;
    end
    #(BIT_NS);
    if (uart_tx !== 1) $fatal(1, "Invalid TX stop bit");
    if (received_count == 20000) $fatal(1, "TX capture overflow");
    received[received_count] = data;
    received_count++;
    #(BIT_NS / 2);
end

task send_byte(input [7:0] data);
    begin
        gpio = 0;
        #(BIT_NS);
        for (int bit_index = 0; bit_index < 8; bit_index++) begin
            gpio = data[bit_index];
            #(BIT_NS);
        end
        gpio = 1;
        #(BIT_NS);
    end
endtask

task send_text(input string text);
    for (int pos = 0; pos < text.len(); pos++) send_byte(text[pos]);
endtask

task expect_text(input string text);
    begin
        for (int pos = 0; pos < text.len(); pos++) begin
            while (received_count <= consumed_count) @(negedge clk);
            if (received[consumed_count] !== text[pos])
                $fatal(1, "UART byte %0d: got %h expected %h in '%s'",
                       consumed_count, received[consumed_count], text[pos], text);
            consumed_count++;
        end
    end
endtask

task select_mode(input int mode);
    begin
        case (mode)
            0: key_n = 4'b1111;
            1: key_n = 4'b1110;
            2: key_n = 4'b1101;
            3: key_n = 4'b1011;
        endcase
    end
endtask

task check_status(input int mode);
    logic [7:0] expected_segments;
    begin
        case (mode)
            1: expected_segments = 8'hf9;
            2: expected_segments = 8'ha4;
            3: expected_segments = 8'hb0;
            default: expected_segments = 8'hff;
        endcase
        if (seg_n !== expected_segments || digit_n !== (mode == 0 ? 4'hf : 4'he))
            $fatal(1, "Incorrect seven-segment status for stage %0d", mode);
    end
endtask

task check_leds;
    if (led_n !== {1'b1, ~ready_flags})
        $fatal(1, "Ready LEDs: got %b expected %b", led_n, {1'b1, ~ready_flags});
endtask

task enter_idle;
    begin
        select_mode(0);
        expect_text("\015\nIDLE\015\n");
        check_status(0);
        check_leds();
    end
endtask

task load_matrix(input int matrix_b);
    int value;
    begin
        select_mode(matrix_b ? 2 : 1);
        expect_text(matrix_b ? "\015\nB:64\015\n" : "\015\nA:64\015\n");
        ready_flags[matrix_b ? 1 : 0] = 0;
        ready_flags[2] = 0;
        check_leds();
        check_status(matrix_b ? 2 : 1);
        for (int address = 0; address < 64; address++) begin
            value = matrix_b ? $signed(b[address]) : $signed(a[address]);
            if (address == 5 && value >= 0)
                send_text($sformatf("+000%0d", value));
            else send_text($sformatf("%0d", value));
            if (address % 8 == 7) send_text("\015\n");
            else if (address % 3 == 0) send_byte(8'h2c);
            else if (address % 3 == 1) send_byte(8'h20);
            else send_byte(8'h09);
        end
        expect_text(matrix_b ? "\015\nMatrix B:\015\n" : "\015\nMatrix A:\015\n");
        ready_flags[matrix_b ? 1 : 0] = 1;
        check_leds();
        expect_matrix(matrix_b ? 2 : 1);
        expect_text(matrix_b ? "\015\nB OK\015\n" : "\015\nA OK\015\n");
        check_leds();
        enter_idle();
    end
endtask

task calculate_reference;
    begin
        for (row = 0; row < 8; row++) begin
            for (col = 0; col < 8; col++) begin
                expected[row*8+col] = 0;
                for (k = 0; k < 8; k++)
                    expected[row*8+col] = expected[row*8+col] +
                        longint'(a[row*8+k]) * longint'(b[k*8+col]);
            end
        end
    end
endtask

task expect_matrix(input int matrix_id);
    longint signed value;
    begin
        for (int address = 0; address < 64; address++) begin
            case (matrix_id)
                1: value = longint'(a[address]);
                2: value = longint'(b[address]);
                default: value = expected[address];
            endcase
            expect_text($sformatf("%0d", value));
            if (address % 8 == 7) expect_text("\015\n");
            else expect_text(" ");
        end
    end
endtask

initial begin
    repeat (4) @(negedge clk);
    reset_n = 1;
    expect_text("READY\015\n");
    check_status(0);
    check_leds();

    // No run is allowed until both complete matrices have been loaded.
    select_mode(3);
    expect_text("\015\nERR INPUT\015\n");
    enter_idle();
    select_mode(1);
    expect_text("\015\nA:64\015\n");
    for (i = 0; i < 63; i++) send_text("0 ");
    before_count = received_count;
    #(BIT_NS * 20);
    if (received_count != before_count) $fatal(1, "Accepted an incomplete matrix");
    check_leds();
    select_mode(3);
    expect_text("\015\nERR INPUT\015\n");
    enter_idle();

    // Reject overflow, a sign without digits, and nonnumeric text.
    for (test_case = 0; test_case < 4; test_case++) begin
        select_mode(1);
        expect_text("\015\nA:64\015\n");
        case (test_case)
            0: send_text("32768 ");
            1: send_text("-32769 ");
            2: send_text("- ");
            3: send_text("1x ");
        endcase
        expect_text("\015\nERR NUMBER\015\n");
        enter_idle();
    end

    // A short switch glitch must not start a new input transaction.
    key_n = 4'b1110;
    @(negedge clk);
    key_n = 4'b1111;
    #(BIT_NS * 20);
    if (received_count != consumed_count) $fatal(1, "Switch glitch was not rejected");

    for (test_case = 0; test_case < 5; test_case++) begin
        for (i = 0; i < 64; i++) begin
            case (test_case)
                0: begin a[i] = 0; b[i] = (i/8 == i%8); end
                1: begin
                    a[i] = i - 32;
                    b[i] = (i/8 == i%8);
                    if (i == 0) a[i] = -32768;
                    if (i == 1) a[i] = 32767;
                end
                2: begin a[i] = i - 32; b[i] = ((i/8*3+i%8*5)%11)-5; end
                3: begin a[i] = -32768; b[i] = -32768; end
                4: begin a[i] = -32768; b[i] = 32767; end
            endcase
        end
        calculate_reference();
        load_matrix(0);
        load_matrix(1);
        // Leave all three switches ON: switch 3 must have priority.
        key_n = 4'b1000;
        ready_flags[2] = 0;
        repeat (12) @(negedge clk);
        check_leds();
        expect_text("\015\nMatrix C:\015\n");
        ready_flags[2] = 1;
        check_leds();
        check_status(3);
        if (test_case == 2) select_mode(0);
        expect_matrix(0);
        expect_text("DONE\015\n");
        check_leds();
        if (test_case == 2) begin
            expect_text("\015\nIDLE\015\n");
            check_status(0);
            check_leds();
        end
        else begin
            #(BIT_NS * 20);
            if (received_count != consumed_count) $fatal(1, "Printed twice while DIP3 held ON");
            enter_idle();
        end
        if (test_case == 1) begin
            // A new DIP3 selection reuses A/B without stale accumulators.
            select_mode(3);
            ready_flags[2] = 0;
            repeat (12) @(negedge clk);
            check_leds();
            expect_text("\015\nMatrix C:\015\n");
            ready_flags[2] = 1;
            check_leds();
            check_status(3);
            expect_matrix(0);
            expect_text("DONE\015\n");
            enter_idle();
        end
    end

    select_mode(1);
    expect_text("\015\nA:64\015\n");
    ready_flags = 3'b010;
    check_leds();
    send_text("1 2 3 ");
    key_n = 4'hf;
    reset_n = 0;
    repeat (4) @(negedge clk);
    reset_n = 1;
    ready_flags = 0;
    expect_text("READY\015\n");
    check_leds();
    select_mode(3);
    expect_text("\015\nERR INPUT\015\n");
    $display("PASS: UART matrix loading, parser errors, all 64 results, switches, repeated runs and reset");
    $finish;
end

initial begin
    #(BIT_NS * 200000);
    $fatal(1, "UART matrix test timed out");
end
endmodule

