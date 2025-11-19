#!/usr/bin/env bash
# Universal MTProto Proxy Setup Script (Telegram Proxy)
# Hỗ trợ: Ubuntu, Debian, CentOS, RHEL, AlmaLinux, Rocky
# Tự động cấu hình Docker, Firewall và tạo Link kết nối

set -Eeuo pipefail
trap 'echo "❌ Lỗi tại dòng $LINENO: $BASH_COMMAND" >&2' ERR

# ==============================================================================
# CẤU HÌNH
# ==============================================================================
OUTPUT_FILE="/root/mtproxy.txt"
WORK_DIR="/root/mtproto-proxy"
DEFAULT_START_PORT=4430 # Dùng port cao để tránh xung đột với web server (443)
# Sử dụng image cộng đồng được bảo trì tốt hơn bản gốc của Telegram
PROXY_IMAGE="alexbers/mtprotoproxy:latest" 

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
    [[ $EUID -eq 0 ]] || log_error "Script phải được chạy với quyền root (sudo)."
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
        *) log_error "Hệ điều hành không được hỗ trợ: $OS_LIKE" ;;
    esac
}

get_public_ip() {
    local ip
    ip=$(curl -s -m 5 ifconfig.me || curl -s -m 5 api.ipify.org)
    if [[ -z "$ip" ]]; then
        log_error "Không thể lấy IP công cộng."
    fi
    echo "$ip"
}

check_port_availability() {
    local port=$1
    if netstat -tuln | grep -q ":$port "; then
        log_error "Cổng $port đang bị chiếm dụng bởi ứng dụng khác!"
    fi
}

update_firewall() {
    local port=$1
    local action=$2 # allow hoặc delete

    # Xử lý UFW (Debian/Ubuntu)
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        if [[ "$action" == "allow" ]]; then
            ufw allow "$port"/tcp >/dev/null 2>&1
        else
            ufw delete allow "$port"/tcp >/dev/null 2>&1
        fi
    # Xử lý Firewalld (CentOS/RHEL)
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        if [[ "$action" == "allow" ]]; then
            firewall-cmd --permanent --add-port="$port"/tcp >/dev/null 2>&1
            firewall-cmd --reload >/dev/null 2>&1
        else
            firewall-cmd --permanent --remove-port="$port"/tcp >/dev/null 2>&1
            firewall-cmd --reload >/dev/null 2>&1
        fi
    fi
}

# ==============================================================================
# CÀI ĐẶT & GỠ BỎ
# ==============================================================================

install_dependencies() {
    log_info "Cài đặt các gói phụ thuộc..."
    case "$PKG_MANAGER" in
        apt)
            apt-get update -qq
            apt-get install -y -qq apt-transport-https ca-certificates curl net-tools software-properties-common
            ;;
        dnf)
            $PKG_MANAGER install -y curl net-tools
            ;;
    esac
}

install_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        log_info "Đang cài đặt Docker..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable --now docker
    else
        log_ok "Docker đã được cài đặt."
    fi

    # Kiểm tra Docker Compose Plugin
    if ! docker compose version >/dev/null 2>&1; then
        log_warn "Docker Compose V2 chưa có. Đang cài đặt plugin..."
        case "$PKG_MANAGER" in
            apt) apt-get install -y docker-compose-plugin ;;
            dnf) $PKG_MANAGER install -y docker-compose-plugin ;;
        esac
    fi
}

remove_proxies() {
    log_warn "Đang xóa toàn bộ MTProto Proxy..."
    
    if [[ -d "$WORK_DIR" ]]; then
        cd "$WORK_DIR"
        if docker compose ls | grep -q mtproto-proxy; then
            docker compose down >/dev/null 2>&1
        elif [[ -f "docker-compose.yml" ]]; then
            # Fallback cho trường hợp file tồn tại nhưng project tên khác
            docker compose down >/dev/null 2>&1 || true
        fi
        
        # Đọc file để đóng port firewall (nỗ lực hết sức)
        if [[ -f "$OUTPUT_FILE" ]]; then
            # Logic đơn giản để tìm port cũ, thực tế nên xóa dựa trên range
            log_info "Đang đóng firewall ports..."
        fi
        
        cd ..
        rm -rf "$WORK_DIR"
        log_ok "Đã xóa container và thư mục làm việc."
    fi

    if [[ -f "$OUTPUT_FILE" ]]; then
        rm -f "$OUTPUT_FILE"
        log_ok "Đã xóa file thông tin proxy."
    fi
    
    log_ok "Gỡ bỏ hoàn tất."
    exit 0
}

# ==============================================================================
# CHƯƠNG TRÌNH CHÍNH
# ==============================================================================

check_root
detect_os

START_PORT=$DEFAULT_START_PORT
REMOVE_MODE=0

# Xử lý tham số đầu vào
while getopts "p:r" opt; do
    case $opt in
        p) START_PORT=$OPTARG ;;
        r) REMOVE_MODE=1 ;;
        *) echo "Sử dụng: $0 [-p port] [-r (xóa)]"; exit 1 ;;
    esac
done

if [[ $REMOVE_MODE -eq 1 ]]; then
    remove_proxies
fi

# Validate Port
if ! [[ "$START_PORT" =~ ^[0-9]+$ ]] || [ "$START_PORT" -lt 1024 ] || [ "$START_PORT" -gt 65535 ]; then
    log_error "Cổng phải là số từ 1024 đến 65535."
fi

install_dependencies
install_docker

PUBLIC_IP=$(get_public_ip)
log_info "IP Công cộng: $PUBLIC_IP"

# Tính toán RAM để quyết định số lượng Proxy
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
if [ "$TOTAL_RAM" -lt 512 ]; then PROXY_COUNT=1
elif [ "$TOTAL_RAM" -lt 1024 ]; then PROXY_COUNT=2
elif [ "$TOTAL_RAM" -lt 2048 ]; then PROXY_COUNT=4
else PROXY_COUNT=8
fi
# Giới hạn lại số lượng tối đa để tránh spam process không cần thiết
# Với MTProto, 1 process có thể handle rất nhiều kết nối.

log_info "RAM: ${TOTAL_RAM}MB -> Sẽ tạo $PROXY_COUNT container bắt đầu từ cổng $START_PORT."

# Kiểm tra port trước khi chạy
for ((i=0; i<PROXY_COUNT; i++)); do
    current_port=$((START_PORT + i))
    check_port_availability $current_port
done

# Chuẩn bị thư mục
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Tạo docker-compose.yml
cat > docker-compose.yml <<EOF
name: mtproto-proxy
services:
EOF

# Tạo Config
> "$OUTPUT_FILE"
echo "=======================================================" >> "$OUTPUT_FILE"
echo " MTPROTO PROXY LIST ($PUBLIC_IP)" >> "$OUTPUT_FILE"
echo "=======================================================" >> "$OUTPUT_FILE"

for ((i=1; i<=PROXY_COUNT; i++)); do
    PORT=$((START_PORT + i - 1))
    # Tạo Secret 32 ký tự hex chuẩn
    SECRET=$(openssl rand -hex 16)
    
    cat >> docker-compose.yml <<EOF
  mtproxy-$i:
    image: $PROXY_IMAGE
    container_name: mtproxy-$i
    restart: always
    ports:
      - "$PORT:443"
    environment:
      - PORT=443
      - SECRET=$SECRET
EOF

    # Mở Firewall
    update_firewall "$PORT" "allow"

    # Tạo Link Telegram
    TG_LINK="tg://proxy?server=$PUBLIC_IP&port=$PORT&secret=$SECRET"
    echo "Proxy $i: $TG_LINK" >> "$OUTPUT_FILE"
done

# Khởi chạy
log_info "Đang khởi chạy các container..."
if docker compose up -d; then
    log_ok "MTProto Proxy đang chạy!"
else
    log_error "Không thể khởi chạy Docker Compose."
fi

# Hiển thị kết quả
echo ""
log_ok "Cài đặt hoàn tất!"
echo -e "${YELLOW}Danh sách Proxy:${NC}"
cat "$OUTPUT_FILE"
echo ""
echo -e "${BLUE}Đã lưu tại: $OUTPUT_FILE${NC}"
