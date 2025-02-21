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

# ==================================================================
# Cài đặt speedtest-cli (nếu chưa có)
# ==================================================================

if ! command_exists speedtest-cli; then
  echo "================= Kiểm tra và cài đặt speedtest-cli =================="
  echo "speedtest-cli chưa được cài đặt. Đang cài đặt..."

  # Cố gắng cài đặt bằng pip3
  if command_exists pip3; then
    sudo pip3 install speedtest-cli || error_exit "Cài đặt speedtest-cli bằng pip3 thất bại."
  else
    echo "pip3 không được tìm thấy. Cố gắng cài đặt pip3..."
    # Cố gắng cài đặt pip3 (ví dụ cho Debian/Ubuntu)
    sudo apt-get update && sudo apt-get install -y python3-pip || error_exit "Cài đặt pip3 thất bại. Hãy cài đặt pip3 thủ công và thử lại."
    sudo pip3 install speedtest-cli || error_exit "Cài đặt speedtest-cli bằng pip3 sau khi cài đặt pip3 thất bại."
  fi
  echo ""
fi

# ==================================================================
# Cấu hình hệ thống
# ==================================================================

echo "================= Hệ Thống =================="
echo "Hostname: $(hostname)"
echo "Thời gian hiện tại: $(date)"
echo "Kernel: $(uname -r)"
echo "Uptime: $(uptime -p)"
echo ""

# Hệ điều hành
echo "================= Hệ Điều Hành =================="
os_name=$(lsb_release -d | awk -F: '{print $2}' | sed 's/^ *//;s/ *$//')
if [ -z "$os_name" ]; then
  os_name=$(cat /etc/os-release | grep PRETTY_NAME | cut -d '=' -f2 | tr -d '"')
fi

if [ -z "$os_name" ]; then
  echo "Không thể xác định tên hệ điều hành."
else
  echo "Hệ điều hành: $os_name"
fi
echo ""

# Cấu hình CPU
echo "================= CPU =================="
echo "Model: $(grep "model name" /proc/cpuinfo | head -n 1 | awk -F: '{print $2}' | sed 's/^ *//;s/ *$//')"
echo "Số nhân: $(nproc)"
echo ""

# Cấu hình bộ nhớ
echo "================= Bộ Nhớ (RAM) =================="
total_mem_kb=$(grep "MemTotal" /proc/meminfo | awk -F: '{print $2}' | sed 's/ kB//;s/^ *//')
total_mem_gb=$(echo "scale=2; $total_mem_kb / 1024 / 1024" | bc)
echo "Tổng dung lượng (RAM): ${total_mem_gb} GB"

# Lấy dung lượng RAM trống (thử nhiều cách)
free_mem_gb=$(free -g | awk 'NR==2 {print $4}')  # Thử lấy từ free -g (GB) trước

if [[ "$free_mem_gb" == "" || "$free_mem_gb" == "0" ]]; then  # Nếu không thành công, thử free -m (MB)
  free_mem_mb=$(free -m | awk 'NR==2 {print $7}') # Lấy "available"
  free_mem_gb=$(echo "scale=2; $free_mem_mb / 1024" | bc)
fi

echo "Dung lượng trống (RAM): ${free_mem_gb} GB"
echo ""

# Cấu hình ổ đĩa
echo "================= Ổ Đĩa =================="
df -h / | awk 'NR==2{print "Tổng: "$2", Đã dùng: "$3", Còn trống: "$4}'
echo ""

# ==================================================================
# Tốc độ mạng (sử dụng speedtest-cli)
# ==================================================================

echo "================= Mạng =================="
echo "Đang kiểm tra tốc độ mạng (sử dụng speedtest-cli)..."
speedtest-cli --simple 2>&1 > /dev/null  # Chuyển hướng stderr và stdout

if [ $? -ne 0 ]; then
  echo "Kiểm tra tốc độ mạng không thành công. Vui lòng kiểm tra kết nối hoặc cài đặt speedtest-cli."
else
  # Lấy kết quả từ dòng đầu tiên của speedtest-cli --simple
  speedtest_results=$(speedtest-cli --simple)
  echo "$speedtest_results"
fi

echo ""

# ==================================================================
# Kiểm tra NAT và hiển thị địa chỉ IP
# ==================================================================

echo "================= Địa chỉ IP và NAT =================="

# Lấy địa chỉ IPv4 (luôn sử dụng API làm phương án cuối cùng và lấy một địa chỉ duy nhất)
ipv4=$(curl -s https://api.ipify.org | head -n 1)

if [ -n "$ipv4" ] && [[ "$ipv4" != "127.0.0.1" ]]; then
  echo "Địa chỉ IPv4: $ipv4"
else
  echo "Không tìm thấy địa chỉ IPv4."
  ipv4="None"
fi

# Lấy địa chỉ IPv6 (nếu có)
ipv6=$(ip -6 addr | grep global | awk '{print $2}' | cut -d'/' -f1 | head -n 1) # Chỉ lấy dòng đầu tiên
if [ -n "$ipv6" ]; then
  echo "Địa chỉ IPv6: $ipv6"
else
  echo "Không tìm thấy địa chỉ IPv6."
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
echo "Loại NAT: $nat_status"

# ==================================================================
# Kiểm tra ảo hóa lồng
# ==================================================================

echo "================= Kiểm tra Ảo Hóa Lồng =================="

# Kiểm tra hỗ trợ CPU (Intel hoặc AMD)
if grep -E '(vmx|svm)' /proc/cpuinfo > /dev/null; then
  CPU_SUPPORT="true"
  echo "CPU hỗ trợ ảo hóa (VT-x hoặc AMD-V)."

  # Kiểm tra KVM modules
  if lsmod | grep kvm > /dev/null; then
    KVM_INSTALLED="true"
    echo "KVM modules đã được tải."

    # Kiểm tra nested virtualization
    if [[ -f /sys/module/kvm_intel/parameters/nested ]]; then
      NESTED_FILE="/sys/module/kvm_intel/parameters/nested"
      KVM_MODULE="kvm_intel"
    elif [[ -f /sys/module/kvm_amd/parameters/nested ]]; then
      NESTED_FILE="/sys/module/kvm_amd/parameters/nested"
      KVM_MODULE="kvm_amd"
    fi

    if [[ -n "$NESTED_FILE" ]]; then
      NESTED_ENABLED=$(cat "$NESTED_FILE")
      if [[ "$NESTED_ENABLED" == "Y" ]]; then
        echo "Ảo hóa lồng đã được bật."
      else
        echo "Ảo hóa lồng chưa được bật."
      fi
    else
      echo "Không tìm thấy file tham số ảo hóa lồng. KVM có thể chưa được cài đặt đúng cách."
    fi

  else
    echo "KVM modules CHƯA được tải."
  fi
else
  CPU_SUPPORT="false"
  echo "CPU KHÔNG hỗ trợ ảo hóa. Ảo hóa lồng không thể thực hiện được."
fi

echo "Kiểm tra hoàn tất."
