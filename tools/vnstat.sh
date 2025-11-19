#!/usr/bin/env bash
# Universal VnStat Setup Script
# Hỗ trợ: Ubuntu/Debian, CentOS/RHEL, Fedora, Arch, Alpine
# Tự động cấu hình Interface và Database

set -Eeuo pipefail

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
    if [[ $EUID -ne 0 ]]; then
        log_error "Vui lòng chạy script này với quyền root (sudo -i)."
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_LIKE=${ID_LIKE:-$ID}
    else
        OS_LIKE="unknown"
    fi
    
    case "$OS_LIKE" in
        *debian*|ubuntu) PKG_MANAGER="apt" ;;
        *rhel*|*centos*|*fedora*|*almalinux*|*rocky*) PKG_MANAGER="dnf" ;;
        *arch*) PKG_MANAGER="pacman" ;;
        *alpine*) PKG_MANAGER="apk" ;;
        *) log_error "Hệ điều hành không được hỗ trợ tự động: $OS_LIKE" ;;
    esac
}

get_active_interface() {
    # Tìm interface đang có kết nối Internet thực tế (route tới 1.1.1.1)
    local iface
    iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')
    
    # Fallback nếu cách trên thất bại
    if [[ -z "$iface" ]]; then
        iface=$(ip route show default | awk '{print $5; exit}')
    fi

    if [[ -z "$iface" ]]; then
        log_error "Không tìm thấy giao diện mạng nào có kết nối Internet."
    fi
    echo "$iface"
}

# ==============================================================================
# CÀI ĐẶT & CẤU HÌNH
# ==============================================================================

install_vnstat() {
    log_info "Đang cập nhật hệ thống và cài đặt VnStat..."
    
    case "$PKG_MANAGER" in
        apt)
            apt-get update -qq
            apt-get install -y -qq vnstat
            ;;
        dnf)
            # CentOS/RHEL cần EPEL để có gói vnstat
            if ! rpm -q epel-release >/dev/null 2>&1; then
                log_info "Đang cài đặt EPEL Repository (cần thiết cho CentOS/RHEL)..."
                dnf install -y epel-release || yum install -y epel-release
            fi
            dnf install -y vnstat
            ;;
        pacman)
            pacman -Sy --noconfirm vnstat
            ;;
        apk)
            apk add vnstat
            ;;
    esac
}

configure_vnstat() {
    local iface=$1
    log_info "Đang cấu hình VnStat cho giao diện: $iface"

    # Dừng service trước khi cấu hình
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop vnstat 2>/dev/null || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service vnstat stop 2>/dev/null || true
    fi

    # Cấp quyền cho thư mục database (quan trọng trên một số VPS)
    mkdir -p /var/lib/vnstat
    chown -R vnstat:vnstat /var/lib/vnstat 2>/dev/null || chown -R root:root /var/lib/vnstat

    # Kích hoạt theo dõi Interface
    # VnStat 2.x dùng lệnh --add, VnStat 1.x dùng -u -i
    if vnstat --version 2>&1 | grep -q "vnStat 2"; then
        log_info "Phát hiện VnStat v2.x (SQLite Mode)"
        # Xóa config cũ nếu cần và thêm mới
        vnstat --remove -i "$iface" --force >/dev/null 2>&1 || true
        vnstat --add -i "$iface" || log_warn "Giao diện có thể đã được thêm tự động."
    else
        log_info "Phát hiện VnStat v1.x (Legacy Mode)"
        vnstat -u -i "$iface"
    fi

    # Khởi động lại Service
    log_info "Khởi động service..."
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now vnstat
        systemctl restart vnstat
    elif command -v rc-service >/dev/null 2>&1; then
        rc-update add vnstat default
        rc-service vnstat restart
    else
        # Fallback cho hệ thống cũ không có service manager chuẩn
        /etc/init.d/vnstat restart
    fi
}

# ==============================================================================
# MAIN
# ==============================================================================

check_root
detect_os

# 1. Cài đặt
install_vnstat

# 2. Tìm card mạng
INTERFACE=$(get_active_interface)
log_ok "Giao diện mạng được chọn: $INTERFACE"

# 3. Cấu hình & Start
configure_vnstat "$INTERFACE"

# 4. Kiểm tra
echo "-----------------------------------------------------"
log_ok "Cài đặt hoàn tất!"
echo "Đang đợi service thu thập dữ liệu mẫu..."
sleep 3 # Đợi daemon ghi dữ liệu

echo "-----------------------------------------------------"
vnstat -i "$INTERFACE"
echo "-----------------------------------------------------"
echo "Các lệnh xem thống kê:"
echo "  vnstat -h   : Xem theo giờ"
echo "  vnstat -d   : Xem theo ngày"
echo "  vnstat -m   : Xem theo tháng"
echo "  vnstat -l   : Xem trực tiếp (Live traffic)"
echo "-----------------------------------------------------"
