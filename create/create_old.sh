
#!/bin/sh
# Recreate this project using only mkdir and cat. No downloads required.
# Usage: bash create.sh [destination]
# Or: chmod +x create.sh && ./create.sh [destination]
# Default destination: current directory. Existing project files are overwritten.
set -eu

if [ "$#" -gt 1 ]; then
    printf 'Usage: %s [destination]\n' "$0" >&2
    exit 1
fi
mkdir -p -- "${1:-.}"
cd -- "${1:-.}"
mkdir -p rtl tb quartus

cat > '.gitignore' <<'CREATE_PROJECT_EOF__GITIGNORE'
build/
quartus/db/
quartus/incremental_db/
quartus/output_files/
quartus/*.qws
CREATE_PROJECT_EOF__GITIGNORE

cat > 'README.txt' <<'CREATE_PROJECT_EOF_README_TXT'
MATMUL 8x8 — 15 HARD + 1 LOGIC — BRAM_ACC REVISION
Ngày kiểm tra: 2026-11-06

1. Vì sao có bản sửa này?

Người dùng báo Fitter cần 441 LAB trong khi EP4CE6E22C8 chỉ có 392 LAB.
Thiết kế vượt 49 LAB, bằng 12,5% sức chứa LAB của chip. Log không cung cấp
bảng tài nguyên theo entity, nên chưa thể quy toàn bộ phần vượt cho một module.

Bản trước đã đáp ứng số lượng bộ nhân theo ý định RTL, nhưng điều đó chưa
đủ để bảo đảm toàn bộ mạch vừa FPGA. 64 accumulator signed35 chiếm 2.240 bit
lưu trữ trong thanh ghi; còn có mux đọc/ghi, adder, buffer và logic điều khiển.
Không được quy đổi 2.240 bit thanh ghi thành đúng 2.240 LE tiết kiệm, vì
Quartus còn đóng gói thanh ghi và logic trong các LE/LAB.

Bản BRAM_ACC chuyển 64 partial sum sang RAM và thu gọn mạng chọn đầu ra:

  Thành phần              Bản trước                 Bản BRAM_ACC
  -----------------------------------------------------------------------
  Grid chạy song song     16                        16
  Bộ nhân/grid            1                         1
  Kiểu bộ nhân            15 dsp + G33 logic         Giữ nguyên
  Partial sum/grid        4 thanh ghi signed35      RAM 4 x 35 bit
  Đọc partial sum         Mux 4:1 tổ hợp             Cổng đọc M9K đồng bộ
  Mux truyền C            64:1, rộng 35 bit          16:1, rộng 35 bit
  Input A/B banks         8 bank packed              Giữ nguyên
  Số M9K mục tiêu         8 cho input                8 input + 16 C = 24
  Không stall đầu ra      116 chu kỳ                 116 chu kỳ

EP4CE6 có 30 M9K. Mỗi bank C dùng cấu hình simple dual-port, có thể chứa
word 35 bit trong mode rộng tối đa 36 bit. Mục tiêu 24 M9K còn dư 6 block.
Mỗi bank rất nhỏ nên hiệu suất sử dụng dung lượng RAM thấp; đổi lại giải
phóng logic và thanh ghi. Đây là lựa chọn ưu tiên diện tích trên chip này.

CHƯA CHẠY QUARTUS CHO BẢN MỚI. 24 M9K là dự kiến kiến trúc, không phải kết
quả Fitter. Cần xác nhận RAM inference, LE/LAB, multiplier mapping và timing.

2. Mở đúng phiên bản trong Quartus

Giải nén vào thư mục mới, mở:
  quartus/matmul8x8_15dsp_1logic.qpf

Top vẫn tên matmul8x8_15dsp_1logic để giữ giao diện tích hợp hiện tại.
Không thêm cùng lúc file top/PE cũ và mới vào một project.
Project có bốn file RTL:
  rtl/tiled_bram_bank.sv
  rtl/grid_accum_bram.sv             <-- FILE MỚI, bắt buộc thêm
  rtl/pe_grid2x2_1mac_mixed.sv        <-- đã sửa
  rtl/matmul8x8_15dsp_1logic.sv       <-- đã sửa

Nếu cập nhật project hiện tại, thay ba file RTL cùng tên bằng bản này và
thêm grid_accum_bram.sv; giữ pin/SDC đúng board mà bạn đã thiết lập.
Thêm vào QSF:
  set_global_assignment -name ALLOW_ANY_RAM_SIZE_FOR_RECOGNITION ON

Project đính kèm đã có dòng trên. RAM accumulator dùng thuộc tính:
  (* ramstyle = "M9K, no_rw_check" *)

Chạy Analysis & Synthesis rồi Fitter (hoặc Start Compilation trong GUI).
Trên Linux có thể chạy tổng hợp tại thư mục quartus:
  quartus_map matmul8x8_15dsp_1logic
Trên Windows:
  .\quartus\run_synthesis.ps1

Đọc các báo cáo:
  - Analysis & Synthesis -> RAM Summary: 16 bank C rộng35, depth4 cần được
    suy luận thành RAM; ngoài ra là 8 bank A/B rộng32, depth8.
  - Resource Utilization by Entity: so sánh logic/register của các PE.
  - Fitter Resource Usage: số LAB phải không vượt 392; xem số M9K thực tế.
  - Multiplier usage: mục tiêu 15 hard multiplier 18x18; nếu báo theo
    9-bit multiplier elements thì tương đương 30. G33 dùng logic.

Ảnh người dùng gửi là Flow Summary, chưa chứa Resource Utilization by Entity.
Không thể suy ra chính xác từng module chiếm bao nhiêu LE/LAB từ ảnh đó.

3. Pipeline mới không thêm chu kỳ tính

Với mỗi k, cả 16 grid cùng issue dest theo thứ tự 00, 01, 10, 11.

  Cạnh n:
    Đọc RAM C[dest] vào acc_q và chốt A*B vào product.
    Đồng thời có thể ghi kết quả của issue trước vào địa chỉ KHÁC.

  Cạnh n+1:
    Ghi acc_q + product về C[product_dest].
    Với k=0, bỏ qua acc_q cũ, ghi trực tiếp product đầu tiên.

Một địa chỉ C được tái sử dụng sau 4 chu kỳ issue; phép ghi đã hoàn tất
trước lần đọc tiếp theo. Không cần bypass dữ liệu cho cùng địa chỉ.
no_rw_check chỉ cho phép Quartus tự chọn hành vi khi collision; thiết kế
không dựa vào hành vi đó, và testbench báo lỗi nếu collision xảy ra.

Sau k=7, FSM chờ ghi xong. Cạnh thoát DRAIN đọc C[0,0], nên vào WRITE_C
đã có dữ liệu đầu tiên. Mỗi cạnh nhận một kết quả sẽ đọc trước kết quả
kế tiếp từ đúng một bank C. Nếu result_ready=0, không đọc tiếp và giữ ổn
định result_valid/result_addr/result_data. Vẫn xuất 64 ô theo row-major.

Mỗi phép nhân ma trận:
  - 32 chu kỳ issue x 16 multiplier = 512 tích vô hướng.
  - 52 chu kỳ fetch/compute/drain + 64 chu kỳ truyền = 116 chu kỳ nếu
    result_ready luôn bằng 1; không tính thời gian nạp input.
  - Mỗi bank C có 32 lượt đọc cho compute, 32 lần ghi, 4 lượt đọc output.

Lưu ý tradeoff: partial sum giờ có chuyển động dữ liệu nội bộ M9K thêm
512 lần đọc + 512 lần ghi mỗi ma trận. Lợi ích là giảm logic, không phải
giảm mọi loại data movement. Data reuse và số lần đọc A/B giữ nguyên.

4. Lưu A/B và multicast giữ nguyên

DATA_W=16 mặc định, ACC_W=35. A/B signed, không cắt bớt độ chính xác C.
G33 phụ trách C[6,6], C[6,7], C[7,6], C[7,7]. 15 grid còn lại có multstyle
"dsp"; G33 có multstyle "logic". Phải kiểm tra ánh xạ sau tổng hợp.

A bank i, word k = {A[2*i+1][k], A[2*i][k]}.
B bank j, word k = {B[k][2*j+1], B[k][2*j]}.
Một tile 2x2 nằm trong hai word liên tiếp ở địa chỉ 2*t và 2*t+1.
Tile A multicast theo hàng grid, tile B multicast theo cột grid.

Mỗi lần chạy đọc A/B đúng 64 word 32bit = 128 phần tử signed16, tức mỗi
phần tử A/B đúng một lần từ input RAM. Con số này không bao gồm RAM C.
Nạp input vẫn một phần tử/chu kỳ; byte enable giữ nguyên nửa word còn lại.

5. Giao diện và reset

Giao diện top giữ nguyên:
  clk, rst: reset đồng bộ active-high.
  load_valid/load_ready: ghi tại cạnh lên nếu cả hai bằng 1.
  load_matrix: 0=A, 1=B; load_addr=row*8+col; load_data signed16 mặc định.
  start/start_ready: bắt đầu khi cả hai bằng 1, sau khi đủ A/B.
  busy: kéo dài qua giai đoạn xuất kết quả.
  result_valid/result_ready: nhận một ô C tại cạnh lên khi cả hai bằng 1.
  result_addr: 0..63 row-major; result_data signed35 mặc định.
  done: xung một chu kỳ sau cạnh nhận kết quả cuối.

Load chỉ nhận khi idle; load có ưu tiên nếu trùng start. Có thể chạy lại
input đã nạp hoặc sửa riêng từng phần tử rồi chạy lại. Reset hủy tác vụ
và làm mất trạng thái "đã nạp đủ", phải nạp lại toàn bộ A/B sau reset.

KHÁC BẢN TRƯỚC: không reset các partial sum C trong RAM. Chúng được ghi
đè ở k=0 của từng lần chạy, trước mọi phép cộng hoặc output dùng giá trị
đó. Không reset RAM và output register giúp suy luận M9K. Khi result_valid=0,
result_data không có ý nghĩa và có thể là X trong mô phỏng.

6. Kiểm tra đã thực hiện

Icarus Verilog 14.0 (devel), SystemVerilog 2012, -Wall:
  - 124/124 phép nhân ma trận ở DATA_W=16, ACC_W=35.
  - 124/124 ở DATA_W=8, ACC_W=19 (kiểm tra tính tham số).
  - Golden model signed64; kiểm tra từng partial sum của cả 64 ô.
  - Zero, identity, min/max, mixed signs, isolate từng k, isolate G33,
    100 ma trận ngẫu nhiên có seed; update từng packed lane.
  - Reset giữa compute/output; reuse không reload; start khi thiếu input;
    start/load khi busy; backpressure ngẫu nhiên và giữ output đầu/cuối.
  - 16 chunk_done đồng bộ, mỗi A/B input đọc đúng một lần.
  - Không collision RAM C; không dùng partial sum trước khi khởi tạo;
    mỗi grid có đúng 32 compute reads, 32 writes, 4 output reads/run.
  - 116 chu kỳ ở tất cả trường hợp không stall.

Log: test-results-16bit.txt và test-results-8bit.txt.
Chạy trên Windows từ thư mục giải nén:
  .\run_sim.ps1 -Wave
  .\run_sim.ps1 -DataWidth 8

Chạy trên Linux nếu có Icarus Verilog:
  mkdir -p build
  iverilog -g2012 -Wall -s tb_matmul8x8_15dsp_1logic -o build/sim.vvp rtl/*.sv tb/tb_matmul8x8_15dsp_1logic.sv
  vvp build/sim.vvp
  vvp build/sim.vvp +vcd

Archive không chứa simulator/build; waveform được tạo lại khi chạy.

7. Những gì chưa được xác nhận

Chưa có Quartus trong môi trường này: chưa xác nhận fit, LE/LAB, số M9K,
DSP mapping hay Fmax của BRAM_ACC. Không được dùng clock 10ns trong testbench
để kết luận phần cứng đạt 100MHz.

QPF đính kèm phục vụ kiểm tra core và tài nguyên, chưa có SDC và pin của
board. Cần ràng buộc clock/IO đúng hệ thống và chạy TimeQuest trước khi
kết luận timing đạt. Các cảnh báo thiếu SDC/pin khác với lỗi thiếu LAB.
Cảnh báo 10230 do LAST_ISSUE đã được sửa thành hằng 3'd7 đúng độ rộng.
Thông báo 14896 về Advanced Physical Optimization không phải lỗi Fitter.

Nguồn kỹ thuật:
  Cyclone IV product table (EP4CE6: 30 M9K):
    https://cdrdv2-public.intel.com/714186/cyclone-iv-product-table.pdf
  Cyclone IV handbook (M9K simple dual-port hỗ trợ 32/36 bit):
    https://cdrdv2-public.intel.com/653974/cyclone4-handbook.pdf
  Quartus Standard Design Compilation (multstyle, no_rw_check):
    https://www.intel.com/programmable/technical-pdfs/683283.pdf
CREATE_PROJECT_EOF_README_TXT

cat > 'run_sim.ps1' <<'CREATE_PROJECT_EOF_RUN_SIM_PS1'
param(
    [string]$Iverilog = '',
    [string]$Vvp = '',
    [ValidateSet(8, 16)]
    [int]$DataWidth = 16,
    [switch]$Wave
)
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    if (-not $Iverilog) {
        $installedCompiler = Get-Command iverilog -ErrorAction SilentlyContinue
        if ($installedCompiler) {
            $Iverilog = $installedCompiler.Source
        } else {
            # Optional local fallbacks used to verify this project. The
            # source archive itself does not redistribute the simulator.
            $candidates = @(
                (Join-Path ([System.IO.Path]::GetTempPath()) 'codex-iverilog14-01a18841/bin/iverilog.exe'),
                (Join-Path $PSScriptRoot '../../work/tools/iverilog-14/portable/bin/iverilog.exe')
            )
            foreach ($candidate in $candidates) {
                if (Test-Path -LiteralPath $candidate) {
                    $Iverilog = (Resolve-Path -LiteralPath $candidate).Path
                    break
                }
            }
        }
    }
    if (-not $Iverilog) {
        throw 'Icarus Verilog not found. Pass -Iverilog and -Vvp, or add them to PATH.'
    }
    if (-not $Vvp) {
        $compilerLocation = (Get-Command $Iverilog -ErrorAction Stop).Source
        $runtimeName = if ($compilerLocation.EndsWith('.exe')) { 'vvp.exe' } else { 'vvp' }
        $Vvp = Join-Path (Split-Path $compilerLocation -Parent) $runtimeName
    }
    New-Item -ItemType Directory -Path 'build' -Force | Out-Null
    $simFile = "build/matmul8x8_15dsp_1logic_dw$DataWidth.vvp"
    $compilerArgs = @('-g2012', '-Wall', '-s', 'tb_matmul8x8_15dsp_1logic',
        "-Ptb_matmul8x8_15dsp_1logic.DATA_W=$DataWidth", '-o', $simFile,
        'rtl/tiled_bram_bank.sv', 'rtl/grid_accum_bram.sv', 'rtl/pe_grid2x2_1mac_mixed.sv',
        'rtl/matmul8x8_15dsp_1logic.sv', 'tb/tb_matmul8x8_15dsp_1logic.sv')
    # Some portable Windows builds retain a build-machine library prefix.
    $compilerPath = (Get-Command $Iverilog -ErrorAction Stop).Source
    $compilerRoot = Split-Path (Split-Path $compilerPath -Parent) -Parent
    $ivlDir = Join-Path $compilerRoot 'lib/ivl'
    if (Test-Path -LiteralPath (Join-Path $ivlDir 'ivl.exe')) {
        # A relative prefix also avoids an Icarus Windows helper-launch bug
        # when the absolute installation path contains spaces.
        $ivlPrefix = Resolve-Path -LiteralPath $ivlDir -Relative
        $compilerArgs = @('-B', $ivlPrefix) + $compilerArgs
    }
    & $Iverilog @compilerArgs
    if ($LASTEXITCODE -ne 0) { throw 'SystemVerilog compilation failed.' }
    $simArgs = @($simFile)
    if ($Wave) { $simArgs += '+vcd' }
    & $Vvp @simArgs
    if ($LASTEXITCODE -ne 0) { throw 'Simulation failed.' }
} finally {
    Pop-Location
}
CREATE_PROJECT_EOF_RUN_SIM_PS1

cat > 'test-results-16bit.txt' <<'CREATE_PROJECT_EOF_TEST_RESULTS_16BIT_TXT'
VCD info: dumpfile build/matmul8x8_15dsp_1logic_dw16.vcd opened for output.
RTL STYLE PASS: 15 dsp-preferred branches + G33 logic branch (not a physical mapping report)
PASS zero                     cycles=116 issue=32 word_reads=64 scalar_reads=128
PASS identity_signed          cycles=116 issue=32 word_reads=64 scalar_reads=128
PASS reuse_without_reload     cycles=156 issue=32 word_reads=64 scalar_reads=128
PASS minimum_times_minimum    cycles=150 issue=32 word_reads=64 scalar_reads=128
PASS maximum_times_maximum    cycles=116 issue=32 word_reads=64 scalar_reads=128
PASS minimum_times_maximum    cycles=153 issue=32 word_reads=64 scalar_reads=128
PASS mixed_extremes           cycles=156 issue=32 word_reads=64 scalar_reads=128
PASS logic_grid_only          cycles=116 issue=32 word_reads=64 scalar_reads=128
ACCUM RAM PASS: per grid/run 32 compute reads, 32 writes, 4 result reads; zero read/write collisions
ALL PASS: 124 matrix products, DATA_W=16 ACC_W=35, 16 concurrent 1-MAC grids (15 dsp-preferred + 1 logic)
tb/tb_matmul8x8_15dsp_1logic.sv:587: $finish called at 324936000 (1ps)
CREATE_PROJECT_EOF_TEST_RESULTS_16BIT_TXT

cat > 'test-results-8bit.txt' <<'CREATE_PROJECT_EOF_TEST_RESULTS_8BIT_TXT'
RTL STYLE PASS: 15 dsp-preferred branches + G33 logic branch (not a physical mapping report)
PASS zero                     cycles=116 issue=32 word_reads=64 scalar_reads=128
PASS identity_signed          cycles=116 issue=32 word_reads=64 scalar_reads=128
PASS reuse_without_reload     cycles=156 issue=32 word_reads=64 scalar_reads=128
PASS minimum_times_minimum    cycles=150 issue=32 word_reads=64 scalar_reads=128
PASS maximum_times_maximum    cycles=116 issue=32 word_reads=64 scalar_reads=128
PASS minimum_times_maximum    cycles=153 issue=32 word_reads=64 scalar_reads=128
PASS mixed_extremes           cycles=156 issue=32 word_reads=64 scalar_reads=128
PASS logic_grid_only          cycles=116 issue=32 word_reads=64 scalar_reads=128
ACCUM RAM PASS: per grid/run 32 compute reads, 32 writes, 4 result reads; zero read/write collisions
ALL PASS: 124 matrix products, DATA_W=8 ACC_W=19, 16 concurrent 1-MAC grids (15 dsp-preferred + 1 logic)
tb/tb_matmul8x8_15dsp_1logic.sv:587: $finish called at 324936000 (1ps)
CREATE_PROJECT_EOF_TEST_RESULTS_8BIT_TXT

cat > 'rtl/tiled_bram_bank.sv' <<'CREATE_PROJECT_EOF_RTL_TILED_BRAM_BANK_SV'
`timescale 1ns/1ps
`default_nettype none

// One packed word contains TWO signed DATA_W-bit elements.
// A 2x2 tile occupies words 2*t and 2*t+1, not a separate RAM block.
// Default: 8 words x 32 bits, four tiles in one logical bank.
// Scalar writes update only one element via byte enables. No read-modify-write.
// Packed byte lanes follow the Quartus Standard RAM inference template.
module tiled_bram_bank #(
    parameter integer DATA_W = 16, // byte-aligned; validated at 8 and 16
    parameter integer ADDR_W = 3
) (
    input  wire                         clk,
    input  wire                         wr_en,
    input  wire [ADDR_W-1:0]            wr_addr,
    input  wire                         wr_lane, // 0=low element, 1=high
    input  wire signed [DATA_W-1:0]     wr_data,
    input  wire                         rd_en,
    input  wire [ADDR_W-1:0]            rd_addr,
    output logic [2*DATA_W-1:0]         rd_data
);
    localparam integer BYTES_PER_ELEMENT = DATA_W/8;
    localparam integer BYTES_PER_WORD = 2*BYTES_PER_ELEMENT;
    wire [2*DATA_W-1:0] wr_word;
    wire [BYTES_PER_WORD-1:0] wr_byte_en;

    // Duplicate the scalar onto both lanes; enables select which is written.
    assign wr_word = {wr_data, wr_data};
    assign wr_byte_en = wr_lane ?
        {{BYTES_PER_ELEMENT{1'b1}}, {BYTES_PER_ELEMENT{1'b0}}} :
        {{BYTES_PER_ELEMENT{1'b0}}, {BYTES_PER_ELEMENT{1'b1}}};

    (* ramstyle = "M9K" *) logic [BYTES_PER_WORD-1:0][7:0] mem [0:(1<<ADDR_W)-1];

    // synthesis translate_off
    initial begin
        if (DATA_W < 8 || DATA_W%8 != 0)
            $fatal(1, "tiled_bram_bank needs a positive whole-byte DATA_W");
    end
    // synthesis translate_on

    integer byte_index;
    always_ff @(posedge clk) begin
        if (wr_en) begin
            for (byte_index = 0; byte_index < BYTES_PER_WORD; byte_index = byte_index + 1)
                if (wr_byte_en[byte_index])
                    mem[wr_addr][byte_index] <= wr_word[8*byte_index +: 8];
        end
        if (rd_en)
            rd_data <= mem[rd_addr];
    end
    // No reset on RAM or its data register. The top's load masks and FSM
    // prevent uninitialized reads and separate loading from computation.
endmodule

`default_nettype wire
CREATE_PROJECT_EOF_RTL_TILED_BRAM_BANK_SV

cat > 'rtl/grid_accum_bram.sv' <<'CREATE_PROJECT_EOF_RTL_GRID_ACCUM_BRAM_SV'
`timescale 1ns/1ps
`default_nettype none

// Four partial sums for ONE grid, stored in one M9K at ACC_W=35.
// Simple dual-port: one synchronous read and one write per clock.
// The schedule NEVER reads and writes the same address on the same edge.
// no_rw_check prevents requiring emulation of a collision we never use.
// No RAM/output reset: first_step overwrites every destination at k=0.
module grid_accum_bram #(
    parameter integer ACC_W = 35
) (
    input  wire                     clk,
    input  wire                     rd_en,
    input  wire [1:0]               rd_addr,
    output logic signed [ACC_W-1:0] rd_data,
    input  wire                     wr_en,
    input  wire [1:0]               wr_addr,
    input  wire signed [ACC_W-1:0]  wr_data
);
    (* ramstyle = "M9K, no_rw_check" *) logic signed [ACC_W-1:0] mem [0:3];

    always_ff @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
        if (rd_en)
            rd_data <= mem[rd_addr];
    end
endmodule

`default_nettype wire
CREATE_PROJECT_EOF_RTL_GRID_ACCUM_BRAM_SV

cat > 'rtl/pe_grid2x2_1mac_mixed.sv' <<'CREATE_PROJECT_EOF_RTL_PE_GRID2X2_1MAC_MIXED_SV'
`timescale 1ns/1ps
`default_nettype none

// One multiplier/adder shared by FOUR partial sums stored in one M9K.
// For each scalar k, issue dest=0,1,2,3 (C00,C01,C10,C11).
// first_step must be high for ALL FOUR destinations at the first k.
// Stage 1 registers product/destination AND synchronously reads old C.
// Stage 2 adds old C to product and writes that destination to RAM.
// USE_LOGIC_MULT selects a synthesis implementation, NOT extra latency.
// Both branches retain exactly the same product register and RAM schedule.
module pe_grid2x2_1mac_mixed #(
    parameter integer DATA_W = 16,
    parameter integer ACC_W  = 2*DATA_W + 3,
    parameter bit USE_LOGIC_MULT = 1'b0
) (
    input  wire                       clk,
    input  wire                       rst,
    input  wire                       step_valid,
    input  wire                       first_step,
    input  wire                       last_step,
    input  wire [1:0]                 dest,
    input  wire signed [DATA_W-1:0]   a0, a1, b0, b1,
    input  wire                       readout_valid,
    input  wire [1:0]                 readout_dest,
    output wire signed [ACC_W-1:0]    readout_data,
    output logic                      chunk_done
);
    localparam integer PROD_W = 2*DATA_W;
    wire signed [DATA_W-1:0] a_selected = dest[1] ? a1 : a0;
    wire signed [DATA_W-1:0] b_selected = dest[0] ? b1 : b0;
    wire signed [PROD_W-1:0] product_comb;
    logic signed [PROD_W-1:0] product;
    wire signed [ACC_W-1:0] acc_q, acc_next;
    wire signed [ACC_W-1:0] extended_product;
    logic product_valid, product_first, product_last;
    logic [1:0] product_dest;
    wire acc_rd_en = !rst && (step_valid || readout_valid);
    wire [1:0] acc_rd_addr = step_valid ? dest : readout_dest;
    wire acc_wr_en = !rst && product_valid;

    // Quartus applies multstyle to the multiplication directly assigned to
    // the attributed variable. Literal attributes avoid string parameters.
    // "dsp" expresses a mapping preference; inspect the synthesis report.
    generate
        if (USE_LOGIC_MULT) begin : g_logic
            (* multstyle = "logic" *) wire signed [PROD_W-1:0] mult_result;
            assign mult_result = a_selected * b_selected;
            assign product_comb = mult_result;
        end else begin : g_dsp
            (* multstyle = "dsp" *) wire signed [PROD_W-1:0] mult_result;
            assign mult_result = a_selected * b_selected;
            assign product_comb = mult_result;
        end
    endgenerate

    assign extended_product = {{(ACC_W-PROD_W){product[PROD_W-1]}}, product};
    assign acc_next = product_first ? extended_product : acc_q + extended_product;
    assign readout_data = acc_q;

    grid_accum_bram #(.ACC_W(ACC_W)) u_accum (
        .clk(clk), .rd_en(acc_rd_en), .rd_addr(acc_rd_addr), .rd_data(acc_q),
        .wr_en(acc_wr_en), .wr_addr(product_dest), .wr_data(acc_next)
    );

    always_ff @(posedge clk) begin
        if (step_valid && !rst)
            product <= product_comb;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            product_valid <= 1'b0;
            product_first <= 1'b0;
            product_last <= 1'b0;
            product_dest <= 2'd0;
            chunk_done <= 1'b0;
        end else begin
            product_valid <= step_valid;
            chunk_done <= product_valid && product_last;
            if (step_valid) begin
                product_dest <= dest;
                product_first <= first_step;
                product_last <= last_step;
            end
        end
    end
endmodule

`default_nettype wire
CREATE_PROJECT_EOF_RTL_PE_GRID2X2_1MAC_MIXED_SV

cat > 'rtl/matmul8x8_15dsp_1logic.sv' <<'CREATE_PROJECT_EOF_RTL_MATMUL8X8_15DSP_1LOGIC_SV'
`timescale 1ns/1ps
`default_nettype none

// C[8][8] = A[8][8] * B[8][8]. All 16 output tiles run concurrently.
// Each physical grid owns one 2x2 C tile and ONE shared multiplier/adder.
// G00..G32 prefer hard multipliers; G33 uses logic (15 hard + 1 soft intent).
// A tiles multicast across grid rows; B tiles multicast down grid columns.
// Revision BRAM_ACC: 64 partial sums live in 16 additional M9K banks.
// Target: 8 input M9Ks + 16 accumulator M9Ks = 24 of EP4CE6's 30 M9Ks.
// Default input banks: 8 x 32 bits; each 2x2 tile occupies TWO addresses.
// Output is a 16-to-1 RAM-output mux instead of a 64-to-1 register mux.
// Confirm actual mapping, LE usage and timing in Quartus for EP4CE6E22C8.
module matmul8x8_15dsp_1logic #(
    parameter integer DATA_W = 16,
    parameter integer ACC_W  = 2*DATA_W + 3
) (
    input  wire                       clk,
    input  wire                       rst,
    input  wire                       load_valid,
    output wire                       load_ready,
    input  wire                       load_matrix, // 0=A, 1=B
    input  wire [5:0]                 load_addr,   // row*8+column
    input  wire signed [DATA_W-1:0]   load_data,
    input  wire                       start,
    output wire                       start_ready,
    output wire                       busy,
    output logic                      done,
    output wire                       result_valid,
    input  wire                       result_ready,
    output wire [5:0]                 result_addr, // ordered 0..63
    output wire signed [ACC_W-1:0]    result_data
);
    typedef enum logic [2:0] {
        IDLE, FETCH0, FETCH1, CAPTURE1, ISSUE, DRAIN, WRITE_C
    } state_t;
    state_t state;
    logic [63:0] loaded_a, loaded_b;
    logic [1:0] k_tile;
    logic [5:0] out_index;
    localparam integer STEPS_PER_K = 4;
    localparam logic [2:0] LAST_ISSUE = 3'd7;
    logic [2:0] issue_index;
    wire wr_fire, wr_a, wr_b;
    wire ram_rd_en, issue, phase, first_step, last_step;
    wire [2:0] read_k;

    wire [2*DATA_W-1:0] qa [0:3]; // low=even row, high=odd row
    wire [2*DATA_W-1:0] qb [0:3]; // low=even col, high=odd col
    // Only ONE copy per input tile, shared by four grids.
    // tile_a[row][phase]: 4 tiles * 4 elements = 16 registers.
    // tile_b[column][phase]: likewise 16 registers.
    logic signed [DATA_W-1:0] tile_a [0:7][0:1];
    logic signed [DATA_W-1:0] tile_b [0:7][0:1];
    wire signed [DATA_W-1:0] a_bus [0:7];
    wire signed [DATA_W-1:0] b_bus [0:7];
    wire [15:0] grid_done;
    wire signed [ACC_W-1:0] grid_result [0:15];
    wire result_prefetch;
    wire [5:0] prefetch_addr;
    wire [3:0] prefetch_grid, output_grid;
    wire [1:0] prefetch_dest;

    // synthesis translate_off
    initial begin
        if (DATA_W < 8 || DATA_W%8 != 0)
            $fatal(1, "Packed BRAM requires byte-aligned DATA_W, e.g. 8 or 16");
        if (ACC_W < 2*DATA_W + 3)
            $fatal(1, "8x8 signed accumulation requires ACC_W >= 2*DATA_W+3");
    end
    // synthesis translate_on

    assign load_ready = !rst && (state == IDLE);
    // Input load wins if requested at the same time as start.
    assign start_ready = !rst && (state == IDLE) &&
                         (&loaded_a) && (&loaded_b) && !load_valid;
    assign busy = (state != IDLE);
    assign wr_fire = load_valid && load_ready;
    assign wr_a = wr_fire && !load_matrix;
    assign wr_b = wr_fire &&  load_matrix;
    assign ram_rd_en = !rst && ((state == FETCH0) || (state == FETCH1));
    assign read_k = {k_tile, (state == FETCH1)};
    assign issue = !rst && (state == ISSUE);
    assign phase = issue_index[2];
    // This stays high for all four destinations at k=0.
    assign first_step = (k_tile == 2'd0) && !phase;
    assign last_step = (issue_index == LAST_ISSUE);

    // Read C[0] on the final DRAIN edge, after the last RAM write completed.
    // Thereafter fetch the NEXT scalar only when the current one is accepted.
    // A stalled output causes no new read: RAM output/address remain stable.
    assign result_prefetch = !rst &&
        (((state == DRAIN) && (k_tile == 2'd3) && (&grid_done)) ||
         ((state == WRITE_C) && result_ready && (out_index != 6'd63)));
    assign prefetch_addr = (state == WRITE_C) ? out_index + 6'd1 : 6'd0;
    assign prefetch_grid = {prefetch_addr[5:4], prefetch_addr[2:1]};
    assign prefetch_dest = {prefetch_addr[3], prefetch_addr[0]};
    assign output_grid = {out_index[5:4], out_index[2:1]};

    // Four A banks, one per pair of rows. A tile is packed by COLUMN:
    //   mem[2*t]   = {A[2*i+1][2*t],   A[2*i][2*t]}.
    //   mem[2*t+1] = {A[2*i+1][2*t+1], A[2*i][2*t+1]}.
    // Four B banks, one per pair of columns. B tile is packed by ROW:
    //   mem[2*t]   = {B[2*t][2*j+1],   B[2*t][2*j]}.
    //   mem[2*t+1] = {B[2*t+1][2*j+1], B[2*t+1][2*j]}.
    // Eight bank reads per scalar k return 16 elements, shared by all grids.
    genvar bank, bus_index, grid_row, grid_col;
    generate
        for (bank = 0; bank < 4; bank = bank + 1) begin : g_banks
            tiled_bram_bank #(.DATA_W(DATA_W), .ADDR_W(3)) u_a (
                .clk(clk), .wr_en(wr_a && load_addr[5:4] == bank),
                .wr_lane(load_addr[3]),
                .wr_addr(load_addr[2:0]), .wr_data(load_data),
                .rd_en(ram_rd_en), .rd_addr(read_k), .rd_data(qa[bank])
            );
            tiled_bram_bank #(.DATA_W(DATA_W), .ADDR_W(3)) u_b (
                .clk(clk), .wr_en(wr_b && load_addr[2:1] == bank),
                .wr_lane(load_addr[0]),
                .wr_addr(load_addr[5:3]), .wr_data(load_data),
                .rd_en(ram_rd_en), .rd_addr(read_k), .rd_data(qb[bank])
            );
        end
        for (bus_index = 0; bus_index < 8; bus_index = bus_index + 1) begin : g_bus
            assign a_bus[bus_index] = tile_a[bus_index][phase];
            assign b_bus[bus_index] = tile_b[bus_index][phase];
        end

        for (grid_row = 0; grid_row < 4; grid_row = grid_row + 1) begin : g_grid_row
            for (grid_col = 0; grid_col < 4; grid_col = grid_col + 1) begin : g_grid_col
                // All grid_col values share the same A pair for this row.
                // All grid_row values share the same B pair for this column.
                // Only G33 owns a logic multiplier. Keep identical latency
                // because the controller waits for all chunk_done together.
                pe_grid2x2_1mac_mixed #(
                    .DATA_W(DATA_W), .ACC_W(ACC_W),
                    .USE_LOGIC_MULT((grid_row == 3) && (grid_col == 3))
                ) u_grid (
                    .clk(clk), .rst(rst), .step_valid(issue),
                    .first_step(first_step), .last_step(last_step),
                    .dest(issue_index[1:0]),
                    .a0(a_bus[2*grid_row]), .a1(a_bus[2*grid_row+1]),
                    .b0(b_bus[2*grid_col]), .b1(b_bus[2*grid_col+1]),
                    .readout_valid(result_prefetch &&
                                   prefetch_grid == 4*grid_row+grid_col),
                    .readout_dest(prefetch_dest),
                    .readout_data(grid_result[4*grid_row+grid_col]),
                    .chunk_done(grid_done[4*grid_row+grid_col])
                );
            end
        end
    endgenerate

    // Accumulator RAM is read-only during output. Stream in row-major order.
    assign result_valid = !rst && (state == WRITE_C);
    assign result_addr = out_index;
    assign result_data = grid_result[output_grid];

    always_ff @(posedge clk) begin
        if (rst) begin
            loaded_a <= '0;
            loaded_b <= '0;
        end else if (wr_fire) begin
            if (load_matrix)
                loaded_b[load_addr] <= 1'b1;
            else
                loaded_a[load_addr] <= 1'b1;
        end
    end

    integer n;
    always_ff @(posedge clk) begin
        // Each read has one synchronous RAM cycle before buffer capture.
        if (!rst && state == FETCH1) begin
            for (n = 0; n < 4; n = n + 1) begin
                tile_a[2*n][0]   <= $signed(qa[n][DATA_W-1:0]);
                tile_a[2*n+1][0] <= $signed(qa[n][2*DATA_W-1:DATA_W]);
                tile_b[2*n][0]   <= $signed(qb[n][DATA_W-1:0]);
                tile_b[2*n+1][0] <= $signed(qb[n][2*DATA_W-1:DATA_W]);
            end
        end
        if (!rst && state == CAPTURE1) begin
            for (n = 0; n < 4; n = n + 1) begin
                tile_a[2*n][1]   <= $signed(qa[n][DATA_W-1:0]);
                tile_a[2*n+1][1] <= $signed(qa[n][2*DATA_W-1:DATA_W]);
                tile_b[2*n][1]   <= $signed(qb[n][DATA_W-1:0]);
                tile_b[2*n+1][1] <= $signed(qb[n][2*DATA_W-1:DATA_W]);
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            k_tile <= 2'd0;
            out_index <= 6'd0;
            issue_index <= 3'd0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                IDLE: if (start && start_ready) begin
                    k_tile <= 2'd0;
                    out_index <= 6'd0;
                    issue_index <= 3'd0;
                    state <= FETCH0;
                end
                FETCH0:   state <= FETCH1;
                FETCH1:   state <= CAPTURE1;
                CAPTURE1: begin
                    issue_index <= 3'd0;
                    state <= ISSUE;
                end
                ISSUE: begin
                    if (last_step)
                        state <= DRAIN;
                    else
                        issue_index <= issue_index + 3'd1;
                end
                DRAIN: if (&grid_done) begin
                    if (k_tile != 2'd3) begin
                        k_tile <= k_tile + 2'd1;
                        state <= FETCH0;
                    end else begin
                        out_index <= 6'd0;
                        state <= WRITE_C;
                    end
                end
                WRITE_C: if (result_ready) begin
                    if (out_index == 6'd63) begin
                        state <= IDLE;
                        done <= 1'b1;
                    end else begin
                        out_index <= out_index + 6'd1;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
CREATE_PROJECT_EOF_RTL_MATMUL8X8_15DSP_1LOGIC_SV

cat > 'tb/tb_matmul8x8_15dsp_1logic.sv' <<'CREATE_PROJECT_EOF_TB_TB_MATMUL8X8_15DSP_1LOGIC_SV'
`timescale 1ns/1ps
`default_nettype none

module tb_matmul8x8_15dsp_1logic;
    parameter integer DATA_W = 16;
    localparam integer ACC_W = 2*DATA_W + 3;
    localparam integer STEPS_PER_K = 4;
    localparam integer EXPECTED_ISSUES = 8*STEPS_PER_K;
    localparam integer EXPECTED_CYCLES = 4*(3 + 2*STEPS_PER_K + 2) + 64;
    localparam integer VMIN = -(1 << (DATA_W-1));
    localparam integer VMAX =  (1 << (DATA_W-1)) - 1;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;
    logic load_valid = 0, load_matrix = 0;
    wire load_ready;
    logic [5:0] load_addr = 0;
    logic signed [DATA_W-1:0] load_data = 0;
    logic start = 0;
    wire start_ready, busy, done;
    wire result_valid;
    logic result_ready = 1;
    wire [5:0] result_addr;
    wire signed [ACC_W-1:0] result_data;

    matmul8x8_15dsp_1logic #(.DATA_W(DATA_W), .ACC_W(ACC_W)) dut (.*);

    // Check elaborated branch selection. RTL simulation cannot prove which
    // physical resources Quartus will use; that needs a synthesis report.
    wire [15:0] logic_selection;
    // Simulation-only RAM visibility; these are NOT asynchronous RTL ports.
    wire signed [ACC_W-1:0] accum_view [0:63];
    genvar grid_r, grid_c, local_slot;
    generate
        for (grid_r = 0; grid_r < 4; grid_r = grid_r + 1) begin : g_style_row
            for (grid_c = 0; grid_c < 4; grid_c = grid_c + 1) begin : g_style_col
                assign logic_selection[4*grid_r+grid_c] =
                    dut.g_grid_row[grid_r].g_grid_col[grid_c].u_grid.USE_LOGIC_MULT;
                for (local_slot = 0; local_slot < 4; local_slot = local_slot + 1) begin : g_acc_view
                    assign accum_view[(2*grid_r+local_slot/2)*8+2*grid_c+local_slot%2] =
                        dut.g_grid_row[grid_r].g_grid_col[grid_c].u_grid.u_accum.mem[local_slot];
                end

                wire compute_read = dut.g_grid_row[grid_r].g_grid_col[grid_c].u_grid.step_valid;
                wire output_read = dut.g_grid_row[grid_r].g_grid_col[grid_c].u_grid.readout_valid;
                wire ram_read = dut.g_grid_row[grid_r].g_grid_col[grid_c].u_grid.u_accum.rd_en;
                wire ram_write = dut.g_grid_row[grid_r].g_grid_col[grid_c].u_grid.u_accum.wr_en;
                wire [1:0] read_addr = dut.g_grid_row[grid_r].g_grid_col[grid_c].u_grid.u_accum.rd_addr;
                wire [1:0] write_addr = dut.g_grid_row[grid_r].g_grid_col[grid_c].u_grid.u_accum.wr_addr;
                integer compute_reads = 0, result_reads = 0, acc_writes = 0;
                logic [3:0] initialized = 0;
                always @(posedge clk) begin
                    if (rst || (start && start_ready)) begin
                        compute_reads = 0;
                        result_reads = 0;
                        acc_writes = 0;
                        initialized = 0;
                    end else begin
                        if (ram_read && ram_write && read_addr == write_addr)
                            $fatal(1, "Accumulator read/write collision at G%0d%0d", grid_r, grid_c);
                        if (compute_read && output_read)
                            $fatal(1, "Compute/output shared a RAM read port");
                        if (compute_read) begin
                            if (!dut.first_step && !initialized[read_addr])
                                $fatal(1, "Accumulation used a stale/uninitialized sum");
                            compute_reads = compute_reads + 1;
                        end
                        if (output_read) begin
                            if (initialized !== 4'hf || ram_write)
                                $fatal(1, "Result read before all sums were ready");
                            result_reads = result_reads + 1;
                        end
                        if (ram_write) begin
                            initialized[write_addr] = 1'b1;
                            acc_writes = acc_writes + 1;
                        end
                    end
                end
                always @(negedge clk) begin
                    if (!rst && done) begin
                        if (compute_reads != 32 || acc_writes != 32 || result_reads != 4)
                            $fatal(1, "G%0d%0d unexpected RAM counts %0d/%0d/%0d",
                                   grid_r, grid_c, compute_reads, acc_writes, result_reads);
                    end
                end
            end
        end
    endgenerate

    logic signed [DATA_W-1:0] a [0:63];
    logic signed [DATA_W-1:0] b [0:63];
    longint signed golden [0:63];
    logic [31:0] rng = 32'h4c2a917d;
    integer pass_count = 0;
    integer issue_count = 0, read_count = 0, active_cycles = 0;

    // Independent reference for EVERY output after each scalar K step.
    integer issued_steps = 0;
    integer pending_k, pending_dest, pending_step, mon_k, mon_n, mon_dest;
    bit pending_valid = 0, accepted_step;
    logic signed [ACC_W-1:0] old_accum [0:63];
    logic [7:0] seen_a [0:3];
    logic [7:0] seen_b [0:3];
    integer reads_a [0:3];
    integer reads_b [0:3];
    // Simulation-only visibility for independently checking the tile layout.
    wire [2*DATA_W-1:0] stored_a [0:3][0:7];
    wire [2*DATA_W-1:0] stored_b [0:3][0:7];

    function automatic longint signed partial_sum(input integer row,
                                                  input integer col,
                                                  input integer last_k);
        integer k;
        begin
            partial_sum = 0;
            for (k = 0; k <= last_k; k = k + 1)
                partial_sum = partial_sum + longint'(a[8*row+k]) * longint'(b[8*k+col]);
        end
    endfunction

    // Observe the actual read port of each physical bank instance. Require
    // every input address to be read once, in order, per matrix product.
    genvar bank, word_index;
    generate
        for (bank = 0; bank < 4; bank = bank + 1) begin : g_read_monitor
            for (word_index = 0; word_index < 8; word_index = word_index + 1) begin : g_storage_view
                assign stored_a[bank][word_index] = dut.g_banks[bank].u_a.mem[word_index];
                assign stored_b[bank][word_index] = dut.g_banks[bank].u_b.mem[word_index];
            end

            // Check EVERY scalar write: the other half-word must retain
            // its exact previous bits, including X before initialization.
            integer written_addr_a, written_addr_b;
            logic [2*DATA_W-1:0] expected_word_a, expected_word_b;
            always @(posedge clk) begin
                if (dut.g_banks[bank].u_a.wr_en) begin
                    if (dut.g_banks[bank].u_a.rd_en)
                        $fatal(1, "Unexpected concurrent A load/read");
                    written_addr_a = dut.g_banks[bank].u_a.wr_addr;
                    expected_word_a = stored_a[bank][written_addr_a];
                    expected_word_a[dut.g_banks[bank].u_a.wr_lane*DATA_W +: DATA_W] = load_data;
                    #1;
                    if (stored_a[bank][written_addr_a] !== expected_word_a)
                        $fatal(1, "A bank %0d write corrupted a packed word", bank);
                end
            end
            always @(posedge clk) begin
                if (dut.g_banks[bank].u_b.wr_en) begin
                    if (dut.g_banks[bank].u_b.rd_en)
                        $fatal(1, "Unexpected concurrent B load/read");
                    written_addr_b = dut.g_banks[bank].u_b.wr_addr;
                    expected_word_b = stored_b[bank][written_addr_b];
                    expected_word_b[dut.g_banks[bank].u_b.wr_lane*DATA_W +: DATA_W] = load_data;
                    #1;
                    if (stored_b[bank][written_addr_b] !== expected_word_b)
                        $fatal(1, "B bank %0d write corrupted a packed word", bank);
                end
            end

            always @(posedge clk) begin
                if (rst || (start && start_ready)) begin
                    seen_a[bank] <= '0;
                    seen_b[bank] <= '0;
                    reads_a[bank] <= 0;
                    reads_b[bank] <= 0;
                end else begin
                    if (dut.g_banks[bank].u_a.rd_en) begin
                        if (!busy || seen_a[bank][dut.g_banks[bank].u_a.rd_addr] ||
                            dut.g_banks[bank].u_a.rd_addr !== reads_a[bank])
                            $fatal(1, "Duplicate/unexpected A bank %0d read", bank);
                        seen_a[bank][dut.g_banks[bank].u_a.rd_addr] <= 1'b1;
                        reads_a[bank] <= reads_a[bank] + 1;
                    end
                    if (dut.g_banks[bank].u_b.rd_en) begin
                        if (!busy || seen_b[bank][dut.g_banks[bank].u_b.rd_addr] ||
                            dut.g_banks[bank].u_b.rd_addr !== reads_b[bank])
                            $fatal(1, "Duplicate/unexpected B bank %0d read", bank);
                        seen_b[bank][dut.g_banks[bank].u_b.rd_addr] <= 1'b1;
                        reads_b[bank] <= reads_b[bank] + 1;
                    end
                end
            end
        end
    endgenerate

    always @(posedge clk) begin
        if (rst || (start && start_ready)) begin
            pending_valid = 0;
            issued_steps = 0;
        end else begin
            accepted_step = dut.issue;
            if (accepted_step) begin
                mon_k = issued_steps/STEPS_PER_K;
                mon_dest = issued_steps%STEPS_PER_K;
                if (mon_k >= 8 || dut.k_tile !== mon_k/2 ||
                    dut.first_step !== (mon_k == 0) || dut.phase !== (mon_k%2 == 1))
                    $fatal(1, "Incorrect first_step/phase/K at issue %0d", mon_k);
                if (dut.last_step !== (issued_steps%(2*STEPS_PER_K) == 2*STEPS_PER_K-1))
                    $fatal(1, "Incorrect last_step at issue %0d", issued_steps);
                if (dut.issue_index[1:0] !== mon_dest)
                    $fatal(1, "Incorrect shared-MAC destination at issue %0d", issued_steps);
                for (mon_n = 0; mon_n < 8; mon_n = mon_n + 1) begin
                    if (dut.a_bus[mon_n] !== a[8*mon_n+mon_k] ||
                        dut.b_bus[mon_n] !== b[8*mon_k+mon_n])
                        $fatal(1, "Wrong shared A/B data at index=%0d k=%0d", mon_n, mon_k);
                end
            end
            for (mon_n = 0; mon_n < 64; mon_n = mon_n + 1)
                old_accum[mon_n] = accum_view[mon_n];
            #1;
            // The same ONE local destination updates in each of the 16
            // grids, including G33, which selects the logic multiplier.
            for (mon_n = 0; mon_n < 64; mon_n = mon_n + 1) begin
                if (pending_valid &&
                    2*((mon_n/8)%2) + mon_n%2 == pending_dest) begin
                    if (longint'(accum_view[mon_n]) !== partial_sum(mon_n/8, mon_n%8, pending_k))
                        $fatal(1, "Partial C[%0d,%0d] wrong after k=%0d", mon_n/8, mon_n%8, pending_k);
                end else if (accum_view[mon_n] !== old_accum[mon_n])
                    $fatal(1, "Inactive accumulator changed at C[%0d]", mon_n);
            end
            if (dut.grid_done !== {16{pending_valid &&
                (pending_step%(2*STEPS_PER_K) == 2*STEPS_PER_K-1)}})
                $fatal(1, "All 16 chunk_done flags must track the same last step");
            pending_valid = accepted_step;
            if (accepted_step) begin
                pending_k = mon_k;
                pending_dest = mon_dest;
                pending_step = issued_steps;
                issued_steps = issued_steps + 1;
            end
        end
    end

    function automatic [31:0] next_random;
        begin
            rng = rng ^ (rng << 13);
            rng = rng ^ (rng >> 17);
            rng = rng ^ (rng << 5);
            next_random = rng;
        end
    endfunction

    // Count actual parallel work and source reads, independently of FSM timing.
    always @(posedge clk) begin
        if (rst || (start && start_ready)) begin
            issue_count = 0;
            read_count = 0;
            active_cycles = 0;
        end else if (busy) begin
            active_cycles = active_cycles + 1;
            if (dut.issue) issue_count = issue_count + 1;
            if (dut.ram_rd_en) read_count = read_count + 1;
        end
    end

    task automatic reset_core;
        begin
            @(negedge clk);
            rst = 1;
            start = 0;
            load_valid = 0;
            result_ready = 1;
            repeat (3) @(negedge clk);
            rst = 0;
            @(negedge clk);
            if (busy || result_valid || done || start_ready)
                $fatal(1, "Reset did not clear controller/input-valid masks");
        end
    endtask

    task automatic write_element(input bit matrix_sel, input integer addr,
                                 input logic signed [DATA_W-1:0] data);
        begin
            @(negedge clk);
            load_valid = 1;
            load_matrix = matrix_sel;
            load_addr = addr[5:0];
            load_data = data;
            @(posedge clk);
            if (!load_ready) $fatal(1, "Input write was not accepted");
        end
    endtask

    task automatic load_matrices;
        integer n, addr;
        begin
            // A permutation of all addresses catches assumptions about
            // strictly ordered loading. Interleave A and B writes.
            for (n = 0; n < 64; n = n + 1) begin
                addr = (5*n + 3) % 64;
                write_element(0, addr, a[addr]);
                write_element(1, addr, b[addr]);
            end
            @(negedge clk);
            load_valid = 0;
        end
    endtask

    task automatic check_storage;
        integer bank_id, k;
        logic [2*DATA_W-1:0] expected_a, expected_b;
        begin
            for (bank_id = 0; bank_id < 4; bank_id = bank_id + 1)
                for (k = 0; k < 8; k = k + 1) begin
                    expected_a = {a[8*(2*bank_id+1)+k], a[8*(2*bank_id)+k]};
                    expected_b = {b[8*k+2*bank_id+1], b[8*k+2*bank_id]};
                    if (stored_a[bank_id][k] !== expected_a || stored_b[bank_id][k] !== expected_b)
                        $fatal(1, "Tile packing wrong: bank=%0d word=%0d", bank_id, k);
                end
        end
    endtask

    // Example host-side tile loader using the unchanged scalar interface.
    task automatic load_tile(input bit matrix_sel, input integer tile_row,
                              input integer tile_col);
        integer r, c, addr;
        begin
            for (r = 0; r < 2; r = r + 1)
                for (c = 0; c < 2; c = c + 1) begin
                    addr = 8*(2*tile_row+r) + 2*tile_col+c;
                    write_element(matrix_sel, addr, matrix_sel ? b[addr] : a[addr]);
                end
        end
    endtask

    task automatic load_matrices_tiled;
        integer tile_row, tile_col;
        begin
            for (tile_row = 0; tile_row < 4; tile_row = tile_row + 1)
                for (tile_col = 0; tile_col < 4; tile_col = tile_col + 1) begin
                    load_tile(0, tile_row, tile_col);
                    load_tile(1, tile_row, tile_col);
                end
            @(negedge clk);
            load_valid = 0;
        end
    endtask

    task automatic patch_element(input bit matrix_sel, input integer addr,
                                  input logic signed [DATA_W-1:0] value);
        begin
            if (matrix_sel) b[addr] = value;
            else            a[addr] = value;
            write_element(matrix_sel, addr, value);
            @(negedge clk);
            load_valid = 0;
        end
    endtask

    task automatic compute_golden;
        integer i, j, k;
        longint signed sum;
        begin
            for (i = 0; i < 8; i = i + 1)
                for (j = 0; j < 8; j = j + 1) begin
                    sum = 0;
                    for (k = 0; k < 8; k = k + 1)
                        sum = sum + longint'(a[8*i+k]) * longint'(b[8*k+j]);
                    golden[8*i+j] = sum;
                end
        end
    endtask

    task automatic run_case(input string label_text, input bit reload,
                            input bit stalls, input bit inject_busy_requests);
        integer count, cycles, forced_stall, final_stall, expected_addr, bank_index;
        logic [63:0] seen;
        bit previous_stall, finished;
        logic [5:0] held_addr;
        logic signed [ACC_W-1:0] held_data;
        logic [31:0] rv;
        begin
            compute_golden();
            if (reload) load_matrices();
            check_storage();
            @(negedge clk);
            start = 1;
            @(posedge clk);
            if (!start_ready) $fatal(1, "start_ready low for %s", label_text);
            @(negedge clk);
            start = 0;
            count = 0;
            cycles = 0;
            forced_stall = 0;
            final_stall = 0;
            seen = '0;
            previous_stall = 0;
            finished = 0;
            while (!finished) begin
                // Drive at falling edges; check the handshake at rising edges.
                rv = next_random();
                result_ready = !stalls || (rv[1:0] != 0);
                if (stalls && result_valid && count == 0 && forced_stall < 8) begin
                    result_ready = 0;
                    forced_stall = forced_stall + 1;
                end
                if (stalls && result_valid && count == 63 && final_stall < 8) begin
                    result_ready = 0;
                    final_stall = final_stall + 1;
                end
                // Pulses while busy must neither overwrite RAM nor restart C.
                load_valid = inject_busy_requests && cycles >= 5 && cycles <= 7;
                start = load_valid;
                load_matrix = 0;
                load_addr = 0;
                load_data = VMAX;

                @(posedge clk);
                if (load_ready || start_ready)
                    $fatal(1, "Ready asserted while processing %s", label_text);
                if (previous_stall &&
                    (!result_valid || result_addr !== held_addr || result_data !== held_data))
                    $fatal(1, "Output changed during backpressure: %s", label_text);
                if (result_valid && result_ready) begin
                    // Every tile finishes together; serialize C row-major.
                    expected_addr = count;
                    if (count >= 64 || result_addr !== expected_addr || seen[result_addr])
                        $fatal(1, "Output address/order mismatch: got %0d expected %0d", result_addr, expected_addr);
                    if (result_data !== golden[result_addr][ACC_W-1:0])
                        $fatal(1, "%s C[%0d]: got %0d expected %0d", label_text,
                               result_addr, $signed(result_data), golden[result_addr]);
                    seen[result_addr] = 1'b1;
                    count = count + 1;
                end
                previous_stall = result_valid && !result_ready;
                held_addr = result_addr;
                held_data = result_data;
                #1;
                if (done) begin
                    if (count != 64 || !(&seen) || busy || result_valid)
                        $fatal(1, "Incorrect completion handshake: %s", label_text);
                    if (issue_count != EXPECTED_ISSUES || read_count != 8)
                        $fatal(1, "Expected %0d issue and 8 RAM-read cycles, got %0d/%0d", EXPECTED_ISSUES, issue_count, read_count);
                    if (!stalls && active_cycles != EXPECTED_CYCLES)
                        $fatal(1, "Expected %0d no-stall cycles, got %0d", EXPECTED_CYCLES, active_cycles);
                    for (bank_index = 0; bank_index < 4; bank_index = bank_index + 1) begin
                        if (reads_a[bank_index] != 8 || reads_b[bank_index] != 8 ||
                            seen_a[bank_index] !== 8'hff || seen_b[bank_index] !== 8'hff)
                            $fatal(1, "Inputs were not read exactly once in bank %0d", bank_index);
                    end
                    finished = 1;
                end
                cycles = cycles + 1;
                if (cycles > 1000) $fatal(1, "Timeout: %s", label_text);
                @(negedge clk);
            end
            start = 0;
            load_valid = 0;
            result_ready = 1;
            pass_count = pass_count + 1;
            if (pass_count <= 8)
                $display("PASS %-24s cycles=%0d issue=%0d word_reads=%0d scalar_reads=%0d", label_text,
                         active_cycles, issue_count, read_count*8, read_count*16);
            @(posedge clk);
            #1;
            if (done) $fatal(1, "done must be a one-cycle pulse");
        end
    endtask

    integer n, trial, lane;
    logic [31:0] random_word;
    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile($sformatf("build/matmul8x8_15dsp_1logic_dw%0d.vcd", DATA_W));
            $dumpvars(0, tb_matmul8x8_15dsp_1logic);
        end
        #1;
        if (logic_selection !== 16'h8000)
            $fatal(1, "Only G33 must select the logic multiplier branch");
        $display("RTL STYLE PASS: 15 dsp-preferred branches + G33 logic branch (not a physical mapping report)");
        reset_core();

        // Starting with missing input elements must have no effect.
        @(negedge clk); start = 1;
        repeat (3) begin
            @(posedge clk); #1;
            if (busy || start_ready) $fatal(1, "Started before full A/B load");
            @(negedge clk);
        end
        start = 0;

        // A single missing element must block start, including the final
        // cycle that writes it. Simultaneous load/start gives load priority.
        for (n = 0; n < 64; n = n + 1) begin a[n] = 0; b[n] = 0; end
        for (n = 0; n < 64; n = n + 1) write_element(0, n, a[n]);
        for (n = 0; n < 63; n = n + 1) write_element(1, n, b[n]);
        @(negedge clk); load_valid = 0; start = 1;
        @(posedge clk); #1;
        if (busy || start_ready) $fatal(1, "Started with B[63] missing");
        write_element(1, 63, b[63]);
        #1;
        if (busy || start_ready) $fatal(1, "Start overrode the final input load");
        @(negedge clk); load_valid = 0; start = 0;

        for (n = 0; n < 64; n = n + 1) begin a[n] = 0; b[n] = n-8; end
        run_case("zero", 1, 0, 0);
        for (n = 0; n < 64; n = n + 1) begin
            a[n] = (n/8 == n%8) ? 1 : 0;
            b[n] = 3*n - 20;
        end
        run_case("identity_signed", 1, 0, 1);
        run_case("reuse_without_reload", 0, 1, 1);
        for (n = 0; n < 64; n = n + 1) begin a[n] = VMIN; b[n] = VMIN; end
        run_case("minimum_times_minimum", 1, 1, 0);
        for (n = 0; n < 64; n = n + 1) begin a[n] = VMAX; b[n] = VMAX; end
        run_case("maximum_times_maximum", 1, 0, 0);
        for (n = 0; n < 64; n = n + 1) begin a[n] = VMIN; b[n] = VMAX; end
        run_case("minimum_times_maximum", 1, 1, 0);
        for (n = 0; n < 64; n = n + 1) begin
            a[n] = n%2 ? VMIN : VMAX;
            b[n] = (n/8)%2 ? VMAX : VMIN;
        end
        run_case("mixed_extremes", 1, 1, 1);

        // Only G33 can have nonzero outputs. Exercise all four of its
        // destinations with mixed signs and full-width operands.
        for (n = 0; n < 64; n = n + 1) begin
            a[n] = (n/8 >= 6) ? ((n%3 == 0) ? VMIN : VMAX) : 0;
            b[n] = (n%8 >= 6) ? ((n%5 == 0) ? VMIN : VMAX) : 0;
        end
        run_case("logic_grid_only", 1, 0, 0);

        // Isolate every K lane, especially the new k=4..7. Nonzero data
        // in every row/column also exercises all 16 grids/all banks.
        for (lane = 0; lane < 8; lane = lane + 1) begin
            for (n = 0; n < 64; n = n + 1) begin
                a[n] = (n%8 == lane) ? n/8-3 : 0;
                b[n] = (n/8 == lane) ? 2*(n%8)-7 : 0;
            end
            run_case($sformatf("isolated_k_%0d", lane), 1, lane%2, 0);
        end
        for (n = 0; n < 64; n = n + 1) begin
            a[n] = 2*n-63;
            b[n] = (n/8 == n%8) ? 1 : 0;
        end
        run_case("right_identity", 1, 0, 0);

        // Explicitly load each 2x2 tile instead of permuted scalar addresses.
        for (n = 0; n < 64; n = n + 1) begin
            a[n] = 7*n-101;
            b[n] = 3*n-87;
        end
        load_matrices_tiled();
        run_case("tile_ordered_load", 0, 0, 0);

        // Change only one half-word, rerun without reloading other values.
        patch_element(0, 8*2+5, VMIN);
        run_case("patch_A_low_lane", 0, 0, 0);
        patch_element(0, 8*3+5, VMAX);
        run_case("patch_A_high_lane", 0, 1, 0);
        patch_element(1, 8*6+4, VMIN);
        run_case("patch_B_low_lane", 0, 0, 0);
        patch_element(1, 8*6+5, VMAX);
        run_case("patch_B_high_lane", 0, 1, 0);

        for (trial = 0; trial < 100; trial = trial + 1) begin
            for (n = 0; n < 64; n = n + 1) begin
                random_word = next_random(); a[n] = random_word[DATA_W-1:0];
                random_word = next_random(); b[n] = random_word[DATA_W-1:0];
            end
            run_case($sformatf("random_%0d", trial), 1, trial%2, trial%3 == 0);
        end

        // Abort in-flight work, reset the load masks, then recover normally.
        @(negedge clk); start = 1;
        @(posedge clk);
        if (!start_ready) $fatal(1, "Cannot start reset-abort test");
        @(negedge clk); start = 0;
        repeat (10) @(negedge clk);
        reset_core();
        run_case("recovery_after_reset", 1, 1, 1);

        // Reset while a valid output is stalled, then fully reload/restart.
        @(negedge clk); start = 1; result_ready = 0;
        @(posedge clk);
        if (!start_ready) $fatal(1, "Cannot start output-reset test");
        @(negedge clk); start = 0;
        while (!result_valid) @(negedge clk);
        repeat (3) @(negedge clk);
        reset_core();
        run_case("recovery_output_reset", 1, 0, 0);

        if (pass_count != 124) $fatal(1, "Unexpected number of completed cases");
        $display("ACCUM RAM PASS: per grid/run 32 compute reads, 32 writes, 4 result reads; zero read/write collisions");
        $display("ALL PASS: %0d matrix products, DATA_W=%0d ACC_W=%0d, 16 concurrent 1-MAC grids (15 dsp-preferred + 1 logic)", pass_count, DATA_W, ACC_W);
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "Global simulation timeout");
    end
endmodule

`default_nettype wire
CREATE_PROJECT_EOF_TB_TB_MATMUL8X8_15DSP_1LOGIC_SV

cat > 'quartus/matmul8x8_15dsp_1logic.qsf' <<'CREATE_PROJECT_EOF_QUARTUS_MATMUL8X8_15DSP_1LOGIC_QSF'
# Analysis & Synthesis project. Board pins and timing constraints are not set.
# Use default DATA_W=16 / ACC_W=35 for the intended 15 x 18-bit hard blocks.
# BRAM_ACC revision: small 4-word accumulator banks deliberately use M9K.
set_global_assignment -name FAMILY "Cyclone IV E"
set_global_assignment -name DEVICE EP4CE6E22C8
set_global_assignment -name TOP_LEVEL_ENTITY matmul8x8_15dsp_1logic
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
set_global_assignment -name ALLOW_ANY_RAM_SIZE_FOR_RECOGNITION ON
set_global_assignment -name SYSTEMVERILOG_FILE ../rtl/tiled_bram_bank.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../rtl/grid_accum_bram.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../rtl/pe_grid2x2_1mac_mixed.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../rtl/matmul8x8_15dsp_1logic.sv
CREATE_PROJECT_EOF_QUARTUS_MATMUL8X8_15DSP_1LOGIC_QSF

cat > 'quartus/matmul8x8_15dsp_1logic.qpf' <<'CREATE_PROJECT_EOF_QUARTUS_MATMUL8X8_15DSP_1LOGIC_QPF'
PROJECT_REVISION = "matmul8x8_15dsp_1logic"
CREATE_PROJECT_EOF_QUARTUS_MATMUL8X8_15DSP_1LOGIC_QPF

cat > 'quartus/run_synthesis.ps1' <<'CREATE_PROJECT_EOF_QUARTUS_RUN_SYNTHESIS_PS1'
param([string]$QuartusMap = 'quartus_map')
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    $compiler = Get-Command $QuartusMap -ErrorAction Stop
    & $compiler.Source 'matmul8x8_15dsp_1logic'
    if ($LASTEXITCODE -ne 0) { throw 'Quartus Analysis & Synthesis failed.' }
    Write-Host 'Analysis & Synthesis finished. Inspect the mapping report and Technology Map Viewer.'
    Write-Host 'Expected intent at DATA_W=16: 15 hard 18x18 multipliers; G33 multiply in logic.'
    Write-Host 'This script does not run Fitter, TimeQuest, or program the FPGA.'
} finally {
    Pop-Location
}
CREATE_PROJECT_EOF_QUARTUS_RUN_SYNTHESIS_PS1

printf 'Project created in %s\n' "$(pwd)"
