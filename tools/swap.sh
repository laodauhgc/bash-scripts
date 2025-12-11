#!/usr/bin/env bash
# Auto Swap Optimizer for Ubuntu
# - Tính toán dung lượng swap khuyến nghị theo RAM
# - Ưu tiên swapfile trên phân vùng root, hỗ trợ SSD/HDD
# - Tự động tạo/mở rộng swap, cập nhật /etc/fstab an toàn
# - Tinh chỉnh swappiness & vfs_cache_pressure
# - Idempotent: chạy nhiều lần không gây lỗi
# Tested on Ubuntu 18.04+ (systemd)

set -euo pipefail

# ----------- UI helpers -----------
log()   { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
ok()    { printf "\033[1;32m[OK]\033[0m   %s\n" "$*"; }
warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err()   { printf "\033[1;31m[ERROR]\033[0m %s\n" "$*" >&2; }
die()   { err "$*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Thiếu lệnh bắt buộc: $1"
}

# ----------- Pre-checks -----------
[ "$(id -u)" -eq 0 ] || die "Vui lòng chạy với quyền root (sudo)."

for c in awk sed grep cut lsblk df free fallocate mkswap swapon swapoff sysctl; do
  require_cmd "$c"
done

if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
  warn "Hệ điều hành không phải Ubuntu (theo /etc/os-release). Vẫn tiếp tục nhưng có thể không tối ưu."
fi

# ----------- Detect system info -----------
TOTAL_RAM_KB=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
[ -n "${TOTAL_RAM_KB:-}" ] || die "Không đọc được tổng RAM từ /proc/meminfo."
TOTAL_RAM_GB=$(awk -v kb="$TOTAL_RAM_KB" 'BEGIN { printf "%.2f", kb/1024/1024 }')

ROOT_MOUNT="/"
ROOT_DEV=$(df -P "$ROOT_MOUNT" | awk 'NR==2 {print $1}')
ROOT_AVAIL_MB=$(df -Pm "$ROOT_MOUNT" | awk 'NR==2 {print $4}')
ROOT_FS=$(df -PT "$ROOT_MOUNT" | awk 'NR==2 {print $2}')

# Xác định ổ gốc là SSD hay HDD (rota=0 -> SSD)
ROOT_DISK=$(lsblk -no pkname "$ROOT_DEV" 2>/dev/null || true)
[ -z "$ROOT_DISK" ] && ROOT_DISK=$(lsblk -no name "$ROOT_DEV" 2>/dev/null || true)
IS_ROTATIONAL=1
if [ -n "$ROOT_DISK" ] && [ -e "/sys/block/$ROOT_DISK/queue/rotational" ]; then
  IS_ROTATIONAL=$(cat "/sys/block/$ROOT_DISK/queue/rotational")
fi
IS_SSD=$([ "$IS_ROTATIONAL" = "0" ] && echo 1 || echo 0)

# ----------- Existing swap -----------
EXISTING_SWAP_MB=$(swapon --show --bytes | awk 'NR>1 {sum+=$3} END {printf "%.0f", sum/1024/1024}')
EXISTING_SWAP_MB=${EXISTING_SWAP_MB:-0}

# ----------- Heuristic for recommended swap -----------
# Mục tiêu: máy chủ không hibernate, cân bằng giữa dự phòng OOM và tránh I/O quá mức.
calc_recommended_swap_mb() {
  # Input: TOTAL_RAM_GB (float)
  # Heuristic:
  #  RAM <= 1 GB    : 2.0 x RAM (min 1 GB)
  #  1-2 GB         : 1.5 x RAM
  #  2-8 GB         : 1.0 x RAM
  #  8-16 GB        : 0.5 x RAM
  #  16-64 GB       : 0.25 x RAM (min 8 GB)
  #  >64 GB         : 16 GB cố định (có thể tăng nếu thiếu bộ nhớ trống)
  local ram_gb="$1"
  local swap_gb
  awk -v r="$ram_gb" '
    function ceil(x){ return (x==int(x))?x:int(x)+1 }
    BEGIN{
      if (r <= 1.0)      s = r * 2.0;
      else if (r <= 2.0) s = r * 1.5;
      else if (r <= 8.0) s = r * 1.0;
      else if (r <= 16.) s = r * 0.5;
      else if (r <= 64.) { s = r * 0.25; if (s < 8) s = 8; }
      else               s = 16.0;
      # Chặn giá trị min 1 GB, max 64 GB (có thể chỉnh khi cần)
      if (s < 1) s = 1;
      if (s > 64) s = 64;
      # Làm tròn lên theo GB
      print int(ceil(s)*1024);
    }'
}

RECOMMENDED_SWAP_MB=$(calc_recommended_swap_mb "$TOTAL_RAM_GB")

# Nếu SSD và RAM nhỏ, có thể tăng nhẹ swap cho an toàn (I/O SSD rẻ hơn HDD)
if [ "$IS_SSD" -eq 1 ] && awk "BEGIN{exit !($TOTAL_RAM_GB < 4.0)}"; then
  RECOMMENDED_SWAP_MB=$(( RECOMMENDED_SWAP_MB + 512 ))  # +512MB
fi

# Đảm bảo không vượt quá 90% dung lượng trống root
MAX_BY_SPACE_MB=$(( ROOT_AVAIL_MB * 90 / 100 ))
if [ "$RECOMMENDED_SWAP_MB" -gt "$MAX_BY_SPACE_MB" ]; then
  warn "Dung lượng trống trên $ROOT_MOUNT hạn chế. Giảm swap từ ${RECOMMENDED_SWAP_MB}MB xuống ${MAX_BY_SPACE_MB}MB."
  RECOMMENDED_SWAP_MB="$MAX_BY_SPACE_MB"
fi

[ "$RECOMMENDED_SWAP_MB" -gt 0 ] || die "Không đủ dung lượng để tạo swap."

# ----------- Decide action -----------
log "RAM thực: ${TOTAL_RAM_GB} GB | Hệ thống tệp: $ROOT_FS | Ổ gốc: $ROOT_DEV ($( [ "$IS_SSD" -eq 1 ] && echo SSD || echo HDD ))"
log "Swap hiện có: ${EXISTING_SWAP_MB} MB | Swap khuyến nghị: ${RECOMMENDED_SWAP_MB} MB"

TARGET_SWAPFILE="/swapfile"
ALT_SWAPFILE="/swapfile-auto"

choose_swapfile_path() {
  local path="$TARGET_SWAPFILE"
  if [ -e "$path" ] && swapon --show=NAME | grep -qx "$path"; then
    # /swapfile đang được dùng -> sử dụng file khác để mở rộng
    path="$ALT_SWAPFILE"
  elif [ -e "$path" ] && [ ! -s "$path" ]; then
    rm -f "$path"
  fi
  echo "$path"
}

# ----------- Create/Extend swap -----------
create_swapfile() {
  local path="$1"
  local size_mb="$2"
  log "Tạo swapfile: $path (kích thước ${size_mb}MB)..."

  # Kiểm tra hệ thống tệp: Btrfs yêu cầu chattr + C hoặc dùng dd
  local use_dd=0
  if [ "$ROOT_FS" = "btrfs" ]; then
    warn "Root là btrfs. Sử dụng dd để tạo swapfile (tránh COW)."
    use_dd=1
  fi

  if [ "$use_dd" -eq 0 ]; then
    if ! fallocate -l "${size_mb}M" "$path" 2>/dev/null; then
      warn "fallocate thất bại, fallback sang dd (chậm hơn)."
      use_dd=1
    fi
  fi

  if [ "$use_dd" -eq 1 ]; then
    dd if=/dev/zero of="$path" bs=1M count="$size_mb" status=progress || die "Tạo swap bằng dd thất bại."
    # Nếu là btrfs, disable COW
    if [ "$ROOT_FS" = "btrfs" ]; then
      chattr +C "$path" 2>/dev/null || true
    fi
  fi

  chmod 600 "$path"
  mkswap "$path" >/dev/null
  local discard_opt=""
  if [ "$IS_SSD" -eq 1 ]; then
    # Cho phép discard nếu là SSD (tùy môi trường, có thể bỏ để dùng fstrim cron)
    discard_opt=",discard"
  fi

  # Kích hoạt tạm thời
  swapon "$path"

  # Thêm vào /etc/fstab nếu chưa có
  if ! grep -qE "^[^#].*\s+$path\s+swap\s" /etc/fstab; then
    printf "%s\t\tswap\tswap\tdefaults,pri=100%s\t0\t0\n" "$path" "$discard_opt" >> /etc/fstab
    ok "Đã cập nhật /etc/fstab với $path."
  else
    ok "/etc/fstab đã có $path."
  fi

  ok "Đã tạo & bật swapfile: $path."
}

# ----------- Tune kernel params -----------
apply_tuning() {
  local swappiness vfs

  # Swappiness: RAM lớn -> giảm; HDD -> cao hơn SSD một chút
  if awk "BEGIN{exit !($TOTAL_RAM_GB >= 32.0)}"; then
    swappiness=10
  elif awk "BEGIN{exit !($TOTAL_RAM_GB >= 16.0)}"; then
    swappiness=15
  elif awk "BEGIN{exit !($TOTAL_RAM_GB >= 8.0)}"; then
    swappiness=20
  else
    swappiness=25
  fi
  if [ "$IS_SSD" -eq 0 ]; then
    # HDD: I/O đắt -> tăng swappiness nhẹ để tránh dồn bộ nhớ bẩn, nhưng vẫn bảo thủ
    swappiness=$(( swappiness + 5 ))
  fi

  # vfs_cache_pressure: cân bằng giữ cache inode/dentry
  if awk "BEGIN{exit !($TOTAL_RAM_GB >= 16.0)}"; then
    vfs=50
  else
    vfs=75
  fi

  local cfg="/etc/sysctl.d/99-swap-tuning.conf"
  cat > "$cfg" <<EOF
# Auto generated by auto-swap-ubuntu.sh
vm.swappiness = $swappiness
vm.vfs_cache_pressure = $vfs
EOF
  sysctl -p "$cfg" >/dev/null
  ok "Đã áp dụng tối ưu kernel: swappiness=$swappiness, vfs_cache_pressure=$vfs."
}

# ----------- Execution flow -----------
NEED_MB=0
if [ "$EXISTING_SWAP_MB" -lt "$RECOMMENDED_SWAP_MB" ]; then
  NEED_MB=$(( RECOMMENDED_SWAP_MB - EXISTING_SWAP_MB ))
  log "Cần bổ sung thêm ${NEED_MB}MB swap."
  if [ "$NEED_MB" -gt "$ROOT_AVAIL_MB" ]; then
    warn "Không đủ dung lượng trống (${ROOT_AVAIL_MB}MB) để đạt khuyến nghị. Sẽ tạo tối đa có thể."
    NEED_MB=$(( ROOT_AVAIL_MB * 90 / 100 ))
  fi
  [ "$NEED_MB" -ge 256 ] || die "Dung lượng bổ sung quá nhỏ (<256MB). Hủy thao tác."

  SWAPFILE_PATH=$(choose_swapfile_path)
  create_swapfile "$SWAPFILE_PATH" "$NEED_MB"
else
  ok "Dung lượng swap hiện tại đã đạt hoặc vượt mức khuyến nghị. Không cần tạo thêm."
fi

apply_tuning

# ----------- Summary -----------
FINAL_SWAP_MB=$(swapon --show --bytes | awk 'NR>1 {sum+=$3} END {printf "%.0f", sum/1024/1024}')
ok "TỔNG KẾT:"
printf "  - RAM:               %.2f GB\n" "$TOTAL_RAM_GB"
printf "  - Ổ gốc:             %s (%s)\n" "$ROOT_DEV" "$( [ "$IS_SSD" -eq 1 ] && echo SSD || echo HDD )"
printf "  - Swap khuyến nghị:  %s MB\n" "$RECOMMENDED_SWAP_MB"
printf "  - Swap hiện tại:     %s MB\n" "$FINAL_SWAP_MB"
printf "  - fstab:             đã cập nhật nếu cần\n"

log "Hoàn tất. Bạn có thể kiểm tra bằng:  swapon --show  &&  cat /proc/sys/vm/swappiness"
