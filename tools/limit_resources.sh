#!/bin/bash

# Script để giới hạn CPU (% sức mạnh, số core) và RAM cho toàn hệ thống hoặc một tiến trình/lệnh
# Mặc định: 75% CPU, 75% RAM, tất cả core
# Tự động cài đặt cgroup-tools nếu chưa có

# Hàm hiển thị hướng dẫn sử dụng
usage() {
    echo "Cách dùng: $0 [tùy chọn] [-- lệnh]"
    echo "Tùy chọn:"
    echo "  -a           Giới hạn tài nguyên cho toàn hệ thống (không cần lệnh)"
    echo "  -c PERCENT   Giới hạn % CPU (1-100, mặc định: 75)"
    echo "  -r PERCENT   Giới hạn % RAM (1-100, mặc định: 75)"
    echo "  -n CORES     Giới hạn số core (ví dụ: 0,1 hoặc 0-2, mặc định: tất cả core)"
    echo "Ví dụ:"
    echo "  $0 -a                     # Giới hạn toàn hệ thống: 75% CPU, 75% RAM, tất cả core"
    echo "  $0 -a -c 50 -r 20         # Giới hạn toàn hệ thống: 50% CPU, 20% RAM"
    echo "  $0 -c 50 -r 20 -n 0,1 -- firefox  # Giới hạn Firefox: 50% CPU, 20% RAM, core 0,1"
    exit 1
}

# Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then
    echo "Vui lòng chạy script với quyền sudo!"
    exit 1
fi

# Hàm kiểm tra và cài đặt cgroup-tools
install_cgroup_tools() {
    if ! command -v cgcreate &> /dev/null; then
        echo "cgroup-tools chưa được cài đặt. Đang cài đặt..."
        if ! apt-get update; then
            echo "Lỗi: Không thể chạy 'apt update'. Kiểm tra kết nối internet hoặc quyền root."
            exit 1
        fi
        if ! apt-get install -y cgroup-tools; then
            echo "Lỗi: Không thể cài đặt cgroup-tools. Vui lòng kiểm tra và thử lại."
            exit 1
        fi
        echo "Đã cài đặt cgroup-tools thành công."
    fi
}

# Gọi hàm cài đặt cgroup-tools
install_cgroup_tools

# Giá trị mặc định
CPU_PERCENT=75
RAM_PERCENT=75
CORE_LIST=$(seq -s, 0 $(( $(nproc) - 1 )))  # Tất cả core
ALL_SYSTEM=false

# Xử lý tham số dòng lệnh
while getopts ":ac:r:n:" opt; do
    case $opt in
        a) ALL_SYSTEM=true ;;
        c) CPU_PERCENT="$OPTARG" ;;
        r) RAM_PERCENT="$OPTARG" ;;
        n) CORE_LIST="$OPTARG" ;;
        \?) echo "Tùy chọn không hợp lệ: -$OPTARG"; usage ;;
    esac
done

# Lấy lệnh sau dấu --
shift $((OPTIND-1))
COMMAND="$@"

# Kiểm tra lệnh nếu không dùng -a
if [ "$ALL_SYSTEM" = false ] && [ -z "$COMMAND" ]; then
    echo "Vui lòng cung cấp lệnh để chạy hoặc dùng tùy chọn -a để giới hạn toàn hệ thống!"
    usage
fi

# Tạo tên cgroup duy nhất
CGROUP_NAME="limited_$$"
CGROUP_PATH="/sys/fs/cgroup"

# Tạo cgroup cho CPU, cpuset và memory
cgcreate -g cpu,cpuset,memory:/$CGROUP_NAME

# Hàm dọn dẹp cgroup khi thoát
cleanup() {
    cgdelete -g cpu,cpuset,memory:/$CGROUP_NAME 2>/dev/null
    echo "Đã dọn dẹp cgroup."
    exit
}
trap cleanup SIGINT SIGTERM EXIT

# Giới hạn CPU (% sức mạnh)
if [ ! -z "$CPU_PERCENT" ]; then
    if ! [[ "$CPU_PERCENT" =~ ^[0-9]+$ ]] || [ "$CPU_PERCENT" -lt 1 ] || [ "$CPU_PERCENT" -gt 100 ]; then
        echo "Lỗi: % CPU phải là số từ 1 đến 100"
        exit 1
    fi
    QUOTA=$((CPU_PERCENT * 10000))
    echo "$QUOTA" > "$CGROUP_PATH/cpu/$CGROUP_NAME/cpu.cfs_quota_us"
    echo "1000000" > "$CGROUP_PATH/cpu/$CGROUP_NAME/cpu.cfs_period_us"
    echo "Đã giới hạn CPU: $CPU_PERCENT%"
fi

# Giới hạn số core
if [ ! -z "$CORE_LIST" ]; then
    echo "$CORE_LIST" > "$CGROUP_PATH/cpuset/$CGROUP_NAME/cpuset.cpus"
    echo "0" > "$CGROUP_PATH/cpuset/$CGROUP_NAME/cpuset.mems"
    echo "Đã giới hạn core: $CORE_LIST"
fi

# Giới hạn RAM (% RAM)
if [ ! -z "$RAM_PERCENT" ]; then
    if ! [[ "$RAM_PERCENT" =~ ^[0-9]+$ ]] || [ "$RAM_PERCENT" -lt 1 ] || [ "$RAM_PERCENT" -gt 100 ]; then
        echo "Lỗi: % RAM phải là số từ 1 đến 100"
        exit 1
    fi
    TOTAL_RAM=$(free --bytes | awk '/Mem:/ {print $2}')
    RAM_LIMIT=$((TOTAL_RAM * RAM_PERCENT / 100))
    echo "$RAM_LIMIT" > "$CGROUP_PATH/memory/$CGROUP_NAME/memory.limit_in_bytes"
    echo "$RAM_LIMIT" > "$CGROUP_PATH/memory/$CGROUP_NAME/memory.memsw.limit_in_bytes" 2>/dev/null
    echo "Đã giới hạn RAM: $RAM_PERCENT% ($RAM_LIMIT bytes)"
fi

# Áp dụng giới hạn
if [ "$ALL_SYSTEM" = true ]; then
    echo "Áp dụng giới hạn tài nguyên cho toàn hệ thống..."
    # Thêm tất cả tiến trình người dùng vào cgroup (trừ tiến trình hệ thống)
    for pid in $(ps -e -o pid --no-headers); do
        # Bỏ qua tiến trình hệ thống (PID thấp hoặc kernel threads)
        if [ $pid -gt 1000 ]; then
            echo $pid > "$CGROUP_PATH/cpu/$CGROUP_NAME/tasks" 2>/dev/null
            echo $pid > "$CGROUP_PATH/cpuset/$CGROUP_NAME/tasks" 2>/dev/null
            echo $pid > "$CGROUP_PATH/memory/$CGROUP_NAME/tasks" 2>/dev/null
        fi
    done
    echo "Giới hạn đã được áp dụng cho toàn hệ thống. Nhấn Ctrl+C để thoát."
    # Giữ script chạy để duy trì cgroup
    sleep infinity
else
    echo "Chạy lệnh: $COMMAND"
    cgexec -g cpu,cpuset,memory:/$CGROUP_NAME $COMMAND
fi
