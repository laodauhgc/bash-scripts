
#!/bin/bash

# Script tự động cài đặt MTProto Proxy trên Ubuntu bằng Docker
# Ngày: 26/05/2025

# Màu sắc cho output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# File lưu thông tin proxy
OUTPUT_FILE="/root/mtproxy.txt"

# Cổng mặc định
START_PORT=10000

# Địa chỉ IP công cộng
PUBLIC_IP=$(curl -s ifconfig.me)
if [ -z "$PUBLIC_IP" ]; then
    echo -e "${RED}Lỗi: Không thể lấy IP công cộng. Kiểm tra kết nối mạng!${NC}"
    exit 1
fi

# Hàm hiển thị hướng dẫn sử dụng
usage() {
    echo -e "${YELLOW}Cách sử dụng: $0 [-p <start_port>]${NC}"
    echo -e "  -p <start_port>: Chỉ định cổng bắt đầu (mặc định: 10000)"
    echo -e "Ví dụ: $0 -p 8000"
    exit 1
}

# Xử lý tùy chọn dòng lệnh
while getopts "p:" opt; do
    case $opt in
        p)
            START_PORT=$OPTARG
            # Kiểm tra xem cổng có phải là số hợp lệ
            if ! [[ "$START_PORT" =~ ^[0-9]+$ ]] || [ "$START_PORT" -lt 1024 ] || [ "$START_PORT" -gt 65535 ]; then
                echo -e "${RED}Lỗi: Cổng phải là số từ 1024 đến 65535!${NC}"
                exit 1
            fi
            ;;
        \?)
            usage
            ;;
    esac
done

# Hàm kiểm tra lệnh
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Hàm ghi log và hiển thị
log_and_show() {
    echo -e "$1"
    echo "$1" >> "$OUTPUT_FILE"
}

# Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Script phải chạy với quyền root. Chạy lại với sudo!${NC}"
    exit 1
fi

# Cập nhật hệ thống
echo -e "${YELLOW}Cập nhật hệ thống...${NC}"
apt update && apt upgrade -y

# Kiểm tra và cài đặt các gói phụ thuộc
echo -e "${YELLOW}Kiểm tra và cài đặt các gói phụ thuộc...${NC}"
apt install -y apt-transport-https ca-certificates curl software-properties-common

# Kiểm tra và cài đặt Docker
if ! command_exists docker; then
    echo -e "${YELLOW}Cài đặt Docker...${NC}"
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io
    systemctl start docker
    systemctl enable docker
else
    echo -e "${GREEN}Docker đã được cài đặt.${NC}"
fi

# Kiểm tra và cài đặt Docker Compose
if ! command_exists docker-compose; then
    echo -e "${YELLOW}Cài đặt Docker Compose...${NC}"
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
else
    echo -e "${GREEN}Docker Compose đã được cài đặt.${NC}"
fi

# Tính toán số proxy dựa trên RAM
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
if [ "$TOTAL_RAM" -lt 512 ]; then
    PROXY_COUNT=1
elif [ "$TOTAL_RAM" -lt 1024 ]; then
    PROXY_COUNT=2
elif [ "$TOTAL_RAM" -lt 2048 ]; then
    PROXY_COUNT=5
else
    PROXY_COUNT=10
fi
echo -e "${YELLOW}Tổng RAM: ${TOTAL_RAM}MB. Sẽ tạo $PROXY_COUNT proxy với cổng bắt đầu từ $START_PORT.${NC}"

# Kiểm tra và cài đặt ufw nếu chưa có
if ! command_exists ufw; then
    echo -e "${YELLOW}Cài đặt ufw...${NC}"
    apt install -y ufw
fi

# Kích hoạt ufw nếu chưa bật
if ! ufw status | grep -q "Status: active"; then
    echo -e "${YELLOW}Kích hoạt ufw...${NC}"
    ufw enable
fi

# Tạo thư mục làm việc
mkdir -p /root/telegram-proxy
cd /root/telegram-proxy

# Tạo file docker-compose.yml
cat > docker-compose.yml <<EOF
version: '3'
services:
EOF

# Tạo dịch vụ proxy
for i in $(seq 1 $PROXY_COUNT); do
    PORT=$((START_PORT + i - 1))
    SECRET=$(openssl rand -hex 16)
    echo "  mtproto-proxy-$i:" >> docker-compose.yml
    echo "    image: telegrammessenger/proxy:latest" >> docker-compose.yml
    echo "    container_name: mtproto-proxy-$i" >> docker-compose.yml
    echo "    ports:" >> docker-compose.yml
    echo "      - \"$PORT:443\"" >> docker-compose.yml
    echo "    environment:" >> docker-compose.yml
    echo "      - SECRET=$SECRET" >> docker-compose.yml
    echo "    restart: always" >> docker-compose.yml

    # Mở cổng trong ufw
    ufw allow $PORT/tcp >/dev/null 2>&1

    # Lưu thông tin proxy
    PROXY_LINK="tg://proxy?server=$PUBLIC_IP&port=$PORT&secret=$SECRET"
    if [ $i -eq 1 ]; then
        echo -e "\nDanh sách proxy MTProto:\n" > "$OUTPUT_FILE"
    fi
    log_and_show "Proxy $i: $PROXY_LINK"
done

# Khởi chạy proxy
echo -e "${YELLOW}Khởi chạy $PROXY_COUNT proxy...${NC}"
docker-compose up -d

# Kiểm tra trạng thái
echo -e "${YELLOW}Kiểm tra trạng thái container...${NC}"
docker ps

# Hiển thị thông tin
echo -e "${GREEN}Hoàn tất! Thông tin proxy đã được lưu tại $OUTPUT_FILE${NC}"
echo -e "${YELLOW}Danh sách proxy để sao chép:${NC}"
cat "$OUTPUT_FILE"

exit 0
