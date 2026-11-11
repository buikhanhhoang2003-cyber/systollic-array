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
