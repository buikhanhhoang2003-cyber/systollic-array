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
