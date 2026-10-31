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
#   ./check_c5.sh [-p /dev/cu.usbserial-XXXX] [-b BAUD] [-m] [-l]
#     -p  Chỉ định cổng (mặc định: tự chọn cổng FTDI, hỏi nếu có nhiều)
#     -b  Baud (mặc định 115200 — chậm nhưng chắc)
#     -m  Sau khi đọc xong, mở serial monitor 115200 để xem log boot
#     -l  Chỉ liệt kê cổng rồi thoát (không kết nối)
#
# VÀO DOWNLOAD MODE trước khi chạy (BẮT BUỘC để đọc được flash):
#   1) Rút hết USB
#   2) Giữ nút BOOT (lỗ "1" mặt sau, dùng que stylus)
#   3) Vẫn giữ BOOT -> cắm USB-C vào Port B (cạnh TRÁI), giữ thêm 2 giây
#
# GHI CHÚ KỸ THUẬT: board này vào download mode THỦ CÔNG, nên script dùng
# "--before no_reset" — nếu để esptool tự reset (default_reset) thì cú nhấp
# DTR/RTS sẽ đá chip RA KHỎI download mode và gây lỗi "No serial data received".
#
set -euo pipefail

PORT=""; BAUD="115200"; DO_MONITOR="0"; LIST_ONLY="0"; CHIP="esp32c5"
APP_OFFSET="0x10000"; APP_READ_LEN="0x180000"   # đọc 1.5MB vùng app để dò version

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; CYN=$'\033[36m'; RST=$'\033[0m'
info(){ printf "%s[*]%s %s\n" "$CYN" "$RST" "$1"; }
ok(){   printf "%s[+]%s %s\n" "$GRN" "$RST" "$1"; }
warn(){ printf "%s[!]%s %s\n" "$YLW" "$RST" "$1"; }
die(){  printf "%s[x]%s %s\n" "$RED" "$RST" "$1" >&2; exit 1; }

while getopts "p:b:mlh" opt; do
  case "$opt" in
    p) PORT="$OPTARG" ;;
    b) BAUD="$OPTARG" ;;
    m) DO_MONITOR="1" ;;
    l) LIST_ONLY="1" ;;
    h) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "Tham số sai. -h để xem trợ giúp." ;;
  esac
done

if command -v esptool.py >/dev/null 2>&1; then ESPTOOL=(esptool.py)
elif python3 -c "import esptool" >/dev/null 2>&1; then ESPTOOL=(python3 -m esptool)
else warn "Cài esptool..."; pip3 install --upgrade esptool pyserial >/dev/null; ESPTOOL=(python3 -m esptool); fi

# ---------- Liệt kê cổng kèm mô tả (để không bắt nhầm Port A / Bluetooth) ----------
info "===== Các cổng serial đang có ====="
if ! python3 - <<'PY'
import sys
try:
    import serial.tools.list_ports as lp
except ImportError:
    sys.exit(2)
ports = [p for p in lp.comports() if "/cu." in p.device]
if not ports:
    print("  (không thấy cổng /dev/cu.* nào)")
for p in ports:
    vid = f"{p.vid:04x}" if p.vid is not None else "----"
    pid = f"{p.pid:04x}" if p.pid is not None else "----"
    if p.vid == 0x303A:
        tag = "  <-- Espressif USB-JTAG (chính là C5)"
    elif p.vid == 0x0403:
        tag = "  <-- FTDI"
    else:
        tag = ""
    print(f"  {p.device:<28} VID:PID={vid}:{pid}  {p.description}{tag}")
PY
then
  warn "(không dùng được pyserial — liệt kê thô bằng ls)"
  ls -1 /dev/cu.* 2>/dev/null | sed 's/^/  /' || echo "  (không thấy cổng /dev/cu.* nào)"
fi
echo

# Ưu tiên cổng FTDI (VID 0403) — đó là mạch nạp của C5 trên board này
pick_port(){
  python3 - <<'PY'
try:
    import serial.tools.list_ports as lp
except ImportError:
    raise SystemExit(1)
cands = [p for p in lp.comports() if "/cu." in p.device]
esp  = [p.device for p in cands if p.vid == 0x303A]   # Espressif USB-Serial-JTAG (C5)
ftdi = [p.device for p in cands if p.vid == 0x0403]   # FTDI bridge
usb  = [p.device for p in cands if "usbserial" in p.device or "usbmodem" in p.device]
for group in (esp, ftdi, usb):
    if len(group) == 1:
        print(group[0]); break
PY
}

if [ "$LIST_ONLY" = "1" ]; then exit 0; fi

if [ -z "$PORT" ]; then
  PORT="$(pick_port || true)"
  [ -n "$PORT" ] && ok "Tự chọn cổng FTDI: $PORT"
fi
[ -n "$PORT" ] || die "Không tự chọn được cổng (không có, hoặc có nhiều cổng cùng loại).
  Xem danh sách ở trên rồi chỉ định: ./check_c5.sh -p /dev/cu.usbserial-XXXX
  Nếu danh sách trống: cài driver FTDI VCP (ftdichip.com) và approve trong
  System Settings -> Privacy & Security."

# ---------- Thử kết nối: no_reset trước, rồi mới default_reset ----------
# Chọn bộ cờ reset theo từng kiểu.
# - usb_reset     : đúng cho USB-Serial-JTAG tích hợp (VID 303A) — KHÔNG cần giữ BOOT
# - default_reset : cầu USB-serial ngoài (FTDI/CP210x) có nối DTR/RTS
# - no_reset      : đã tự vào download mode bằng tay (giữ BOOT + cắm USB)
reset_args(){
  case "$1" in
    usb_reset)     printf '%s\n' --before usb_reset     --after no_reset ;;
    default_reset) printf '%s\n' --before default_reset --after no_reset ;;
    no_reset)      printf '%s\n' --before no_reset      --after no_reset ;;
  esac
}

info "===== Kết nối chip (thử lần lượt các kiểu reset) ====="
CONNECTED=0; OUT=""; CONN_MODE=""; CONN_BAUD=""
for mode in usb_reset default_reset no_reset; do
  for b in "$BAUD" 921600; do
    IFS=$'\n' read -r -d '' -a ARGS < <(reset_args "$mode"; printf '\0')
    info "thử: --before $mode @ $b ..."
    if OUT="$("${ESPTOOL[@]}" --chip "$CHIP" --port "$PORT" --baud "$b" "${ARGS[@]}" flash_id 2>&1)" \
       && printf '%s' "$OUT" | grep -qi "ESP32-C5"; then
      CONNECTED=1; CONN_MODE="$mode"; CONN_BAUD="$b"; break 2
    fi
    [ "$b" = "$BAUD" ] || break
  done
done

if [ "$CONNECTED" != "1" ]; then
  printf '%s\n' "$OUT"
  echo
  die "Không kết nối được chip. Kiểm tra theo thứ tự:
  1) Cổng có phải Espressif USB-JTAG (VID 303A) ở danh sách trên không?
     Nếu là 303A thì chip chính là C5 và KHÔNG cần giữ BOOT.
  2) Thử vào DOWNLOAD MODE bằng tay: rút USB -> giữ BOOT (lỗ '1')
     -> cắm USB-C Port B (cạnh TRÁI) -> giữ thêm 2s, rồi chạy lại.
  3) Sau mỗi lần chip reset, cổng USB-JTAG re-enumerate và ĐỔI TÊN.
     Chạy './check_c5.sh -l' để lấy tên cổng mới.
  4) Cáp USB-C phải hỗ trợ DATA (cáp chỉ sạc sẽ không chạy)."
fi

ok "Kết nối OK (--before $CONN_MODE @ $CONN_BAUD)"
printf '%s\n' "$OUT"
IFS=$'\n' read -r -d '' -a ARGS < <(reset_args "$CONN_MODE"; printf '\0')

echo; info "===== MAC ====="
"${ESPTOOL[@]}" --chip "$CHIP" --port "$PORT" --baud "$CONN_BAUD" "${ARGS[@]}" read_mac || true

echo; info "===== Dò phiên bản firmware (đọc vùng app, CHỈ ĐỌC) ====="
DUMP="$(mktemp -t c5_app.XXXXXX)"; DUMP="${DUMP}.bin"
if "${ESPTOOL[@]}" --chip "$CHIP" --port "$PORT" --baud "$CONN_BAUD" "${ARGS[@]}" \
      read_flash "$APP_OFFSET" "$APP_READ_LEN" "$DUMP" >/dev/null 2>&1; then
  ok "Đã đọc vùng app -> $DUMP"
  echo "--- Chuỗi phiên bản tìm thấy ---"
  strings "$DUMP" 2>/dev/null | grep -iE "marauder|v[0-9]+\.[0-9]+\.[0-9]+" \
    | grep -ivE "https?://" | sort -u | head -25 || echo "(không thấy)"
  echo "--- Chuỗi dạng v1.x ---"
  strings "$DUMP" 2>/dev/null | grep -oE "v?1\.[0-9]+\.[0-9]+" | sort -u | head -15 || echo "(không thấy)"
else
  warn "Không đọc được vùng app."
fi

if [ "$DO_MONITOR" = "1" ]; then
  echo; info "===== Serial monitor 115200 (Ctrl-] để thoát) ====="
  warn "Rút ra cắm lại BÌNH THƯỜNG (KHÔNG giữ BOOT) rồi nhấn Enter..."
  read -r _
  python3 -m serial.tools.miniterm "$PORT" 115200
fi

echo; ok "Xong. Dán toàn bộ output ở trên cho Claude để phân tích."
