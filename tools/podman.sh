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

# Bước 1: Cập nhật hệ thống
echo "Cập nhật hệ thống..."
apt update && apt upgrade -y

# Bước 2: Cài đặt Podman và các công cụ bổ sung
echo "Cài đặt Podman, podman-compose, buildah, podman-docker..."
apt install podman podman-compose buildah podman-docker cgroup-tools -y

# Bước 3: Cấu hình user namespaces cho rootless
echo "Cấu hình user namespaces..."
sysctl -w user.max_user_namespaces=28633
echo "user.max_user_namespaces=28633" >> /etc/sysctl.conf

# Bước 4: Tăng giới hạn tài nguyên
echo "Tăng giới hạn tài nguyên..."
echo "* soft nofile 65535" >> /etc/security/limits.conf
echo "* hard nofile 65535" >> /etc/security/limits.conf

# Bước 5: Cấu hình registry (Docker Hub, quay.io)
echo "Cấu hình container registries..."
cat <<EOF > /etc/containers/registries.conf
unqualified-search-registries = ["docker.io", "quay.io"]
EOF

# Bước 6: Kiểm tra cài đặt Podman
echo "Kiểm tra phiên bản Podman..."
podman --version

# Bước 7: Chạy container thử nghiệm
echo "Chạy container thử nghiệm hello-world..."
podman run --rm docker.io/library/hello-world

# Bước 8: Thông báo hoàn tất
if [ $? -eq 0 ]; then
    echo "Cài đặt Podman hoàn tất! Bạn có thể bắt đầu sử dụng Podman."
    echo "Dùng lệnh 'podman' hoặc 'docker' để quản lý container."
else
    echo "Có lỗi xảy ra khi chạy container thử nghiệm. Vui lòng kiểm tra kết nối mạng hoặc cấu hình."
fi

exit 0
