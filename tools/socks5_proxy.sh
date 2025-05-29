#!/bin/bash

# Màu sắc cho output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# File lưu thông tin proxy
OUTPUT_FILE="/root/socks5proxy.txt"

# Thư mục làm việc
WORK_DIR="/root/socks5-proxy"

# Cổng mặc định
START_PORT=5000

# Địa chỉ IP công cộng
PUBLIC_IP=$(curl -s ifconfig.me)
if [ -z "$PUBLIC_IP" ]; then
    echo -e "${RED}Lỗi: Không thể lấy IP công cộng. Kiểm tra kết nối mạng!${NC}"
    exit 1
fi

# Hàm kiểm tra lệnh
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Hàm kiểm tra cổng
check_port() {
    local port=$1
    if netstat -tuln | grep -q ":$port\s"; then
        echo -e "${RED}Lỗi: Cổng $port đã được sử dụng!${NC}"
        exit 1
    fi
}

# Hàm hiển thị hướng dẫn sử dụng
usage() {
    echo -e "${YELLOW}Cách sử dụng: $0 [-p <start_port>] [-r]${NC}"
    echo -e "  -p <start_port>: Chỉ định cổng bắt đầu (mặc định: 5000)"
    echo -e "  -r: Xóa tất cả proxy đã cài đặt"
    echo -e "Ví dụ: $0 -p 8000"
    echo -e "       $0 -r"
    exit 1
}

# Hàm xóa tất cả proxy
remove_proxies() {
    echo -e "${YELLOW}Đang xóa tất cả proxy SOCKS5...${NC}"

    # Dừng và xóa container
    if [ -f "$WORK_DIR/docker-compose.yml" ]; then
        cd "$WORK_DIR"
        docker-compose down >/dev/null 2>&1
        echo -e "${GREEN}Đã dừng và xóa các container proxy.${NC}"
    fi

    # Xóa thư mục làm việc
    if [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
        echo -e "${GREEN}Đã xóa thư mục $WORK_DIR$.${NC}"
    fi

    # Xóa file thông tin proxy
    if [ -f "$OUTPUT_FILE" ]; then
        rm -f "$OUTPUT_FILE"
        echo -e "${GREEN}Đã xóa file $OUTPUT_FILE$.${NC}"
    fi

    # Đóng các cổng trong UFW
    if command_exists ufw; then
        for i in $(seq 0 9); do
            PORT=$((START_PORT + i))
            ufw delete allow $PORT/tcp >/dev/null 2>&1
        done
        echo -e "${GREEN}Đã đóng các cổng UFW (nếu có).${NC}"
    fi

    echo -e "${GREEN}Hoàn tất xóa!${NC}"
    exit 0
}

# Xử lý tùy chọn dòng lệnh
REMOVE_FLAG=0
while getopts "p:r" opt; do
    case $opt in
        p)
            START_PORT=$OPTARG
            if ! [[ "$START_PORT" =~ ^[0-9]+$ ]] || [ "$START_PORT" -lt 1024 ] || [ "$START_PORT" -gt 65535 ]; then
                echo -e "${RED}Lỗi: Cổng phải từ 1024 đến 65535!${NC}"
                exit 1
            fi
            ;;
        r)
            REMOVE_FLAG=1
            ;;
        *)
            usage
            ;;
    esac
done

# Thực hiện xóa nếu có tùy chọn -r
if [ "$REMOVE_FLAG" -eq 1 ]; then
    remove_proxies
fi

# Hàm ghi log và hiển thị
log_and_show() {
    echo -e "$1"
    echo "$1" >> "$OUTPUT_FILE"
}

# Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Script phải chạy với quyền root!${NC}"
    exit 1
fi

# Cập nhật hệ thống
echo -e "${YELLOW}Cập nhật hệ thống...${NC}"
apt update && apt upgrade -y

# Kiểm tra và cài đặt các gói phụ thuộc
echo -e "${YELLOW}Cài đặt các gói phụ thuộc...${NC}"
apt install -y apt-transport-https ca-certificates curl software-properties-common net-tools

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
echo -e "${YELLOW}Tổng RAM: ${TOTAL_RAM}MB. Sẽ tạo $PROXY_COUNT proxy SOCKS5 với cổng bắt đầu từ $START_PORT.${NC}"

# Kiểm tra cổng trước khi tạo proxy
for i in $(seq 0 $((PROXY_COUNT - 1))); do
    PORT=$((START_PORT + i))
    check_port $PORT
done

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
mkdir -p "$WORK_DIR/logs"
cd "$WORK_DIR"

# Tạo file docker-compose.yml
cat > docker-compose.yml <<EOF
version: '3'
services:
EOF

# Tạo dịch vụ proxy
for i in $(seq 1 $PROXY_COUNT); do
    PORT=$((START_PORT + i - 1))
    USERNAME=$(openssl rand -hex 4)
    PASSWORD=$(openssl rand -hex 4)
    echo "  socks5-proxy-$i:" >> docker-compose.yml
    echo "    image: serjs/go-socks5-proxy:latest" >> docker-compose.yml
    echo "    container_name: socks5-proxy-$i" >> docker-compose.yml
    echo "    ports:" >> docker-compose.yml
    echo "      - \"$PORT:1080\"" >> docker-compose.yml
    echo "    environment:" >> docker-compose.yml
    echo "      - SOCKS_USER=$USERNAME" >> docker-compose.yml
    echo "      - SOCKS_PASS=$PASSWORD" >> docker-compose.yml
    echo "    restart: always" >> docker-compose.yml
    echo "    cap_add:" >> docker-compose.yml
    echo "      - NET_ADMIN" >> docker-compose.yml

    # Mở cổng trong ufw
    ufw allow $PORT/tcp >/dev/null 2>&1

    # Lưu thông tin proxy
    PROXY_INFO="Proxy $i: socks5://$PUBLIC_IP:$PORT@$USERNAME:$PASSWORD"
    if [ $i -eq 1 ]; then
        echo -e "\nDanh sách proxy SOCKS5:\n" > "$OUTPUT_FILE"
    fi
    log_and_show "$PROXY_INFO"
done

# Khởi chạy proxy
echo -e "${YELLOW}Khởi chạy $PROXY_COUNT proxy SOCKS5...${NC}"
docker-compose up -d

# Kiểm tra trạng thái và log
echo -e "${YELLOW}Kiểm tra trạng thái container...${NC}"
docker ps
echo -e "${YELLOW}Log của socks5-proxy-1:${NC}"
docker logs socks5-proxy-1 || echo -e "${RED}Không thể lấy log của socks5-proxy-1${NC}"

# Hiển thị thông tin
echo -e "${GREEN}Hoàn tất! Thông tin proxy đã được lưu tại $OUTPUT_FILE${NC}"
echo -e "${YELLOW}Danh sách proxy để sao chép:${NC}"
cat "$OUTPUT_FILE"

exit 0
