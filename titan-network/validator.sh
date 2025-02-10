#!/bin/bash

# Các icon Unicode
INFO="ℹ️"
SUCCESS="✅"
WARNING="⚠️"
ERROR="❌"

# Các thông báo
MSG_ROOT_REQUIRED="${ERROR} Script này cần được chạy với quyền root."
MSG_CANNOT_DETERMINE="Không thể xác định"
MSG_CPU_MINIMUM="Cấu hình không đạt yêu cầu: Cần tối thiểu 8 vCPU."
MSG_CPU_OK="CPU: Đạt yêu cầu (tối thiểu 8 vCPU)"
MSG_RAM_MINIMUM="Cấu hình không đạt yêu cầu: Cần tối thiểu 16 GB RAM."
MSG_RAM_OK="RAM: Đạt yêu cầu (tối thiểu 16 GB)"
MSG_DISK_MINIMUM="Cấu hình không đạt yêu cầu: Cần tối thiểu 200GB dung lượng ổ đĩa."
MSG_DISK_OK="Ổ đĩa: Đạt yêu cầu (tối thiểu 200GB)"
MSG_UBUNTU_MINIMUM="Hệ điều hành cần phải là Ubuntu 22.04"
MSG_UBUNTU_OK="Hệ điều hành: Đạt yêu cầu - Ubuntu 22.04"
MSG_SYSTEM_OK="Đã kiểm tra: Hệ thống đáp ứng cấu hình tối thiểu."

# Các mode
MODES="init recovery monitor uninstall"

# Hàm kiểm tra quyền root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        printf "%b ${MSG_ROOT_REQUIRED}\n" "${ERROR}"
        exit 1
    fi
}

# Hàm in thông báo và dừng loading (nếu cần)
print_and_cleanup() {
    local message="$1"
    printf "%s\n" "$message"
    exit 1
}

# Hàm kiểm tra yêu cầu hệ thống
check_requirement() {
    local name="$1"           # Tên của yêu cầu (ví dụ: "CPU")
    local check_command="$2"  # Lệnh để kiểm tra yêu cầu
    local expected_value="$3" # Giá trị mong đợi
    local error_message="$4"  # Thông báo lỗi nếu không đạt yêu cầu
    local success_message="$5"  # Thông báo thành công
    local unit="$6"          # Đơn vị (ví dụ: "vCPU", "GB", " ")
    local checkType="$7"      # "numeric" or "string"

    local value=$(eval "$check_command")

    if [[ -z "$value" ]]; then
        printf "%b ${MSG_CANNOT_DETERMINE} %s.\n" "${ERROR}" "$name"
        sleep 0.5
        exit 1
    fi
	
	if [[ "$checkType" == "numeric" ]]; then
    	if [[ $(echo "$value < $expected_value" | bc -l) -eq 1 ]]; then
        	printf "%s %s - Hệ thống có %s %s.\n" "${ERROR}" "$error_message" "$value" "$unit"
        	sleep 0.5
        	exit 1
    	fi
	else
		if [[ "$value" != "$expected_value" ]]; then
        	printf "%s %s\n" "${ERROR}" "$error_message"
        	sleep 0.5
        	exit 1
    	fi
	fi

    if [[ $name != "Ubuntu Version" ]]; then
        printf "%s %s - Hệ thống có %s %s.\n"  "${SUCCESS}" "$success_message" "$value" "$unit"
        sleep 0.5
    else
        printf "%s %s\n" "${SUCCESS}" "$success_message"
        sleep 0.5
    fi


}

# Hàm kiểm tra cấu hình hệ thống
check_system_requirements() {
    # Kiểm tra các yêu cầu
    check_requirement "CPU" \
        "lscpu | grep '^CPU(s):' | awk '{print \$2}'" \
        "8" \
        "${MSG_CPU_MINIMUM}" \
        "${MSG_CPU_OK}" \
        "vCPU" \
		"numeric"

    CPU_VALUE=$(lscpu | grep "^CPU(s):" | awk '{print $2}')

    check_requirement "RAM" \
        "free | grep Mem | awk '{print \$2}' | awk '{printf \"%.1f\", \$1 / 1024 / 1024}'" \
        "15.2" \
        "${MSG_RAM_MINIMUM}" \
        "${MSG_RAM_OK}" \
        "GB" \
		"numeric"
    
    RAM_VALUE=$(free | grep Mem | awk '{print $2}' | awk '{printf "%.1f", $1 / 1024 / 1024}')

    check_requirement "Disk Space" \
        "df -h / | awk 'NR==2 {print \$2}' | sed 's/G//'" \
        "180" \
        "${MSG_DISK_MINIMUM}" \
        "${MSG_DISK_OK}" \
        "GB" \
        "numeric"

    DISK_VALUE=$(df -h / | awk 'NR==2 {print $2}' | sed 's/G//')

    check_requirement "Ubuntu Version" \
        "lsb_release -rs" \
        "22.04" \
        "${MSG_UBUNTU_MINIMUM}" \
        "${MSG_UBUNTU_OK}" \
        "" \
		"string"
	UBUNTU_VERSION=$(lsb_release -rs)

    printf "%s ${MSG_SYSTEM_OK}\n" "${SUCCESS}"
    sleep 0.5
}

# Hàm hiển thị hướng dẫn sử dụng
usage() {
    echo "Sử dụng: $0 --mode=<init|recovery|monitor|uninstall>"
    echo "Ví dụ:"
    echo "  $0 --mode=init"
    echo "  $0 --mode=recovery"
	echo "  $0 --mode=monitor"
    echo "  $0 --mode=uninstall"
    exit 1
}

# Hàm hiển thị menu
show_menu() {
    echo "Vui lòng chọn một mode:"
    echo "  1) init - BẮT ĐẦU TẠO MỚI VALIDATOR"
    echo "  2) recovery - BẮT ĐẦU KHÔI PHỤC VALIDATOR"
    echo "  3) monitor - GIÁM SÁT VALIDATOR"
    echo "  4) uninstall - GỠ CÀI ĐẶT VALIDATOR"
    read -p "Nhập số (1-4): " choice

    case "$choice" in
        1)
            MODE="init"
            ;;
        2)
            MODE="recovery"
            ;;
        3)
            MODE="monitor"
            ;;
        4)
            MODE="uninstall"
            ;;
        *)
            echo "Lựa chọn không hợp lệ."
            exit 1
            ;;
    esac
}

# Hàm xử lý mode init
handle_init() {
    printf "%s BẮT ĐẦU TẠO MỚI VALIDATOR\n"  "${INFO}"
    # Thêm code cho chế độ init tại đây
}

# Hàm xử lý mode recovery
handle_recovery() {
    printf "%s BẮT ĐẦU KHÔI PHỤC VALIDATOR\n" "${INFO}"
    # Thêm code cho chế độ recovery tại đây
}

# Hàm xử lý mode monitor
handle_monitor() {
    printf "%s GIÁM SÁT VALIDATOR\n"  "${INFO}"
    # Thêm code cho chế độ monitor tại đây
}

# Hàm xử lý mode uninstall
handle_uninstall() {
    printf "%s GỠ CÀI ĐẶT VALIDATOR\n"  "${INFO}"
    # Thêm code cho chế độ uninstall tại đây
}

# Kiểm tra quyền root
check_root

# Lấy giá trị của tham số --mode
eval set -- $(getopt --long "mode:" -o "" -n "$0" -- "$@")
while true; do
    case "$1" in
        --mode)
            MODE="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            MODE=""
            break
            ;;
    esac
done

# Kiểm tra xem có tham số --mode hay không
if [ -z "$MODE" ]; then
    show_menu
fi

#Kiểm tra xem mode nhập vào có hợp lệ không
valid=false
for m in $MODES; do
  if [[ "$MODE" == "$m" ]]; then
    valid=true
    break
  fi
done

if [[ "$valid" == "false" ]]; then
  show_menu
fi

# Kiểm tra cấu hình hệ thống (chỉ cho init và recovery)
if [[ "$MODE" == "init" ]] || [[ "$MODE" == "recovery" ]]; then
    echo "===================== KIỂM TRA CẤU HÌNH ====================="
    check_system_requirements
fi

# Thêm thông báo MODE
case "$MODE" in
    init)
        echo "===================== BẮT ĐẦU TẠO MỚI VALIDATOR ====================="
        ;;
    recovery)
        echo "===================== BẮT ĐẦU KHÔI PHỤC VALIDATOR ====================="
        ;;
	monitor)
        echo "===================== GIÁM SÁT VALIDATOR ====================="
        ;;
    uninstall)
        echo "===================== GỠ CÀI ĐẶT VALIDATOR ====================="
        ;;
esac

# Xử lý theo mode
case "$MODE" in
    init)
        handle_init
        ;;
    recovery)
        handle_recovery
        ;;
	monitor)
        handle_monitor
        ;;
    uninstall)
        handle_uninstall
        ;;
    *)
        printf "%s Mode không hợp lệ: %s\n" "${ERROR}" "$MODE"
        usage
        exit 1
        ;;
    esac

exit 0
