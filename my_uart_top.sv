`timescale 1ns / 1ps

// USB-to-TTL UART: RXD to PIN_114, TXD to PIN_111, common GND, 3.3 V logic.
module my_uart_top #(
    parameter int CLKS_PER_BIT = 5208,
    parameter int DEBOUNCE_CYCLES = 500000
)(
    input logic clk_50mhz,
    input logic reset_n,
    input logic [3:0] key_n,
    input logic gpio,
    output logic uart_tx,
    output logic [3:0] led_n,
    output logic [7:0] seg_n,
    output logic [3:0] digit_n
);

logic [1:0] reset_sync;
logic [3:0] keys_meta, keys_sync;
logic rst_n;
assign rst_n = reset_sync[1];
always_ff @(posedge clk_50mhz or negedge reset_n) begin
    if (!reset_n) begin
        reset_sync <= 0;
        keys_meta <= 4'hf;
        keys_sync <= 4'hf;
    end else begin
        reset_sync <= {reset_sync[0], 1'b1};
        keys_meta <= key_n;
        keys_sync <= keys_meta;
    end
end

// Higher-numbered switches take priority if more than one is ON.
logic [1:0] requested_mode;
assign requested_mode = !keys_sync[2] ? 2'd3 :
                            !keys_sync[1] ? 2'd2 :
                            !keys_sync[0] ? 2'd1 : 2'd0;
logic [1:0] mode_candidate, selected_mode, active_mode;
logic [18:0] debounce_count;
assign digit_n = active_mode == 0 ? 4'hf : 4'b1110;
always_comb begin
    case (active_mode)
        2'd1: seg_n = 8'hf9;
        2'd2: seg_n = 8'ha4;
        2'd3: seg_n = 8'hb0;
        default: seg_n = 8'hff;
    endcase
end

always_ff @(posedge clk_50mhz or negedge rst_n) begin
    if (!rst_n) begin
        mode_candidate <= 0;
        selected_mode <= 0;
        debounce_count <= 0;
    end else if (requested_mode != mode_candidate) begin
        mode_candidate <= requested_mode;
        debounce_count <= 0;
    end else if (debounce_count == DEBOUNCE_CYCLES - 1) begin
        selected_mode <= mode_candidate;
    end else begin
        debounce_count <= debounce_count + 1'b1;
    end
end

localparam MODE_IDLE = 4'd0, MESSAGE = 4'd1, INPUT = 4'd2,
           WAIT_CORE = 4'd3, READ_VALUE = 4'd4, LATCH_VALUE = 4'd5,
           CONVERT = 4'd6, PRINT_NUMBER = 4'd7,
           PRINT_SEPARATOR = 4'd8, PRINT_LF = 4'd9;
logic [3:0] state, message_next;
// Protocol strings use an octal carriage return for portable SystemVerilog parsing.
logic [127:0] message;
logic [3:0] message_left;

logic rx_bps_start, tx_bps_start, rx_clk_bps, tx_clk_bps;
logic [7:0] rx_data;
logic rx_valid;
logic [7:0] tx_data;
logic tx_start;
logic tx_ready;
assign tx_ready = !tx_bps_start && !tx_start;

speed_select #(.CLKS_PER_BIT(CLKS_PER_BIT)) speed_rx(
    .clk(clk_50mhz), .rst_n(rst_n),
    .bps_start(rx_bps_start), .clk_bps(rx_clk_bps)
);
my_uart_rx receiver(
    .clk(clk_50mhz), .rst_n(rst_n),
    .rx_enable(state == INPUT && selected_mode == active_mode),
    .rs232_rx(gpio), .rx_data(rx_data), .rx_valid(rx_valid),
    .clk_bps(rx_clk_bps), .bps_start(rx_bps_start)
);
speed_select #(.CLKS_PER_BIT(CLKS_PER_BIT)) speed_tx(
    .clk(clk_50mhz), .rst_n(rst_n),
    .bps_start(tx_bps_start), .clk_bps(tx_clk_bps)
);
my_uart_tx transmitter(
    .clk(clk_50mhz), .rst_n(rst_n),
    .tx_data(tx_data), .tx_start(tx_start), .rs232_tx(uart_tx),
    .clk_bps(tx_clk_bps), .bps_start(tx_bps_start)
);

logic load_we, load_b, core_start;
logic [5:0] load_addr, read_addr;
logic [1:0] print_matrix;
logic signed [15:0] load_data;
logic core_busy, core_done;
logic signed [34:0] read_data;
matrix_multiply matrix(
    .clk(clk_50mhz), .rst_n(rst_n),
    .load_we(load_we), .load_b(load_b), .load_addr(load_addr),
    .load_data(load_data), .start(core_start), .busy(core_busy),
    .done(core_done), .read_matrix(print_matrix),
    .read_addr(read_addr), .read_data(read_data)
);

logic a_valid, b_valid, c_valid;
assign led_n = ~{1'b0, c_valid, b_valid, a_valid};
logic [5:0] input_count;
logic token_started, have_digits, negative;
logic [15:0] magnitude;
logic is_digit;
assign is_digit = rx_data >= 8'h30 && rx_data <= 8'h39;
logic is_separator;
assign is_separator = rx_data == 8'h20 || rx_data == 8'h2c ||
                    rx_data == 8'h09 || rx_data == 8'h0a || rx_data == 8'h0d;
logic is_sign;
assign is_sign = rx_data == 8'h2d || rx_data == 8'h2b;
logic [19:0] decimal_next;
assign decimal_next = ({4'd0, magnitude} << 3) +
                           ({4'd0, magnitude} << 1) + {16'd0, rx_data[3:0]};
logic number_error;
assign number_error = (is_digit && decimal_next > (negative ? 20'd32768 : 20'd32767)) ||
                    (is_sign && token_started) ||
                    (is_separator && token_started && !have_digits) ||
                    (!is_digit && !is_sign && !is_separator);

logic [34:0] binary;
logic [43:0] bcd, bcd_adjusted;
logic [5:0] bit_count;
logic [3:0] digit_index;
logic negative_pending, leading_zero;
int decimal_digit;

// Shift/add-3 converts one bit per clock without a large hardware divider.
always_comb begin
    bcd_adjusted = bcd;
    for (decimal_digit = 0; decimal_digit < 11; decimal_digit = decimal_digit + 1)
        if (bcd[decimal_digit*4 +: 4] >= 5)
            bcd_adjusted[decimal_digit*4 +: 4] = bcd[decimal_digit*4 +: 4] + 4'd3;
end

always_ff @(posedge clk_50mhz or negedge rst_n) begin
    if (!rst_n) begin
        state <= MESSAGE;
        message <= "READY\015\n";
        message_left <= 7;
        message_next <= MODE_IDLE;
        active_mode <= 0;
        tx_data <= 0;
        tx_start <= 0;
        load_we <= 0;
        load_b <= 0;
        load_addr <= 0;
        load_data <= 0;
        core_start <= 0;
        read_addr <= 0;
        print_matrix <= 0;
        a_valid <= 0;
        b_valid <= 0;
        c_valid <= 0;
        input_count <= 0;
        token_started <= 0;
        have_digits <= 0;
        negative <= 0;
        magnitude <= 0;
        binary <= 0;
        bcd <= 0;
        bit_count <= 0;
        digit_index <= 0;
        negative_pending <= 0;
        leading_zero <= 1;
    end else begin
        tx_start <= 0;
        load_we <= 0;
        core_start <= 0;

        // Finish a computation/print before applying a new switch selection.
        if ((state == MODE_IDLE || state == INPUT) && selected_mode != active_mode) begin
            active_mode <= selected_mode;
            input_count <= 0;
            token_started <= 0;
            have_digits <= 0;
            negative <= 0;
            magnitude <= 0;
            state <= MESSAGE;
            message_next <= MODE_IDLE;
            case (selected_mode)
                2'd0: begin
                    message <= "\015\nIDLE\015\n";
                    message_left <= 8;
                end
                2'd1: begin
                    a_valid <= 0;
                    c_valid <= 0;
                    message <= "\015\nA:64\015\n";
                    message_left <= 8;
                    message_next <= INPUT;
                end
                2'd2: begin
                    b_valid <= 0;
                    c_valid <= 0;
                    message <= "\015\nB:64\015\n";
                    message_left <= 8;
                    message_next <= INPUT;
                end
                2'd3: begin
                    if (a_valid && b_valid) begin
                        core_start <= 1;
                        c_valid <= 0;
                        state <= WAIT_CORE;
                    end else begin
                        message <= "\015\nERR INPUT\015\n";
                        message_left <= 13;
                    end
                end
            endcase
        end else begin
            case (state)
                MODE_IDLE: ;
                MESSAGE: if (tx_ready) begin
                    tx_data <= message[(message_left - 1'b1)*8 +: 8];
                    tx_start <= 1;
                    message_left <= message_left - 1'b1;
                    if (message_left == 1) state <= message_next;
                end
                INPUT: if (rx_valid) begin
                    if (number_error) begin
                        message <= "\015\nERR NUMBER\015\n";
                        message_left <= 14;
                        message_next <= MODE_IDLE;
                        state <= MESSAGE;
                    end else if (is_digit) begin
                        magnitude <= decimal_next[15:0];
                        token_started <= 1;
                        have_digits <= 1;
                    end else if (is_sign) begin
                        negative <= rx_data == 8'h2d;
                        token_started <= 1;
                    end else if (is_separator && have_digits) begin
                        load_we <= 1;
                        load_b <= active_mode == 2;
                        load_addr <= input_count;
                        load_data <= negative ? -magnitude : magnitude;
                        magnitude <= 0;
                        token_started <= 0;
                        have_digits <= 0;
                        negative <= 0;
                        if (input_count == 63) begin
                            if (active_mode == 1) begin
                                a_valid <= 1;
                                print_matrix <= 1;
                                message <= "\015\nMatrix A:\015\n";
                            end else begin
                                b_valid <= 1;
                                print_matrix <= 2;
                                message <= "\015\nMatrix B:\015\n";
                            end
                            read_addr <= 0;
                            message_left <= 13;
                            message_next <= READ_VALUE;
                            state <= MESSAGE;
                        end else input_count <= input_count + 1'b1;
                    end
                end
                WAIT_CORE: if (core_done) begin
                    c_valid <= 1;
                    print_matrix <= 0;
                    read_addr <= 0;
                    message <= "\015\nMatrix C:\015\n";
                    message_left <= 13;
                    message_next <= READ_VALUE;
                    state <= MESSAGE;
                end
                READ_VALUE: state <= LATCH_VALUE;
                LATCH_VALUE: begin
                    binary <= read_data[34] ? -read_data : read_data;
                    negative_pending <= read_data[34];
                    bcd <= 0;
                    bit_count <= 0;
                    leading_zero <= 1;
                    digit_index <= 10;
                    state <= CONVERT;
                end
                CONVERT: begin
                    {bcd, binary} <= {bcd_adjusted, binary} << 1;
                    if (bit_count == 34) state <= PRINT_NUMBER;
                    else bit_count <= bit_count + 1'b1;
                end
                PRINT_NUMBER: if (tx_ready) begin
                    if (negative_pending) begin
                        tx_data <= 8'h2d;
                        tx_start <= 1;
                        negative_pending <= 0;
                    end else if (leading_zero && digit_index != 0 &&
                                 bcd[digit_index*4 +: 4] == 0) begin
                        digit_index <= digit_index - 1'b1;
                    end else begin
                        tx_data <= 8'h30 + {4'd0, bcd[digit_index*4 +: 4]};
                        tx_start <= 1;
                        leading_zero <= 0;
                        if (digit_index == 0) state <= PRINT_SEPARATOR;
                        else digit_index <= digit_index - 1'b1;
                    end
                end
                PRINT_SEPARATOR: if (tx_ready) begin
                    tx_start <= 1;
                    if (read_addr[2:0] == 7) begin
                        tx_data <= 8'h0d;
                        state <= PRINT_LF;
                    end else begin
                        tx_data <= 8'h20;
                        read_addr <= read_addr + 1'b1;
                        state <= READ_VALUE;
                    end
                end
                PRINT_LF: if (tx_ready) begin
                    tx_data <= 8'h0a;
                    tx_start <= 1;
                    if (read_addr == 63) begin
                        case (print_matrix)
                            2'd1: begin
                                message <= "\015\nA OK\015\n";
                                message_left <= 8;
                            end
                            2'd2: begin
                                message <= "\015\nB OK\015\n";
                                message_left <= 8;
                            end
                            default: begin
                                message <= "DONE\015\n";
                                message_left <= 6;
                            end
                        endcase
                        message_next <= MODE_IDLE;
                        state <= MESSAGE;
                    end else begin
                        read_addr <= read_addr + 1'b1;
                        state <= READ_VALUE;
                    end
                end
                default: state <= MODE_IDLE;
            endcase
        end
    end
end

endmodule
