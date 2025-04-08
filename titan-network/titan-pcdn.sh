#!/bin/bash
# install-titan-pcdn.sh - Cài đặt tự động Titan PCDN sử dụng image tùy chỉnh

# Ngừng ngay nếu có lỗi
set -e

# Màu sắc cho output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Hàm kiểm tra quyền Root ---
check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Lỗi: Script này cần quyền root để chạy.${NC}"
    echo -e "${YELLOW}Vui lòng sử dụng 'sudo ./install-titan-pcdn.sh [ACCESS_TOKEN]' hoặc chạy với tư cách root.${NC}"
    exit 1
  fi
  echo -e "${GREEN}* Quyền root đã được xác nhận.${NC}"
}

# --- Hàm cài đặt Docker ---
install_docker() {
  if command -v docker &> /dev/null && docker compose version &> /dev/null; then
    echo -e "${GREEN}* Docker và Docker Compose plugin đã được cài đặt.${NC}"
    return 0
  fi

  echo -e "${BLUE}* Bắt đầu cài đặt Docker và Docker Compose plugin...${NC}"
  export DEBIAN_FRONTEND=noninteractive
  # Cập nhật package list
  apt-get update -y > /dev/null
  # Cài các gói cần thiết
  apt-get install -y apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release > /dev/null
  # Thêm Docker GPG key
  mkdir -p /usr/share/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --batch --yes --output /usr/share/keyrings/docker-archive-keyring.gpg --dearmor
  # Thêm Docker repository
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  # Cài Docker Engine và Compose plugin
  apt-get update -y > /dev/null
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin > /dev/null
  # Khởi động và enable Docker service
  systemctl start docker
  systemctl enable docker
  echo -e "${GREEN}* Docker và Docker Compose plugin đã được cài đặt và khởi động.${NC}"
}

# --- Hàm chính cài đặt PCDN ---
setup_pcdn() {
  local access_token="$1"
  local project_dir=~/titan-pcdn # Thư mục cài đặt

  echo -e "${BLUE}* Bắt đầu cấu hình Titan PCDN tại thư mục: ${project_dir}${NC}"

  # Tạo thư mục và di chuyển vào
  mkdir -p "${project_dir}/data/docker"
  cd "${project_dir}" || exit 1

  # Tạo file .env
  echo -e "${BLUE}  - Đang tạo file .env chứa ACCESS_TOKEN...${NC}"
  echo "ACCESS_TOKEN=${access_token}" > .env
  chmod 600 .env # Giới hạn quyền đọc cho an toàn

  # Tạo file docker-compose.yaml
  echo -e "${BLUE}  - Đang tạo file docker-compose.yaml...${NC}"
  cat > docker-compose.yaml << EOF
services:
  titan-pcdn:
    image: laodauhgc/titan-pcdn:latest
    container_name: titan-pcdn
    privileged: true
    restart: always
    tty: true
    stdin_open: true
    security_opt:
      - apparmor:unconfined
    network_mode: host
    volumes:
      - ./data:/app/data
      - ./data/docker:/var/lib/docker
      - /etc/docker:/etc/docker:ro
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - ACCESS_TOKEN=\${ACCESS_TOKEN} # Docker Compose sẽ đọc từ file .env
      - TARGETARCH=amd64             # Đặt cứng hoặc tự động phát hiện nếu cần
      - OS=linux
EOF

  # Pull image mới nhất
  echo -e "${BLUE}* Đang kéo (pull) image mới nhất: laodauhgc/titan-pcdn:latest...${NC}"
  if docker compose pull; then
    echo -e "${GREEN}* Pull image thành công.${NC}"
  else
    echo -e "${RED}Lỗi: Không thể pull image. Vui lòng kiểm tra kết nối mạng và tên image.${NC}"
    exit 1
  fi

  # Khởi chạy container
  echo -e "${BLUE}* Đang khởi chạy container Titan PCDN...${NC}"
  if docker compose up -d; then
    echo -e "${GREEN}* Khởi chạy container thành công!${NC}"
    echo -e "=================================================="
    echo -e "${GREEN}=== Cài đặt và Khởi chạy Hoàn Tất! ===${NC}"
    echo -e "  - Thư mục cài đặt: ${project_dir}"
    echo -e "  - ACCESS_TOKEN đã được cấu hình (lưu trong file .env)."
    echo -e "  - Kiểm tra logs: ${YELLOW}cd ${project_dir} && docker compose logs -f${NC}"
    echo -e "  - Trạng thái container hiện tại:"
    sleep 2
    docker compose ps
    echo ""
    echo -e "  Lệnh quản lý:"
    echo -e "  - Khởi động: ${YELLOW}cd ${project_dir} && docker compose up -d${NC}"
    echo -e "  - Dừng:      ${YELLOW}cd ${project_dir} && docker compose down${NC}"
    echo -e "  - Khởi động lại: ${YELLOW}cd ${project_dir} && docker compose restart${NC}"
    echo -e "=================================================="
  else
    echo -e "${RED}Lỗi: Không thể khởi chạy container. Vui lòng kiểm tra log bằng lệnh:${NC}"
    echo -e "${YELLOW}cd ${project_dir} && docker compose logs${NC}"
    exit 1
  fi
}

# --- Chương trình chính ---

echo "=================================================="
echo "     Chào mừng đến với Script Cài đặt Titan PCDN     "
echo "=================================================="

# 1. Kiểm tra quyền root
check_root

# 2. Lấy ACCESS_TOKEN
USER_ACCESS_TOKEN=""
if [ -z "$1" ]; then
  read -p "Vui lòng nhập ACCESS_TOKEN của bạn: " USER_ACCESS_TOKEN
else
  USER_ACCESS_TOKEN=$1
fi

if [ -z "$USER_ACCESS_TOKEN" ]; then
  echo -e "${RED}Lỗi: ACCESS_TOKEN không được để trống.${NC}"
  exit 1
fi
echo -e "${GREEN}* Đã nhận ACCESS_TOKEN.${NC}"

# 3. Cài đặt Docker (nếu cần)
install_docker

# 4. Thiết lập và chạy PCDN
setup_pcdn "$USER_ACCESS_TOKEN"

exit 0
