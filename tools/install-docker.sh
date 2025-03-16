#!/bin/bash

# Cập nhật và nâng cấp hệ thống
echo "Cập nhật và nâng cấp hệ thống..."
apt update -y && apt upgrade -y

# Cài đặt các gói cần thiết để sử dụng kho lưu trữ qua HTTPS
echo "Cài đặt các gói cần thiết..."
apt install apt-transport-https ca-certificates curl gnupg lsb-release -y

# Thêm khóa GPG chính thức của Docker
echo "Thêm khóa GPG của Docker..."
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

# Xác định tên bản phân phối Debian/Ubuntu và codename
export DISTRO=$(grep ^ID= /etc/os-release | cut -d'=' -f2 | tr -d '"')
export CODENAME=$(grep ^VERSION_CODENAME= /etc/os-release | cut -d'=' -f2 | tr -d '"')

# In thông tin DISTRO và CODENAME để debug
echo "Distro: $DISTRO"
echo "Codename: $CODENAME"

# Thiết lập kho lưu trữ Docker ổn định
echo "Thiết lập kho lưu trữ Docker..."
if [ "$DISTRO" = "ubuntu" ]; then
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $CODENAME stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
elif [ "$DISTRO" = "debian" ]; then
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $CODENAME stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
else
  echo "Không hỗ trợ bản phân phối này. Vui lòng điều chỉnh script."
  exit 1
fi

# Cập nhật lại danh sách gói để bao gồm kho lưu trữ Docker
echo "Cập nhật danh sách gói..."
apt update -y

# Cài đặt Docker Engine
echo "Cài đặt Docker Engine..."
apt install docker-ce docker-ce-cli containerd.io docker-compose-plugin -y

# Khởi động lại Docker service
echo "Khởi động lại Docker service..."
systemctl restart docker

# Kiểm tra cài đặt Docker
echo "Kiểm tra cài đặt Docker..."
docker --version
docker run hello-world

# Kiểm tra cài đặt Docker Compose
echo "Kiểm tra cài đặt Docker Compose..."
docker compose version

echo "Hoàn tất cài đặt Docker và Docker Compose!"
