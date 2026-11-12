#!/usr/bin/env bash
# Tạo UART ba mode, accelerator 4 core/tile 4x4 và GUI PyQt; cần Bash và coreutils.
# Cách dùng: bash create_matmul.sh [thư_mục_đích]
# Đích mặc định: ./matmul. Thư mục cha phải tồn tại; đích phải chưa tồn tại.
set -euo pipefail
set -o noclobber

if (( $# > 1 )); then
    printf 'Cách dùng: bash %s [thư_mục_đích]\n' "$0" >&2
    exit 2
fi

destination="${1:-./matmul}"
# mkdir tạo đích mới hoặc thất bại nếu đích đã tồn tại, kể cả symlink.
if ! mkdir -- "$destination"; then
    printf 'Không tạo được thư mục đích: %s. Hãy chọn thư mục mới trong thư mục cha có sẵn.\n' "$destination" >&2
    exit 1
fi
mkdir -- "$destination/rtl"

cat > "$destination/rtl/matmul.v" <<'__MATMUL_EMBEDDED_FILE_0__'
module matmul (
    input  wire       clk_50mhz,
    input  wire       reset_n,
    input  wire       dip1_n,
    input  wire       dip2_n,
    input  wire       dip3_n,
    input  wire       uart_rx,
    output wire       uart_tx,
    output wire [3:0] led_n,
    output wire [3:0] digit_n,
    output wire [7:0] seg_n
);
    // Assert immediately; release only through the two clocked stages.
    (* preserve *) reg reset_meta = 1'b0;
    (* preserve *) reg reset_sync = 1'b0;
    always @(posedge clk_50mhz or negedge reset_n) begin
        if (!reset_n) begin
            reset_meta <= 1'b0;
            reset_sync <= 1'b0;
        end else begin
            reset_meta <= 1'b1;
            reset_sync <= reset_meta;
        end
    end

    (* preserve *) reg [2:0] dip_meta;
    (* preserve *) reg [2:0] dip_sync;
    always @(posedge clk_50mhz or negedge reset_sync) begin
        if (!reset_sync) begin
            dip_meta <= 3'b111;
            dip_sync <= 3'b111;
        end else begin
            dip_meta <= {dip3_n, dip2_n, dip1_n};
            dip_sync <= dip_meta;
        end
    end

    reg [19:0] debounce_count;
    reg [2:0] dip_stable;
    reg [2:0] dip_candidate;
    always @(posedge clk_50mhz or negedge reset_sync) begin
        if (!reset_sync) begin
            debounce_count <= 20'd0;
            dip_stable <= 3'b111;
            dip_candidate <= 3'b111;
        end else if (dip_sync != dip_candidate) begin
            dip_candidate <= dip_sync;
            debounce_count <= 20'd0;
        end else if (dip_candidate == dip_stable) begin
            debounce_count <= 20'd0;
        end else if (debounce_count == 20'd999999) begin
            debounce_count <= 20'd0;
            dip_stable <= dip_candidate;
        end else begin
            debounce_count <= debounce_count + 1'b1;
        end
    end

    wire tx_busy;
    localparam [1:0] MODE_IDLE = 2'd0, MODE_TX = 2'd1,
                     MODE_RX = 2'd2, MODE_MATRIX = 2'd3;
    // A higher DIP number takes priority; only one UART sender is enabled.
    wire [1:0] requested_mode = !dip_stable[2] ? MODE_MATRIX :
                                !dip_stable[1] ? MODE_RX :
                                !dip_stable[0] ? MODE_TX : MODE_IDLE;
    reg [1:0] mode;
    // Finish the current stop bit before changing mode.
    always @(posedge clk_50mhz or negedge reset_sync) begin
        if (!reset_sync)
            mode <= MODE_IDLE;
        else if (!tx_busy)
            mode <= requested_mode;
    end
    wire mode_rx = (mode == MODE_RX);
    wire mode_matrix = (mode == MODE_MATRIX);
    wire [7:0] matrix_tx_data;
    wire matrix_tx_valid;
    wire matrix_tx_ready = mode_matrix && requested_mode == MODE_MATRIX && !tx_busy;

    // {PIN_84, PIN_85, PIN_86, PIN_87}; 0 lights a small onboard LED.
    assign led_n = !reset_sync ? 4'b1111 :
                   mode == MODE_TX ? 4'b1110 :
                   mode_rx ? 4'b1101 :
                   mode_matrix ? 4'b1011 : 4'b1111;

    uart_tx u_tx (
        .clk(clk_50mhz),
        .reset_n(reset_sync),
        .enable((mode == MODE_TX && requested_mode == MODE_TX) ||
                (mode_matrix && requested_mode == MODE_MATRIX && matrix_tx_valid)),
        .data(mode_matrix ? matrix_tx_data : 8'h41),
        .tx(uart_tx),
        .busy(tx_busy)
    );

    wire [7:0] rx_data;
    wire rx_valid;
    uart_rx u_rx (
        .clk(clk_50mhz),
        .reset_n(reset_sync),
        .rx_enable(mode_rx || mode_matrix),
        .rx(uart_rx),
        .data(rx_data),
        .valid(rx_valid)
    );

    matrix_uart u_matrix (
        .clk(clk_50mhz),
        .reset_n(reset_sync),
        .enable(mode_matrix),
        .rx_data(rx_data),
        .rx_valid(rx_valid),
        .tx_data(matrix_tx_data),
        .tx_valid(matrix_tx_valid),
        .tx_ready(matrix_tx_ready)
    );

    reg [3:0] digit;
    always @(posedge clk_50mhz or negedge reset_sync) begin
        if (!reset_sync) begin
            digit <= 4'd0;
        end else if (!mode_rx) begin
            digit <= 4'd0;
        end else if (rx_valid) begin
            if (rx_data >= 8'h30 && rx_data <= 8'h39) begin
                digit <= rx_data[3:0];
            end else if (rx_data == 8'h08 || rx_data == 8'h7f) begin
                digit <= 4'd0;
            end
        end
    end

    sevenseg_scan u_display (
        .clk(clk_50mhz),
        .reset_n(reset_sync),
        .enable(mode_rx),
        .digit(digit),
        .digit_n(digit_n),
        .seg_n(seg_n)
    );
endmodule
__MATMUL_EMBEDDED_FILE_0__

cat > "$destination/rtl/uart_tx.v" <<'__MATMUL_EMBEDDED_FILE_1__'
module uart_tx (
    input  wire       clk,
    input  wire       reset_n,
    input  wire       enable,
    input  wire [7:0] data,
    output reg        tx,
    output reg        busy
);
    // 50 MHz / 5208 = 9600.614 baud; all timing stays on clk.
    localparam [12:0] BIT_LAST = 13'd5207;
    reg [12:0] bit_count;
    reg [3:0] bit_index;
    reg [9:0] frame;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            tx <= 1'b1;
            busy <= 1'b0;
            bit_count <= 13'd0;
            bit_index <= 4'd0;
            frame <= 10'h3ff;
        end else if (!busy) begin
            tx <= 1'b1;
            bit_count <= 13'd0;
            bit_index <= 4'd0;
            if (enable) begin
                frame <= {1'b1, data, 1'b0};
                tx <= 1'b0;
                busy <= 1'b1;
            end
        end else if (bit_count == BIT_LAST) begin
            bit_count <= 13'd0;
            if (bit_index == 4'd9) begin
                tx <= 1'b1;
                busy <= 1'b0;
            end else begin
                frame <= {1'b1, frame[9:1]};
                tx <= frame[1];
                bit_index <= bit_index + 1'b1;
            end
        end else begin
            bit_count <= bit_count + 1'b1;
        end
    end
endmodule
__MATMUL_EMBEDDED_FILE_1__

cat > "$destination/rtl/uart_rx.v" <<'__MATMUL_EMBEDDED_FILE_2__'
`timescale 1ns / 1ps

module uart_rx (
    input  wire       clk,
    input  wire       reset_n,
    input  wire       rx_enable,
    input  wire       rx,
    output reg  [7:0] data,
    output reg        valid
);
    localparam [12:0] BIT_LAST = 13'd5207;
    localparam [12:0] HALF_LAST = 13'd2603;

    (* preserve *) reg rx_meta;
    (* preserve *) reg rx_sync;
    reg rx_previous;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
            rx_previous <= 1'b1;
        end else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;
            rx_previous <= rx_sync;
        end
    end

    reg bps_start;
    reg [12:0] baud_count;
    reg [3:0] num;
    reg [7:0] shift_data;
    // Clock enable at each bit midpoint; never used as a separate clock.
    wire clk_bps = bps_start && (baud_count == HALF_LAST);
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            baud_count <= 13'd0;
        else if (!rx_enable || !bps_start || baud_count == BIT_LAST)
            baud_count <= 13'd0;
        else
            baud_count <= baud_count + 1'b1;
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            bps_start <= 1'b0;
            data <= 8'd0;
            valid <= 1'b0;
            shift_data <= 8'd0;
            num <= 4'd0;
        end else begin
            valid <= 1'b0;
            if (!rx_enable) begin
                bps_start <= 1'b0;
                num <= 4'd0;
                shift_data <= 8'd0;
                data <= 8'd0;
            end else if (!bps_start) begin
                num <= 4'd0;
                if (rx_previous && !rx_sync)
                    bps_start <= 1'b1;
            end else if (clk_bps) begin
                if (num == 4'd0) begin
                    if (rx_sync)
                        bps_start <= 1'b0;
                    else
                        num <= 4'd1;
                end else if (num <= 4'd8) begin
                    shift_data[num - 1'b1] <= rx_sync;
                    num <= num + 1'b1;
                end else begin
                    bps_start <= 1'b0;
                    if (rx_sync) begin
                        data <= shift_data;
                        valid <= 1'b1;
                    end
                end
            end
        end
    end
endmodule
__MATMUL_EMBEDDED_FILE_2__

cat > "$destination/rtl/sevenseg_scan.v" <<'__MATMUL_EMBEDDED_FILE_3__'
module sevenseg_scan (
    input  wire       clk,
    input  wire       reset_n,
    input  wire       enable,
    input  wire [3:0] digit,
    output reg  [3:0] digit_n,
    output reg  [7:0] seg_n
);
    reg [7:0] segments;
    reg [8:0] blank_count;

    always @* begin
        // {dp,g,f,e,d,c,b,a}, common anode; decimal point stays off.
        case (digit)
            4'd0: segments = 8'hc0;
            4'd1: segments = 8'hf9;
            4'd2: segments = 8'ha4;
            4'd3: segments = 8'hb0;
            4'd4: segments = 8'h99;
            4'd5: segments = 8'h92;
            4'd6: segments = 8'h82;
            4'd7: segments = 8'hf8;
            4'd8: segments = 8'h80;
            4'd9: segments = 8'h90;
            default: segments = 8'hff;
        endcase
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            blank_count <= 9'd0;
            digit_n <= 4'b1111;
            seg_n <= 8'hff;
        end else if (!enable) begin
            blank_count <= 9'd0;
            digit_n <= 4'b1111;
            seg_n <= 8'hff;
        end else if (digit_n != 4'b1111 && seg_n != segments) begin
            digit_n <= 4'b1111;
            blank_count <= 9'd0;
        end else if (digit_n == 4'b1111) begin
            // Allow the PNP driver to turn off before changing shared segments.
            if (blank_count == 9'd249)
                seg_n <= segments;
            if (blank_count == 9'd499) begin
                // DIG1 / PIN_133 follows dig[0] in the vendor examples.
                digit_n <= 4'b1110;
                blank_count <= 9'd0;
            end else begin
                blank_count <= blank_count + 1'b1;
            end
        end
    end
endmodule
__MATMUL_EMBEDDED_FILE_3__

cat > "$destination/matmul.qpf" <<'__MATMUL_EMBEDDED_FILE_4__'
QUARTUS_VERSION = "21.1"
PROJECT_REVISION = "matmul"
__MATMUL_EMBEDDED_FILE_4__

cat > "$destination/matmul.qsf" <<'__MATMUL_EMBEDDED_FILE_5__'
# Board pinout/device settings: ../Altera-Cyclone-IV-board-V3.0/cyclone_iv_board_v3.qsf
# Used ports only; board key_n[0..2] are named dip1_n/dip2_n/dip3_n here.
# UART TX matches FPGA-UART-TX/PIN_114; RX uses board ext_clk_in/PIN_24.
# Assignments are embedded so the project remains standalone.
set_global_assignment -name TOP_LEVEL_ENTITY matmul
set_global_assignment -name ORIGINAL_QUARTUS_VERSION 21.1.0
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
set_global_assignment -name VERILOG_INPUT_VERSION VERILOG_2001
set_global_assignment -name STRATIX_DEVICE_IO_STANDARD "3.3-V LVTTL"
set_global_assignment -name VERILOG_FILE rtl/matmul.v
set_global_assignment -name VERILOG_FILE rtl/uart_tx.v
set_global_assignment -name VERILOG_FILE rtl/uart_rx.v
set_global_assignment -name VERILOG_FILE rtl/sevenseg_scan.v
set_global_assignment -name VERILOG_FILE rtl/matrix_uart.v
set_global_assignment -name VERILOG_FILE rtl/matmul8x8_top.v
set_global_assignment -name VERILOG_FILE rtl/matmul8x8_dataflow.v
set_global_assignment -name VERILOG_FILE rtl/tile_c4x4_1dsp.v
set_global_assignment -name VERILOG_FILE rtl/tile_bram.v
set_global_assignment -name SDC_FILE matmul.sdc

# Device and I/O assignments taken from the board QSF.
# Bus targets use native QSF syntax, as in the vendor .qsf examples.
set_global_assignment -name FAMILY "Cyclone IV E"
set_global_assignment -name DEVICE EP4CE6E22C8
set_global_assignment -name RESERVE_ALL_UNUSED_PINS "AS INPUT TRI-STATED"
set_global_assignment -name RESERVE_ALL_UNUSED_PINS_WEAK_PULLUP "AS INPUT TRI-STATED"
set_global_assignment -name CYCLONEII_RESERVE_NCEO_AFTER_CONFIGURATION "USE AS REGULAR IO"
set_global_assignment -name ENABLE_INIT_DONE_OUTPUT OFF
set_global_assignment -name ENABLE_DEVICE_WIDE_RESET OFF
set_global_assignment -name ENABLE_DEVICE_WIDE_OE OFF
set_location_assignment PIN_23 -to clk_50mhz
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to clk_50mhz
set_location_assignment PIN_25 -to reset_n
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to reset_n
set_location_assignment PIN_88 -to dip1_n
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to dip1_n
set_location_assignment PIN_89 -to dip2_n
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to dip2_n
set_location_assignment PIN_90 -to dip3_n
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to dip3_n
set_location_assignment PIN_87 -to led_n[0]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to led_n[0]
set_location_assignment PIN_86 -to led_n[1]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to led_n[1]
set_location_assignment PIN_85 -to led_n[2]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to led_n[2]
set_location_assignment PIN_84 -to led_n[3]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to led_n[3]
set_location_assignment PIN_133 -to digit_n[0]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to digit_n[0]
set_location_assignment PIN_135 -to digit_n[1]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to digit_n[1]
set_location_assignment PIN_136 -to digit_n[2]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to digit_n[2]
set_location_assignment PIN_137 -to digit_n[3]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to digit_n[3]
set_location_assignment PIN_128 -to seg_n[0]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to seg_n[0]
set_location_assignment PIN_121 -to seg_n[1]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to seg_n[1]
set_location_assignment PIN_125 -to seg_n[2]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to seg_n[2]
set_location_assignment PIN_129 -to seg_n[3]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to seg_n[3]
set_location_assignment PIN_132 -to seg_n[4]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to seg_n[4]
set_location_assignment PIN_126 -to seg_n[5]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to seg_n[5]
set_location_assignment PIN_124 -to seg_n[6]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to seg_n[6]
set_location_assignment PIN_127 -to seg_n[7]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to seg_n[7]
# TX matches UART_TX.qsf: P1 contact 7, also feeding the MAX3232 T1IN input.
set_location_assignment PIN_114 -to uart_tx
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to uart_tx
# P1 contact 34: CLK2 is input-only and is used here as UART data input.
set_location_assignment PIN_24 -to uart_rx
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to uart_rx
__MATMUL_EMBEDDED_FILE_5__

cat > "$destination/matmul.sdc" <<'__MATMUL_EMBEDDED_FILE_6__'
create_clock -name clk_50mhz -period 20.000 [get_ports {clk_50mhz}]
derive_clock_uncertainty

# Only the external asynchronous paths into the synchronizers are excluded.
# Stage-to-stage paths and synchronized reset distribution remain timed.
set_false_path -from [get_ports {reset_n}] -to [get_registers {*reset_meta *reset_sync}]
set_false_path -from [get_ports {dip1_n dip2_n dip3_n}] -to [get_registers {*dip_meta*}]
set_false_path -from [get_ports {uart_rx}] -to [get_registers {*u_rx|rx_meta}]

# LEDs have no capture clock; UART is sampled by an independent PC clock.
# These exceptions end at output pads, leaving all internal paths timed.
set_false_path -to [get_ports {uart_tx led_n[*] digit_n[*] seg_n[*]}]
__MATMUL_EMBEDDED_FILE_6__

cat > "$destination/check_project.py" <<'__MATMUL_EMBEDDED_FILE_7__'
"""Check source assignments and the Fitter .pin report when available; no compilation."""

from pathlib import Path
import re
import shlex


def main():
    root = Path(__file__).resolve().parent
    globals_ = {}
    sources = []
    locations = {}
    standards = {}
    for line in (root / "matmul.qsf").read_text().splitlines():
        words = shlex.split(line, comments=True)
        if not words:
            continue
        command = words[0]
        assert command in {
            "set_global_assignment", "set_location_assignment",
            "set_instance_assignment",
        }, line
        assert not any(c in line for c in "$;"), line
        if command == "set_global_assignment":
            assert words[1] == "-name" and len(words) == 4, line
            if words[2] == "VERILOG_FILE":
                sources.append(words[3])
            else:
                assert words[2] not in globals_, line
                globals_[words[2]] = words[3]
        elif command == "set_location_assignment":
            assert words[2] == "-to" and len(words) == 4, line
            port = words[3]
            assert port not in locations, port
            locations[port] = int(words[1].removeprefix("PIN_"))
        else:
            assert words[1:4] == ["-name", "IO_STANDARD", "3.3-V LVTTL"], line
            assert words[4] == "-to" and len(words) == 6, line
            port = words[5]
            assert port not in standards, port
            standards[port] = words[3]

    assert globals_["FAMILY"] == "Cyclone IV E"
    assert globals_["DEVICE"] == "EP4CE6E22C8"
    assert globals_["TOP_LEVEL_ENTITY"] == "matmul"
    assert globals_["VERILOG_INPUT_VERSION"] == "VERILOG_2001"
    assert globals_["STRATIX_DEVICE_IO_STANDARD"] == "3.3-V LVTTL"
    assert globals_["RESERVE_ALL_UNUSED_PINS"] == "AS INPUT TRI-STATED"
    assert globals_["RESERVE_ALL_UNUSED_PINS_WEAK_PULLUP"] == "AS INPUT TRI-STATED"
    assert globals_["CYCLONEII_RESERVE_NCEO_AFTER_CONFIGURATION"] == "USE AS REGULAR IO"
    assert globals_["ENABLE_DEVICE_WIDE_RESET"] == "OFF"
    assert globals_["ENABLE_DEVICE_WIDE_OE"] == "OFF"
    revision = re.search(r'PROJECT_REVISION\s*=\s*"([^"]+)"',
                         (root / "matmul.qpf").read_text()).group(1)
    assert revision == "matmul" and (root / (revision + ".qsf")).is_file()
    assert len(sources) == len(set(sources)) == 9
    assert all((root / path).is_file() for path in sources)
    assert set(sources) == {str(p.relative_to(root)) for p in (root / "rtl").glob("*.v")}
    assert (root / globals_["SDC_FILE"]).is_file()

    header = (root / "rtl/matmul.v").read_text().split(");", 1)[0]
    assert re.search(r"module\s+matmul\s*\(", header)
    ports = set()
    for _, high, low, name in re.findall(
        r"(input|output)\s+wire\s*(?:\[(\d+):(\d+)\])?\s*(\w+)", header
    ):
        if high:
            ports.update(f"{name}[{i}]" for i in range(int(low), int(high) + 1))
        else:
            ports.add(name)
    expected = dict(clk_50mhz=23, reset_n=25, dip1_n=88, dip2_n=89, dip3_n=90,
                    uart_tx=114, uart_rx=24)
    for bus, pins in [("led_n", [87, 86, 85, 84]),
                      ("digit_n", [133, 135, 136, 137]),
                      ("seg_n", [128, 121, 125, 129, 132, 126, 124, 127])]:
        expected.update({f"{bus}[{i}]": pin for i, pin in enumerate(pins)})
    assert ports == set(expected) == set(locations) == set(standards)
    assert locations == expected
    assert len(set(locations.values())) == len(ports) == 23
    print("PASS: 23 unique pins, all top-level ports assigned with 3.3-V LVTTL;")
    print("      device/revision/top match; 9 HDL files and SDC exist.")
    print("Static checks only: HDL compilation, simulation and timing are not checked.")

    pin_report = root / globals_["PROJECT_OUTPUT_DIRECTORY"] / (revision + ".pin")
    if pin_report.is_file():
        fitted = set()
        for line in pin_report.read_text(encoding="utf-8", errors="replace").splitlines():
            fields = [field.strip() for field in line.split(":")]
            if len(fields) != 7 or fields[0] not in ports:
                continue
            name, location, _, standard, _, _, assigned = fields
            assert name not in fitted, f"Duplicate Fitter pin: {name}"
            assert location == str(locations[name]), (
                f"{name}: Fitter uses PIN_{location}, expected PIN_{locations[name]}"
            )
            assert standard == standards[name], f"{name}: Fitter I/O standard is {standard}"
            assert assigned == "Y", f"{name}: Fitter did not apply a user pin assignment"
            fitted.add(name)
        assert fitted == ports, f"Missing Fitter pins: {sorted(ports - fitted)}"
        print("PASS: Fitter report matches all 23 pins, 3.3-V LVTTL, User Assignment=Y.")
    else:
        print("No Fitter .pin report found; actual placement has not been checked.")


if __name__ == "__main__":
    main()
__MATMUL_EMBEDDED_FILE_7__

cat > "$destination/README.md" <<'__MATMUL_EMBEDDED_FILE_8__'
# UART và nhân ma trận — Cyclone IV V3.0

Project dùng FPGA **EP4CE6E22C8**, clock onboard **50 MHz**, Verilog-2001.
Mở **`matmul.qpf`** bằng Quartus Prime Lite 21.1; revision và top-level đều
là **`matmul`**. Không cần thêm file từ hai thư mục tham khảo.

`matmul.qsf` lấy trực tiếp cấu hình device và các gán chân đang dùng từ
**`../Altera-Cyclone-IV-board-V3.0/cyclone_iv_board_v3.qsf`** theo yêu cầu.
Đổi tên `key_n[0..2]` thành `dip1_n`, `dip2_n`, `dip3_n`
(PIN_88, PIN_89, PIN_90). Đây là **ba công tắc DIP vật lý** trên board.
TX dùng **PIN_114** giống `../FPGA-UART-TX/UART_TX.qsf`.
Ví dụ đó chỉ phát TX, không có cổng RX; project bổ sung RX tại
`ext_clk_in/PIN_24` của file board để tránh ngõ ra MAX3232 ở PIN_115.
Các assignment được nhúng vào QSF của project; không cần file board khi
chép project hoặc dùng `create_matmul.sh` trên máy khác. Không import các
ngoại vi không dùng như SDRAM, LCD, VGA hay I2C.

Theo ví dụ board, chỉ **DIG1/PIN_133 (`dig[0]` trong `sled.qsf`)** của cụm LED 7 đoạn
hiển thị số trong mode DIP2; ba digit còn lại luôn tắt. LED báo mode là
**LED nhỏ LED1/PIN_87 cho DIP1, LED2/PIN_86 cho DIP2, LED3/PIN_85 cho DIP3**.
LED nhỏ sáng ở mức 0; trong reset tất cả tắt. LED4 luôn tắt.
Mỗi lần nhập một chữ số **0–9** qua terminal, digit 7 đoạn hiển thị ngay
đúng chữ số đó: nhập `7` thì hiện `7`, nhập tiếp `2` thì thay bằng `2`.
**DIP1 OFF, DIP2 ON, DIP3 OFF** bật chế độ nhận một chữ số. DIG1 hiện `0` ngay khi vào chế độ
này, kể cả chưa nhận UART; không cần nhấn Enter để cập nhật số.

## DIP3: nhập hai ma trận và nhân

Hướng dẫn từng bước và khối **8×8 để copy/paste** nằm trong
[UART_MATRIX_EXAMPLE.md](UART_MATRIX_EXAMPLE.md), kèm kết quả mong đợi.

Đặt DIP1/DIP2 OFF, **DIP3 ON (PIN_90 = 0)**. LED3/PIN_85 sáng,
các LED nhỏ khác và toàn bộ LED 7 đoạn tắt. Chờ FPGA gửi `READY` rồi nhập:

```text
M m k n
các phần tử A, theo từng hàng
các phần tử B, theo từng hàng
```

`m`, `k`, `n` từ **1 đến 8**: A có kích thước m×k, B có kích thước k×n,
C = A×B có kích thước m×n. Nhập đúng m×k số của A trước, tiếp đến k×n số
của B. **Không gửi chữ A/B hoặc dòng mô tả**. Các số là ASCII thập phân,
phân cách bằng dấu cách, Tab, CR hoặc LF; Enter CRLF cũng được.
Phần tử thuộc **−32768…32767**, cho phép dấu `-` hoặc `+` phía trước.
Không nhận dấu phẩy hoặc số thập phân. Số cuối phải kết thúc bằng một
ký tự phân cách, chẳng hạn Enter, để được chấp nhận.

Ví dụ gửi nguyên khối sau, có Enter sau dòng cuối:

```text
M 2 2 2
1 2
3 4
5 6
7 8
```

Kết quả mong đợi trên terminal:

```text
C 2 2
19 22
43 50
READY
```

Không cần lệnh RUN: FPGA tự nhân sau khi nhận đủ B. Các dòng kết quả dùng
CRLF. Kết quả dùng **35 bit có dấu**, đủ chứa tổng 8 tích của số 16 bit,
kể cả giá trị dương 8589934592; không cắt xuống 16/32 bit. Lõi tính dùng
**bốn core song song, tile 4×4**, port từ `../matmul8x8_4core_tile4x4`.
Kết quả được đổi sang ASCII bằng binary-to-BCD tuần tự, không dùng bộ chia.

- Thiếu phần tử: FPGA chờ tiếp. Khi đang nhập, gửi `M` hoặc `m` để bắt đầu
  lại cả header và hai ma trận, không cần reset.
- Sai kích thước, số vượt miền, dấu không kèm chữ số hoặc ký tự không hợp lệ
  trong dữ liệu: FPGA trả `ERR` rồi `READY`. Đợi `READY` trước khi gửi lại.
- **Chỉ gửi một phép nhân mỗi lần, chờ `READY` trước phép tiếp theo.**
  Byte đến khi đang tính hoặc xuất kết quả bị bỏ qua; không có hàng đợi.
- Không echo các phần tử. Có thể bật local echo trên terminal để xem mình gõ.
  Backspace/Delete không chỉnh sửa token trong mode ma trận; dùng `M` để nhập lại.
- Chuyển khỏi DIP3 hoặc nhấn RESET hủy phép đang nhập/tính/xuất. Khi rời mode,
  frame TX hiện tại được gửi hết; bỏ phần kết quả dang dở và chờ `READY` mới
  sau khi quay lại DIP3.

RAM chứa A/B/C không reset từng ô để giữ khả năng dùng block RAM. Bộ đếm và
trạng thái được reset; chỉ tính khi đủ toàn bộ A/B, chỉ xuất khi đã ghi đủ C.
Không xuất nội dung RAM cũ sau reset hoặc sau khi hủy phép nhân.

## Kiến trúc tăng tốc: bốn core, tile 4×4

Đã đọc `README.txt`, bốn module RTL và testbench của repo tham khảo
`../matmul8x8_4core_tile4x4`. Project nhúng các module đã port, không phụ thuộc
đường dẫn repo đó khi biên dịch hoặc chạy `create_matmul.sh` trên máy khác.
Repo tham khảo được giữ nguyên. Bốn file `.sv` được chuyển sang **Verilog-2001
`.v`**: FSM dùng localparam/reg, không dùng logic/always_ff/enum hoặc cast
SystemVerilog; các liên kết giữa core được trải phẳng thành bus.

`matmul` vẫn là top-level của board. `matmul8x8_top` là khối tăng tốc nội bộ,
không gán cổng tile 256 bit ra chân FPGA. Clock, reset ngoài, UART, DIP1/2/3,
LED, GUI và giao thức `M m k n` / `C m n` / `ERR` / `READY` giữ nguyên.

Luồng dữ liệu trong `matrix_uart.v`:

1. Nhận đủ m×k phần tử A và k×n phần tử B. Bộ đệm dùng địa chỉ `8*row+col`.
2. Đọc và đóng gói bốn tile A rồi bốn tile B. Mỗi tile gồm 16 số 16 bit,
   theo hàng; phần tử [0,0] nằm ở 16 bit thấp nhất. Cell ngoài kích thước
   thực được điền **0**, không đọc dữ liệu cũ ở vùng đó.
3. Giữ `load_valid`/payload tới khi `load_ready`, chỉ start khi `start_ready`.
   Engine chỉ cho start sau khi loaded-mask xác nhận đủ bốn tile mỗi ma trận.
4. Bốn core hoạt động theo mạng 2×2: A truyền sang phải, B truyền xuống dưới,
   một hop mỗi clock. Mỗi core có một phép nhân 16×16 và RAM giữ 16 partial sum
   35 bit. Các partial sum được cập nhật qua hai lượt:

   | Core / tile C | Lượt đầu, khởi tạo C | Lượt sau, cộng vào C |
   |---|---|---|
   | Core00 / C00 | A00 × B00 | A01 × B10 |
   | Core01 / C01 | A00 × B01 | A01 × B11 |
   | Core10 / C10 | A10 × B00 | A11 × B10 |
   | Core11 / C11 | A10 × B01 | A11 × B11 |

5. Thu các xung done lệch nhau bằng done-mask trước khi chuyển lượt. Sau
   lượt cuối, accelerator phát 64 kết quả theo hàng. Adapter lưu toàn bộ C,
   chờ done rồi xuất **chỉ m×n** phần tử lên UART như trước.

Ma trận chữ nhật và mọi kích thước 1–8 dùng cùng engine 8×8 qua zero-padding;
không yêu cầu kích thước chia hết cho 4. Ví dụ A 2×3 nhân B 3×1 vẫn gửi
`M 2 3 1` và nhận `C 2 1`. Phần tử mới luôn được nạp đủ trước start.
Reset hoặc rời DIP3 reset control/loaded-mask của accelerator; RAM và các
thanh ghi payload không reset từng ô, được bảo vệ bởi FSM/valid. Lượt đầu
ghi mới tất cả partial sum trước khi tích lũy, nên không dùng C của phép cũ.

Port giữ các thuộc tính ưu tiên M9K và DSP của repo tham khảo. Bộ đệm A/B/C
ở lớp UART cũng dùng cổng RAM đọc đồng bộ không reset payload để hỗ trợ
suy diễn block RAM. **Số DSP/M9K/LE thực tế, khả năng fit EP4CE6E22C8 và
timing 50 MHz chưa được xác nhận**; cần xem báo cáo Quartus sau biên dịch.
Không suy ra mức tăng tốc đã đo từ số core: đóng gói tile và UART 9600 baud
vẫn tốn thời gian; tốc độ truyền có thể chiếm phần lớn tổng thời gian.

`matrix_uart.v` có self-check chỉ dành cho mô phỏng trong
`synthesis translate_off`: kiểm tra địa chỉ kết quả 0…63 và đủ 64 phần tử
trước done. Không đưa thêm testbench vào project. Chưa chạy mô phỏng cho
bản port; kết quả trong `test-results-16bit.txt` của repo tham khảo không
phải kết quả kiểm thử của project này.

**Bản port này thay HDL:** mở lại `matmul.qpf`, biên dịch toàn project,
nạp `output_files/matmul.sof` mới và nhấn/nhả RESET. GUI hiện tại dùng được
với cùng giao thức; không cần đổi file Python để dùng lõi mới.

## Ứng dụng Python / PyQt cho PC

Chạy **`matrix_gui.py`** bằng Python 3.9 trở lên. Ứng dụng dùng
[PyQt5](https://www.riverbankcomputing.com/static/Docs/PyQt5/) cho giao diện
và [pySerial](https://pyserial.readthedocs.io/en/latest/pyserial_api.html)
cho UART. Không cần NumPy; phép nhân Python dùng số nguyên không cắt xuống 32 bit.
Ứng dụng PC dùng cùng giao thức UART với lõi bốn core.

Cài thư viện rồi mở ứng dụng trên Linux:

```sh
cd /home/hoangb/workspace/matmul
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements-gui.txt
python matrix_gui.py
```

1. Bật riêng **DIP3** trước khi kết nối. Đóng terminal serial khác đang dùng
   cùng adapter. Chọn cổng trong danh
   sách hoặc gõ trực tiếp `/dev/ttyUSB0`, `/dev/ttyACM0` hay `COM3`, rồi bấm
   **Kết nối**. UART cố định **9600, 8N1, không flow control**.
   Nếu gặp Permission denied, kiểm tra quyền truy cập thiết bị serial của tài khoản.
2. Ứng dụng tự đồng bộ với FPGA sau khi kết nối. Đợi dòng trạng thái
   **FPGA READY**; khi đó nút **Gửi FPGA và đối chiếu** mới được bật.
   Nếu bật DIP3 sau khi đã kết nối hoặc cần thử lại, bấm **Đồng bộ FPGA**.
   Không cần nhận lại thông báo READY lúc board mới khởi động.
3. Chọn **m, k, n** từ 1–8: A m×k, B k×n, C m×n. Nhập mỗi hàng một dòng,
   cách các số bằng dấu cách hoặc Tab. Các phần tử thuộc **−32768…32767**.
   Thay kích thước giữ nguyên văn bản đang nhập; sửa lại số hàng/cột cho khớp.
4. Hoặc bấm **Mẫu 2×2** hay **Mẫu 8×8** để điền sẵn. Hai nút mẫu thay dữ liệu
   đang nhập. Mẫu 2×2 cho kết quả `19 22 / 43 50`; mẫu 8×8 dùng A = 1–64,
   B là ma trận đơn vị như tài liệu copy/paste.
5. Bấm **Tính Python** để tính mà không cần board. Bấm **Gửi FPGA và đối chiếu**
   để tự tính Python, đóng gói `M m k n` cùng A/B và gửi đủ xuống dòng cuối.
   Không cần copy dữ liệu hoặc nhấn Enter trong terminal.
6. Chờ hai ô kết quả và thông báo **KHỚP** hoặc **KHÔNG KHỚP**. Khi khác nhau,
   ứng dụng báo số ô sai cùng tọa độ ô sai đầu tiên, đánh số từ 1.

Parser tích lũy các mảnh UART qua nhiều lần đọc, kiểm tra `C m n`, đúng số
hàng/cột và miền kết quả 35 bit có dấu. Chỉ công nhận kết quả khi nhận đủ
ma trận **và `READY` cuối**. Nhật ký hiển thị TX/RX để đối chiếu dữ liệu.
Ứng dụng chỉ gửi một yêu cầu tại một thời điểm và khóa ô nhập trong lúc chờ.
UART được đọc không chặn bằng QTimer; dữ liệu gửi thành từng phần nhỏ.

Nút gửi bị mờ có nghĩa là chưa kết nối, đang đồng bộ hoặc đang chờ phép tính.
Ứng dụng đồng bộ bằng lệnh `M 0` kèm LF. Với HDL hiện tại, kích thước 0
không hợp lệ nên FPGA trả `ERR` rồi `READY`; cặp phản hồi này xác nhận UART
và đưa parser FPGA về trạng thái chờ lệnh mới. **ERR ở riêng bước đồng bộ
là phản hồi dự kiến**, không phải lỗi phép nhân. Thao tác đồng bộ hủy dữ liệu
ma trận nhập dở trên board; không cho đồng bộ khi ứng dụng đang chờ phép nhân.
Lệnh đồng bộ này vẫn được parser UART hỗ trợ khi dùng accelerator mới.

Nếu sau 5 giây không nhận đủ cặp phản hồi, ứng dụng báo lỗi đồng bộ và cho
thử lại. Nhật ký chỉ có dòng Kết nối/TX mà không có RX: kiểm tra board đang
chạy SOF có mode DIP3, DIP3 đã ON, đúng adapter và dây **FPGA TX 114 → RX
adapter, FPGA RX 24 ← TX adapter**, cùng GND. Chọn đúng cổng và giữ 9600 8N1.
Nếu FPGA đang xuất một kết quả từ phiên trước, chờ xong rồi bấm Đồng bộ FPGA.

Nếu FPGA trả `ERR`, phản hồi không hợp lệ hoặc hết 15 giây, ứng dụng báo
phép tính thất bại. Bật riêng DIP3 rồi bấm **Đồng bộ FPGA** trước khi thử lại.
Nếu vẫn không có phản hồi, nhấn RESET trên board rồi thử đồng bộ lại.
Rút adapter hoặc ngắt kết nối hủy yêu cầu đang chờ. Nút RESET
trên board vẫn cần thao tác tay; UART không có lệnh reset phần cứng.

File có kiểm tra nhỏ cho xử lý số, phép nhân, định dạng gửi và parser nhận
từng byte, kể cả số âm và kết quả vượt 32 bit. Có thể chạy thủ công bằng
Python chuẩn, không cần PyQt/adapter:

```sh
python3 matrix_gui.py --self-test
```

Theo yêu cầu hiện tại, chưa chạy self-test, mở GUI, cài thư viện hoặc thử
UART thực tế. Các lệnh trên là hướng dẫn để bạn tự chạy.

## Sửa gán chân theo báo cáo Fitter

Báo cáo `.pin` bạn cung cấp cho thấy các cổng bus output bị Fitter tự gán
chân (`User Assignment = N`), trong khi clock, UART và DIP được gán đúng.
Ví dụ:

| Tín hiệu | Chân trong báo cáo sai | Chân board cần dùng |
|---|---|---|
| `led_n[0]` | 84 | 87 |
| `digit_n[0]` | 98 | 133 |
| `seg_n[0]` | 105 | 128 |

Vì vậy DIG1 không nhận tín hiệu chọn digit, còn một số tín hiệu segment
bị đưa sang chân LED nhỏ. Hiện tượng này chưa chứng minh UART không nhận
byte; phải sửa ánh xạ output trước.

QSF hiện dùng tên bus dạng native như các ví dụ vendor, chẳng hạn
`set_location_assignment PIN_133 -to digit_n[0]`, đồng thời ghi rõ
`IO_STANDARD` cho từng bit và mặc định toàn project là `3.3-V LVTTL`.
Các cổng bus output giữ nguyên tên; DIP3 là cổng mới tại PIN_90.

Sau khi biên dịch lại, báo cáo **mới** phải cho thấy:

- `led_n[0..3]`: 87, 86, 85, 84.
- `digit_n[0..3]`: 133, 135, 136, 137.
- `seg_n[0..7]`: 128, 121, 125, 129, 132, 126, 124, 127.
- Tất cả output trên có `3.3-V LVTTL` và **`User Assignment = Y`**.

Các giá trị VCCIO/2.5 V trong báo cáo cũ là cấu hình mà Quartus suy ra cho
bản biên dịch đó, không phải phép đo điện áp nguồn trên PCB.

## Các file

| File | Chức năng |
|---|---|
| `rtl/matmul.v` | Top-level, đồng bộ ba DIP, chống dội, chọn mode và ghép UART |
| `rtl/uart_tx.v` | Phát UART 8N1, lặp byte `0x41` khi được cho phép |
| `rtl/uart_rx.v` | RX theo mẫu `bps_start`/`clk_bps`, đồng bộ đầu vào, xác nhận start và stop |
| `rtl/sevenseg_scan.v` | Giải mã một chữ số trên DIG1, tắt digit trước khi đổi segment |
| `rtl/matrix_uart.v` | Parser UART, đóng gói/đệm 0 tile, điều khiển accelerator và xuất C m×n |
| `rtl/matmul8x8_top.v` | Input tile RAM A/B, loaded-mask, giao diện start/result |
| `rtl/matmul8x8_dataflow.v` | Engine hai lượt, mạng 2×2 core, done-mask và xuất C theo hàng |
| `rtl/tile_c4x4_1dsp.v` | Core tile 4×4, phép nhân có dấu, partial sum 35 bit và forwarding |
| `rtl/tile_bram.v` | RAM lưu bốn tile 4×4, đọc đồng bộ |
| `matmul.qpf`, `matmul.qsf` | Project, revision, device, nguồn và gán chân |
| `matmul.sdc` | Clock và ngoại lệ timing tại biên bất đồng bộ |
| `check_project.py` | Kiểm tra QSF/HDL và đối chiếu chân, I/O, User Assignment của `.pin` nếu có |
| `UART_MATRIX_EXAMPLE.md` | Hướng dẫn từng bước, dữ liệu 8×8 để copy/paste và kết quả mong đợi |
| `matrix_gui.py` | Giao diện PyQt, tính Python, gửi UART, parse và đối chiếu kết quả FPGA |
| `requirements-gui.txt` | Thư viện PyQt5 và pySerial cho ứng dụng PC |

Không kèm testbench trong project. Theo yêu cầu hiện tại, không chạy Icarus
hoặc kiểm thử local cho bản sửa này. QSF chỉ đưa chín file HDL trong `rtl/`
vào tổng hợp.

## Tạo lại project bằng một file shell

File `create_matmul.sh` chứa sẵn nội dung của mười bảy file project trong bản
hiện tại, không cần mạng hoặc thư mục tham khảo để tạo file. Chạy bằng Bash:

```sh
bash /duong/dan/create_matmul.sh ./matmul
```

Không truyền đường dẫn thì mặc định tạo `./matmul` tại thư mục đang đứng.
Thư mục đích phải chưa tồn tại, thư mục cha phải tồn tại. Script từ chối
thư mục đã có để bảo vệ các chỉnh sửa của bạn. Có thể chép riêng script
sang máy Linux khác; script không tự biên dịch hay nạp FPGA. Sau khi tạo,
mở `matmul.qpf`, hoặc chạy `python3 ./matmul/check_project.py` để kiểm tra tĩnh.
Nội dung nhúng là bản chụp tại lúc tạo script; sửa HDL sau đó không tự cập
nhật nội dung script.

## Nối UART theo chân TX của FPGA-UART-TX

Nối TX của FPGA theo đúng ví dụ tại PIN_114. Nếu đã nối TX ở PIN_111,
chuyển dây sang PIN_114; dây RX của FPGA vẫn dùng PIN_24:

| Chức năng | Chân FPGA | Chân đầu nối P1 | USB-to-UART TTL 3.3 V |
|---|---|---|---|
| TX của FPGA | **PIN_114** | **P1 chân 7** | RX của adapter |
| RX của FPGA | **PIN_24** | **P1 chân 34** | TX của adapter |
| GND | GND | P1 chân 1 hoặc 2 | GND |

Cấp nguồn board bằng nguồn của board. Không nối dây VCC/5 V của adapter.
Đây là chân mức logic TTL, không nối tín hiệu điện áp RS-232 từ DB9 vào FPGA.
Số chân FPGA và số chân header khác nhau: **PIN_24 là P1 chân 34**, không
phải P1 chân 24. Xác định đúng chân 1 của P1 trên PCB trước khi đếm chân.
Các chân nguồn nằm gần cuối header, không nối nhầm RX vào nguồn.

`FPGA-UART-TX/UART_TX.qsf` gán `tx` vào PIN_114 và không có RX.
Khối “IO interface” trong schematic V2.1 xác nhận PIN_114 ra P1.7,
PIN_24 ra P1.34. `cyclone_iv_board_v3.qsf` cũng khai báo PIN_24 là
`ext_clk_in`; bảng chân chip xác nhận chân 24 là ngõ vào CLK2.
PIN_24 chỉ nhận dữ liệu UART, clock hệ thống vẫn là PIN_23.

Trong schematic, PIN_114 đồng thời nối **T1IN/U4.11**, là đầu vào MAX3232:
FPGA có thể phát cho RX adapter và đầu vào U4 cùng lúc.
**Không nối TX adapter vào PIN_115**, vì chân đó nối đầu ra **R1OUT/U4.12**.
RX của project dùng PIN_24, không nối MAX3232 trong schematic; không cần
cắt mạch hoặc tháo U4 để dùng đường RX này.
Chưa đo thông mạch trên PCB V3.0 thực tế; kiểm tra đúng nhãn/header nếu PCB
của bạn khác sơ đồ V2.1. Khi dùng, adapter phải giữ RX ở idle mức 1;
nếu để RX rời khỏi adapter, có thể thêm điện trở ngoài 10 kΩ kéo RX lên 3.3 V.

## Chân và cực tính

Tất cả 23 chân dùng **3.3-V LVTTL**, không trùng chân. Các chân không dùng
được đặt **AS INPUT TRI-STATED** theo file board đã chỉ định. Các thiết lập
NCEO, INIT_DONE, DEV_OE và DEV_CLRn lấy theo file đó; DEV_OE/DEV_CLRn tắt
để sử dụng chân 86/87 cho LED. Không đặt `WEAK_PULL_UP_RESISTOR` trong QSF:
Fitter báo lỗi 169057 với thiết lập này ở chân RESET/DIP1. Board có điện trở
kéo lên ngoài cho RESET và các DIP; adapter điều khiển mức idle của UART RX.
QSF cũng đặt `STRATIX_DEVICE_IO_STANDARD` thành `3.3-V LVTTL` để tránh
dùng mặc định 2.5 V cho một cổng chưa có chuẩn I/O riêng. Chân chính xác
vẫn phải được xác nhận bằng báo cáo Fitter, không chỉ dựa vào file nguồn.

| Cổng HDL | Chức năng | Chân FPGA |
|---|---|---|
| `clk_50mhz` | Clock 50 MHz | 23 |
| `reset_n` | Reset, nhấn = 0 | 25 |
| `dip1_n` | DIP1 / KEY1, yêu cầu phát, ON = 0 | 88 |
| `dip2_n` | DIP2 / KEY2, yêu cầu nhận, ON = 0 | 89 |
| `dip3_n` | DIP3 / KEY3, nhân ma trận, ON = 0 | 90 |
| `uart_tx`, `uart_rx` | TX, RX qua P1.7/P1.34 | 114, 24 |
| `led_n[0]` … `led_n[3]` | LED1 … LED4 | 87, 86, 85, 84 |
| `digit_n[0]` … `digit_n[3]` | DIG1 … DIG4 | 133, 135, 136, 137 |
| `seg_n[0]` … `seg_n[7]` | a, b, c, d, e, f, g, dp | 128, 121, 125, 129, 132, 126, 124, 127 |

LED đơn sáng khi xuất 0. LED 7 đoạn common-anode: chọn digit và segment
đều tích cực thấp, `seg_n[7:0] = {dp,g,f,e,d,c,b,a}`. Dấu chấm luôn tắt.

Đối chiếu nguồn tài liệu:

1. `../Altera-Cyclone-IV-board-V3.0/Hardware documentation/Development board pin information.pdf`,
   trang 1–3: clock, reset, KEY/DIP chung chân, LED và LED 7 đoạn khớp bảng
   gán trên; TX là chân UART 114, RX được chủ động đổi sang chân mở rộng 24.
2. `Hardware documentation/Development board schematic diagram V2.1.pdf`,
   khối “Crystal and reset”, “Digital Tube”, “Button, LED, DIP switch”,
   “RS232 Serial port”: reset kéo lên 3.3 V, nút nhấn/DIP kéo xuống GND,
   segment kéo thấp và digit qua transistor PNP 8550.
3. Ví dụ vendor `Peripheral control 01 light 4 LED/led/led1.qsf` xác nhận
   LED1=87 đến LED4=84. Nhãn net LED1…LED4 trong schematic V2.1 đảo thứ tự
   so với bảng chân; project theo bảng chân và ví dụ vendor, không theo tên
   net LED của schematic. Nếu số in trên PCB khác, đổi riêng bốn location
   assignment của `led_n` sau khi thử từng LED.
   Trên schematic V2.1, R30/R31/R32/R33 lần lượt nối các net LED4/LED3/LED2/LED1,
   và khối P3 nối các net đó với PIN_87/86/85/84. Vì vậy tên R33 không đồng
   nghĩa LED1/PIN_87 trong bảng chân. Chưa xác minh thứ tự điện trở trên PCB V3.0.
4. Khối “Digital Tube” vẽ **DIG1 → Q1 → D4 (chân 6 của cụm hiển thị)**,
   **DIG2 → Q2 → D3 (chân 8)**, **DIG3 → Q3 → D2 (chân 9)**,
   **DIG4 → Q4 → D1 (chân 12)**. Vì vậy dùng thứ tự trái sang phải
   **DIG4, DIG3, DIG2, DIG1 = 137, 136, 135, 133**.
   Bản sửa hiện tại dùng **DIG1/PIN_133**, tức `digit_n = 4'b1110`, đúng chỉ số
   `dig[0]` trong ví dụ `sled.qsf`; DIG2–DIG4 luôn tắt. Trên sơ đồ V2.1,
   DIG1 nằm bên phải; chưa xác nhận vị trí thực tế trên PCB V3.0. Bản trước
   chọn DIG4 theo giả định "đầu tiên bên trái"; nay dùng tên DIG1 của board.
   Không đổi chân segment. Nếu thay đổi gán chân QSF,
   cập nhật bảng kỳ vọng tương ứng trong `check_project.py`.
5. `../FPGA-UART-TX/UART_TX.qsf` và `README.md` xác nhận clock chân 23,
   TX chân 114, KEY1 chân 88, LED1–LED4 ở 87–84 và 5208 clock/bit.
   Project giữ các chân đang dùng đó. RX chân 24 là phần bổ sung vì ví dụ
   không có bộ nhận. Mã ví dụ không được sao chép nguyên vì cần bổ sung
   reset, RX và logic tuần tự phù hợp.
6. `Cyclone IV chip/EP4CE6 pin information.pdf`: chân E144 86/87 có chức
   năng tùy chọn DEV_OE/DEV_CLRn; chúng được tắt trong QSF.
   `Dev Board Manual.pdf` yêu cầu các chân chưa dùng ở trạng thái tri-state.
7. `Peripheral control 06 Digital tube static control/sled/sled.v` xác nhận
   mã segment 0–9 là C0, F9, A4, B0, 99, 92, 82, F8, 80, 90; `dig=0000`
   trong ví dụ bật cả bốn digit. Project này chỉ cho phép `1110` hoặc `1111`,
   giữ DIG2–DIG4 tắt. `Peripheral control 16 .../SEG_D.v` cũng dùng mã active-low
   và chọn từng digit bằng `1110`, `1101`, `1011`.

DIP1/KEY1 cùng chân 88, DIP2/KEY2 cùng chân 89, DIP3/KEY3 cùng chân 90.
Không có chức năng độc lập cho ba nút này. Khi DIP tương ứng OFF,
giữ KEY1/KEY2/KEY3 cũng kéo cùng tín hiệu
xuống 0. Chọn theo chữ **ON** in trên DIP: ON = 0, OFF = 1; hướng lên/xuống
phụ thuộc hướng nhìn board.

Giá trị cần thấy ở **các chân FPGA** sau khi chống dội:

| Trạng thái | PIN_87 | PIN_86 | PIN_85 | PIN_84 | Chọn digit |
|---|---|---|---|---|---|
| Giữ RESET | 1 | 1 | 1 | 1 | `1111`, tắt hết |
| Cả ba DIP OFF: chờ | 1 | 1 | 1 | 1 | `1111`, tắt hết |
| Chỉ DIP1 ON: phát | 0 | 1 | 1 | 1 | `1111`, tắt hết |
| DIP2 ON, DIP3 OFF: nhận | 1 | 0 | 1 | 1 | `1110`, chỉ DIG1; `1111` trong khoảng tắt |
| DIP3 ON: ma trận | 1 | 1 | 0 | 1 | `1111`, tắt hết |

PIN_84 luôn xuất mức 1; PIN_85 chỉ kéo thấp trong mode ma trận. Chưa xác nhận
trạng thái thực tế của phiên bản hiện tại trên phần cứng. Nếu hiện tượng
LED sai vẫn còn sau khi nạp SOF mới,
đối chiếu chân trong Pin Planner/Fitter report và đo mức ở PIN_84–87
(hoặc điểm mở rộng tương ứng) trước khi đổi cực tính hay gán chân.

## Hành vi

| DIP1 | DIP2 | DIP3 | LED nhỏ trên board | UART | LED 7 đoạn |
|---|---|---|---|---|---|
| OFF | OFF | OFF | Tất cả tắt | TX idle, không nhận số | Tắt |
| ON | OFF | OFF | LED1/PIN_87 sáng | Gửi `AAAAAA…`, không CR/LF | Tắt |
| Bất kỳ | ON | OFF | LED2/PIN_86 sáng | TX idle, nhận 0–9, không echo | DIG1 hiện `0`, rồi hiện số nhận được |
| Bất kỳ | Bất kỳ | ON | LED3/PIN_85 sáng | Nhập và nhân ma trận, xuất C | Tắt |

Mỗi mode chỉ bật một LED nhỏ. Ưu tiên **DIP3 > DIP2 > DIP1** khi nhiều DIP ON.
Sau hai FF đồng bộ cho mỗi DIP, cả ba mức DIP phải ổn định khoảng
**1.000.000 clock = 20 ms** mới được chấp nhận. Bộ đếm bắt đầu lại nếu có
DIP thay đổi trong thời gian này. TX hoàn tất frame đang chạy trước khi
đổi mode; độ trễ thêm tối đa khoảng **1,042 ms**. Không khởi động frame mới
của mode cũ sau yêu cầu chuyển.

Quy tắc nhập trong mode 2:

- Chỉ nhận ASCII `0`…`9`. Mỗi số mới thay trực tiếp số đang hiển thị:
  nhập `7` → hiện `7`, nhập tiếp `2` → hiện `2`.
- CR (`0x0D`), LF (`0x0A`) hoặc CRLF giữ số hiện tại. Không cần Enter
  sau mỗi số; nhập `7`, Enter → vẫn hiện `7`.
- Backspace (`0x08`) hoặc Delete (`0x7F`) xóa số đang hiện về `0`.
- Ký tự khác bị bỏ qua, giữ số hiện tại. Không xử lý số âm hoặc thập phân.
- Rời chế độ nhận xóa số; bật DIP2 để nhận lại sẽ hiện `0`.

UART chạy **9600 baud, 8 data bits, no parity, 1 stop bit, LSB trước,
idle 1**, không flow control. Bộ đếm dùng **5208 clock/bit**,
tương đương 9600,614 baud, sai số khoảng **+0,0064%**. TX giữ đủ cả stop bit;
giữa các frame liên tiếp có thêm một clock 20 ns ở idle.

RX triển khai theo mẫu bộ nhận bạn cung cấp, chuyển `logic`/`always_ff`
thành `wire`/`reg`/`always` để giữ Verilog-2001. `rx_enable` bật trong
mode DIP2 hoặc DIP3. Hai FF đồng bộ và một FF lưu mức trước phát hiện
cạnh xuống start; `bps_start` khởi động bộ đếm baud nội bộ.
`clk_bps` là **clock enable**, xuất hiện ở giữa mỗi bit; mọi thanh ghi vẫn
dùng clock 50 MHz. Xác nhận start sau 2604 clock, rồi lấy tám data bit LSB
trước và kiểm tra stop, cách nhau 5208 clock. Stop cao tạo `rx_valid` một
clock và byte dữ liệu cho parser tương ứng; stop thấp thì bỏ frame.
Không cần nối thêm module tạo baud hoặc clock khác ở ngoài.

Tất cả logic dùng cạnh lên của clock 50 MHz, không tạo clock chia mới.
Trong mode 2 chỉ bật DIG1. Mỗi khi đổi số: tắt tất cả digit, đợi **5 µs**
cho transistor PNP ngắt, nạp mã segment, đợi thêm **5 µs** rồi bật lại DIG1.
Trong thời gian giữ số, digit sáng liên tục. DIG2–DIG4 luôn xuất mức 1 để tắt;
dấu chấm luôn tắt. Trong chế độ phát, ma trận, chờ hoặc reset,
tất cả digit/segment tắt.

Nhấn RESET kéo thấp gây reset bất đồng bộ. Nhả RESET qua hai FF đồng bộ
trước khi logic hoạt động. Trong reset, TX idle, LED và hiển thị tắt.
Hai FF nhả reset có giá trị power-up bằng 0 cho FPGA, để mạch tự khởi động
qua chuỗi reset khi nạp xong mà không phụ thuộc việc đã nhấn nút RESET.
Sau nhả reset, mạch chờ ba DIP ổn định khoảng 20 ms rồi chọn chế độ theo
bảng trên. Muốn nhận một chữ số, đặt **DIP1 OFF, DIP2 ON, DIP3 OFF**;
LED2 sáng và DIG1 hiện `0`. Muốn nhân ma trận, bật DIP3 và chờ `READY`.
Cần nhấn rồi nhả RESET sau mỗi lần nạp.

## Biên dịch và nạp bằng Quartus Prime Lite 21.1

1. Cài hỗ trợ device **Cyclone IV E**. Mở `matmul.qpf`, kiểm tra revision
   `matmul`, top-level `matmul`, device **EP4CE6E22C8**.
   Nếu Quartus đang mở bản cũ, đóng project, cập nhật lại file QSF từ bản
   sửa này rồi mở lại QPF để đọc lại assignment. Không dùng báo cáo `.pin`
   hoặc SOF của lần biên dịch trước để đánh giá các thay đổi mới.
2. Chọn **Processing → Start Compilation**. Hoặc mở terminal có Quartus
   trong PATH, chuyển vào thư mục này và chạy:

   ```sh
   quartus_sh --flow compile matmul -c matmul
   ```

3. Kiểm tra Compilation Report và TimeQuest: không có Error, latch,
   multiple driver, missing pin, ignored assignment, empty collection
   trong SDC; xem setup/hold và recovery/removal có slack không âm.
   Xác nhận clock `clk_50mhz` là 20 ns. Ngoại lệ SDC chỉ áp dụng từ chân
   bất đồng bộ vào tầng đồng bộ đầu tiên (reset vào hai FF nhả reset),
   và tới các ngõ ra ngoài không có clock thu đồng bộ. Đường giữa hai FF
   và reset nội bộ vẫn được phân tích timing.
   Mở `output_files/matmul.pin`, đối chiếu bảng chân ở trên: `digit_n[0]`
   phải ở 133, `seg_n[0]` ở 128, toàn bộ output phải có `User Assignment=Y`
   và chuẩn 3.3-V LVTTL trước khi nạp SOF.
4. Kết nối USB-Blaster/JTAG đúng chiều theo board. Trong
   **Tools → Programmer**, chọn hardware USB-Blaster, mode **JTAG**,
   Add File **`output_files/matmul.sof`**, đánh dấu **Program/Configure**,
   nhấn **Start**. Không dùng AS để nạp trực tiếp file SOF.
   Sau lần sửa này, cần **biên dịch lại rồi nạp lại SOF**. Mở QPF hoặc chỉ
   chạy script tạo nguồn không thay chương trình đang chạy trong FPGA.
   Trong Programmer, chọn lại đúng SOF vừa biên dịch tại
   `/home/hoangb/workspace/matmul/output_files/matmul.sof` nếu dùng project tại
   đường dẫn gốc; kiểm tra thời gian sửa file mới hơn các nguồn HDL.
5. Nhấn rồi nhả nút **RESET**, chờ DIP ổn định. SOF nạp vào FPGA có tính
   tạm thời; mất nguồn cần nạp lại. Project này không tạo quy trình ghi
   flash EPCS.

## Terminal và thử trên board

Mở đúng COM/tty của adapter; đặt **9600, 8N1, Flow control: None**.
Terminal cần gửi ký tự ngay từng phím; tắt line buffering/local line editing
(trong PuTTY: **Local line editing → Force off**). Mode 2 không echo:
bật **Local echo → Force on** nếu muốn nhìn ký tự mình gõ trên PC.
Local echo không thay đổi dữ liệu FPGA nhận hay số trên LED.

1. **DIP1 ON, DIP2/DIP3 OFF:** sau khoảng 20 ms LED1 sáng, LED khác tắt, toàn bộ LED
   7 đoạn tắt. PC nhận `AAAAAA…` liên tục, không thêm xuống dòng.
2. **DIP1/DIP3 OFF, DIP2 ON:** sau chống dội và frame TX cuối, LED2 sáng,
   terminal dừng nhận `A`, DIG1 hiện `0` ngay cả trước khi PC gửi dữ liệu.
   Ba digit còn lại tắt. Nếu DIG1 chưa hiện `0`, mạch chưa ở trạng thái nhận
   hoặc phần hiển thị/nạp FPGA chưa hoạt động đúng; chưa thể quy cho parser.
   Chờ ít nhất 1 ms trước khi gõ.
3. Gõ riêng từng số `0` đến `9`: mỗi lần DIG1 hiện đúng số vừa gõ,
   không cần Enter. Gõ `7`, Enter → giữ `7`; gõ `2` → hiện `2`.
   Thử terminal gửi Enter dưới dạng CR, LF rồi CRLF.
4. Gõ `7`, Backspace → hiện `0`; gõ `2`, Delete → hiện `0`.
   Nếu phím Delete gửi chuỗi escape thay vì byte `0x7F`, dùng tính năng
   gửi byte của terminal để thử đúng mã. Chỉ các byte `0x08`/`0x7F` mới xóa.
5. Gửi `abc!?` → số giữ nguyên. Kiểm tra `0`…`9`, dấu chấm tắt,
   chỉ DIG1 sáng, ba vị trí còn lại tắt. Các LED nhỏ
   báo mode, không dùng digit 7 đoạn làm đèn báo mode.
6. **DIP3 ON:** LED3 sáng, toàn bộ LED 7 đoạn tắt, PC nhận `READY`.
   Gửi ví dụ 2×2 ở đầu tài liệu; đối chiếu `19 22` và `43 50`, rồi `READY`.
   Có thể thử số âm, kích thước chữ nhật và tối đa 8×8. Thử `M 9 1 1`
   kèm Enter để xem `ERR` rồi `READY`.
7. Tắt cả ba DIP → tất cả LED tắt, TX idle. Bật lại riêng DIP2 → DIG1 hiện `0`.
   Thử nhiều DIP ON để kiểm tra ưu tiên DIP3 > DIP2 > DIP1. Thử bật/tắt
   nhanh hơn 20 ms: mode chỉ đổi khi mức mới ổn định đủ thời gian.
   Không dùng KEY1/KEY2/KEY3 như nút riêng.
8. Nhấn giữ RESET: TX idle, tất cả LED tắt; nhả RESET: chờ 20 ms rồi chọn
   lại chế độ theo DIP1/DIP2/DIP3. Trong mode ma trận, đợi `READY` và gửi lại từ `M`.

## Trạng thái bản sửa hiện tại

Theo yêu cầu, **không chạy Icarus, mô phỏng, biên dịch hoặc kiểm thử local**
cho phiên bản HDL/QSF hiện tại. Không có xác nhận hoạt động trên board thật.
Kết quả mô phỏng các bản trước không được dùng để kết luận bản sửa này đạt.

`check_project.py` đã được cập nhật theo gán chân hiện tại và đối chiếu
`output_files/matmul.pin` nếu file đó tồn tại. Công cụ báo lỗi nếu Fitter
tự gán sai chân, dùng sai I/O standard, thiếu cổng hoặc `User Assignment=N`.
Không chuẩn hóa bỏ dấu ngoặc nhọn ở tên cổng QSF khi kiểm tra để tránh
che mất khác biệt tên cổng. Công cụ không chạy trong lần sửa này.
Nếu sau này cần kiểm tra bằng
Python 3.9 trở lên, có thể chạy thủ công:

```sh
python3 check_project.py
```

Kiểm tra tĩnh không thay thế Quartus/TimeQuest hoặc việc nạp và thử trên board.
Chưa xác nhận tài nguyên và timing của lõi bốn core/tile 4×4 trên EP4CE6.
Chưa tạo SOF cho bản sửa này. Cần biên dịch lại project và nạp SOF mới theo
hướng dẫn ở trên; script shell chỉ tạo file nguồn và cấu hình.

Chưa xác minh kết nối và thứ tự LED/digit bằng PCB V3.0 thực tế.
Cần nối **TX=P1.7, RX=P1.34**, rồi biên dịch và nạp SOF mới.
__MATMUL_EMBEDDED_FILE_8__

cat > "$destination/rtl/matrix_uart.v" <<'__MATMUL_EMBEDDED_FILE_9__'
module matrix_uart (
    input  wire       clk,
    input  wire       reset_n,
    input  wire       enable,
    input  wire [7:0] rx_data,
    input  wire       rx_valid,
    output reg  [7:0] tx_data,
    output reg        tx_valid,
    input  wire       tx_ready
);
    localparam [4:0] MESSAGE = 5'd0, WAIT_M = 5'd1,
                     DIM_M = 5'd2, DIM_K = 5'd3, DIM_N = 5'd4,
                     LOAD_A = 5'd5, LOAD_B = 5'd6,
                     TILE_READ = 5'd7, TILE_PACK = 5'd8, TILE_LOAD = 5'd9,
                     HEADER = 5'd10, READ_RESULT = 5'd11, CONVERT_START = 5'd12,
                     CONVERT = 5'd13, SIGN = 5'd14, DIGITS = 5'd15,
                     SEPARATOR = 5'd16, LINE_FEED = 5'd17,
                     CORE_START = 5'd18, CORE_WAIT = 5'd19;
    localparam [55:0] READY_TEXT = "READY\r\n";
    localparam [95:0] ERROR_TEXT = "ERR\r\nREADY\r\n";

    reg [4:0] state;
    reg error_message;
    reg [3:0] message_pos;
    reg [2:0] header_pos;
    reg [3:0] rows_m, inner_k, cols_n;
    reg [2:0] input_row, input_col;
    reg [15:0] magnitude;
    reg negative, token_active, token_digits;

    // Contents become valid only after all required elements have been written.
    (* ramstyle = "M9K" *) reg signed [15:0] matrix_a [0:63];
    (* ramstyle = "M9K" *) reg signed [15:0] matrix_b [0:63];
    (* ramstyle = "M9K" *) reg signed [34:0] matrix_c [0:63];
    reg load_matrix;
    reg [1:0] load_tile;
    reg [3:0] pack_element;
    reg [255:0] tile_data;
    reg [15:0] a_pack_q, b_pack_q;
    wire [2:0] pack_row = {load_tile[1], pack_element[3:2]};
    wire [2:0] pack_col = {load_tile[0], pack_element[1:0]};
    wire [5:0] pack_addr = {pack_row, pack_col};
    wire pack_in_range = load_matrix ? (pack_row < inner_k && pack_col < cols_n) :
                                      (pack_row < rows_m && pack_col < inner_k);
    wire core_load_ready, core_start_ready, core_done, core_result_valid;
    wire [5:0] core_result_addr;
    wire signed [34:0] core_result_data;

    reg [2:0] result_row, result_col;
    reg signed [34:0] result_value;
    reg result_negative;
    reg [34:0] binary_shift;
    reg [43:0] bcd;
    reg [43:0] bcd_adjusted;
    reg [5:0] conversion_left;
    reg [3:0] decimal_pos;
    reg leading_digit;
    integer nibble;

    wire is_digit = (rx_data >= 8'h30 && rx_data <= 8'h39);
    wire is_space = (rx_data == 8'h20 || rx_data == 8'h09 ||
                     rx_data == 8'h0d || rx_data == 8'h0a);
    wire is_m = (rx_data == 8'h4d || rx_data == 8'h6d);
    wire input_state = (state >= DIM_M && state <= LOAD_B);
    wire [3:0] rx_digit = rx_data[3:0];
    wire [15:0] token_value = negative ? (~magnitude + 16'd1) : magnitude;
    wire accept_token = reset_n && enable && rx_valid && is_space && token_active && token_digits;

    // Unreset synchronous RAM ports; FSM/valid signals protect every payload read.
    always @(posedge clk) begin
        if (accept_token && state == LOAD_A)
            matrix_a[{input_row, input_col}] <= token_value;
        if (accept_token && state == LOAD_B)
            matrix_b[{input_row, input_col}] <= token_value;
        if (reset_n && enable && state == TILE_READ && pack_in_range) begin
            if (load_matrix)
                b_pack_q <= matrix_b[pack_addr];
            else
                a_pack_q <= matrix_a[pack_addr];
        end
        if (reset_n && enable && state == CORE_WAIT && core_result_valid)
            matrix_c[core_result_addr] <= core_result_data;
        if (reset_n && enable && state == READ_RESULT)
            result_value <= matrix_c[{result_row, result_col}];
    end

    // Hold the accelerator reset until a complete new A/B pair is available.
    wire core_reset = !reset_n || !enable || input_state || state == MESSAGE || state == WAIT_M;
    matmul8x8_top #(.ELEM_W(16), .ACC_W(35)) u_accelerator (
        .clk(clk), .rst(core_reset),
        .load_valid(state == TILE_LOAD), .load_ready(core_load_ready),
        .load_matrix(load_matrix), .load_tile_id(load_tile), .load_tile_data(tile_data),
        .start(state == CORE_START), .start_ready(core_start_ready), .busy(), .done(core_done),
        .result_valid(core_result_valid), .result_ready(state == CORE_WAIT),
        .result_addr(core_result_addr), .result_data(core_result_data)
    );

    // Binary-to-BCD conversion takes 35 clock enables, without a divider.
    always @* begin
        bcd_adjusted = bcd;
        for (nibble = 0; nibble < 11; nibble = nibble + 1) begin
            if (bcd[nibble * 4 +: 4] >= 4'd5)
                bcd_adjusted[nibble * 4 +: 4] = bcd[nibble * 4 +: 4] + 4'd3;
        end
    end

    always @* begin
        tx_valid = 1'b0;
        tx_data = 8'd0;
        if (enable) begin
            case (state)
                MESSAGE: begin
                    tx_valid = 1'b1;
                    if (error_message)
                        tx_data = ERROR_TEXT[(11 - message_pos) * 8 +: 8];
                    else
                        tx_data = READY_TEXT[(6 - message_pos) * 8 +: 8];
                end
                HEADER: begin
                    tx_valid = 1'b1;
                    case (header_pos)
                        3'd0: tx_data = 8'h43;
                        3'd1: tx_data = 8'h20;
                        3'd2: tx_data = 8'h30 + rows_m;
                        3'd3: tx_data = 8'h20;
                        3'd4: tx_data = 8'h30 + cols_n;
                        3'd5: tx_data = 8'h0d;
                        default: tx_data = 8'h0a;
                    endcase
                end
                SIGN: begin
                    tx_valid = result_negative;
                    tx_data = 8'h2d;
                end
                DIGITS: begin
                    if (leading_digit || bcd[43:40] != 4'd0 || decimal_pos == 4'd0) begin
                        tx_valid = 1'b1;
                        tx_data = 8'h30 + bcd[43:40];
                    end
                end
                SEPARATOR: begin
                    tx_valid = 1'b1;
                    tx_data = (result_col == cols_n - 1'b1) ? 8'h0d : 8'h20;
                end
                LINE_FEED: begin
                    tx_valid = 1'b1;
                    tx_data = 8'h0a;
                end
                default: begin end
            endcase
        end
    end

    // shortcut: RX during compute/output is dropped; add a FIFO for queued requests.
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= MESSAGE;
            error_message <= 1'b0;
            message_pos <= 4'd0;
            header_pos <= 3'd0;
            rows_m <= 4'd0;
            inner_k <= 4'd0;
            cols_n <= 4'd0;
            input_row <= 3'd0;
            input_col <= 3'd0;
            magnitude <= 16'd0;
            negative <= 1'b0;
            token_active <= 1'b0;
            token_digits <= 1'b0;
            load_matrix <= 1'b0;
            load_tile <= 2'd0;
            pack_element <= 4'd0;
            tile_data <= 256'd0;
            result_row <= 3'd0;
            result_col <= 3'd0;
            result_negative <= 1'b0;
            binary_shift <= 35'd0;
            bcd <= 44'd0;
            conversion_left <= 6'd0;
            decimal_pos <= 4'd0;
            leading_digit <= 1'b0;
        end else if (!enable) begin
            state <= MESSAGE;
            error_message <= 1'b0;
            message_pos <= 4'd0;
        end else if (rx_valid && is_m && (state == WAIT_M || input_state)) begin
            state <= DIM_M;
            rows_m <= 4'd0;
            inner_k <= 4'd0;
            cols_n <= 4'd0;
            input_row <= 3'd0;
            input_col <= 3'd0;
            magnitude <= 16'd0;
            negative <= 1'b0;
            token_active <= 1'b0;
            token_digits <= 1'b0;
        end else begin
            case (state)
                MESSAGE: begin
                    if (tx_ready) begin
                        if ((!error_message && message_pos == 4'd6) ||
                            (error_message && message_pos == 4'd11)) begin
                            state <= WAIT_M;
                            magnitude <= 16'd0;
                            negative <= 1'b0;
                            token_active <= 1'b0;
                            token_digits <= 1'b0;
                        end else begin
                            message_pos <= message_pos + 1'b1;
                        end
                    end
                end
                WAIT_M: begin end
                DIM_M, DIM_K, DIM_N, LOAD_A, LOAD_B: begin
                    if (rx_valid) begin
                        if (is_digit) begin
                            if (magnitude > 16'd3276 ||
                                (magnitude == 16'd3276 &&
                                 rx_digit > (negative ? 4'd8 : 4'd7))) begin
                                state <= MESSAGE;
                                error_message <= 1'b1;
                                message_pos <= 4'd0;
                            end else begin
                                magnitude <= (magnitude << 3) + (magnitude << 1) + rx_digit;
                                token_active <= 1'b1;
                                token_digits <= 1'b1;
                            end
                        end else if ((rx_data == 8'h2d || rx_data == 8'h2b) && !token_active) begin
                            negative <= (rx_data == 8'h2d);
                            token_active <= 1'b1;
                        end else if (is_space) begin
                            if (token_active) begin
                                magnitude <= 16'd0;
                                negative <= 1'b0;
                                token_active <= 1'b0;
                                token_digits <= 1'b0;
                                if (!token_digits ||
                                    (state <= DIM_N && (negative || magnitude < 16'd1 || magnitude > 16'd8))) begin
                                    state <= MESSAGE;
                                    error_message <= 1'b1;
                                    message_pos <= 4'd0;
                                end else begin
                                    case (state)
                                        DIM_M: begin
                                            rows_m <= magnitude[3:0];
                                            state <= DIM_K;
                                        end
                                        DIM_K: begin
                                            inner_k <= magnitude[3:0];
                                            state <= DIM_N;
                                        end
                                        DIM_N: begin
                                            cols_n <= magnitude[3:0];
                                            state <= LOAD_A;
                                        end
                                        LOAD_A: begin
                                            if (input_col == inner_k - 1'b1) begin
                                                input_col <= 3'd0;
                                                if (input_row == rows_m - 1'b1) begin
                                                    state <= LOAD_B;
                                                    input_row <= 3'd0;
                                                end else begin
                                                    input_row <= input_row + 1'b1;
                                                end
                                            end else begin
                                                input_col <= input_col + 1'b1;
                                            end
                                        end
                                        LOAD_B: begin
                                            if (input_col == cols_n - 1'b1) begin
                                                input_col <= 3'd0;
                                                if (input_row == inner_k - 1'b1) begin
                                                    load_matrix <= 1'b0;
                                                    load_tile <= 2'd0;
                                                    pack_element <= 4'd0;
                                                    state <= TILE_READ;
                                                end else begin
                                                    input_row <= input_row + 1'b1;
                                                end
                                            end else begin
                                                input_col <= input_col + 1'b1;
                                            end
                                        end
                                        default: begin end
                                    endcase
                                end
                            end
                        end else begin
                            state <= MESSAGE;
                            error_message <= 1'b1;
                            message_pos <= 4'd0;
                        end
                    end
                end
                TILE_READ: begin
                    state <= TILE_PACK;
                end
                TILE_PACK: begin
                    // Out-of-range cells are zero, never stale RAM from the previous request.
                    tile_data[pack_element*16 +: 16] <= !pack_in_range ? 16'd0 :
                                                       load_matrix ? b_pack_q : a_pack_q;
                    if (pack_element == 4'd15)
                        state <= TILE_LOAD;
                    else begin
                        pack_element <= pack_element + 1'b1;
                        state <= TILE_READ;
                    end
                end
                TILE_LOAD: begin
                    if (core_load_ready) begin
                        pack_element <= 4'd0;
                        if (load_tile != 2'd3) begin
                            load_tile <= load_tile + 1'b1;
                            state <= TILE_READ;
                        end else if (!load_matrix) begin
                            load_matrix <= 1'b1;
                            load_tile <= 2'd0;
                            state <= TILE_READ;
                        end else begin
                            state <= CORE_START;
                        end
                    end
                end
                CORE_START: begin
                    if (core_start_ready)
                        state <= CORE_WAIT;
                end
                CORE_WAIT: begin
                    if (core_done) begin
                        header_pos <= 3'd0;
                        state <= HEADER;
                    end
                end
                HEADER: begin
                    if (tx_ready) begin
                        if (header_pos == 3'd6) begin
                            result_row <= 3'd0;
                            result_col <= 3'd0;
                            state <= READ_RESULT;
                        end else begin
                            header_pos <= header_pos + 1'b1;
                        end
                    end
                end
                READ_RESULT: begin
                    state <= CONVERT_START;
                end
                CONVERT_START: begin
                    result_negative <= result_value[34];
                    binary_shift <= result_value[34] ? (~result_value + 35'd1) : result_value;
                    bcd <= 44'd0;
                    conversion_left <= 6'd35;
                    decimal_pos <= 4'd10;
                    leading_digit <= 1'b0;
                    state <= CONVERT;
                end
                CONVERT: begin
                    bcd <= {bcd_adjusted[42:0], binary_shift[34]};
                    binary_shift <= {binary_shift[33:0], 1'b0};
                    conversion_left <= conversion_left - 1'b1;
                    if (conversion_left == 6'd1)
                        state <= SIGN;
                end
                SIGN: begin
                    if (!result_negative || tx_ready)
                        state <= DIGITS;
                end
                DIGITS: begin
                    if (!leading_digit && bcd[43:40] == 4'd0 && decimal_pos != 4'd0) begin
                        bcd <= {bcd[39:0], 4'd0};
                        decimal_pos <= decimal_pos - 1'b1;
                    end else if (tx_ready) begin
                        leading_digit <= 1'b1;
                        if (decimal_pos == 4'd0) begin
                            state <= SEPARATOR;
                        end else begin
                            bcd <= {bcd[39:0], 4'd0};
                            decimal_pos <= decimal_pos - 1'b1;
                        end
                    end
                end
                SEPARATOR: begin
                    if (tx_ready) begin
                        if (result_col == cols_n - 1'b1) begin
                            state <= LINE_FEED;
                        end else begin
                            result_col <= result_col + 1'b1;
                            state <= READ_RESULT;
                        end
                    end
                end
                LINE_FEED: begin
                    if (tx_ready) begin
                        if (result_row == rows_m - 1'b1) begin
                            state <= MESSAGE;
                            error_message <= 1'b0;
                            message_pos <= 4'd0;
                        end else begin
                            result_row <= result_row + 1'b1;
                            result_col <= 3'd0;
                            state <= READ_RESULT;
                        end
                    end
                end
                default: begin
                    state <= MESSAGE;
                    error_message <= 1'b1;
                    message_pos <= 4'd0;
                end
            endcase
        end
    end

    // synthesis translate_off
    reg [6:0] checked_results;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            checked_results <= 7'd0;
        else if (core_reset || state == CORE_START)
            checked_results <= 7'd0;
        else if (state == CORE_WAIT) begin
            if (core_result_valid) begin
                if (checked_results >= 7'd64 || core_result_addr !== checked_results[5:0]) begin
                    $display("ERROR: accelerator result sequence is not 0..63");
                    $stop;
                end
                checked_results <= checked_results + 1'b1;
            end
            if (core_done && checked_results !== 7'd64) begin
                $display("ERROR: accelerator done before all 64 C values were stored");
                $stop;
            end
        end
    end
    // synthesis translate_on
endmodule
__MATMUL_EMBEDDED_FILE_9__

cat > "$destination/UART_MATRIX_EXAMPLE.md" <<'__MATMUL_EMBEDDED_FILE_10__'
# Ví dụ copy/paste: nhân hai ma trận 8×8 qua UART

Ví dụ này dùng A chứa các số 1–64 và B là ma trận đơn vị. Vì C = A×B = A,
bạn có thể đối chiếu kết quả ngay. Tất cả số nhập đều thuộc miền số nguyên
có dấu 16 bit mà project hỗ trợ.

1. Nếu chưa nạp phiên bản có mode ma trận, mở `matmul.qpf`, top-level
   `matmul`, biên dịch rồi nạp `output_files/matmul.sof` bằng USB-Blaster/JTAG.
   Xem hướng dẫn đầy đủ trong [README.md](README.md).
2. Kiểm tra dây: FPGA TX **PIN_114 / P1 chân 7 → RX adapter**;
   FPGA RX **PIN_24 / P1 chân 34 ← TX adapter**; nối chung GND.
   Dùng adapter UART TTL 3.3 V.
3. Mở cổng COM/tty của adapter trong terminal serial. Chọn **9600 baud,
   8 data bits, no parity, 1 stop bit, flow control None**. Gửi dạng
   **Text/ASCII**. Enter có thể gửi CR, LF hoặc CRLF. Nếu dùng PuTTY,
   đặt Local line editing = Force off; có thể bật Local echo = Force on
   để xem dữ liệu mình dán. FPGA không echo dữ liệu nhập.
4. Đặt **DIP1 OFF, DIP2 OFF, DIP3 ON**. Nhấn rồi nhả RESET khi terminal
   đã mở. LED nhỏ PIN_85 sáng; toàn bộ LED 7 đoạn tắt. Chờ dòng `READY`.
5. Copy **toàn bộ khối dưới đây một lần**, dán vào vùng gửi dữ liệu của
   terminal serial, rồi nhấn **Enter sau số cuối**. Nếu terminal có hộp
   soạn dữ liệu riêng, chọn gửi Text/ASCII và gửi nguyên khối kèm xuống
   dòng cuối. Không cần gõ lại từng số hoặc nhấn Enter cho từng hàng.

```text
M 8 8 8
1 2 3 4 5 6 7 8
9 10 11 12 13 14 15 16
17 18 19 20 21 22 23 24
25 26 27 28 29 30 31 32
33 34 35 36 37 38 39 40
41 42 43 44 45 46 47 48
49 50 51 52 53 54 55 56
57 58 59 60 61 62 63 64
1 0 0 0 0 0 0 0
0 1 0 0 0 0 0 0
0 0 1 0 0 0 0 0
0 0 0 1 0 0 0 0
0 0 0 0 1 0 0 0
0 0 0 0 0 1 0 0
0 0 0 0 0 0 1 0
0 0 0 0 0 0 0 1
```

`M 8 8 8` khai báo kích thước. Tám dòng tiếp theo là A, tám dòng cuối là B.
Không gửi thêm chữ A/B, dấu phẩy hoặc dấu bao quanh khối Markdown.
Nếu thao tác paste đã gửi cả xuống dòng cuối, FPGA tự bắt đầu tính ngay;
không cần nhấn thêm Enter hoặc gửi lệnh RUN.

6. Chờ FPGA trả kết quả dưới đây. Nếu bật local echo, dữ liệu bạn vừa
   dán cũng xuất hiện trên terminal; kết quả FPGA bắt đầu bằng `C 8 8`.

```text
C 8 8
1 2 3 4 5 6 7 8
9 10 11 12 13 14 15 16
17 18 19 20 21 22 23 24
25 26 27 28 29 30 31 32
33 34 35 36 37 38 39 40
41 42 43 44 45 46 47 48
49 50 51 52 53 54 55 56
57 58 59 60 61 62 63 64
READY
```

7. Đợi `READY` cuối cùng rồi mới dán phép nhân tiếp theo. Khi muốn thay
   dữ liệu nhưng giữ kích thước 8×8, sửa 64 số của A và 64 số của B trong
   khối gửi, vẫn giữ đúng thứ tự từng hàng và miền **−32768…32767**.

Nếu chưa thấy `READY` ban đầu, kiểm tra cổng serial, DIP3 và phiên bản SOF;
nhấn/nhả RESET khi terminal đang mở để nhận lại thông báo. Nếu thấy `ERR`
rồi `READY`, copy lại nguyên khối dữ liệu. Nếu đang nhập dở và chưa có
kết quả, có thể gửi lại cả khối bắt đầu bằng `M` để bắt đầu lại.

Đây là dữ liệu mẫu và kết quả toán học mong đợi; chưa chạy trên board.
Byte gửi khi FPGA đang tính hoặc xuất kết quả sẽ bị bỏ qua, nên luôn chờ `READY`.
__MATMUL_EMBEDDED_FILE_10__

cat > "$destination/matrix_gui.py" <<'__MATMUL_EMBEDDED_FILE_11__'
#!/usr/bin/env python3
"""PyQt5 UART client for matmul: Python reference and FPGA result comparison."""

import re
import sys
import time


def parse_matrix(text, rows, cols, name):
    lines = [line.split() for line in text.splitlines() if line.strip()]
    if len(lines) != rows:
        raise ValueError(f"{name}: cần {rows} hàng, đang có {len(lines)} hàng.")
    matrix = []
    for r, tokens in enumerate(lines, 1):
        if len(tokens) != cols:
            raise ValueError(f"{name}, hàng {r}: cần {cols} số, đang có {len(tokens)} số.")
        values = []
        for c, token in enumerate(tokens, 1):
            if not re.fullmatch(r"[+-]?[0-9]+", token):
                raise ValueError(f"{name}[{r},{c}]: cần số nguyên thập phân.")
            value = int(token)
            if not -32768 <= value <= 32767:
                raise ValueError(f"{name}[{r},{c}]: số phải thuộc -32768…32767.")
            values.append(value)
        matrix.append(values)
    return matrix


def multiply(a, b):
    return [[sum(a[r][k] * b[k][c] for k in range(len(b)))
             for c in range(len(b[0]))] for r in range(len(a))]


def format_matrix(matrix):
    return "\n".join(" ".join(str(value) for value in row) for row in matrix)


def encode_request(a, b):
    header = f"M {len(a)} {len(b)} {len(b[0])}\n"
    return (header + format_matrix(a) + "\n" + format_matrix(b) + "\n").encode("ascii")


class ResultParser:
    """Accumulate fragmented UART bytes; accept a result only at final READY."""

    def __init__(self):
        self.reset()

    def reset(self):
        self.buffer = bytearray()
        self.expected_shape = None
        self.shape = None
        self.rows = []
        self.syncing = False
        self.sync_error_seen = False

    def synchronize(self):
        self.reset()
        self.syncing = True

    def begin(self, rows, cols):
        self.reset()
        self.expected_shape = (rows, cols)

    def feed(self, data):
        self.buffer.extend(data)
        if len(self.buffer) > 4096:
            raise ValueError("RX quá dài, không có kết quả hợp lệ. Kiểm tra DIP3 và baud rate.")
        events = []
        while b"\n" in self.buffer:
            line, _, remaining = self.buffer.partition(b"\n")
            self.buffer = bytearray(remaining)
            line = line.rstrip(b"\r").decode("ascii").strip()
            if not line:
                continue
            if self.syncing:
                # M 0 intentionally rejects a zero dimension: its reply is ERR then READY.
                if line == "ERR":
                    self.sync_error_seen = True
                elif line == "READY" and self.sync_error_seen:
                    self.syncing = False
                    events.append(("ready", None))
                continue
            if line == "READY":
                if self.expected_shape is not None:
                    if self.shape is None or len(self.rows) != self.shape[0]:
                        raise ValueError("FPGA gửi READY khi kết quả chưa đủ; phép tính có thể đã bị reset.")
                    events.append(("result", self.rows))
                self.expected_shape = None
                self.shape = None
                self.rows = []
                events.append(("ready", None))
            elif line == "ERR":
                self.expected_shape = None
                self.shape = None
                self.rows = []
                events.append(("error", "FPGA trả ERR: dữ liệu bị từ chối."))
            elif line.startswith("C"):
                match = re.fullmatch(r"C\s+([1-8])\s+([1-8])", line)
                if not match or self.expected_shape is None or self.shape is not None:
                    raise ValueError("Header kết quả không hợp lệ hoặc không thuộc phép tính đang chờ.")
                self.shape = (int(match[1]), int(match[2]))
                if self.shape != self.expected_shape:
                    raise ValueError(f"Kích thước FPGA trả {self.shape}, cần {self.expected_shape}.")
            else:
                if self.shape is None or len(self.rows) >= self.shape[0]:
                    raise ValueError("Dữ liệu RX ngoài kết quả ma trận. Bật DIP3 rồi nhấn RESET.")
                tokens = line.split()
                if len(tokens) != self.shape[1] or any(
                    not re.fullmatch(r"[+-]?[0-9]{1,11}", token) for token in tokens
                ):
                    raise ValueError("Hàng kết quả FPGA sai số cột hoặc chứa ký tự không hợp lệ.")
                row = [int(token) for token in tokens]
                if any(not -(1 << 34) <= value < (1 << 34) for value in row):
                    raise ValueError("Kết quả FPGA vượt miền số nguyên có dấu 35 bit.")
                self.rows.append(row)
        return events


def self_check():
    a = parse_matrix("1 2\n3 4", 2, 2, "A")
    b = parse_matrix("5 6\n7 8", 2, 2, "B")
    assert multiply(a, b) == [[19, 22], [43, 50]]
    assert encode_request(a, b) == b"M 2 2 2\n1 2\n3 4\n5 6\n7 8\n"
    assert multiply([[-32768] * 8 for _ in range(8)],
                    [[-32768] * 8 for _ in range(8)]) == [[8589934592] * 8 for _ in range(8)]
    assert multiply([[1, -2, 3]], [[4], [5], [-6]]) == [[-24]]
    for invalid in ("32768", "-32769", "1.5", "1 2", ""):
        try:
            parse_matrix(invalid, 1, 1, "A")
        except ValueError:
            continue
        raise AssertionError(f"Accepted invalid matrix: {invalid!r}")
    parser = ResultParser()
    assert parser.feed(b"REA") == []
    assert parser.feed(b"DY\r\n") == [("ready", None)]
    parser.begin(2, 2)
    events = []
    for byte in b"C 2 2\r\n19 22\r\n43 50\r\nREADY\r\n":
        events.extend(parser.feed(bytes([byte])))
    assert events == [("result", [[19, 22], [43, 50]]), ("ready", None)]
    parser.begin(1, 2)
    assert parser.feed(b"C 1 2\n-8589672448 8589934592\nREADY\n")[0] == (
        "result", [[-8589672448, 8589934592]])
    for reply in (b"C 1 2\n", b"READY\n", b"C 1 1\n1.5\n",
                  b"C 1 1\n17179869184\n", b"C 1 1\n1\n2\n"):
        parser.begin(1, 1)
        try:
            parser.feed(reply)
        except ValueError:
            continue
        raise AssertionError(f"Accepted invalid reply: {reply!r}")
    parser.begin(1, 1)
    assert parser.feed(b"ERR\r\nREADY\r\n") == [
        ("error", "FPGA trả ERR: dữ liệu bị từ chối."), ("ready", None)]
    parser.synchronize()
    assert parser.feed(b"READY\r\nC 1 1\r\n123\r\nREADY\r\nER") == []
    assert parser.syncing
    assert parser.feed(b"R\r\nREA") == []
    assert parser.feed(b"DY\r\n") == [("ready", None)]
    assert not parser.syncing
    parser.begin(1, 1)
    assert parser.feed(b"C 1 1\n0\nREADY\n") == [("result", [[0]]), ("ready", None)]
    print("PASS: matrix validation, signed multiplication, UART framing and result parser.")


def main():
    if sys.argv[1:] == ["--self-test"]:
        self_check()
        return 0
    try:
        import serial
        from serial.tools import list_ports
        from PyQt5.QtCore import Qt, QTimer
        from PyQt5.QtGui import QFontDatabase
        from PyQt5.QtWidgets import (
            QApplication, QComboBox, QGroupBox, QHBoxLayout, QLabel,
            QMainWindow, QMessageBox, QPlainTextEdit, QPushButton,
            QSpinBox, QVBoxLayout, QWidget,
        )
    except ImportError as exc:
        print(f"Thiếu thư viện: {exc}\nCài bằng: python3 -m pip install -r requirements-gui.txt",
              file=sys.stderr)
        return 1

    class MatrixWindow(QMainWindow):
        def __init__(self):
            super().__init__()
            self.setWindowTitle("Nhân ma trận UART — Python / FPGA")
            self.resize(1050, 800)
            self.serial_port = None
            self.parser = ResultParser()
            self.ready = False
            self.pending = False
            self.tx_queue = b""
            self.deadline = 0.0
            self.expected = None

            root = QWidget()
            self.setCentralWidget(root)
            layout = QVBoxLayout(root)
            connection = QHBoxLayout()
            self.port_box = QComboBox()
            self.port_box.setEditable(True)
            self.port_box.setMinimumWidth(200)
            self.refresh_button = QPushButton("Quét cổng")
            self.connect_button = QPushButton("Kết nối")
            self.sync_button = QPushButton("Đồng bộ FPGA")
            connection.addWidget(QLabel("Cổng UART:"))
            connection.addWidget(self.port_box, 1)
            connection.addWidget(self.refresh_button)
            connection.addWidget(self.connect_button)
            connection.addWidget(self.sync_button)
            connection.addWidget(QLabel("9600 baud · 8N1 · Flow control None"))
            layout.addLayout(connection)
            layout.addWidget(QLabel(
                "Bật riêng DIP3; LED nhỏ PIN_85 sáng, LED 7 đoạn tắt. "
                "Ứng dụng tự đồng bộ sau khi kết nối; có thể bấm Đồng bộ FPGA để thử lại."))
            self.status = QLabel("Chưa kết nối. Có thể tính bằng Python khi chưa có board.")
            self.status.setWordWrap(True)
            layout.addWidget(self.status)

            dimensions = QHBoxLayout()
            self.m, self.k, self.n = QSpinBox(), QSpinBox(), QSpinBox()
            for label, spin in (("Hàng A (m)", self.m), ("Cột A / hàng B (k)", self.k),
                                ("Cột B (n)", self.n)):
                spin.setRange(1, 8)
                spin.setValue(2)
                dimensions.addWidget(QLabel(label))
                dimensions.addWidget(spin)
            self.sample2 = QPushButton("Mẫu 2×2")
            self.sample8 = QPushButton("Mẫu 8×8")
            dimensions.addWidget(self.sample2)
            dimensions.addWidget(self.sample8)
            layout.addLayout(dimensions)

            self.a_text, self.b_text = QPlainTextEdit(), QPlainTextEdit()
            self.python_text, self.fpga_text = QPlainTextEdit(), QPlainTextEdit()
            self.python_text.setReadOnly(True)
            self.fpga_text.setReadOnly(True)
            self.a_group = QGroupBox()
            self.b_group = QGroupBox()
            input_row = QHBoxLayout()
            output_row = QHBoxLayout()
            for group, editor, row in (
                (self.a_group, self.a_text, input_row),
                (self.b_group, self.b_text, input_row),
                (QGroupBox("C = A×B — Python"), self.python_text, output_row),
                (QGroupBox("C = A×B — FPGA"), self.fpga_text, output_row),
            ):
                box = QVBoxLayout(group)
                editor.setFont(QFontDatabase.systemFont(QFontDatabase.FixedFont))
                editor.setLineWrapMode(QPlainTextEdit.NoWrap)
                box.addWidget(editor)
                row.addWidget(group)
            layout.addWidget(QLabel("Mỗi hàng một dòng; cách các số bằng dấu cách hoặc Tab. "
                                    "Phần tử: -32768…32767."))
            layout.addLayout(input_row, 2)
            actions = QHBoxLayout()
            self.python_button = QPushButton("Tính Python")
            self.send_button = QPushButton("Gửi FPGA và đối chiếu")
            actions.addWidget(self.python_button)
            actions.addWidget(self.send_button)
            layout.addLayout(actions)
            layout.addLayout(output_row, 2)
            self.comparison = QLabel("Chưa đối chiếu.")
            self.comparison.setWordWrap(True)
            layout.addWidget(self.comparison)
            self.log = QPlainTextEdit()
            self.log.setReadOnly(True)
            self.log.setMaximumBlockCount(300)
            self.log.setMaximumHeight(150)
            layout.addWidget(QLabel("Nhật ký UART:"))
            layout.addWidget(self.log)

            self.refresh_button.clicked.connect(self.refresh_ports)
            self.connect_button.clicked.connect(self.toggle_connection)
            self.sync_button.clicked.connect(self.synchronize_fpga)
            self.python_button.clicked.connect(self.calculate)
            self.send_button.clicked.connect(self.send_request)
            self.sample2.clicked.connect(lambda: self.load_sample(2))
            self.sample8.clicked.connect(lambda: self.load_sample(8))
            for editor in (self.a_text, self.b_text):
                editor.textChanged.connect(self.input_changed)
            for spin in (self.m, self.k, self.n):
                spin.valueChanged.connect(self.input_changed)
            self.timer = QTimer(self)
            self.timer.timeout.connect(self.poll_serial)
            self.timer.start(20)
            self.refresh_ports()
            self.load_sample(2)
            self.update_controls()

        def refresh_ports(self):
            current = self.port_box.currentText().strip()
            self.port_box.clear()
            try:
                for port in sorted(list_ports.comports()):
                    self.port_box.addItem(port.device)
                    self.port_box.setItemData(self.port_box.count() - 1, port.description, Qt.ToolTipRole)
            except (OSError, serial.SerialException) as exc:
                self.status.setText(f"Không quét được cổng: {exc}")
            if current:
                self.port_box.setCurrentText(current)

        def input_changed(self):
            self.a_group.setTitle(f"A — {self.m.value()}×{self.k.value()}")
            self.b_group.setTitle(f"B — {self.k.value()}×{self.n.value()}")
            self.python_text.clear()
            self.fpga_text.clear()
            self.comparison.setText("Dữ liệu đã thay đổi; chưa đối chiếu.")

        def load_sample(self, size):
            for spin in (self.m, self.k, self.n):
                spin.setValue(size)
            if size == 2:
                a, b = [[1, 2], [3, 4]], [[5, 6], [7, 8]]
            else:
                a = [[r * size + c + 1 for c in range(size)] for r in range(size)]
                b = [[int(r == c) for c in range(size)] for r in range(size)]
            self.a_text.setPlainText(format_matrix(a))
            self.b_text.setPlainText(format_matrix(b))

        def calculate(self):
            try:
                a = parse_matrix(self.a_text.toPlainText(), self.m.value(), self.k.value(), "A")
                b = parse_matrix(self.b_text.toPlainText(), self.k.value(), self.n.value(), "B")
            except ValueError as exc:
                QMessageBox.warning(self, "Dữ liệu ma trận chưa hợp lệ", str(exc))
                return None
            result = multiply(a, b)
            self.python_text.setPlainText(format_matrix(result))
            return a, b, result

        def update_controls(self):
            connected = self.serial_port is not None
            self.port_box.setEnabled(not connected)
            self.refresh_button.setEnabled(not connected)
            self.connect_button.setText("Ngắt kết nối" if connected else "Kết nối")
            self.sync_button.setEnabled(connected and not self.pending and not self.parser.syncing)
            self.send_button.setEnabled(connected and self.ready and not self.pending)
            if not connected:
                self.send_button.setToolTip("Chọn cổng UART rồi bấm Kết nối.")
            elif self.pending:
                self.send_button.setToolTip("Đang chờ phép nhân hiện tại hoàn tất, tối đa 15 giây.")
            elif self.parser.syncing:
                self.send_button.setToolTip("Đang chờ FPGA phản hồi bước đồng bộ, tối đa 5 giây.")
            elif not self.ready:
                self.send_button.setToolTip("Bật riêng DIP3 rồi bấm Đồng bộ FPGA; xem nhật ký RX nếu không phản hồi.")
            else:
                self.send_button.setToolTip("Gửi ma trận và đối chiếu với kết quả Python.")
            for widget in (self.a_text, self.b_text, self.m, self.k, self.n,
                           self.sample2, self.sample8, self.python_button):
                widget.setEnabled(not self.pending)

        def toggle_connection(self):
            if self.serial_port is not None:
                self.disconnect_port("Đã ngắt kết nối; phép tính đang chờ đã hủy.")
                return
            port = self.port_box.currentText().strip()
            if not port:
                QMessageBox.warning(self, "Chọn cổng UART", "Chọn hoặc nhập cổng, ví dụ /dev/ttyUSB0 hoặc COM3.")
                return
            try:
                self.serial_port = serial.Serial(
                    port=port, baudrate=9600, bytesize=serial.EIGHTBITS,
                    parity=serial.PARITY_NONE, stopbits=serial.STOPBITS_ONE,
                    timeout=0, write_timeout=0, xonxoff=False, rtscts=False, dsrdtr=False,
                )
            except (OSError, ValueError, serial.SerialException) as exc:
                QMessageBox.warning(self, "Không kết nối được UART", str(exc))
                return
            self.log.appendPlainText(f"Kết nối {port}: 9600 8N1.")
            self.synchronize_fpga()

        def synchronize_fpga(self):
            if self.serial_port is None or self.pending or self.parser.syncing:
                return
            try:
                self.serial_port.reset_input_buffer()
            except (OSError, serial.SerialException) as exc:
                self.disconnect_port(f"Lỗi UART: {exc}. Kiểm tra adapter rồi kết nối lại.")
                return
            self.parser.synchronize()
            self.ready = False
            # Existing HDL accepts M while idle/input; dimension 0 requests a known error reply.
            self.tx_queue = b"M 0\n"
            self.deadline = time.monotonic() + 5.0
            self.status.setText("Đang đồng bộ FPGA (tối đa 5 giây). Bật riêng DIP3 trên board.")
            self.log.appendPlainText("TX đồng bộ: M 0\\n (chờ ERR rồi READY; hủy dữ liệu nhập dở).")
            self.update_controls()

        def disconnect_port(self, message):
            if self.serial_port is not None:
                try:
                    self.serial_port.close()
                except (OSError, serial.SerialException):
                    pass
            self.serial_port = None
            self.ready = False
            self.pending = False
            self.tx_queue = b""
            self.expected = None
            self.parser.reset()
            self.status.setText(message)
            self.update_controls()

        def send_request(self):
            if self.serial_port is None or not self.ready or self.pending:
                return
            # Consume already-buffered mode/reset messages before starting another request.
            self.poll_serial()
            if self.serial_port is None or not self.ready:
                return
            calculated = self.calculate()
            if calculated is None:
                return
            a, b, self.expected = calculated
            self.fpga_text.clear()
            self.comparison.setText("Đang chờ kết quả FPGA…")
            self.parser.begin(len(a), len(b[0]))
            self.tx_queue = encode_request(a, b)
            self.ready = False
            self.pending = True
            self.deadline = time.monotonic() + 15.0
            self.log.appendPlainText("TX:\n" + self.tx_queue.decode("ascii"))
            self.status.setText("Đang gửi ma trận và chờ FPGA trả đủ kết quả cùng READY…")
            self.update_controls()

        def protocol_error(self, message):
            self.ready = False
            self.pending = False
            self.tx_queue = b""
            self.expected = None
            self.parser.reset()
            if self.serial_port is not None:
                try:
                    self.serial_port.reset_output_buffer()
                except (OSError, serial.SerialException) as exc:
                    self.disconnect_port(f"Lỗi UART: {exc}")
                    return
            self.status.setText(message + " Bật riêng DIP3 rồi bấm Đồng bộ FPGA. Nếu vẫn lỗi, nhấn RESET và thử lại.")
            self.comparison.setText("Phép tính thất bại; chưa có kết quả để đối chiếu.")
            self.log.appendPlainText("LỖI: " + message)
            self.update_controls()

        def accept_result(self, result):
            self.fpga_text.setPlainText(format_matrix(result))
            differences = [(r + 1, c + 1, self.expected[r][c], value)
                           for r, row in enumerate(result) for c, value in enumerate(row)
                           if value != self.expected[r][c]]
            if differences:
                r, c, expected, actual = differences[0]
                self.comparison.setText(
                    f"KHÔNG KHỚP: {len(differences)} ô khác nhau. "
                    f"Ô [{r},{c}]: Python = {expected}, FPGA = {actual}.")
            else:
                self.comparison.setText("KHỚP: toàn bộ phần tử FPGA bằng kết quả Python.")
            self.pending = False
            self.expected = None

        def poll_serial(self):
            if self.serial_port is None:
                return
            try:
                incoming = self.serial_port.read(min(self.serial_port.in_waiting, 4096))
                if incoming:
                    self.log.appendPlainText("RX: " + repr(incoming.decode("ascii", errors="replace")))
                    try:
                        events = self.parser.feed(incoming)
                    except (ValueError, UnicodeError) as exc:
                        self.protocol_error(str(exc))
                        return
                    for kind, value in events:
                        if kind == "error":
                            self.protocol_error(value)
                            return
                        if kind == "result":
                            self.accept_result(value)
                        elif kind == "ready":
                            self.ready = True
                            self.status.setText("FPGA READY — có thể gửi ma trận.")
                    self.update_controls()
                if self.tx_queue:
                    written = self.serial_port.write(self.tx_queue[:16])
                    self.tx_queue = self.tx_queue[written:]
                if self.parser.syncing and time.monotonic() > self.deadline:
                    self.protocol_error(
                        "Không nhận được ERR/READY sau 5 giây. "
                        "Kiểm tra đúng cổng, SOF có mode DIP3, dây TX/RX và GND.")
                elif self.pending and time.monotonic() > self.deadline:
                    self.protocol_error("Hết 15 giây mà chưa nhận đủ kết quả và READY.")
            except (OSError, serial.SerialException) as exc:
                self.disconnect_port(f"Lỗi UART: {exc}. Kiểm tra adapter rồi kết nối lại.")

        def closeEvent(self, event):
            self.timer.stop()
            self.disconnect_port("Đã đóng kết nối.")
            event.accept()

    app = QApplication(sys.argv)
    window = MatrixWindow()
    window.show()
    return app.exec_()


if __name__ == "__main__":
    sys.exit(main())
__MATMUL_EMBEDDED_FILE_11__

cat > "$destination/requirements-gui.txt" <<'__MATMUL_EMBEDDED_FILE_12__'
PyQt5>=5.15,<6
pyserial>=3.5,<4
__MATMUL_EMBEDDED_FILE_12__

cat > "$destination/rtl/matmul8x8_top.v" <<'__MATMUL_EMBEDDED_FILE_13__'
`timescale 1ns/1ps
`default_nettype none
// Ported from matmul8x8_4core_tile4x4; Verilog-2001 interface/syntax.

// Complete accelerator component, including both input tile_bram instances.
// Wide load port is an INTERNAL FPGA interface, not a board pin assignment.
// Load four A and four B 4x4 tiles before start. Tile ID=2*tile_row+tile_col.
// One start computes all 64 signed C values, streamed in row-major order.
module matmul8x8_top #(
    parameter integer ELEM_W = 16,
    parameter integer ACC_W = 2*ELEM_W+3
) (
    input wire clk, rst,
    input wire load_valid,
    output wire load_ready,
    input wire load_matrix, // 0=A, 1=B
    input wire [1:0] load_tile_id,
    input wire [16*ELEM_W-1:0] load_tile_data,
    input wire start,
    output wire start_ready, busy, done,
    output wire result_valid,
    input wire result_ready,
    output wire [5:0] result_addr,
    output wire signed [ACC_W-1:0] result_data
);
    reg [3:0] loaded_a, loaded_b;
    wire engine_ready;
    wire load_accept = load_valid && load_ready;
    wire engine_start = start && start_ready;
    assign load_ready = !rst && engine_ready;
    // A write has priority over start, including an update to an existing tile.
    assign start_ready = !rst && engine_ready && (&loaded_a) && (&loaded_b) && !load_valid;
    always @(posedge clk) begin
        if (rst) begin loaded_a <= 4'd0; loaded_b <= 4'd0; end
        else if (load_accept) begin
            if (!load_matrix) loaded_a[load_tile_id] <= 1'b1;
            else loaded_b[load_tile_id] <= 1'b1;
        end
    end

    wire a_rd_en, b_rd_en, a_rd_valid, b_rd_valid;
    wire [1:0] a_rd_tile_id, b_rd_tile_id;
    wire [16*ELEM_W-1:0] a_rd_tile_data, b_rd_tile_data;
    tile_bram #(.ELEM_W(ELEM_W)) u_a_bram (
        .clk(clk), .rst(rst), .wr_en(load_accept && !load_matrix),
        .wr_tile_id(load_tile_id), .wr_tile_data(load_tile_data),
        .rd_en(a_rd_en), .rd_tile_id(a_rd_tile_id), .rd_tile_data(a_rd_tile_data), .rd_valid(a_rd_valid)
    );
    tile_bram #(.ELEM_W(ELEM_W)) u_b_bram (
        .clk(clk), .rst(rst), .wr_en(load_accept && load_matrix),
        .wr_tile_id(load_tile_id), .wr_tile_data(load_tile_data),
        .rd_en(b_rd_en), .rd_tile_id(b_rd_tile_id), .rd_tile_data(b_rd_tile_data), .rd_valid(b_rd_valid)
    );
    matmul8x8_dataflow #(.ELEM_W(ELEM_W), .ACC_W(ACC_W)) u_dataflow (
        .clk(clk), .rst(rst), .start(engine_start), .start_ready(engine_ready), .busy(busy), .done(done),
        .a_rd_en(a_rd_en), .a_rd_tile_id(a_rd_tile_id), .a_rd_tile_data(a_rd_tile_data), .a_rd_valid(a_rd_valid),
        .b_rd_en(b_rd_en), .b_rd_tile_id(b_rd_tile_id), .b_rd_tile_data(b_rd_tile_data), .b_rd_valid(b_rd_valid),
        .result_valid(result_valid), .result_ready(result_ready), .result_addr(result_addr), .result_data(result_data)
    );
endmodule
`default_nettype wire
__MATMUL_EMBEDDED_FILE_13__

cat > "$destination/rtl/matmul8x8_dataflow.v" <<'__MATMUL_EMBEDDED_FILE_14__'
`timescale 1ns/1ps
`default_nettype none
// Ported from matmul8x8_4core_tile4x4; Verilog-2001 interface/syntax.

// Full 8x8 matmul, 2x2 physical cores, each core owns C[4x4] and ONE multiplier.
// Two input memories: 4 row-major 4x4 tile words each, element [0,0] at LSB.
// Two waves: C(R,S) = A(R,0)*B(0,S) + A(R,1)*B(1,S).
// Registered tile forwarding: A moves right, B moves down, one hop/clock.
// Wait for every done pulse before injecting the next wave.
module matmul8x8_dataflow #(
    parameter integer ELEM_W = 16,
    parameter integer ACC_W = 2*ELEM_W+3
) (
    input wire clk, rst,
    input wire start,
    output wire start_ready, busy,
    output reg done,
    output wire a_rd_en,
    output wire [1:0] a_rd_tile_id,
    input wire [16*ELEM_W-1:0] a_rd_tile_data,
    input wire a_rd_valid,
    output wire b_rd_en,
    output wire [1:0] b_rd_tile_id,
    input wire [16*ELEM_W-1:0] b_rd_tile_data,
    input wire b_rd_valid,
    output wire result_valid,
    input wire result_ready,
    output wire [5:0] result_addr,
    output wire signed [ACC_W-1:0] result_data
);
    localparam [2:0] IDLE = 3'd0, FETCH_REQ = 3'd1, FETCH_WAIT = 3'd2,
                     INJECT = 3'd3, WAIT_DONE = 3'd4, READ_C = 3'd5, EMIT_C = 3'd6;
    localparam integer TILE_W = 16*ELEM_W;
    reg [2:0] state;
    reg k_block, fetch_slot, inject_cycle;
    reg a_seen, b_seen;
    reg [3:0] done_mask;
    reg [5:0] out_index;
    reg [16*ELEM_W-1:0] a_edge [0:1];
    reg [16*ELEM_W-1:0] b_edge [0:1];
    wire first_chunk = !k_block;
    wire accept_start = start && start_ready;
    wire [3:0] core_start, core_ready, core_busy, core_done, core_forward_valid;
    wire [3:0] core_read_ready, core_read_valid;
    wire [4*ACC_W-1:0] core_read_data;

    assign start_ready = !rst && state == IDLE;
    assign busy = !rst && state != IDLE;
    assign a_rd_en = !rst && state == FETCH_REQ;
    assign b_rd_en = !rst && state == FETCH_REQ;
    assign a_rd_tile_id = {fetch_slot, k_block};
    assign b_rd_tile_id = {k_block, fetch_slot};
    assign result_valid = !rst && state == EMIT_C;
    assign result_addr = out_index;
    wire [1:0] output_core = {out_index[5], out_index[2]};
    assign result_data = core_read_data[output_core*ACC_W +: ACC_W];

    // First read in READ_C. After that, an output handshake prefetches the
    // next scalar on the same edge. No read during an output stall.
    wire want_read = !rst && ((state == READ_C) ||
                         (state == EMIT_C && result_ready && out_index != 6'd63));
    wire [5:0] next_index = state == EMIT_C ? out_index + 6'd1 : out_index;
    wire [1:0] next_core = {next_index[5], next_index[2]};
    wire [3:0] next_dest = {next_index[4:3], next_index[1:0]};

    // A/B responses can arrive at different clocks; one outstanding request
    // per memory and per-response flags prevent recapturing stale payloads.
    always @(posedge clk) begin
        if (!rst && state == FETCH_WAIT) begin
            if (a_rd_valid && !a_seen) a_edge[fetch_slot] <= a_rd_tile_data;
            if (b_rd_valid && !b_seen) b_edge[fetch_slot] <= b_rd_tile_data;
        end
    end
    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            k_block <= 1'b0;
            fetch_slot <= 1'b0;
            inject_cycle <= 1'b0;
            a_seen <= 1'b0;
            b_seen <= 1'b0;
            done_mask <= 4'd0;
            out_index <= 6'd0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                IDLE: if (accept_start) begin
                    k_block <= 1'b0;
                    fetch_slot <= 1'b0;
                    done_mask <= 4'd0;
                    out_index <= 6'd0;
                    state <= FETCH_REQ;
                end
                FETCH_REQ: begin
                    a_seen <= 1'b0;
                    b_seen <= 1'b0;
                    state <= FETCH_WAIT;
                end
                FETCH_WAIT: begin
                    if (a_rd_valid) a_seen <= 1'b1;
                    if (b_rd_valid) b_seen <= 1'b1;
                    if ((a_seen || a_rd_valid) && (b_seen || b_rd_valid)) begin
                        if (fetch_slot) begin
                            // All cores are idle here: initially, or after
                            // their previous-wave done pulses were collected.
                            if (&core_ready) begin
                                inject_cycle <= 1'b0;
                                done_mask <= 4'd0;
                                state <= INJECT;
                            end
                        end else begin
                            fetch_slot <= 1'b1;
                            state <= FETCH_REQ;
                        end
                    end
                end
                INJECT: begin
                    // Row 0 / column 0 at cycle 0, row 1 / column 1 at 1.
                    // Node starts occur at offsets [0,1;1,2].
                    if (inject_cycle) state <= WAIT_DONE;
                    else inject_cycle <= 1'b1;
                end
                WAIT_DONE: begin
                    done_mask <= done_mask | core_done;
                    if (&(done_mask | core_done)) begin
                        if (!k_block) begin
                            k_block <= 1'b1;
                            fetch_slot <= 1'b0;
                            state <= FETCH_REQ;
                        end else begin
                            out_index <= 6'd0;
                            state <= READ_C;
                        end
                    end
                end
                READ_C: if (core_read_ready[next_core]) state <= EMIT_C;
                EMIT_C: if (result_ready) begin
                    if (out_index == 6'd63) begin
                        done <= 1'b1;
                        state <= IDLE;
                    end else begin
                        out_index <= out_index + 6'd1;
                        // Normally ready is always high after WAIT_DONE.
                        if (!core_read_ready[next_core]) state <= READ_C;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end

    wire [6*TILE_W-1:0] a_link;
    wire [6*TILE_W-1:0] b_link;
    wire [5:0] a_valid;
    wire [5:0] b_valid;
    genvar r,c;
    generate
        for (r=0; r<2; r=r+1) begin : G_A_EDGE
            assign a_link[(3*r)*TILE_W +: TILE_W] = a_edge[r];
            assign a_valid[3*r] = !rst && state == INJECT && inject_cycle == (r == 1);
        end
        for (c=0; c<2; c=c+1) begin : G_B_EDGE
            assign b_link[c*TILE_W +: TILE_W] = b_edge[c];
            assign b_valid[c] = !rst && state == INJECT && inject_cycle == (c == 1);
        end
        for (r=0; r<2; r=r+1) begin : G_ROW
            for (c=0; c<2; c=c+1) begin : G_COL
                localparam [1:0] GID=2*r+c;
                assign core_start[GID] = a_valid[3*r+c] && b_valid[2*r+c];
                assign a_valid[3*r+c+1] = core_forward_valid[GID];
                assign b_valid[2*(r+1)+c] = core_forward_valid[GID];
                tile_c4x4_1dsp #(.ELEM_W(ELEM_W), .ACC_W(ACC_W)) core (
                    .clk(clk), .rst(rst), .start(core_start[GID]), .first_chunk(first_chunk),
                    .a_tile_data(a_link[(3*r+c)*TILE_W +: TILE_W]), .b_tile_data(b_link[(2*r+c)*TILE_W +: TILE_W]),
                    .start_ready(core_ready[GID]), .busy(core_busy[GID]), .done(core_done[GID]),
                    .a_forward_data(a_link[(3*r+c+1)*TILE_W +: TILE_W]), .b_forward_data(b_link[(2*(r+1)+c)*TILE_W +: TILE_W]),
                    .forward_valid(core_forward_valid[GID]),
                    .c_rd_en(want_read && next_core == GID), .c_rd_addr(next_dest),
                    .c_rd_ready(core_read_ready[GID]), .c_rd_data(core_read_data[GID*ACC_W +: ACC_W]),
                    .c_rd_valid(core_read_valid[GID])
                );
            end
        end
    endgenerate
endmodule
`default_nettype wire
__MATMUL_EMBEDDED_FILE_14__

cat > "$destination/rtl/tile_c4x4_1dsp.v" <<'__MATMUL_EMBEDDED_FILE_15__'
`timescale 1ns/1ps
`default_nettype none
// Ported from matmul8x8_4core_tile4x4; Verilog-2001 interface/syntax.

// ONE C[4x4] tile, ONE multiplier. Each call performs A[4x4]*B[4x4].
// first_chunk=1: C=A*B; first_chunk=0: C=C+A*B.
// Two calls complete one C tile of an 8x8 matmul. ACC_W=35 for signed16.
// Input tiles are packed row-major, element [0,0] in the LSBs.
module tile_c4x4_1dsp #(
    parameter integer ELEM_W = 16,
    parameter integer ACC_W = 2*ELEM_W+3
) (
    input wire clk, rst,
    input wire start,
    input wire first_chunk,
    input wire [16*ELEM_W-1:0] a_tile_data, b_tile_data,
    output wire start_ready, busy,
    output reg done,

    // Accepted input tiles forwarded from the SAME registers used locally.
    // One-cycle valid pulse; payload remains held until the next start.
    output wire [16*ELEM_W-1:0] a_forward_data, b_forward_data,
    output reg forward_valid,

    // Read one C element while idle. Address = 4*row+column.
    input wire c_rd_en,
    input wire [3:0] c_rd_addr,
    output wire c_rd_ready,
    output wire signed [ACC_W-1:0] c_rd_data,
    output reg c_rd_valid
);
    localparam integer PROD_W = 2*ELEM_W;
    localparam [1:0] IDLE = 2'd0, ISSUE = 2'd1, DRAIN = 2'd2;
    reg [1:0] state;
    reg [16*ELEM_W-1:0] a_buf, b_buf;
    reg [5:0] issue_index;
    reg first_latched, initialized;
    assign a_forward_data = a_buf;
    assign b_forward_data = b_buf;
    wire [1:0] k = issue_index[5:4];
    wire [3:0] dest = issue_index[3:0];
    wire [3:0] a_index = {dest[3:2], k}; // 4*row+k
    wire [3:0] b_index = {k, dest[1:0]}; // 4*k+column
    wire signed [ELEM_W-1:0] a_value = $signed(a_buf[a_index*ELEM_W +: ELEM_W]);
    wire signed [ELEM_W-1:0] b_value = $signed(b_buf[b_index*ELEM_W +: ELEM_W]);

    // Block accumulation into uninitialized RAM after reset.
    assign start_ready = !rst && state == IDLE && (first_chunk || initialized);
    assign busy = !rst && state != IDLE;
    wire accept_start = start && start_ready;
    assign c_rd_ready = !rst && state == IDLE && initialized && !start;
    wire accept_read = c_rd_en && c_rd_ready;
    wire issue = !rst && state == ISSUE;

    (* multstyle = "dsp" *) wire signed [PROD_W-1:0] product_comb;
    reg signed [PROD_W-1:0] product;
    reg product_valid, product_first;
    reg [3:0] product_dest;
    wire signed [ACC_W-1:0] product_extended =
        {{(ACC_W-PROD_W){product[PROD_W-1]}}, product};
    assign product_comb = a_value * b_value;

    // 16 partial sums. No memory reset: the first k of first_chunk overwrites
    // every destination before any old value is used for accumulation.
    (* ramstyle = "M9K, no_rw_check" *) reg signed [ACC_W-1:0] c_mem [0:15];
    reg signed [ACC_W-1:0] c_q;
    wire mem_rd_en = issue || accept_read;
    wire [3:0] mem_rd_addr = issue ? dest : c_rd_addr;
    wire mem_wr_en = !rst && product_valid;
    wire signed [ACC_W-1:0] c_next = product_first ? product_extended : c_q + product_extended;
    assign c_rd_data = c_q;

    always @(posedge clk) begin
        if (mem_rd_en) c_q <= c_mem[mem_rd_addr];
        if (mem_wr_en) c_mem[product_dest] <= c_next;
    end
    // Payload registers need no reset; valid/control signals protect them.
    always @(posedge clk) begin
        if (accept_start) begin a_buf <= a_tile_data; b_buf <= b_tile_data; end
        if (issue) product <= product_comb;
    end
    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            issue_index <= 6'd0;
            first_latched <= 1'b0;
            initialized <= 1'b0;
            product_valid <= 1'b0;
            product_first <= 1'b0;
            product_dest <= 4'd0;
            c_rd_valid <= 1'b0;
            done <= 1'b0;
            forward_valid <= 1'b0;
        end else begin
            done <= 1'b0;
            forward_valid <= accept_start;
            c_rd_valid <= accept_read;
            product_valid <= issue;
            if (issue) begin
                product_dest <= dest;
                product_first <= first_latched && k == 2'd0;
            end
            case (state)
                IDLE: if (accept_start) begin
                    first_latched <= first_chunk;
                    initialized <= 1'b0;
                    issue_index <= 6'd0;
                    state <= ISSUE;
                end
                ISSUE: if (issue_index == 6'd63) state <= DRAIN;
                       else issue_index <= issue_index + 6'd1;
                DRAIN: if (product_valid) begin
                    // Last RAM write occurs on this same edge.
                    initialized <= 1'b1;
                    done <= 1'b1;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
__MATMUL_EMBEDDED_FILE_15__

cat > "$destination/rtl/tile_bram.v" <<'__MATMUL_EMBEDDED_FILE_16__'
`timescale 1ns/1ps
`default_nettype none
// Ported from matmul8x8_4core_tile4x4; Verilog-2001 interface/syntax.

// One 8x8 matrix stored as four 4x4 tiles.
// tile_id = 2*tile_row + tile_col; each tile is row-major, first element LSB.
module tile_bram #(
    parameter integer ELEM_W = 16
) (
    input  wire clk,
    input  wire rst,

    input  wire wr_en,
    input  wire [1:0] wr_tile_id,
    input  wire [16*ELEM_W-1:0] wr_tile_data,

    input  wire rd_en,
    input  wire [1:0] rd_tile_id,
    output reg [16*ELEM_W-1:0] rd_tile_data,
    output reg rd_valid
);
    localparam integer TILE_W = 16 * ELEM_W;

    // Quartus attribute for Cyclone IV. A wide word can span multiple M9Ks.
    (* ramstyle = "M9K" *)
    reg [TILE_W-1:0] mem [0:3];

    always @(posedge clk) begin
        if (rst) rd_valid <= 1'b0;
        else     rd_valid <= rd_en;
    end

    // Reset suppresses accesses; it does not clear the RAM contents.
    always @(posedge clk) begin
        if (!rst && wr_en)
            mem[wr_tile_id] <= wr_tile_data;
    end

    always @(posedge clk) begin
        if (!rst && rd_en)
            rd_tile_data <= mem[rd_tile_id];
    end
endmodule

`default_nettype wire
__MATMUL_EMBEDDED_FILE_16__

printf 'Đã tạo 17 file project tại: %s\n' "$destination"
printf 'Mở: %s/matmul.qpf (top-level/revision: matmul).\n' "$destination"
printf 'UART: TX PIN_114/P1.7 -> RX adapter; RX PIN_24/P1.34 <- TX adapter; TTL 3.3 V, GND chung; 9600 8N1.\n'
printf 'DIP3 OFF: DIP1 phát A; DIP2 nhận 0-9 và hiển thị DIG1. DIP2 ưu tiên hơn DIP1.\n'
printf 'DIP3 ON (PIN_90): nhân ma trận 1-8, signed 16 bit; chờ READY rồi gửi M m k n, A và B.\n'
printf 'Sau biên dịch, xem output_files/matmul.pin: DIG1=133, segment a=128, 3.3-V LVTTL, User Assignment=Y.\n'
printf 'Ví dụ 8x8 để copy/paste: %s/UART_MATRIX_EXAMPLE.md\n' "$destination"
printf 'Ứng dụng PC: %s/matrix_gui.py (cài requirements-gui.txt; xem README).\n' "$destination"
printf 'GUI tự đồng bộ khi kết nối; bật DIP3 trước, chờ FPGA READY rồi gửi ma trận.\n'
printf 'Accelerator: 4 core song song, tile 4x4, Verilog-2001; cần biên dịch và nạp SOF mới.\n'
