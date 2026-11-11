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
