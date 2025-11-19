#!/usr/bin/env bash
# Universal Swap Manager
# Hỗ trợ: Ubuntu, Debian, CentOS, RHEL, Fedora, Arch, Alpine
# Tính năng: Smart Size, Fallback dd, Kernel Tuning

set -Eeuo pipefail

# ==============================================================================
# CẤU HÌNH & BIẾN
# ==============================================================================
SWAP_FILE="/swapfile"
FSTAB="/etc/fstab"
SYSCTL_CONF="/etc/sysctl.d/99-swap-tuning.conf"

# Màu sắc
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# ==============================================================================
# HÀM HỖ TRỢ
# ==============================================================================

log_info()  { echo -e "${BLUE}[INFO] $1${NC}"; }
log_ok()    { echo -e "${GREEN}[OK] $1${NC}"; }
log_warn()  { echo -e "${YELLOW}[WARN] $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

check_root() {
    [[ $EUID -eq 0 ]] || log_error "Vui lòng chạy với quyền root (sudo)."
}

remove_swap() {
    log_warn "Đang tiến hành gỡ bỏ Swap..."

    # 1. Tắt swap
    if swapon --show | grep -q "$SWAP_FILE"; then
        swapoff "$SWAP_FILE" || log_error "Không thể tắt swap."
        log_ok "Đã tắt swap."
    else
        log_info "Swap không hoạt động."
    fi

    # 2. Xóa khỏi fstab (Chỉ xóa dòng chứa /swapfile)
    if grep -q "$SWAP_FILE" "$FSTAB"; then
        # Tạo backup an toàn trước khi sửa
        cp "$FSTAB" "${FSTAB}.bak.$(date +%s)"
        # Dùng sed để xóa dòng chứa /swapfile
        sed -i "\#$SWAP_FILE#d" "$FSTAB"
        log_ok "Đã xóa cấu hình trong /etc/fstab."
    fi

    # 3. Xóa file
    if [[ -f "$SWAP_FILE" ]]; then
        rm -f "$SWAP_FILE"
        log_ok "Đã xóa file $SWAP_FILE."
    fi

    # 4. Xóa cấu hình sysctl tuning
    if [[ -f "$SYSCTL_CONF" ]]; then
        rm -f "$SYSCTL_CONF"
        # Reload lại sysctl mặc định (hoặc gần nhất)
        sysctl --system >/dev/null 2>&1 || true
        log_ok "Đã gỡ bỏ cấu hình tối ưu kernel."
    fi

    log_ok "Hoàn tất gỡ bỏ!"
    free -h
    exit 0
}

# ==============================================================================
# CHƯƠNG TRÌNH CHÍNH
# ==============================================================================

check_root

# Xử lý tham số
if [[ "${1:-}" == "-r" ]]; then
    remove_swap
fi

# 1. Tính toán dung lượng Swap (Smart Sizing)
# Lấy RAM bằng MB
RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
DISK_FREE_MB=$(df -m / | awk 'NR==2 {print $4}')

log_info "RAM: ${RAM_MB} MB | Đĩa trống: ${DISK_FREE_MB} MB"

# Logic tính toán
if [ "$RAM_MB" -lt 2048 ]; then
    # < 2GB RAM -> Swap = 2x RAM
    TARGET_SWAP=$((RAM_MB * 2))
elif [ "$RAM_MB" -lt 8192 ]; then
    # 2GB - 8GB RAM -> Swap = RAM
    TARGET_SWAP=$RAM_MB
else
    # > 8GB RAM -> Swap = 8GB (Max cap)
    TARGET_SWAP=8192
fi

# Đảm bảo đĩa còn trống ít nhất 1GB sau khi tạo swap
if [ "$DISK_FREE_MB" -lt $((TARGET_SWAP + 1024)) ]; then
    log_warn "Dung lượng đĩa thấp. Điều chỉnh lại kích thước Swap..."
    TARGET_SWAP=$((DISK_FREE_MB - 1024))
    if [ "$TARGET_SWAP" -lt 512 ]; then
        log_error "Không đủ dung lượng đĩa để tạo Swap an toàn (Cần tối thiểu 512MB)."
    fi
fi

log_info "Kích thước Swap dự kiến: ${TARGET_SWAP} MB"

# 2. Dọn dẹp swap cũ nếu có
if grep -q "$SWAP_FILE" "$FSTAB" || [[ -f "$SWAP_FILE" ]]; then
    log_warn "Phát hiện Swap cũ, đang dọn dẹp..."
    swapoff "$SWAP_FILE" >/dev/null 2>&1 || true
    rm -f "$SWAP_FILE"
    sed -i "\#$SWAP_FILE#d" "$FSTAB"
fi

# 3. Tạo file Swap
log_info "Đang tạo file Swap..."
if command -v fallocate >/dev/null 2>&1; then
    if fallocate -l "${TARGET_SWAP}M" "$SWAP_FILE" 2>/dev/null; then
        log_ok "Đã tạo file bằng fallocate."
    else
        log_warn "fallocate thất bại (có thể do File System). Chuyển sang dùng dd..."
        dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$TARGET_SWAP" status=progress
    fi
else
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$TARGET_SWAP" status=progress
fi

# 4. Phân quyền & Format
chmod 600 "$SWAP_FILE"
mkswap "$SWAP_FILE" >/dev/null
swapon "$SWAP_FILE"
log_ok "Đã kích hoạt Swap."

# 5. Cập nhật fstab
# Sao lưu fstab gốc nếu chưa có
if [ ! -f "${FSTAB}.bak" ]; then
    cp "$FSTAB" "${FSTAB}.bak"
fi
echo "$SWAP_FILE none swap sw 0 0" >> "$FSTAB"
log_ok "Đã cập nhật fstab."

# 6. Tối ưu hóa Kernel (Sysctl)
log_info "Tối ưu hóa Swappiness..."
# Swappiness=10: Chỉ dùng swap khi RAM thực sự đầy (tốt cho server)
# Cache_pressure=50: Cân bằng giữa việc cache file system và giải phóng RAM
cat > "$SYSCTL_CONF" <<EOF
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF

# Áp dụng ngay lập tức
sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || sysctl -w vm.swappiness=10 >/dev/null 2>&1
log_ok "Đã áp dụng cấu hình tối ưu."

# 7. Kết quả
echo "-------------------------------------------------------"
log_ok "Cài đặt hoàn tất!"
echo "-------------------------------------------------------"
free -h
echo "-------------------------------------------------------"
echo -e "${YELLOW}Để gỡ bỏ: $0 -r${NC}"
