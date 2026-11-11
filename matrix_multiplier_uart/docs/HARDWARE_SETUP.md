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
