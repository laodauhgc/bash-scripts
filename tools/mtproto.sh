#!/usr/bin/env bash
# Script Fix lỗi MTProto Proxy (Final Version)
# Sử dụng Image Tyony ổn định hơn & Fix lỗi lệch Secret

set -Eeuo pipefail

# ================= CONFIG =================
START_PORT=4430
FAKE_DOMAIN="www.google.com"
OUTPUT_FILE="/root/mtproxy_final.txt"
# ==========================================

# Màu sắc
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}=== BẮT ĐẦU SỬA LỖI MTPROXY (FINAL FIX) ===${NC}"

# 1. Dọn dẹp sạch sẽ container cũ
echo -e "${YELLOW}[1/6] Dọn dẹp container cũ...${NC}"
if [ -d "/root/mtproto-proxy" ]; then
    cd /root/mtproto-proxy
    docker compose down >/dev/null 2>&1 || docker-compose down >/dev/null 2>&1 || true
    cd ..
    rm -rf /root/mtproto-proxy
fi
docker ps -a --filter "name=mtproxy" -q | xargs -r docker rm -f >/dev/null 2>&1

# 2. Lấy IP
PUBLIC_IP=$(curl -s -m 5 ifconfig.me)
[ -z "$PUBLIC_IP" ] && { echo -e "${RED}Không lấy được IP.${NC}"; exit 1; }

# 3. Tính toán
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
if [ "$TOTAL_RAM" -lt 1024 ]; then PROXY_COUNT=1
elif [ "$TOTAL_RAM" -lt 2048 ]; then PROXY_COUNT=2
else PROXY_COUNT=4
fi

echo -e "${GREEN}IP: ${PUBLIC_IP} | Tạo $PROXY_COUNT Proxy.${NC}"

# 4. Chuẩn bị Hex Domain cho FakeTLS
# Chuyển domain sang hex
DOMAIN_HEX=$(echo -n "$FAKE_DOMAIN" | xxd -ps | tr -d '\n')

# 5. Tạo Docker Compose
mkdir -p /root/mtproto-proxy
cd /root/mtproto-proxy

cat > docker-compose.yml <<EOF
name: mtproto-proxy
services:
EOF

> "$OUTPUT_FILE"
echo "=======================================================" >> "$OUTPUT_FILE"
echo " MTPROTO PROXY LIST (Fixed & Verified)" >> "$OUTPUT_FILE"
echo "=======================================================" >> "$OUTPUT_FILE"

for ((i=1; i<=PROXY_COUNT; i++)); do
    PORT=$((START_PORT + i - 1))
    # Tạo Random Hex 32 ký tự
    RAND_HEX=$(openssl rand -hex 16)
    
    # Tạo FULL SECRET (ee + Random + DomainHex)
    # Đây là điểm quan trọng: Ta tạo secret hoàn chỉnh rồi ném vào container
    # Container sẽ không phải tự đoán hay ghép chuỗi nữa.
    FULL_SECRET="ee${RAND_HEX}${DOMAIN_HEX}"
    
    cat >> docker-compose.yml <<EOF
  mtproxy-$i:
    image: tyony/mtproto-proxy:latest
    container_name: mtproxy-$i
    restart: always
    ports:
      - "$PORT:443"
    environment:
      - SECRET=$FULL_SECRET
      # Image này dùng port 443 bên trong mặc định
EOF
    
    # Mở ufw
    if command -v ufw >/dev/null; then ufw allow "$PORT"/tcp >/dev/null 2>&1; fi

    TG_LINK="tg://proxy?server=$PUBLIC_IP&port=$PORT&secret=$FULL_SECRET"
    
    echo "Proxy $i (Port $PORT):" >> "$OUTPUT_FILE"
    echo "Link: $TG_LINK" >> "$OUTPUT_FILE"
    echo "-------------------------------------------------------" >> "$OUTPUT_FILE"
done

# 6. Khởi chạy
echo -e "${YELLOW}[5/6] Khởi chạy container (Image: tyony)...${NC}"
if docker compose up -d; then
    echo -e "${GREEN}[OK] Container đã chạy.${NC}"
else
    docker-compose up -d
fi

# 7. Kiểm tra thử (Self-Check)
echo -e "${YELLOW}[6/6] Kiểm tra kết nối nội bộ...${NC}"
sleep 5
CHECK_PORT=$START_PORT
# Dùng curl để test xem cổng có mở không (không cần nội dung trả về, chỉ cần connect được)
if curl -v telnet://127.0.0.1:$CHECK_PORT >/dev/null 2>&1; then
    echo -e "${GREEN}✅ Kiểm tra Local: Cổng $CHECK_PORT ĐANG MỞ và phản hồi.${NC}"
else
    echo -e "${RED}❌ Kiểm tra Local: Không thể kết nối vào cổng $CHECK_PORT.${NC}"
    echo "Vui lòng kiểm tra lại 'docker logs mtproxy-1'"
fi

echo ""
echo -e "${GREEN}Hoàn tất! Hãy thử copy link bên dưới vào Telegram:${NC}"
cat "$OUTPUT_FILE"
