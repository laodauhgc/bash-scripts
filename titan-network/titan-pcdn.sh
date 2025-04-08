#!/bin/bash
# titan-pcdn.sh - Cài đặt và chạy Titan PCDN với ACCESS_TOKEN
# Sử dụng: ./titan-pcdn.sh [ACCESS_TOKEN]

echo "=================================================="
echo "Kiểm tra và cài đặt Docker (nếu cần)..."
echo "=================================================="

# Kiểm tra xem Docker đã cài chưa
if ! command -v docker &> /dev/null
then
    echo "-> Docker chưa cài đặt. Bắt đầu quá trình cài đặt..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y > /dev/null
    apt-get install -y apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release > /dev/null
    mkdir -p /usr/share/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --batch --yes --output /usr/share/keyrings/docker-archive-keyring.gpg --dearmor
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -y > /dev/null
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin > /dev/null
    systemctl start docker
    systemctl enable docker
    echo "-> Docker đã được cài đặt và khởi động."
else
    echo "-> Docker đã được cài đặt."
fi

# Kiểm tra Docker Compose plugin
if ! docker compose version &> /dev/null; then
     if ! command -v docker-compose &> /dev/null; then
       echo "Lỗi: Không tìm thấy 'docker compose' hoặc 'docker-compose'. Vui lòng cài đặt hoặc cập nhật Docker."
       exit 1
     fi
fi

echo "=================================================="
echo "Bắt đầu triển khai Titan PCDN..."
echo "=================================================="

# Lấy ACCESS_TOKEN từ tham số hoặc yêu cầu nhập
if [ -z "$1" ]; then
  read -p "Vui lòng nhập ACCESS_TOKEN của bạn: " ACCESS_TOKEN_VAR
else
  ACCESS_TOKEN_VAR=$1
fi

if [ -z "$ACCESS_TOKEN_VAR" ]; then
  echo "Lỗi: ACCESS_TOKEN không được để trống."
  exit 1
fi

# Thiết lập thư mục dự án
PROJECT_DIR=~/titan-pcdn
mkdir -p "$PROJECT_DIR/data/agent" "$PROJECT_DIR/data/docker"
cd "$PROJECT_DIR" || exit 1 # Thoát nếu không thể cd

echo "-> Đang tạo file docker-compose.yml tại $(pwd)..."
# Tạo file docker-compose.yml
cat > docker-compose.yml << EOF
version: "3.9"
services:
  titan-pcdn:
    image: laodauhgc/titan-pcdn:latest # Sử dụng image mới của bạn
    container_name: titan-pcdn
    privileged: true
    restart: always
    tty: true
    stdin_open: true
    security_opt:
      - apparmor=unconfined
    network_mode: host
    volumes:
      - ./data:/app/data
      - ./data/docker:/var/lib/docker
      - /etc/docker:/etc/docker:ro
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - ACCESS_TOKEN=${ACCESS_TOKEN_VAR}
      # Các biến môi trường khác đã được đặt trong Dockerfile
      - TARGETARCH=amd64
      - OS=linux
EOF

echo "-> Đang khởi động container..."
# Ưu tiên dùng 'docker compose'
if command -v docker &> /dev/null && docker compose version &> /dev/null; then
    docker compose up -d
else
    # Fallback về docker-compose cũ
    docker-compose up -d
fi

# Kiểm tra kết quả
if [ $? -eq 0 ]; then
    echo "=== Triển khai hoàn tất! ==="
    echo "- Thư mục cài đặt: $(pwd)"
    echo "- Kiểm tra logs: cd $PROJECT_DIR && docker compose logs -f"
    echo "- Trạng thái container:"
    sleep 2
    docker ps | grep titan-pcdn || echo "Container có thể chưa khởi động hoàn toàn, vui lòng kiểm tra lại sau."
else
    echo "Lỗi: Không thể khởi động container. Kiểm tra logs: cd $PROJECT_DIR && docker compose logs"
fi

echo ""
echo "Lệnh quản lý:"
echo "- Khởi động: cd $PROJECT_DIR && docker compose up -d"
echo "- Dừng: cd $PROJECT_DIR && docker compose down"
echo "- Khởi động lại: cd $PROJECT_DIR && docker compose restart"

exit 0
