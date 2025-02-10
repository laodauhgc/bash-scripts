#!/bin/bash

# Các icon Unicode
INFO="ℹ️"
SUCCESS="✅"
WARNING="⚠️"
ERROR="❌"

# Các thông báo
MSG_ROOT_REQUIRED="${ERROR} Script này cần được chạy với quyền root."
MSG_CANNOT_DETERMINE="Không thể xác định"
MSG_CPU_MINIMUM="Cần tối thiểu 8 vCPU."
MSG_CPU_OK="Đạt yêu cầu (tối thiểu 8 vCPU)."
MSG_RAM_MINIMUM="Cần tối thiểu 16 GB RAM."
MSG_RAM_OK="Đạt yêu cầu (tối thiểu 16 GB)."
MSG_DISK_MINIMUM="Cần tối thiểu 200GB dung lượng ổ đĩa."
MSG_DISK_OK="Đạt yêu cầu (tối thiểu 200GB)."
MSG_UBUNTU_MINIMUM="Hệ điều hành cần Ubuntu 22.04."
MSG_UBUNTU_OK="Hệ điều hành: Đạt yêu cầu."
MSG_SYSTEM_OK="Hệ thống đáp ứng cấu hình tối thiểu."

# Các mode
MODES="init recovery monitor uninstall"

# Go version
GO_VERSION="1.23.6"
GO_ARCH="linux-amd64"
GO_FILE="go${GO_VERSION}.${GO_ARCH}.tar.gz"
GO_URL="https://go.dev/dl/${GO_FILE}"

# Titan version
TITAN_VERSION="0.3.0"
TITAND_FILE="titand_${TITAN_VERSION}-1_g167b7fd6.tar.gz"
TITAND_URL="https://github.com/Titannet-dao/titan-chain/releases/download/v${TITAN_VERSION}/${TITAND_FILE}"
LIBWASMVM_FILE="libwasmvm.x86_64.so"
LIBWASMVM_URL="https://github.com/Titannet-dao/titan-chain/releases/download/v${TITAN_VERSION}/${LIBWASMVM_FILE}"

# Systemd file content
SYSTEMD_FILE_CONTENT="[Unit]
Description=Titan Daemon
After=network-online.target

[Service]
User=root
ExecStart=/usr/local/bin/titand start
Restart=always
RestartSec=3
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target"

# Hàm kiểm tra quyền root
check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "${ERROR} ${MSG_ROOT_REQUIRED}"
    exit 1
  fi
}

#Hàm in thông báo
print_msg() {
  echo "$1"
}

# Hàm kiểm tra yêu cầu hệ thống
check_system_requirements() {
  print_msg "===================== KIỂM TRA CẤU HÌNH ====================="

  # CPU
  CPU_CORES=$(lscpu | grep "^CPU(s):" | awk '{print $2}')
  if [ -z "$CPU_CORES" ] || [ "$CPU_CORES" -lt 8 ]; then
    print_msg "${ERROR} ${MSG_CPU_MINIMUM} - Không tìm thấy hoặc không đủ CPU."
    exit 1
  fi
  print_msg "${SUCCESS} CPU: ${MSG_CPU_OK} - Hệ thống có $CPU_CORES vCPU."

  # RAM
  TOTAL_RAM_KB=$(free | grep Mem | awk '{print $2}')
  TOTAL_RAM_GB=$(echo "scale=1; $TOTAL_RAM_KB / 1024 / 1024" | bc)

  if [ $(echo "$TOTAL_RAM_GB < 15.2" | bc -l) -eq 1 ]; then
    print_msg "${ERROR} ${MSG_RAM_MINIMUM} - Hệ thống có $TOTAL_RAM_GB GB."
    exit 1
  fi
  print_msg "${SUCCESS} RAM: ${MSG_RAM_OK} - Hệ thống có $TOTAL_RAM_GB GB."

  # Disk
  DISK_SPACE_GB=$(df -h / | awk 'NR==2 {print $2}' | sed 's/G//')
  if [ -z "$DISK_SPACE_GB" ]; then
    print_msg "${ERROR} ${MSG_CANNOT_DETERMINE} Ổ đĩa."
    exit 1
  fi

  DISK_SPACE_GB=$(echo $DISK_SPACE_GB | sed 's/[^0-9]//g')
  if [ "$DISK_SPACE_GB" -lt 180 ]; then
    print_msg "${ERROR} ${MSG_DISK_MINIMUM} - Hệ thống có $DISK_SPACE_GB GB."
    exit 1
  fi
  print_msg "${SUCCESS} Ổ đĩa: ${MSG_DISK_OK} - Hệ thống có $DISK_SPACE_GB GB."

  # OS
  UBUNTU_VERSION=$(lsb_release -rs)
  if [ "$UBUNTU_VERSION" != "22.04" ]; then
    print_msg "${ERROR} ${MSG_UBUNTU_MINIMUM} - Hệ thống có $UBUNTU_VERSION."
    exit 1
  fi
  print_msg "${SUCCESS} Hệ điều hành: ${MSG_UBUNTU_OK}"

  print_msg "${SUCCESS} ${MSG_SYSTEM_OK}."
}
# Hàm cài đặt các gói phụ thuộc
install_dependencies() {
    echo "${INFO} Cài đặt các gói phụ thuộc..."
    sudo apt-get update -y && sudo apt-get install -y \
        build-essential cmake git python3-pip python3-venv openjdk-11-jdk npm wget curl htop tmux screen ufw openssh-server unzip zip net-tools tree nano
    echo "${SUCCESS} Các gói phụ thuộc đã được cài đặt."
}

# Hàm cài đặt Go
install_go() {
    echo "${INFO} Cài đặt Go ${GO_VERSION}..."
    # Tải file Go
    echo "${INFO} Tải ${GO_FILE} từ ${GO_URL}..."
    wget -q "${GO_URL}" || { echo "${ERROR} Không thể tải ${GO_FILE}."; exit 1; }

    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf "${GO_FILE}"

	echo "export PATH=\$PATH:/usr/local/go/bin" >> /root/.profile
    export PATH=$PATH:/usr/local/go/bin

    rm "${GO_FILE}"

    go version
    echo "${SUCCESS} Go ${GO_VERSION} đã được cài đặt."
    echo "${INFO} Vui lòng chạy lệnh 'source /root/.profile' để cập nhật biến môi trường PATH."
}

# Hàm cài đặt titand và libwasmvm
install_titand() {
    echo "${INFO} Cài đặt titand ${TITAN_VERSION} và libwasmvm..."

    # Tải titand
    echo "${INFO} Tải ${TITAND_FILE} từ ${TITAND_URL}..."
    wget -q -P /root/ "${TITAND_URL}" || { echo "${ERROR} Không thể tải ${TITAND_FILE}."; exit 1; }

    # Giải nén titand
    echo "${INFO} Giải nén ${TITAND_FILE}..."
    sudo tar -zxvf /root/${TITAND_FILE} --strip-components=1 -C /usr/local/bin
    rm /root/${TITAND_FILE}

    # Tải libwasmvm
    echo "${INFO} Tải ${LIBWASMVM_FILE} từ ${LIBWASMVM_URL}..."
    wget -q -P /root/ "${LIBWASMVM_URL}" || { echo "${ERROR} Không thể tải ${LIBWASMVM_FILE}."; exit 1; }

    # Di chuyển libwasmvm
    echo "${INFO} Di chuyển ${LIBWASMVM_FILE}..."
    sudo mv /root/${LIBWASMVM_FILE} /usr/local/lib/

    # Cấu hình thư viện
    sudo ldconfig

    echo "${SUCCESS} titand ${TITAN_VERSION} và libwasmvm đã được cài đặt."
}

# Hàm tạo và kích hoạt systemd service
create_systemd_service() {
    echo "${INFO} Tạo và kích hoạt systemd service..."
    # Tạo file service
    sudo tee /etc/systemd/system/titan.service > /dev/null <<EOF
${SYSTEMD_FILE_CONTENT}
EOF

    # Kích hoạt service
    sudo systemctl enable titan.service > /dev/null

    echo "${SUCCESS} Systemd service đã được tạo và kích hoạt (nhưng chưa khởi động)."
}

# Hàm gỡ cài đặt titand
uninstall_titand() {
    echo "${INFO} Bắt đầu gỡ cài đặt TitanD..."

    # Dừng service nếu đang chạy
    if systemctl is-active --quiet titan.service; then
        echo "${INFO} Dừng service titan.service..."
        sudo systemctl stop titan.service
    fi

    # Disable service
    echo "${INFO} Vô hiệu hóa service titan.service..."
    sudo systemctl disable titan.service

    # Xóa file service
    echo "${INFO} Xóa file service /etc/systemd/system/titan.service..."
    sudo rm -f /etc/systemd/system/titan.service

    # Xóa symlinks liên quan đến service (nếu có)
    echo "${INFO} Xóa các symlink liên quan..."
    sudo rm -f /etc/systemd/system/multi-user.target.wants/titan.service

    # Xóa titand binary
    echo "${INFO} Xóa titand binary..."
    sudo rm -f /usr/local/bin/titand

    # Xóa libwasmvm
    echo "${INFO} Xóa libwasmvm..."
    sudo rm -f /usr/local/lib/libwasmvm.x86_64.so

    # Cập nhật ldconfig
    sudo ldconfig

    echo "${SUCCESS} TitanD đã được gỡ cài đặt thành công."
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
    print_msg "${INFO} BẮT ĐẦU TẠO MỚI VALIDATOR"
    # Thêm code cho chế độ init tại đây
}

# Hàm xử lý mode recovery
handle_recovery() {
    print_msg "${INFO} BẮT ĐẦU KHÔI PHỤC VALIDATOR"
    # Thêm code cho chế độ recovery tại đây
}

# Hàm xử lý mode monitor
handle_monitor() {
    print_msg "${INFO} GIÁM SÁT VALIDATOR"
    # Thêm code cho chế độ monitor tại đây
}

# Hàm xử lý mode uninstall
handle_uninstall() {
    print_msg "${INFO} GỠ CÀI ĐẶT VALIDATOR"
	uninstall_titand
    # Thêm code cho chế độ uninstall tại đây
}

# Lấy giá trị của tham số --mode
MODE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      if [ -n "$2" ] && [[ "$2" == init || "$2" == recovery || "$2" == monitor || "$2" == uninstall ]]; then
        MODE="$2"
        shift 2
      else
        echo "Tham số --mode không hợp lệ."
        exit 1
      fi
      ;;
    *)
      echo "Tham số không hợp lệ: $1"
      exit 1
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

# Kiểm tra quyền root
check_root

# Kiểm tra cấu hình hệ thống (chỉ cho init và recovery)
if [[ "$MODE" == "init" ]] || [[ "$MODE" == "recovery" ]]; then
    check_system_requirements

    # Cài đặt các gói phụ thuộc
    install_dependencies

    # Cài đặt Go
    install_go

    # Cài đặt titand và libwasmvm
    install_titand

	# Tạo và kích hoạt systemd service
    create_systemd_service
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
        echo "${ERROR} Mode không hợp lệ: $MODE"
        usage
        exit 0
        ;;
    esac

exit 0
