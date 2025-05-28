#!/bin/bash

# Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then
    echo "Script cần chạy với quyền root. Vui lòng dùng sudo."
    exit 1
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

# Tạo cgroup
cgcreate -g cpu:/$CGROUP_NAME

# Đặt giới hạn CPU: 75% của một lõi (75000/100000 microseconds)
cgset -r cpu.cfs_quota_us=75000 -r cpu.cfs_period_us=100000 /$CGROUP_NAME

# Tìm và thêm các tiến trình hiện tại vào cgroup
PIDS=$(pgrep -f "$KEYWORD")
if [ -z "$PIDS" ]; then
    echo "Không tìm thấy tiến trình nào có từ khóa '$KEYWORD'."
else
    for PID in $PIDS; do
        if [ -d "/proc/$PID" ]; then
            echo "Thêm PID $PID vào cgroup $CGROUP_NAME với giới hạn 75% CPU"
            cgclassify -g cpu:/$CGROUP_NAME $PID
        fi
    done
fi

# Theo dõi các tiến trình mới
echo "Theo dõi các tiến trình mới có từ khóa '$KEYWORD'..."
while true; do
    sleep 5
    NEW_PIDS=$(pgrep -f "$KEYWORD")
    for NEW_PID in $NEW_PIDS; do
        if [ -d "/proc/$NEW_PID" ] && ! grep -q "$CGROUP_NAME" /proc/$NEW_PID/cgroup 2>/dev/null; then
            echo "Thêm PID mới $NEW_PID vào cgroup $CGROUP_NAME"
            cgclassify -g cpu:/$CGROUP_NAME $NEW_PID
        fi
    done
done
