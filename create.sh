#!/usr/bin/env bash
# Self-contained project generator: mkdir + literal file contents.
# Usage: ./create_matrix_multiplier_uart.sh [new_project_directory]
# Default: ./matrix_multiplier_uart in the current working directory.
set -euo pipefail

if (( $# > 1 )); then
    printf 'Usage: %s [new_project_directory]\n' "$0" >&2
    exit 2
fi
project_dir="${1:-matrix_multiplier_uart}"
if [[ -e "$project_dir" || -L "$project_dir" ]]; then
    printf 'Destination already exists: %s\nChoose a new directory: %s /path/to/new/matrix_multiplier_uart\n' "$project_dir" "$0" >&2
    exit 1
fi
mkdir -p -- "$project_dir"
cd -- "$project_dir"
mkdir -p docs rtl sim host scripts quartus tests

cat > README.md <<'MATRIX_UART_FILE_001_END'
# Nhân ma trận 8×8 tuần tự qua UART trên Cyclone IV

Dự án giáo dục cho **EP4CE6E22C8**, clock **50 MHz**, UART **115200 8N1**.
Một datapath nhân signed 16×16 dùng lại 512 lần, accumulator/result signed
64 bit; không CPU, không NumPy và không IP UART độc quyền.

Đích triển khai: `/home/hoangb/workspace/matmul/matrix_multiplier_uart/`.
Tài liệu và ví dụ bo gốc trong `Altera-Cyclone-IV-board-V3.0` chỉ được đọc,
không thay đổi. Đã đối chiếu inventory, manual, pin table, schematic, QSF
của các ví dụ và mã UART trước khi viết RTL.

## Chạy mô phỏng

```bash
cd /home/hoangb/workspace/matmul/matrix_multiplier_uart
sudo apt install iverilog
./scripts/run_sim.sh
```

Script compile **Verilog-2005** với `-Wall`, chạy ba testbench tự kiểm;
bất kỳ lỗi nào trả mã khác 0. Có thể đặt biến `IVERILOG`/`VVP` khi dùng bản
cài riêng. Không thêm testbench vào danh sách file synthesis.

## Cài và mở GUI

```bash
cd /home/hoangb/workspace/matmul/matrix_multiplier_uart
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python host/main.py
```

Chọn cổng serial, Connect; bật **DIP2**, tắt **DIP1**, chờ switch ổn định rồi
nhập hoặc tạo A/B và bấm Calculate on FPGA. Calculate in Python dùng vòng lặp
Python với số nguyên chính xác; Compare Results so sánh cả 64 phần tử.
Thời gian hiển thị cho FPGA là round-trip UART, không phải thời gian tính lõi.
Switch ON kéo chân KEY xuống 0; GUI và tài liệu mô tả SW=1 nghĩa là **ON**.

| SW1 | SW2 | Mode | LED |
|---:|---:|---|---|
| 0 | 0 | Idle, không xử lý gói | Tắt hết |
| 1 | 0 | Phát `hello\r\n` mỗi giây | Chỉ LED1 |
| 0 | 1 | Nhận A/B, nhân và trả C | Chỉ LED2 |
| 1 | 1 | Invalid, hủy transaction | Tắt hết |

Mỗi KEY dùng chung giữa DIP switch và nút nhấn; để nút nhấn thả khi dùng DIP.
Đổi mode hủy gói dở; byte TX đã bắt đầu vẫn hoàn tất. Một request tại một thời điểm.

## Phần cứng và Quartus

Clock=23, reset=25, SW1/2=88/89, LED1..4=87/86/85/84,
TX=114, **RX=115**. Reset/KEY/LED active low; I/O **3.3-V LVTTL**.
UART mặc định qua **MAX3232 và DB9 RS-232**, không phải USB-UART tích hợp.
Dùng USB-to-RS232 adapter phù hợp; DB9 của bo: 2=TX, 3=RX, 5=GND.
Xem [hướng dẫn đấu nối và bằng chứng chân](docs/HARDWARE_SETUP.md) trước khi nối.

```bash
cd quartus
quartus_sh --flow compile matrix_multiplier
```

Mở `quartus/matrix_multiplier.qpf`, kiểm tra EP4CE6E22C8, compile, xem Fitter,
TimeQuest và dùng USB-Blaster/JTAG nạp `.sof`. Máy phát triển hiện không có
Quartus; **chưa chạy synthesis/fitting/timing hoặc nạp bo**. Không có bitstream
được tạo hay kết quả tài nguyên được khẳng định.

Sơ đồ được cung cấp là **V2.1** trong workspace mang tên V3.0. Tên LED trên sơ đồ
đảo thứ tự so với pin table/ví dụ; QSF dùng pin table/ví dụ đúng bảng yêu cầu.
Cần kiểm tra revision PCB, thứ tự LED và đường RS-232 trên bo thực tế.

## Kiểm thử host

```bash
QT_QPA_PLATFORM=offscreen python -m unittest discover -s tests -v
```

Không cần bo cho kiểm thử parser, phép nhân Python, pseudo-terminal serial và
Qt offscreen. Test tương tác desktop, thiết bị USB và bo được ghi riêng là chưa chạy.

## Tệp và tài liệu

| Đường dẫn | Vai trò |
|---|---|
| `rtl/matrix_multiplier.v` | A/B/C RAM, READ/MAC/STORE và một multiplier |
| `rtl/uart_rx.v`, `rtl/uart_tx.v` | UART byte với handshake, nhận liên tục |
| `rtl/uart_protocol.v` | Framing, checksum, lỗi, chạy lõi, serializer |
| `rtl/mode_controller.v`, `rtl/top.v` | Đồng bộ/debounce switch, LED, hello và tích hợp |
| `sim/tb_matrix_multiplier.v`, `sim/tb_uart.v`, `sim/tb_top.v` | Testbench tự kiểm |
| `host/serial_client.py`, `host/main.py`, `host/matrix_utils.py` | Worker serial, GUI, reference và validation |
| `tests/test_host.py` | Kiểm thử host tự động |
| `scripts/run_sim.sh` | Chạy toàn bộ mô phỏng |
| `quartus/` | Project, pin assignments và constraint 20 ns |
| [REQUIREMENTS](docs/REQUIREMENTS.md) | Yêu cầu và cách xác minh |
| [ARCHITECTURE](docs/ARCHITECTURE.md) | Sơ đồ hệ thống, FSM, memory và timing |
| [UART_PROTOCOL](docs/UART_PROTOCOL.md) | Định dạng byte, lỗi, timeout và recovery |
| [HARDWARE_SETUP](docs/HARDWARE_SETUP.md) | Nguồn phần cứng, cáp, Linux và nạp FPGA |
| [TEST_PLAN](docs/TEST_PLAN.md) | Kế hoạch, bằng chứng và trạng thái thực thi |

Lõi đã xác minh **512 MAC, 1088 clock** (21,76 µs theo clock danh định).
Ba testbench RTL và **6 kiểm thử host/GUI qua PTY + Qt offscreen đã PASS**;
bằng chứng và kiểm tra cuối cùng được ghi trong TEST_PLAN. Timing 50 MHz, RAM/DSP inference, bounce thực và
hoạt động UART trên bo vẫn cần xác minh bằng Quartus và phần cứng.
MATRIX_UART_FILE_001_END

cat > docs/ARCHITECTURE.md <<'MATRIX_UART_FILE_002_END'
# Kiến trúc hệ thống

Thiết kế dùng clock 50 MHz duy nhất. UART nhận hai ma trận A/B, FSM tuần tự
dùng một phép nhân signed16×16 và accumulator signed64, rồi UART trả C cho
Python. DIP/nút nhấn chọn một trong bốn mode; GUI không điều khiển mode FPGA.

## 1. Sơ đồ khối và trách nhiệm

```mermaid
flowchart LR
    GUI[PyQt5: bảng A/B/C và log] <-->|signal Qt| HOST[Serial worker + packet parser]
    HOST <-->|115200 8N1 qua adapter RS232| DB9[DB9 / MAX3232 trên bo]
    DB9 -->|RX115 logic3.3V| RX[uart_rx]
    TX[uart_tx] -->|TX114 logic3.3V| DB9
    RX -->|data / valid / framing_error| P[uart_protocol]
    P -->|load / start| MAC[matrix_multiplier]
    MAC -->|done / synchronous result read| P
    P -->|data / valid| MUX[Chọn nguồn TX trong top]
    HELLO[hello sequencer trong top] --> MUX
    MUX --> TX
    TX -->|ready| P
    TX -->|ready| HELLO
    KEY[KEY1/KEY2 active low] --> MODE[mode_controller: 2FF + debounce]
    MODE --> LED[LED1..4 active low]
    MODE -->|mode / changed| CTRL[top: enable, RX idle guard]
    CTRL --> P
    CTRL --> RX
    CTRL --> HELLO
```

| Tệp | Trách nhiệm và giao diện chính |
|---|---|
| `rtl/top.v` | Đồng bộ nhả reset, nối module, chặn RX qua biên mode, tạo chuỗi hello/timer và mux TX |
| `rtl/mode_controller.v` | Hai FF cho KEY, debounce chung vector hai bit, giải mã mode và pattern LED; phát changed trong một chu kỳ |
| `rtl/uart_rx.v` | Hai FF cho RX, kiểm tra start giữa bit, lấy 8 data bit LSB-first, kiểm tra stop; valid/error là pulse một chu kỳ |
| `rtl/uart_tx.v` | Nhận data khi valid && ready, chốt frame start/data/stop, giữ đúng số clock mỗi bit; ready = !busy |
| `rtl/uart_protocol.v` | Tìm magic, kiểm tra cmd/length/checksum, nạp A/B, start core, chờ done, gửi kết quả/lỗi với handshake |
| `rtl/matrix_multiplier.v` | RAM A/B/C, chỉ số i/j/k và FSM IDLE/READ/MAC/STORE; một signed multiplier, một accumulator64 |
| `host/matrix_utils.py` | Kiểm tra input, reference số nguyên Python và packet encode/decode |
| `host/serial_client.py` | Stream parser và serial worker; không chờ UART trong Qt main thread |
| `host/main.py` | Giao diện, nhập A/B, thao tác, kết quả FPGA/Python, compare, log và vòng đời kết nối |

## 2. Lưu trữ và số học

| Bộ nhớ | Kích thước logic | Địa chỉ row-major | Cách dùng |
|---|---|---|---|
| A | 64×signed16 = 1024 bit | `row*8+col` | Ghi khi core idle; đọc đồng bộ tại `{i,k}` |
| B | 64×signed16 = 1024 bit | `row*8+col` | Ghi khi core idle; đọc đồng bộ tại `{k,j}` |
| C | 64×signed64 = 4096 bit | `row*8+col` | Ghi tại `{i,j}` trong STORE; cổng đọc kết quả đồng bộ |

Tổng dữ liệu RAM logic là **6144 bit**, chưa gồm thanh ghi điều khiển,
operand và accumulator. Attribute `ramstyle="M9K"` thể hiện ý định dùng RAM
nhúng; số block RAM thực tế và DSP được Quartus xác định, chưa có report.
RAM không reset/khởi tạo toàn bộ để giữ khả năng infer RAM. Reset xóa control
state, không xóa vật lý dữ liệu A/B/C. Protocol chỉ start sau khi đã nhận đủ
A/B và checksum hợp lệ, nên dữ liệu RAM cũ không tạo transaction mới.

Hai operand được đọc vào `a_data`, `b_data` signed16. Biểu thức duy nhất
`a_data * b_data` tạo signed32, sau đó sign-extend rõ ràng lên signed64.
Accumulator và C đều signed64; không truncate tổng và không saturation.
Tổng tám tích int16 cần 35 bit signed ở trường hợp biên: tám tích
`(-32768)*(-32768)` cho **8589934592**. UART giữ biểu diễn bù hai int64
để host giải mã không mơ hồ.

## 3. FSM nhân tuần tự

```mermaid
stateDiagram-v2
    [*] --> IDLE
    IDLE --> READ: start / i=j=k=0, accumulator=0
    READ --> MAC: operand RAM đã được đọc đồng bộ
    MAC --> READ: k<7 / cộng product, k++
    MAC --> STORE: k=7 / cộng product cuối
    STORE --> READ: còn ô / ghi C, accumulator=0, k=0, tăng j rồi i
    STORE --> IDLE: i=7 và j=7 / ghi C cuối, done=1
    IDLE --> IDLE: chờ start; có thể nạp A/B
```

Mỗi ô C cần tám cặp READ/MAC rồi một STORE. READ cho phép RAM cung cấp
operand ổn định trước cạnh MAC. MAC cuối cập nhật accumulator bằng
nonblocking assignment; STORE ở cạnh sau ghi tổng đã có đủ tám tích.
STORE đưa j về 0 khi hết cột và tăng i; kết thúc ô `[7][7]` hạ busy, phát
done đúng một chu kỳ và trở lại IDLE.

Số phép MAC là `8×8×8 = 512`. Từ cạnh chấp nhận start tới cạnh done:

```text
64 ô × (8 × 2 chu kỳ READ/MAC + 1 chu kỳ STORE) = 1088 chu kỳ
1088 / 50 000 000 = 21.76 µs
```

`tb_matrix_multiplier.v` đếm cả MAC và chu kỳ, so sánh 64 kết quả mỗi mẫu;
đã xác nhận 512/1088 trong mô phỏng. Con số này không bao gồm nhận packet,
serializer, USB/OS hoặc cập nhật GUI. Khi core busy, ghi input bị chặn;
start mới chỉ được chấp nhận ở IDLE. Reset abort và không tự tiếp tục.

## 4. Dòng dữ liệu UART và packet FSM

```mermaid
stateDiagram-v2
    [*] --> MAGIC1
    MAGIC1 --> MAGIC2: M
    MAGIC2 --> COMMAND: X
    MAGIC2 --> MAGIC2: M / giữ prefix mới
    MAGIC2 --> MAGIC1: byte khác
    COMMAND --> LENGTH_LO: cmd=01
    LENGTH_LO --> LENGTH_HI: low=00
    LENGTH_HI --> PAYLOAD: high=01
    PAYLOAD --> CHECKSUM: đủ256byte, đã nạp A/B
    CHECKSUM --> COMPUTE: checksum đúng / start
    COMPUTE --> RESPONSE_PREP: done
    RESPONSE_PREP --> RESPONSE_SEND: đợi1clock cho RAM read
    RESPONSE_SEND --> RESPONSE_PREP: ready và còn byte / tăng tx_index
    RESPONSE_SEND --> MAGIC1: ready và checksum cuối đã nhận
    COMMAND --> RESPONSE_PREP: error01
    LENGTH_LO --> RESPONSE_PREP: error02
    LENGTH_HI --> RESPONSE_PREP: error02
    CHECKSUM --> RESPONSE_PREP: error03
```

Request gồm 262 byte, payload A128 byte rồi B128 byte. `payload_index`
8 bit chạy 0..255: bit7 chọn A/B; bit[6:1] chọn phần tử 0..63; bit0
phân biệt low/high byte. Mỗi high byte tạo một pulse load_en và signed16
`{high,low}`. Checksum hợp lệ mới phát start. Lỗi framing/timeout khi đang
chờ packet cũng chuyển sang response lỗi code05/code04.

`uart_protocol` và `uart_tx` trao đổi valid/ready, không dùng delay tùy ý.
Khi ready=0, serializer giữ byte/index/checksum. Sau mỗi handshake,
RESPONSE_PREP đợi một chu kỳ để cổng đọc C đồng bộ cập nhật đúng phần tử;
thời gian truyền byte UART dài hơn chu kỳ chuẩn bị này. `tx_index` chọn
header, từng byte little-endian của C và checksum cuối. Frame lỗi dùng cùng
serializer nhưng payload một byte error code. Xem
[UART_PROTOCOL.md](UART_PROTOCOL.md) để biết định dạng và quy tắc resync.

Chỉ một request đang xử lý. RX khi COMPUTE hoặc phát response bị bỏ;
không FIFO, không queue, không reply BUSY riêng. Host chờ full response
đã kiểm checksum trước khi gửi request tiếp theo. `busy` nội bộ protocol
biểu thị COMPUTE/phát response, không phải một chân điều khiển luồng UART.

## 5. Mode và reset

```mermaid
flowchart TD
    K[KEY raw active low] --> S[Hai FF và đảo cực tính]
    S --> D[Ứng viên ổn định500000clock ≈10ms]
    D --> M{mode = SW2,SW1}
    M -->|00| I[Idle: LED tắt, không producer]
    M -->|01| H[Hello: LED1, hello lặp1s]
    M -->|10| G[Matrix: LED2, chờ RX high10bit]
    G --> P[Arm RX và enable protocol/core]
    M -->|11| X[Invalid: LED tắt, bỏ transaction]
    C[Mode thay đổi] --> A[Hủy state producer và parser/core]
    A --> F[Byte TX đã nhận tiếp tục đến hết stop bit]
```

Vector mode là `{SW2,SW1}`: SW1 dùng `key_n[0]`, SW2 dùng `key_n[1]`.
Debouncer theo cả vector nên cần cặp KEY ổn định khoảng 10 ms sau thời gian
đồng bộ; bounce làm đổi candidate và bắt đầu đếm lại. Đây là các phần tử
cơ khí có cả DIP và nút nhấn dùng chung net, không phải bốn nguồn input
độc lập. LED active low: mode1=`1110`, mode2=`1101`, mode0/3=`1111`.

Mode change tạo changed một chu kỳ, chặn ngay producer cũ và reset control
protocol/core. Khi vào matrix, top dùng hai FF riêng để đếm RX high liên tục
`10×CLKS_PER_BIT` clock trước khi arm receiver. Một UART byte liên tục có
tối đa chín bit high (data FF và stop), nên guard loại phần byte/stream đi
qua biên mode. RX có hai FF riêng phục vụ lấy mẫu UART; không cộng thêm hai
FF guard vào đường data RX. Sau guard, host phải gửi packet đầy đủ mới.

TX chốt toàn bộ frame khi valid && ready. Đổi mode không reset UART TX,
vì vậy byte đang truyền được hoàn tất; producer mới chờ ready. Các byte
còn lại của packet/hello cũ bị hủy. Reset ngoài khác mode change: reset
assert bất đồng bộ và có thể cắt ngắn byte TX; nhả reset được đồng bộ hai FF.

Hello bắt đầu ngay khi mode1 ổn định và TX sẵn sàng, không chờ thêm một
giây trước dòng đầu. Trong mode1 ổn định, các lần bắt đầu dòng được timer
HELLO_CYCLES=50000000 clock cách nhau khoảng một giây. Payload cố định là
`hello\r\n`; matrix RX/protocol tắt hoàn toàn trong mode này.

## 6. Timing, host và giới hạn kiểm chứng

Divider UART mặc định là `round(50000000/115200)=434` clock/bit, cho baud
thực tế **115207.37**, sai số khoảng **+0.0064%**. Receiver kiểm tra start
ở nửa bit, lấy mẫu data mỗi 434 clock và chỉ phát valid khi stop cao.
Framing lỗi đưa receiver vào RECOVER chờ high. Test vật lý byte bằng mô
phỏng đã bao phủ divider 434, và stream không có khoảng nghỉ thêm ở
divider 16 để giảm thời gian chạy test. Các tham số testbench thay đổi
timer/debounce, không dùng delay simulation trong module synthesizable.

Riêng thời gian bit của request khoảng 22.74 ms và response khoảng
44.96 ms; tổng khoảng 67.7 ms trước overhead GUI/USB/OS. TX có handshake
giữa byte; phép tính core21.76 µs là phần rất nhỏ. GUI phải ghi nhãn thời
gian đo là **UART round-trip**, không gọi đó là thời gian nhân FPGA.

Host giữ Qt main thread cho giao diện và dùng worker/QThread cho serial.
Nó phân biệt hello text với frame MX, kiểm tra trọn response, decode64
giá trị int64 rồi mới gửi dữ liệu sang bảng kết quả. Reference dùng số
nguyên Python; việc Compare chỉ có ý nghĩa khi cùng cặp A/B được sử dụng.
Serial phải được đóng khi disconnect và thoát ứng dụng. Kiểm thử host/GUI
được báo riêng trong TEST_PLAN; mô phỏng RTL không kiểm chứng GUI.

Chưa có synthesis/fitting/TimeQuest hay chạy bo thật. Không khẳng định số
DSP, M9K, logic elements, fMAX hoặc khả năng đạt timing chỉ từ mô phỏng.
Sơ đồ bo V2.1 và tên workspace V3.0 có khác revision; thứ tự tên LED cũng
có mâu thuẫn đã ghi tại HARDWARE_SETUP. Kiểm tra phần cứng và compiler report
là bước tiếp theo trước khi coi dự án đã được xác nhận trên Cyclone IV.
MATRIX_UART_FILE_002_END

cat > docs/HARDWARE_SETUP.md <<'MATRIX_UART_FILE_003_END'
# Thiết lập phần cứng

Tài liệu này phân biệt thông tin đã đối chiếu trong workspace bo mạch với
kết quả đo/chạy trên bo. Chưa thực hiện bất kỳ phép thử nào trên FPGA thật.
Nguồn phần cứng nằm tại
`/home/hoangb/workspace/Altera-Cyclone-IV-board-V3.0`; không sửa các ví dụ
trong thư mục đó. Đích cài đặt dự án là
`/home/hoangb/workspace/matmul/matrix_multiplier_uart`.

## 1. Nguồn và mức xác minh

| Mã | Nguồn cục bộ | Vị trí/bằng chứng |
|---|---|---|
| S1 | `Hardware documentation/Development board pin information.pdf` | Trang 1: CLOCK, RESET, KEY, DIP, LED và UART |
| S2 | `Hardware documentation/Development board schematic diagram V2.1.pdf` | Trang duy nhất: khối Crystal and reset, Button/LED/DIP switch, RS232 Serial port, FPGA main chip và IO interface |
| S3 | `Example code/Peripheral control 08 RS232 serial/uart/my_uart_top.qsf` | Device EP4CE6E22C8; clock 23, reset 25, KEY1 88, UART TX 114/RX 115; I/O 3.3-V LVTTL |
| S4 | `Example code/Peripheral control 08 RS232 serial/uart/my_uart_top.sdc` | Clock chu kỳ 20.000 ns |
| S5 | `Example code/Peripheral control 05 Dial switch control LED/ckey_led/ckey_led.qsf` và `.v` | KEY1..4 = 88..91; LED1..4 = 87..84; nối trực tiếp mức KEY tới LED active low |
| S6 | `Example code/Peripheral control 01 light 4 LED/led/led1.qsf` | LED `[0..3]` = 87, 86, 85, 84 |
| S7 | `Dev Board Manual.pdf` | Trang 1: nguồn USB/adapter 5 V và AS/JTAG; trang 2: unused pins phải input tri-state |
| S8 | `board.jpg` | Ảnh có DIP, nút nhấn riêng, DB9 và cổng USB; chỉ hỗ trợ nhận diện ngoại hình |

Các đường dẫn trong bảng tính từ thư mục nguồn bo mạch nói trên. S1–S7 đã
được đọc/đối chiếu; S2 được xem cả sơ đồ dây nối, không chỉ văn bản trích xuất.
Tên workspace ghi V3.0 nhưng sơ đồ được cung cấp ghi V2.1. Vì vậy, đây là
xác minh bằng tài liệu trong workspace, chưa phải xác nhận revision của chiếc
bo đang sử dụng. Cần đối chiếu chữ trên PCB và mã FPGA trước khi nạp.

## 2. Chân và mức điện

| Cổng RTL | Chức năng | Chân | Mức hoạt động | Bằng chứng |
|---|---|---|---|---|
| `clk_50mhz` | Clock 50 MHz | `PIN_23` | Cạnh lên; chu kỳ 20 ns | S1 trang 1; S2 oscillator X ghi 50MHz, R3 33Ω tới FPGA_CLK/U5I; S3–S4 |
| `reset_n` | Reset ngoài | `PIN_25` | 0 khi nhấn | S1 trang 1; S2 R2 10kΩ kéo lên 3.3 V, nút RESET xuống GND; S3 |
| `key_n[0]` | SW1/KEY1 | `PIN_88` | DIP ON hoặc nút nhấn = 0 | S1 trang 1; S2; S5 |
| `key_n[1]` | SW2/KEY2 | `PIN_89` | DIP ON hoặc nút nhấn = 0 | S1 trang 1; S2; S5 |
| `led_n[0]` | LED1 theo pin table/ví dụ | `PIN_87` | 0 = sáng | S1 trang 1; S5–S6; xem mâu thuẫn bên dưới |
| `led_n[1]` | LED2 theo pin table/ví dụ | `PIN_86` | 0 = sáng | Như trên |
| `led_n[2]` | LED3 theo pin table/ví dụ | `PIN_85` | 0 = sáng | Như trên |
| `led_n[3]` | LED4 theo pin table/ví dụ | `PIN_84` | 0 = sáng | Như trên |
| `uart_tx` | TX phía logic FPGA | `PIN_114` | UART idle = 1 | S1 trang 1; S2 U4 T1IN; S3 |
| `uart_rx` | RX phía logic FPGA | `PIN_115` | UART idle = 1 | S1 trang 1; S2 U4 R1OUT; S3 |

S2 khối U5K nối toàn bộ VCCIO1..8 tới **3.3 V**. Các cổng trên dùng
**3.3-V LVTTL** theo S3, không phải mức RS232 trực tiếp. Điện áp vật lý trên
bo chưa được đo. Chip mục tiêu là **Cyclone IV E EP4CE6E22C8**, package
144 chân, đúng S2/S3/S5/S6; kiểm tra mã in trên chip thực tế.

**Mâu thuẫn tên LED:** S2 dùng thứ tự net LED1..4 ngược với bảng chân S1 và
ví dụ S5/S6. Dự án theo bảng chân và ví dụ: LED1 = 87, LED2 = 86, LED3 = 85,
LED4 = 84. Cực tính active low vẫn nhất quán: anode LED ở 3.3 V, cathode
qua điện trở 470Ω tới FPGA. Chưa xác nhận LED nào khớp số in trên PCB thật;
không đánh dấu phép thử LED PASS trước khi quan sát từng đèn.

### SW1/SW2 là gì?

Bo có cả DIP switch giữ trạng thái và các nút nhấn momentary. DIP vị trí 1
và nút KEY1 dùng chung net KEY1; vị trí 2 và nút KEY2 dùng chung net KEY2.
S2 có pull-up 10kΩ, DIP nối xuống GND và nhánh nút nhấn qua điện trở 220Ω.
Do đó không tạo hai cổng FPGA riêng cho hai phần tử dùng chung chân.

Trong các bảng mode, **SW = 1 có nghĩa là bật vật lý**; đó là mức logic sau
đảo `~key_n`, không phải điện áp trên chân. Để duy trì mode, dùng DIP; để
thử tạm thời, có thể giữ nút tương ứng khi DIP đó OFF. Khi DIP đã ON,
thả nút không làm net trở về 1. KEY3/KEY4 không dùng trong dự án.
RTL phải đồng bộ và debounce các net cơ khí trước khi giải mã mode;
thời gian bounce thực tế chưa được đo trên bo.

## 3. Kết nối UART đúng loại điện

S2 cho thấy **MAX3232E trên bo chuyển giữa logic 3.3 V và cổng DB9 RS232**.
Không có USB-UART bridge trong sơ đồ này; USB được mô tả là đường cấp nguồn
trong S7. Cắm cáp USB nguồn không tự tạo một cổng serial Linux.

| Điểm nối | Hướng tương đối với bo | Đường trong S2 |
|---|---|---|
| DB9 chân 2 | TX từ bo | FPGA UART_TXD → U4 T1IN chân 11 → T1OUT chân 14 → DB9 chân 2 |
| DB9 chân 3 | RX vào bo | DB9 chân 3 → U4 R1IN chân 13 → R1OUT chân 12 → FPGA UART_RXD |
| DB9 chân 5 | GND | GND chung |

Dùng **adapter USB-to-RS232** có mức điện RS232 tại DB9. Kiểm tra đường dây
để TX của adapter tới RX của bo, RX của adapter tới TX của bo và GND nối
chung; không suy ra cách đấu chỉ từ giới tính đầu nối. Với adapter có pinout
PC/DTE thông thường, RX nằm ở chân 2 và TX ở chân 3, tương ứng các chân của
bo trong bảng trên. Kiểm tra pinout adapter và dây trước khi cắm.

Không nối adapter USB-TTL 3.3 V/5 V vào DB9. Không đưa mức RS232 vào chân
FPGA. Dự án sử dụng đường UART bản địa **TX114/RX115** và MAX3232 trên bo;
không cần gán thêm GPIO UART. Các net UART cũng xuất hiện ở header mở rộng
trong S2 nhưng tài liệu này không sử dụng đường đấu đó.

Cấu hình Linux/GUI: **115200 baud, 8 data bits, no parity, 1 stop bit**, không
RTS/CTS và không XON/XOFF. UART logic idle cao; không đảo tín hiệu thêm
trong RTL vì MAX3232 đã xử lý giao tiếp điện RS232.

## 4. Chuẩn bị và nạp Quartus

1. Đối chiếu PCB, mã chip, chân clock/reset và đường MAX3232 với bảng trên.
2. Cấp nguồn theo S7: cổng USB hoặc adapter 5 V theo vị trí công tắc nguồn.
   S7 mô tả nhấn công tắc nguồn là chọn USB, nhả là adapter 5 V; đối chiếu
   bo thực tế vì tài liệu schematic có revision khác tên workspace.
3. Trong Quartus có hỗ trợ Cyclone IV E, mở
   `quartus/matrix_multiplier.qpf`. Kiểm tra device `EP4CE6E22C8`, top `top`,
   các tệp `../rtl/*.v`, `matrix_multiplier.sdc` và assignments của bảng chân.
4. Kiểm tra I/O standard `3.3-V LVTTL`; unused pins là
   `AS INPUT TRI-STATED` theo S7. Không import toàn bộ pinout các ngoại vi
   khác vào thiết kế này. Không bật chức năng device-wide OE/reset trên
   các chân LED dùng chung chức năng của chip.
5. Chạy Analysis & Synthesis, Fitter và TimeQuest. Clock là 20.000 ns;
   kiểm tra không latch, không chân tự gán ngoài bảng, không xung đột chân,
   không lỗi timing. Các đầu vào bất đồng bộ cần đi qua mạch đồng bộ;
   constraint không thay thế mạch đồng bộ trong RTL.
6. Dùng Programmer, chọn USB-Blaster và JTAG, Auto Detect để xác nhận chip.
   Thêm `.sof` vừa biên dịch, chọn Program/Configure rồi Start. `.sof` nạp
   cấu hình tạm thời; cấu hình mất khi tắt nguồn. Không ghi flash/EPCS trong
   quy trình tối thiểu này. S7 yêu cầu không rút/cắm cáp JTAG/AS khi đang
   cấp điện; chuẩn bị kết nối khi bo tắt nguồn.

Có thể gọi compiler từ thư mục `quartus` nếu các công cụ đã có trong PATH:

```bash
cd /home/hoangb/workspace/matmul/matrix_multiplier_uart/quartus
quartus_sh --flow compile matrix_multiplier
```

Trạng thái hiện tại: **Quartus chưa có trong PATH khi kiểm tra môi trường;
chưa chạy Analysis & Synthesis, Fitter, TimeQuest hay Programmer**. Tệp QSF
và SDC không phải bằng chứng compile hoặc timing đã đạt.

## 5. Linux và GUI

```bash
cd /home/hoangb/workspace/matmul/matrix_multiplier_uart
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python -m serial.tools.list_ports -v
python host/main.py
```

Cắm/rút **adapter serial** và so sánh danh sách cổng để tìm đúng thiết bị;
đọc mô tả VID/PID/serial number nếu có. `/dev/ttyUSB*` hoặc `/dev/ttyACM*`
là các tên có thể gặp, không phải cam kết bo tự cung cấp USB serial.
Tên `/dev/serial/by-id/` nếu tồn tại giúp nhận diện cùng adapter sau khi
thứ tự `/dev/ttyUSB*` đổi. Không chọn nhầm USB-Blaster dùng nạp JTAG.

```bash
ls -l /dev/ttyUSB0
id
```

Thay `/dev/ttyUSB0` bằng cổng thực tế. Nếu nhóm sở hữu thiết bị là `dialout`
và tài khoản chưa thuộc nhóm này, thêm nhóm rồi đăng xuất/đăng nhập lại:

```bash
sudo usermod -a -G dialout "$USER"
```

Không cần chạy GUI bằng root hoặc đổi quyền thiết bị thành world-writable.
Đóng terminal serial khác trước khi Connect trong GUI. Chọn cổng đúng,
giữ 115200, kết nối; Disconnect/thoát ứng dụng phải đóng serial port.

## 6. Thử thủ công trên bo

Thực hiện sau khi compile thành công và đã xác nhận dây/điện áp. Trong bảng,
ON/OFF là vị trí DIP vật lý; mức cổng `key_n` bị đảo so với SW logical.

| ID | Chuẩn bị và thao tác | Kết quả cần thấy | Trạng thái |
|---|---|---|---|
| HW_BOARD | Đọc mã chip, revision PCB; đối chiếu S1/S2; đo nguồn VCCIO nếu có thiết bị | EP4CE6E22C8, các net/chân và 3.3 V khớp; ghi ảnh và phép đo | NOT RUN |
| HW_IDLE | SW1 OFF, SW2 OFF; nhấn/thả reset; mở UART | Bốn LED tắt; TX idle; không tự gửi dữ liệu | NOT RUN |
| HW_HELLO | SW1 ON, SW2 OFF; quan sát ít nhất 3 giây | Chỉ LED1 sáng; log có `hello\r\n` xấp xỉ mỗi giây | NOT RUN |
| HW_HELLO_RX | Trong hello mode, gửi request matrix hợp lệ | Không tính matrix/không trả packet matrix; hello vẫn hoạt động | NOT RUN |
| HW_MATRIX | SW1 OFF, SW2 ON; Load Example, Calculate in Python, Calculate on FPGA, Compare Results | Chỉ LED2 sáng; nhận đủ packet, checksum hợp lệ; C bằng Python, PASS | NOT RUN |
| HW_REPEAT | Giữ matrix mode, tính ít nhất 10 lần với số âm/dương; thử zero, identity và cực trị int16 | Từng lần có response hợp lệ và kết quả đúng, không cần reset | NOT RUN |
| HW_INVALID | SW1 ON, SW2 ON, thử gửi request | Tất cả LED tắt; không hello/không phép tính mới; transaction dở bị bỏ | NOT RUN |
| HW_ABORT | Đổi mode giữa request, phép tính và response; sau đó về matrix mode và gửi request mới | Bỏ state cũ; byte TX đang chạy được phép xong; request mới cho kết quả đúng | NOT RUN |
| HW_LED_ORDER | Chạy hello rồi matrix, đối chiếu số LED in trên PCB | LED1/LED2 khớp mapping 87/86 hoặc ghi rõ sai khác revision để sửa assignment | NOT RUN |
| HW_RESET | Reset giữa phép tính; đưa về matrix mode và gửi lại đầy đủ | Không trả kết quả dở; phục hồi với request mới | NOT RUN |
| HW_HOST_CLOSE | Disconnect, reconnect rồi đóng GUI | Cổng được đóng/mở lại, không treo event loop hay giữ thiết bị sau thoát | NOT RUN |

Sau mỗi mode change, giao thức bỏ transaction cũ và yêu cầu một packet mới.
Nếu một byte đang được truyền, byte đó được hoàn tất trước khi nguồn phát
của mode mới sử dụng UART. Vì vậy log có thể còn phần cuối của byte/packet
cũ; không coi nó là kết quả hợp lệ nếu chưa kiểm tra toàn bộ frame.
Chờ mode ổn định và đường UART trở về idle trước khi gửi lại từ host.

Lưu evidence thật cho mỗi bước: ngày giờ, revision, ảnh LED/dây nối, compiler
report và UART log (kèm hex khi kiểm tra packet). Chỉ chuyển `NOT RUN` sang
`PASS` sau khi đã thực hiện và đối chiếu kết quả trên bo. Kết quả mô phỏng
được ghi riêng trong `TEST_PLAN.md`, không thay thế các phép thử phần cứng.
MATRIX_UART_FILE_003_END

cat > docs/REQUIREMENTS.md <<'MATRIX_UART_FILE_004_END'
# Yêu cầu và truy vết kiểm chứng

Mục tiêu là một dự án giáo dục tối thiểu: nhận hai ma trận 8×8 qua UART,
nhân tuần tự bằng một datapath nhân, trả kết quả và đối chiếu trên GUI Linux.
Không dùng SIMD, Strassen, mảng multiplier song song, pipeline matrix engine,
CPU ngoài hoặc soft-core. Không thay đổi ví dụ bo mạch sẵn có.

`PASS (mô phỏng)` chỉ áp dụng cho testbench đã chạy bằng Icarus; không có
nghĩa thiết kế đã chạy trên FPGA. `PASS (tài liệu)` là đối chiếu tài liệu,
không phải đo điện. `NOT RUN` là chưa thực hiện. GUI/host đã được kiểm thử
bằng unit test, pseudo-terminal và Qt offscreen; Quartus chưa có trong PATH. Bảng kết quả
thực thi chi tiết được ghi tại [TEST_PLAN.md](TEST_PLAN.md).

## Yêu cầu phần cứng và dự án

| ID | Yêu cầu đo được / kết quả mong đợi | Phương pháp và evidence | Trạng thái |
|---|---|---|---|
| HW_001 | Clock/reset/KEY1/KEY2/LED1..4/TX/RX lần lượt là 23/25/88/89/87..84/114/115; chỉ gán chân có bằng chứng | Đối chiếu pin table trang 1, schematic trang 1 và QSF ví dụ; bảng nguồn trong HARDWARE_SETUP.md | PASS (tài liệu); PCB thật NOT RUN |
| HW_002 | Clock đầu vào 50 MHz, SDC 20 ns; device EP4CE6E22C8 | Oscillator X và U5I của schematic; QSF/SDC ví dụ UART; kiểm tra QSF/SDC mới | PASS (tài liệu); tần số đo thật NOT RUN |
| HW_003 | Reset, KEY/DIP và LED active low; SW logical 1 là DIP ON/nút nhấn, tức đảo mức chân | Schematic pull-up và dây GND; ví dụ Dial switch; test LED/mode trên bo | PASS (tài liệu); thử bo NOT RUN |
| HW_004 | VCCIO 3.3 V, I/O 3.3-V LVTTL; UART qua MAX3232 tới DB9 RS232, không giả định USB-UART | Schematic U5K/U4, manual nguồn; DB9 TX2/RX3/GND5 | PASS (tài liệu); đo/đấu bo NOT RUN |
| HW_005 | Ghi rõ mâu thuẫn tên LED của schematic V2.1 so với pin table/ví dụ và revision workspace V3.0 | HARDWARE_SETUP.md nêu cả hai nguồn; thử từng LED trước khi xác nhận số trên PCB | PASS (ghi nhận); xác minh vật lý NOT RUN |
| QRT_001 | QPF/QSF gồm đủ 6 tệp RTL, đúng device/pin/I/O/SDC; unused pins input tri-state | Kiểm tra nội dung quartus/* so với nguồn phần cứng | PASS (kiểm tra tệp) |
| QRT_002 | Analysis & Synthesis/Fitter/TimeQuest thành công, không latch và đạt clock 50 MHz | Chạy Quartus và lưu report; kiểm tra RAM/DSP mapping thật | NOT RUN: Quartus chưa có trong PATH |

## Yêu cầu mode

Mode được mã hóa `{SW2, SW1}` sau đảo cực tính, đồng bộ và debounce.
LED pattern dưới đây theo thứ tự `led_n[3:0]`; 1 là tắt.

| ID | Yêu cầu đo được / kết quả mong đợi | Phương pháp và evidence | Trạng thái |
|---|---|---|---|
| MODE_001 | SW1=1, SW2=0: mode 1, LED=`1110`; gửi đúng 7 byte `hello\r\n`; lặp xấp xỉ 1 s; bỏ request matrix | tb_top: hai dòng hello, interval đúng HELLO_CYCLES và không core done khi gửi request trong hello | PASS (mô phỏng); bo NOT RUN |
| MODE_002 | SW1=0, SW2=1: mode 2, LED=`1101`; ngừng hello; request hợp lệ trả đúng C; cho phép tính lại không reset | tb_top: hai request liên tiếp theo giao dịch và kiểm tra 64 int64/result checksum | PASS (mô phỏng); bo NOT RUN |
| MODE_003 | SW1=0, SW2=0: mode 0, LED=`1111`, TX idle, không tự phát hoặc tính matrix | tb_top: trạng thái reset/idle, gửi request trong idle không có response/done | PASS (mô phỏng); bo NOT RUN |
| MODE_004 | SW1=1, SW2=1: mode 3, LED=`1111`; không hello/phép tính mới, bỏ transaction dở | tb_top: bỏ request thiếu, gửi request ở invalid không có response/done, quay về matrix phục hồi | PASS (mô phỏng); bo NOT RUN |
| MODE_005 | KEY đi qua hai FF và chỉ đổi mode sau khoảng 10 ms ổn định; xung bounce ngắn không được chấp nhận | mode_controller.v: DEBOUNCE_CYCLES=500000; tb_top dùng tham số rút ngắn, tạo bounce 3 chu kỳ so với ngưỡng 8 | PASS (RTL/mô phỏng); bounce đo thật NOT RUN |
| MODE_006 | Sau mode change, reset parser/core; chỉ arm RX sau ≥10 bit liên tục mức idle cao; byte đi qua biên mode không thành header mới | top.v: guard 10×CLKS_PER_BIT; tb_top gửi M/X qua biên idle→matrix và kiểm tra parser vẫn chờ magic | PASS (RTL/mô phỏng); bo NOT RUN |
| MODE_007 | Byte TX đã được nhận handshake phải hoàn tất cả stop bit khi đổi mode; không phát byte mới từ mode cũ | tb_top: decoder UART độc lập bắt stop bit khi hello→idle và response→invalid; kiểm tra số byte không tăng thêm | PASS (mô phỏng); bo NOT RUN |
| MODE_008 | External reset abort ngay; matrix core không tự tiếp tục sau reset | tb_matrix_multiplier: reset giữa phép tính, chờ 1200 chu kỳ không busy/done rồi tính lại đúng | PASS (mô phỏng); bo NOT RUN |

MODE_007 không áp dụng khi nhấn reset ngoài: reset có thể cắt ngắn byte
đang truyền. Đổi mode khi core đang COMPUTE được xử lý bằng reset core;
tb_top đã kiểm tra abort giữa MAC, không done/response và quay lại Matrix.
Thử vật lý đổi mode trong cửa sổ COMPUTE 21.76 µs vẫn là NOT RUN.

## Yêu cầu tính toán

| ID | Yêu cầu đo được / kết quả mong đợi | Phương pháp và evidence | Trạng thái |
|---|---|---|---|
| MAT_001 | A/B đều 8×8, từng phần tử signed int16 −32768..32767; C gồm 64 kết quả chính xác trong signed int64 | tb_matrix_multiplier đối chiếu reference model cho toàn bộ 64 ô ở mỗi mẫu | PASS (mô phỏng) |
| MAT_002 | Một biểu thức nhân signed16×16, ba chỉ số i/j/k; đúng 512 MAC cho mỗi phép tính, không multiplier array | Kiểm tra matrix_multiplier.v; bench đếm state MAC=512 | PASS (RTL/mô phỏng); DSP mapping Quartus NOT RUN |
| MAT_003 | Product 32 bit được sign-extend lên 64 bit trước cộng; không overflow/truncation kết quả toán học 35 bit | Bench zero, identity, ones, positive, negative, mixed, 32767×32767, −32768×−32768 và hai cực trị trái dấu | PASS (mô phỏng) |
| MAT_004 | FSM READ/MAC/STORE hoàn tất sau 1088 chu kỳ từ cạnh nhận start; done chỉ một chu kỳ, busy hạ khi done | Bench đếm 64×(8×2+1)=1088 chu kỳ và kiểm tra done pulse | PASS (mô phỏng) |
| MAT_005 | Tính lại không reset/reload vẫn đúng; sau abort và nạp đầy đủ request mới vẫn đúng | tb_matrix_multiplier có lần lặp giữ RAM và tính lại sau reset; tb_uart/tb_top lặp request | PASS (mô phỏng) |

Không ghi “512 chu kỳ tính toán”: 512 là số MAC. 1088 chu kỳ tương đương
21.76 µs với clock 50 MHz và chỉ là độ trễ core, không gồm UART/GUI.

## Yêu cầu UART

| ID | Yêu cầu đo được / kết quả mong đợi | Phương pháp và evidence | Trạng thái |
|---|---|---|---|
| UART_001 | Nhận request 262 byte: MX/01/length 0100/A128/B128/checksum; int16 little-endian, row-major | tb_uart cấp byte parser; tb_top gửi bit UART toàn request và kiểm tra kết quả | PASS (mô phỏng) |
| UART_002 | Response 518 byte: MX/81/length 0200/C512/checksum; từng C int64 little-endian | tb_uart và tb_top kiểm tra header, độ dài, checksum và 64 giá trị signed | PASS (mô phỏng) |
| UART_003 | Cấu hình 115200 8N1, LSB trước; divider 434 tại 50 MHz; nhận byte back-to-back không mất dữ liệu | tb_uart: 256 giá trị byte ở divider 16 và 434; 32 frame RX liên tục không khoảng nghỉ thêm ở divider 16 | PASS (mô phỏng); UART điện thật NOT RUN |
| UART_004 | Sai magic bị bỏ; hỗ trợ prefix M chồng nhau; sai cmd/length/checksum trả lần lượt lỗi 01/02/03 | tb_uart kiểm tra magic và packet lỗi MX/FF/length1/code/checksum | PASS (mô phỏng) |
| UART_005 | Packet thiếu byte timeout sau 100 ms không có rx_valid; stop bit lỗi trả code05; không tính matrix lỗi | tb_uart: TIMEOUT_CYCLES rút ngắn, code04/05; bench physical UART từ chối stop bit sai | PASS (mô phỏng) |
| UART_006 | TX giữ valid/data cho đến ready; không bỏ/trùng byte dưới backpressure | tb_uart stall TX và thay đổi tx_ready; đối chiếu trọn response | PASS (mô phỏng) |
| UART_007 | Chỉ một transaction; RX khi COMPUTE/trả response bị bỏ; gửi request mới sau full reply được xử lý | tb_uart chèn byte trong busy/stall, lặp 3 mẫu; tb_top lặp full request/response | PASS (mô phỏng) |
| UART_008 | Mode disable hủy partial packet, enable lại không tái sử dụng packet dở | tb_uart tắt protocol giữa payload rồi enable; tb_top đổi qua invalid và nhận lại request mới | PASS (mô phỏng) |

Checksum là tổng unsigned tất cả byte trước checksum modulo 256; không phải
CRC. Busy không có packet thông báo riêng: host phải chờ response hoặc
timeout. Không hỗ trợ xếp hàng/pipeline nhiều request.

## Yêu cầu host và GUI

Các yêu cầu dưới đây được kiểm thử host độc lập trong `tests/test_host.py`;
việc RTL PASS không được dùng để thay thế bằng chứng Python/GUI.

| ID | Yêu cầu đo được / kết quả mong đợi | Kiểm chứng | Trạng thái |
|---|---|---|---|
| GUI_001 | Hai bảng A/B 8×8 chỉnh sửa được; từ chối ô rỗng, chữ, số thập phân và ngoài int16 trước khi gửi | Host validation + GUI offscreen | PASS (host/offscreen) |
| GUI_002 | Reference dùng số nguyên Python; Compare báo PASS khi cả 64 ô bằng nhau, FAIL khi có sai khác | Host zero/identity/extremes; cố ý sửa một ô kết quả | PASS (host/offscreen) |
| GUI_003 | List/Refresh port, Connect/Disconnect, baud mặc định115200 và trạng thái kết nối rõ | Khởi tạo GUI/list_ports; worker với PTY; adapter thật cần thử riêng | PASS (host); adapter NOT RUN |
| GUI_004 | Có Random (min/max mặc định−10..10 cấu hình được), Clear, Load Example, FPGA/Python/Compare | GUI offscreen kiểm tra chức năng, random range và invalid range | PASS (offscreen) |
| GUI_005 | Chỉ hiển thị FPGA C sau khi xác nhận đủ header/cmd/length/checksum và decode signed64 | Parser test response hợp lệ, cắt ngắn, sai checksum/length/command và cực trị | PASS (host) |
| GUI_006 | hello được log dạng text, không được coi là matrix response; log có timestamp, kết nối, TX/RX/error, tùy chọn hex | Parser/PTY trộn hello và binary, payload chứa literal hello, phục hồi sau gói dở | PASS (host) |
| GUI_007 | Serial I/O chạy QThread/worker, GUI không chờ UART trong main thread; đóng serial khi Disconnect/thoát | Qt offscreen, PTY delayed response + QTimer heartbeat, close/disconnect | PASS (host/offscreen); bo NOT RUN |
| GUI_008 | Hiển thị hai kết quả FPGA/Python, PASS/FAIL và thời gian round trip ghi đúng nhãn | GUI offscreen kiểm bảng và nhãn UART round-trip | PASS (offscreen) |
| HOST_001 | Python3 + PyQt5 + pyserial; reference không phụ thuộc NumPy | requirements.txt, import/compile và test trên Python3.10/PyQt5/pyserial đã cài | PASS (môi trường hiện tại); cài venv mới NOT RUN |

Các lần kiểm chứng GUI/host thực tế sau đó phải được cập nhật vào
`TEST_PLAN.md` với lệnh, số test và kết quả. Kiểm tra trên bo luôn được ghi
riêng; không chuyển hardware sang PASS dựa trên test giả lập hoặc offscreen.
MATRIX_UART_FILE_004_END

cat > docs/TEST_PLAN.md <<'MATRIX_UART_FILE_005_END'
# Kế hoạch và kết quả kiểm thử

Các trạng thái dưới đây tách mô phỏng, phần mềm host và bo thật. **PASS mô phỏng
không phải PASS phần cứng.** Mọi test bo đang NOT RUN vì chưa kết nối bo.
Ngày chạy kiểm tra phần mềm/RTL: 2026-11-11, Ubuntu Linux.

## Chuẩn bị và lệnh

- Icarus Verilog 11.0 (gói Ubuntu, giải nén trong `/tmp/matrix-iverilog` của phiên
  triển khai); biên dịch `-g2005 -Wall`, không cần SystemVerilog.
- Python 3.10.12, PyQt5 5.15.6 / Qt 5.15.3, pyserial 3.5.
- Các mô phỏng có watchdog và `$fatal`; shell dừng ngay khi một test lỗi.
- UART test chạy bộ chia 16 để kiểm nhanh, đồng thời test byte ở bộ chia thật
  **434 với clock 50 MHz**. Top test rút ngắn debounce/hello để tăng tốc mô phỏng;
  giá trị mặc định phần cứng vẫn 10 ms / 1 giây.

```bash
./scripts/run_sim.sh
QT_QPA_PLATFORM=offscreen python3 -m unittest discover -s tests -v
python3 -m compileall -q host tests
```

Lệnh RTL thực tế trong môi trường chưa cài system-wide:

```bash
IVERILOG=/tmp/matrix-iverilog/iverilog \
VVP=/tmp/matrix-iverilog/usr/bin/vvp ./scripts/run_sim.sh
```

`/tmp/matrix-iverilog/iverilog` là wrapper cho binary của gói Ubuntu, thêm
`-B /tmp/matrix-iverilog/usr/lib/x86_64-linux-gnu/ivl`; đây chỉ là môi trường test,
không phải phụ thuộc được đóng gói vào dự án.

## RTL: đã chạy tự động

Chuẩn bị chung: chạy script ở thư mục gốc; mọi expected được assert bằng testbench.

| ID | Mục tiêu / bước | Expected | Bằng chứng | Trạng thái |
|---|---|---|---|---|
| SIM_M01 | Nạp A=B=0, start, đọc đủ C | 64 số 0 | `tb_matrix_multiplier` pattern 0 | PASS |
| SIM_M02 | A=I, B có cả âm/dương | C=B | Pattern 1, oracle độc lập | PASS |
| SIM_M03 | A=B=1 | Mọi C=8 | Pattern 2 | PASS |
| SIM_M04 | Toàn dương rồi toàn âm | Khớp vòng lặp signed64 reference | Pattern 3,4 | PASS |
| SIM_M05 | Trộn dấu và biên int16 | Không lỗi mở rộng dấu | Pattern 5 | PASS |
| SIM_M06 | A=B=32767 | Mọi C=8589410312 | Pattern 6 | PASS |
| SIM_M07 | A=B=-32768 | Mọi C=8589934592 | Pattern 7 | PASS |
| SIM_M08 | A=-32768, B=32767 | Mọi C=-8589672448 | Pattern 8 | PASS |
| SIM_M09 | Start lại, không reset | C đúng mỗi lần | Repeated calculation | PASS |
| SIM_M10 | Reset giữa MAC, nạp và chạy lại | Hủy busy, không done giả, khôi phục | Reset recovery | PASS |
| SIM_M11 | Đếm FSM từ start tới done | 512 MAC,1088 clocks cho mỗi run | Assertion đếm từng clock | PASS |
| SIM_U01 | Loopback TX/RX tất cả 256 byte, CPB16 và434 | Đúng byte, stop hợp lệ | `tb_uart` UART links | PASS |
| SIM_U02 | Gửi UART không đồng pha, back-to-back 8N1 | Không mất byte | Manual RX stream | PASS |
| SIM_U03 | Start glitch, stop sai, sau đó frame đúng | Không valid giả, phục hồi | UART glitch/framing checks | PASS |
| SIM_U04 | Packet hợp lệ, payload mixed/min/max | Đúng header,64 signed64,checksum518byte | Independent response oracle | PASS |
| SIM_U05 | Magic sai / magic chồng `4D 4D 58` | Ignore/resync, gói sau đúng | Magic tests | PASS |
| SIM_U06 | Sai command, từng byte length, checksum | Error code1,2,3, không tính | Error response assertions | PASS |
| SIM_U07 | Gói dở quá timeout, framing error | Error code4,5 | Timeout/framing tests | PASS |
| SIM_U08 | Nhiều transaction chờ reply, không reset | Đủ response mỗi lần | Consecutive transaction tests | PASS |
| SIM_U09 | RX khi compute/TX; stall tx_ready | Input bị bỏ, valid/data ổn định tới accept | Backpressure toàn bộ response | PASS |
| SIM_T01 | SW=00,10,01,11 theo bảng logic | LED1111,1110,1101,1111 active-low | `tb_top` mode assertions | PASS |
| SIM_T02 | Bounce ngắn rồi switch ổn định | Bỏ bounce, nhận trạng thái ổn định | Debounce test | PASS |
| SIM_T03 | Hello mode nhận request Matrix | Chỉ hello, không MAC | Wire decode + completed counter | PASS |
| SIM_T04 | Đọc hai hello liên tiếp | Đúng7byte,line period theo parameter | Independent wire decoder/time check | PASS |
| SIM_T05 | Gửi packet vật lý, đọc C, lặp lại | 518byte đúng, C=B với A=I | Physical UART integration | PASS |
| SIM_T06 | Đổi mode giữa byte TX / giữa response | Hoàn tất byte hiện tại, không byte tiếp | Stop-bit assertions/count | PASS |
| SIM_T07 | Byte RX qua biên mode; abort input ở invalid | Không dùng byte cũ; idle guard có hiệu lực | Stale RX + recovery test | PASS |
| SIM_T08 | Quay lại Matrix sau abort | Gói mới tính đúng | Recovery transaction | PASS |
| SIM_T09 | Đổi về Idle trong lúc core đang MAC | Hủy busy, không done/response, phục hồi khi về Matrix | Top compute abort assertion | PASS |

Kết thúc thực tế của các testbench:

```text
PASS tb_matrix_multiplier: arithmetic, repeated runs, reset recovery
PASS tb_uart
PASS tb_top: four modes, LEDs, debounce, repeated hello, continuous UART packets, mode abort/recovery, TX byte completion
PASS: all RTL simulations
```

`tb_uart` cũng kết thúc PASS sau các assertion UART/protocol; kết quả chi tiết
có thể tái tạo bằng script. Không có log Quartus hoặc log bo được tạo giả.

## Host và GUI

Chuẩn bị: cài `requirements.txt`; tests dùng pseudo-terminal Linux thay cho
thiết bị thật và Qt offscreen thay cho desktop. Host unit tests và Python
compileall đã PASS; không gộp kết quả này với kiểm thử cáp/FPGA.

| ID | Mục tiêu / bước | Expected | Bằng chứng | Trạng thái |
|---|---|---|---|---|
| HOST_01 | Validate đủ64cell mỗi ma trận, biên và input sai | Từ chối rỗng/noninteger/out-of-range | `tests/test_host.py` | PASS |
| HOST_02 | Reference Python: zero/identity/mixed/extremes | Khớp oracle, không tràn int32 | Unit tests | PASS |
| HOST_03 | Encode/decode, checksum,length,error và binary có hello | Chỉ nhận gói hoàn chỉnh, không lẫn text | Parser tests | PASS |
| HOST_04 | Serial qua pseudo-terminal, timeout/disconnect | Worker phản hồi, đóng port | PTY tests: phản hồi cắt đoạn, checksum sai + response đến muộn, reconnect, timeout | PASS |
| HOST_05 | Qt offscreen, thao tác bảng và nút | Validation, random,example,Python,compare | GUI smoke tests, cố ý sửa một ô để FAIL, đổi input xóa kết quả cũ | PASS |
| HOST_06 | Chờ response trong worker, QTimer vẫn chạy | Qt event loop hoạt động khi UART chưa trả lời | PTY + QTimer heartbeat | PASS |
| HOST_07 | Nhận header/payload dở khi không có request, idle250ms rồi hello | Bỏ phần binary dở, hello lại được ghi log | PTY recovery assertion | PASS |
| HOST_08 | GUI → QThread → pyserial qua PTY, disconnect/reconnect, đóng cửa sổ khi pending | TX262/RX518 đúng, bảng C đúng, Compare PASS, raw hex/hello log, thread kết thúc và cổng đóng | `test_gui_serial_roundtrip` dùng signal thật | PASS |
| GUI_HW01 | Desktop thực, chọn cổng và refresh | Hiển thị cổng đúng, UI responsive | Thao tác người dùng | NOT RUN |
| GUI_HW02 | Đóng cửa sổ khi đang chờ reply thật | Cổng đóng, thread kết thúc | Desktop + adapter thật | NOT RUN |

Lần chạy host cuối: **6 tests, OK**, Python compileall thành công. Qt offscreen
in thông báo `This plugin does not support propagateSizeHints()`; đó là giới
hạn backend offscreen, không phải test failure. Đã xem ảnh GUI chụp offscreen;
không coi đây là kiểm chứng desktop/serial adapter thật.

Kiểm tra cấu trúc đủ 23 tệp bắt buộc + `tests/test_host.py`, liên kết tài liệu,
code fence, whitespace, 6 nguồn synthesis và 10 pin assignment đều đạt.
So sánh SHA-256 trước/sau của **6678 tệp** trong workspace bo mạch khẳng định
không sửa hoặc xóa ví dụ/tài liệu sẵn có.

## Quartus và bo thật: chưa chạy

Chuẩn bị: bo đúng revision, USB-Blaster, USB-to-RS232/cáp phù hợp và Quartus hỗ
trợ Cyclone IV. Làm theo HARDWARE_SETUP; ghi log và ảnh đo thực tế khi thực thi.

| ID | Mục tiêu | Bước / expected | Bằng chứng cần thu | Trạng thái |
|---|---|---|---|---|
| QUA_01 | Analysis/synthesis/fitting | Compile qpf đúng device, không lỗi/latch | `*.map.rpt`, `*.fit.rpt` | NOT RUN: thiếu Quartus |
| QUA_02 | Timing và tài nguyên | TimeQuest Fmax đáp ứng50MHz; xác nhận một multiplier logic, RAM inference | `*.sta.rpt`, RTL/Technology Viewer | NOT RUN |
| HW_01 | PCB/pin/điện áp | Kiểm revision, clock50MHz, VCCIO3.3V | Ảnh PCB, đo clock/voltage | NOT RUN |
| HW_02 | LED polarity/thứ tự | Hello chỉ LED1, Matrix chỉ LED2, LED3/4 tắt | Video/ảnh và bảng pin | NOT RUN |
| HW_03 | KEY/DIP/reset | ON/nhấn kéo thấp; release high; reset sạch | Đo mức logic, thử bounce | NOT RUN |
| HW_04 | RS232 vật lý | DB9 pin2TX,pin3RX,pin5GND; 1152008N1 | Cáp, adapter, logic/scope capture | NOT RUN |
| HW_05 | Hello thật | SW1 ON, SW2 OFF: hello mỗi giây | GUI log timestamp | NOT RUN |
| HW_06 | Nhân thật và so sánh | Identity, random, max/min;64cell PASS | TX/RX log + GUI result | NOT RUN |
| HW_07 | Lặp lại, mode abort, kết nối lại | Không cần reset giữa phép tính; phục hồi sau abort | Log và thao tác trên bo | NOT RUN |
| HW_08 | Idle/invalid | Không phát thêm byte sau byte đang chạy; không tính | UART capture, LED | NOT RUN |

## Giới hạn bằng chứng

Mô phỏng lý tưởng không chứng minh metastability, bounce thực, jitter của clock,
đặc tính cáp, điện áp, resource mapping hay timing sau place-and-route. Checksum
sum8 phát hiện lỗi đơn giản, không bảo vệ mọi hoán vị byte/lỗi bù nhau; đây là
giao thức giáo dục theo yêu cầu. Không retransmit tự động, không pipeline request.
MATRIX_UART_FILE_005_END

cat > docs/UART_PROTOCOL.md <<'MATRIX_UART_FILE_006_END'
# Giao thức UART

UART **115200 baud, 8N1**, không flow control; byte và phần tử đều little-endian,
ma trận row-major. Clock 50 MHz chia 434 cho baud thực tế khoảng 115207,37
(sai số +0,0064%). Một byte gồm start=0, 8 data bit LSB trước, stop=1.

## Request nhân ma trận

| Offset | Số byte | Giá trị |
|---|---:|---|
| 0 | 2 | Magic `4D 58` (ASCII MX) |
| 2 | 1 | Command `01` |
| 3 | 2 | Payload length `00 01` = 256 |
| 5 | 128 | A: 64 số signed int16, mỗi số 2 byte |
| 133 | 128 | B: cùng định dạng |
| 261 | 1 | Tổng unsigned các byte offset 0..260, modulo 256 |

Tổng **262 byte**. Chỉ sau khi checksum đúng mới bắt đầu nhân. Giá trị âm dùng
bù hai; ví dụ -32768 = `00 80`, -1 = `FF FF`, 32767 = `FF 7F`.

## Response kết quả

| Offset | Số byte | Giá trị |
|---|---:|---|
| 0 | 2 | `4D 58` |
| 2 | 1 | `81` |
| 3 | 2 | `00 02` = 512 |
| 5 | 512 | C: 64 số signed int64, mỗi số 8 byte |
| 517 | 1 | Tổng unsigned các byte offset 0..516, modulo 256 |

Tổng **518 byte**. Kết quả toán học cần 35 bit có dấu và được mở rộng dấu lên
64 bit, không bão hòa, không cắt xuống int32. Host phải kiểm tra magic, command,
độ dài, đủ toàn bộ payload và checksum trước khi hiển thị. Không diễn giải
`hello`, CR hoặc LF bên trong payload nhị phân thành văn bản.

Ví dụ giải mã phần tử n trong Python:

```python
import struct
value = struct.unpack_from('<q', packet, 5 + 8*n)[0]
```

## Response lỗi

Định dạng **7 byte**: `4D 58 FF 01 00 CODE CHECKSUM`. Độ dài payload = 1.
Checksum bao gồm magic, command, length và CODE. Không có kết quả C trong gói lỗi.

| CODE | Ý nghĩa | Điều kiện |
|---:|---|---|
| 1 | Command không hợp lệ | Byte sau magic khác `01` |
| 2 | Payload length không hợp lệ | Hai byte length không phải `00 01` |
| 3 | Checksum sai | Đã nhận 256 byte payload nhưng tổng không khớp |
| 4 | Timeout nhận | Khoảng trống giữa hai byte trong gói đạt 100 ms |
| 5 | UART framing error | Stop bit thấp trong lúc đang nhận ở Matrix mode |

Ví dụ lỗi command: `4D 58 FF 01 00 01 A6`.
Lỗi command/length trả ngay khi phát hiện, không chờ phần payload khai báo sai.
Framing error cũng hủy transaction hiện tại. Gói lỗi luôn đi qua cùng handshake TX.

## Framing, busy và phục hồi

1. Chỉ Matrix mode (`SW1=0, SW2=1`, trạng thái logic ON/OFF) nhận request.
2. Bộ nhận tìm `4D 58`; byte rác hoặc magic sai bị bỏ qua, không trả lỗi.
   Chuỗi `4D 4D 58` nhận diện magic ở hai byte cuối.
3. Sau magic, xác minh command và length trước khi ghi A/B. Không tìm magic
   bên trong payload có độ dài hợp lệ. Checksum sai không cho phép tính.
4. Trong COMPUTE và RESPONSE, input bị bỏ qua. **Chỉ một request đang xử lý**;
   host phải nhận hết response trước request tiếp theo. Không có hàng đợi hoặc
   mã lỗi busy; không hỗ trợ gửi nhiều request liền nhau mà không chờ reply.
5. Khi hoàn tất response/lỗi, trở lại tìm magic. Khi lỗi, host phải ngừng stream
   sai và gửi lại **toàn bộ** request từ đầu; không nối tiếp payload bị cắt.
   Với stream lỗi đang tiếp tục, các byte trong thời gian busy bị bỏ qua;
   phần đuôi còn lại được xem như dữ liệu cần tìm magic mới.
6. Timeout FPGA đo từ byte hợp lệ gần nhất khi đã có byte magic đầu tiên,
   không áp dụng trong idle, compute hoặc phát response. 100 ms là khoảng
   cách giữa byte, không phải giới hạn tổng thời gian gói.
7. Đổi mode hủy parser, lõi nhân, accumulator và trạng thái valid của request.
   RAM không xóa toàn bộ; request mới ghi đủ A/B và xác minh checksum trước khi
   dùng lại. Mỗi lần vào Matrix mode cần RX idle cao liên tục **10 bit**
   (~86,8 µs) sau debounce trước khi nhận header, tránh dùng byte dở từ mode cũ.
   Chờ khoảng 50 ms sau thao tác switch trước khi bấm Calculate.
8. Byte TX đã được chấp nhận hoàn tất cả stop bit khi đổi mode; phần còn lại
   của response/hello bị hủy. Do đó có thể còn một byte trên dây khi LED đã
   chuyển idle/invalid. Reset vật lý có thể cắt byte đang phát.

Host dùng timeout response 3 giây. Khi buffer có dữ liệu dở và không có byte
mới trong 250 ms, host xóa phần dở để có thể tiếp tục nhận hello; nếu đang chờ
kết quả thì đồng thời báo lỗi và đóng cổng. Timeout có thể do switch sai mode
hoặc đổi mode giữa gói. Host cũng đóng cổng khi header/checksum/response lỗi
để response muộn không thể bị gán nhầm cho request sau. Kết nối lại, kiểm tra
Matrix mode và gửi lại. Mỗi kết nối mới xóa buffer nhận cũ. Không có transaction
ID nên không gửi đồng thời từ hai chương trình.

## Hello và ví dụ gói

Hello mode phát đúng `68 65 6C 6C 6F 0D 0A` (`hello\r\n`), lần đầu ngay
sau khi mode ổn định, sau đó xấp xỉ mỗi giây. Matrix command trong mode này
bị bỏ qua. Host ghi dòng hello vào log, không xem là kết quả.

Request A=B=0 có header `4D 58 01 00 01`, tiếp theo 256 byte `00`, checksum
`A7`. Response có header `4D 58 81 00 02`, 512 byte `00`, checksum `28`.
Tạo ví dụ chính xác không cần chép hàng trăm byte:

```python
request = bytes.fromhex('4d 58 01 00 01') + bytes(256)
request += bytes([sum(request) & 255])
assert len(request) == 262 and request[-1] == 0xa7
response = bytes.fromhex('4d 58 81 00 02') + bytes(512)
response += bytes([sum(response) & 255])
assert len(response) == 518 and response[-1] == 0x28
```

Ở 115200 baud, thời gian dây tối thiểu hai chiều là `(262+518)*10/115200`
≈ **67,71 ms**. Còn có chờ OS, adapter USB, Qt và handshake. GUI đo **round-trip**;
1088 clock / 50 MHz = **21,76 µs** là latency lõi được xác minh trong mô phỏng,
không phải số đo trên bo và không được suy ra từ thời gian round-trip.
MATRIX_UART_FILE_006_END

cat > host/main.py <<'MATRIX_UART_FILE_007_END'
"""GUI PyQt5 cho bộ nhân tuần tự 8 × 8 trên FPGA."""

import random
import sys
import time
from datetime import datetime

from PyQt5.QtCore import Qt
from PyQt5.QtWidgets import (
    QApplication, QCheckBox, QComboBox, QGridLayout, QGroupBox, QHBoxLayout,
    QLabel, QMainWindow, QPlainTextEdit, QPushButton, QSpinBox, QTableWidget,
    QTableWidgetItem, QVBoxLayout, QWidget,
)
from serial.tools import list_ports

from matrix_utils import multiply, validate_matrix
from serial_client import SerialClient


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Nhân ma trận 8 × 8 — Cyclone IV / UART")
        self.resize(1180, 1000)
        self.connected = False
        self.closing = False
        self.fpga_result = None
        self.python_result = None
        self.sent_inputs = None
        self.fpga_inputs = None
        self.python_inputs = None
        self.worker = SerialClient(self)

        central = QWidget()
        self.setCentralWidget(central)
        layout = QVBoxLayout(central)
        connection = QHBoxLayout()
        self.ports = QComboBox()
        self.ports.setMinimumWidth(250)
        refresh = QPushButton("Làm mới cổng")
        refresh.clicked.connect(self.refresh_ports)
        self.connect_button = QPushButton("Kết nối")
        self.connect_button.clicked.connect(self.connect_serial)
        self.disconnect_button = QPushButton("Ngắt kết nối")
        self.disconnect_button.clicked.connect(self.worker.disconnect_port)
        self.disconnect_button.setEnabled(False)
        self.connection_status = QLabel("Chưa kết nối")
        for widget in (QLabel("UART"), self.ports, refresh, QLabel("115200 baud / 8N1"),
                       self.connect_button, self.disconnect_button, self.connection_status):
            connection.addWidget(widget)
        layout.addLayout(connection)
        layout.addWidget(QLabel("SW1 ON: hello; SW2 ON: tính ma trận. Chờ ít nhất 50 ms sau khi đổi switch."))

        tables = QGridLayout()
        self.matrix_a = self.make_table("A — signed 16-bit", tables, 0, 0, True)
        self.matrix_b = self.make_table("B — signed 16-bit", tables, 0, 1, True)
        self.fpga_table = self.make_table("C FPGA — signed 64-bit", tables, 1, 0, False)
        self.python_table = self.make_table("C Python — tham chiếu", tables, 1, 1, False)
        layout.addLayout(tables)
        self.matrix_a.itemChanged.connect(self.inputs_changed)
        self.matrix_b.itemChanged.connect(self.inputs_changed)

        actions = QHBoxLayout()
        self.random_min = QSpinBox()
        self.random_max = QSpinBox()
        for spin in (self.random_min, self.random_max):
            spin.setRange(-32768, 32767)
        self.random_min.setValue(-10)
        self.random_max.setValue(10)
        actions.addWidget(QLabel("Ngẫu nhiên từ"))
        actions.addWidget(self.random_min)
        actions.addWidget(QLabel("đến"))
        actions.addWidget(self.random_max)
        self.action_buttons = []
        for title, callback in (("Tạo ngẫu nhiên", self.random_matrices),
                                ("Xóa ma trận", self.clear_matrices),
                                ("Nạp ví dụ", self.load_example),
                                ("Tính trên FPGA", self.calculate_fpga),
                                ("Tính bằng Python", self.calculate_python),
                                ("So sánh", self.compare_results)):
            button = QPushButton(title)
            button.clicked.connect(callback)
            self.action_buttons.append(button)
            actions.addWidget(button)
        layout.addLayout(actions)
        self.comparison = QLabel("Chưa so sánh")
        self.fpga_time = QLabel("UART round-trip: chưa đo")
        self.python_time = QLabel("Python: chưa đo")
        self.error_label = QLabel("")
        self.error_label.setStyleSheet("color: #b00020")
        self.error_label.setWordWrap(True)
        status = QHBoxLayout()
        for label in (self.comparison, self.fpga_time, self.python_time):
            status.addWidget(label)
        layout.addLayout(status)
        layout.addWidget(self.error_label)
        self.raw_hex = QCheckBox("Hiện raw hex")
        layout.addWidget(self.raw_hex)
        self.log_panel = QPlainTextEdit()
        self.log_panel.setReadOnly(True)
        self.log_panel.setMaximumBlockCount(5000)
        self.log_panel.setMaximumHeight(160)
        layout.addWidget(self.log_panel)

        self.worker.connection_changed.connect(self.connection_changed)
        self.worker.busy_changed.connect(self.set_busy)
        self.worker.log.connect(self.add_log)
        self.worker.raw.connect(self.add_raw)
        self.worker.error.connect(self.show_error)
        self.worker.result_received.connect(self.receive_result)
        self.worker.finished.connect(self.finish_close)
        self.refresh_ports()
        self.clear_matrices()
        self.worker.start()

    def make_table(self, title, layout, row, column, editable):
        box = QGroupBox(title)
        table = QTableWidget(8, 8)
        table.setHorizontalHeaderLabels([str(i + 1) for i in range(8)])
        table.setVerticalHeaderLabels([str(i + 1) for i in range(8)])
        for i in range(8):
            table.setColumnWidth(i, 62 if editable else 110)
        if not editable:
            table.setEditTriggers(QTableWidget.NoEditTriggers)
        box_layout = QVBoxLayout(box)
        box_layout.addWidget(table)
        layout.addWidget(box, row, column)
        return table

    def refresh_ports(self):
        previous = self.ports.currentData()
        self.ports.clear()
        for port in list_ports.comports():
            self.ports.addItem(f"{port.device} — {port.description}", port.device)
        index = self.ports.findData(previous)
        if index >= 0:
            self.ports.setCurrentIndex(index)

    def connect_serial(self):
        port = self.ports.currentData()
        if port is None:
            self.show_error("Không tìm thấy cổng serial; cắm adapter và làm mới danh sách.")
            return
        self.worker.connect_port(port)

    def connection_changed(self, connected, description):
        self.connected = connected
        self.connection_status.setText(f"● {description}")
        self.connection_status.setStyleSheet("color: green" if connected else "color: #666")
        self.connect_button.setEnabled(not connected)
        self.disconnect_button.setEnabled(connected)
        self.add_log(f"Kết nối: {description}")

    def add_log(self, message):
        self.log_panel.appendPlainText(f"{datetime.now().strftime('%H:%M:%S.%f')[:-3]}  {message}")

    def add_raw(self, direction, data):
        if self.raw_hex.isChecked():
            self.add_log(f"{direction} hex: {data.hex(' ')}")

    def show_error(self, message):
        self.error_label.setText(message)
        if self.fpga_result is None:
            self.comparison.setText("Chưa có kết quả FPGA hợp lệ")
        self.add_log(f"LỖI: {message}")

    def inputs_changed(self):
        self.fpga_result = None
        self.python_result = None
        self.fpga_inputs = None
        self.python_inputs = None
        self.fpga_table.clearContents()
        self.python_table.clearContents()
        self.comparison.setText("Chưa so sánh")
        self.fpga_time.setText("UART round-trip: chưa đo")
        self.python_time.setText("Python: chưa đo")
        self.error_label.clear()

    def fill_table(self, table, matrix):
        table.blockSignals(True)
        for i in range(8):
            for j in range(8):
                item = QTableWidgetItem(str(matrix[i][j]))
                item.setTextAlignment(Qt.AlignRight | Qt.AlignVCenter)
                table.setItem(i, j, item)
        table.blockSignals(False)

    def set_inputs(self, a, b):
        self.fill_table(self.matrix_a, a)
        self.fill_table(self.matrix_b, b)
        self.inputs_changed()

    def clear_matrices(self):
        self.set_inputs([[0] * 8 for _ in range(8)], [[0] * 8 for _ in range(8)])

    def random_matrices(self):
        low, high = self.random_min.value(), self.random_max.value()
        if low > high:
            self.show_error("Cận dưới ngẫu nhiên phải nhỏ hơn hoặc bằng cận trên.")
            return
        self.set_inputs([[random.randint(low, high) for _ in range(8)] for _ in range(8)],
                        [[random.randint(low, high) for _ in range(8)] for _ in range(8)])

    def load_example(self):
        self.set_inputs([[int(i == j) for j in range(8)] for i in range(8)],
                        [[i * 8 + j - 32 for j in range(8)] for i in range(8)])

    def read_inputs(self):
        matrices = []
        for table, name in ((self.matrix_a, "A"), (self.matrix_b, "B")):
            cells = [[table.item(i, j).text() if table.item(i, j) else ""
                      for j in range(8)] for i in range(8)]
            matrices.append(validate_matrix(cells, name))
        return matrices

    def calculate_fpga(self):
        try:
            if not self.connected:
                raise ValueError("Cần kết nối serial và bật SW2 để tính trên FPGA.")
            self.sent_inputs = self.read_inputs()
            self.fpga_result = None
            self.fpga_inputs = None
            self.fpga_table.clearContents()
            self.fpga_time.setText("UART round-trip: đang chờ")
            self.comparison.setText("Đang chờ FPGA")
            self.error_label.clear()
            self.set_busy(True)
            self.worker.calculate(*self.sent_inputs)
        except ValueError as exc:
            self.show_error(str(exc))

    def calculate_python(self):
        try:
            self.python_inputs = self.read_inputs()
            started = time.perf_counter()
            self.python_result = multiply(*self.python_inputs)
            self.python_time.setText(f"Python: {(time.perf_counter() - started) * 1000:.3f} ms")
            self.fill_table(self.python_table, self.python_result)
            self.error_label.clear()
        except ValueError as exc:
            self.show_error(str(exc))

    def receive_result(self, matrix, elapsed_ms):
        self.fpga_result = matrix
        self.fpga_inputs = self.sent_inputs
        self.fill_table(self.fpga_table, matrix)
        self.fpga_time.setText(f"UART round-trip: {elapsed_ms:.3f} ms (gồm truyền/nhận)")
        self.comparison.setText("Đã nhận FPGA; nhấn So sánh")
        self.add_log("RX: đã kiểm tra header, độ dài và checksum; hiển thị 64 kết quả")

    def compare_results(self):
        try:
            inputs = self.read_inputs()
            if self.fpga_result is None or self.fpga_inputs != inputs:
                raise ValueError("Cần kết quả FPGA cho đúng A/B hiện tại.")
            if self.python_result is None or self.python_inputs != inputs:
                self.calculate_python()
            passed = self.fpga_result == self.python_result
            self.comparison.setText("PASS: 64/64 phần tử bằng nhau" if passed else "FAIL: kết quả khác nhau")
            self.add_log(self.comparison.text())
        except ValueError as exc:
            self.show_error(str(exc))

    def set_busy(self, busy):
        self.matrix_a.setEnabled(not busy)
        self.matrix_b.setEnabled(not busy)
        for button in self.action_buttons:
            button.setEnabled(not busy)

    def closeEvent(self, event):
        if self.worker.isRunning():
            self.closing = True
            self.worker.stop()
            event.ignore()
        else:
            event.accept()

    def finish_close(self):
        if self.closing:
            self.close()


if __name__ == "__main__":
    app = QApplication(sys.argv)
    window = MainWindow()
    window.show()
    sys.exit(app.exec_())
MATRIX_UART_FILE_007_END

cat > host/matrix_utils.py <<'MATRIX_UART_FILE_008_END'
"""Phép tính tham chiếu và định dạng gói tin, không cần NumPy."""

import re
import struct

SIZE = 8
MAGIC = b"MX"
ERROR_CODES = {
    1: "Lệnh không hợp lệ",
    2: "Độ dài không hợp lệ",
    3: "Checksum không hợp lệ",
    4: "Hết thời gian nhận gói",
    5: "Lỗi stop bit UART",
}


def validate_matrix(matrix, name="Ma trận"):
    if len(matrix) != SIZE or any(len(row) != SIZE for row in matrix):
        raise ValueError(f"{name} phải có đúng 8 × 8 phần tử")
    result = []
    for i, row in enumerate(matrix):
        values = []
        for j, cell in enumerate(row):
            text = str(cell).strip()
            if not re.fullmatch(r"[+-]?[0-9]+", text):
                raise ValueError(f"{name}[{i + 1},{j + 1}]: cần số nguyên, không để trống")
            value = int(text)
            if not -32768 <= value <= 32767:
                raise ValueError(f"{name}[{i + 1},{j + 1}]: ngoài khoảng -32768..32767")
            values.append(value)
        result.append(values)
    return result


def multiply(a, b):
    a = validate_matrix(a, "A")
    b = validate_matrix(b, "B")
    return [[sum(a[i][k] * b[k][j] for k in range(SIZE))
             for j in range(SIZE)] for i in range(SIZE)]


def encode_request(a, b):
    a = validate_matrix(a, "A")
    b = validate_matrix(b, "B")
    values = [value for matrix in (a, b) for row in matrix for value in row]
    packet = MAGIC + struct.pack("<BH128h", 0x01, 256, *values)
    return packet + bytes([sum(packet) & 0xFF])


def decode_response(packet):
    if len(packet) < 6 or packet[:2] != MAGIC:
        raise ValueError("RX: thiếu magic hoặc gói chưa đầy đủ")
    command, length = struct.unpack_from("<BH", packet, 2)
    if (command, length) not in ((0x81, 512), (0xFF, 1)):
        raise ValueError("RX: lệnh hoặc độ dài phản hồi không hợp lệ")
    if len(packet) != length + 6:
        raise ValueError("RX: số byte phản hồi không đúng độ dài")
    if sum(packet[:-1]) & 0xFF != packet[-1]:
        raise ValueError("RX: checksum không hợp lệ")
    if command == 0xFF:
        code = packet[5]
        raise ValueError(f"FPGA lỗi 0x{code:02X}: {ERROR_CODES.get(code, 'Mã lỗi chưa biết')}")
    values = struct.unpack_from("<64q", packet, 5)
    return [list(values[i:i + SIZE]) for i in range(0, 64, SIZE)]
MATRIX_UART_FILE_008_END

cat > host/serial_client.py <<'MATRIX_UART_FILE_009_END'
"""Một QThread sở hữu cổng serial; GUI chỉ gửi lệnh qua Queue."""

import queue
import time

import serial
from PyQt5.QtCore import QThread, pyqtSignal

from matrix_utils import MAGIC, decode_response, encode_request


class StreamDecoder:
    """Tách dòng hello và gói nhị phân theo độ dài, kể cả khi đọc từng phần."""

    def __init__(self):
        self.buffer = bytearray()

    def feed(self, data):
        self.buffer.extend(data)
        events = []
        while self.buffer:
            if self.buffer.startswith(MAGIC):
                if len(self.buffer) < 5:
                    break
                command = self.buffer[2]
                length = int.from_bytes(self.buffer[3:5], "little")
                if (command, length) not in ((0x81, 512), (0xFF, 1)):
                    events.append(("error", "RX: lệnh hoặc độ dài phản hồi không hợp lệ"))
                    del self.buffer[0]
                    continue
                total = length + 6
                if len(self.buffer) < total:
                    break
                events.append(("packet", bytes(self.buffer[:total])))
                del self.buffer[:total]
                continue
            magic = self.buffer.find(MAGIC)
            newline = self.buffer.find(b"\n")
            if newline >= 0 and (magic < 0 or newline < magic):
                text = bytes(self.buffer[:newline + 1])
                del self.buffer[:newline + 1]
                events.append(("text", text.decode("ascii", errors="replace").rstrip("\r\n")))
            elif magic > 0:
                del self.buffer[:magic]
            elif len(self.buffer) > 200:
                # shortcut: chỉ giữ tối đa 200 byte text, tăng khi thêm lệnh text dài.
                del self.buffer[:-1]
            else:
                break
        return events


class SerialClient(QThread):
    connection_changed = pyqtSignal(bool, str)
    busy_changed = pyqtSignal(bool)
    result_received = pyqtSignal(object, float)
    log = pyqtSignal(str)
    raw = pyqtSignal(str, bytes)
    error = pyqtSignal(str)

    def __init__(self, parent=None, response_timeout=3.0):
        super().__init__(parent)
        self.commands = queue.Queue()
        self.response_timeout = response_timeout

    def connect_port(self, port, baudrate=115200):
        self.commands.put(("connect", (port, baudrate)))

    def disconnect_port(self):
        self.commands.put(("disconnect", None))

    def calculate(self, a, b):
        self.commands.put(("calculate", encode_request(a, b)))

    def stop(self):
        self.requestInterruption()
        self.commands.put(("stop", None))

    def run(self):
        port = None
        decoder = StreamDecoder()
        sent_at = None
        last_rx = None

        def clear_pending():
            nonlocal sent_at
            sent_at = None
            self.busy_changed.emit(False)

        def close_port():
            nonlocal port, decoder, last_rx
            if port is not None:
                port.close()
                port = None
            decoder = StreamDecoder()
            last_rx = None
            clear_pending()
            self.connection_changed.emit(False, "Chưa kết nối")

        try:
            while not self.isInterruptionRequested():
                try:
                    command, argument = self.commands.get(timeout=0.02 if port is None else 0)
                except queue.Empty:
                    command, argument = None, None
                try:
                    if command == "stop":
                        break
                    if command == "disconnect":
                        if sent_at is not None:
                            self.error.emit("Đã hủy yêu cầu FPGA khi ngắt kết nối")
                        close_port()
                        self.log.emit("Đã đóng cổng serial")
                    elif command == "connect":
                        close_port()
                        device, baudrate = argument
                        if baudrate != 115200:
                            raise ValueError("FPGA sử dụng cố định 115200 baud")
                        port = serial.Serial(device, baudrate, timeout=0.02, write_timeout=0.5)
                        port.reset_input_buffer()
                        self.connection_changed.emit(True, device)
                        self.log.emit(f"Kết nối {device}: 115200, 8N1")
                    elif command == "calculate":
                        if port is None:
                            raise ValueError("Chưa kết nối cổng serial")
                        if sent_at is not None:
                            raise ValueError("Đang chờ phản hồi; chỉ gửi một yêu cầu mỗi lần")
                        decoder = StreamDecoder()
                        port.reset_input_buffer()
                        sent_at = time.monotonic()
                        self.busy_changed.emit(True)
                        if port.write(argument) != len(argument):
                            raise serial.SerialTimeoutException("TX chưa gửi đủ gói tin")
                        self.raw.emit("TX", argument)
                        self.log.emit("TX: MX, lệnh 0x01, payload 256 byte, tổng 262 byte")
                    if port is not None:
                        data = port.read(min(max(port.in_waiting, 1), 1024))
                        if data:
                            last_rx = time.monotonic()
                            self.raw.emit("RX", data)
                        for kind, value in decoder.feed(data):
                            if kind == "text":
                                if value:
                                    self.log.emit(f"RX text: {value}")
                            elif kind == "error":
                                self.error.emit(value)
                                close_port()
                                break
                            else:
                                self.log.emit(f"RX: MX, lệnh 0x{value[2]:02X}, tổng {len(value)} byte")
                                try:
                                    matrix = decode_response(value)
                                except ValueError as exc:
                                    self.error.emit(str(exc))
                                    close_port()
                                    break
                                else:
                                    if sent_at is None:
                                        self.log.emit("RX: bỏ phản hồi không có yêu cầu đang chờ")
                                    else:
                                        elapsed_ms = (time.monotonic() - sent_at) * 1000
                                        self.result_received.emit(matrix, elapsed_ms)
                                        clear_pending()
                        # Đổi mode có thể cắt gói; xóa phần dở sau 250 ms không có byte mới.
                        if decoder.buffer and last_rx is not None and time.monotonic() - last_rx > 0.25:
                            decoder = StreamDecoder()
                            if sent_at is not None:
                                self.error.emit("RX: phản hồi bị ngắt giữa gói; đã đóng cổng, hãy kết nối lại.")
                                close_port()
                            else:
                                self.log.emit("RX: bỏ dữ liệu dở dang sau 250 ms không có byte mới")
                        if sent_at is not None and time.monotonic() - sent_at >= self.response_timeout:
                            self.error.emit("Hết thời gian chờ phản hồi; đã ngắt kết nối. Kiểm tra MODE 2 rồi kết nối lại.")
                            close_port()
                except (OSError, serial.SerialException, ValueError) as exc:
                    self.error.emit(str(exc))
                    close_port()
        finally:
            close_port()
MATRIX_UART_FILE_009_END

cat > quartus/matrix_multiplier.qpf <<'MATRIX_UART_FILE_010_END'
PROJECT_REVISION = "matrix_multiplier"
MATRIX_UART_FILE_010_END

cat > quartus/matrix_multiplier.qsf <<'MATRIX_UART_FILE_011_END'
set_global_assignment -name FAMILY "Cyclone IV E"
set_global_assignment -name DEVICE EP4CE6E22C8
set_global_assignment -name TOP_LEVEL_ENTITY top
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
set_global_assignment -name RESERVE_ALL_UNUSED_PINS "AS INPUT TRI-STATED"
set_global_assignment -name CYCLONEII_RESERVE_NCEO_AFTER_CONFIGURATION "USE AS REGULAR IO"
set_global_assignment -name ENABLE_INIT_DONE_OUTPUT OFF
set_global_assignment -name ENABLE_DEVICE_WIDE_RESET OFF
set_global_assignment -name ENABLE_DEVICE_WIDE_OE OFF
set_global_assignment -name VERILOG_FILE ../rtl/top.v
set_global_assignment -name VERILOG_FILE ../rtl/uart_rx.v
set_global_assignment -name VERILOG_FILE ../rtl/uart_tx.v
set_global_assignment -name VERILOG_FILE ../rtl/uart_protocol.v
set_global_assignment -name VERILOG_FILE ../rtl/mode_controller.v
set_global_assignment -name VERILOG_FILE ../rtl/matrix_multiplier.v
set_global_assignment -name SDC_FILE matrix_multiplier.sdc

# Pin table p1, V2.1 schematic p1, matching vendor EP4CE6 examples.
# LED order follows the pin table/examples; schematic LED net names are reversed.
set_location_assignment PIN_23 -to clk_50mhz
set_location_assignment PIN_25 -to reset_n
set_location_assignment PIN_88 -to {key_n[0]}
set_location_assignment PIN_89 -to {key_n[1]}
set_location_assignment PIN_87 -to {led_n[0]}
set_location_assignment PIN_86 -to {led_n[1]}
set_location_assignment PIN_85 -to {led_n[2]}
set_location_assignment PIN_84 -to {led_n[3]}
set_location_assignment PIN_114 -to uart_tx
set_location_assignment PIN_115 -to uart_rx
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to clk_50mhz
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to reset_n
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {key_n[*]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {led_n[*]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to uart_tx
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to uart_rx
MATRIX_UART_FILE_011_END

cat > quartus/matrix_multiplier.sdc <<'MATRIX_UART_FILE_012_END'
create_clock -name clk_50mhz -period 20.000 [get_ports {clk_50mhz}]
derive_clock_uncertainty
# Board buttons/UART are asynchronous; RTL synchronizes inputs and reset release.
set_false_path -from [get_ports {reset_n key_n[*] uart_rx}]
# UART and static LEDs have no external clock relationship.
set_false_path -to [get_ports {uart_tx led_n[*]}]
MATRIX_UART_FILE_012_END

cat > requirements.txt <<'MATRIX_UART_FILE_013_END'
PyQt5
pyserial
MATRIX_UART_FILE_013_END

cat > rtl/matrix_multiplier.v <<'MATRIX_UART_FILE_014_END'
`timescale 1ns / 1ps

module matrix_multiplier(
    input clk,
    input reset_n,
    input load_en,
    input load_matrix,
    input [5:0] load_addr,
    input signed [15:0] load_data,
    input start,
    output busy,
    output reg done,
    input [5:0] result_addr,
    output reg signed [63:0] result_data
);

localparam IDLE = 2'd0, READ = 2'd1, MAC = 2'd2, STORE = 2'd3;
reg [1:0] state;
reg [2:0] i, j, k;
reg signed [63:0] accumulator;
reg signed [15:0] a_data, b_data;
wire signed [31:0] product = a_data * b_data;
wire signed [63:0] extended_product = {{32{product[31]}}, product};

(* ramstyle = "M9K" *) reg signed [15:0] matrix_a [0:63];
(* ramstyle = "M9K" *) reg signed [15:0] matrix_b [0:63];
(* ramstyle = "M9K" *) reg signed [63:0] matrix_c [0:63];

assign busy = state != IDLE;

// Memories have no reset so Quartus can infer embedded RAM.
always @(posedge clk) begin
    if (reset_n && load_en && !busy) begin
        if (load_matrix)
            matrix_b[load_addr] <= load_data;
        else
            matrix_a[load_addr] <= load_data;
    end
    a_data <= matrix_a[{i, k}];
    b_data <= matrix_b[{k, j}];
    if (reset_n && state == STORE)
        matrix_c[{i, j}] <= accumulator;
    result_data <= matrix_c[result_addr];
end

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        state <= IDLE;
        i <= 0;
        j <= 0;
        k <= 0;
        accumulator <= 0;
        done <= 0;
    end else begin
        done <= 0;
        case (state)
            IDLE: if (start) begin
                i <= 0;
                j <= 0;
                k <= 0;
                accumulator <= 0;
                state <= READ;
            end
            READ: state <= MAC;
            MAC: begin
                accumulator <= accumulator + extended_product;
                if (k == 7)
                    state <= STORE;
                else begin
                    k <= k + 1'b1;
                    state <= READ;
                end
            end
            STORE: begin
                accumulator <= 0;
                k <= 0;
                if (j == 7) begin
                    j <= 0;
                    if (i == 7) begin
                        done <= 1;
                        state <= IDLE;
                    end else begin
                        i <= i + 1'b1;
                        state <= READ;
                    end
                end else begin
                    j <= j + 1'b1;
                    state <= READ;
                end
            end
            default: state <= IDLE;
        endcase
    end
end

endmodule
MATRIX_UART_FILE_014_END

cat > rtl/mode_controller.v <<'MATRIX_UART_FILE_015_END'
`timescale 1ns/1ps
module mode_controller #(
    parameter integer DEBOUNCE_CYCLES = 500000
)(
    input clk, input reset_n, input [1:0] key_n,
    output reg [1:0] mode, output changed, output reg [3:0] led_n
);
    reg [1:0] key_meta, key_sync, candidate, previous_mode;
    integer stable_count;
    assign changed = mode != previous_mode;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            key_meta <= 2'b11; key_sync <= 2'b11; candidate <= 0;
            mode <= 0; previous_mode <= 0; stable_count <= 0;
        end else begin
            key_meta <= key_n; key_sync <= key_meta;
            previous_mode <= mode;
            if (~key_sync != candidate) begin
                candidate <= ~key_sync; stable_count <= 0;
            end else if (stable_count < DEBOUNCE_CYCLES-1) stable_count <= stable_count+1;
            else mode <= candidate;
        end
    end
    always @* begin
        case (mode)
            1: led_n = 4'b1110;
            2: led_n = 4'b1101;
            default: led_n = 4'b1111;
        endcase
    end
endmodule
MATRIX_UART_FILE_015_END

cat > rtl/top.v <<'MATRIX_UART_FILE_016_END'
`timescale 1ns/1ps
module top #(
    parameter integer CLOCK_HZ = 50000000,
    parameter integer BAUD = 115200,
    parameter integer CLKS_PER_BIT = (CLOCK_HZ+BAUD/2)/BAUD,
    parameter integer DEBOUNCE_CYCLES = CLOCK_HZ/100,
    parameter integer HELLO_CYCLES = CLOCK_HZ,
    parameter integer TIMEOUT_CYCLES = CLOCK_HZ/10
)(
    input clk_50mhz, input reset_n, input [1:0] key_n,
    input uart_rx, output uart_tx, output [3:0] led_n
);
    reg [1:0] reset_sync;
    wire reset_ready = reset_sync[1];
    always @(posedge clk_50mhz or negedge reset_n)
        if (!reset_n) reset_sync <= 0;
        else reset_sync <= {reset_sync[0], 1'b1};

    wire [1:0] mode;
    wire mode_changed;
    mode_controller #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)) modes(
        .clk(clk_50mhz), .reset_n(reset_ready), .key_n(key_n),
        .mode(mode), .changed(mode_changed), .led_n(led_n)
    );

    reg [1:0] rx_sync;
    integer idle_count;
    reg rx_armed;
    always @(posedge clk_50mhz or negedge reset_ready) begin
        if (!reset_ready) begin rx_sync <= 2'b11; idle_count <= 0; rx_armed <= 0; end
        else begin
            rx_sync <= {rx_sync[0], uart_rx};
            if (mode != 2 || mode_changed) begin idle_count <= 0; rx_armed <= 0; end
            else if (!rx_armed) begin
                // A whole idle character discards any byte crossing the mode boundary.
                if (!rx_sync[1]) idle_count <= 0;
                else if (idle_count == 10*CLKS_PER_BIT-1) rx_armed <= 1;
                else idle_count <= idle_count+1;
            end
        end
    end
    wire matrix_enable = mode == 2 && !mode_changed && rx_armed;
    wire [7:0] rx_data, protocol_data;
    wire rx_valid, rx_error, protocol_valid, tx_ready;
    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) receiver(
        .clk(clk_50mhz), .reset_n(reset_ready), .enable(matrix_enable),
        .rx(uart_rx), .data(rx_data), .valid(rx_valid), .framing_error(rx_error)
    );
    uart_protocol #(.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) protocol(
        .clk(clk_50mhz), .reset_n(reset_ready), .enable(matrix_enable),
        .rx_data(rx_data), .rx_valid(rx_valid), .rx_error(rx_error),
        .tx_data(protocol_data), .tx_valid(protocol_valid), .tx_ready(tx_ready), .busy()
    );

    integer hello_count;
    reg [2:0] hello_index;
    reg hello_active;
    reg [7:0] hello_data;
    always @* begin
        case (hello_index)
            0: hello_data = "h";
            1: hello_data = "e";
            2,3: hello_data = "l";
            4: hello_data = "o";
            5: hello_data = 8'h0d;
            default: hello_data = 8'h0a;
        endcase
    end
    wire hello_valid = mode == 1 && !mode_changed && hello_active;
    always @(posedge clk_50mhz or negedge reset_ready) begin
        if (!reset_ready) begin hello_count <= 0; hello_index <= 0; hello_active <= 0; end
        else if (mode != 1 || mode_changed) begin
            hello_count <= 0; hello_index <= 0; hello_active <= 0;
        end else begin
            if (hello_count != 0) hello_count <= hello_count-1;
            else if (!hello_active) begin hello_active <= 1; hello_index <= 0; hello_count <= HELLO_CYCLES-1; end
            if (hello_valid && tx_ready) begin
                if (hello_index == 6) hello_active <= 0;
                else hello_index <= hello_index+1'b1;
            end
        end
    end
    // Mode changes clear producers; the transmitter finishes its accepted byte.
    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) transmitter(
        .clk(clk_50mhz), .reset_n(reset_ready),
        .data(mode == 1 ? hello_data : protocol_data),
        .valid(hello_valid || protocol_valid), .ready(tx_ready), .tx(uart_tx), .busy()
    );
endmodule
MATRIX_UART_FILE_016_END

cat > rtl/uart_protocol.v <<'MATRIX_UART_FILE_017_END'
`timescale 1ns/1ps
module uart_protocol #(
    parameter integer TIMEOUT_CYCLES = 5000000
)(
    input clk, input reset_n, input enable,
    input [7:0] rx_data, input rx_valid, input rx_error,
    output reg [7:0] tx_data, output tx_valid, input tx_ready,
    output busy
);
    localparam MAGIC1=0, MAGIC2=1, COMMAND=2, LENGTH_LO=3, LENGTH_HI=4,
               PAYLOAD=5, CHECKSUM=6, COMPUTE=7, RESPONSE_PREP=8, RESPONSE_SEND=9;
    reg [3:0] state;
    reg [7:0] checksum, payload_index, low_byte, error_code;
    reg [9:0] tx_index;
    integer timeout_count;
    reg load_en, load_matrix, start;
    reg [5:0] load_addr;
    reg signed [15:0] load_data;
    wire done;
    wire signed [63:0] result_data;
    wire [9:0] payload_offset = tx_index-10'd5;
    wire [5:0] result_addr = payload_offset[8:3];
    wire core_reset_n = reset_n && enable;

    matrix_multiplier core(
        .clk(clk), .reset_n(core_reset_n),
        .load_en(load_en), .load_matrix(load_matrix), .load_addr(load_addr),
        .load_data(load_data), .start(start), .busy(), .done(done),
        .result_addr(result_addr), .result_data(result_data)
    );
    assign busy = state >= COMPUTE;
    assign tx_valid = enable && state == RESPONSE_SEND;
    always @* begin
        case (tx_index)
            0: tx_data = 8'h4d;
            1: tx_data = 8'h58;
            2: tx_data = error_code == 0 ? 8'h81 : 8'hff;
            3: tx_data = error_code == 0 ? 8'h00 : 8'h01;
            4: tx_data = error_code == 0 ? 8'h02 : 8'h00;
            default: begin
                if (error_code != 0)
                    tx_data = tx_index == 5 ? error_code : checksum;
                else if (tx_index == 517) tx_data = checksum;
                else tx_data = result_data >> {payload_offset[2:0], 3'b000};
            end
        endcase
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= MAGIC1; checksum <= 0; payload_index <= 0; low_byte <= 0;
            error_code <= 0; tx_index <= 0; timeout_count <= 0;
            load_en <= 0; load_matrix <= 0; load_addr <= 0; load_data <= 0; start <= 0;
        end else begin
            load_en <= 0; start <= 0;
            if (!enable) begin
                state <= MAGIC1; checksum <= 0; payload_index <= 0;
                error_code <= 0; tx_index <= 0; timeout_count <= 0;
            end else if (state < COMPUTE && rx_error) begin
                error_code <= 5; tx_index <= 0; checksum <= 0;
                timeout_count <= 0; state <= RESPONSE_PREP;
            end else if (state > MAGIC1 && state < COMPUTE &&
                         !rx_valid && timeout_count == TIMEOUT_CYCLES-1) begin
                error_code <= 4; tx_index <= 0; checksum <= 0;
                timeout_count <= 0; state <= RESPONSE_PREP;
            end else begin
                if (state == MAGIC1 || state >= COMPUTE || rx_valid) timeout_count <= 0;
                else timeout_count <= timeout_count+1;
                if (state < COMPUTE && rx_valid) begin
                    checksum <= checksum+rx_data;
                    case (state)
                        MAGIC1: if (rx_data == 8'h4d) begin
                            checksum <= 8'h4d; state <= MAGIC2;
                        end
                        MAGIC2: if (rx_data == 8'h58) state <= COMMAND;
                            else if (rx_data == 8'h4d) checksum <= 8'h4d;
                            else state <= MAGIC1;
                        COMMAND: if (rx_data == 1) state <= LENGTH_LO;
                            else begin error_code <= 1; state <= RESPONSE_PREP; checksum <= 0; tx_index <= 0; end
                        LENGTH_LO: if (rx_data == 0) state <= LENGTH_HI;
                            else begin error_code <= 2; state <= RESPONSE_PREP; checksum <= 0; tx_index <= 0; end
                        LENGTH_HI: if (rx_data == 1) begin
                            payload_index <= 0; state <= PAYLOAD;
                        end else begin error_code <= 2; state <= RESPONSE_PREP; checksum <= 0; tx_index <= 0; end
                        PAYLOAD: begin
                            if (!payload_index[0]) low_byte <= rx_data;
                            else begin
                                load_en <= 1; load_matrix <= payload_index[7];
                                load_addr <= payload_index[6:1]; load_data <= {rx_data, low_byte};
                            end
                            if (payload_index == 255) state <= CHECKSUM;
                            else payload_index <= payload_index+1'b1;
                        end
                        CHECKSUM: begin
                            checksum <= 0; tx_index <= 0;
                            if (rx_data == checksum) begin
                                start <= 1; error_code <= 0; state <= COMPUTE;
                            end else begin error_code <= 3; state <= RESPONSE_PREP; end
                        end
                        default: state <= MAGIC1;
                    endcase
                end else if (state == COMPUTE && done) begin
                    state <= RESPONSE_PREP; tx_index <= 0; checksum <= 0;
                end else if (state == RESPONSE_PREP) begin
                    // One clock lets the synchronous result RAM read settle.
                    state <= RESPONSE_SEND;
                end else if (state == RESPONSE_SEND && tx_ready) begin
                    if ((error_code != 0 && tx_index == 6) || tx_index == 517) begin
                        state <= MAGIC1; checksum <= 0;
                    end else begin
                        checksum <= checksum+tx_data; tx_index <= tx_index+1'b1;
                        state <= RESPONSE_PREP;
                    end
                end
            end
        end
    end
endmodule
MATRIX_UART_FILE_017_END

cat > rtl/uart_rx.v <<'MATRIX_UART_FILE_018_END'
`timescale 1ns/1ps
module uart_rx #(
    parameter integer CLKS_PER_BIT = 434
)(
    input clk, input reset_n, input enable, input rx,
    output reg [7:0] data, output reg valid, output reg framing_error
);
    localparam IDLE=0, START=1, DATA=2, STOP=3, RECOVER=4;
    reg [2:0] state;
    reg [1:0] rx_sync;
    integer count;
    reg [2:0] bit_index;
    reg [7:0] shift;

    always @(posedge clk or negedge reset_n)
        if (!reset_n) rx_sync <= 2'b11;
        else rx_sync <= {rx_sync[0], rx};

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= IDLE; count <= 0; bit_index <= 0;
            shift <= 0; data <= 0; valid <= 0; framing_error <= 0;
        end else begin
            valid <= 0;
            framing_error <= 0;
            if (!enable) begin
                state <= IDLE; count <= 0; bit_index <= 0;
            end else case (state)
                IDLE: if (!rx_sync[1]) begin
                    count <= CLKS_PER_BIT/2-1;
                    state <= START;
                end
                START: if (count != 0) count <= count-1;
                    else if (rx_sync[1]) state <= IDLE;
                    else begin
                        count <= CLKS_PER_BIT-1; bit_index <= 0; state <= DATA;
                    end
                DATA: if (count != 0) count <= count-1;
                    else begin
                        shift[bit_index] <= rx_sync[1];
                        count <= CLKS_PER_BIT-1;
                        if (bit_index == 7) state <= STOP;
                        else bit_index <= bit_index+1'b1;
                    end
                STOP: if (count != 0) count <= count-1;
                    else if (rx_sync[1]) begin
                        data <= shift; valid <= 1; state <= IDLE;
                    end else begin
                        framing_error <= 1; state <= RECOVER;
                    end
                RECOVER: if (rx_sync[1]) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
MATRIX_UART_FILE_018_END

cat > rtl/uart_tx.v <<'MATRIX_UART_FILE_019_END'
`timescale 1ns/1ps
module uart_tx #(
    parameter integer CLKS_PER_BIT = 434
)(
    input clk, input reset_n,
    input [7:0] data, input valid,
    output ready, output tx, output reg busy
);
    reg [9:0] frame;
    reg [3:0] bit_index;
    integer count;
    assign ready = !busy;
    assign tx = busy ? frame[0] : 1'b1;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            busy <= 0; frame <= 10'h3ff; bit_index <= 0; count <= 0;
        end else if (!busy) begin
            if (valid) begin
                frame <= {1'b1, data, 1'b0};
                busy <= 1; bit_index <= 0; count <= CLKS_PER_BIT-1;
            end
        end else if (count != 0) count <= count-1;
        else if (bit_index == 9) busy <= 0;
        else begin
            frame <= {1'b1, frame[9:1]};
            bit_index <= bit_index+1'b1;
            count <= CLKS_PER_BIT-1;
        end
    end
endmodule
MATRIX_UART_FILE_019_END

cat > scripts/run_sim.sh <<'MATRIX_UART_FILE_020_END'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
IVERILOG=${IVERILOG:-iverilog}
VVP=${VVP:-vvp}
command -v "$IVERILOG" >/dev/null || { echo 'FAIL: install Icarus Verilog (iverilog)' >&2; exit 1; }
command -v "$VVP" >/dev/null || { echo 'FAIL: install vvp' >&2; exit 1; }
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT
for testbench in tb_matrix_multiplier tb_uart tb_top; do
    "$IVERILOG" -g2005 -Wall -s "$testbench" -o "$build_dir/$testbench" "sim/$testbench.v" rtl/*.v
    "$VVP" "$build_dir/$testbench"
done
echo 'PASS: all RTL simulations'
MATRIX_UART_FILE_020_END

cat > sim/tb_matrix_multiplier.v <<'MATRIX_UART_FILE_021_END'
`timescale 1ns / 1ps

module tb_matrix_multiplier;
reg clk = 0;
reg reset_n = 0;
reg load_en = 0;
reg load_matrix = 0;
reg [5:0] load_addr = 0;
reg signed [15:0] load_data = 0;
reg start = 0;
wire busy, done;
reg [5:0] result_addr = 0;
wire signed [63:0] result_data;
reg signed [15:0] a [0:63];
reg signed [15:0] b [0:63];
integer test_id;

always #10 clk = !clk;

matrix_multiplier dut(
    .clk(clk), .reset_n(reset_n), .load_en(load_en),
    .load_matrix(load_matrix), .load_addr(load_addr), .load_data(load_data),
    .start(start), .busy(busy), .done(done),
    .result_addr(result_addr), .result_data(result_data)
);

task prepare;
    input integer pattern;
    integer n;
    begin
        for (n = 0; n < 64; n = n + 1) begin
            case (pattern)
                0: begin a[n] = 0; b[n] = 0; end
                1: begin a[n] = (n / 8 == n % 8); b[n] = n - 32; end
                2: begin a[n] = 1; b[n] = 1; end
                3: begin a[n] = n + 1; b[n] = 64 - n; end
                4: begin a[n] = -n - 1; b[n] = n - 64; end
                5: begin a[n] = (n % 2) ? -32768 : 32767;
                         b[n] = (n % 3) ? n - 31 : -n; end
                6: begin a[n] = 32767; b[n] = 32767; end
                7: begin a[n] = -32768; b[n] = -32768; end
                default: begin a[n] = -32768; b[n] = 32767; end
            endcase
        end
    end
endtask

task load_inputs;
    integer n, matrix_index;
    begin
        for (matrix_index = 0; matrix_index < 2; matrix_index = matrix_index + 1)
            for (n = 0; n < 64; n = n + 1) begin
                @(negedge clk);
                load_en = 1;
                load_matrix = matrix_index;
                load_addr = n;
                load_data = matrix_index ? b[n] : a[n];
            end
        @(negedge clk);
        load_en = 0;
    end
endtask

task calculate_and_check;
    integer cycles, mac_count, row, col, term;
    reg signed [63:0] expected, left_value, right_value;
    begin
        @(negedge clk);
        start = 1;
        @(posedge clk);
        #1;
        if (!busy || done)
            $fatal(1, "Start did not enter computation");
        @(negedge clk);
        start = 0;
        cycles = 0;
        mac_count = 0;
        while (!done && cycles < 1200) begin
            @(posedge clk);
            if (dut.state == 2'd2)
                mac_count = mac_count + 1;
            #1;
            cycles = cycles + 1;
        end
        if (!done || busy || cycles != 1088 || mac_count != 512)
            $fatal(1, "Control: done=%b busy=%b cycles=%0d MACs=%0d",
                   done, busy, cycles, mac_count);
        for (row = 0; row < 8; row = row + 1)
            for (col = 0; col < 8; col = col + 1) begin
                expected = 0;
                for (term = 0; term < 8; term = term + 1) begin
                    left_value = a[row * 8 + term];
                    right_value = b[term * 8 + col];
                    expected = expected + left_value * right_value;
                end
                @(negedge clk);
                result_addr = row * 8 + col;
                @(posedge clk);
                #1;
                if (result_data !== expected)
                    $fatal(1, "Pattern %0d C[%0d,%0d]: expected %0d got %0d",
                           test_id, row, col, expected, result_data);
                if (done)
                    $fatal(1, "Done must pulse for only one clock");
            end
        $display("PASS matrix pattern %0d: 64 results, 512 MACs, 1088 clocks", test_id);
    end
endtask

initial begin
    repeat (3) @(negedge clk);
    reset_n = 1;
    for (test_id = 0; test_id < 9; test_id = test_id + 1) begin
        prepare(test_id);
        load_inputs;
        calculate_and_check;
    end
    // Repeat without reset or reloading to prove input storage is retained.
    test_id = 8;
    calculate_and_check;
    @(negedge clk);
    start = 1;
    @(negedge clk);
    start = 0;
    repeat (41) @(negedge clk);
    reset_n = 0;
    #1;
    if (busy || done)
        $fatal(1, "Reset failed to abort computation");
    repeat (3) @(negedge clk);
    reset_n = 1;
    repeat (1200) begin
        @(posedge clk);
        #1;
        if (busy || done)
            $fatal(1, "Aborted operation resumed after reset");
    end
    test_id = 5;
    prepare(test_id);
    load_inputs;
    calculate_and_check;
    $display("PASS tb_matrix_multiplier: arithmetic, repeated runs, reset recovery");
    $finish;
end

initial begin
    #1000000;
    $fatal(1, "Matrix simulation timeout");
end
endmodule
MATRIX_UART_FILE_021_END

cat > sim/tb_top.v <<'MATRIX_UART_FILE_022_END'
`timescale 1ns/1ps
module tb_top;
    localparam CPB=16, BIT_NS=CPB*20, HELLO_CYCLES=1600;
    reg clk=0, reset_n=0;
    reg [1:0] key_n=2'b11;
    reg rx=1;
    wire tx;
    wire [3:0] led_n;
    reg [7:0] received[0:8191];
    time received_time[0:8191];
    integer received_count=0, completed=0;
    integer base, n, m, saved;
    reg [7:0] byte_value;
    integer bit_index;
    reg [7:0] sum;
    reg signed [63:0] value;
    always #10 clk=~clk;
    top #(.CLKS_PER_BIT(CPB), .DEBOUNCE_CYCLES(8),
          .HELLO_CYCLES(HELLO_CYCLES), .TIMEOUT_CYCLES(4000)) dut(
        .clk_50mhz(clk), .reset_n(reset_n), .key_n(key_n),
        .uart_rx(rx), .uart_tx(tx), .led_n(led_n)
    );
    always @(posedge clk) if (dut.protocol.core.done) completed=completed+1;

    // Independent wire decoder checks every transmitted stop bit.
    initial forever begin
        @(negedge tx);
        #(BIT_NS/2);
        if (tx !== 0) $fatal(1,"Short TX start");
        for (bit_index=0;bit_index<8;bit_index=bit_index+1) begin
            #(BIT_NS); byte_value[bit_index]=tx;
        end
        #(BIT_NS);
        if (tx !== 1) $fatal(1,"Bad TX stop / truncated byte on mode change");
        received[received_count]=byte_value;
        received_time[received_count]=$time;
        received_count=received_count+1;
    end
    task wait_bytes;
        input integer target;
        integer ticks;
        begin
            ticks=0;
            while (received_count<target && ticks<200000) begin
                @(negedge clk); ticks=ticks+1;
            end
            if (received_count<target) $fatal(1,"TX timeout: got%0d need%0d",received_count,target);
        end
    endtask
    task mode;
        input [1:0] enabled;
        input [3:0] expected_led;
        begin
            key_n=~enabled;
            repeat(24) @(negedge clk);
            if (led_n !== expected_led) $fatal(1,"Mode%0d LED=%b",enabled,led_n);
        end
    endtask
    task send_byte;
        input [7:0] data;
        integer b;
        begin
            rx=0; #(BIT_NS);
            for (b=0;b<8;b=b+1) begin rx=data[b]; #(BIT_NS); end
            rx=1; #(BIT_NS);
        end
    endtask
    task send_request;
        integer index;
        reg [7:0] checksum;
        reg signed [15:0] element;
        begin
            send_byte(8'h4d); send_byte(8'h58); send_byte(1);
            send_byte(0); send_byte(1); checksum=8'ha7;
            for (index=0;index<128;index=index+1) begin
                if (index<64) element=(index/8==index%8);
                else element=index-96;
                send_byte(element[7:0]); send_byte(element[15:8]);
                checksum=checksum+element[7:0]+element[15:8];
            end
            send_byte(checksum);
        end
    endtask
    task check_result;
        input integer offset;
        integer index,b;
        reg [7:0] checksum;
        reg signed [63:0] element;
        begin
            wait_bytes(offset+518);
            if (received[offset]!==8'h4d || received[offset+1]!==8'h58 ||
                received[offset+2]!==8'h81 || received[offset+3]!==0 || received[offset+4]!==2)
                $fatal(1,"Bad response header");
            checksum=0;
            for (index=0;index<517;index=index+1) checksum=checksum+received[offset+index];
            if (checksum!==received[offset+517]) $fatal(1,"Bad response checksum");
            for (index=0;index<64;index=index+1) begin
                for (b=0;b<8;b=b+1) element[b*8+:8]=received[offset+5+index*8+b];
                if (element !== index-32) $fatal(1,"Result[%0d]=%0d",index,element);
            end
        end
    endtask
    task check_hello;
        input integer offset;
        begin
            if (received[offset]!=="h" || received[offset+1]!=="e" ||
                received[offset+2]!=="l" || received[offset+3]!=="l" ||
                received[offset+4]!=="o" || received[offset+5]!==13 || received[offset+6]!==10)
                $fatal(1,"Incorrect hello line at%0d",offset);
        end
    endtask
    initial begin
        #100; reset_n=1;
        repeat(30) @(negedge clk);
        if (led_n!==15 || tx!==1) $fatal(1,"Idle reset");
        key_n=2'b10; repeat(3) @(negedge clk); key_n=2'b11;
        repeat(30) @(negedge clk);
        if (led_n!==15 || received_count!=0) $fatal(1,"Switch bounce accepted");
        send_request();
        if (received_count!=0 || completed!=0) $fatal(1,"Idle processed request");

        base=received_count; mode(1,4'b1110);
        wait_bytes(base+14); check_hello(base); check_hello(base+7);
        if (received_time[base+7]-received_time[base] != HELLO_CYCLES*20)
            $fatal(1,"Hello interval incorrect");
        fork
            send_request();
            begin repeat(45000) @(negedge clk); end
        join
        if (completed!=0) $fatal(1,"Hello processed matrix");

        // Stop during a fresh hello byte; it must finish with no following byte.
        @(negedge tx); saved=received_count;
        #(BIT_NS); mode(0,15);
        wait_bytes(saved+1); #(BIT_NS*12);
        if (received_count!=saved+1 || tx!==1) $fatal(1,"Idle launched extra TX");

        // A byte started in idle must not form the new matrix packet header.
        fork
            begin send_byte(8'h4d); send_byte(8'h58); end
            begin #(BIT_NS*2); mode(2,4'b1101); end
        join
        #(BIT_NS*14);
        if (!dut.rx_armed || dut.protocol.state!=0) $fatal(1,"Stale RX / not rearmed");
        base=received_count; send_request(); check_result(base);
        base=received_count; send_request(); check_result(base);
        if (completed!=2) $fatal(1,"Repeated calculation count");

        // Leaving Matrix during MAC must cancel computation without a response.
        #(BIT_NS); saved=received_count; send_request();
        wait(dut.protocol.core.busy);
        mode(0,15); repeat(1500) @(negedge clk);
        if (completed!=2 || received_count!=saved || dut.protocol.core.busy)
            $fatal(1,"Mode change failed to abort calculation");
        mode(2,4'b1101); #(BIT_NS*12);

        // Abort incomplete input in invalid mode; no reply or calculation follows.
        #(BIT_NS); send_byte(8'h4d); send_byte(8'h58); send_byte(1); send_byte(0);
        mode(3,15); saved=received_count;
        send_request(); #(BIT_NS*15);
        if (received_count!=saved || completed!=2 || tx!==1) $fatal(1,"Invalid mode active");
        mode(2,4'b1101); #(BIT_NS*12);
        base=received_count; send_request(); check_result(base);

        // Abort response on a mode transition; finish the in-flight byte only.
        #(BIT_NS); send_request();
        @(negedge tx); saved=received_count;
        #(BIT_NS); mode(3,15);
        wait_bytes(saved+1); #(BIT_NS*12);
        if (received_count!=saved+1 || tx!==1) $fatal(1,"Response continued in invalid mode");
        mode(1,4'b1110); base=received_count;
        wait_bytes(base+7); check_hello(base);
        mode(0,15); #(BIT_NS*20);
        $display("PASS tb_top: four modes, LEDs, debounce, repeated hello, continuous UART packets, mode abort/recovery, TX byte completion");
        $finish;
    end
    initial begin #200000000; $fatal(1,"Top watchdog"); end
endmodule
MATRIX_UART_FILE_022_END

cat > sim/tb_uart.v <<'MATRIX_UART_FILE_023_END'
`timescale 1ns / 1ps

module tb_uart;
reg clk = 0;
reg reset_n = 0;
always #10 clk = !clk;

reg [7:0] byte16 = 0, byte434 = 0;
reg valid16 = 0, valid434 = 0;
wire ready16, ready434, tx16, tx434;
reg loopback16 = 1, manual_rx = 1;
wire [7:0] received16, received434;
wire received_valid16, received_valid434, framing16, framing434;
reg [7:0] expected16 [0:511];
integer queued16 = 0, count16 = 0, count434 = 0, errors16 = 0;

uart_tx #(.CLKS_PER_BIT(16)) tx_fast(
    .clk(clk), .reset_n(reset_n), .data(byte16), .valid(valid16),
    .ready(ready16), .tx(tx16), .busy()
);
uart_rx #(.CLKS_PER_BIT(16)) rx_fast(
    .clk(clk), .reset_n(reset_n), .enable(1'b1),
    .rx(loopback16 ? tx16 : manual_rx), .data(received16),
    .valid(received_valid16), .framing_error(framing16)
);
// Default divider verifies the actual 50 MHz / 115200 baud configuration.
uart_tx tx_real(
    .clk(clk), .reset_n(reset_n), .data(byte434), .valid(valid434),
    .ready(ready434), .tx(tx434), .busy()
);
uart_rx rx_real(
    .clk(clk), .reset_n(reset_n), .enable(1'b1), .rx(tx434),
    .data(received434), .valid(received_valid434), .framing_error(framing434)
);

always @(posedge clk) begin
    #1;
    if (reset_n && received_valid16) begin
        if (count16 >= queued16 || received16 !== expected16[count16])
            $fatal(1, "16-clock UART byte %0d mismatch: %h", count16, received16);
        count16 = count16 + 1;
    end
    if (reset_n && framing16)
        errors16 = errors16 + 1;
    if (reset_n && received_valid434) begin
        if (count434 >= 256 || received434 !== (count434 & 255))
            $fatal(1, "434-clock UART byte %0d mismatch: %h", count434, received434);
        count434 = count434 + 1;
    end
    if (reset_n && framing434)
        $fatal(1, "Framing error at hardware baud divider");
end

task manual_frame;
    input [7:0] value;
    input good_stop;
    integer bit_number;
    begin
        manual_rx = 0;
        #320;
        for (bit_number = 0; bit_number < 8; bit_number = bit_number + 1) begin
            manual_rx = value[bit_number];
            #320;
        end
        manual_rx = good_stop;
        #320;
    end
endtask

task physical_fast;
    integer n, original_count;
    begin
        for (n = 0; n < 256; n = n + 1) begin
            @(negedge clk);
            while (!ready16) @(negedge clk);
            expected16[queued16] = n;
            queued16 = queued16 + 1;
            byte16 = n;
            valid16 = 1;
            @(negedge clk);
            valid16 = 0;
        end
        wait(ready16);
        repeat (20) @(negedge clk);
        if (count16 != 256)
            $fatal(1, "Missing loopback bytes at divider16");
        loopback16 = 0;
        // No extra idle time between these asynchronously aligned frames.
        #7;
        for (n = 0; n < 32; n = n + 1) begin
            expected16[queued16] = 255 - n;
            queued16 = queued16 + 1;
            manual_frame(255 - n, 1);
        end
        repeat (20) @(negedge clk);
        if (count16 != 288)
            $fatal(1, "Missing continuous manually timed RX bytes");
        original_count = count16;
        manual_frame(8'h00, 0);
        manual_rx = 1;
        repeat (32) @(negedge clk);
        if (errors16 != 1 || count16 != original_count)
            $fatal(1, "Bad stop bit was not rejected");
        manual_rx = 0;
        #80;
        manual_rx = 1;
        #640;
        if (count16 != original_count || errors16 != 1)
            $fatal(1, "Short start glitch was not rejected");
        expected16[queued16] = 8'ha5;
        queued16 = queued16 + 1;
        manual_frame(8'ha5, 1);
        repeat (20) @(negedge clk);
        if (count16 != queued16)
            $fatal(1, "RX did not recover after malformed frames");
        $display("PASS UART divider16: all256bytes, continuous RX, start/stop rejection");
    end
endtask

task physical_real;
    integer n;
    begin
        for (n = 0; n < 256; n = n + 1) begin
            @(negedge clk);
            while (!ready434) @(negedge clk);
            byte434 = n;
            valid434 = 1;
            @(negedge clk);
            valid434 = 0;
        end
        wait(ready434);
        repeat (500) @(negedge clk);
        if (count434 != 256)
            $fatal(1, "Missing bytes at hardware baud divider");
        $display("PASS UART divider434: all256bytes at 50MHz, 115200 baud");
    end
endtask

reg protocol_enable = 1;
reg [7:0] rx_byte = 0;
reg rx_valid = 0, rx_error = 0, tx_ready = 1;
reg apply_backpressure = 0, stalled = 0;
reg [7:0] stalled_byte;
wire [7:0] tx_byte;
wire tx_valid, protocol_busy;
reg [7:0] response [0:1023];
integer response_count = 0;
reg signed [15:0] a [0:63], b [0:63];

uart_protocol #(.TIMEOUT_CYCLES(2000)) protocol(
    .clk(clk), .reset_n(reset_n), .enable(protocol_enable),
    .rx_data(rx_byte), .rx_valid(rx_valid), .rx_error(rx_error),
    .tx_data(tx_byte), .tx_valid(tx_valid), .tx_ready(tx_ready), .busy(protocol_busy)
);

always @(posedge clk)
    if (reset_n && tx_valid && tx_ready) begin
        if (response_count >= 1024)
            $fatal(1, "Unexpected excess response data");
        response[response_count] = tx_byte;
        response_count = response_count + 1;
    end

always @(posedge clk) begin
    if (!reset_n || !protocol_enable)
        stalled <= 0;
    else begin
        if (stalled && (!tx_valid || tx_byte !== stalled_byte))
            $fatal(1, "Protocol changed a byte before ready accepted it");
        stalled <= tx_valid && !tx_ready;
        stalled_byte <= tx_byte;
    end
end

task send_byte;
    input [7:0] value;
    begin
        @(negedge clk);
        rx_byte = value;
        rx_valid = 1;
        @(negedge clk);
        rx_valid = 0;
    end
endtask

task clear_response;
    begin
        @(negedge clk);
        if (protocol_busy)
            $fatal(1, "Protocol still busy before next request");
        response_count = 0;
    end
endtask

task wait_response;
    input integer packet_size;
    integer cycles;
    begin
        cycles = 0;
        while ((response_count < packet_size || protocol_busy) && cycles < 10000) begin
            @(negedge clk);
            cycles = cycles + 1;
            if (apply_backpressure)
                tx_ready = (cycles % 5 == 0);
        end
        tx_ready = 1;
        if (response_count != packet_size || protocol_busy)
            $fatal(1, "Response timeout/length: expected%0d got%0d", packet_size, response_count);
    end
endtask

task check_packet;
    input [7:0] command;
    input integer length;
    integer n;
    reg [7:0] sum;
    begin
        if (response[0] !== 8'h4d || response[1] !== 8'h58 ||
            response[2] !== command || response[3] !== (length & 255) ||
            response[4] !== (length >> 8))
            $fatal(1, "Invalid response header");
        sum = 0;
        for (n = 0; n < length + 5; n = n + 1)
            sum = sum + response[n];
        if (response[length + 5] !== sum)
            $fatal(1, "Invalid response checksum");
    end
endtask

task check_error;
    input [7:0] code;
    begin
        wait_response(7);
        check_packet(8'hff, 1);
        if (response[5] !== code)
            $fatal(1, "Expected error%0d got%0d", code, response[5]);
        $display("PASS protocol error code%0d", code);
    end
endtask

task header;
    begin
        send_byte(8'h4d);
        send_byte(8'h58);
        send_byte(1);
        send_byte(0);
        send_byte(1);
    end
endtask

task request;
    input bad_checksum;
    integer matrix_index, n;
    reg [15:0] value;
    reg [7:0] sum;
    begin
        header;
        sum = 8'h4d + 8'h58 + 1 + 0 + 1;
        for (matrix_index = 0; matrix_index < 2; matrix_index = matrix_index + 1)
            for (n = 0; n < 64; n = n + 1) begin
                value = matrix_index ? b[n] : a[n];
                send_byte(value[7:0]);
                send_byte(value[15:8]);
                sum = sum + value[7:0] + value[15:8];
            end
        send_byte(bad_checksum ? sum ^ 8'h80 : sum);
    end
endtask

task check_matrix;
    integer row, col, term, byte_number;
    reg signed [63:0] expected, observed, left_value, right_value;
    begin
        wait_response(518);
        check_packet(8'h81, 512);
        for (row = 0; row < 8; row = row + 1)
            for (col = 0; col < 8; col = col + 1) begin
                expected = 0;
                for (term = 0; term < 8; term = term + 1) begin
                    left_value = a[row * 8 + term];
                    right_value = b[term * 8 + col];
                    expected = expected + left_value * right_value;
                end
                observed = 0;
                for (byte_number = 0; byte_number < 8; byte_number = byte_number + 1)
                    observed = observed | ({56'd0, response[5 + (row * 8 + col) * 8 + byte_number]}
                                           << (byte_number * 8));
                if (observed !== expected)
                    $fatal(1, "UART result[%0d,%0d]: expected%0d got%0d", row, col, expected, observed);
            end
    end
endtask

task protocol_tests;
    integer n, scenario;
    reg [7:0] held_byte;
    begin
        // Invalid magic is silently discarded, including overlapping M prefixes.
        send_byte(8'h00);
        send_byte(8'h58);
        send_byte(8'h4d);
        send_byte(8'h00);
        repeat (5) @(negedge clk);
        if (response_count != 0 || protocol_busy)
            $fatal(1, "Invalid magic generated output");
        send_byte(8'h4d);
        send_byte(8'h4d);
        send_byte(8'h58);
        send_byte(8'h7f);
        check_error(1);

        clear_response;
        send_byte(8'h4d); send_byte(8'h58); send_byte(1); send_byte(1);
        check_error(2);
        clear_response;
        send_byte(8'h4d); send_byte(8'h58); send_byte(1); send_byte(0); send_byte(0);
        check_error(2);

        for (n = 0; n < 64; n = n + 1) begin
            a[n] = (n % 2) ? -32768 : 32767;
            b[n] = n - 31;
        end
        clear_response;
        request(1);
        check_error(3);
        clear_response;
        send_byte(8'h4d);
        check_error(4);
        clear_response;
        header;
        send_byte(8'h12);
        @(negedge clk); rx_error = 1;
        @(negedge clk); rx_error = 0;
        check_error(5);

        for (scenario = 0; scenario < 3; scenario = scenario + 1) begin
            if (scenario != 0)
                for (n = 0; n < 64; n = n + 1) begin
                    a[n] = scenario == 1 ? -32768 : 32767;
                    b[n] = -32768;
                end
            clear_response;
            tx_ready = 0;
            request(0);
            if (!protocol_busy)
                $fatal(1, "Valid request did not start computation");
            // Bytes while computing are discarded rather than becoming another packet.
            send_byte(8'h4d); send_byte(8'h58); send_byte(8'h7f);
            wait(tx_valid);
            @(negedge clk);
            held_byte = tx_byte;
            repeat (11) begin
                @(negedge clk);
                if (!tx_valid || tx_byte !== held_byte)
                    $fatal(1, "TX handshake changed a stalled byte");
            end
            // Bytes while a response is stalled are also discarded.
            send_byte(8'h4d); send_byte(8'h58); send_byte(8'h7f);
            @(negedge clk); tx_ready = 1;
            apply_backpressure = (scenario == 1);
            check_matrix;
            apply_backpressure = 0;
            $display("PASS protocol matrix scenario%0d: complete518byte response", scenario);
        end
        clear_response;
        header;
        send_byte(8'h34);
        @(negedge clk); protocol_enable = 0;
        repeat (5) @(negedge clk);
        protocol_enable = 1;
        repeat (2005) @(negedge clk);
        if (response_count != 0 || protocol_busy)
            $fatal(1, "Disabled partial request survived re-enable");
        request(0);
        check_matrix;
        $display("PASS protocol reset/re-enable recovery and repeated requests");
    end
endtask

initial begin
    repeat (4) @(negedge clk);
    reset_n = 1;
    fork
        physical_fast;
        physical_real;
        protocol_tests;
    join
    $display("PASS tb_uart");
    $finish;
end

initial begin
    #30000000;
    $fatal(1, "UART testbench timeout");
end
endmodule
MATRIX_UART_FILE_023_END

cat > tests/test_host.py <<'MATRIX_UART_FILE_024_END'
"""Kiểm thử host: python3 -m unittest discover -s tests -v."""

import os
import select
import struct
import sys
import time
import tty
import unittest
from pathlib import Path

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "host"))

from PyQt5.QtCore import QTimer
from PyQt5.QtWidgets import QApplication
from main import MainWindow
from matrix_utils import decode_response, encode_request, multiply, validate_matrix
from serial_client import SerialClient, StreamDecoder


def response(matrix):
    packet = b"MX\x81\x00\x02" + struct.pack("<64q", *(v for row in matrix for v in row))
    return packet + bytes([sum(packet) & 255])


class HostTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def spin_until(self, condition, timeout=2):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.app.processEvents()
            if condition():
                return
            time.sleep(0.005)
        self.fail("Hết thời gian chờ sự kiện Qt")

    def test_validation_reference_and_request(self):
        a = [[int(i == j) for j in range(8)] for i in range(8)]
        b = [[i * 8 + j - 32 for j in range(8)] for i in range(8)]
        self.assertEqual(multiply(a, b), b)
        self.assertEqual(multiply([[0] * 8 for _ in range(8)], b), [[0] * 8 for _ in range(8)])
        self.assertEqual(multiply([[1] * 8 for _ in range(8)], [[1] * 8 for _ in range(8)]),
                         [[8] * 8 for _ in range(8)])
        self.assertEqual(multiply([[32767] * 8 for _ in range(8)],
                                  [[32767] * 8 for _ in range(8)]), [[8589410312] * 8 for _ in range(8)])
        self.assertEqual(multiply([[-32768] * 8 for _ in range(8)],
                                  [[-32768] * 8 for _ in range(8)]), [[8589934592] * 8 for _ in range(8)])
        mixed = [[(-1) ** (i + j) * (i * 8 + j) for j in range(8)] for i in range(8)]
        self.assertEqual(multiply(mixed, a), mixed)
        for malformed in ([], [[0] * 8 for _ in range(7)], [[0] * 7 for _ in range(8)]):
            with self.assertRaises(ValueError):
                validate_matrix(malformed)
        packet = encode_request(a, b)
        self.assertEqual(len(packet), 262)
        self.assertEqual(packet[:5], b"MX\x01\x00\x01")
        self.assertEqual(sum(packet[:-1]) & 255, packet[-1])
        self.assertEqual(struct.unpack_from("<h", packet, 133)[0], -32)
        for invalid in ("", "x", "1.0", "1_000", "32768", "-32769"):
            a[2][3] = invalid
            with self.assertRaises(ValueError):
                validate_matrix(a, "A")

    def test_complete_response_validation(self):
        c = [[-(i * 8 + j) for j in range(8)] for i in range(8)]
        packet = response(c)
        self.assertEqual(decode_response(packet), c)
        for bad in (packet[:-1], packet + b"x", b"NO" + packet[2:],
                    packet[:2] + b"\x82" + packet[3:],
                    packet[:-1] + bytes([packet[-1] ^ 1])):
            with self.assertRaises(ValueError):
                decode_response(bad)
        for code in range(1, 6):
            error = b"MX\xff\x01\x00" + bytes([code])
            error += bytes([sum(error) & 255])
            with self.assertRaisesRegex(ValueError, f"0x{code:02X}"):
                decode_response(error)

    def test_stream_binary_payload_not_hello(self):
        decoder = StreamDecoder()
        c = [[0] * 8 for _ in range(8)]
        c[0][0] = int.from_bytes(b"hello\r\n\x00", "little")
        stream = b"hello\r\nnoise" + response(c) + b"hello\r\n" + response(c)
        events = []
        for byte in stream:
            events.extend(decoder.feed(bytes([byte])))
        self.assertEqual([v for k, v in events if k == "text"], ["hello", "hello"])
        packets = [v for k, v in events if k == "packet"]
        self.assertEqual(len(packets), 2)
        self.assertEqual(decode_response(packets[0]), c)
        decoder.feed(b"x" * 1000)
        self.assertLessEqual(len(decoder.buffer), 200)

    def test_serial_worker_pty_and_timeout(self):
        master, slave = os.openpty()
        tty.setraw(slave)
        worker = SerialClient(response_timeout=0.2)
        connections, results, errors, logs = [], [], [], []
        heartbeats = []
        timer = QTimer()
        timer.setInterval(5)
        timer.timeout.connect(lambda: heartbeats.append(1))
        worker.connection_changed.connect(lambda up, name: connections.append(up))
        worker.result_received.connect(lambda matrix, ms: results.append((matrix, ms)))
        worker.error.connect(errors.append)
        worker.log.connect(logs.append)

        def read_request(a, b):
            received = bytearray()
            deadline = time.monotonic() + 1
            while len(received) < 262 and time.monotonic() < deadline:
                self.app.processEvents()
                if select.select([master], [], [], 0.02)[0]:
                    received.extend(os.read(master, 262 - len(received)))
            self.assertEqual(bytes(received), encode_request(a, b))

        worker.start()
        try:
            worker.connect_port(os.ttyname(slave))
            self.spin_until(lambda: connections and connections[-1])
            os.write(master, b"MX\x81\x00\x02\x01\x02")
            self.spin_until(lambda: any("250 ms" in line for line in logs))
            os.write(master, b"hello\r\n")
            self.spin_until(lambda: "RX text: hello" in logs)
            a = [[1] * 8 for _ in range(8)]
            b = [[-2] * 8 for _ in range(8)]
            worker.calculate(a, b)
            read_request(a, b)
            timer.start()
            self.spin_until(lambda: len(heartbeats) >= 3)
            timer.stop()
            self.assertEqual(results, [])
            os.write(master, b"hello\r\n")
            packet = response(multiply(a, b))
            os.write(master, packet[:17])
            self.app.processEvents()
            self.assertEqual(results, [])
            os.write(master, packet[17:])
            self.spin_until(lambda: len(results) == 1)
            self.assertEqual(results[0][0], [[-16] * 8 for _ in range(8)])
            self.assertGreater(results[0][1], 0)
            self.assertIn("RX text: hello", logs)
            worker.calculate(a, b)
            read_request(a, b)
            corrupt = packet[:-1] + bytes([packet[-1] ^ 1])
            os.write(master, corrupt + packet)
            self.spin_until(lambda: errors and not connections[-1])
            self.assertIn("checksum", errors[-1])
            self.assertEqual(len(results), 1)
            os.write(master, packet)
            worker.connect_port(os.ttyname(slave))
            self.spin_until(lambda: connections[-1])
            worker.calculate(a, b)
            read_request(a, b)
            os.write(master, packet)
            self.spin_until(lambda: len(results) == 2)
            worker.calculate(a, b)
            read_request(a, b)
            self.spin_until(lambda: len(errors) == 2 and not connections[-1])
            self.assertIn("Hết thời gian", errors[-1])
        finally:
            timer.stop()
            worker.stop()
            self.assertTrue(worker.wait(1500))
            os.close(master)
            os.close(slave)

    def test_gui_serial_roundtrip(self):
        master, slave = os.openpty()
        tty.setraw(slave)
        window = MainWindow()
        window.show()

        def read_request(a, b):
            received = bytearray()
            deadline = time.monotonic() + 1
            while len(received) < 262 and time.monotonic() < deadline:
                self.app.processEvents()
                if select.select([master], [], [], 0.02)[0]:
                    received.extend(os.read(master, 262 - len(received)))
            self.assertEqual(bytes(received), encode_request(a, b))

        try:
            device = os.ttyname(slave)
            window.ports.addItem("PTY kiểm thử", device)
            window.ports.setCurrentIndex(window.ports.count() - 1)
            window.connect_serial()
            self.spin_until(lambda: window.connected)
            self.assertIn(device, window.connection_status.text())
            window.raw_hex.setChecked(True)
            window.load_example()
            window.calculate_python()
            a, b = window.read_inputs()
            window.calculate_fpga()
            self.assertFalse(window.matrix_a.isEnabled())
            self.assertFalse(window.matrix_b.isEnabled())
            read_request(a, b)
            os.write(master, b"hello\r\n" + response(multiply(a, b)))
            self.spin_until(lambda: window.fpga_result is not None and window.matrix_a.isEnabled())
            self.assertEqual(window.fpga_result, b)
            self.assertEqual(window.fpga_table.item(7, 7).text(), str(b[7][7]))
            window.compare_results()
            self.assertTrue(window.comparison.text().startswith("PASS"))
            self.assertIn("UART round-trip", window.fpga_time.text())
            log = window.log_panel.toPlainText()
            self.assertIn("TX hex:", log)
            self.assertIn("RX hex:", log)
            self.assertIn("RX text: hello", log)
            window.worker.disconnect_port()
            self.spin_until(lambda: not window.connected)
            self.assertIn("Chưa kết nối", window.connection_status.text())
            window.connect_serial()
            self.spin_until(lambda: window.connected)
            window.calculate_fpga()
            read_request(a, b)
            window.close()
            self.spin_until(lambda: not window.worker.isRunning() and not window.isVisible())
            self.assertFalse(window.connected)
        finally:
            window.close()
            self.spin_until(lambda: not window.worker.isRunning())
            os.close(master)
            os.close(slave)

    def test_gui_offscreen_actions_and_close(self):
        window = MainWindow()
        window.show()
        try:
            window.load_example()
            window.calculate_python()
            a, b = window.read_inputs()
            self.assertEqual(window.python_result, b)
            window.sent_inputs = [a, b]
            window.receive_result(multiply(a, b), 68.5)
            window.compare_results()
            self.assertTrue(window.comparison.text().startswith("PASS"))
            self.assertIn("UART round-trip", window.fpga_time.text())
            window.fpga_result[0][0] += 1
            window.compare_results()
            self.assertTrue(window.comparison.text().startswith("FAIL"))
            window.matrix_a.item(0, 0).setText("")
            self.assertIsNone(window.fpga_result)
            window.calculate_python()
            self.assertIn("không để trống", window.error_label.text())
            self.assertNotIn("Đang chờ", window.comparison.text())
            window.random_min.setValue(2)
            window.random_max.setValue(1)
            window.random_matrices()
            self.assertIn("Cận dưới", window.error_label.text())
            window.random_min.setValue(-10)
            window.random_max.setValue(10)
            window.random_matrices()
            self.assertTrue(all(-10 <= x <= 10 for m in window.read_inputs() for row in m for x in row))
            window.clear_matrices()
            self.assertEqual(window.read_inputs(), [[[0] * 8 for _ in range(8)]] * 2)
        finally:
            window.close()
            self.spin_until(lambda: not window.worker.isRunning() and not window.isVisible())


if __name__ == "__main__":
    unittest.main()
MATRIX_UART_FILE_024_END

chmod +x scripts/run_sim.sh
printf 'Created all 24 project files in %s\n' "$PWD"
