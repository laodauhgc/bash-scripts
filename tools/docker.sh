#!/bin/bash
set -euo pipefail

# Màu sắc cho đầu ra
GREEN='\e[32m'
RED='\e[31m'
YELLOW='\e[33m'
RESET='\e[0m'

# Hàm ghi log (có màu)
log() {
    local msg="$1"
    local color="${2:-$GREEN}"
    echo -e "${color}${msg}${RESET}"
    echo "$msg" >> /tmp/docker_install.log  # Lưu log vào file
}

# Kiểm tra quyền root
if [[ $EUID -ne 0 ]]; then
  log "Cần quyền root để chạy script này." "$RED"
  exit 1
fi

# Xác định hệ điều hành
if [[ -f /etc/os-release ]]; then
  source /etc/os-release
  OS=$ID
  VERSION_ID=$VERSION_ID
else
  log "Không thể xác định hệ điều hành." "$RED"
  exit 1
fi

log "Hệ điều hành: ${OS} ${VERSION_ID}"

# Hàm cài đặt Docker cho Ubuntu/Debian
install_docker_ubuntu() {
  log "Cài đặt Docker trên Ubuntu/Debian..."

  # Lấy codename
  CODENAME=$(lsb_release -cs)
  log "Codename: ${CODENAME}"

  # Gỡ cài đặt các gói cũ (nếu có)
  log "Gỡ các gói Docker cũ (nếu có)..."
  for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    sudo apt-get remove -y $pkg
  done

  # Cài đặt các gói cần thiết
  log "Cài đặt các gói cần thiết..."
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl

  # Tạo thư mục keyrings (nếu chưa tồn tại)
  sudo install -m 0755 -d /etc/apt/keyrings

  # Thêm Docker GPG key
  log "Thêm Docker GPG key..."
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc

  # Thêm kho lưu trữ Docker
  log "Thêm kho lưu trữ Docker..."
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  # Cập nhật và cài đặt Docker Engine
  log "Cài đặt Docker Engine..."
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  # Khởi động và kích hoạt Docker
  log "Khởi động và kích hoạt Docker..."
  sudo systemctl start docker
  sudo systemctl enable docker

  log "Docker đã được cài đặt thành công."
}

# Hàm cài đặt Docker Compose (plugin)
install_docker_compose() {
  log "Đang cài đặt Docker Compose..."

  # Kiểm tra xem Docker Compose đã được cài đặt hay chưa (không cần thiết vì nó được cài đặt như một phần của docker-compose-plugin)
  log "Docker Compose đã được cài đặt như một phần của Docker Engine."
}

# Xử lý theo hệ điều hành
case "$OS" in
  ubuntu)
    install_docker_ubuntu
    ;;
  *)
    log "Hệ điều hành không được hỗ trợ." "$RED"
    exit 1
    ;;
esac

install_docker_compose

# Thêm người dùng vào nhóm docker
sudo usermod -aG docker $USER
log "Đã thêm người dùng $USER vào nhóm docker."

log "Cài đặt hoàn tất. Vui lòng đăng xuất và đăng nhập lại để các thay đổi về nhóm có hiệu lực."
log "Bạn có thể kiểm tra bằng lệnh: docker run hello-world"

log "Kiểm tra cài đặt bằng lệnh: sudo docker run hello-world"
# Update: 30.03.2025
