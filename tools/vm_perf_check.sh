#!/bin/bash

# ==============================================================================
# VM Performance & Quality Check Script v1.1
# Description: Measures key performance indicators for a Virtual Machine.
# Author:      @LaoDauTg
# Date:        Sun Apr 12 2025
# Requires:    bash, awk, grep, sed, bc, top, free, uptime, ip, ping
# Optional Deps: sysstat (for iostat, sar), fio (for disk benchmark)
# ==============================================================================

# --- Configuration ---
SAMPLE_INTERVAL=2
SAMPLE_COUNT=3
TARGET_DISK=""
FIO_SIZE="256M"
FIO_TEST_DIR="/tmp"
PING_TARGET=""
PING_COUNT=4
WARN_CPU_STEAL=5
WARN_SWAP_USAGE=10
WARN_DISK_UTIL=85
WARN_NET_ERRORS=1
WARN_PING_LATENCY=100

# --- Colors ---
COLOR_BLUE="\033[0;34m"
COLOR_GREEN="\033[0;32m"
COLOR_YELLOW="\033[0;33m"
COLOR_RED="\033[0;31m"
COLOR_NC="\033[0m" # No Color

# --- Helper Functions ---
info() { printf "${COLOR_BLUE}ℹ %s${COLOR_NC}\n" "$1"; }
success() { printf "${COLOR_GREEN}✅ %s${COLOR_NC}\n" "$1"; } # Added success icon definition
warn() { printf "${COLOR_YELLOW}⚠️ %s${COLOR_NC}\n" "$1"; } # Added warning icon definition
error_exit() { printf "${COLOR_RED}❌ Error: %s${COLOR_NC}\n" "$1" >&2; exit 1; } # Added error icon definition
command_exists() { command -v "$1" &>/dev/null; }
check_sudo() {
  if [[ $EUID -ne 0 ]]; then
    if ! sudo -n uptime &>/dev/null; then
       info "Sudo privileges are needed for installing missing packages (sysstat, fio)."
       sudo -v
       if [ $? -ne 0 ]; then
           error_exit "Sudo privileges are required. Please run with sudo or grant passwordless sudo."
       fi
    fi
    SUDO_CMD="sudo"
  else
    SUDO_CMD=""
  fi
}

install_package() {
  local pkg_name="$1"
  local pkg_manager=""

  if command_exists apt-get; then
    pkg_manager="apt-get"
    local update_cmd="update"
  elif command_exists yum; then
    pkg_manager="yum"
    local update_cmd="makecache" # Or check-update, makecache is usually faster
  elif command_exists dnf; then
    pkg_manager="dnf"
    local update_cmd="makecache"
  else
    warn "Cannot determine package manager. Please install '$pkg_name' manually."
    return 1
  fi

  info "Attempting to install '$pkg_name' using $pkg_manager..."
  check_sudo
  # Run update only if needed, be less aggressive
  # $SUDO_CMD $pkg_manager $update_cmd -y || warn "Failed to update package lists."
  $SUDO_CMD $pkg_manager install -y "$pkg_name"
  # Verify command exists *after* install attempt
  local cmd_to_check="$pkg_name"
  [[ "$pkg_name" == "sysstat" ]] && cmd_to_check="iostat" # Check for iostat if installing sysstat

  if ! command_exists "$cmd_to_check"; then
     # Give package manager a few seconds to update PATH etc.
     sleep 2
     if ! command_exists "$cmd_to_check"; then
        error_exit "Failed to install/find '$pkg_name' (command: $cmd_to_check). Please install it manually."
     fi
  fi
  success "'$pkg_name' installed or already present."
}

get_root_disk() {
  lsblk -no pkname "$(findmnt -n -o SOURCE /)" 2>/dev/null | head -n 1 || \
  lsblk -no pkname "$(df / | awk 'NR==2 {print $1}')" 2>/dev/null | head -n 1 || \
  echo "sda" # Fallback
}

get_gateway() {
   ip route | grep default | awk '{print $3}' | head -n 1
}

is_numeric() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

# --- Dependency Checks & Setup ---
# (Dependency check logic remains the same)
info "Checking required tools..."
basic_tools=("awk" "grep" "sed" "bc" "top" "free" "uptime" "ip" "ping" "lsblk" "df" "findmnt")
missing_basic=()
for tool in "${basic_tools[@]}"; do
  if ! command_exists "$tool"; then
    missing_basic+=("$tool")
  fi
done
if [ ${#missing_basic[@]} -gt 0 ]; then
  error_exit "Missing basic required tools: ${missing_basic[*]}. Please install them."
fi

needs_sysstat=0
needs_fio=0
if ! command_exists iostat || ! command_exists sar; then
  needs_sysstat=1
  warn "sysstat (for iostat/sar) not found."
fi
if ! command_exists fio; then
  needs_fio=1
  warn "fio (for disk benchmark) not found."
fi

if [ $needs_sysstat -eq 1 ]; then install_package "sysstat"; fi
if [ $needs_fio -eq 1 ]; then install_package "fio"; fi

if [ -z "$TARGET_DISK" ]; then
    TARGET_DISK=$(get_root_disk)
    info "Auto-detected root disk: /dev/$TARGET_DISK"
    if [ ! -b "/dev/$TARGET_DISK" ]; then
        warn "Could not reliably detect root block device '/dev/$TARGET_DISK'. Disk stats might be inaccurate."
        # Don't fallback blindly here, let iostat fail later if needed
    fi
fi

if [ -z "$PING_TARGET" ]; then
    PING_TARGET=$(get_gateway)
    if [ -z "$PING_TARGET" ]; then
        warn "Could not auto-detect default gateway. Falling back to 8.8.8.8 for ping test."
        PING_TARGET="8.8.8.8"
    else
        info "Auto-detected default gateway for ping test: $PING_TARGET"
    fi
fi


# --- Data Collection ---
info "Starting data collection (this may take a minute, especially the FIO test)..."
output_buffer=""

# 1. CPU Usage
output_buffer+="-------------------- CPU Usage --------------------\n"
# Run top once, capture output
top_output=$(top -bn1)
cpu_info=$(echo "$top_output" | grep '%Cpu(s)')
cpu_us=$(echo "$cpu_info" | awk '{print $2}')
cpu_sy=$(echo "$cpu_info" | awk '{print $4}')
# cpu_ni=$(echo "$cpu_info" | awk '{print $6}') # Often 0, less critical for basic check
cpu_id=$(echo "$cpu_info" | awk '{print $8}')
cpu_wa=$(echo "$cpu_info" | awk '{print $10}')
# cpu_hi=$(echo "$cpu_info" | awk '{print $12}') # Hardware IRQ
# cpu_si=$(echo "$cpu_info" | awk '{print $14}') # Software IRQ
cpu_st=$(echo "$cpu_info" | awk '{print $16}')
load_avg=$(uptime | awk -F'load average: ' '{print $2}')

output_buffer+=$(printf " User: %6.1f%%   System: %6.1f%%   Idle: %6.1f%% \n" "$cpu_us" "$cpu_sy" "$cpu_id")
output_buffer+=$(printf " Wait: %6.1f%%   Steal*: %6.1f%% \n" "$cpu_wa" "$cpu_st")
# Check if steal time is numeric before comparing
if is_numeric "$cpu_st" && (( $(echo "$cpu_st > $WARN_CPU_STEAL" | bc -l) )); then
    output_buffer+="$(warn " High CPU Steal Time detected! Indicates CPU contention at the hypervisor level.")\n"
fi
output_buffer+="\nLoad Average (1m, 5m, 15m): $load_avg\n"
output_buffer+="\n*Steal time: Time the VM wanted to run but the hypervisor ran something else.\n"

# 2. Memory Usage
output_buffer+="\n-------------------- Memory Usage -------------------\n"
mem_info=$(free -m)
mem_total=$(echo "$mem_info" | awk 'NR==2{print $2}')
mem_used=$(echo "$mem_info" | awk 'NR==2{print $3}')
# mem_free=$(echo "$mem_info" | awk 'NR==2{print $4}') # Less useful than available
mem_cache=$(echo "$mem_info" | awk 'NR==2{print $6}') # Buff/Cache
mem_available=$(echo "$mem_info" | awk 'NR==2{print $7}')

swap_total=$(echo "$mem_info" | awk 'NR==3{print $2}')
swap_used=$(echo "$mem_info" | awk 'NR==3{print $3}')

mem_used_percent="0.0"
if [[ "$mem_total" -gt 0 ]]; then
    # FIX: Multiply by 100 first for bc
    mem_used_percent=$(echo "scale=1; ($mem_used * 100) / $mem_total" | bc)
fi
mem_available_percent="0.0"
if [[ "$mem_total" -gt 0 ]]; then
    # FIX: Multiply by 100 first for bc
    mem_available_percent=$(echo "scale=1; ($mem_available * 100) / $mem_total" | bc)
fi
swap_used_percent="0.0"
if [[ "$swap_total" -gt 0 ]]; then
    # FIX: Multiply by 100 first for bc
    swap_used_percent=$(echo "scale=1; ($swap_used * 100) / $swap_total" | bc)
fi

output_buffer+=$(printf "Total RAM:     %6d MB\n" "$mem_total")
output_buffer+=$(printf "Used RAM:      %6d MB (%s%%)\n" "$mem_used" "$mem_used_percent")
output_buffer+=$(printf "Available RAM: %6d MB (%s%%)\n" "$mem_available" "$mem_available_percent")
output_buffer+=$(printf "Buffers/Cache: %6d MB\n" "$mem_cache")
output_buffer+="\n"
output_buffer+=$(printf "Total Swap:    %6d MB\n" "$swap_total")
output_buffer+=$(printf "Used Swap:     %6d MB (%s%%)\n" "$swap_used" "$swap_used_percent")

if is_numeric "$swap_used_percent" && (( $(echo "$swap_used_percent > $WARN_SWAP_USAGE" | bc -l) )); then
    output_buffer+="$(warn " High Swap Usage detected! Indicates memory pressure.")\n"
fi
if is_numeric "$mem_available" && [ "$mem_available" -lt 100 ]; then
     output_buffer+="$(warn " Low Available RAM (< 100MB).")\n"
fi

# 3. Disk I/O Monitoring
output_buffer+="\n-------------------- Disk I/O (Device: /dev/$TARGET_DISK) ---------------\n"
avg_rs="N/A"; avg_ws="N/A"; avg_rkBs="N/A"; avg_wkBs="N/A"; avg_await="N/A"; avg_util="N/A" # Init vars
if [ -b "/dev/$TARGET_DISK" ]; then
    info "Running iostat to monitor disk activity..."
    # FIX: Removed one %.2f from printf format string (expecting 6 values)
    iostat_output=$(iostat -dx "$TARGET_DISK" "$SAMPLE_INTERVAL" "$SAMPLE_COUNT" | awk -v dev="$TARGET_DISK" '
        BEGIN { count=0; sum_rs=0; sum_ws=0; sum_rkBs=0; sum_wkBs=0; sum_await=0; sum_util=0; }
        $1 == dev {
            if (NR > 3 && NF >= 14) { # Check number of fields for safety
               # Assuming standard iostat -dx output columns
               # 4=r/s, 5=w/s, 6=rkB/s, 7=wkB/s, 10=await, 14=%util
               sum_rs+=$4; sum_ws+=$5; sum_rkBs+=$6; sum_wkBs+=$7; sum_await+=$10; sum_util+=$14;
               count++;
            }
        }
        END {
            if (count > 0) {
                 printf "%.2f %.2f %.2f %.2f %.2f %.2f", sum_rs/count, sum_ws/count, sum_rkBs/count, sum_wkBs/count, sum_await/count, sum_util/count;
            } else {
                 print "Error: No data parsed"; # Print error if no data lines match
            }
        }')

    if [[ $iostat_output == *"Error"* ]] || [[ -z "$iostat_output" ]]; then
        output_buffer+="$(warn " Could not get valid iostat data for /dev/$TARGET_DISK. Output: $iostat_output")\n"
    else
        read -r avg_rs avg_ws avg_rkBs avg_wkBs avg_await avg_util <<< "$iostat_output"
        # Re-validate values are numeric just in case awk failed slightly differently
        is_numeric "$avg_rs" || avg_rs="N/A"
        is_numeric "$avg_ws" || avg_ws="N/A"
        is_numeric "$avg_rkBs" || avg_rkBs="N/A"
        is_numeric "$avg_wkBs" || avg_wkBs="N/A"
        is_numeric "$avg_await" || avg_await="N/A"
        is_numeric "$avg_util" || avg_util="N/A"
    fi
else
     output_buffer+="$(warn " Target block device /dev/$TARGET_DISK not found. Skipping iostat.")\n"
fi
# Display results (even if N/A)
output_buffer+=$(printf "Avg Read IOPS:  %8s r/s\n" "$avg_rs") # Use %s for N/A
output_buffer+=$(printf "Avg Write IOPS: %8s w/s\n" "$avg_ws")
output_buffer+=$(printf "Avg Read Speed: %8s kB/s\n" "$avg_rkBs")
output_buffer+=$(printf "Avg Write Speed:%8s kB/s\n" "$avg_wkBs")
output_buffer+=$(printf "Avg I/O Wait:   %8s ms (await)\n" "$avg_await")
output_buffer+=$(printf "Avg Disk Util:  %8s %% \n" "$avg_util")

if is_numeric "$avg_util" && (( $(echo "$avg_util > $WARN_DISK_UTIL" | bc -l) )); then
    output_buffer+="$(warn " High Disk Utilization detected! Disk might be a bottleneck.")\n"
fi
if is_numeric "$avg_await" && (( $(echo "$avg_await > 50" | bc -l) )); then
    output_buffer+="$(warn " High Average I/O Wait time detected (> 50ms).")\n"
fi

# 4. Disk I/O Benchmarking (using fio)
output_buffer+="\n-------------------- Disk Benchmark (using FIO) -------------------\n"
seq_write_bw=0; seq_write_iops=0; seq_read_bw=0; seq_read_iops=0; # Init FIO vars
rand_write_bw=0; rand_write_iops=0; rand_read_bw=0; rand_read_iops=0;
fio_error_flag=0

FIO_TEST_FILE="$FIO_TEST_DIR/vm_perf_test.fio"
if [ ! -d "$FIO_TEST_DIR" ] || [ ! -w "$FIO_TEST_DIR" ]; then
     output_buffer+="$(warn " FIO test directory '$FIO_TEST_DIR' does not exist or is not writable. Skipping FIO benchmark.")\n"
     fio_error_flag=1
else
    info "Running FIO benchmark (Sequential & Random Read/Write)... This might take a minute."
    warn "FIO benchmark will create a test file '$FIO_TEST_FILE' of size $FIO_SIZE."

    fio_base_cmd="fio --name=vm_perf_test --filename=$FIO_TEST_FILE --size=$FIO_SIZE --runtime=15s --time_based --direct=1 --verify=0 --bs=4k --ioengine=libaio --iodepth=64 --numjobs=1 --group_reporting --minimal"

    # Run Sequential Write
    seq_write_output=$($fio_base_cmd --rw=write 2>&1)
    if [ $? -ne 0 ]; then warn "FIO seq write failed. Output: $seq_write_output"; fio_error_flag=1; else
        seq_write_bw=$(echo "$seq_write_output" | awk -F';' '{print int($8)}') # BW is $8
        seq_write_iops=$(echo "$seq_write_output" | awk -F';' '{print int($9)}') # IOPS is $9
    fi

    # Run Sequential Read
    seq_read_output=$($fio_base_cmd --rw=read 2>&1)
    if [ $? -ne 0 ]; then warn "FIO seq read failed. Output: $seq_read_output"; fio_error_flag=1; else
        seq_read_bw=$(echo "$seq_read_output" | awk -F';' '{print int($49)}') # BW is $49
        seq_read_iops=$(echo "$seq_read_output" | awk -F';' '{print int($50)}') # IOPS is $50
    fi

    # Run Random Write
    rand_write_output=$($fio_base_cmd --rw=randwrite 2>&1)
    if [ $? -ne 0 ]; then warn "FIO rand write failed. Output: $rand_write_output"; fio_error_flag=1; else
        rand_write_bw=$(echo "$rand_write_output" | awk -F';' '{print int($8)}') # BW is $8
        rand_write_iops=$(echo "$rand_write_output" | awk -F';' '{print int($9)}') # IOPS is $9
    fi

    # Run Random Read
    rand_read_output=$($fio_base_cmd --rw=randread 2>&1)
    if [ $? -ne 0 ]; then warn "FIO rand read failed. Output: $rand_read_output"; fio_error_flag=1; else
        rand_read_bw=$(echo "$rand_read_output" | awk -F';' '{print int($49)}') # BW is $49
        rand_read_iops=$(echo "$rand_read_output" | awk -F';' '{print int($50)}') # IOPS is $50
    fi

    # Cleanup test file
    rm -f "$FIO_TEST_FILE"
fi

# Display FIO results
if [ $fio_error_flag -eq 0 ]; then
    output_buffer+=$(printf "Seq. Write: %8d KiB/s, %8d IOPS\n" "$seq_write_bw" "$seq_write_iops")
    output_buffer+=$(printf "Seq. Read:  %8d KiB/s, %8d IOPS\n" "$seq_read_bw" "$seq_read_iops")
    output_buffer+=$(printf "Rand. Write:%8d KiB/s, %8d IOPS\n" "$rand_write_bw" "$rand_write_iops")
    output_buffer+=$(printf "Rand. Read: %8d KiB/s, %8d IOPS\n" "$rand_read_bw" "$rand_read_iops")
    output_buffer+="\n(Benchmark results depend heavily on storage type, hypervisor, and configuration)\n"
else
    output_buffer+="(FIO benchmark encountered errors or was skipped)\n"
fi


# 5. Network I/O
output_buffer+="\n-------------------- Network I/O --------------------\n"
rx_kBs="0.00"; tx_kBs="0.00"; rx_errs="0"; tx_errs="0"; rx_drop="0"; tx_drop="0" # Init vars
net_interfaces=$(ip -o link show | awk -F': ' '!/lo/ {print $2}') # Get non-loopback interfaces
if [ -z "$net_interfaces" ]; then
    output_buffer+="$(warn " No active non-loopback network interfaces found.")\n"
else
    first_iface=$(echo "$net_interfaces" | head -n 1)
    output_buffer+=$(printf "Monitoring interface: %s (Primary)\n" "$first_iface")
    info "Running sar to monitor network activity..."
    # Get the Average line for the specific interface
    sar_output=$(sar -n DEV "$SAMPLE_INTERVAL" $((SAMPLE_COUNT - 1)) 2>/dev/null | grep Average | grep "$first_iface")

    if [ -n "$sar_output" ]; then
        # Use awk to parse fields robustly
        read -r rx_kBs tx_kBs rx_errs tx_errs rx_drop tx_drop <<< $(echo "$sar_output" | awk '{print $5, $6, $9, $10, $11, $12}')

        # Validate numeric values (especially errors/drops which might be absent)
        is_numeric "$rx_kBs" || rx_kBs="N/A"
        is_numeric "$tx_kBs" || tx_kBs="N/A"
        is_numeric "$rx_errs" || rx_errs=0
        is_numeric "$tx_errs" || tx_errs=0
        is_numeric "$rx_drop" || rx_drop=0
        is_numeric "$tx_drop" || tx_drop=0

        output_buffer+=$(printf "Avg RX Speed:   %8s kB/s\n" "$rx_kBs")
        output_buffer+=$(printf "Avg TX Speed:   %8s kB/s\n" "$tx_kBs")
        output_buffer+=$(printf "Errors (RX/TX): %s / %s\n" "$rx_errs" "$tx_errs")
        output_buffer+=$(printf "Drops (RX/TX):  %s / %s\n" "$rx_drop" "$tx_drop") # FIX: Display parsed values

        # FIX: Check if numeric before bc comparison
        net_warn_check="0"
        if [[ "$rx_errs" -ge "$WARN_NET_ERRORS" ]] || \
           [[ "$tx_errs" -ge "$WARN_NET_ERRORS" ]] || \
           [[ "$rx_drop" -ge "$WARN_NET_ERRORS" ]] || \
           [[ "$tx_drop" -ge "$WARN_NET_ERRORS" ]]; then
            net_warn_check="1"
        fi

        if [ "$net_warn_check" -eq 1 ]; then
             output_buffer+="$(warn " Network errors or drops detected on interface $first_iface!")\n"
        fi
    else
        output_buffer+="$(warn " Could not get sar data for interface $first_iface. Check sysstat or run duration.")\n"
    fi
fi

# 6. Network Latency
output_buffer+="\n-------------------- Network Latency --------------------\n"
ping_avg="N/A" # Init var
info "Pinging $PING_TARGET..."
ping_output=$(ping -c "$PING_COUNT" -W 1 "$PING_TARGET" 2>&1)

if [[ $ping_output == *"unknown host"* ]]; then
    output_buffer+="$(warn " Could not resolve host: $PING_TARGET. Skipping latency test.")\n"
elif [[ $ping_output == *"100% packet loss"* ]]; then
    output_buffer+="$(warn " 100% packet loss when pinging $PING_TARGET. Network issue?")\n"
elif [[ $ping_output == *"rtt min/avg/max/mdev"* ]]; then
    # Extract avg value more reliably
    ping_avg=$(echo "$ping_output" | tail -n 1 | awk -F'/' '{print $5}') # avg is the 5th field when split by /
    if is_numeric "$ping_avg"; then
        output_buffer+=$(printf "Avg Latency to %s: %.2f ms\n" "$PING_TARGET" "$ping_avg")
        if (( $(echo "$ping_avg > $WARN_PING_LATENCY" | bc -l) )); then
             output_buffer+="$(warn " High network latency detected (> $WARN_PING_LATENCY ms).")\n"
        fi
    else
        output_buffer+="$(warn " Could not parse average ping time from output.")\n"
        ping_avg="N/A" # Reset if parsing failed
    fi
else
     output_buffer+="$(warn " Could not get valid ping statistics for $PING_TARGET.")\n"
fi

# --- Final Output ---
info "Performance Check Complete. Results:"
echo ""
printf "%b" "$output_buffer"

exit 0
