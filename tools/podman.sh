#!/bin/bash

# Script tự động cài đặt Podman trên Ubuntu 22.04
# Chạy với quyền root hoặc sử dụng sudo

# Kiểm tra hệ điều hành
if [[ ! -f /etc/os-release ]] || ! grep -q "Ubuntu 22.04" /etc/os-release; then
    echo "Script này chỉ hỗ trợ Ubuntu 22.04. Thoát."
    exit 1
fi

# Kiểm tra quyền root
if [[ $EUID -ne 0 ]]; then
    echo "Vui lòng chạy script này với quyền root (sudo)."
    exit 1
fi

echo "Bắt đầu cài đặt Podman và các công cụ liên quan..."

# Bước 1: Cập nhật hệ thống và thêm kho lưu trữ Podman
echo "Cập nhật hệ thống và thêm kho lưu trữ Podman..."
apt update && apt upgrade -y
apt install -y software-properties-common
add-apt-repository -y ppa:projectatomic/ppa
apt update

# Bước 2: Cài đặt Podman và các công cụ bổ sung
echo "Cài đặt Podman, buildah, podman-docker..."
apt install -y podman buildah podman-docker cgroup-tools

# Bước 3: Cài đặt podman-compose qua pip
echo "Cài đặt podman-compose qua pip..."
apt install -y python3-pip
pip3 install podman-compose

# Bước 4: Cấu hình user namespaces cho rootless
echo "Cấu hình user namespaces..."
sysctl -w user.max_user_namespaces=28633
echo "user.max_user_namespaces=28633" >> /etc/sysctl.conf

# Bước 5: Tăng giới hạn tài nguyên
echo "Tăng giới hạn tài nguyên..."
echo "* soft nofile 65535" >> /etc/security/limits.conf
echo "* hard nofile 65535" >> /etc/security/limits.conf

# Bước 6: Tạo thư mục và cấu hình registry
echo "Cấu hình container registries..."
mkdir -p /etc/containers
cat <<EOF > /etc/containers/registries.conf
unqualified-search-registries = ["docker.io", "quay.io"]
EOF

# Bước 7: Kiểm tra cài đặt Podman
echo "Kiểm tra phiên bản Podman..."
if ! command -v podman &> /dev/null; then
    echo "Lỗi: Podman không được cài đặt. Vui lòng kiểm tra kho lưu trữ hoặc cài đặt thủ công."
    exit 1
fi
podman --version

# Bước 8: Chạy container thử nghiệm
echo "Chạy container thử nghiệm hello-world..."
podman run --rm docker.io/library/hello-world

# Bước 9: Thông báo hoàn tất
if [ $? -eq 0 ]; then
    echo "Cài đặt Podman hoàn tất! Bạn có thể bắt đầu sử dụng Podman."
    echo "Dùng lệnh 'podman' hoặc 'docker' để quản lý container."
    echo "Podman-compose đã được cài đặt qua pip, sử dụng bằng 'podman-compose'."
else
    echo "Có lỗi xảy ra khi chạy container thử nghiệm. Vui lòng kiểm tra kết nối mạng hoặc cấu hình."
    exit 1
fi

exit 0
