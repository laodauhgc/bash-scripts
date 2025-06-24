#!/bin/bash

# Kiểm tra quyền root
if [[ $EUID -ne 0 ]]; then
   echo "Script này cần chạy với quyền root (sudo)."
   exit 1
fi

# Hàm hiển thị hướng dẫn
usage() {
    echo "Cách dùng: $0 [-r]"
    echo "  -r: Khôi phục trạng thái ban đầu (xóa swap và khôi phục /etc/fstab)"
    exit 1
}

# Xử lý tùy chọn dòng lệnh
while getopts "r" opt; do
    case $opt in
        r)
            RESTORE=1
            ;;
        *)
            usage
            ;;
    esac
done

# Chế độ khôi phục
if [[ $RESTORE -eq 1 ]]; then
    echo "Khôi phục trạng thái ban đầu..."

    # Tắt swap hiện tại
    if swapon --show | grep -q '/swapfile'; then
        echo "Tắt swap..."
        swapoff /swapfile
    fi

    # Xóa file swap
    if [ -f /swapfile ]; then
        echo "Xóa file swap..."
        rm /swapfile
    else
        echo "Không tìm thấy file swap."
    fi

    # Khôi phục /etc/fstab từ bản sao lưu
    if [ -f /etc/fstab.bak ]; then
        echo "Khôi phục /etc/fstab từ bản sao lưu..."
        mv /etc/fstab.bak /etc/fstab
    else
        echo "Không tìm thấy bản sao lưu /etc/fstab.bak."
    fi

    # Kiểm tra swap sau khi khôi phục
    echo "Kiểm tra swap hiện tại..."
    swapon --show
    free -h

    echo "Hoàn tất khôi phục!"
    exit 0
fi

# Chế độ tạo swap (mặc định)
# Lấy dung lượng RAM vật lý (tính bằng MB)
RAM_SIZE=$(free -m | awk '/^Mem:/{print $2}')
SWAP_SIZE=$((RAM_SIZE * 2))

# Chuyển đổi kích thước swap sang GB để hiển thị
SWAP_SIZE_GB=$(echo "scale=2; $SWAP_SIZE / 1024" | bc)

echo "RAM vật lý: $RAM_SIZE MB"
echo "Tạo swap với kích thước: $SWAP_SIZE MB (~$SWAP_SIZE_GB GB)"

# Tắt swap hiện tại (nếu có)
echo "Tắt swap hiện tại..."
swapoff -a

# Xóa file swap cũ (nếu có)
if [ -f /swapfile ]; then
    echo "Xóa file swap cũ..."
    rm /swapfile
fi

# Tạo file swap mới
echo "Tạo file swap mới với kích thước $SWAP_SIZE MB..."
fallocate -l "${SWAP_SIZE}M" /swapfile

# Phân quyền cho file swap
chmod 600 /swapfile

# Định dạng file swap
echo "Định dạng file swap..."
mkswap /swapfile

# Kích hoạt swap
echo "Kích hoạt swap..."
swapon /swapfile

# Sao lưu file /etc/fstab
cp /etc/fstab /etc/fstab.bak

# Thêm swap vào /etc/fstab để tự động kích hoạt khi khởi động
grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab

# Kiểm tra swap đã được kích hoạt
echo "Kiểm tra swap..."
swapon --show
free -h

echo "Hoàn tất! Swap với kích thước $SWAP_SIZE MB đã được tạo và kích hoạt."
