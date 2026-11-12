// Cyclone IV EP4CE6E22C8, 50 MHz, UART 9600 8N1.
module uart_modes #(
    parameter integer CLK_HZ = 50000000,
    parameter integer BAUD = 9600,
    parameter integer DEBOUNCE_CYCLES = 1000000,
    parameter integer SCAN_CYCLES = 12500
)(
    input wire clk_50mhz,
    input wire reset_n,
    input wire mode_sw_n,
    input wire uart_rx,
    output wire uart_tx,
    output wire [3:0] led_n,
    output reg [3:0] digit_n,
    output reg [7:0] seg_n
);
    // Asynchronous assertion, synchronous release of the board reset.
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
    reg [1:0] reset_sync;
    always @(posedge clk_50mhz or negedge reset_n)
        if (!reset_n) reset_sync <= 2'b00;
        else reset_sync <= {reset_sync[0], 1'b1};
    wire rst_n = reset_sync[1];

    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
    reg [1:0] sw_sync;
    reg mode2;
    reg [31:0] debounce_count;
    always @(posedge clk_50mhz or negedge rst_n) begin
        if (!rst_n) begin
            sw_sync <= 2'b11;
            mode2 <= 1'b1;
            debounce_count <= 0;
        end else begin
            sw_sync <= {sw_sync[0], mode_sw_n};
            if (sw_sync[1] == mode2) debounce_count <= 0;
            else if (debounce_count == DEBOUNCE_CYCLES-1) begin
                mode2 <= sw_sync[1];
                debounce_count <= 0;
            end else debounce_count <= debounce_count + 1'b1;
        end
    end

    assign led_n = mode2 ? 4'b1101 : 4'b1110;

    // TX emits repeated ASCII 'A', with the required stop bit per frame.
    wire tx_busy;
    wire tx_rst_n = rst_n & ~mode2;
    uart_tx_8n1 #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) tx_inst (
        .clk(clk_50mhz), .rst_n(tx_rst_n),
        .start(~tx_busy), .data(8'h41), .tx(uart_tx), .busy(tx_busy)
    );

    wire [7:0] rx_data;
    wire rx_valid;
    wire rx_rst_n = rst_n & mode2;
    uart_rx_8n1 #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) rx_inst (
        .clk(clk_50mhz), .rst_n(rx_rst_n), .rx(uart_rx),
        .data(rx_data), .valid(rx_valid)
    );

    // Four BCD digits, thousands at [15:12], units at [3:0].
    reg [15:0] number_bcd;
    reg new_number;
    always @(posedge clk_50mhz or negedge rst_n) begin
        if (!rst_n) begin
            number_bcd <= 16'h0000;
            new_number <= 1'b1;
        end else if (!mode2) begin
            number_bcd <= 16'h0000;
            new_number <= 1'b1;
        end else if (rx_valid) begin
            if (rx_data >= 8'h30 && rx_data <= 8'h39) begin
                if (new_number) number_bcd <= {12'h000, rx_data[3:0]};
                else number_bcd <= {number_bcd[11:0], rx_data[3:0]};
                new_number <= 1'b0;
            end else if (rx_data == 8'h0D || rx_data == 8'h0A) begin
                new_number <= 1'b1;
            end else if (rx_data == 8'h08 || rx_data == 8'h7F) begin
                number_bcd <= {4'h0, number_bcd[15:4]};
            end
        end
    end

    // seg_n[7:0] = {dp,g,f,e,d,c,b,a}, active low.
    function [7:0] encode_digit;
        input [3:0] value;
        begin
            case (value)
                0: encode_digit = 8'hC0;
                1: encode_digit = 8'hF9;
                2: encode_digit = 8'hA4;
                3: encode_digit = 8'hB0;
                4: encode_digit = 8'h99;
                5: encode_digit = 8'h92;
                6: encode_digit = 8'h82;
                7: encode_digit = 8'hF8;
                8: encode_digit = 8'h80;
                9: encode_digit = 8'h90;
                default: encode_digit = 8'hFF;
            endcase
        end
    endfunction

    reg [31:0] scan_count;
    reg [1:0] scan_index;
    reg [3:0] current_digit;
    always @* begin
        // Assumes DIG1 is the leftmost physical digit.
        case (scan_index)
            0: current_digit = number_bcd[15:12];
            1: current_digit = number_bcd[11:8];
            2: current_digit = number_bcd[7:4];
            3: current_digit = number_bcd[3:0];
            default: current_digit = 0;
        endcase
    end
    always @(posedge clk_50mhz or negedge rst_n) begin
        if (!rst_n) begin
            scan_count <= 0;
            scan_index <= 0;
            digit_n <= 4'b1111;
            seg_n <= 8'hFF;
        end else begin
            if (scan_count == SCAN_CYCLES-1) begin
                scan_count <= 0;
                scan_index <= scan_index + 1'b1;
            end else scan_count <= scan_count + 1'b1;

            // Blank before changing segments, then enable the next digit.
            if (!mode2) begin
                digit_n <= 4'b1111;
                seg_n <= 8'hFF;
            end else if (scan_count == 0) digit_n <= 4'b1111;
            else if (scan_count == 1) seg_n <= encode_digit(current_digit);
            else if (scan_count == 2) digit_n <= ~(4'b0001 << scan_index);
        end
    end
endmodule

module uart_tx_8n1 #(
    parameter integer CLK_HZ = 50000000,
    parameter integer BAUD = 9600
)(
    input wire clk, input wire rst_n,
    input wire start, input wire [7:0] data,
    output reg tx, output reg busy
);
    localparam integer BIT_CYCLES = (CLK_HZ + BAUD/2) / BAUD;
    reg [31:0] count;
    reg [3:0] bit_index;
    reg [9:0] frame;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx <= 1'b1;
            busy <= 1'b0;
            count <= 0;
            bit_index <= 0;
            frame <= 10'h3FF;
        end else if (!busy) begin
            tx <= 1'b1;
            if (start) begin
                frame <= {1'b1, data, 1'b0};
                tx <= 1'b0;
                busy <= 1'b1;
                count <= 0;
                bit_index <= 0;
            end
        end else if (count == BIT_CYCLES-1) begin
            count <= 0;
            if (bit_index == 9) begin
                tx <= 1'b1;
                busy <= 1'b0;
            end else begin
                bit_index <= bit_index + 1'b1;
                frame <= {1'b1, frame[9:1]};
                tx <= frame[1];
            end
        end else count <= count + 1'b1;
    end
endmodule

module uart_rx_8n1 #(
    parameter integer CLK_HZ = 50000000,
    parameter integer BAUD = 9600
)(
    input wire clk, input wire rst_n, input wire rx,
    output reg [7:0] data, output reg valid
);
    localparam integer BIT_CYCLES = (CLK_HZ + BAUD/2) / BAUD;
    localparam [1:0] IDLE=0, START=1, DATA=2, STOP=3;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
    reg [1:0] rx_sync;
    reg [1:0] state;
    reg [31:0] count;
    reg [2:0] bit_index;
    reg [7:0] shift;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rx_sync <= 2'b11;
        else rx_sync <= {rx_sync[0], rx};
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            count <= 0;
            bit_index <= 0;
            shift <= 0;
            data <= 0;
            valid <= 0;
        end else begin
            valid <= 0;
            case (state)
                IDLE: begin
                    count <= 0;
                    if (!rx_sync[1]) state <= START;
                end
                START: begin
                    if (count == BIT_CYCLES/2-1) begin
                        count <= 0;
                        if (!rx_sync[1]) begin
                            bit_index <= 0;
                            state <= DATA;
                        end else state <= IDLE;
                    end else count <= count + 1'b1;
                end
                DATA: begin
                    if (count == BIT_CYCLES-1) begin
                        count <= 0;
                        shift[bit_index] <= rx_sync[1];
                        if (bit_index == 7) state <= STOP;
                        else bit_index <= bit_index + 1'b1;
                    end else count <= count + 1'b1;
                end
                STOP: begin
                    if (count == BIT_CYCLES-1) begin
                        count <= 0;
                        if (rx_sync[1]) begin
                            data <= shift;
                            valid <= 1;
                        end
                        state <= IDLE;
                    end else count <= count + 1'b1;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
