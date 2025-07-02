#!/bin/bash

# Kiểm tra quyền root
[[ $EUID -ne 0 ]] && { echo "Cần quyền root (sudo)."; exit 1; }

# Hàm hiển thị hướng dẫn
usage() { echo "Cách dùng: $0 [-r]"; echo "  -r: Gỡ bỏ swap và khôi phục trạng thái ban đầu"; exit 1; }

# Xử lý tùy chọn
while getopts "r" opt; do
    case $opt in
        r) RESTORE=1 ;;
        *) usage ;;
    esac
done

# Chế độ gỡ bỏ swap và khôi phục
if [[ $RESTORE -eq 1 ]]; then
    echo "Gỡ bỏ swap và khôi phục trạng thái..."
    # Tắt swap nếu đang hoạt động
    if swapon --show | grep -q '/swapfile'; then
        swapoff /swapfile && echo "Đã tắt swap." || { echo "Tắt swap thất bại."; exit 1; }
    else
        echo "Không có swap đang hoạt động."
    fi
    # Xóa file swap
    [[ -f /swapfile ]] && { rm /swapfile && echo "Đã xóa file swap."; } || echo "Không tìm thấy file swap."
    # Khôi phục fstab
    [[ -f /etc/fstab.bak ]] && { mv /etc/fstab.bak /etc/fstab && echo "Đã khôi phục /etc/fstab."; } || echo "Không tìm thấy bản sao lưu /etc/fstab.bak."
    # Kiểm tra trạng thái
    echo "Trạng thái swap hiện tại:"
    swapon --show
    free -h
    echo "Hoàn tất gỡ bỏ và khôi phục!"
    exit 0
fi

# Chế độ tạo swap
RAM_SIZE=$(free -m | awk '/^Mem:/{print $2}')
DISK_FREE=$(df -m / | awk 'NR==2 {print $4}')  # Dung lượng trống (MB)

# Kiểm tra dung lượng ổ cứng
if [[ $DISK_FREE -lt $RAM_SIZE ]]; then
    echo "Lỗi: Dung lượng trống ($DISK_FREE MB) nhỏ hơn RAM ($RAM_SIZE MB). Không thể tạo swap."
    exit 1
elif [[ $DISK_FREE -lt $((RAM_SIZE * 2)) ]]; then
    SWAP_SIZE=$RAM_SIZE
    echo "Cảnh báo: Dung lượng trống ($DISK_FREE MB) không đủ cho swap 2x RAM. Tạo swap $SWAP_SIZE MB."
else
    SWAP_SIZE=$((RAM_SIZE * 2))
    echo "Tạo swap $SWAP_SIZE MB (2x RAM)."
fi

SWAP_SIZE_GB=$(bc <<< "scale=2; $SWAP_SIZE / 1024")
echo "RAM: ${RAM_SIZE}MB, Swap: ${SWAP_SIZE}MB (~${SWAP_SIZE_GB}GB)"

# Tắt và xóa swap cũ
swapoff -a && echo "Đã tắt swap."
[[ -f /swapfile ]] && { rm /swapfile && echo "Đã xóa swap cũ."; }

# Tạo swap mới
echo "Tạo swap ${SWAP_SIZE}MB..."
fallocate -l "${SWAP_SIZE}M" /swapfile || { echo "Tạo swap thất bại."; exit 1; }
chmod 600 /swapfile
mkswap /swapfile >/dev/null || { echo "Định dạng swap thất bại."; exit 1; }
swapon /swapfile || { echo "Kích hoạt swap thất bại."; exit 1; }

# Cập nhật fstab
[[ -f /etc/fstab.bak ]] || cp /etc/fstab /etc/fstab.bak
grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab

# Kiểm tra
echo "Trạng thái swap:"
swapon --show
free -h
echo "Swap ${SWAP_SIZE}MB đã được tạo và kích hoạt."
