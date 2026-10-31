#!/usr/bin/env bash
#
# portmap_c5.sh — Theo dõi cổng serial xuất hiện/biến mất theo thời gian thực.
# CHỈ ĐỌC. Dùng để xác định cổng USB-C nào trên board nối tới chip nào.
#
# CÁCH DÙNG:
#   ./portmap_c5.sh
#
# KỊCH BẢN THỬ (làm chậm, chờ dòng in ra sau mỗi bước):
#   1) RÚT HẾT USB khỏi thiết bị Marauder  -> xem còn cổng nào "sót lại"
#      (cổng nào còn sót = KHÔNG phải của Marauder)
#   2) Cắm Port A (cạnh TRÊN)              -> ghi lại cổng mới
#   3) Rút ra
#   4) Cắm Port B (cạnh TRÁI)              -> ghi lại cổng mới
#   5) Rút ra
#   6) Cắm cổng USB-C ở ĐÁY board          -> ghi lại cổng mới
#   7) Thử lại Port B nhưng BẬT công tắc nguồn thiết bị
#
# Ctrl-C để thoát. Dán toàn bộ output cho Claude.
#
set -uo pipefail

GRN=$'\033[32m'; RED=$'\033[31m'; CYN=$'\033[36m'; YLW=$'\033[33m'; RST=$'\033[0m'

snapshot(){
  python3 - <<'PY' 2>/dev/null
try:
    import serial.tools.list_ports as lp
except ImportError:
    raise SystemExit
for p in sorted(lp.comports(), key=lambda x: x.device):
    if "/cu." not in p.device:
        continue
    vid = f"{p.vid:04x}" if p.vid is not None else "----"
    pid = f"{p.pid:04x}" if p.pid is not None else "----"
    # bỏ qua các cổng Bluetooth/hệ thống cho đỡ nhiễu
    if p.vid is None and any(k in p.device for k in
        ("Bluetooth", "debug-console", "EV3", "JBL", "AirPods", "Headset")):
        continue
    print(f"{p.device}|{vid}:{pid}|{p.description}")
PY
}

label(){
  case "$1" in
    303a:*) printf " %s<- Espressif USB-Serial-JTAG (chip ESP32 đời mới: C5/C3/C6/S3)%s" "$GRN" "$RST" ;;
    0403:*) printf " %s<- FTDI bridge (đúng như manual mô tả cho C5)%s" "$GRN" "$RST" ;;
    10c4:*) printf " %s<- Silicon Labs CP210x bridge%s" "$GRN" "$RST" ;;
    1a86:*) printf " %s<- CH340/CH9102 bridge%s" "$GRN" "$RST" ;;
    *)      printf "" ;;
  esac
}

echo "${CYN}=== Theo dõi cổng serial (Ctrl-C để thoát) ===${RST}"
echo "${YLW}BƯỚC 1: RÚT HẾT USB khỏi thiết bị Marauder ngay bây giờ.${RST}"
echo "Các cổng còn thấy dưới đây là CỦA THỨ KHÁC, không phải Marauder:"
echo
PREV="$(snapshot)"
if [ -z "$PREV" ]; then
  echo "  (không có cổng USB-serial nào — tốt, nền sạch)"
else
  printf '%s\n' "$PREV" | while IFS='|' read -r dev vp desc; do
    printf "  %-26s %s  %s%s\n" "$dev" "$vp" "$desc" "$(label "$vp")"
  done
fi
echo
echo "${YLW}Giờ bắt đầu cắm/rút từng cổng USB-C. Mỗi thay đổi sẽ in ra bên dưới.${RST}"
echo

while true; do
  sleep 1
  CUR="$(snapshot)"
  if [ "$CUR" != "$PREV" ]; then
    TS="$(date +%H:%M:%S)"
    # cổng mới
    comm -13 <(printf '%s\n' "$PREV" | sort) <(printf '%s\n' "$CUR" | sort) \
      | grep -v '^$' | while IFS='|' read -r dev vp desc; do
          printf "[%s] %s+ XUẤT HIỆN%s  %-26s %s  %s%s\n" \
            "$TS" "$GRN" "$RST" "$dev" "$vp" "$desc" "$(label "$vp")"
        done
    # cổng mất
    comm -23 <(printf '%s\n' "$PREV" | sort) <(printf '%s\n' "$CUR" | sort) \
      | grep -v '^$' | while IFS='|' read -r dev vp desc; do
          printf "[%s] %s- MẤT     %s  %-26s %s  %s\n" \
            "$TS" "$RED" "$RST" "$dev" "$vp" "$desc"
        done
    PREV="$CUR"
  fi
done
