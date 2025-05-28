#!/bin/bash

# Kiểm tra xem cpulimit đã được cài đặt chưa
if ! command -v cpulimit &> /dev/null; then
    echo "cpulimit chưa được cài đặt. Đang cài đặt..."
    sudo apt-get update
    sudo apt-get install -y cpulimit
fi

# Kiểm tra tham số đầu vào
if [ -z "$1" ]; then
    echo "Vui lòng cung cấp giới hạn CPU (phần trăm, ví dụ: 50 cho 50%)"
    exit 1
fi

CPU_LIMIT=$1

# Kiểm tra giá trị hợp lệ
if ! [[ "$CPU_LIMIT" =~ ^[0-9]+$ ]] || [ "$CPU_LIMIT" -lt 1 ] || [ "$CPU_LIMIT" -gt 100 ]; then
    echo "Giới hạn CPU phải là một số từ 1 đến 100"
    exit 1
fi

# Lấy danh sách các process ID (PID) đang chạy
PIDS=$(ps -e -o pid --no-headers)

# Áp dụng giới hạn CPU cho từng process
for PID in $PIDS; do
    # Kiểm tra xem process có tồn tại không
    if [ -d "/proc/$PID" ]; then
        echo "Áp dụng giới hạn $CPU_LIMIT% CPU cho PID: $PID"
        cpulimit -p "$PID" -l "$CPU_LIMIT" &
    fi
done

echo "Đã áp dụng giới hạn $CPU_LIMIT% CPU cho tất cả các process hiện tại."

# Theo dõi các process mới (tùy chọn)
echo "Theo dõi các process mới..."
while true; do
    sleep 5
    NEW_PIDS=$(ps -e -o pid --no-headers)
    for NEW_PID in $NEW_PIDS; do
        if [ -d "/proc/$NEW_PID" ] && ! pgrep -f "cpulimit -p $NEW_PID" > /dev/null; then
            echo "Áp dụng giới hạn $CPU_LIMIT% CPU cho PID mới: $NEW_PID"
            cpulimit -p "$NEW_PID" -l "$CPU_LIMIT" &
        fi
    done
done
