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

  # Cài đặt các gói cần thiết (cố gắng sửa lỗi phụ thuộc)
  apt update
  apt --fix-broken install -y
  apt install -y ca-certificates curl gnupg apt-transport-https

  # Thêm Docker GPG key
  curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

  # Thêm kho lưu trữ Docker
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian ${CODENAME} stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  # Cài đặt Docker Engine
  apt update
  apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

  # Khởi động và kích hoạt Docker
  systemctl start docker
  systemctl enable docker

  log "Docker đã được cài đặt thành công."
}

# Hàm cài đặt Docker Compose (plugin)
install_docker_compose() {
  log "Đang cài đặt Docker Compose..."

  # Kiểm tra xem Docker Compose đã được cài đặt hay chưa
  if ! docker compose version >/dev/null 2>&1; then
    log "Plugin Docker Compose không được cài đặt đúng cách. Vui lòng kiểm tra cài đặt Docker của bạn." "$RED"
    log "Cài đặt docker compose plugin"
    apt install -y docker-compose-plugin
  else
    log "Docker Compose đã được cài đặt."
  fi
}

# Xử lý theo hệ điều hành
case "$OS" in
  ubuntu|debian)
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
# Update: 30.03.2025
