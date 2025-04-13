#!/bin/bash
# Exit on error and fail pipe
set -o errexit
set -o pipefail

# --- Configuration ---
SAMPLE_INTERVAL=2
SAMPLE_COUNT=3
TARGET_DISK=""
FIO_SIZE="256M"
FIO_TEST_DIR="/tmp"
FIO_RUNTIME=20
FIO_RAMP_TIME=5
PING_TARGET=""
PING_COUNT=4
WARN_CPU_STEAL=5.0
WARN_SWAP_USAGE=10.0
WARN_DISK_UTIL=85.0
WARN_DISK_AWAIT=50.0
WARN_NET_ERRORS=1
WARN_PING_LATENCY=100.0

# --- Colors & Icons ---
COLOR_BLUE="\033[0;34m"; COLOR_GREEN="\033[0;32m"; COLOR_YELLOW="\033[0;33m";
COLOR_RED="\033[0;31m"; COLOR_NC="\033[0m";
ICON_INFO="ℹ"; ICON_SUCCESS="✅"; ICON_WARN="⚠️"; ICON_ERROR="❌"

# --- Global Variables ---
SUDO_CMD=""
declare -a warnings_list

# --- Helper Functions ---
info()    { printf "${COLOR_BLUE}${ICON_INFO} %s${COLOR_NC}\n" "$1"; }
success() { printf "${COLOR_GREEN}${ICON_SUCCESS} %s${COLOR_NC}\n" "$1"; }
warn()    { local msg="$1"; printf "${COLOR_YELLOW}${ICON_WARN} %s${COLOR_NC}\n" "$msg"; warnings_list+=("$msg"); }
error_exit() { printf "${COLOR_RED}${ICON_ERROR} Error: %s${COLOR_NC}\n" "$1" >&2; exit 1; }
command_exists() { command -v "$1" &>/dev/null; }

check_sudo() {
  [[ $EUID -eq 0 ]] && SUDO_CMD="" && return 0
  if ! sudo -n uptime &>/dev/null; then
     info "Sudo privileges are needed for installing missing packages."
     if ! sudo -v; then
       error_exit "Sudo privileges required and failed to acquire."
     fi
  fi
  SUDO_CMD="sudo"
}

install_package() {
  local pkg_name="$1" cmd_to_check="$1"
  [[ "$pkg_name" == "sysstat" ]] && cmd_to_check="iostat"
  [[ "$pkg_name" == "jq" ]] && cmd_to_check="jq"
  [[ "$pkg_name" == "fio" ]] && cmd_to_check="fio"

  if command_exists "$cmd_to_check"; then return 0; fi

  local pkg_manager=""
  if command_exists apt-get; then pkg_manager="apt-get";
  elif command_exists yum; then pkg_manager="yum";
  elif command_exists dnf; then pkg_manager="dnf";
  else warn "Cannot determine package manager. Please install '$pkg_name' manually."; return 1; fi

  info "Attempting to install '$pkg_name' using $pkg_manager..."
  check_sudo
  if $SUDO_CMD $pkg_manager install -y "$pkg_name"; then
    sleep 1
    if command_exists "$cmd_to_check"; then
      success "'$pkg_name' ($cmd_to_check) installed successfully."
    else
      error_exit "Installation of '$pkg_name' reported success, but command '$cmd_to_check' not found."
    fi
  else
     error_exit "Failed to install '$pkg_name' using $pkg_manager."
  fi
}

get_root_disk() {
  lsblk -no pkname "$(findmnt -n -o SOURCE /)" 2>/dev/null | head -n 1 || \
  lsblk -no pkname "$(df / | awk 'NR==2 {print $1}')" 2>/dev/null | head -n 1 || \
  echo "sda"
}

get_gateway() { ip route | grep default | awk '{print $3}' | head -n 1; }
is_numeric() { [[ "$1" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]]; }
to_int() { printf "%.0f" "$1" 2>/dev/null || echo 0; }

# Cleanup function
FIO_TEST_FILE="$FIO_TEST_DIR/vm_perf_test_$(date +%s).fio" # Define early for trap
cleanup() {
  if [[ -n "$FIO_TEST_FILE" ]] && [[ -f "$FIO_TEST_FILE" ]]; then
    rm -f "$FIO_TEST_FILE"
  fi
  rm -f /tmp/fio_*.json
}
trap cleanup EXIT INT TERM HUP

# --- Dependency Checks & Setup ---
info "Checking required tools..."
basic_tools=("awk" "grep" "sed" "bc" "top" "free" "uptime" "ip" "ping" "printf" "lsblk" "df" "findmnt" "jq")
optional_tools=("iostat" "sar" "fio")
missing_basic=()
for tool in "${basic_tools[@]}"; do
  if ! command_exists "$tool"; then missing_basic+=("$tool"); fi
done
if [ ${#missing_basic[@]} -gt 0 ]; then
  install_package "jq" # Try installing jq first as it's crucial
  missing_basic=()
  for tool in "${basic_tools[@]}"; do
    if ! command_exists "$tool"; then missing_basic+=("$tool"); fi
  done
  if [ ${#missing_basic[@]} -gt 0 ]; then
      error_exit "Missing basic required tools: ${missing_basic[*]}. Please install them (especially jq)."
  fi
fi
success "Basic tools check passed."

install_package "sysstat"
install_package "fio"

fio_version="N/A"
command_exists fio && fio_version=$(fio --version 2>&1)

if [ -z "$TARGET_DISK" ]; then
    TARGET_DISK=$(get_root_disk)
    info "Auto-detected root disk: /dev/$TARGET_DISK"
    if [ ! -b "/dev/$TARGET_DISK" ]; then
        warn "Detected root disk '/dev/$TARGET_DISK' is not a block device. Disk stats may fail."
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


# --- Data Collection Functions ---

collect_os_info() {
    local os_name kernel
    os_name=$( ([ -f /etc/os-release ] && source /etc/os-release && echo "$PRETTY_NAME") || lsb_release -ds || echo "N/A" )
    kernel=$(uname -r)
    printf "%-18s %s\n" "Operating System:" "$os_name"
    printf "%-18s %s\n" "Kernel Version:" "$kernel"
}

collect_cpu_info() {
    output_buffer+="-------------------- CPU Usage --------------------\n"
    local top_output cpu_info cpu_us cpu_sy cpu_id cpu_wa cpu_st load_avg
    top_output=$(top -bn1 || echo "Error running top") # Add error handling
    if [[ "$top_output" == *"Error"* ]]; then
        warn "Failed to collect CPU usage via top."
        output_buffer+=" N/A\n"
        return
    fi

    cpu_info=$(echo "$top_output" | grep '%Cpu(s)')
    cpu_us=$(echo "$cpu_info" | awk '{print $2}')
    cpu_sy=$(echo "$cpu_info" | awk '{print $4}')
    cpu_id=$(echo "$cpu_info" | awk '{print $8}')
    cpu_wa=$(echo "$cpu_info" | awk '{print $10}')
    cpu_st=$(echo "$cpu_info" | awk '{print $16}')
    load_avg=$(uptime | awk -F'load average: ' '{print $2}')

    output_buffer+=$(printf " User: %6.1f%%   System: %6.1f%%   Idle: %6.1f%% \n" "$cpu_us" "$cpu_sy" "$cpu_id")
    output_buffer+=$(printf " Wait: %6.1f%%   Steal*: %6.1f%% \n" "$cpu_wa" "$cpu_st")
    if is_numeric "$cpu_st" && (( $(echo "$cpu_st > $WARN_CPU_STEAL" | bc -l) )); then
        warn "CPU Steal Time (${cpu_st}%) exceeds threshold (${WARN_CPU_STEAL}%)."
    fi
    output_buffer+="\nLoad Average (1m, 5m, 15m): $load_avg\n"
    output_buffer+="\n*Steal time: CPU time the hypervisor didn't allocate to this VM when requested.\n"
}

collect_mem_info() {
    output_buffer+="\n-------------------- Memory Usage -------------------\n"
    local mem_info mem_total mem_used mem_cache mem_available swap_total swap_used
    mem_info=$(free -m || echo "Error running free")
     if [[ "$mem_info" == *"Error"* ]]; then
        warn "Failed to collect Memory usage via free."
        output_buffer+=" N/A\n"
        return
    fi

    mem_total=$(echo "$mem_info" | awk 'NR==2{print $2}')
    mem_used=$(echo "$mem_info" | awk 'NR==2{print $3}')
    mem_cache=$(echo "$mem_info" | awk 'NR==2{print $6}')
    mem_available=$(echo "$mem_info" | awk 'NR==2{print $7}')
    swap_total=$(echo "$mem_info" | awk 'NR==3{print $2}')
    swap_used=$(echo "$mem_info" | awk 'NR==3{print $3}')

    local mem_used_percent="0.0" mem_available_percent="0.0" swap_used_percent="0.0"
    [[ "$mem_total" -gt 0 ]] && mem_used_percent=$(echo "scale=1; ($mem_used * 100) / $mem_total" | bc)
    [[ "$mem_total" -gt 0 ]] && mem_available_percent=$(echo "scale=1; ($mem_available * 100) / $mem_total" | bc)
    [[ "$swap_total" -gt 0 ]] && swap_used_percent=$(echo "scale=1; ($swap_used * 100) / $swap_total" | bc)

    output_buffer+=$(printf "Total RAM:     %6d MB\n" "$mem_total")
    output_buffer+=$(printf "Used RAM:      %6d MB (%5.1f%%)\n" "$mem_used" "$mem_used_percent")
    output_buffer+=$(printf "Available RAM: %6d MB (%5.1f%%)\n" "$mem_available" "$mem_available_percent")
    output_buffer+=$(printf "Buffers/Cache: %6d MB\n" "$mem_cache")
    output_buffer+="\n"
    output_buffer+=$(printf "Total Swap:    %6d MB\n" "$swap_total")
    output_buffer+=$(printf "Used Swap:     %6d MB (%5.1f%%)\n" "$swap_used" "$swap_used_percent")

    if is_numeric "$swap_used_percent" && (( $(echo "$swap_used_percent > $WARN_SWAP_USAGE" | bc -l) )); then
        warn "Swap Usage (${swap_used_percent}%) exceeds threshold (${WARN_SWAP_USAGE}%)."
    fi
    if is_numeric "$mem_available" && [ "$mem_available" -lt 100 ]; then
         warn "Available RAM (${mem_available}MB) is below 100MB."
    fi
}

collect_disk_io() {
    output_buffer+="\n-------------------- Disk I/O (Device: /dev/$TARGET_DISK) ---------------\n"
    local avg_rs="N/A" avg_ws="N/A" avg_rkBs="N/A" avg_wkBs="N/A" avg_await="N/A" avg_util="N/A"

    if ! command_exists iostat; then
        output_buffer+="$(warn " iostat command not found. Skipping Disk I/O Monitoring.")\n"
    elif [ ! -b "/dev/$TARGET_DISK" ]; then
        output_buffer+="$(warn " Target block device /dev/$TARGET_DISK not found. Skipping Disk I/O Monitoring.")\n"
    else
        info "Running iostat to monitor disk activity..."
        local iostat_output iostat_error=""
        iostat_output=$( (iostat -dx "$TARGET_DISK" "$SAMPLE_INTERVAL" "$SAMPLE_COUNT" 2> >(iostat_error=$(cat); cat >&2)) || true )

        if [[ -n "$iostat_error" ]]; then warn "iostat command produced errors: $iostat_error"; fi

        local parsed_data
        parsed_data=$(echo "$iostat_output" | awk -v dev="$TARGET_DISK" '
            BEGIN { count=0; sum_rs=0; sum_ws=0; sum_rkBs=0; sum_wkBs=0; sum_await=0; sum_util=0; }
            $1 == dev {
                if (NR > 3 && NF >= 14 && $4 ~ /^[0-9.]/ && $5 ~ /^[0-9.]/ && $6 ~ /^[0-9.]/ && $7 ~ /^[0-9.]/ && $10 ~ /^[0-9.]/ && $14 ~ /^[0-9.]/) {
                   sum_rs+=$4; sum_ws+=$5; sum_rkBs+=$6; sum_wkBs+=$7; sum_await+=$10; sum_util+=$14; count++;
                } }
            END { if (count > 0) { printf "%.2f %.2f %.2f %.2f %.2f %.2f", sum_rs/count, sum_ws/count, sum_rkBs/count, sum_wkBs/count, sum_await/count, sum_util/count; } else { print "Error: No parseable data"; } }')

        if [[ "$parsed_data" == *"Error"* ]] || [[ -z "$parsed_data" ]]; then
            warn "Could not get valid iostat data for /dev/$TARGET_DISK. Parsing failed."
        else
            read -r avg_rs avg_ws avg_rkBs avg_wkBs avg_await avg_util <<< "$parsed_data"
            is_numeric "$avg_rs" || avg_rs="N/A"; is_numeric "$avg_ws" || avg_ws="N/A";
            is_numeric "$avg_rkBs" || avg_rkBs="N/A"; is_numeric "$avg_wkBs" || avg_wkBs="N/A";
            is_numeric "$avg_await" || avg_await="N/A"; is_numeric "$avg_util" || avg_util="N/A";
        fi
    fi
    output_buffer+=$(printf "Avg Read IOPS:  %8s r/s\n" "$avg_rs")
    output_buffer+=$(printf "Avg Write IOPS: %8s w/s\n" "$avg_ws")
    output_buffer+=$(printf "Avg Read Speed: %8s kB/s\n" "$avg_rkBs")
    output_buffer+=$(printf "Avg Write Speed:%8s kB/s\n" "$avg_wkBs")
    output_buffer+=$(printf "Avg I/O Wait:   %8s ms (await)\n" "$avg_await")
    output_buffer+=$(printf "Avg Disk Util:  %8s %% \n" "$avg_util")

    if is_numeric "$avg_util" && (( $(echo "$avg_util > $WARN_DISK_UTIL" | bc -l) )); then warn "Disk Utilization (${avg_util}%) exceeds threshold (${WARN_DISK_UTIL}%)."; fi
    if is_numeric "$avg_await" && (( $(echo "$avg_await > $WARN_DISK_AWAIT" | bc -l) )); then warn "Disk Average I/O Wait (${avg_await}ms) exceeds threshold (${WARN_DISK_AWAIT}ms)."; fi
}

run_fio_test() {
    local rw_mode="$1" json_out_file="$2" fio_stderr fio_exit_code
    local bw=0 iops=0

    fio_stderr=$($SUDO_CMD fio --name="vm_perf_${rw_mode}" --filename="$FIO_TEST_FILE" --size="$FIO_SIZE" \
        --runtime="${FIO_RUNTIME}s" --ramp_time="${FIO_RAMP_TIME}s" --time_based --direct=1 \
        --verify=0 --bs=4k --ioengine=libaio --iodepth=64 --numjobs=1 \
        --group_reporting --output-format=json --output="$json_out_file" \
        --rw="$rw_mode" 2>&1)
    fio_exit_code=$?

    if [ $fio_exit_code -ne 0 ]; then warn "FIO test ($rw_mode) failed (Exit Code: $fio_exit_code). Stderr: $fio_stderr"; echo "0 0"; return 1; fi

    if [[ ! -f "$json_out_file" ]] || [[ ! -r "$json_out_file" ]]; then warn "FIO output file $json_out_file not found or not readable for $rw_mode."; echo "0 0"; return 1; fi

    local parse_field_bw parse_field_iops
    if [[ "$rw_mode" == *"read"* ]]; then parse_field_bw=".jobs[0].read.bw"; parse_field_iops=".jobs[0].read.iops";
    else parse_field_bw=".jobs[0].write.bw"; parse_field_iops=".jobs[0].write.iops"; fi

    bw=$(jq -r "$parse_field_bw // 0" "$json_out_file" 2>/dev/null || echo 0)
    iops=$(jq -r "$parse_field_iops // 0" "$json_out_file" 2>/dev/null || echo 0)

    bw=$(printf "%.1f" "$bw"); iops=$(printf "%.1f" "$iops");
    echo "$bw $iops"; return 0;
}

collect_fio_benchmark() {
    output_buffer+="\n-------------------- Disk Benchmark (using FIO ${fio_version}) -----------\n"
    local seq_write_bw="0.0" seq_write_iops="0.0" seq_read_bw="0.0" seq_read_iops="0.0"
    local rand_write_bw="0.0" rand_write_iops="0.0" rand_read_bw="0.0" rand_read_iops="0.0"
    local fio_error_flag=0

    if ! command_exists fio; then output_buffer+="$(warn " FIO command not found. Skipping FIO benchmark.")\n"; fio_error_flag=1;
    elif [ ! -d "$FIO_TEST_DIR" ] || [ ! -w "$FIO_TEST_DIR" ]; then output_buffer+="$(warn " FIO test directory '$FIO_TEST_DIR' does not exist or is not writable. Skipping.")\n"; fio_error_flag=1;
    else
        info "Preparing FIO test file: $FIO_TEST_FILE (Size: $FIO_SIZE)"; info "Running FIO benchmarks (runtime=${FIO_RUNTIME}s, ramp_time=${FIO_RAMP_TIME}s)...";
        local json_out_sw="/tmp/fio_sw.json" json_out_sr="/tmp/fio_sr.json"; local json_out_rw="/tmp/fio_rw.json" json_out_rr="/tmp/fio_rr.json";

        read -r seq_write_bw seq_write_iops < <(run_fio_test write "$json_out_sw") || fio_error_flag=1
        read -r seq_read_bw seq_read_iops < <(run_fio_test read "$json_out_sr") || fio_error_flag=1
        read -r rand_write_bw rand_write_iops < <(run_fio_test randwrite "$json_out_rw") || fio_error_flag=1
        read -r rand_read_bw rand_read_iops < <(run_fio_test randread "$json_out_rr") || fio_error_flag=1;
    fi

    if [ $fio_error_flag -eq 0 ]; then
        output_buffer+=$(printf "Seq. Write: %8.1f KiB/s, %8.1f IOPS\n" "$seq_write_bw" "$seq_write_iops")
        output_buffer+=$(printf "Seq. Read:  %8.1f KiB/s, %8.1f IOPS\n" "$seq_read_bw" "$seq_read_iops")
        output_buffer+=$(printf "Rand. Write:%8.1f KiB/s, %8.1f IOPS\n" "$rand_write_bw" "$rand_write_iops")
        output_buffer+=$(printf "Rand. Read: %8.1f KiB/s, %8.1f IOPS\n" "$rand_read_bw" "$rand_read_iops")
        output_buffer+="\n(Benchmark results depend heavily on storage type, hypervisor, workload, etc.)\n";
    else output_buffer+="(FIO benchmark encountered errors, was skipped, or produced zero results.)\n"; fi
}

collect_net_io() {
    output_buffer+="\n-------------------- Network I/O --------------------\n"
    local rx_kBs="N/A" tx_kBs="N/A" rx_errs_int="0" tx_errs_int="0" rx_drop_int="0" tx_drop_int="0"
    local net_interfaces first_iface sar_output sar_error=""

    if ! command_exists sar; then output_buffer+="$(warn " sar command not found. Skipping Network I/O.")\n"; return; fi

    net_interfaces=$(ip -o link show | awk -F': ' '!/lo/ {print $2}')
    if [ -z "$net_interfaces" ]; then output_buffer+="$(warn " No active non-loopback network interfaces found.")\n"; return; fi

    first_iface=$(echo "$net_interfaces" | head -n 1)
    output_buffer+=$(printf "Monitoring interface: %s (Primary)\n" "$first_iface"); info "Running sar to monitor network activity...";
    sar_output=$( (sar -n DEV "$SAMPLE_INTERVAL" $((SAMPLE_COUNT - 1)) 2> >(sar_error=$(cat); cat >&2)) || true )
    if [[ -n "$sar_error" ]]; then warn "sar command produced errors: $sar_error"; fi

    local parsed_data
    parsed_data=$(echo "$sar_output" | grep Average | grep "$first_iface")

    if [ -n "$parsed_data" ]; then
        local rx_kBs_raw tx_kBs_raw rx_errs_raw tx_errs_raw rx_drop_raw tx_drop_raw
        read -r rx_kBs_raw tx_kBs_raw rx_errs_raw tx_errs_raw rx_drop_raw tx_drop_raw <<< $(echo "$parsed_data" | awk '{print $5, $6, $9, $10, $11, $12}')
        is_numeric "$rx_kBs_raw" && rx_kBs=$(printf "%.2f" "$rx_kBs_raw") || rx_kBs="N/A"
        is_numeric "$tx_kBs_raw" && tx_kBs=$(printf "%.2f" "$tx_kBs_raw") || tx_kBs="N/A"
        rx_errs_int=$(to_int "$rx_errs_raw"); tx_errs_int=$(to_int "$tx_errs_raw");
        rx_drop_int=$(to_int "$rx_drop_raw"); tx_drop_int=$(to_int "$tx_drop_raw");
        if [[ "$rx_errs_int" -ge "$WARN_NET_ERRORS" ]] || [[ "$tx_errs_int" -ge "$WARN_NET_ERRORS" ]] || \
           [[ "$rx_drop_int" -ge "$WARN_NET_ERRORS" ]] || [[ "$tx_drop_int" -ge "$WARN_NET_ERRORS" ]]; then
             warn "Network errors or drops detected on interface $first_iface (Errors: ${rx_errs_int}/${tx_errs_int}, Drops: ${rx_drop_int}/${tx_drop_int})."; fi
    else warn "Could not get sar data average for interface $first_iface."; fi
    output_buffer+=$(printf "Avg RX Speed:   %8s kB/s\n" "$rx_kBs")
    output_buffer+=$(printf "Avg TX Speed:   %8s kB/s\n" "$tx_kBs")
    output_buffer+=$(printf "Errors (RX/TX): %d / %d\n" "$rx_errs_int" "$tx_errs_int")
    output_buffer+=$(printf "Drops (RX/TX):  %d / %d\n" "$rx_drop_int" "$tx_drop_int")
}

collect_net_latency() {
    output_buffer+="\n-------------------- Network Latency --------------------\n"
    local ping_avg="N/A" ping_output ping_error=""

    info "Pinging $PING_TARGET ($PING_COUNT times)...";
    ping_output=$(ping -c "$PING_COUNT" -W 1 "$PING_TARGET" 2> >(ping_error=$(cat); cat >&2)) || true

    if [[ -n "$ping_error" ]]; then if [[ $ping_error == *"unknown host"* ]]; then warn "Could not resolve host: $PING_TARGET."; output_buffer+="Result: Unknown Host\n"; return; fi; fi
    if [[ $ping_output == *"100% packet loss"* ]]; then warn "100% packet loss when pinging $PING_TARGET."; output_buffer+="Result: 100% Packet Loss\n";
    elif [[ $ping_output == *"rtt min/avg/max/mdev"* ]]; then
        ping_avg=$(echo "$ping_output" | tail -n 1 | awk -F'/' '{print $5}')
        if is_numeric "$ping_avg"; then
            output_buffer+=$(printf "Avg Latency to %s: %.2f ms\n" "$PING_TARGET" "$ping_avg")
            if (( $(echo "$ping_avg > $WARN_PING_LATENCY" | bc -l) )); then warn "Network Latency (${ping_avg}ms) exceeds threshold (${WARN_PING_LATENCY}ms)."; fi
        else warn "Could not parse average ping time from output."; output_buffer+="Result: Parsing Error\n"; fi
    else warn "Could not get valid ping statistics for $PING_TARGET."; output_buffer+="Result: Unknown Error\n"; fi
}

generate_summary() {
    printf "\n${COLOR_BLUE}==================== Summary =====================${COLOR_NC}\n"
    if [ ${#warnings_list[@]} -eq 0 ]; then
        success "No major performance issues detected based on configured thresholds."
    else
        warn "Potential performance issues detected (${#warnings_list[@]} item(s)):"
        for warning in "${warnings_list[@]}"; do
             printf "${COLOR_YELLOW}- %s${COLOR_NC}\n" "$warning"
        done
    fi
    printf "${COLOR_BLUE}===================================================${COLOR_NC}\n"
}


# --- Main Execution ---
output_buffer="" # Reset buffer

info "Gathering Basic System Info..."
printf "-------------------- System Info --------------------\n"
collect_os_info
printf "%-18s %s\n" "Hostname:" "$(hostname)"
# FIX: Use specific date format to avoid issues with printf interpreting '-' as option
printf "%-18s %s\n" "Date:" "$(date +"%Y-%m-%d %H:%M:%S %Z")"
echo ""

info "Starting performance checks..."
collect_cpu_info
collect_mem_info
collect_disk_io
collect_fio_benchmark
collect_net_io
collect_net_latency

info "Performance Check Complete. Results:"
echo ""
printf "%b" "$output_buffer" # Print the buffer

generate_summary # Generate and print summary

exit 0
