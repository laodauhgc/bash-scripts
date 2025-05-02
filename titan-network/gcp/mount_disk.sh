#!/bin/bash

# Định nghĩa biến mặc định
DISK="/dev/sdb"
MOUNT_POINT="/mnt"
FILESYSTEM="ext4"

# Hàm hiển thị cách sử dụng
usage() {
  echo "Cách sử dụng: $0 [-p <mount_point>]"
  echo "  -p <mount_point>: Đường dẫn để gắn ổ đĩa (mặc định: /mnt)"
  exit 1
}

# Xử lý tham số dòng lệnh
while getopts "p:" opt; do
  case $opt in
    p)
      MOUNT_POINT="$OPTARG"
      ;;
    \?)
      echo "Tham số không hợp lệ."
      usage
      ;;
  esac
done

# Kiểm tra xem script có chạy với quyền root không
if [ "$EUID" -ne 0 ]; then
  echo "Vui lòng chạy script với quyền root (dùng sudo)."
  exit 1
fi

# Kiểm tra xem ổ đĩa có tồn tại không
if [ ! -b "$DISK" ]; then
  echo "Ổ đĩa $DISK không tồn tại. Vui lòng kiểm tra lại tên thiết bị (dùng lsblk)."
  exit 1
fi

# Kiểm tra xem ổ đĩa đã được định dạng chưa
if ! blkid "$DISK" > /dev/null 2>&1; then
  echo "Ổ đĩa $DISK chưa được định dạng. Đang định dạng với $FILESYSTEM..."
  mkfs.$FILESYSTEM -F "$DISK"
  if [ $? -eq 0 ]; then
    echo "Định dạng ổ đĩa thành công."
  else
    echo "Lỗi khi định dạng ổ đĩa."
    exit 1
  fi
else
  echo "Ổ đĩa $DISK đã được định dạng."
fi

# Tạo thư mục gắn nếu chưa tồn tại
if [ ! -d "$MOUNT_POINT" ]; then
  echo "Tạo thư mục $MOUNT_POINT..."
  mkdir -p "$MOUNT_POINT"
fi

# Gắn ổ đĩa vào thư mục
echo "Gắn ổ đĩa $DISK vào $MOUNT_POINT..."
mount "$DISK" "$MOUNT_POINT"
if [ $? -eq 0 ]; then
  echo "Gắn ổ đĩa thành công."
else
  echo "Lỗi khi gắn ổ đĩa."
  exit 1
fi

# Lấy UUID của ổ đĩa
UUID=$(blkid -s UUID -o value "$DISK")
if [ -z "$UUID" ]; then
  echo "Không thể lấy UUID của ổ đĩa."
  exit 1
fi

# Thêm vào /etc/fstab để tự động gắn khi khởi động
if ! grep -qs "$MOUNT_POINT" /etc/fstab; then
  echo "Thêm $MOUNT_POINT vào /etc/fstab để tự động gắn..."
  echo "UUID=$UUID $MOUNT_POINT $FILESYSTEM defaults 0 2" >> /etc/fstab
  if [ $? -eq 0 ]; then
    echo "Đã thêm vào /etc/fstab thành công."
  else
    echo "Lỗi khi thêm vào /etc/fstab."
    exit 1
  fi
else
  echo "$MOUNT_POINT đã tồn tại trong /etc/fstab."
fi

# Kiểm tra lại xem ổ đĩa đã được gắn chưa
if mountpoint -q "$MOUNT_POINT"; then
  echo "Ổ đĩa đã được gắn thành công tại $MOUNT_POINT."
  df -h "$MOUNT_POINT"
else
  echo "Lỗi: Ổ đĩa chưa được gắn tại $MOUNT_POINT."
  exit 1
fi

echo "Hoàn tất."
