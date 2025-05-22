#!/bin/bash

# Script để giới hạn CPU (% sức mạnh, số core) và RAM cho một tiến trình/lệnh
# Mặc định: 75% CPU, 75% RAM, tất cả core
# Tự động cài đặt cgroup-tools nếu chưa có

# Hàm hiển thị hướng dẫn sử dụng
usage() {
    echo "Cách dùng: $0 [tùy chọn] -- lệnh"
    echo "Tùy chọn:"
    echo "  -c PERCENT   Giới hạn % CPU (1-100, mặc định: 75)"
    echo "  -r PERCENT   Giới hạn % RAM (1-100, mặc định: 75)"
    echo "  -n CORES     Giới hạn số core (ví dụ: 0,1 hoặc 0-2, mặc định: tất cả core)"
    echo "Ví dụ: $0 -c 50 -r 20 -n 0,1 -- firefox"
    echo "       Giới hạn Firefox dùng 50% CPU, 20% RAM, trên core 0 và 1"
    echo "       $0 -- firefox (dùng mặc định: 75% CPU, 75% RAM, tất cả core)"
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
        # Cập nhật danh sách gói
        if ! apt-get update; then
            echo "Lỗi: Không thể chạy 'apt update'. Kiểm tra kết nối internet hoặc quyền root."
            exit 1
        fi
        # Cài đặt cgroup-tools
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
CORE_LIST=$(seq -s, 0 $(( $(nproc) - 1 )))  # Tất cả core (0,1,2,...,n-1)

# Xử lý tham số dòng lệnh
while getopts ":c:r:n:" opt; do
    case $opt in
        c) CPU_PERCENT="$OPTARG" ;;
        r) RAM_PERCENT="$OPTARG" ;;
        n) CORE_LIST="$OPTARG" ;;
        \?) echo "Tùy chọn không hợp lệ: -$OPTARG"; usage ;;
    esac
done

# Lấy lệnh sau dấu --
shift $((OPTIND-1))
COMMAND="$@"

# Kiểm tra lệnh
if [ -z "$COMMAND" ]; then
    echo "Vui lòng cung cấp lệnh để chạy!"
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
    # Tính toán quota (75% = 750000/1000000)
    QUOTA=$((CPU_PERCENT * 10000))
    echo "$QUOTA" > "$CGROUP_PATH/cpu/$CGROUP_NAME/cpu.cfs_quota_us"
    echo "1000000" > "$CGROUP_PATH/cpu/$CGROUP_NAME/cpu.cfs_period_us"
    echo "Đã giới hạn CPU: $CPU_PERCENT%"
fi

# Giới hạn số core
if [ ! -z "$CORE_LIST" ]; then
    echo "$CORE_LIST" > "$CGROUP_PATH/cpuset/$CGROUP_NAME/cpuset.cpus"
    # Đảm bảo cpuset.mems được thiết lập (thường là 0)
    echo "0" > "$CGROUP_PATH/cpuset/$CGROUP_NAME/cpuset.mems"
    echo "Đã giới hạn core: $CORE_LIST"
fi

# Giới hạn RAM (% RAM)
if [ ! -z "$RAM_PERCENT" ]; then
    if ! [[ "$RAM_PERCENT" =~ ^[0-9]+$ ]] || [ "$RAM_PERCENT" -lt 1 ] || [ "$RAM_PERCENT" -gt 100 ]; then
        echo "Lỗi: % RAM phải là số từ 1 đến 100"
        exit 1
    fi
    # Lấy tổng RAM (bytes)
    TOTAL_RAM=$(free --bytes | awk '/Mem:/ {print $2}')
    # Tính RAM giới hạn
    RAM_LIMIT=$((TOTAL_RAM * RAM_PERCENT / 100))
    echo "$RAM_LIMIT" > "$CGROUP_PATH/memory/$CGROUP_NAME/memory.limit_in_bytes"
    # Giới hạn swap (nếu có)
    echo "$RAM_LIMIT" > "$CGROUP_PATH/memory/$CGROUP_NAME/memory.memsw.limit_in_bytes" 2>/dev/null
    echo "Đã giới hạn RAM: $RAM_PERCENT% ($RAM_LIMIT bytes)"
fi

# Chạy lệnh trong cgroup
echo "Chạy lệnh: $COMMAND"
cgexec -g cpu,cpuset,memory:/$CGROUP_NAME $COMMAND
