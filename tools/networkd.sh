#!/bin/bash

# Network Throttling Detection Script for Ubuntu
# Monitors network speed, latency, packet loss, and compares with speedtest to detect throttling
# Output: /var/log/network_throttle.log
#
# Usage:
#   1. Save this script as networkd.sh and make it executable:
#      chmod +x networkd.sh
#   2. Run the script as root to start monitoring:
#      sudo ./networkd.sh [-i <interval_seconds>]
#   3. Options:
#      -h              Show this help message
#      -r              Stop the running monitoring process
#      -l              View log in real-time
#      -i <seconds>    Set monitoring interval (default: 60 seconds)
#   4. Stop monitoring:
#      sudo ./networkd.sh -r
#   5. View log:
#      cat /var/log/network_throttle.log  # Full log
#      sudo ./networkd.sh -l              # Real-time log
#   6. Monitor process (optional):
#      ps aux | grep networkd.sh
#
# Features:
#   - Monitors continuously until stopped with -r.
#   - Measures download/upload speed (iftop), latency/loss (mtr) every minute, speedtest every hour.
#   - Detects throttling (speed stuck low or low vs. speedtest).
#   - Logs top bandwidth-consuming app (nethogs) when speed is low.
#   - Automatic log rotation to manage disk space.
#   - Summary report (average speed, throttling events) when stopped.
#   - Runs in background, saves PID to /var/run/network_throttle.pid.
#
# Notes:
#   - Requires root (sudo) for iftop and package installation.
#   - Needs internet for installing tools (iftop, bc, speedtest-cli, mtr, nethogs) and speedtest.
#   - Log (~200 KB/day) stored at /var/log/network_throttle.log.
#   - Check "Status" column for errors (e.g., "mtr failed", "No traffic").

# Configuration
LOG_FILE="/var/log/network_throttle.log"
PID_FILE="/var/run/network_throttle.pid"
INTERVAL=60  # Default: Check every 1 minute (60 seconds)
SAMPLE_TIME=15  # Sample network speed for 15 seconds
SPEEDTEST_INTERVAL=$((60*60))  # Run speedtest every 1 hour
THROTTLE_THRESHOLD=10  # Detect throttling if speed stuck below 10 Mbps for 10 checks
THROTTLE_COUNT=0  # Counter for throttling detection
SUMMARY_FILE="/tmp/network_throttle_summary.txt"  # Temporary file for summary
NETHOGS_THRESHOLD=5  # Check nethogs if download speed below 5 Mbps

# Function to show help message
show_help() {
    echo "Network Throttling Detection Script"
    echo "Usage: sudo $0 [options]"
    echo "Options:"
    echo "  -h              Show this help message"
    echo "  -r              Stop the running monitoring process"
    echo "  -l              View log in real-time"
    echo "  -i <seconds>    Set monitoring interval (default: 60 seconds)"
    echo "Examples:"
    echo "  sudo $0                # Start monitoring with default 60s interval"
    echo "  sudo $0 -i 120         # Start monitoring with 120s interval"
    echo "  sudo $0 -r             # Stop monitoring"
    echo "  sudo $0 -l             # View log in real-time"
    echo "Log file: $LOG_FILE"
    echo "PID file: $PID_FILE"
    exit 0
}

# Function to install required packages
install_dependencies() {
    echo "Installing dependencies..." >> "$LOG_FILE"
    apt-get update -y >> "$LOG_FILE" 2>&1
    for pkg in iftop bc speedtest-cli mtr nethogs; do
        if ! command -v "${pkg/-cli/}" &> /dev/null; then
            echo "Installing $pkg..." >> "$LOG_FILE"
            apt-get install -y "$pkg" >> "$LOG_FILE" 2>&1
            if [[ $? -ne 0 ]]; then
                echo "Error: Failed to install $pkg." >> "$LOG_FILE"
                exit 1
            fi
        fi
    done
}

# Function to detect active network interface
detect_interface() {
    INTERFACES=$(ip link | grep -v 'lo:' | grep 'state UP' | awk -F': ' '{print $2}' | tr -d ' ')
    if [[ -z "$INTERFACES" ]]; then
        echo "Error: No active network interface found." >> "$LOG_FILE"
        exit 1
    fi
    echo "$INTERFACES" | head -n 1
}

# Function to check network connectivity
check_connectivity() {
    mtr -c 2 -r 1.1.1.1 >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        echo "Warning: No internet connectivity detected (mtr to 1.1.1.1 failed)." >> "$LOG_FILE"
        return 1
    fi
    return 0
}

# Function to check interface traffic
check_interface_traffic() {
    local iface="$1"
    ip -s link show "$iface" 2>/dev/null | grep -A 2 "$iface" | grep -E 'RX.*bytes|TX.*bytes' >> "$LOG_FILE"
}

# Function to run speedtest and extract results
run_speedtest() {
    if ! check_connectivity; then
        echo "0.00/0.00/0.00"
        return
    fi
    SPEEDTEST_OUTPUT=$(speedtest-cli --simple 2>/dev/null)
    if [[ -z "$SPEEDTEST_OUTPUT" ]]; then
        echo "Error: speedtest-cli failed at $(date '+%Y-%m-%d %H:%M:%S')." >> "$LOG_FILE"
        echo "0.00/0.00/0.00"
        return
    fi
    DOWNLOAD=$(echo "$SPEEDTEST_OUTPUT" | grep Download | awk '{print $2}' | grep -E '^[0-9.]+$' || echo "0.00")
    UPLOAD=$(echo "$SPEEDTEST_OUTPUT" | grep Upload | awk '{print $2}' | grep -E '^[0-9.]+$' || echo "0.00")
    PING=$(echo "$SPEEDTEST_OUTPUT" | grep Ping | awk '{print $2}' | grep -E '^[0-9.]+$' || echo "0.00")
    echo "$DOWNLOAD/$UPLOAD/$PING"
}

# Function to run nethogs and get top bandwidth-consuming app
run_nethogs() {
    NETHOGS_OUTPUT=$(timeout 5 nethogs "$INTERFACE" -t 2>/dev/null | grep -v "Refreshing" | head -n 1)
    if [[ -n "$NETHOGS_OUTPUT" ]]; then
        echo "$NETHOGS_OUTPUT" | awk '{print $1}' | cut -d'/' -f1 | tr -d '\n'
    else
        echo "N/A"
    fi
}

# Function to setup log rotation
setup_log_rotation() {
    local ROTATE_CONF="/etc/logrotate.d/network_throttle"
    if [[ ! -f "$ROTATE_CONF" ]]; then
        echo "$LOG_FILE {
    daily
    rotate 7
    compress
    missingok
    notifempty
    create 644 root root
}" > "$ROTATE_CONF"
        logrotate -f "$ROTATE_CONF" 2>> "$LOG_FILE"
    fi
}

# Function to stop running process
stop_process() {
    if [[ -f "$PID_FILE" ]]; then
        PID=$(cat "$PID_FILE")
        if ps -p "$PID" > /dev/null; then
            echo "Stopping process with PID $PID..."
            kill "$PID"
            if [[ $? -eq 0 ]]; then
                echo "Process stopped successfully."
                rm -f "$PID_FILE"
                # Generate summary report
                if [[ -f "$LOG_FILE" ]]; then
                    TOTAL_LINES=$(grep -v '^-' "$LOG_FILE" | grep -v '^Network' | grep -v '^Generated' | grep -v '^Interval' | grep -v '^Monitoring' | grep -v '^Warning' | wc -l)
                    if [[ $TOTAL_LINES -gt 0 ]]; then
                        AVG_DOWN=$(awk '{sum+=$2} END {if (NR>0) print sum/NR}' "$LOG_FILE" | grep -v '^-' | grep -v '^Network' | grep -v '^Generated' | grep -v '^Interval' | grep -v '^Monitoring' | grep -v '^Warning')
                        AVG_UP=$(awk '{sum+=$3} END {if (NR>0) print sum/NR}' "$LOG_FILE" | grep -v '^-' | grep -v '^Network' | grep -v '^Generated' | grep -v '^Interval' | grep -v '^Monitoring' | grep -v '^Warning')
                        THROTTLE_EVENTS=$(grep "Possible throttling detected" "$LOG_FILE" | wc -l)
                        echo "Summary Report:" > "$SUMMARY_FILE"
                        echo "Monitoring duration: $((TOTAL_LINES * INTERVAL / 3600)) hours" >> "$SUMMARY_FILE"
                        echo "Average Download: $(printf "%.2f" "$AVG_DOWN") Mbps" >> "$SUMMARY_FILE"
                        echo "Average Upload: $(printf "%.2f" "$AVG_UP") Mbps" >> "$SUMMARY_FILE"
                        echo "Throttling events detected: $THROTTLE_EVENTS" >> "$SUMMARY_FILE"
                        echo "Summary saved to $SUMMARY_FILE"
                        cat "$SUMMARY_FILE"
                    fi
                fi
            else
                echo "Error: Failed to stop process with PID $PID."
                exit 1
            fi
        else
            echo "No running process found with PID $PID."
            rm -f "$PID_FILE"
        fi
    else
        echo "No PID file found. No running process."
    fi
    exit 0
}

# Function to view log in real-time
view_log_realtime() {
    if [[ -f "$LOG_FILE" ]]; then
        tail -f "$LOG_FILE"
    else
        echo "Error: Log file $LOG_FILE does not exist."
        exit 1
    fi
}

# Parse command-line options
while getopts "hrli:" opt; do
    case $opt in
        h) show_help ;;
        r) stop_process ;;
        l) view_log_realtime ;;
        i) INTERVAL="$OPTARG"
           if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || [[ "$INTERVAL" -lt 10 ]]; then
               echo "Error: Interval must be a number >= 10 seconds."
               exit 1
           fi ;;
        *) echo "Invalid option. Use -h for help."
           exit 1 ;;
    esac
done

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (sudo)." >> "$LOG_FILE"
    exit 1
fi

# Create log file and set permissions
if [[ ! -f "$LOG_FILE" ]]; then
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
fi

# Install dependencies
install_dependencies

# Setup log rotation
setup_log_rotation

# Detect network interface
INTERFACE=$(detect_interface)
echo "Using network interface: $INTERFACE" >> "$LOG_FILE"

# Check network connectivity and interface traffic
check_connectivity || echo "Starting monitoring despite no internet connectivity." >> "$LOG_FILE"
echo "Interface traffic stats before starting:" >> "$LOG_FILE"
check_interface_traffic "$INTERFACE"

# Write log header
echo "Network Throttling Detection Log - Interface: $INTERFACE" > "$LOG_FILE"
echo "Generated on: $(date '+%Y-%m-%d %H:%M:%S %Z')" >> "$LOG_FILE"
echo "Interval: $INTERVAL seconds" >> "$LOG_FILE"
echo "-------------------------------------------------------------" >> "$LOG_FILE"
printf "%-20s %-15s %-15s %-15s %-10s %-15s %-15s %-30s %-15s\n" \
    "Timestamp" "Down (Mbps)" "Up (Mbps)" "Latency (ms)" "Loss (%)" "Speedtest Down" "Speedtest Up" "Top App" "Status" >> "$LOG_FILE"
echo "-------------------------------------------------------------" >> "$LOG_FILE"

# Run monitoring in background
{
    LAST_SPEEDTEST=0
    LAST_DOWN=0
    TOTAL_DOWN=0
    TOTAL_UP=0
    CHECK_COUNT=0

    while true; do
        START_TIME=$(date +%s)
        TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
        STATUS="OK"

        # Run iftop for network speed
        IFTOP_OUTPUT=$(iftop -t -s $SAMPLE_TIME -i "$INTERFACE" 2>/dev/null)
        if [[ -z "$IFTOP_OUTPUT" ]]; then
            echo "Warning: iftop failed to retrieve data at $TIMESTAMP" >> "$LOG_FILE"
            DOWNLOAD="0"
            UPLOAD="0"
            STATUS="iftop failed"
        else
            DOWNLOAD=$(echo "$IFTOP_OUTPUT" | grep -A 2 "Total send and receive rate" | tail -n 1 | awk '{print $1}' | tr -d '[:alpha:]' | grep -E '^[0-9.]+$' || echo "0")
            UPLOAD=$(echo "$IFTOP_OUTPUT" | grep -A 2 "Total send rate" | tail -n 1 | awk '{print $1}' | tr -d '[:alpha:]' | grep -E '^[0-9.]+$' || echo "0")
        fi

        # Convert speeds to Mbps
        if [[ -n "$DOWNLOAD" && "$DOWNLOAD" != "0" ]]; then
            if [[ "$IFTOP_OUTPUT" =~ "Kb" ]]; then
                DOWNLOAD=$(echo "$DOWNLOAD / 1000" | bc -l)
            elif [[ "$IFTOP_OUTPUT" =~ "Gb" ]]; then
                DOWNLOAD=$(echo "$DOWNLOAD * 1000" | bc -l)
            fi
        else
            DOWNLOAD="0"
            [[ "$STATUS" == "OK" && "$DOWNLOAD" == "0" ]] && STATUS="No traffic"
        fi
        if [[ -n "$UPLOAD" && "$UPLOAD" != "0" ]]; then
            if [[ "$IFTOP_OUTPUT" =~ "Kb" ]]; then
                UPLOAD=$(echo "$UPLOAD / 1000" | bc -l)
            elif [[ "$IFTOP_OUTPUT" =~ "Gb" ]]; then
                UPLOAD=$(echo "$UPLOAD * 1000" | bc -l)
            fi
        else
            UPLOAD="0"
        fi
        DOWNLOAD=$(printf "%.2f" "$DOWNLOAD")
        UPLOAD=$(printf "%.2f" "$UPLOAD")

        # Run mtr for latency and packet loss
        MTR_OUTPUT=$(mtr -c 10 -r 1.1.1.1 2>/dev/null | grep -E '^\s*1\.' | head -n 1)
        if [[ -z "$MTR_OUTPUT" ]]; then
            echo "Warning: mtr failed to retrieve data at $TIMESTAMP (tried 1.1.1.1)" >> "$LOG_FILE"
            LATENCY="N/A"
            LOSS="N/A"
            [[ "$STATUS" == "OK" ]] && STATUS="mtr failed"
        else
            LATENCY=$(echo "$MTR_OUTPUT" | awk '{print $6}' | grep -E '^[0-9.]+$' || echo "N/A")
            LOSS=$(echo "$MTR_OUTPUT" | awk '{print $3}' | tr -d '%' | grep -E '^[0-9.]+$' || echo "N/A")
            if [[ "$LATENCY" == "N/A" || "$LOSS" == "N/A" ]]; then
                echo "Warning: mtr output invalid at $TIMESTAMP" >> "$LOG_FILE"
                [[ "$STATUS" == "OK" ]] && STATUS="mtr invalid"
            fi
        fi

        # Run nethogs if speed is low
        TOP_APP="N/A"
        if [[ $(echo "$DOWNLOAD > 0 && $DOWNLOAD < $NETHOGS_THRESHOLD" | bc -l) -eq 1 ]]; then
            TOP_APP=$(run_nethogs)
        fi

        # Run speedtest every hour
        SPEEDTEST_DOWN="N/A"
        SPEEDTEST_UP="N/A"
        if [[ $((CHECK_COUNT * INTERVAL)) -ge $LAST_SPEEDTEST ]]; then
            SPEEDTEST_RESULT=$(run_speedtest)
            SPEEDTEST_DOWN=$(echo "$SPEEDTEST_RESULT" | cut -d'/' -f1)
            SPEEDTEST_UP=$(echo "$SPEEDTEST_RESULT" | cut -d'/' -f2)
            LAST_SPEEDTEST=$((LAST_SPEEDTEST + SPEEDTEST_INTERVAL))
            # Compare iftop with speedtest
            if [[ "$SPEEDTEST_DOWN" != "0.00" && $(echo "$DOWNLOAD < $SPEEDTEST_DOWN * 0.5" | bc -l) -eq 1 ]]; then
                [[ "$STATUS" == "OK" || "$STATUS" == "No traffic" ]] && STATUS="Low speed vs. speedtest"
            fi
        fi

        # Detect throttling (speed stuck below threshold)
        if [[ $(echo "$DOWNLOAD > 0 && $DOWNLOAD < $THROTTLE_THRESHOLD" | bc -l) -eq 1 && \
              $(echo "$LAST_DOWN > 0 && $LAST_DOWN < $THROTTLE_THRESHOLD" | bc -l) -eq 1 && \
              $(echo "$DOWNLOAD - $LAST_DOWN < 0.5 && $LAST_DOWN - $DOWNLOAD < 0.5" | bc -l) -eq 1 ]]; then
            THROTTLE_COUNT=$((THROTTLE_COUNT + 1))
            if [[ $THROTTLE_COUNT -ge 10 ]]; then
                [[ "$STATUS" == "OK" || "$STATUS" == "No traffic" || "$STATUS" == "Low speed vs. speedtest" ]] && STATUS="Possible throttling detected"
            fi
        else
            THROTTLE_COUNT=0
        fi
        LAST_DOWN=$DOWNLOAD

        # Update summary data
        if [[ "$DOWNLOAD" != "0" ]]; then
            TOTAL_DOWN=$(echo "$TOTAL_DOWN + $DOWNLOAD" | bc -l)
            TOTAL_UP=$(echo "$TOTAL_UP + $UPLOAD" | bc -l)
            CHECK_COUNT=$((CHECK_COUNT + 1))
        fi

        # Write to log with safe printf
        printf "%-20s %-15s %-15s %-15s %-10s %-15s %-15s %-30s %-15s\n" \
            "$TIMESTAMP" "$DOWNLOAD" "$UPLOAD" "$LATENCY" "$LOSS" "$SPEEDTEST_DOWN" "$SPEEDTEST_UP" "$TOP_APP" "$STATUS" >> "$LOG_FILE" 2>/dev/null

        # Precise sleep to maintain interval
        END_TIME=$(date +%s)
        ELAPSED=$((END_TIME - START_TIME))
        SLEEP_TIME=$((INTERVAL - ELAPSED))
        [[ $SLEEP_TIME -gt 0 ]] && sleep $SLEEP_TIME
    done
} &

# Save PID to file
PID=$!
echo "$PID" > "$PID_FILE"
echo "Network throttling detection started in background (PID: $PID). Log saved to $LOG_FILE."
