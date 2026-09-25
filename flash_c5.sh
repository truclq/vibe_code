#!/usr/bin/env bash
#
# flash_c5.sh — Erase + Flash + Verify firmware cho ESP32-C5
# (module "5G" của ESP32 Marauder Double Barrel 5G)
#
# Dùng trên macOS. Yêu cầu: python3 + esptool (script sẽ tự cài esptool nếu thiếu).
#
# CÁCH DÙNG:
#   ./flash_c5.sh [-d THU_MUC_BIN] [-p /dev/cu.usbserial-XXXX] [-b BAUD] [-y]
#
#   -d  Thư mục chứa các file .bin (mặc định: ./bins)
#   -p  Chỉ định cổng serial (mặc định: tự dò cổng USB mới cắm)
#   -b  Baud rate (mặc định: 921600; lỗi thì thử 115200)
#   -y  Bỏ qua hỏi xác nhận (chạy thẳng)
#
# CÁC FILE .BIN CẦN CÓ trong thư mục bins:
#   bootloader.bin        -> nạp tại 0x2000  (đặc thù ESP32-C5, KHÔNG phải 0x1000)
#   partitions.bin        -> nạp tại 0x8000  (hoặc partition-table.bin)
#   ota_data_initial.bin  -> nạp tại 0xd000  (TÙY CHỌN, chỉ nạp nếu có file)
#   <app>.bin             -> nạp tại 0x10000 (file .bin LỚN NHẤT còn lại)
#
# QUY TRÌNH VÀO DOWNLOAD MODE (làm TRƯỚC khi chạy script, hoặc khi script báo chờ):
#   1) Rút hết USB.
#   2) Dùng que stylus GIỮ nút BOOT (lỗ "1" mặt sau).
#   3) Vẫn giữ BOOT, cắm USB-C vào Port B (cạnh TRÁI). Giữ thêm 1-2 giây.
#
set -euo pipefail

# ---- Offsets đặc thù ESP32-C5 (lấy từ c5_flasher.py chính thức của Marauder) ----
OFF_BOOTLOADER="0x2000"
OFF_PARTITIONS="0x8000"
OFF_OTADATA="0xd000"
OFF_APP="0x10000"
CHIP="esp32c5"

BINS_DIR="./bins"
PORT=""
BAUD="921600"
ASSUME_YES="0"

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; CYN=$'\033[36m'; RST=$'\033[0m'
info(){ printf "%s[*]%s %s\n" "$CYN" "$RST" "$1"; }
ok(){   printf "%s[+]%s %s\n" "$GRN" "$RST" "$1"; }
warn(){ printf "%s[!]%s %s\n" "$YLW" "$RST" "$1"; }
err(){  printf "%s[x]%s %s\n" "$RED" "$RST" "$1" >&2; }
die(){  err "$1"; exit 1; }

while getopts "d:p:b:yh" opt; do
  case "$opt" in
    d) BINS_DIR="$OPTARG" ;;
    p) PORT="$OPTARG" ;;
    b) BAUD="$OPTARG" ;;
    y) ASSUME_YES="1" ;;
    h) sed -n '2,40p' "$0"; exit 0 ;;
    *) die "Tham số không hợp lệ. Dùng -h để xem trợ giúp." ;;
  esac
done

# ---- Chọn lệnh esptool ----
if command -v esptool.py >/dev/null 2>&1; then
  ESPTOOL=(esptool.py)
elif python3 -c "import esptool" >/dev/null 2>&1; then
  ESPTOOL=(python3 -m esptool)
else
  warn "Chưa có esptool, đang cài qua pip3..."
  pip3 install --upgrade esptool pyserial >/dev/null
  ESPTOOL=(python3 -m esptool)
fi
ok "esptool: ${ESPTOOL[*]}"

# ---- Kiểm tra thư mục bins ----
[ -d "$BINS_DIR" ] || die "Không thấy thư mục bins: $BINS_DIR (dùng -d để chỉ định)"

find_first(){ # find_first name1 name2 ...
  for n in "$@"; do
    local f="$BINS_DIR/$n"
    [ -f "$f" ] && { echo "$f"; return 0; }
  done
  return 1
}

BOOTLOADER="$(find_first bootloader.bin || true)"
PARTITIONS="$(find_first partition-table.bin partitions.bin || true)"
OTADATA="$(find_first ota_data_initial.bin || true)"

[ -n "$BOOTLOADER" ] || die "Thiếu bootloader.bin trong $BINS_DIR"
[ -n "$PARTITIONS" ] || die "Thiếu partitions.bin / partition-table.bin trong $BINS_DIR"

# App = file .bin lớn nhất, loại trừ bootloader/partitions/otadata
APP=""; APP_SIZE=0
while IFS= read -r f; do
  case "$f" in "$BOOTLOADER"|"$PARTITIONS"|"$OTADATA") continue ;; esac
  sz=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f")
  if [ "$sz" -gt "$APP_SIZE" ]; then APP_SIZE="$sz"; APP="$f"; fi
done < <(find "$BINS_DIR" -maxdepth 1 -type f -name '*.bin')
[ -n "$APP" ] || die "Không tìm thấy file firmware ứng dụng (.bin) trong $BINS_DIR"

# ---- Dò cổng nếu chưa chỉ định ----
list_ports(){ ls /dev/cu.usbserial-* /dev/cu.usbmodem* /dev/cu.SLAB_USBtoUART* 2>/dev/null || true; }
if [ -z "$PORT" ]; then
  info "Đang dò cổng... Hãy đưa C5 vào download mode (giữ BOOT lỗ '1' + cắm USB-C Port B)."
  BEFORE="$(list_ports)"
  info "Đang chờ cổng USB mới xuất hiện (Ctrl-C để hủy)..."
  for _ in $(seq 1 60); do
    AFTER="$(list_ports)"
    NEW="$(comm -13 <(printf '%s\n' "$BEFORE" | sort) <(printf '%s\n' "$AFTER" | sort) | grep -v '^$' || true)"
    if [ -n "$NEW" ]; then PORT="$(printf '%s\n' "$NEW" | head -1)"; break; fi
    sleep 1
  done
  if [ -z "$PORT" ]; then
    CUR="$(list_ports)"
    [ -n "$CUR" ] && { PORT="$(printf '%s\n' "$CUR" | head -1)"; warn "Không thấy cổng MỚI, dùng cổng đang có: $PORT"; }
  fi
fi
[ -n "$PORT" ] || die "Không dò được cổng. Chỉ định bằng -p /dev/cu.usbserial-XXXX (cài driver FTDI VCP nếu Mac không thấy cổng)."
ok "Cổng: $PORT"

# ---- Tóm tắt ----
echo
info "Kế hoạch flash:"
printf "   chip        : %s\n" "$CHIP"
printf "   port / baud : %s @ %s\n" "$PORT" "$BAUD"
printf "   %-9s %s  %s\n" "$OFF_BOOTLOADER" "bootloader" "$BOOTLOADER"
printf "   %-9s %s  %s\n" "$OFF_PARTITIONS" "partitions" "$PARTITIONS"
[ -n "$OTADATA" ] && printf "   %-9s %s  %s\n" "$OFF_OTADATA" "ota_data  " "$OTADATA"
printf "   %-9s %s  %s (%s bytes)\n" "$OFF_APP" "app       " "$APP" "$APP_SIZE"
echo

if [ "$ASSUME_YES" != "1" ]; then
  read -r -p "${YLW}Xác nhận ERASE + FLASH + VERIFY? (y/N): ${RST}" ans
  [ "${ans:-}" = "y" ] || [ "${ans:-}" = "Y" ] || { echo "Đã hủy."; exit 0; }
fi

# ---- Xác nhận đúng chip ESP32-C5 trước khi xóa ----
info "Kiểm tra chip..."
if ! "${ESPTOOL[@]}" --chip "$CHIP" --port "$PORT" chip_id 2>&1 | tee /tmp/c5_chipid.log | grep -qi "ESP32-C5"; then
  warn "Không xác nhận được 'ESP32-C5' (xem /tmp/c5_chipid.log)."
  warn "Có thể bạn đang cắm nhầm Port A (con ESP32 màn hình) hoặc chưa vào download mode."
  if [ "$ASSUME_YES" != "1" ]; then
    read -r -p "${YLW}Vẫn tiếp tục? (y/N): ${RST}" ans2
    [ "${ans2:-}" = "y" ] || [ "${ans2:-}" = "Y" ] || die "Dừng để an toàn."
  fi
fi

# ---- Erase ----
info "ERASE flash..."
"${ESPTOOL[@]}" --chip "$CHIP" --port "$PORT" --baud "$BAUD" erase_flash
ok "Đã erase."

# ---- Flash ----
FLASH_ARGS=(--chip "$CHIP" --port "$PORT" --baud "$BAUD" --before default_reset --after hard_reset
            write_flash -z
            "$OFF_BOOTLOADER" "$BOOTLOADER"
            "$OFF_PARTITIONS" "$PARTITIONS")
[ -n "$OTADATA" ] && FLASH_ARGS+=("$OFF_OTADATA" "$OTADATA")
FLASH_ARGS+=("$OFF_APP" "$APP")

info "FLASH firmware..."
"${ESPTOOL[@]}" "${FLASH_ARGS[@]}"
ok "Đã flash."

# ---- Verify ----
info "VERIFY (bootloader + partitions + app)..."
VERIFY_OK=1
"${ESPTOOL[@]}" --chip "$CHIP" --port "$PORT" --baud "$BAUD" verify_flash "$OFF_BOOTLOADER" "$BOOTLOADER" || VERIFY_OK=0
"${ESPTOOL[@]}" --chip "$CHIP" --port "$PORT" --baud "$BAUD" verify_flash "$OFF_PARTITIONS" "$PARTITIONS" || VERIFY_OK=0
"${ESPTOOL[@]}" --chip "$CHIP" --port "$PORT" --baud "$BAUD" verify_flash "$OFF_APP" "$APP" || VERIFY_OK=0

echo
if [ "$VERIFY_OK" = "1" ]; then
  ok "HOÀN TẤT — flash + verify đều OK."
  echo
  info "Bước tiếp theo (V&V chức năng):"
  echo "  1) Rút ra cắm lại (KHÔNG giữ BOOT). Xem log boot:"
  echo "       python3 -m serial.tools.miniterm $PORT 115200"
  echo "  2) Trên Flipper (Momentum): Momentum -> Protocols -> GPIO Pins -> ESP32/8266 UART -> Extra 15,16"
  echo "  3) Mở app Marauder trên Flipper -> WiFi scan -> phải thấy được AP băng 5GHz."
else
  err "VERIFY THẤT BẠI. Đừng dùng thiết bị vội — thử lại:"
  echo "   - Hạ baud:  ./flash_c5.sh -b 115200"
  echo "   - Kiểm tra cáp USB (phải hỗ trợ data) và vào lại download mode."
  exit 1
fi
