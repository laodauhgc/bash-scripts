#!/bin/bash

# Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then
    echo "Script cần chạy với quyền root. Vui lòng dùng sudo."
    exit 1
fi

# Kiểm tra tham số: nếu là "reset", xóa cgroup
if [ "$1" = "reset" ]; then
    CGROUP_PATH="/sys/fs/cgroup/nockchain_limited"
    if [ -d "$CGROUP_PATH" ]; then
        echo "Xóa cgroup nockchain_limited để khôi phục hiệu suất CPU 100%..."
        # Di chuyển tất cả tiến trình ra khỏi cgroup
        while read -r PID; do
            [ -n "$PID" ] && echo "$PID" > /sys/fs/cgroup/cgroup.procs 2>/dev/null
        done < "$CGROUP_PATH/cgroup.procs"
        # Xóa cgroup
        rmdir "$CGROUP_PATH" 2>/dev/null || {
            echo "Lỗi khi xóa cgroup. Kiểm tra quyền hoặc trạng thái cgroup."
            exit 1
        }
        echo "Đã xóa cgroup. Hiệu suất CPU đã được khôi phục."
    else
        echo "Không tìm thấy cgroup nockchain_limited. Không cần reset."
    fi
    exit 0
fi

# Kiểm tra cgroup v2
if [ "$(stat -fc %T /sys/fs/cgroup)" != "cgroup2fs" ]; then
    echo "Lỗi: Script chỉ hỗ trợ cgroup v2. Hệ thống của bạn dùng cgroup v1."
    exit 1
fi

# Tên cgroup
CGROUP_PATH="/sys/fs/cgroup/nockchain_limited"

# Từ khóa để lọc tiến trình
KEYWORD="nockchain|run_nockchain_miner.sh"

# Xóa cgroup cũ nếu tồn tại
if [ -d "$CGROUP_PATH" ]; then
    echo "Xóa cgroup cũ nockchain_limited..."
    while read -r PID; do
        [ -n "$PID" ] && echo "$PID" > /sys/fs/cgroup/cgroup.procs 2>/dev/null
    done < "$CGROUP_PATH/cgroup.procs"
    rmdir "$CGROUP_PATH" 2>/dev/null
fi

# Tạo cgroup
echo "Tạo cgroup nockchain_limited..."
mkdir "$CGROUP_PATH" || {
    echo "Lỗi: Không thể tạo cgroup."
    exit 1
}

# Kích hoạt controller CPU
echo "+cpu" > "$CGROUP_PATH/cgroup.subtree_control" 2>/dev/null || {
    echo "Lỗi: Không thể kích hoạt controller CPU."
    rmdir "$CGROUP_PATH"
    exit 1
}

# Đặt giới hạn CPU: 75% của một lõi (75000/100000 microseconds)
echo "Đặt giới hạn 75% CPU cho cgroup nockchain_limited..."
echo "75000 100000" > "$CGROUP_PATH/cpu.max" || {
    echo "Lỗi: Không thể đặt giới hạn CPU."
    rmdir "$CGROUP_PATH"
    exit 1
}

# Tìm và thêm các tiến trình hiện tại vào cgroup
PIDS=$(pgrep -f "$KEYWORD")
if [ -z "$PIDS" ]; then
    echo "Không tìm thấy tiến trình nào có từ khóa '$KEYWORD'."
else
    for PID in $PIDS; do
        if [ -d "/proc/$PID" ]; then
            echo "Thêm PID $PID vào cgroup nockchain_limited với giới hạn 75% CPU"
            echo "$PID" > "$CGROUP_PATH/cgroup.procs" || {
                echo "Lỗi: Không thể thêm PID $PID vào cgroup."
            }
        fi
    done
    echo "Đã áp dụng giới hạn 75% CPU cho các tiến trình khớp với '$KEYWORD'."
fi

echo "Hoàn tất. Để khôi phục hiệu suất CPU 100%, chạy: sudo $0 reset"
