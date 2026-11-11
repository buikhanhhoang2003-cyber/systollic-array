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
