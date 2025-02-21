#!/bin/bash

# ==================================================================
# Hàm hỗ trợ
# ==================================================================

# Hàm in thông báo và thoát nếu có lỗi
error_exit() {
  echo "Lỗi: $1" >&2
  exit 1
}

# Hàm kiểm tra lệnh có tồn tại không
command_exists() {
  command -v "$1" &> /dev/null
}

# Hàm lấy giá trị từ mảng ngôn ngữ
get_text() {
  local key="$1"
  eval "echo \${${LANGUAGE_ARRAY}[$key]}"
}

# ==================================================================
# Xử lý tham số dòng lệnh
# ==================================================================

echo "Tham số dòng lệnh: $@" # Ghi nhật ký tất cả các tham số

if [[ "$1" == "--ver" ]]; then
  LANGUAGE="$2"
  echo "Ngôn ngữ được chọn (từ tham số): $LANGUAGE" # Ghi nhật ký ngôn ngữ
  shift
  shift
else
  LANGUAGE="en"
  echo "Ngôn ngữ mặc định: $LANGUAGE" # Ghi nhật ký ngôn ngữ
fi

# Giá trị mặc định nếu LANGUAGE không hợp lệ
LANGUAGE=${LANGUAGE:-"en"}

echo "Ngôn ngữ cuối cùng: $LANGUAGE" # Ghi nhật ký ngôn ngữ

# ==================================================================
# Định nghĩa ngôn ngữ (nhúng trực tiếp vào script)
# ==================================================================

declare -A TEXTS_EN=(
  ["INSTALL_SPEEDTEST_HEADER"]="================= Checking and installing speedtest-cli =================="
  ["INSTALLING_SPEEDTEST"]="speedtest-cli is not installed. Installing..."
  ["INSTALL_SPEEDTEST_PIP_FAILED"]="Installing speedtest-cli with pip3 failed."
  ["INSTALL_PIP_FAILED"]="Installing pip3 failed. Please install pip3 manually and try again."
  ["INSTALL_SPEEDTEST_AFTER_PIP_FAILED"]="Installing speedtest-cli with pip3 after installing pip3 failed."

  ["SYSTEM_HEADER"]="System Information"
  ["HOSTNAME"]="Hostname"
  ["CURRENT_TIME"]="Current Time"
  ["KERNEL"]="Kernel"
  ["UPTIME"]="Uptime"

  ["OS_HEADER"]="Operating System"
  ["OS"]="Operating System"
  ["OS_UNKNOWN"]="Could not determine operating system name."

  ["CPU_HEADER"]="CPU Information"
  ["CPU_MODEL"]="Model"
  ["CPU_CORES"]="Number of Cores"

  ["RAM_HEADER"]="RAM Information"
  ["RAM_TOTAL"]="Total RAM"
  ["RAM_FREE"]="Free RAM"

  ["DISK_HEADER"]="Disk Information"

  ["NETWORK_HEADER"]="Network Information"
  ["CHECKING_SPEED"]="Checking network speed (using speedtest-cli)..."
  ["SPEEDTEST_FAILED"]="Network speed test failed. Please check connection or speedtest-cli installation."

  ["IP_NAT_HEADER"]="IP Address and NAT Information"
  ["IPV4_ADDRESS"]="IPv4 Address"
  ["IPV4_NOT_FOUND"]="No IPv4 address found."
  ["IPV6_ADDRESS"]="IPv6 Address"
  ["IPV6_NOT_FOUND"]="No IPv6 address found."
  ["NAT_TYPE"]="NAT Type"

  ["NESTED_VIRT_HEADER"]="Nested Virtualization Check"
  ["VIRT_SUPPORTED"]="CPU supports virtualization (VT-x or AMD-V)."
  ["VIRT_NOT_SUPPORTED"]="CPU does NOT support virtualization. Nested virtualization is not possible."
  ["KVM_LOADED"]="KVM modules are loaded."
  ["KVM_NOT_LOADED"]="KVM modules are NOT loaded."
  ["NESTED_ENABLED"]="Nested virtualization is enabled."
  ["NESTED_DISABLED"]="Nested virtualization is disabled."
  ["NESTED_FILE_NOT_FOUND"]="Could not find nested virtualization parameter file. KVM may not be installed properly."
  ["CHECK_COMPLETE"]="Checks completed."
)

declare -A TEXTS_VI=(
  ["INSTALL_SPEEDTEST_HEADER"]="================= Kiểm tra và cài đặt speedtest-cli =================="
  ["INSTALLING_SPEEDTEST"]="speedtest-cli chưa được cài đặt. Đang cài đặt..."
  ["INSTALL_SPEEDTEST_PIP_FAILED"]="Cài đặt speedtest-cli bằng pip3 thất bại."
  ["INSTALL_PIP_FAILED"]="Cài đặt pip3 thất bại. Vui lòng cài đặt pip3 thủ công và thử lại."
  ["INSTALL_SPEEDTEST_AFTER_PIP_FAILED"]="Cài đặt speedtest-cli bằng pip3 sau khi cài đặt pip3 thất bại."

  ["SYSTEM_HEADER"]="Thông Tin Hệ Thống"
  ["HOSTNAME"]="Tên Máy"
  ["CURRENT_TIME"]="Thời Gian Hiện Tại"
  ["KERNEL"]="Nhân Hệ Thống"
  ["UPTIME"]="Thời Gian Hoạt Động"

  ["OS_HEADER"]="Hệ Điều Hành"
  ["OS"]="Hệ Điều Hành"
  ["OS_UNKNOWN"]="Không thể xác định tên hệ điều hành."

  ["CPU_HEADER"]="Thông Tin CPU"
  ["CPU_MODEL"]="Mẫu CPU"
  ["CPU_CORES"]="Số Lõi"

  ["RAM_HEADER"]="Thông Tin RAM"
  ["RAM_TOTAL"]="Tổng Dung Lượng RAM"
  ["RAM_FREE"]="Dung Lượng RAM Trống"

  ["DISK_HEADER"]="Thông Tin Ổ Đĩa"

  ["NETWORK_HEADER"]="Thông Tin Mạng"
  ["CHECKING_SPEED"]="Kiểm tra tốc độ mạng (sử dụng speedtest-cli)..."
  ["SPEEDTEST_FAILED"]="Kiểm tra tốc độ mạng không thành công. Vui lòng kiểm tra kết nối hoặc cài đặt speedtest-cli."

  ["IP_NAT_HEADER"]="Địa Chỉ IP và Thông Tin NAT"
  ["IPV4_ADDRESS"]="Địa Chỉ IPv4"
  ["IPV4_NOT_FOUND"]="Không tìm thấy địa chỉ IPv4."
  ["IPV6_ADDRESS"]="Địa Chỉ IPv6"
  ["IPV6_NOT_FOUND"]="Không tìm thấy địa chỉ IPv6."
  ["NAT_TYPE"]="Loại NAT"

  ["NESTED_VIRT_HEADER"]="Kiểm Tra Ảo Hóa Lồng"
  ["VIRT_SUPPORTED"]="CPU hỗ trợ ảo hóa (VT-x hoặc AMD-V)."
  ["VIRT_NOT_SUPPORTED"]="CPU KHÔNG hỗ trợ ảo hóa. Ảo hóa lồng không thể thực hiện được."
  ["KVM_LOADED"]="KVM modules đã được tải."
  ["KVM_NOT_LOADED"]="KVM modules CHƯA được tải."
  ["NESTED_ENABLED"]="Ảo hóa lồng đã được bật."
  ["NESTED_DISABLED"]="Ảo hóa lồng chưa được bật."
  ["NESTED_FILE_NOT_FOUND"]="Không tìm thấy file tham số ảo hóa lồng. KVM có thể chưa được cài đặt đúng cách."
  ["CHECK_COMPLETE"]="Kiểm tra hoàn tất."
)

declare -A TEXTS_RU=(
  ["INSTALL_SPEEDTEST_HEADER"]="================= Проверка и установка speedtest-cli =================="
  ["INSTALLING_SPEEDTEST"]="speedtest-cli не установлен. Установка..."
  ["INSTALL_SPEEDTEST_PIP_FAILED"]="Не удалось установить speedtest-cli с помощью pip3."
  ["INSTALL_PIP_FAILED"]="Не удалось установить pip3. Пожалуйста, установите pip3 вручную и повторите попытку."
  ["INSTALL_SPEEDTEST_AFTER_PIP_FAILED"]="Не удалось установить speedtest-cli с помощью pip3 после установки pip3."

  ["SYSTEM_HEADER"]="Информация о системе"
  ["HOSTNAME"]="Имя хоста"
  ["CURRENT_TIME"]="Текущее время"
  ["KERNEL"]="Ядро"
  ["UPTIME"]="Время работы"

  ["OS_HEADER"]="Операционная система"
  ["OS"]="Операционная система"
  ["OS_UNKNOWN"]="Не удалось определить имя операционной системы."

  ["CPU_HEADER"]="Информация о процессоре"
  ["CPU_MODEL"]="Модель"
  ["CPU_CORES"]="Количество ядер"

  ["RAM_HEADER"]="Информация об оперативной памяти"
  ["RAM_TOTAL"]="Всего оперативной памяти"
  ["RAM_FREE"]="Свободно оперативной памяти"

  ["DISK_HEADER"]="Информация о диске"

  ["NETWORK_HEADER"]="Информация о сети"
  ["CHECKING_SPEED"]="Проверка скорости сети (с помощью speedtest-cli)..."
  ["SPEEDTEST_FAILED"]="Не удалось проверить скорость сети. Пожалуйста, проверьте соединение или установку speedtest-cli."

  ["IP_NAT_HEADER"]="Информация об IP-адресе и NAT"
  ["IPV4_ADDRESS"]="IPv4-адрес"
  ["IPV4_NOT_FOUND"]="IPv4-адрес не найден."
  ["IPV6_ADDRESS"]="IPv6-адрес"
  ["IPV6_NOT_FOUND"]="IPv6-адрес не найден."
  ["NAT_TYPE"]="Тип NAT"

  ["NESTED_VIRT_HEADER"]="Проверка вложенной виртуализации"
  ["VIRT_SUPPORTED"]="Процессор поддерживает виртуализацию (VT-x или AMD-V)."
  ["VIRT_NOT_SUPPORTED"]="Процессор НЕ поддерживает виртуализацию. Вложенная виртуализация невозможна."
  ["KVM_LOADED"]="KVM-модули загружены."
  ["KVM_NOT_LOADED"]="KVM-модули НЕ загружены."
  ["NESTED_ENABLED"]="Вложенная виртуализация включена."
  ["NESTED_DISABLED"]="Вложенная виртуализация отключена."
  ["NESTED_FILE_NOT_FOUND"]="Не удалось найти файл параметра вложенной виртуализации. Возможно, KVM установлен неправильно."
  ["CHECK_COMPLETE"]="Проверки завершены."
)

declare -A TEXTS_ID=(
  ["INSTALL_SPEEDTEST_HEADER"]="================= Memeriksa dan memasang speedtest-cli =================="
  ["INSTALLING_SPEEDTEST"]="speedtest-cli tidak terpasang. Memasang..."
  ["INSTALL_SPEEDTEST_PIP_FAILED"]="Gagal memasang speedtest-cli dengan pip3."
  ["INSTALL_PIP_FAILED"]="Gagal memasang pip3. Silakan pasang pip3 secara manual dan coba lagi."
  ["INSTALL_SPEEDTEST_AFTER_PIP_FAILED"]="Gagal memasang speedtest-cli dengan pip3 setelah memasang pip3."

  ["SYSTEM_HEADER"]="Informasi Sistem"
  ["HOSTNAME"]="Nama Host"
  ["CURRENT_TIME"]="Waktu Saat Ini"
  ["KERNEL"]="Kernel"
  ["UPTIME"]="Waktu Aktif"

  ["OS_HEADER"]="Sistem Operasi"
  ["OS"]="Sistem Operasi"
  ["OS_UNKNOWN"]="Tidak dapat menentukan nama sistem operasi."

  ["CPU_HEADER"]="Informasi CPU"
  ["CPU_MODEL"]="Model"
  ["CPU_CORES"]="Jumlah Inti"

  ["RAM_HEADER"]="Informasi RAM"
  ["RAM_TOTAL"]="Total RAM"
  ["RAM_FREE"]="RAM Bebas"

  ["DISK_HEADER"]="Informasi Disk"

  ["NETWORK_HEADER"]="Informasi Jaringan"
  ["CHECKING_SPEED"]="Memeriksa kecepatan jaringan (menggunakan speedtest-cli)..."
  ["SPEEDTEST_FAILED"]="Pengujian kecepatan jaringan gagal. Silakan periksa koneksi atau pemasangan speedtest-cli."

  ["IP_NAT_HEADER"]="Informasi Alamat IP dan NAT"
  ["IPV4_ADDRESS"]="Alamat IPv4"
  ["IPV4_NOT_FOUND"]="Tidak ditemukan alamat IPv4."
  ["IPV6_ADDRESS"]="Alamat IPv6"
  ["IPV6_NOT_FOUND"]="Tidak ditemukan alamat IPv6."
  ["NAT_TYPE"]="Jenis NAT"

  ["NESTED_VIRT_HEADER"]="Pemeriksaan Virtualisasi Bertingkat"
  ["VIRT_SUPPORTED"]="CPU mendukung virtualisasi (VT-x atau AMD-V)."
  ["VIRT_NOT_SUPPORTED"]="CPU TIDAK mendukung virtualisasi. Virtualisasi bertingkat tidak mungkin dilakukan."
  ["KVM_LOADED"]="Modul KVM dimuat."
  ["KVM_NOT_LOADED"]="Modul KVM TIDAK dimuat."
  ["NESTED_ENABLED"]="Virtualisasi bertingkat diaktifkan."
  ["NESTED_DISABLED"]="Virtualisasi bertingkat dinonaktifkan."
  ["NESTED_FILE_NOT_FOUND"]="Tidak dapat menemukan berkas parameter virtualisasi bertingkat. KVM mungkin tidak terpasang dengan benar."
  ["CHECK_COMPLETE"]="Pemeriksaan selesai."
)

declare -A TEXTS_CN=(
  ["INSTALL_SPEEDTEST_HEADER"]="================= 检查和安装 speedtest-cli =================="
  ["INSTALLING_SPEEDTEST"]="未安装 speedtest-cli。正在安装..."
  ["INSTALL_SPEEDTEST_PIP_FAILED"]="使用 pip3 安装 speedtest-cli 失败。"
  ["INSTALL_PIP_FAILED"]="安装 pip3 失败。请手动安装 pip3 并重试。"
  ["INSTALL_SPEEDTEST_AFTER_PIP_FAILED"]="安装 pip3 后使用 pip3 安装 speedtest-cli 失败。"

  ["SYSTEM_HEADER"]="系统信息"
  ["HOSTNAME"]="主机名"
  ["CURRENT_TIME"]="当前时间"
  ["KERNEL"]="内核"
  ["UPTIME"]="运行时间"

  ["OS_HEADER"]="操作系统"
  ["OS"]="操作系统"
  ["OS_UNKNOWN"]="无法确定操作系统名称。"

  ["CPU_HEADER"]="CPU 信息"
  ["CPU_MODEL"]="型号"
  ["CPU_CORES"]="核心数"

  ["RAM_HEADER"]="内存信息"
  ["RAM_TOTAL"]="总内存"
  ["RAM_FREE"]="可用内存"

  ["DISK_HEADER"]="磁盘信息"

  ["NETWORK_HEADER"]="网络信息"
  ["CHECKING_SPEED"]="正在检查网络速度（使用 speedtest-cli）..."
  ["SPEEDTEST_FAILED"]="网络速度测试失败。请检查连接或 speedtest-cli 安装。"

  ["IP_NAT_HEADER"]="IP 地址和 NAT 信息"
  ["IPV4_ADDRESS"]="IPv4 地址"
  ["IPV4_NOT_FOUND"]="未找到 IPv4 地址。"
  ["IPV6_ADDRESS"]="IPv6 地址"
  ["IPV6_NOT_FOUND"]="未找到 IPv6 地址。"
  ["NAT_TYPE"]="NAT 类型"

  ["NESTED_VIRT_HEADER"]="嵌套虚拟化检查"
  ["VIRT_SUPPORTED"]="CPU 支持虚拟化 (VT-x 或 AMD-V)。"
  ["VIRT_NOT_SUPPORTED"]="CPU 不支持虚拟化。无法进行嵌套虚拟化。"
  ["KVM_LOADED"]="已加载 KVM 模块。"
  ["KVM_NOT_LOADED"]="未加载 KVM 模块。"
  ["NESTED_ENABLED"]="已启用嵌套虚拟化。"
  ["NESTED_DISABLED"]="已禁用嵌套虚拟化。"
  ["NESTED_FILE_NOT_FOUND"]="找不到嵌套虚拟化参数文件。KVM 可能未正确安装。"
  ["CHECK_COMPLETE"]="检查完成。"
)

# ==================================================================
# Chọn ngôn ngữ
# ==================================================================

case "$LANGUAGE" in
  "vi")
    LANGUAGE_ARRAY="TEXTS_VI"
    ;;
  "ru")
    LANGUAGE_ARRAY="TEXTS_RU"
    ;;
  "cn")
    LANGUAGE_ARRAY="TEXTS_CN"
    ;;
  "id")
    LANGUAGE_ARRAY="TEXTS_ID"
    ;;
  *)
    LANGUAGE_ARRAY="TEXTS_EN"
    ;;
esac

echo "Mảng ngôn ngữ được chọn: $LANGUAGE_ARRAY" # Ghi nhật ký mảng ngôn ngữ

# ==================================================================
# Kiểm tra sự tồn tại của lệnh
# ==================================================================

command_exists speedtest-cli || echo "speedtest-cli không được cài đặt"
command_exists pip3 || echo "pip3 không được cài đặt"
command_exists curl || echo "curl không được cài đặt"
command_exists ip || echo "ip không được cài đặt"
command_exists grep || echo "grep không được cài đặt"
command_exists awk || echo "awk không được cài đặt"
command_exists sed || echo "sed không được cài đặt"
command_exists df || echo "df không được cài đặt"
command_exists lsblk || echo "lsblk không được cài đặt"
command_exists mount || echo "mount không được cài đặt"
command_exists iptables || echo "iptables không được cài đặt"
command_exists nft || echo "nft không được cài đặt"

# ==================================================================
# Cài đặt speedtest-cli (nếu chưa có)
# ==================================================================

if ! command_exists speedtest-cli; then
  echo "================= $(get_text INSTALL_SPEEDTEST_HEADER) =================="
  echo "$(get_text INSTALLING_SPEEDTEST)"

  # Cố gắng cài đặt bằng pip3
  if command_exists pip3; then
    sudo pip3 install speedtest-cli || error_exit "$(get_text INSTALL_SPEEDTEST_PIP_FAILED)"
  else
    echo "pip3 không được tìm thấy. Cố gắng cài đặt pip3..."
    # Cố gắng cài đặt pip3 (ví dụ cho Debian/Ubuntu)
    sudo apt-get update && sudo apt-get install -y python3-pip || error_exit "$(get_text INSTALL_PIP_FAILED)"
    sudo pip3 install speedtest-cli || error_exit "$(get_text INSTALL_SPEEDTEST_AFTER_PIP_FAILED)"
  fi
  echo ""
fi

echo "Đã hoàn thành phần cài đặt speedtest-cli" # Ghi nhật ký

# ==================================================================
# Cấu hình hệ thống
# ==================================================================

echo "================= $(get_text SYSTEM_HEADER) =================="
echo "$(get_text HOSTNAME): $(hostname)"
echo "$(get_text CURRENT_TIME): $(date)"
echo "$(get_text KERNEL): $(uname -r)"
echo "$(get_text UPTIME): $(uptime -p)"
echo ""

# Hệ điều hành
echo "================= $(get_text OS_HEADER) =================="
os_name=$(lsb_release -d | awk -F: '{print $2}' | sed 's/^ *//;s/ *$//')
if [ -z "$os_name" ]; then
  os_name=$(cat /etc/os-release | grep PRETTY_NAME | cut -d '=' -f2 | tr -d '"')
fi

if [ -z "$os_name" ]; then
  echo "$(get_text OS_UNKNOWN)"
else
  echo "$(get_text OS): $os_name"
fi
echo ""

# Cấu hình CPU
echo "================= $(get_text CPU_HEADER) =================="
echo "$(get_text CPU_MODEL): $(grep "model name" /proc/cpuinfo | head -n 1 | awk -F: '{print $2}' | sed 's/^ *//;s/ *$//')"
echo "$(get_text CPU_CORES): $(nproc)"
echo ""

# Cấu hình bộ nhớ
echo "================= $(get_text RAM_HEADER) =================="
total_mem_kb=$(grep "MemTotal" /proc/meminfo | awk -F: '{print $2}' | sed 's/ kB//;s/^ *//')
total_mem_gb=$(echo "scale=2; $total_mem_kb / 1024 / 1024" | bc)
echo "$(get_text RAM_TOTAL): ${total_mem_gb} GB"

# Lấy dung lượng RAM trống (thử nhiều cách)
free_mem_gb=$(free -g | awk 'NR==2 {print $4}')  # Thử lấy từ free -g (GB) trước

if [[ "$free_mem_gb" == "" || "$free_mem_gb" == "0" ]]; then  # Nếu không thành công, thử free -m (MB)
  free_mem_mb=$(free -m | awk 'NR==2 {print $7}') # Lấy "available"
  free_mem_gb=$(echo "scale=2; $free_mem_mb / 1024" | bc)
fi

echo "$(get_text RAM_FREE): ${free_mem_gb} GB"
echo ""

# Cấu hình ổ đĩa
echo "================= $(get_text DISK_HEADER) =================="
df -h / | awk 'NR==2{print "Tổng: "$2", Đã dùng: "$3", Còn trống: "$4}'
echo ""

# ==================================================================
# Tốc độ mạng (sử dụng speedtest-cli)
# ==================================================================

echo "================= $(get_text NETWORK_HEADER) =================="
echo "$(get_text CHECKING_SPEED)"
speedtest-cli --simple 2>&1 > /dev/null  # Chuyển hướng stderr và stdout

if [ $? -ne 0 ]; then
  echo "$(get_text SPEEDTEST_FAILED)"
else
  # Lấy kết quả từ dòng đầu tiên của speedtest-cli --simple
  speedtest_results=$(speedtest-cli --simple)
  echo "$speedtest_results"
fi

echo ""

# ==================================================================
# Kiểm tra NAT và hiển thị địa chỉ IP
# ==================================================================

echo "================= $(get_text IP_NAT_HEADER) =================="

# Lấy địa chỉ IPv4 (luôn sử dụng API làm phương án cuối cùng và lấy một địa chỉ duy nhất)
ipv4=$(curl -s https://api.ipify.org | head -n 1)

if [ -n "$ipv4" ] && [[ "$ipv4" != "127.0.0.1" ]]; then
  echo "$(get_text IPV4_ADDRESS): $ipv4"
else
  echo "$(get_text IPV4_NOT_FOUND)"
  ipv4="None"
fi

# Lấy địa chỉ IPv6 (nếu có)
ipv6=$(ip -6 addr | grep global | awk '{print $2}' | cut -d'/' -f1 | head -n 1) # Chỉ lấy dòng đầu tiên
if [ -n "$ipv6" ]; then
  echo "$(get_text IPV6_ADDRESS): $ipv6"
else
  echo "$(get_text IPV6_NOT_FOUND)"
  ipv6="None"
fi

# Kiểm tra NAT bằng iptables/nftables
check_nat() {
  local config_output
  if command_exists nft; then
    NAT_CONFIG_CMD="nft list ruleset"
    NAT_TYPE_CHECK="nft"
  else
    NAT_CONFIG_CMD="iptables -t nat -L -v"
    NAT_TYPE_CHECK="iptables"
  fi
  config_output=$(eval "$NAT_CONFIG_CMD")

  # Check if the nat table is present at all (no NAT at all)
  if ! echo "$config_output" | grep -q "table ip nat"; then
      echo "No NAT"
      return
  fi

  # Check for NAT type 1 (Masquerade) - SNAT for a whole network on one interface on POSTROUTING chain
  if echo "$config_output" | grep -q "chain postrouting" &&  echo "$config_output" | grep -q 'masquerade'; then
      echo "NAT1"
      return
  fi

  # Check for NAT type 2 (SNAT with specific IP) on POSTROUTING chain
  if echo "$config_output" | grep -q "chain postrouting" && echo "$config_output" | grep -q 'snat to'; then
      echo "NAT2"
      return
   fi

  # Check for NAT type 3 (DNAT) on PREROUTING chain
  if echo "$config_output" | grep -q "chain prerouting" && echo "$config_output" | grep -q 'dnat to'; then
       echo "NAT3"
       return
  fi

  # If none of the above rules matched - still output "No NAT" because no common NAT rule found.
  echo "No NAT"
}

nat_status=$(check_nat)
echo "$(get_text NAT_TYPE): $nat_status"

# ==================================================================
# Kiểm tra ảo hóa lồng
# ==================================================================

echo "================= $(get_text NESTED_VIRT_HEADER) =================="

# Kiểm tra hỗ trợ CPU (Intel hoặc AMD)
if grep -E '(vmx|svm)' /proc/cpuinfo > /dev/null; then
  CPU_SUPPORT="true"
  echo "$(get_text VIRT_SUPPORTED)"

  # Kiểm tra KVM modules
  if lsmod | grep kvm > /dev/null; then
    KVM_INSTALLED="true"
    echo "$(get_text KVM_LOADED)"

    # Kiểm tra nested virtualization
    if [[ -f /sys/module/kvm_intel/parameters/nested ]]; then
      NESTED_FILE="/sys/module/kvm_intel/parameters/nested"
      KVM_MODULE="kvm_intel"
    elif [[ -f /sys/module/kvm_amd/parameters/nested" ]]; then
      NESTED_FILE="/sys/module/kvm_amd/parameters/nested"
      KVM_MODULE="kvm_amd"
    fi

    if [[ -n "$NESTED_FILE" ]]; then
      NESTED_ENABLED=$(cat "$NESTED_FILE")
      if [[ "$NESTED_ENABLED" == "Y" ]]; then
        echo "$(get_text NESTED_ENABLED)"
      else
        echo "$(get_text NESTED_DISABLED)"
      fi
    else
      echo "$(get_text NESTED_FILE_NOT_FOUND)"
    fi

  else
    echo "$(get_text KVM_NOT_LOADED)"
  fi
else
  CPU_SUPPORT="false"
  echo "$(get_text VIRT_NOT_SUPPORTED)"
fi

echo "$(get_text CHECK_COMPLETE)"
