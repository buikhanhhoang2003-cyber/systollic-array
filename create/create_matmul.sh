#!/usr/bin/env bash
# Tạo project UART hai mode từ nội dung nhúng; cần Bash và các lệnh coreutils.
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

    (* preserve *) reg dip_meta;
    (* preserve *) reg dip_sync;
    always @(posedge clk_50mhz or negedge reset_sync) begin
        if (!reset_sync) begin
            dip_meta <= 1'b1;
            dip_sync <= 1'b1;
        end else begin
            dip_meta <= dip1_n;
            dip_sync <= dip_meta;
        end
    end

    reg [19:0] debounce_count;
    reg requested_rx;
    always @(posedge clk_50mhz or negedge reset_sync) begin
        if (!reset_sync) begin
            debounce_count <= 20'd0;
            requested_rx <= 1'b1;
        end else if (dip_sync == requested_rx) begin
            debounce_count <= 20'd0;
        end else if (debounce_count == 20'd999999) begin
            debounce_count <= 20'd0;
            requested_rx <= dip_sync;
        end else begin
            debounce_count <= debounce_count + 1'b1;
        end
    end

    wire tx_busy;
    reg mode_rx;
    // Finish the current stop bit before entering RX mode.
    always @(posedge clk_50mhz or negedge reset_sync) begin
        if (!reset_sync)
            mode_rx <= 1'b1;
        else if (!requested_rx)
            mode_rx <= 1'b0;
        else if (!tx_busy)
            mode_rx <= 1'b1;
    end

    // {PIN_84, PIN_85, PIN_86, PIN_87}; 0 lights a small onboard LED.
    assign led_n = !reset_sync ? 4'b1111 :
                   mode_rx ? 4'b1101 : 4'b1110;

    uart_tx u_tx (
        .clk(clk_50mhz),
        .reset_n(reset_sync),
        .enable(!mode_rx && !requested_rx),
        .data(8'h41),
        .tx(uart_tx),
        .busy(tx_busy)
    );

    wire [7:0] rx_data;
    wire rx_valid;
    uart_rx u_rx (
        .clk(clk_50mhz),
        .reset_n(reset_sync),
        .rx(uart_rx),
        .data(rx_data),
        .valid(rx_valid)
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
module uart_rx (
    input  wire       clk,
    input  wire       reset_n,
    input  wire       rx,
    output reg  [7:0] data,
    output reg        valid
);
    localparam [12:0] BIT_LAST = 13'd5207;
    localparam [12:0] HALF_LAST = 13'd2603;
    localparam [1:0] IDLE = 2'd0, START = 2'd1,
                     DATA = 2'd2, STOP = 2'd3;

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

    reg [1:0] state;
    reg [12:0] bit_count;
    reg [2:0] bit_index;
    reg [7:0] shift_data;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= IDLE;
            bit_count <= 13'd0;
            bit_index <= 3'd0;
            shift_data <= 8'd0;
            data <= 8'd0;
            valid <= 1'b0;
        end else begin
            valid <= 1'b0;
            // Keep frame synchronization in both modes; the top filters digits.
            case (state)
                IDLE: begin
                    bit_count <= 13'd0;
                    bit_index <= 3'd0;
                    if (rx_previous && !rx_sync)
                        state <= START;
                end
                START: begin
                    if (bit_count == HALF_LAST) begin
                        bit_count <= 13'd0;
                        if (!rx_sync)
                            state <= DATA;
                        else
                            state <= IDLE;
                    end else begin
                        bit_count <= bit_count + 1'b1;
                    end
                end
                DATA: begin
                    if (bit_count == BIT_LAST) begin
                        bit_count <= 13'd0;
                        shift_data[bit_index] <= rx_sync;
                        if (bit_index == 3'd7)
                            state <= STOP;
                        else
                            bit_index <= bit_index + 1'b1;
                    end else begin
                        bit_count <= bit_count + 1'b1;
                    end
                end
                STOP: begin
                    if (bit_count == BIT_LAST) begin
                        bit_count <= 13'd0;
                        state <= IDLE;
                        if (rx_sync) begin
                            data <= shift_data;
                            valid <= 1'b1;
                        end
                    end else begin
                        bit_count <= bit_count + 1'b1;
                    end
                end
                default: begin
                    state <= IDLE;
                    bit_count <= 13'd0;
                    bit_index <= 3'd0;
                    shift_data <= 8'd0;
                    data <= 8'd0;
                end
            endcase
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
# Used ports only; board key_n[0] is named dip1_n in this top-level.
# UART TX matches FPGA-UART-TX/PIN_114; RX uses board ext_clk_in/PIN_24.
# Assignments are embedded so the project remains standalone.
set_global_assignment -name TOP_LEVEL_ENTITY matmul
set_global_assignment -name ORIGINAL_QUARTUS_VERSION 21.1.0
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
set_global_assignment -name VERILOG_INPUT_VERSION VERILOG_2001
set_global_assignment -name VERILOG_FILE rtl/matmul.v
set_global_assignment -name VERILOG_FILE rtl/uart_tx.v
set_global_assignment -name VERILOG_FILE rtl/uart_rx.v
set_global_assignment -name VERILOG_FILE rtl/sevenseg_scan.v
set_global_assignment -name SDC_FILE matmul.sdc

# Device and I/O assignments taken from the board QSF.
set_global_assignment -name FAMILY "Cyclone IV E"
set_global_assignment -name DEVICE EP4CE6E22C8
set_global_assignment -name RESERVE_ALL_UNUSED_PINS "AS INPUT TRI-STATED"
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
set_location_assignment PIN_87 -to {led_n[0]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {led_n[0]}
set_location_assignment PIN_86 -to {led_n[1]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {led_n[1]}
set_location_assignment PIN_85 -to {led_n[2]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {led_n[2]}
set_location_assignment PIN_84 -to {led_n[3]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {led_n[3]}
set_location_assignment PIN_133 -to {digit_n[0]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {digit_n[0]}
set_location_assignment PIN_135 -to {digit_n[1]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {digit_n[1]}
set_location_assignment PIN_136 -to {digit_n[2]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {digit_n[2]}
set_location_assignment PIN_137 -to {digit_n[3]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {digit_n[3]}
set_location_assignment PIN_128 -to {seg_n[0]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {seg_n[0]}
set_location_assignment PIN_121 -to {seg_n[1]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {seg_n[1]}
set_location_assignment PIN_125 -to {seg_n[2]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {seg_n[2]}
set_location_assignment PIN_129 -to {seg_n[3]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {seg_n[3]}
set_location_assignment PIN_132 -to {seg_n[4]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {seg_n[4]}
set_location_assignment PIN_126 -to {seg_n[5]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {seg_n[5]}
set_location_assignment PIN_124 -to {seg_n[6]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {seg_n[6]}
set_location_assignment PIN_127 -to {seg_n[7]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {seg_n[7]}
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
set_false_path -from [get_ports {dip1_n}] -to [get_registers {*dip_meta}]
set_false_path -from [get_ports {uart_rx}] -to [get_registers {*u_rx|rx_meta}]

# LEDs have no capture clock; UART is sampled by an independent PC clock.
# These exceptions end at output pads, leaving all internal paths timed.
set_false_path -to [get_ports {uart_tx led_n[*] digit_n[*] seg_n[*]}]
__MATMUL_EMBEDDED_FILE_6__

cat > "$destination/check_project.py" <<'__MATMUL_EMBEDDED_FILE_7__'
"""Check project files and pin coverage; this does not compile or simulate HDL."""

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
            port = words[3].strip("{}")
            assert port not in locations, port
            locations[port] = int(words[1].removeprefix("PIN_"))
        else:
            assert words[1:4] == ["-name", "IO_STANDARD", "3.3-V LVTTL"], line
            assert words[4] == "-to" and len(words) == 6, line
            port = words[5].strip("{}")
            assert port not in standards, port
            standards[port] = words[3]

    assert globals_["FAMILY"] == "Cyclone IV E"
    assert globals_["DEVICE"] == "EP4CE6E22C8"
    assert globals_["TOP_LEVEL_ENTITY"] == "matmul"
    assert globals_["VERILOG_INPUT_VERSION"] == "VERILOG_2001"
    assert globals_["RESERVE_ALL_UNUSED_PINS"] == "AS INPUT TRI-STATED"
    assert globals_["CYCLONEII_RESERVE_NCEO_AFTER_CONFIGURATION"] == "USE AS REGULAR IO"
    assert globals_["ENABLE_DEVICE_WIDE_RESET"] == "OFF"
    assert globals_["ENABLE_DEVICE_WIDE_OE"] == "OFF"
    revision = re.search(r'PROJECT_REVISION\s*=\s*"([^"]+)"',
                         (root / "matmul.qpf").read_text()).group(1)
    assert revision == "matmul" and (root / (revision + ".qsf")).is_file()
    assert len(sources) == len(set(sources)) == 4
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
    expected = dict(clk_50mhz=23, reset_n=25, dip1_n=88, uart_tx=114, uart_rx=24)
    for bus, pins in [("led_n", [87, 86, 85, 84]),
                      ("digit_n", [133, 135, 136, 137]),
                      ("seg_n", [128, 121, 125, 129, 132, 126, 124, 127])]:
        expected.update({f"{bus}[{i}]": pin for i, pin in enumerate(pins)})
    assert ports == set(expected) == set(locations) == set(standards)
    assert locations == expected
    assert len(set(locations.values())) == len(ports) == 21
    print("PASS: 21 unique pins, all top-level ports assigned with 3.3-V LVTTL;")
    print("      device/revision/top match; 4 HDL files and SDC exist.")
    print("Static checks only: HDL compilation, simulation and timing are not checked.")


if __name__ == "__main__":
    main()
__MATMUL_EMBEDDED_FILE_7__

cat > "$destination/README.md" <<'__MATMUL_EMBEDDED_FILE_8__'
# UART hai mode — Cyclone IV V3.0

Project dùng FPGA **EP4CE6E22C8**, clock onboard **50 MHz**, Verilog-2001.
Mở **`matmul.qpf`** bằng Quartus Prime Lite 21.1; revision và top-level đều
là **`matmul`**. Không cần thêm file từ hai thư mục tham khảo.

`matmul.qsf` lấy trực tiếp cấu hình device và các gán chân đang dùng từ
**`../Altera-Cyclone-IV-board-V3.0/cyclone_iv_board_v3.qsf`** theo yêu cầu.
Đổi tên cổng `key_n[0]` của file board thành `dip1_n` trong top-level.
TX dùng **PIN_114** giống `../FPGA-UART-TX/UART_TX.qsf`.
Ví dụ đó chỉ phát TX, không có cổng RX; project bổ sung RX tại
`ext_clk_in/PIN_24` của file board để tránh ngõ ra MAX3232 ở PIN_115.
Các assignment được nhúng vào QSF của project; không cần file board khi
chép project hoặc dùng `create_matmul.sh` trên máy khác. Không import các
ngoại vi không dùng như SDRAM, LCD, VGA hay I2C.

Theo ví dụ board, chỉ **DIG1/PIN_133 (`dig[0]` trong `sled.qsf`)** của cụm LED 7 đoạn
hiển thị số; ba digit còn lại luôn tắt. LED báo mode là **LED nhỏ LED1/PIN_87
cho mode 1 và LED2/PIN_86 cho mode 2 trên board**, tách biệt với cụm LED
7 đoạn. Cả hai sáng ở mức 0; trong reset cả hai tắt. LED3/LED4 luôn tắt.
Mỗi lần nhập một chữ số **0–9** qua terminal, digit 7 đoạn hiển thị ngay
đúng chữ số đó: nhập `7` thì hiện `7`, nhập tiếp `2` thì thay bằng `2`.
Ban đầu hiện `0`; không cần nhấn Enter để cập nhật.

## Các file

| File | Chức năng |
|---|---|
| `rtl/matmul.v` | Top-level, đồng bộ reset/DIP, chống dội, chọn mode, giữ một chữ số 0–9 |
| `rtl/uart_tx.v` | Phát UART 8N1, lặp byte `0x41` khi được cho phép |
| `rtl/uart_rx.v` | Đồng bộ RX hai FF, xác nhận start, lấy mẫu giữa bit, kiểm tra stop |
| `rtl/sevenseg_scan.v` | Giải mã một chữ số trên DIG1, tắt digit trước khi đổi segment |
| `matmul.qpf`, `matmul.qsf` | Project, revision, device, nguồn và gán chân |
| `matmul.sdc` | Clock và ngoại lệ timing tại biên bất đồng bộ |
| `check_project.py` | Tự kiểm tra tĩnh cổng/chân, I/O, device và file nguồn |

Không kèm testbench trong project. Theo yêu cầu hiện tại, không chạy Icarus
hoặc kiểm thử local cho bản sửa này. QSF chỉ đưa bốn file HDL trong `rtl/`
vào tổng hợp.

## Tạo lại project bằng một file shell

File `create_matmul.sh` chứa sẵn nội dung của chín file project trong bản
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

Tất cả 21 chân dùng **3.3-V LVTTL**, không trùng chân. Các chân không dùng
được đặt **AS INPUT TRI-STATED** theo file board đã chỉ định. Các thiết lập
NCEO, INIT_DONE, DEV_OE và DEV_CLRn lấy theo file đó; DEV_OE/DEV_CLRn tắt
để sử dụng chân 86/87 cho LED. Không đặt `WEAK_PULL_UP_RESISTOR` trong QSF:
Fitter báo lỗi 169057 với thiết lập này ở chân RESET/DIP1. Board có điện trở
kéo lên ngoài cho RESET và DIP1; adapter điều khiển mức idle của UART RX.

| Cổng HDL | Chức năng | Chân FPGA |
|---|---|---|
| `clk_50mhz` | Clock 50 MHz | 23 |
| `reset_n` | Reset, nhấn = 0 | 25 |
| `dip1_n` | DIP1 / KEY1, ON = 0 | 88 |
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

DIP1 và KEY1 cùng chân 88. Không có chức năng KEY1 độc lập; khi DIP1 OFF,
nhấn giữ KEY1 cũng có thể yêu cầu mode 1 sau thời gian chống dội.

Giá trị cần thấy ở **các chân FPGA** sau khi chống dội:

| Trạng thái | PIN_87 | PIN_86 | PIN_85 | PIN_84 | Chọn digit |
|---|---|---|---|---|---|
| Giữ RESET | 1 | 1 | 1 | 1 | `1111`, tắt hết |
| Mode 1, DIP1 ON | 0 | 1 | 1 | 1 | `1111`, tắt hết |
| Mode 2, DIP1 OFF | 1 | 0 | 1 | 1 | `1110`, chỉ DIG1; `1111` trong khoảng tắt |

PIN_85/PIN_84 được xuất mức 1 tường minh, không để tri-state. Chưa xác nhận
trạng thái thực tế của phiên bản hiện tại trên phần cứng. Nếu hiện tượng
LED sai vẫn còn sau khi nạp SOF mới,
đối chiếu chân trong Pin Planner/Fitter report và đo mức ở PIN_84–87
(hoặc điểm mở rộng tương ứng) trước khi đổi cực tính hay gán chân.

## Hành vi

| DIP1 ổn định | LED nhỏ trên board | UART | LED 7 đoạn |
|---|---|---|---|
| ON = 0, mode 1 | LED1 sáng; LED2–4 tắt | Gửi `AAAAAA…`, không CR/LF | Tắt cả digit và segment |
| OFF = 1, mode 2 | LED2 sáng; LED1/3/4 tắt | TX idle = 1, nhận RX, không echo | Digit đầu tiên hiện `0`, mỗi số 0–9 nhận được thay số đang hiện; ba digit còn lại tắt |

Sau hai FF đồng bộ, DIP phải khác mode yêu cầu liên tục **1.000.000 clock
= 20 ms** mới được chấp nhận. Khi chuyển từ mode 1 sang mode 2, TX hoàn tất
frame đang chạy trước khi LED2 sáng và mode 2 có hiệu lực; độ trễ thêm tối
đa khoảng **1,042 ms**. Không khởi động frame mới sau yêu cầu chuyển sang RX.

Quy tắc nhập trong mode 2:

- Chỉ nhận ASCII `0`…`9`. Mỗi số mới thay trực tiếp số đang hiển thị:
  nhập `7` → hiện `7`, nhập tiếp `2` → hiện `2`.
- CR (`0x0D`), LF (`0x0A`) hoặc CRLF giữ số hiện tại. Không cần Enter
  sau mỗi số; nhập `7`, Enter → vẫn hiện `7`.
- Backspace (`0x08`) hoặc Delete (`0x7F`) xóa số đang hiện về `0`.
- Ký tự khác bị bỏ qua, giữ số hiện tại. Không xử lý số âm hoặc thập phân.
- Vào mode 1 xóa số; trở lại mode 2 hiện `0`.

UART chạy **9600 baud, 8 data bits, no parity, 1 stop bit, LSB trước,
idle 1**, không flow control. Bộ đếm dùng **5208 clock/bit**,
tương đương 9600,614 baud, sai số khoảng **+0,0064%**. TX giữ đủ cả stop bit;
giữa các frame liên tiếp có thêm một clock 20 ns ở idle.

RX dùng hai FF đồng bộ và một FF lưu mức trước để phát hiện cạnh xuống
của start bit, tương tự cách phát hiện start trong ví dụ UART board.
Xác nhận start sau nửa bit (2604 clock), lấy mẫu mỗi 5208 clock ở giữa
tám bit dữ liệu và stop bit. Stop thấp thì bỏ frame, trở lại chờ cạnh start.
RX luôn theo dõi khung UART ở cả hai mode; top-level chỉ cập nhật số khi
mode 2 có hiệu lực. Không reset bộ nhận theo công tắc mode và không chờ
thêm một bit idle khi chuyển mode.

Tất cả logic dùng cạnh lên của clock 50 MHz, không tạo clock chia mới.
Trong mode 2 chỉ bật DIG1. Mỗi khi đổi số: tắt tất cả digit, đợi **5 µs**
cho transistor PNP ngắt, nạp mã segment, đợi thêm **5 µs** rồi bật lại DIG1.
Trong thời gian giữ số, digit sáng liên tục. DIG2–DIG4 luôn xuất mức 1 để tắt;
dấu chấm luôn tắt. Trong mode 1/reset, cả bốn digit và toàn bộ segment đều tắt.

Nhấn RESET kéo thấp gây reset bất đồng bộ. Nhả RESET qua hai FF đồng bộ
trước khi logic hoạt động. Trong reset, TX idle, LED và hiển thị tắt.
Hai FF nhả reset có giá trị power-up bằng 0 cho FPGA, để mạch tự khởi động
qua chuỗi reset khi nạp xong mà không phụ thuộc việc đã nhấn nút RESET.
Sau nhả reset, mặc định vào RX/hiện `0`; nếu DIP1 ON, sau khoảng 20 ms
sẽ vào mode 1. Cần nhấn rồi nhả RESET sau mỗi lần nạp.

## Biên dịch và nạp bằng Quartus Prime Lite 21.1

1. Cài hỗ trợ device **Cyclone IV E**. Mở `matmul.qpf`, kiểm tra revision
   `matmul`, top-level `matmul`, device **EP4CE6E22C8**.
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

1. **DIP1 ON:** sau khoảng 20 ms LED1 sáng, LED khác tắt, toàn bộ LED
   7 đoạn tắt. PC nhận `AAAAAA…` liên tục, không thêm xuống dòng.
2. **DIP1 OFF:** sau chống dội và frame TX cuối, LED2 sáng, terminal dừng
   nhận `A`, DIG1 hiện `0`, ba digit còn lại tắt.
   Chờ ít nhất 1 ms trước khi gõ.
3. Gõ riêng từng số `0` đến `9`: mỗi lần DIG1 hiện đúng số vừa gõ,
   không cần Enter. Gõ `7`, Enter → giữ `7`; gõ `2` → hiện `2`.
   Thử terminal gửi Enter dưới dạng CR, LF rồi CRLF.
4. Gõ `7`, Backspace → hiện `0`; gõ `2`, Delete → hiện `0`.
   Nếu phím Delete gửi chuỗi escape thay vì byte `0x7F`, dùng tính năng
   gửi byte của terminal để thử đúng mã. Chỉ các byte `0x08`/`0x7F` mới xóa.
5. Gửi `abc!?` → số giữ nguyên. Kiểm tra `0`…`9`, dấu chấm tắt,
   chỉ DIG1 sáng, ba vị trí còn lại tắt. LED nhỏ LED1/LED2
   báo mode, không dùng digit 7 đoạn làm đèn báo mode.
6. Chuyển ON rồi OFF → hiện `0`. Thử bật/tắt nhanh hơn 20 ms: mode chỉ đổi
   khi mức mới ổn định đủ thời gian. Không dùng KEY1 như nút riêng.
7. Nhấn giữ RESET: TX idle, tất cả LED tắt; nhả RESET: hiện `0` trong RX,
   hoặc tự chuyển sang TX sau chống dội nếu DIP1 vẫn ON.

## Trạng thái bản sửa hiện tại

Theo yêu cầu, **không chạy Icarus, mô phỏng, biên dịch hoặc kiểm thử local**
cho phiên bản HDL/QSF hiện tại. Không có xác nhận hoạt động trên board thật.
Kết quả mô phỏng các bản trước không được dùng để kết luận bản sửa này đạt.

`check_project.py` đã được cập nhật theo gán chân UART mới và bỏ pull-up nội,
nhưng không chạy trong lần sửa này. Nếu sau này cần kiểm tra tĩnh bằng
Python 3.9 trở lên, có thể chạy thủ công:

```sh
python3 check_project.py
```

Kiểm tra tĩnh không thay thế Quartus/TimeQuest hoặc việc nạp và thử trên board.
Chưa tạo SOF cho bản sửa này. Cần biên dịch lại project và nạp SOF mới theo
hướng dẫn ở trên; script shell chỉ tạo file nguồn và cấu hình.

Chưa xác minh kết nối và thứ tự LED/digit bằng PCB V3.0 thực tế.
Cần nối **TX=P1.7, RX=P1.34**, rồi biên dịch và nạp SOF mới.
__MATMUL_EMBEDDED_FILE_8__

printf 'Đã tạo 9 file project tại: %s\n' "$destination"
printf 'Mở: %s/matmul.qpf (top-level/revision: matmul).\n' "$destination"
printf 'UART: TX PIN_114/P1.7 -> RX adapter; RX PIN_24/P1.34 <- TX adapter; TTL 3.3 V, GND chung.\n'
