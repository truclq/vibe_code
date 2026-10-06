#!/usr/bin/env bash
#
# check_c5.sh — Kiểm tra (CHỈ ĐỌC) firmware trên ESP32-C5
# (module "5G" của ESP32 Marauder Double Barrel 5G)
#
# Script này KHÔNG erase, KHÔNG flash — chỉ đọc thông tin để biết:
#   - Có đúng là chip ESP32-C5 không, MAC, dung lượng flash
#   - Phiên bản Marauder đang chạy (trích từ chuỗi trong firmware)
#   - (tùy chọn) xem log boot trực tiếp
#
# CÁCH DÙNG (trên macOS):
#   ./check_c5.sh [-p /dev/cu.usbserial-XXXX] [-b BAUD] [-m]
#     -p  Chỉ định cổng (mặc định: tự dò cổng USB mới cắm)
#     -b  Baud (mặc định 921600)
#     -m  Sau khi đọc xong, mở serial monitor 115200 để xem log boot
#
# VÀO DOWNLOAD MODE trước khi chạy (để đọc được flash):
#   Giữ nút BOOT (lỗ "1" mặt sau) + cắm USB-C vào Port B (cạnh trái), giữ thêm 1-2s.
#
set -euo pipefail

PORT=""; BAUD="921600"; DO_MONITOR="0"; CHIP="esp32c5"
APP_OFFSET="0x10000"; APP_READ_LEN="0x180000"   # đọc 1.5MB vùng app để dò version

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; CYN=$'\033[36m'; RST=$'\033[0m'
info(){ printf "%s[*]%s %s\n" "$CYN" "$RST" "$1"; }
ok(){   printf "%s[+]%s %s\n" "$GRN" "$RST" "$1"; }
warn(){ printf "%s[!]%s %s\n" "$YLW" "$RST" "$1"; }
die(){  printf "%s[x]%s %s\n" "$RED" "$RST" "$1" >&2; exit 1; }

while getopts "p:b:mh" opt; do
  case "$opt" in
    p) PORT="$OPTARG" ;;
    b) BAUD="$OPTARG" ;;
    m) DO_MONITOR="1" ;;
    h) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "Tham số sai. -h để xem trợ giúp." ;;
  esac
done

if command -v esptool.py >/dev/null 2>&1; then ESPTOOL=(esptool.py)
elif python3 -c "import esptool" >/dev/null 2>&1; then ESPTOOL=(python3 -m esptool)
else warn "Cài esptool..."; pip3 install --upgrade esptool pyserial >/dev/null; ESPTOOL=(python3 -m esptool); fi

list_ports(){ ls /dev/cu.usbserial-* /dev/cu.usbmodem* /dev/cu.SLAB_USBtoUART* 2>/dev/null || true; }
if [ -z "$PORT" ]; then
  info "Dò cổng... đưa C5 vào download mode (giữ BOOT lỗ '1' + cắm USB-C Port B)."
  CUR="$(list_ports)"
  [ -n "$CUR" ] && PORT="$(printf '%s\n' "$CUR" | head -1)"
fi
[ -n "$PORT" ] || die "Không thấy cổng. Chỉ định -p, hoặc cài driver FTDI VCP."
ok "Cổng: $PORT"

echo; info "===== Thông tin chip ====="
"${ESPTOOL[@]}" --chip "$CHIP" --port "$PORT" --baud "$BAUD" flash_id || \
  warn "Không đọc được — có thể chưa vào download mode hoặc cắm nhầm Port A."
echo; "${ESPTOOL[@]}" --chip "$CHIP" --port "$PORT" read_mac || true

echo; info "===== Dò phiên bản firmware (đọc vùng app, chỉ đọc) ====="
DUMP="$(mktemp -t c5_app.XXXXXX).bin"
if "${ESPTOOL[@]}" --chip "$CHIP" --port "$PORT" --baud "$BAUD" \
      read_flash "$APP_OFFSET" "$APP_READ_LEN" "$DUMP" >/dev/null 2>&1; then
  ok "Đã đọc vùng app -> $DUMP"
  echo "Các chuỗi phiên bản tìm thấy:"
  strings "$DUMP" 2>/dev/null | grep -iE "marauder|^v?[0-9]+\.[0-9]+\.[0-9]+" \
    | grep -ivE "https?://" | sort -u | head -20 || true
  echo
  echo "Nếu trống, thử xem toàn bộ chuỗi có 'v1.' :"
  strings "$DUMP" 2>/dev/null | grep -iE "v1\.[0-9]" | sort -u | head -20 || true
else
  warn "Không đọc được vùng app (cần ở download mode)."
fi

if [ "$DO_MONITOR" = "1" ]; then
  echo; info "===== Serial monitor 115200 (Ctrl-] để thoát) ====="
  warn "Rút ra cắm lại BÌNH THƯỜNG (không giữ BOOT) rồi nhấn Enter..."
  read -r _
  python3 -m serial.tools.miniterm "$PORT" 115200
fi

echo; ok "Xong. Dán toàn bộ output ở trên cho Claude để phân tích firmware."
