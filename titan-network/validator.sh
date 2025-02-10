#!/bin/bash

# Các icon Unicode
INFO="ℹ️"        # Thông tin
SUCCESS="✅"     # Thành công
WARNING="⚠️"     # Cảnh báo
ERROR="❌"       # Lỗi

# Hàm kiểm tra quyền root
check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${ERROR} Script này cần được chạy với quyền root."
    exit 1
  fi
}

# Hàm kiểm tra cấu hình hệ thống
check_system_requirements() {
  # Kiểm tra CPU
  CPU_CORES=$(lscpu | grep "^CPU(s):" | awk '{print $2}')
  if [[ -z "$CPU_CORES" ]]; then
    echo -e "${ERROR} Không thể xác định số lượng CPU cores."
    exit 1
  fi
  if [[ "$CPU_CORES" -lt 8 ]]; then
    echo -e "${ERROR} Cấu hình không đạt yêu cầu: Cần tối thiểu 8 vCPU. Hệ thống có $CPU_CORES vCPU."
    exit 1
  fi

  # Kiểm tra RAM (điều chỉnh ngưỡng xuống 7.2 GB)
  TOTAL_RAM_KB=$(free | grep Mem | awk '{print $2}')
  TOTAL_RAM_GB=$(echo "scale=1; $TOTAL_RAM_KB / 1024 / 1024" | bc) # Convert KB to GB with 1 decimal place
  if [[ $(echo "$TOTAL_RAM_GB < 7.2" | bc -l) -eq 1 ]]; then
    echo -e "${ERROR} Cấu hình không đạt yêu cầu: Cần tối thiểu 8 GB RAM. Hệ thống có $TOTAL_RAM_GB GB RAM."
    exit 1
  fi

  #Kiểm tra disk space (điều chỉnh ngưỡng xuống 180GB)
  DISK_SPACE_GB=$(df -h / | awk 'NR==2 {print $2}' | sed 's/G//')

  if [[ -z "$DISK_SPACE_GB" ]]; then
      echo -e "${ERROR} Không thể xác định dung lượng ổ đĩa."
      exit 1
  fi

  #Remove the decimal part if any:
  DISK_SPACE_GB=${DISK_SPACE_GB%.*}

  if [[ "$DISK_SPACE_GB" -lt 180 ]]; then
      echo -e "${ERROR} Cấu hình không đạt yêu cầu: Cần tối thiểu 200GB dung lượng ổ đĩa. Hệ thống có $DISK_SPACE_GB GB."
      exit 1
  fi

  # Kiểm tra phiên bản Ubuntu
  UBUNTU_VERSION=$(lsb_release -rs)
  if [[ "$UBUNTU_VERSION" != "22.04" ]]; then
    echo -e "${ERROR} Cấu hình không đạt yêu cầu: Cần hệ điều hành Ubuntu 22.04. Hệ thống đang chạy $UBUNTU_VERSION."
    exit 1
  fi

  echo -e "${SUCCESS} Đã kiểm tra: Hệ thống đáp ứng cấu hình tối thiểu."
}

# Hàm hiển thị hướng dẫn sử dụng
usage() {
  echo "Sử dụng: $0 --mode=<init|recovery>"
  echo "Ví dụ:"
  echo "  $0 --mode=init"
  echo "  $0 --mode=recovery"
  exit 1
}

# Hàm xử lý mode init
handle_init() {
  echo -e "${INFO} Bạn đã chọn chế độ: init"
  # Thêm code cho chế độ init tại đây
}

# Hàm xử lý mode recovery
handle_recovery() {
  echo -e "${INFO} Bạn đã chọn chế độ: recovery"
  # Thêm code cho chế độ recovery tại đây
}

# Kiểm tra quyền root
check_root

# Kiểm tra cấu hình hệ thống
check_system_requirements

# Lấy giá trị của tham số --mode (SỬA LỖI Ở ĐÂY)
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
      echo -e "${ERROR} Lỗi tham số: $1" >&2
      usage
      exit 1
      ;;
  esac
done

# Kiểm tra xem có tham số --mode hay không
if [ -z "$MODE" ]; then
  echo -e "${ERROR} Bạn phải chỉ định --mode=<init|recovery>"
  usage
  exit 1
fi

# Xử lý theo mode
case "$MODE" in
  init)
    handle_init
    ;;
  recovery)
    handle_recovery
    ;;
  *)
    echo -e "${ERROR} Mode không hợp lệ: $MODE"
    usage
    exit 1
    ;;
esac

exit 0
