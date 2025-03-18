#!/bin/bash

# Định nghĩa các biểu tượng và màu sắc
INFO_ICON="ℹ️" # Information
SUCCESS_ICON="✅" # Success
WARNING_ICON="⚠️" # Warning
ERROR_ICON="❌" # Error

# Hàm trợ giúp
error_exit() {
  echo -e "${ERROR_ICON} Error: $1" >&2
  exit 1
}

command_exists() {
  command -v "$1" &> /dev/null
}

# Tùy chọn người dùng
SHOW_ALL=1
INTERACTIVE=0
SAVE_RESULTS=0
RESULTS_FILE="system_info_$(date +'%Y%m%d_%H%M%S').txt"

# Parse các tùy chọn
while getopts "hias" opt; do
  case $opt in
    h)
      echo "Usage: $0 [options]"
      echo "Options:"
      echo "  -h  Show this help message"
      echo "  -i  Interactive mode"
      echo "  -a  Show all information"
      echo "  -s  Save results to file"
      exit 0
      ;;
    i)
      INTERACTIVE=1
      ;;
    a)
      SHOW_ALL=1
      ;;
    s)
      SAVE_RESULTS=1
      ;;
    *)
      error_exit "Invalid option: $OPTARG"
      ;;
  esac
done

# Kiểm tra và cài đặt speedtest-cli
if ! command_exists speedtest-cli; then
  echo -e "================= Checking and Installing speedtest-cli =================="
  echo -e "${INFO_ICON} speedtest-cli is not installed. Installing..."

  if command_exists pip3; then
    sudo pip3 install speedtest-cli || error_exit "Failed to install speedtest-cli using pip3."
    echo -e "${SUCCESS_ICON} speedtest-cli installed successfully using pip3."
  else
    echo -e "${WARNING_ICON} pip3 not found. Attempting to install pip3..."
    sudo apt-get update && sudo apt-get install -y python3-pip || error_exit "Failed to install pip3. Please install pip3 manually and try again."
    sudo pip3 install speedtest-cli || error_exit "Failed to install speedtest-cli using pip3 after installing pip3."
    echo -e "${SUCCESS_ICON} pip3 and speedtest-cli installed successfully."
  fi
  echo ""
fi

# Chế độ tương tác
if [ $INTERACTIVE -eq 1 ]; then
  echo -e "Welcome! You are in interactive mode."
  read -p "Do you want to continue? (y/n): " -n 1 -r
  echo ""
  if [[ $REPLY =~ ^[Nn]$ ]]; then
    echo "Goodbye!"
    exit 0
  fi
fi

# Hiển thị thông tin hệ thống
echo -e "================= System Information =================="
echo "Hostname: $(hostname)"
echo "Current time: $(date)"
echo "Kernel: $(uname -r)"
echo "Uptime: $(uptime -p)"
echo ""

# Hiển thị thông tin hệ điều hành
echo -e "================= Operating System =================="
os_name=$(lsb_release -d | awk -F: '{print $2}' | sed 's/^ *//;s/ *$//')
if [ -z "$os_name" ]; then
  os_name=$(cat /etc/os-release | grep PRETTY_NAME | cut -d '=' -f2 | tr -d '"')
fi

if [ -z "$os_name" ]; then
  echo -e "${WARNING_ICON} Unable to determine operating system name."
else
  echo "Operating System: $os_name"
fi
echo ""

# Hiển thị thông tin CPU
echo -e "================= CPU Information =================="
echo "Model: $(grep "model name" /proc/cpuinfo | head -n 1 | awk -F: '{print $2}' | sed 's/^ *//;s/ *$//')"
echo "Number of cores: $(nproc)"
echo ""

# Hiển thị thông tin bộ nhớ
echo -e "================= Memory Information =================="
total_mem_kb=$(grep "MemTotal" /proc/meminfo | awk -F: '{print $2}' | sed 's/ kB//;s/^ *//')
total_mem_gb=$(echo "scale=2; $total_mem_kb / 1024 / 1024" | bc)
echo "Total Memory (RAM): ${total_mem_gb} GB"

free_mem_gb=$(free -g | awk 'NR==2 {print $4}') 
if [[ "$free_mem_gb" == "" || "$free_mem_gb" == "0" ]]; then
  free_mem_mb=$(free -m | awk 'NR==2 {print $7}') 
  free_mem_gb=$(echo "scale=2; $free_mem_mb / 1024" | bc)
fi

echo "Free Memory (RAM): ${free_mem_gb} GB"
echo ""

# Hiển thị thông tin đĩa
echo -e "================= Disk Information =================="
df -h / | awk 'NR==2{print "Total: "$2", Used: "$3", Available: "$4}'
echo ""

# Kiểm tra tốc độ mạng
echo -e "================= Network Information =================="
echo -e "${INFO_ICON} Testing network speed (using speedtest-cli)..."
speedtest-cli --simple 2>&1 > /dev/null

if [ $? -ne 0 ]; then
  echo -e "${ERROR_ICON} Network speed test failed. Please check your connection or speedtest-cli installation."
else
  speedtest_results=$(speedtest-cli --simple)
  echo -e "${SUCCESS_ICON} Speedtest Results: ${speedtest_results}"
fi

echo ""

# Kiểm tra địa chỉ IP và NAT
echo -e "================= IP Address and NAT =================="

ipv4=$(curl -s https://api.ipify.org | head -n 1)
if [ -n "$ipv4" ] && [[ "$ipv4" != "127.0.0.1" ]]; then
  echo "IPv4 Address: $ipv4"
else
  echo -e "${WARNING_ICON} IPv4 address not found."
  ipv4="None"
fi

ipv6=$(ip -6 addr | grep global | awk '{print $2}' | cut -d'/' -f1 | head -n 1)
if [ -n "$ipv6" ]; then
  echo "IPv6 Address: $ipv6"
else
  echo -e "${WARNING_ICON} IPv6 address not found."
  ipv6="None"
fi

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

  if ! echo "$config_output" | grep -q "table ip nat"; then
    echo "No NAT"
    return
  fi

  if echo "$config_output" | grep -q "chain postrouting" && echo "$config_output" | grep -q 'masquerade'; then
    echo "NAT1"
    return
  fi

  if echo "$config_output" | grep -q "chain postrouting" && echo "$config_output" | grep -q 'snat to'; then
    echo "NAT2"
    return
  fi

  if echo "$config_output" | grep -q "chain prerouting" && echo "$config_output" | grep -q 'dnat to'; then
    echo "NAT3"
    return
  fi

  echo "No NAT"
}

nat_status=$(check_nat)
echo "NAT Type: $nat_status"

echo ""

# Kiểm tra ảo hóa lồng nhau
echo -e "================= Nested Virtualization Check =================="

if grep -E '(vmx|svm)' /proc/cpuinfo > /dev/null; then
  CPU_SUPPORT="true"
  echo "${INFO_ICON} CPU supports virtualization (VT-x or AMD-V)."

  if lsmod | grep kvm > /dev/null; then
    KVM_INSTALLED="true"
    echo "${INFO_ICON} KVM modules are loaded."

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
        echo "${SUCCESS_ICON} Nested virtualization is enabled."
      else
        echo "${WARNING_ICON} Nested virtualization is not enabled."
      fi
    else
      echo "${WARNING_ICON} Nested virtualization parameter file not found. KVM may not be properly installed."
    fi

  else
    echo "${WARNING_ICON} KVM modules are NOT loaded."
  fi
else
  CPU_SUPPORT="false"
  echo "${ERROR_ICON} CPU does NOT support virtualization. Nested virtualization is not possible."
fi

echo ""

# Lưu kết quả
if [ $SAVE_RESULTS -eq 1 ]; then
  echo -e "${INFO_ICON} Saving results to $RESULTS_FILE..."
  echo "System Information:" > "$RESULTS_FILE"
  echo "Hostname: $(hostname)" >> "$RESULTS_FILE"
  echo "Current time: $(date)" >> "$RESULTS_FILE"
  echo "Kernel: $(uname -r)" >> "$RESULTS_FILE"
  echo "Uptime: $(uptime -p)" >> "$RESULTS_FILE"
  echo "" >> "$RESULTS_FILE"
  echo "Operating System: $os_name" >> "$RESULTS_FILE"
  echo "" >> "$RESULTS_FILE"
  echo "CPU Model: $(grep "model name" /proc/cpuinfo | head -n 1 | awk -F: '{print $2}' | sed 's/^ *//;s/ *$//')" >> "$RESULTS_FILE"
  echo "Number of cores: $(nproc)" >> "$RESULTS_FILE"
  echo "" >> "$RESULTS_FILE"
  echo "Total Memory (RAM): ${total_mem_gb} GB" >> "$RESULTS_FILE"
  echo "Free Memory (RAM): ${free_mem_gb} GB" >> "$RESULTS_FILE"
  echo "" >> "$RESULTS_FILE"
  echo "Disk Usage:" >> "$RESULTS_FILE"
  df -h / | awk 'NR==2{print "Total: "$2", Used: "$3", Available: "$4}' >> "$RESULTS_FILE"
  echo "" >> "$RESULTS_FILE"
  echo "Network Speedtest Results: ${speedtest_results}" >> "$RESULTS_FILE"
  echo "" >> "$RESULTS_FILE"
  echo "IPv4 Address: $ipv4" >> "$RESULTS_FILE"
  echo "IPv6 Address: $ipv6" >> "$RESULTS_FILE"
  echo "NAT Type: $nat_status" >> "$RESULTS_FILE"
  echo "" >> "$RESULTS_FILE"
  echo "Nested Virtualization Support: $CPU_SUPPORT" >> "$RESULTS_FILE"
  if [ "$CPU_SUPPORT" == "true" ]; then
    echo "Nested Virtualization Enabled: $(if [[ "$NESTED_ENABLED" == "Y" ]]; then echo "Yes"; else echo "No"; fi)" >> "$RESULTS_FILE"
  fi
  echo -e "${SUCCESS_ICON} Results saved to $RESULTS_FILE."
fi

echo -e "\n${SUCCESS_ICON} Check complete."
