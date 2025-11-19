#!/usr/bin/env bash
# Optimized from Original Script
# Image: telegrammessenger/proxy:latest (Official)
# Supports: Ubuntu/Debian/CentOS/RHEL

set -Eeuo pipefail

# ================= CONFIG =================
OUTPUT_FILE="/root/mtproxy.txt"
WORK_DIR="/root/mtproto-proxy"
START_PORT=10000  # Giữ nguyên port gốc của bạn
# ==========================================

# Màu sắc
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}=== CÀI ĐẶT MTPROXY (OFFICIAL IMAGE) ===${NC}"

# 1. Kiểm tra Root
[[ $EUID -ne 0 ]] && { echo -e "${RED}Cần quyền root.${NC}"; exit 1; }

# 2. Phát hiện OS và Package Manager
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_LIKE=${ID_LIKE:-$ID}
else
    OS_LIKE="unknown"
fi

case "$OS_LIKE" in
    *debian*|ubuntu) PKG_MANAGER="apt" ;;
    *rhel*|*centos*|*fedora*) PKG_MANAGER="dnf" ;;
    *) echo "OS không hỗ trợ tự động cài package."; exit 1 ;;
esac

# 3. Hàm cài đặt Docker chuẩn
install_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "Cài đặt Docker..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable --now docker
    fi

    # Cài Docker Compose Plugin (Sửa lỗi command not found)
    if ! docker compose version >/dev/null 2>&1; then
        echo "Cài đặt Docker Compose Plugin..."
        case "$PKG_MANAGER" in
            apt) apt-get update && apt-get install -y docker-compose-plugin ;;
            dnf) dnf install -y docker-compose-plugin ;;
        esac
    fi
}

# 4. Dọn dẹp cũ (Cleanup)
if [[ -d "$WORK_DIR" ]]; then
    cd "$WORK_DIR"
    docker compose down >/dev/null 2>&1 || docker-compose down >/dev/null 2>&1 || true
    cd ..
    rm -rf "$WORK_DIR"
fi
# Xóa container cũ tên mtproto-proxy-*
docker ps -a --filter "name=mtproto-proxy" -q | xargs -r docker rm -f >/dev/null 2>&1

# 5. Cài đặt Dependencies
install_docker
case "$PKG_MANAGER" in
    apt) apt-get install -y -qq curl net-tools ;;
    dnf) dnf install -y curl net-tools ;;
esac

# 6. Lấy IP và Tính RAM
PUBLIC_IP=$(curl -s -m 5 ifconfig.me)
[ -z "$PUBLIC_IP" ] && { echo -e "${RED}Lỗi IP.${NC}"; exit 1; }

TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
if [ "$TOTAL_RAM" -lt 512 ]; then PROXY_COUNT=1
elif [ "$TOTAL_RAM" -lt 1024 ]; then PROXY_COUNT=2
elif [ "$TOTAL_RAM" -lt 2048 ]; then PROXY_COUNT=5
else PROXY_COUNT=10
fi

echo -e "${GREEN}RAM: ${TOTAL_RAM}MB -> Tạo $PROXY_COUNT Proxy.${NC}"

# 7. Tạo Docker Compose (Giữ nguyên Image gốc)
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

cat > docker-compose.yml <<EOF
name: mtproto-proxy
services:
EOF

> "$OUTPUT_FILE"

for ((i=1; i<=PROXY_COUNT; i++)); do
    PORT=$((START_PORT + i - 1))
    SECRET=$(openssl rand -hex 16)
    
    cat >> docker-compose.yml <<EOF
  mtproto-proxy-$i:
    image: telegrammessenger/proxy:latest
    container_name: mtproto-proxy-$i
    restart: always
    ports:
      - "$PORT:443"
    environment:
      - SECRET=$SECRET
EOF

    # Mở Firewall (Hỗ trợ cả UFW và Firewalld)
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q active; then
        ufw allow "$PORT"/tcp >/dev/null 2>&1
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="$PORT"/tcp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi

    LINK="tg://proxy?server=$PUBLIC_IP&port=$PORT&secret=$SECRET"
    echo "Proxy $i: $LINK" >> "$OUTPUT_FILE"
done

# 8. Khởi chạy
echo -e "${YELLOW}Đang khởi chạy...${NC}"
# Dùng docker compose (v2) thay vì docker-compose (v1)
if docker compose up -d; then
    echo -e "${GREEN}Thành công!${NC}"
else
    # Fallback
    docker-compose up -d
fi

echo ""
echo -e "${GREEN}Danh sách Proxy:${NC}"
cat "$OUTPUT_FILE"
