#!/bin/bash

# Cập nhật hệ thống
echo "Cập nhật hệ thống..."
sudo apt update
sudo apt upgrade -y

# Cài đặt Vnstat
echo "Cài đặt Vnstat..."
sudo apt install vnstat -y

# Tự động tìm giao diện mạng
echo "Tìm kiếm giao diện mạng..."
interface=$(ip route show default | awk '{print $5}')

# Kiểm tra xem có tìm thấy giao diện nào không
if [ -z "$interface" ]; then
  echo "Lỗi: Không tìm thấy giao diện mạng. Vui lòng kiểm tra kết nối mạng của bạn."
  exit 1
fi

echo "Đã tìm thấy giao diện mạng: $interface"

# Khởi tạo cơ sở dữ liệu Vnstat
echo "Khởi tạo cơ sở dữ liệu Vnstat cho giao diện $interface..."
sudo vnstat -i "$interface"

# Khởi động và kích hoạt Vnstat
echo "Khởi động và kích hoạt Vnstat..."
sudo systemctl start vnstat
sudo systemctl enable vnstat

# Kiểm tra Vnstat
echo "Kiểm tra Vnstat..."
vnstat

echo "Cài đặt và cấu hình Vnstat hoàn tất!"
echo "Bạn có thể sử dụng các lệnh sau để xem thống kê:"
echo "  vnstat -d  (Thống kê theo ngày)"
echo "  vnstat -h  (Thống kê theo giờ)"
echo "  vnstat -m  (Thống kê hàng tháng)"
echo "  vnstat -w  (Thống kê hàng tuần)"
