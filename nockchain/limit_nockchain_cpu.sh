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
        # Xóa tiến trình khỏi cgroup trước
        echo 0 > /sys/fs/cgroup/$CGROUP_NAME/cgroup.procs 2>/dev/null
        rmdir /sys/fs/cgroup/$CGROUP_NAME 2>/dev/null || {
            echo "Lỗi khi xóa cgroup. Kiểm tra quyền hoặc trạng thái cgroup."
            exit 1
        }
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
    apt-get install -y cgroup-tools || {
        echo "Lỗi: Không thể cài đặt cgroup-tools."
        exit 1
    }
fi

# Tên cgroup
CGROUP_NAME="nockchain_limited"

# Từ khóa để lọc tiến trình
KEYWORD="nockchain|run_nockchain_miner.sh"

# Kiểm tra phiên bản cgroup
CGROUP_VERSION=$(stat -fc %T /sys/fs/cgroup)
if [ "$CGROUP_VERSION" = "cgroup2fs" ]; then
    echo "Hệ thống sử dụng cgroup v2."
    CGROUP_V2=1
else
    echo "Hệ thống sử dụng cgroup v1."
    CGROUP_V2=0
fi

# Xóa cgroup cũ nếu tồn tại
if [ -d "/sys/fs/cgroup/$CGROUP_NAME" ]; then
    if [ "$CGROUP_V2" -eq 1 ]; then
        echo 0 > /sys/fs/cgroup/$CGROUP_NAME/cgroup.procs 2>/dev/null
        rmdir /sys/fs/cgroup/$CGROUP_NAME 2>/dev/null
    else
        cgdelete -g cpu:/$CGROUP_NAME 2>/dev/null
    fi
fi

# Tạo cgroup
echo "Tạo cgroup $CGROUP_NAME..."
if [ "$CGROUP_V2" -eq 1 ]; then
    mkdir /sys/fs/cgroup/$CGROUP_NAME || {
        echo "Lỗi: Không thể tạo cgroup."
        exit 1
    }
    # Kích hoạt controller CPU
    echo "+cpu" > /sys/fs/cgroup/$CGROUP_NAME/cgroup.controllers 2>/dev/null
else
    cgcreate -g cpu:/$CGROUP_NAME || {
        echo "Lỗi: Không thể tạo cgroup. Kiểm tra phân hệ CPU."
        exit 1
    }
fi

# Đặt giới hạn CPU: 75% của một lõi
echo "Đặt giới hạn 75% CPU cho cgroup $CGROUP_NAME..."
if [ "$CGROUP_V2" -eq 1 ]; then
    # cgroup v2: sử dụng cpu.max (75000/100000 microseconds)
    echo "75000 100000" > /sys/fs/cgroup/$CGROUP_NAME/cpu.max || {
        echo "Lỗi: Không thể đặt giới hạn CPU. Kiểm tra quyền hoặc controller CPU."
        exit 1
    }
else
    # cgroup v1: sử dụng cpu.cfs_quota_us và cpu.cfs_period_us
    cgset -r cpu.cfs_quota_us=75000 -r cpu.cfs_period_us=100000 /$CGROUP_NAME || {
        echo "Lỗi: Không thể đặt giới hạn CPU. Kiểm tra quyền hoặc phân hệ CPU."
        exit 1
    }
fi

# Tìm và thêm các tiến trình hiện tại vào cgroup
PIDS=$(pgrep -f "$KEYWORD")
if [ -z "$PIDS" ]; then
    echo "Không tìm thấy tiến trình nào có từ khóa '$KEYWORD'."
else
    for PID in $PIDS; do
        if [ -d "/proc/$PID" ]; then
            echo "Thêm PID $PID vào cgroup $CGROUP_NAME với giới hạn 75% CPU"
            if [ "$CGROUP_V2" -eq 1 ]; then
                echo $PID > /sys/fs/cgroup/$CGROUP_NAME/cgroup.procs || {
                    echo "Lỗi: Không thể thêm PID $PID vào cgroup."
                }
            else
                cgclassify -g cpu:/$CGROUP_NAME $PID || {
                    echo "Lỗi: Không thể thêm PID $PID vào cgroup."
                }
            fi
        fi
    done
    echo "Đã áp dụng giới hạn 75% CPU cho các tiến trình khớp với '$KEYWORD'."
fi

echo "Hoàn tất. Để khôi phục hiệu suất CPU 100%, chạy: sudo $0 reset"
