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
        if [ -s "$CGROUP_PATH/cgroup.procs" ]; then
            while read -r PID; do
                if [ -n "$PID" ]; then
                    # Kiểm tra xem PID còn tồn tại không
                    if [ -d "/proc/$PID" ]; then
                        echo "$PID" > /sys/fs/cgroup/cgroup.procs 2>/dev/null || {
                            echo "Cảnh báo: Không thể di chuyển PID $PID ra khỏi cgroup."
                        }
                    fi
                fi
            done < "$CGROUP_PATH/cgroup.procs"
        fi
        # Đợi một chút để đảm bảo tiến trình được di chuyển
        sleep 1
        # Kiểm tra lại xem cgroup có trống không
        if [ -s "$CGROUP_PATH/cgroup.procs" ]; then
            echo "Lỗi: Vẫn còn tiến trình trong cgroup. Thử buộc di chuyển..."
            # Buộc di chuyển bằng cách ghi 0
            echo 0 > "$CGROUP_PATH/cgroup.procs" 2>/dev/null
        fi
        # Xóa cgroup
        rmdir "$CGROUP_PATH" 2>/dev/null || {
            echo "Lỗi: Không thể xóa cgroup. Kiểm tra trạng thái bằng: cat $CGROUP_PATH/cgroup.procs"
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

# Số lõi CPU
NUM_CORES=$(nproc)
if [ -z "$NUM_CORES" ]; then
    echo "Lỗi: Không thể xác định số lõi CPU."
    exit 1
fi

# Tính giới hạn CPU: 75% của tổng CPU (75% x số lõi x 100000 microseconds)
CPU_QUOTA=$((NUM_CORES * 100000 * 75 / 100))
CPU_PERIOD=100000
echo "Hệ thống có $NUM_CORES lõi. Giới hạn tổng CPU ở mức 75% (${CPU_QUOTA}/${CPU_PERIOD} microseconds)."

# Xóa cgroup cũ nếu tồn tại
if [ -d "$CGROUP_PATH" ]; then
    echo "Xóa cgroup cũ nockchain_limited..."
    if [ -s "$CGROUP_PATH/cgroup.procs" ]; then
        while read -r PID; do
            if [ -n "$PID" ] && [ -d "/proc/$PID" ]; then
                echo "$PID" > /sys/fs/cgroup/cgroup.procs 2>/dev/null
            fi
        done < "$CGROUP_PATH/cgroup.procs"
        sleep 1
        if [ -s "$CGROUP_PATH/cgroup.procs" ]; then
            echo 0 > "$CGROUP_PATH/cgroup.procs" 2>/dev/null
        fi
    fi
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

# Đặt giới hạn CPU: 75% của tổng CPU
echo "Đặt giới hạn 75% tổng CPU (${CPU_QUOTA}/${CPU_PERIOD}) cho cgroup nockchain_limited..."
echo "$CPU_QUOTA $CPU_PERIOD" > "$CGROUP_PATH/cpu.max" || {
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
            echo "Thêm PID $PID vào cgroup nockchain_limited với giới hạn 75% tổng CPU"
            echo "$PID" > "$CGROUP_PATH/cgroup.procs" || {
                echo "Lỗi: Không thể thêm PID $PID vào cgroup."
            }
        fi
    done
    echo "Đã áp dụng giới hạn 75% tổng CPU cho các tiến trình khớp với '$KEYWORD'."
fi

echo "Hoàn tất. Để khôi phục hiệu suất CPU 100%, chạy: sudo $0 reset"
