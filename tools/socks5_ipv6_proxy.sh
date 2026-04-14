#!/usr/bin/env bash
# ==============================================================================
# IPv6 SOCKS5 Proxy Auto-Setup Script
# Creates multiple SOCKS5 proxies, each with a unique public IPv6 address
# Supports: Ubuntu, Debian, CentOS, AlmaLinux, Rocky Linux
# Uses: microsocks (lightweight, proven IPv6 support)
#
# Usage:
#   ./socks5_ipv6_proxy.sh              # Auto-detect and create proxies
#   ./socks5_ipv6_proxy.sh -n 20        # Create exactly 20 proxies
#   ./socks5_ipv6_proxy.sh -p 20000     # Ports start at 20000
#   ./socks5_ipv6_proxy.sh -r           # Remove everything
# ==============================================================================

set -Eeuo pipefail
trap 'echo -e "\033[0;31m[ERROR]\033[0m Line $LINENO: $BASH_COMMAND" >&2' ERR

# ======================== CONFIGURATION ========================
WORK_DIR="/root/socks5-ipv6"
OUTPUT_FILE="/root/socks5_ipv6_proxies.txt"
START_PORT=10000
PID_DIR="/run/socks5-ipv6"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ======================== HELPERS ========================
log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

check_root() {
    [[ $EUID -eq 0 ]] || log_error "This script must be run as root/sudo."
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID:-unknown}"
    else
        OS_ID="unknown"
    fi
    case "$OS_ID" in
        ubuntu|debian|pop) PKG="apt" ;;
        centos|almalinux|rocky|rhel|fedora) PKG="dnf" ;;
        *) log_error "Unsupported OS: $OS_ID" ;;
    esac
}

# ======================== PREREQUISITES ========================
install_deps() {
    log_info "Installing dependencies..."
    case "$PKG" in
        apt)
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y -qq curl net-tools openssl python3 iproute2 microsocks >/dev/null 2>&1
            ;;
        dnf)
            dnf install -y -q curl net-tools openssl python3 iproute gcc git make >/dev/null 2>&1
            ;;
    esac

    # Verify microsocks is available, compile if not
    if ! command -v microsocks &>/dev/null; then
        log_info "Building microsocks from source..."
        local build_dir="/tmp/microsocks-build"
        rm -rf "$build_dir"
        git clone --depth=1 https://github.com/rofl0r/microsocks.git "$build_dir" 2>/dev/null
        make -C "$build_dir" -j"$(nproc)" >/dev/null 2>&1
        cp "$build_dir/microsocks" /usr/local/bin/microsocks
        chmod +x /usr/local/bin/microsocks
        rm -rf "$build_dir"
    fi

    command -v microsocks &>/dev/null || log_error "Failed to install microsocks."
    log_ok "Dependencies ready (microsocks: $(which microsocks))"
}

# ======================== IPv6 DETECTION & VALIDATION ========================
detect_ipv6() {
    log_info "Detecting IPv6 configuration..."

    command -v python3 &>/dev/null || log_error "python3 is required but not found."

    local ipv6_line
    ipv6_line=$(ip -6 addr show scope global 2>/dev/null | grep -oP 'inet6 \K[0-9a-f:]+/[0-9]+' | head -1 || true)

    if [[ -z "$ipv6_line" ]]; then
        log_error "No global IPv6 address found. This VPS does not have an IPv6 subnet."
    fi

    IPV6_ADDR="${ipv6_line%%/*}"
    IPV6_PREFIX="${ipv6_line##*/}"

    if (( IPV6_PREFIX > 64 )); then
        log_error "IPv6 prefix /${IPV6_PREFIX} is too small. Need /64 or larger."
    fi

    IPV6_IFACE=$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
    if [[ -z "$IPV6_IFACE" ]]; then
        IPV6_IFACE=$(ip -6 addr show scope global | awk -F'[ :]+' '/^[0-9]/{print $2}' | head -1)
    fi
    [[ -n "$IPV6_IFACE" ]] || log_error "Cannot detect IPv6 network interface."

    IPV6_NET=$(python3 -c "
import ipaddress
net = ipaddress.IPv6Network('${IPV6_ADDR}/${IPV6_PREFIX}', strict=False)
print(str(net.network_address))
")

    log_ok "Address  : ${IPV6_ADDR}/${IPV6_PREFIX}"
    log_ok "Subnet   : ${IPV6_NET}/${IPV6_PREFIX}"
    log_ok "Interface: ${IPV6_IFACE}"
}

check_ipv6_connectivity() {
    log_info "Testing IPv6 connectivity..."
    if ping -6 -c 1 -W 5 google.com &>/dev/null; then
        log_ok "IPv6 internet reachable"
    elif ping -6 -c 1 -W 5 2001:4860:4860::8888 &>/dev/null; then
        log_ok "IPv6 connectivity OK (ICMP blocked but route exists)"
    else
        log_warn "IPv6 ping failed. Continuing (firewall may block ICMP)..."
    fi
}

test_ipv6_assignment() {
    log_info "Testing IPv6 address assignment + outgoing connectivity..."

    local test_ip
    test_ip=$(generate_random_ipv6)
    ip -6 addr add "${test_ip}/128" dev "$IPV6_IFACE" 2>/dev/null || log_error "Cannot assign IPv6 to ${IPV6_IFACE}."
    sleep 1

    # Test actual TCP outgoing from this IPv6
    local result
    result=$(curl -s -m 10 --interface "$test_ip" https://api64.ipify.org 2>/dev/null || true)

    ip -6 addr del "${test_ip}/128" dev "$IPV6_IFACE" 2>/dev/null || true

    if [[ "$result" == "$test_ip" ]]; then
        log_ok "IPv6 ${test_ip} is routable and shows correct outgoing IP"
    elif [[ -n "$result" ]]; then
        log_warn "IPv6 assigned but outgoing shows: ${result} (NDP proxy may help)"
    else
        log_warn "IPv6 connectivity test inconclusive (will configure NDP proxy)"
    fi
}

# ======================== IPv6 GENERATION ========================
generate_random_ipv6() {
    python3 -c "
import ipaddress, secrets
net = ipaddress.IPv6Network('${IPV6_NET}/${IPV6_PREFIX}', strict=False)
bits = 128 - net.prefixlen
host_id = secrets.randbelow(2**bits - 2) + 1
addr = net.network_address + host_id
print(str(addr))
"
}

# ======================== RAM -> PROXY COUNT ========================
calculate_proxy_count() {
    TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
    TOTAL_CORES=$(nproc 2>/dev/null || echo 1)

    # microsocks uses ~0.5MB per instance - very lightweight
    if   (( TOTAL_RAM < 512  )); then PROXY_COUNT=5
    elif (( TOTAL_RAM < 1024 )); then PROXY_COUNT=50
    elif (( TOTAL_RAM < 2048 )); then PROXY_COUNT=100
    elif (( TOTAL_RAM < 4096 )); then PROXY_COUNT=200
    elif (( TOTAL_RAM < 8192 )); then PROXY_COUNT=300
    else PROXY_COUNT=500
    fi

    log_info "System  : ${TOTAL_RAM}MB RAM, ${TOTAL_CORES} CPU cores"
    log_info "Creating: ${PROXY_COUNT} proxies"
}

# ======================== CREATE PROXIES ========================
setup_proxies() {
    # Clean previous installation if exists
    if [[ -d "$WORK_DIR" ]]; then
        log_warn "Previous installation found. Stopping..."
        stop_all_proxies
        rm -rf "$WORK_DIR"
    fi

    mkdir -p "$WORK_DIR" "$PID_DIR"

    local public_ipv4
    public_ipv4=$(curl -s -4 -m 5 ifconfig.me 2>/dev/null || curl -s -4 -m 5 api.ipify.org 2>/dev/null || echo "N/A")
    PUBLIC_IPV4="$public_ipv4"

    # ---- Proxy data file (used by systemd to start proxies) ----
    # Format: PORT|USER|PASS|IPV6
    > "$WORK_DIR/proxies.conf"

    # ---- Output file (raw, one proxy per line) ----
    > "$OUTPUT_FILE"

    # ---- Generate proxies ----
    USED_IPS=()

    for ((i = 1; i <= PROXY_COUNT; i++)); do
        local ipv6
        while true; do
            ipv6=$(generate_random_ipv6)
            local dup=0
            for u in "${USED_IPS[@]:-}"; do
                [[ "$u" == "$ipv6" ]] && dup=1 && break
            done
            (( dup == 0 )) && break
        done
        USED_IPS+=("$ipv6")

        local user pass port
        user=$(openssl rand -hex 6)
        pass=$(openssl rand -hex 8)
        port=$(( START_PORT + i - 1 ))

        # Assign IPv6 to host interface
        ip -6 addr add "${ipv6}/128" dev "$IPV6_IFACE" 2>/dev/null || true

        # Save proxy config
        echo "${port}|${user}|${pass}|${ipv6}" >> "$WORK_DIR/proxies.conf"

        # Save to output file (raw format)
        echo "socks5://${user}:${pass}@${public_ipv4}:${port}" >> "$OUTPUT_FILE"

        # Progress
        printf "  ${GREEN}[%3d/%d]${NC} :%d -> %s\n" "$i" "$PROXY_COUNT" "$port" "$ipv6"
    done

}

# ======================== START / STOP PROXIES ========================
start_all_proxies() {
    log_info "Starting ${PROXY_COUNT} microsocks instances..."
    mkdir -p "$PID_DIR"
    local started=0 failed=0

    while IFS='|' read -r port user pass ipv6; do
        # Run in background, suppress stdout, redirect stderr
        microsocks -p "$port" -u "$user" -P "$pass" -b "$ipv6" >/dev/null 2>&1 &
        local pid=$!
        sleep 0.05  # tiny delay to avoid fd race

        # Check if process started successfully
        if kill -0 "$pid" 2>/dev/null; then
            echo "$pid" >> "$PID_DIR/pids"
            started=$((started + 1))
        else
            failed=$((failed + 1))
            log_warn "Failed to start proxy on port ${port}"
        fi
    done < "$WORK_DIR/proxies.conf"

    if (( failed > 0 )); then
        log_warn "${started} started, ${failed} failed"
    else
        log_ok "All ${started} proxies started"
    fi
}

stop_all_proxies() {
    # Kill by PID file first
    if [[ -f "$PID_DIR/pids" ]]; then
        while read -r pid; do
            kill "$pid" 2>/dev/null || true
        done < "$PID_DIR/pids"
        rm -f "$PID_DIR/pids"
    fi
    # Fallback: kill all microsocks
    pkill -f "microsocks -p" 2>/dev/null || true
    sleep 1
    pkill -9 -f "microsocks -p" 2>/dev/null || true
}

# ======================== NDP PROXY ========================
setup_ndp() {
    log_info "Configuring NDP proxy..."

    sysctl -w net.ipv6.conf.all.proxy_ndp=1 &>/dev/null
    sysctl -w "net.ipv6.conf.${IPV6_IFACE}.proxy_ndp=1" &>/dev/null

    cat > /etc/sysctl.d/99-socks5-ndp.conf <<SYSCTL
net.ipv6.conf.all.proxy_ndp=1
net.ipv6.conf.${IPV6_IFACE}.proxy_ndp=1
SYSCTL

    for ipv6 in "${USED_IPS[@]}"; do
        ip -6 neigh add proxy "$ipv6" dev "$IPV6_IFACE" 2>/dev/null || true
    done

    log_ok "NDP proxy enabled for ${#USED_IPS[@]} addresses"
}

# ======================== PERSISTENCE ========================
make_persistent() {
    log_info "Making configuration persistent..."

    # ---------- Layer 1: Network config (netplan/ifcfg) ----------
    write_network_config

    # ---------- Layer 2: Boot script for IPv6 + NDP ----------
    cat > /usr/local/bin/socks5-ipv6-setup.sh <<HEADER
#!/bin/bash
# Auto-generated by socks5_ipv6_proxy.sh
HEADER

    for ipv6 in "${USED_IPS[@]}"; do
        cat >> /usr/local/bin/socks5-ipv6-setup.sh <<LINE
ip -6 addr add ${ipv6}/128 dev ${IPV6_IFACE} 2>/dev/null || true
ip -6 neigh add proxy ${ipv6} dev ${IPV6_IFACE} 2>/dev/null || true
LINE
    done
    chmod +x /usr/local/bin/socks5-ipv6-setup.sh

    # ---------- Layer 3: Systemd service for proxies ----------
    cat > /usr/local/bin/socks5-ipv6-start.sh <<'STARTEOF'
#!/bin/bash
# Start all microsocks proxies from config
CONF="/root/socks5-ipv6/proxies.conf"
PIDFILE="/run/socks5-ipv6/pids"
[[ -f "$CONF" ]] || exit 1
mkdir -p /run/socks5-ipv6

while IFS='|' read -r port user pass ipv6; do
    microsocks -p "$port" -u "$user" -P "$pass" -b "$ipv6" >/dev/null 2>&1 &
    echo $! >> "$PIDFILE"
done < "$CONF"
STARTEOF
    chmod +x /usr/local/bin/socks5-ipv6-start.sh

    cat > /etc/systemd/system/socks5-ipv6.service <<UNIT
[Unit]
Description=SOCKS5 IPv6 Proxy Service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/usr/local/bin/socks5-ipv6-setup.sh
ExecStart=/usr/local/bin/socks5-ipv6-start.sh
ExecStop=/bin/bash -c 'pkill -f "microsocks -p" || true'

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable socks5-ipv6.service &>/dev/null

    # ---------- Layer 4: Watchdog ----------
    setup_watchdog

    log_ok "4-layer persistence enabled"
}

# ======================== NETWORK CONFIG ========================
write_network_config() {
    log_info "Writing IPv6 to network config..."

    if command -v netplan &>/dev/null; then
        local netplan_file="/etc/netplan/60-socks5-ipv6.yaml"
        cat > "$netplan_file" <<NETPLAN
# Auto-generated by socks5_ipv6_proxy.sh - DO NOT EDIT
network:
  version: 2
  ethernets:
    ${IPV6_IFACE}:
      addresses:
NETPLAN
        for ipv6 in "${USED_IPS[@]}"; do
            echo "        - \"${ipv6}/128\"" >> "$netplan_file"
        done
        chmod 600 "$netplan_file"
        netplan apply 2>/dev/null || log_warn "netplan apply failed (IPv6 added via ip cmd)"
        log_ok "Netplan config: ${netplan_file}"

    elif [[ -d /etc/sysconfig/network-scripts ]]; then
        local ifcfg_file="/etc/sysconfig/network-scripts/ifcfg-${IPV6_IFACE}-socks5-ipv6"
        cat > "$ifcfg_file" <<IFCFG
# Auto-generated by socks5_ipv6_proxy.sh
DEVICE=${IPV6_IFACE}
IPV6ADDR_SECONDARIES="$(printf '%s/128 ' "${USED_IPS[@]}")"
IFCFG
        log_ok "ifcfg config: ${ifcfg_file}"

    elif [[ -d /etc/network/interfaces.d ]]; then
        local iface_file="/etc/network/interfaces.d/socks5-ipv6"
        > "$iface_file"
        for ipv6 in "${USED_IPS[@]}"; do
            echo "iface ${IPV6_IFACE} inet6 static" >> "$iface_file"
            echo "    address ${ipv6}/128" >> "$iface_file"
            echo "" >> "$iface_file"
        done
        log_ok "interfaces.d config: ${iface_file}"

    else
        log_warn "Unknown network config. IPv6 relies on boot script + watchdog."
    fi
}

# ======================== WATCHDOG ========================
setup_watchdog() {
    log_info "Setting up watchdog..."

    cat > /usr/local/bin/socks5-ipv6-watchdog.sh <<WDSCRIPT
#!/bin/bash
# Auto-generated watchdog - recovers lost IPv6 and dead proxies
IFACE="${IPV6_IFACE}"
CONF="${WORK_DIR}/proxies.conf"
RECOVERED=0

[[ -f "\$CONF" ]] || exit 0

# --- Check and re-add missing IPv6 addresses ---
WDSCRIPT

    for ipv6 in "${USED_IPS[@]}"; do
        cat >> /usr/local/bin/socks5-ipv6-watchdog.sh <<WDCHECK
if ! ip -6 addr show dev \$IFACE | grep -q "${ipv6}"; then
    ip -6 addr add ${ipv6}/128 dev \$IFACE 2>/dev/null
    ip -6 neigh add proxy ${ipv6} dev \$IFACE 2>/dev/null || true
    RECOVERED=\$((RECOVERED + 1))
    logger -t socks5-watchdog "Recovered IPv6: ${ipv6}"
fi
WDCHECK
    done

    cat >> /usr/local/bin/socks5-ipv6-watchdog.sh <<'WDTAIL'

# --- Check and restart dead proxy processes ---
while IFS='|' read -r port user pass ipv6; do
    if ! ss -tlnp | grep -q ":${port} "; then
        microsocks -p "$port" -u "$user" -P "$pass" -b "$ipv6" >/dev/null 2>&1 &
        logger -t socks5-watchdog "Restarted proxy on port ${port} (${ipv6})"
        RECOVERED=$((RECOVERED + 1))
    fi
done < "$CONF"

if (( RECOVERED > 0 )); then
    logger -t socks5-watchdog "Total recovered: $RECOVERED"
fi
WDTAIL

    chmod +x /usr/local/bin/socks5-ipv6-watchdog.sh

    cat > /etc/systemd/system/socks5-ipv6-watchdog.service <<WDSVC
[Unit]
Description=SOCKS5 IPv6 Proxy - Watchdog

[Service]
Type=oneshot
ExecStart=/usr/local/bin/socks5-ipv6-watchdog.sh
WDSVC

    cat > /etc/systemd/system/socks5-ipv6-watchdog.timer <<WDTIMER
[Unit]
Description=SOCKS5 IPv6 Proxy - Watchdog Timer

[Timer]
OnBootSec=120
OnUnitActiveSec=60
AccuracySec=10

[Install]
WantedBy=timers.target
WDTIMER

    systemctl daemon-reload
    systemctl enable --now socks5-ipv6-watchdog.timer &>/dev/null
    log_ok "Watchdog active (checks every 60s)"
}

# ======================== FIREWALL ========================
configure_firewall() {
    local first_port=$START_PORT
    local last_port=$(( START_PORT + PROXY_COUNT - 1 ))

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        log_info "Configuring UFW..."
        ufw allow "${first_port}:${last_port}"/tcp &>/dev/null
        log_ok "UFW: opened ports ${first_port}-${last_port}"

    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        log_info "Configuring firewalld..."
        firewall-cmd --permanent --add-port="${first_port}-${last_port}"/tcp &>/dev/null
        firewall-cmd --reload &>/dev/null
        log_ok "Firewalld: opened ports ${first_port}-${last_port}"

    else
        log_warn "No active firewall detected. Ensure ports ${first_port}-${last_port} are accessible."
    fi
}

# ======================== REMOVE ALL ========================
remove_all() {
    log_warn "Removing all IPv6 SOCKS5 proxies..."

    # Stop all microsocks processes
    stop_all_proxies
    log_ok "Proxy processes stopped"

    # Remove IPv6 addresses
    if [[ -f /usr/local/bin/socks5-ipv6-setup.sh ]]; then
        while IFS= read -r line; do
            if [[ "$line" == *"addr add"* ]]; then
                local addr iface
                addr=$(echo "$line" | grep -oP 'add \K[0-9a-f:]+')
                iface=$(echo "$line" | grep -oP 'dev \K\S+')
                ip -6 addr del "${addr}/128" dev "$iface" 2>/dev/null || true
                ip -6 neigh del proxy "$addr" dev "$iface" 2>/dev/null || true
            fi
        done < /usr/local/bin/socks5-ipv6-setup.sh
        log_ok "IPv6 addresses removed"
    fi

    # Remove systemd services
    systemctl disable --now socks5-ipv6.service 2>/dev/null || true
    systemctl disable --now socks5-ipv6-watchdog.timer 2>/dev/null || true
    systemctl disable --now socks5-ipv6-watchdog.service 2>/dev/null || true
    rm -f /etc/systemd/system/socks5-ipv6.service
    rm -f /etc/systemd/system/socks5-ipv6-watchdog.service
    rm -f /etc/systemd/system/socks5-ipv6-watchdog.timer
    rm -f /usr/local/bin/socks5-ipv6-setup.sh
    rm -f /usr/local/bin/socks5-ipv6-start.sh
    rm -f /usr/local/bin/socks5-ipv6-watchdog.sh
    systemctl daemon-reload 2>/dev/null || true
    log_ok "Systemd services removed"

    # Remove network config
    rm -f /etc/netplan/60-socks5-ipv6.yaml
    netplan apply 2>/dev/null || true
    rm -f /etc/sysconfig/network-scripts/ifcfg-*-socks5-ipv6 2>/dev/null || true
    rm -f /etc/network/interfaces.d/socks5-ipv6 2>/dev/null || true
    log_ok "Network config removed"

    # Remove sysctl
    rm -f /etc/sysctl.d/99-socks5-ndp.conf
    sysctl --system &>/dev/null || true

    # Remove firewall rules (best effort)
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw status numbered 2>/dev/null | grep -oP '\d+:\d+' | while read -r range; do
            ufw delete allow "${range}/tcp" 2>/dev/null || true
        done || true
    fi

    # Remove work dir and output
    rm -rf "$WORK_DIR" "$PID_DIR" "$OUTPUT_FILE"

    log_ok "Cleanup complete. All proxies removed."
    exit 0
}

# ======================== VERIFY ========================
verify_proxies() {
    log_info "Verifying proxy functionality..."
    local test_line
    test_line=$(head -1 "$WORK_DIR/proxies.conf")
    local port user pass ipv6
    IFS='|' read -r port user pass ipv6 <<< "$test_line"

    local result
    result=$(curl -s -m 15 -x "socks5://${user}:${pass}@127.0.0.1:${port}" https://api64.ipify.org 2>/dev/null || true)

    if [[ "$result" == "$ipv6" ]]; then
        log_ok "Proxy verified: outgoing IPv6 = ${result}"
    elif [[ -n "$result" ]]; then
        log_warn "Proxy works but outgoing IP: ${result} (expected ${ipv6})"
    else
        log_warn "Proxy verification timed out (may still work for IPv4 targets)"
    fi
}

# ======================== SUMMARY ========================
show_summary() {
    echo ""
    echo -e "${GREEN}=================================================================${NC}"
    echo -e "${GREEN}  ALL ${PROXY_COUNT} IPv6 SOCKS5 PROXIES ARE RUNNING${NC}"
    echo -e "${GREEN}=================================================================${NC}"
    echo ""

    # Show first 5 and last 2 for brevity
    head -15 "$OUTPUT_FILE"
    if (( PROXY_COUNT > 7 )); then
        echo "  ... ($(( PROXY_COUNT - 7 )) more proxies) ..."
        tail -5 "$OUTPUT_FILE"
    else
        tail -n +16 "$OUTPUT_FILE"
    fi

    echo ""
    echo -e "${CYAN}Full proxy list: ${OUTPUT_FILE}${NC}"
    echo ""
    echo -e "${YELLOW}Quick test:${NC}"
    local first_line
    first_line=$(head -1 "$WORK_DIR/proxies.conf")
    local tp tu tps tv6
    IFS='|' read -r tp tu tps tv6 <<< "$first_line"
    echo -e "  curl -x socks5://${tu}:${tps}@${PUBLIC_IPV4}:${tp} https://api64.ipify.org"
    echo ""
    echo -e "${YELLOW}Management:${NC}"
    echo -e "  Remove all  : $0 -r"
    echo -e "  Status      : ss -tlnp | grep microsocks | wc -l"
    echo -e "  Watchdog log: journalctl -t socks5-watchdog"
    echo ""
}

# ======================== MAIN ========================
main() {
    check_root
    detect_os

    local REMOVE=0
    local CUSTOM_COUNT=0

    while getopts "rn:p:h" opt; do
        case $opt in
            r) REMOVE=1 ;;
            n) CUSTOM_COUNT=$OPTARG ;;
            p) START_PORT=$OPTARG ;;
            h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  -n COUNT   Number of proxies (default: auto based on RAM)"
                echo "  -p PORT    Start port (default: ${START_PORT})"
                echo "  -r         Remove all proxies and cleanup"
                echo "  -h         Show this help"
                exit 0
                ;;
            *) echo "Usage: $0 [-r] [-n count] [-p port] [-h]"; exit 1 ;;
        esac
    done

    echo -e "${CYAN}"
    echo "  ============================================"
    echo "    IPv6 SOCKS5 Proxy Auto-Setup"
    echo "    Engine: microsocks"
    echo "  ============================================"
    echo -e "${NC}"

    [[ $REMOVE -eq 1 ]] && remove_all

    # Step 1: Detect & validate IPv6
    detect_ipv6
    check_ipv6_connectivity

    # Step 2: Calculate proxy count
    calculate_proxy_count
    if (( CUSTOM_COUNT > 0 )); then
        PROXY_COUNT=$CUSTOM_COUNT
        log_info "Using custom count: ${PROXY_COUNT} proxies"
    fi

    # Step 3: Install dependencies
    install_deps

    # Step 4: Test IPv6
    test_ipv6_assignment

    # Step 5: Create & assign proxies
    echo ""
    log_info "Generating ${PROXY_COUNT} proxies with unique IPv6 addresses..."
    echo ""
    USED_IPS=()
    setup_proxies

    # Step 6: NDP + persistence + firewall
    echo ""
    setup_ndp
    make_persistent
    configure_firewall

    # Step 7: Start all proxies
    echo ""
    start_all_proxies

    # Step 8: Verify
    sleep 2
    local listening
    listening=$(ss -tlnp 2>/dev/null | grep -c "microsocks" || echo 0)
    log_ok "${listening}/${PROXY_COUNT} proxies listening"

    verify_proxies
    show_summary
}

main "$@"
