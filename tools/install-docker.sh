#!/bin/bash

# Cập nhật và nâng cấp hệ thống | Ubuntu 22.04
echo "Cập nhật và nâng cấp hệ thống..."
sudo apt update -y && sudo apt upgrade -y

# Cài đặt các gói cần thiết để sử dụng kho lưu trữ qua HTTPS
echo "Cài đặt các gói cần thiết..."
sudo apt install apt-transport-https ca-certificates curl gnupg lsb-release -y

# Thêm khóa GPG chính thức của Docker
echo "Thêm khóa GPG của Docker..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

# Thiết lập kho lưu trữ Docker ổn định
echo "Thiết lập kho lưu trữ Docker..."
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Cập nhật lại danh sách gói để bao gồm kho lưu trữ Docker
echo "Cập nhật danh sách gói..."
sudo apt update -y

# Cài đặt Docker Engine
echo "Cài đặt Docker Engine..."
sudo apt install docker-ce docker-ce-cli containerd.io docker-compose-plugin -y

# Thêm người dùng hiện tại vào nhóm docker (để chạy Docker mà không cần sudo)
echo "Thêm người dùng vào nhóm docker..."
sudo usermod -aG docker $USER

# Khởi động lại Docker service
echo "Khởi động lại Docker service..."
sudo systemctl restart docker

# Kiểm tra cài đặt Docker
echo "Kiểm tra cài đặt Docker..."
docker --version
sudo docker run hello-world

# Cài đặt Docker Compose (nếu chưa cài bằng apt) - Cách 1: Sử dụng apt (đã cài ở trên)
#echo "Cài đặt Docker Compose bằng apt..."
#sudo apt install docker-compose-plugin -y

# Cài đặt Docker Compose (nếu chưa cài bằng apt) - Cách 2: Sử dụng curl (nếu cần phiên bản mới hơn)
#LATEST_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep tag_name | cut -d '"' -f 4)
#echo "Phiên bản Docker Compose mới nhất: $LATEST_VERSION"
#sudo curl -L "https://github.com/docker/compose/releases/download/${LATEST_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
#sudo chmod +x /usr/local/bin/docker-compose

# Tạo symbolic link cho docker-compose (nếu cài bằng curl)
#sudo ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose

# Kiểm tra cài đặt Docker Compose
echo "Kiểm tra cài đặt Docker Compose..."
docker compose version

echo "Hoàn tất cài đặt Docker và Docker Compose!"
