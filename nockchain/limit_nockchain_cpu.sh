#!/bin/bash

# Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then
    echo "Script cần chạy với quyền root. Vui lòng dùng sudo."
    exit 1
fi

# Kiểm tra tham số: nếu là "reset", xóa cgroup
if [ "$1" = "reset" ]; then
    CGROUP_NAME="nockchain_limited"
    if [ -d "/sys/fs/cgroup/$CGROUP_NAME" ]; then
        echo "Xóa cgroup $CGROUP_NAME để khôi phục hiệu suất CPU 100%..."
        cgdelete -g cpu:/$CGROUP_NAME
        echo "Đã xóa cgroup. Hiệu suất CPU đã được khôi phục."
    else
        echo "Không tìm thấy cgroup $CGROUP_NAME. Không cần reset."
    fi
    exit 0
fi

# Cài đặt cgroup-tools nếu chưa có
if ! command -v cgcreate &> /dev/null; then
    echo "cgroup-tools chưa được cài đặt. Đang cài đặt..."
    apt-get update
    apt-get install -y cgroup-tools
fi

# Tên cgroup
CGROUP_NAME="nockchain_limited"

# Từ khóa để lọc tiến trình
KEYWORD="nockchain|run_nockchain_miner.sh"

# Kiểm tra xem cgroup đã tồn tại chưa, nếu có thì xóa
if [ -d "/sys/fs/cgroup/$CGROUP_NAME" ]; then
    cgdelete -g cpu:/$CGROUP_NAME
fi

# Tạo cgroup
echo "Tạo cgroup $CGROUP_NAME..."
cgcreate -g cpu:/$CGROUP_NAME || {
    echo "Lỗi: Không thể tạo cgroup. Kiểm tra phân hệ CPU hoặc phiên bản cgroup."
    exit 1
}

# Đặt giới hạn CPU: 75% của một lõi (75000/100000 microseconds)
echo "Đặt giới hạn 75% CPU cho cgroup $CGROUP_NAME..."
cgset -r cpu.cfs_quota_us=75000 -r cpu.cfs_period_us=100000 /$CGROUP_NAME || {
    echo "Lỗi: Không thể đặt giới hạn CPU. Kiểm tra cgroup v1/v2 hoặc quyền truy cập."
    exit 1
}

# Tìm và thêm các tiến trình hiện tại vào cgroup
PIDS=$(pgrep -f "$KEYWORD")
if [ -z "$PIDS" ]; then
    echo "Không tìm thấy tiến trình nào có từ khóa '$KEYWORD'."
else
    for PID in $PIDS; do
        if [ -d "/proc/$PID" ]; then
            echo "Thêm PID $PID vào cgroup $CGROUP_NAME với giới hạn 75% CPU"
            cgclassify -g cpu:/$CGROUP_NAME $PID || {
                echo "Lỗi: Không thể thêm PID $PID vào cgroup."
            }
        fi
    done
    echo "Đã áp dụng giới hạn 75% CPU cho các tiến trình khớp với '$KEYWORD'."
fi

echo "Hoàn tất. Để khôi phục hiệu suất CPU 100%, chạy: sudo $0 reset"
