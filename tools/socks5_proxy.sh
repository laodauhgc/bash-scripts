#!/usr/bin/env bash
# Universal SOCKS5 Proxy Setup Script
# Supports: Ubuntu, Debian, CentOS, AlmaLinux, Rocky Linux
# Uses Docker Compose V2 & Auto Firewall Config

set -Eeuo pipefail
trap 'echo "❌ Error at line $LINENO: $BASH_COMMAND" >&2' ERR

# ==============================================================================
# CONFIGURATION
# ==============================================================================
OUTPUT_FILE="/root/socks5proxy.txt"
WORK_DIR="/root/socks5-proxy"
DEFAULT_START_PORT=5000
PROXY_IMAGE="ghcr.io/tarampampam/3proxy:latest" # Lightweight & maintained

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

log_info()  { echo -e "${BLUE}[INFO] $1${NC}"; }
log_ok()    { echo -e "${GREEN}[OK] $1${NC}"; }
log_warn()  { echo -e "${YELLOW}[WARN] $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

check_root() {
    [[ $EUID -eq 0 ]] || log_error "This script must be run as root/sudo."
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID=$ID
        OS_LIKE=${ID_LIKE:-$ID}
    else
        OS_ID="unknown"
        OS_LIKE="unknown"
    fi

    case "$OS_LIKE" in
        *debian*|ubuntu) PKG_MANAGER="apt" ;;
        *rhel*|*centos*|*fedora*) PKG_MANAGER="dnf" ;;
        *) log_error "Unsupported OS: $OS_ID ($OS_LIKE)" ;;
    esac
}

check_port_availability() {
    local port=$1
    if netstat -tuln | grep -q ":$port "; then
        log_error "Port $port is already in use!"
    fi
}

get_public_ip() {
    local ip
    ip=$(curl -s -m 5 ifconfig.me || curl -s -m 5 api.ipify.org)
    if [[ -z "$ip" ]]; then
        log_error "Could not determine Public IP."
    fi
    echo "$ip"
}

update_firewall() {
    local port=$1
    local action=$2 # allow or delete

    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        if [[ "$action" == "allow" ]]; then
            ufw allow "$port"/tcp >/dev/null 2>&1
        else
            ufw delete allow "$port"/tcp >/dev/null 2>&1
        fi
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        if [[ "$action" == "allow" ]]; then
            firewall-cmd --permanent --add-port="$port"/tcp >/dev/null 2>&1
            firewall-cmd --reload >/dev/null 2>&1
        else
            firewall-cmd --permanent --remove-port="$port"/tcp >/dev/null 2>&1
            firewall-cmd --reload >/dev/null 2>&1
        fi
    fi
}

# ==============================================================================
# INSTALLATION & REMOVAL LOGIC
# ==============================================================================

install_dependencies() {
    log_info "Installing system dependencies..."
    case "$PKG_MANAGER" in
        apt)
            apt-get update -qq
            apt-get install -y -qq apt-transport-https ca-certificates curl net-tools software-properties-common
            ;;
        dnf)
            $PKG_MANAGER install -y curl net-tools
            ;;
    esac
}

install_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        log_info "Installing Docker & Compose V2..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable --now docker
    else
        log_ok "Docker is already installed."
    fi

    # Check for Compose Plugin (V2)
    if ! docker compose version >/dev/null 2>&1; then
        log_warn "Docker Compose Plugin not found. Attempting to fix..."
        case "$PKG_MANAGER" in
            apt) apt-get install -y docker-compose-plugin ;;
            dnf) $PKG_MANAGER install -y docker-compose-plugin ;;
        esac
    fi
}

remove_proxies() {
    log_warn "Removing all SOCKS5 proxies..."

    if [[ -d "$WORK_DIR" ]]; then
        cd "$WORK_DIR"
        if docker compose ls | grep -q socks5-proxy; then
            docker compose down >/dev/null 2>&1
        elif [[ -f "docker-compose.yml" ]]; then
            docker compose down >/dev/null 2>&1 || docker-compose down >/dev/null 2>&1
        fi
        cd ..
        rm -rf "$WORK_DIR"
        log_ok "Removed containers and directory."
    fi

    if [[ -f "$OUTPUT_FILE" ]]; then
        rm -f "$OUTPUT_FILE"
        log_ok "Removed info file."
    fi

    log_ok "Cleanup complete."
    exit 0
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

check_root
detect_os

START_PORT=$DEFAULT_START_PORT
REMOVE_MODE=0

while getopts "p:r" opt; do
    case $opt in
        p) START_PORT=$OPTARG ;;
        r) REMOVE_MODE=1 ;;
        *) echo "Usage: $0 [-p start_port] [-r (remove)]"; exit 1 ;;
    esac
done

if [[ $REMOVE_MODE -eq 1 ]]; then
    remove_proxies
fi

# Validations
if ! [[ "$START_PORT" =~ ^[0-9]+$ ]] || [ "$START_PORT" -lt 1024 ] || [ "$START_PORT" -gt 65535 ]; then
    log_error "Port must be between 1024 and 65535."
fi

install_dependencies
install_docker

PUBLIC_IP=$(get_public_ip)
log_info "Public IP: $PUBLIC_IP"

# Calculate RAM & Instances
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
if [ "$TOTAL_RAM" -lt 512 ]; then PROXY_COUNT=1
elif [ "$TOTAL_RAM" -lt 1024 ]; then PROXY_COUNT=2
elif [ "$TOTAL_RAM" -lt 2048 ]; then PROXY_COUNT=5
else PROXY_COUNT=10
fi

log_info "RAM: ${TOTAL_RAM}MB -> Creating $PROXY_COUNT proxies starting at port $START_PORT."

# Check ports
for ((i=0; i<PROXY_COUNT; i++)); do
    current_port=$((START_PORT + i))
    check_port_availability $current_port
done

# Prepare Workspace
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Create docker-compose.yml
cat > docker-compose.yml <<EOF
name: socks5-proxy
services:
EOF

# Generate Configs
> "$OUTPUT_FILE"
echo "-------------------------------------------------------" >> "$OUTPUT_FILE"
echo " SOCKS5 PROXY LIST ($PUBLIC_IP)" >> "$OUTPUT_FILE"
echo "-------------------------------------------------------" >> "$OUTPUT_FILE"

for ((i=1; i<=PROXY_COUNT; i++)); do
    PORT=$((START_PORT + i - 1))
    USER=$(openssl rand -hex 4)
    PASS=$(openssl rand -hex 4)
    
    # Append to compose file
    cat >> docker-compose.yml <<EOF
  proxy-$i:
    image: $PROXY_IMAGE
    container_name: socks5-$i
    restart: always
    ports:
      - "$PORT:1080/tcp"
    environment:
      - SOCKS5_USER=$USER
      - SOCKS5_PASS=$PASS
      # 3proxy specific vars (simple auth)
      - CL=0.0.0.0
EOF

    # Open Firewall
    update_firewall "$PORT" "allow"

    # Save Info
    echo "Proxy $i: socks5://$USER:$PASS@$PUBLIC_IP:$PORT" >> "$OUTPUT_FILE"
done

# Start Services
log_info "Starting containers..."
if docker compose up -d; then
    log_ok "Proxies are running!"
else
    log_error "Failed to start proxies."
fi

# Display Info
echo ""
log_ok "Installation Successful!"
echo -e "${YELLOW}Proxy Details:${NC}"
cat "$OUTPUT_FILE"
echo ""
echo -e "${BLUE}Saved to: $OUTPUT_FILE${NC}"
