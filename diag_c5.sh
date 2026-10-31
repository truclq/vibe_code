#!/usr/bin/env bash
#
# diag_c5.sh — Thu thập dữ liệu chẩn đoán cho ESP32-C5 (Double Barrel 5G)
# CHỈ ĐỌC. Không erase, không flash, không ghi gì vào thiết bị.
#
# Dùng:  ./diag_c5.sh [-p /dev/cu.usbmodemXXXX]
# Rồi dán TOÀN BỘ output cho Claude.
#
set -uo pipefail   # cố ý KHÔNG dùng -e: muốn chạy hết mọi phép thử dù có lỗi

PORT="${2:-}"
[ "${1:-}" = "-p" ] && PORT="${2:-}"

hr(){ printf '\n========== %s ==========\n' "$1"; }

if command -v esptool.py >/dev/null 2>&1; then ESPTOOL=(esptool.py)
else ESPTOOL=(python3 -m esptool); fi

hr "1. PHIÊN BẢN CÔNG CỤ"
echo "--- esptool version (QUAN TRỌNG: ESP32-C5 cần esptool >= 4.8, tốt nhất 5.x) ---"
"${ESPTOOL[@]}" version 2>&1 | head -5
echo "--- python ---"
python3 --version 2>&1
echo "--- pyserial ---"
python3 -c "import serial; print('pyserial', serial.__version__)" 2>&1 | head -2

hr "2. DANH SÁCH CỔNG"
python3 -m serial.tools.list_ports -v 2>&1 | head -40
echo "--- ls /dev/cu.* ---"
ls -1 /dev/cu.* 2>/dev/null

# Tự chọn cổng nếu chưa chỉ định
if [ -z "$PORT" ]; then
  PORT="$(ls -1 /dev/cu.usbmodem* /dev/cu.usbserial* 2>/dev/null | head -1)"
fi
echo
echo ">>> Dùng cổng: ${PORT:-<KHÔNG CÓ>}"
[ -n "$PORT" ] || { echo "Không có cổng nào để thử. Dừng."; exit 0; }

hr "3. ESPTOOL TỰ NHẬN DIỆN CHIP (không ép --chip)"
for mode in usb_reset default_reset no_reset; do
  echo "--- --before $mode ---"
  timeout 25 "${ESPTOOL[@]}" --port "$PORT" --before "$mode" --after no_reset chip_id 2>&1 | tail -15
  echo
done

hr "4. ÉP --chip esp32c5 (để so sánh thông báo lỗi)"
timeout 25 "${ESPTOOL[@]}" --chip esp32c5 --port "$PORT" --before usb_reset --after no_reset chip_id 2>&1 | tail -12

hr "5. LOG BOOT (8 giây, 115200)"
echo "Đang nghe cổng... HÃY TẮT/BẬT công tắc nguồn thiết bị NGAY BÂY GIỜ."
timeout 8 python3 - "$PORT" <<'PY' 2>&1 | head -60
import sys
try:
    import serial
except ImportError:
    print("(không có pyserial, bỏ qua)"); raise SystemExit
try:
    s = serial.Serial(sys.argv[1], 115200, timeout=1)
except Exception as e:
    print("Không mở được cổng:", e); raise SystemExit
import time
end = time.time() + 7
while time.time() < end:
    data = s.read(512)
    if data:
        sys.stdout.write(data.decode('utf-8', 'replace'))
        sys.stdout.flush()
PY

hr "6. LOG BOOT @ 74880 (tốc độ log ROM của một số chip)"
timeout 6 python3 - "$PORT" <<'PY' 2>&1 | head -30
import sys, time
try:
    import serial
except ImportError:
    print("(không có pyserial)"); raise SystemExit
try:
    s = serial.Serial(sys.argv[1], 74880, timeout=1)
except Exception as e:
    print("Không mở được:", e); raise SystemExit
end = time.time() + 5
while time.time() < end:
    d = s.read(512)
    if d:
        sys.stdout.write(d.decode('utf-8','replace')); sys.stdout.flush()
PY

hr "XONG"
echo "Dán toàn bộ output ở trên cho Claude."
