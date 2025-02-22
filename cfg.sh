#!/bin/bash
INFO_ICON="ℹ️" # Information
SUCCESS_ICON="✅" # Success
ERROR_ICON="❌" # Error
WARNING_ICON="⚠️" # Warning

# ==================================================================
# Helper Functions
# ==================================================================

# Function to print an error message and exit
error_exit() {
  echo -e "${ERROR_ICON} Error: $1" >&2
  exit 1
}

# Function to check if a command exists
command_exists() {
  command -v "$1" &> /dev/null
}

# ==================================================================
# Install speedtest-cli (if it doesn't exist)
# ==================================================================

if ! command_exists speedtest-cli; then
  echo -e "================= Checking and Installing speedtest-cli =================="
  echo -e "${INFO_ICON} speedtest-cli is not installed. Installing..."

  # Attempt to install using pip3
  if command_exists pip3; then
    sudo pip3 install speedtest-cli || error_exit "Failed to install speedtest-cli using pip3."
    echo -e "${SUCCESS_ICON} speedtest-cli installed successfully using pip3."
  else
    echo -e "${WARNING_ICON} pip3 not found. Attempting to install pip3..."
    # Attempt to install pip3 (e.g., for Debian/Ubuntu)
    sudo apt-get update && sudo apt-get install -y python3-pip || error_exit "Failed to install pip3. Please install pip3 manually and try again."
    sudo pip3 install speedtest-cli || error_exit "Failed to install speedtest-cli using pip3 after installing pip3."
    echo -e "${SUCCESS_ICON} pip3 and speedtest-cli installed successfully."
  fi
  echo ""
fi

# ==================================================================
# System Configuration
# ==================================================================

echo -e "================= System =================="
echo "Hostname: $(hostname)"
echo "Current time: $(date)"
echo "Kernel: $(uname -r)"
echo "Uptime: $(uptime -p)"
echo ""

# Operating System
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

# CPU Configuration
echo -e "================= CPU =================="
echo "Model: $(grep "model name" /proc/cpuinfo | head -n 1 | awk -F: '{print $2}' | sed 's/^ *//;s/ *$//')"
echo "Number of cores: $(nproc)"
echo ""

# Memory Configuration
echo -e "================= Memory (RAM) =================="
total_mem_kb=$(grep "MemTotal" /proc/meminfo | awk -F: '{print $2}' | sed 's/ kB//;s/^ *//')
total_mem_gb=$(echo "scale=2; $total_mem_kb / 1024 / 1024" | bc)
echo "Total Memory (RAM): ${total_mem_gb} GB"

# Get Free RAM (Try multiple methods)
free_mem_gb=$(free -g | awk 'NR==2 {print $4}')  # Try getting from free -g (GB) first

if [[ "$free_mem_gb" == "" || "$free_mem_gb" == "0" ]]; then  # If unsuccessful, try free -m (MB)
  free_mem_mb=$(free -m | awk 'NR==2 {print $7}') # Get "available"
  free_mem_gb=$(echo "scale=2; $free_mem_mb / 1024" | bc)
fi

echo "Free Memory (RAM): ${free_mem_gb} GB"
echo ""

# Disk Configuration
echo -e "================= Disk =================="
df -h / | awk 'NR==2{print "Total: "$2", Used: "$3", Available: "$4}'
echo ""

# ==================================================================
# Network Speed (using speedtest-cli)
# ==================================================================

echo -e "================= Network =================="
echo -e "${INFO_ICON} Testing network speed (using speedtest-cli)..."
speedtest-cli --simple 2>&1 > /dev/null  # Redirect stderr and stdout

if [ $? -ne 0 ]; then
  echo -e "${ERROR_ICON} Network speed test failed. Please check your connection or speedtest-cli installation."
else
  # Get results from the first line of speedtest-cli --simple
  speedtest_results=$(speedtest-cli --simple)
  echo -e "${SUCCESS_ICON} Speedtest Results: ${speedtest_results}"
fi

echo ""

# ==================================================================
# NAT Check and IP Address Display
# ==================================================================

echo -e "================= IP Address and NAT =================="

# Get IPv4 address (always use the API as a last resort and get a single address)
ipv4=$(curl -s https://api.ipify.org | head -n 1)

if [ -n "$ipv4" ] && [[ "$ipv4" != "127.0.0.1" ]]; then
  echo "IPv4 Address: $ipv4"
else
  echo -e "${WARNING_ICON} IPv4 address not found."
  ipv4="None"
fi

# Get IPv6 address (if available)
ipv6=$(ip -6 addr | grep global | awk '{print $2}' | cut -d'/' -f1 | head -n 1) # Only get the first line
if [ -n "$ipv6" ]; then
  echo "IPv6 Address: $ipv6"
else
  echo -e "${WARNING_ICON} IPv6 address not found."
  ipv6="None"
fi

# Check NAT using iptables/nftables
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
echo "NAT Type: $nat_status"

# ==================================================================
# Nested Virtualization Check
# ==================================================================

echo -e "================= Nested Virtualization Check =================="

# Check CPU support (Intel or AMD)
if grep -E '(vmx|svm)' /proc/cpuinfo > /dev/null; then
  CPU_SUPPORT="true"
  echo "${INFO_ICON} CPU supports virtualization (VT-x or AMD-V)."

  # Check KVM modules
  if lsmod | grep kvm > /dev/null; then
    KVM_INSTALLED="true"
    echo "${INFO_ICON} KVM modules are loaded."

    # Check nested virtualization
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

echo "${SUCCESS_ICON} Check complete."
