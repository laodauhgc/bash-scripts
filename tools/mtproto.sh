#!/usr/bin/env bash
# Script Fix lỗi & Cài đặt MTProto Proxy (Chuẩn FakeTLS)
# Fix lỗi: Default secret, Connection timeout

set -Eeuo pipefail

# ================= CONFIG =================
# Dùng port 4430 để tránh trùng port 443 của hệ thống
START_PORT=4430
# Domain giả danh (FakeTLS) - Giúp proxy khó bị chặn hơn
FAKE_DOMAIN="www.google.com"
DOMAIN_HEX=$(echo -n "$FAKE_DOMAIN" | xxd -ps | tr -d '\n')
# File lưu thông tin
OUTPUT_FILE="/root/mtproxy_fixed.txt"
# ==========================================

# Màu sắc
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}=== BẮT ĐẦU QUÁ TRÌNH SỬA LỖI & CÀI ĐẶT MTPROXY ===${NC}"

# 1. Dọn dẹp container cũ nát
echo -e "${YELLOW}[1/5] Dọn dẹp các container cũ...${NC}"
if [ -d "/root/mtproto-proxy" ]; then
    cd /root/mtproto-proxy
    docker compose down >/dev/null 2>&1 || docker-compose down >/dev/null 2>&1 || true
    cd ..
    rm -rf /root/mtproto-proxy
fi
# Xóa lẻ tẻ nếu còn sót
docker ps -a --filter "name=mtproxy" -q | xargs -r docker rm -f >/dev/null 2>&1

# 2. Lấy IP
PUBLIC_IP=$(curl -s -m 5 ifconfig.me)
if [ -z "$PUBLIC_IP" ]; then
    echo -e "${RED}Lỗi: Không lấy được IP Public.${NC}"
    exit 1
fi

# 3. Tính toán số lượng Proxy
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
if [ "$TOTAL_RAM" -lt 1024 ]; then PROXY_COUNT=1
elif [ "$TOTAL_RAM" -lt 2048 ]; then PROXY_COUNT=2
else PROXY_COUNT=4 
fi
# Giới hạn 4 proxy là đủ cho nhu cầu lớn, tránh spam port

echo -e "${GREEN}RAM: ${TOTAL_RAM}MB. IP: ${PUBLIC_IP}.${NC}"
echo -e "${GREEN}Sẽ tạo $PROXY_COUNT Proxy chế độ FakeTLS (giả danh $FAKE_DOMAIN).${NC}"

# 4. Tạo Docker Compose mới
mkdir -p /root/mtproto-proxy
cd /root/mtproto-proxy

cat > docker-compose.yml <<EOF
name: mtproto-proxy
services:
EOF

# Xóa file cũ
> "$OUTPUT_FILE"
echo "=======================================================" >> "$OUTPUT_FILE"
echo " MTPROTO PROXY LIST (FakeTLS Mode - Anti Censorship)" >> "$OUTPUT_FILE"
echo "=======================================================" >> "$OUTPUT_FILE"

for ((i=1; i<=PROXY_COUNT; i++)); do
    PORT=$((START_PORT + i - 1))
    # Tạo Secret 32 ký tự Hex chuẩn
    SECRET=$(openssl rand -hex 16)
    
    # Thêm vào docker-compose
    cat >> docker-compose.yml <<EOF
  mtproxy-$i:
    image: alexbers/mtprotoproxy:latest
    container_name: mtproxy-$i
    restart: always
    ports:
      - "$PORT:443"
    environment:
      - PORT=443
      - SECRET=$SECRET
      - TLS_DOMAIN=$FAKE_DOMAIN
      - WORKERS=1
EOF
    
    # Mở ufw (Local firewall)
    if command -v ufw >/dev/null; then
        ufw allow "$PORT"/tcp >/dev/null 2>&1
    fi

    # Tạo Link kết nối chuẩn FakeTLS
    # Cấu trúc: tg://proxy?server=IP&port=PORT&secret=ee + SECRET + HEX_DOMAIN
    # ee: đánh dấu FakeTLS
    FULL_SECRET="ee${SECRET}${DOMAIN_HEX}"
    TG_LINK="tg://proxy?server=$PUBLIC_IP&port=$PORT&secret=$FULL_SECRET"
    
    echo "Proxy $i (Port $PORT):" >> "$OUTPUT_FILE"
    echo "Link: $TG_LINK" >> "$OUTPUT_FILE"
    echo "-------------------------------------------------------" >> "$OUTPUT_FILE"
done

# 5. Khởi chạy
echo -e "${YELLOW}[4/5] Đang khởi chạy container...${NC}"
if docker compose up -d; then
    echo -e "${GREEN}[5/5] Thành công! Container đang chạy.${NC}"
else
    # Fallback nếu docker compose v2 chưa cài
    docker-compose up -d
fi

echo ""
echo -e "${YELLOW}LƯU Ý QUAN TRỌNG VỚI GOOGLE CLOUD (GCP):${NC}"
echo -e "Bạn PHẢI mở port trên trang quản trị Google Cloud Firewall:"
echo -e "   - Port Range: ${START_PORT}-$((START_PORT + PROXY_COUNT - 1))"
echo -e "   - Protocol: TCP"
echo ""
echo -e "${GREEN}Thông tin kết nối đã lưu tại: $OUTPUT_FILE${NC}"
cat "$OUTPUT_FILE"
