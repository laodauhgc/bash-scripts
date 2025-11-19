#!/usr/bin/env bash

# ==============================================================================
# CONFIGURATION
# ==============================================================================
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

IMAGE_NAME="laodauhgc/titan-edge"
BASE_DIR="/root/titan-edge"
STORAGE_GB=50
START_PORT=1235
BIND_URL="https://api-test1.container1.titannet.io/api/v2/device/binding"
DEFAULT_NODE_COUNT=5

# ==============================================================================
# SYSTEM COMPATIBILITY FUNCTIONS
# ==============================================================================

log_info() { echo -e "${BLUE}[INFO] $1${NC}"; }
log_success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}"; }

check_root() {
    if [[ "$(id -u)" -ne "0" ]]; then
        log_error "This script must be run as root."
        exit 1
    fi
}

# Detect OS and install dependencies (curl)
ensure_dependencies() {
    if ! command -v curl &> /dev/null; then
        log_info "Installing curl..."
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y curl
        elif command -v dnf &> /dev/null; then
            dnf install -y curl
        elif command -v yum &> /dev/null; then
            yum install -y curl
        elif command -v pacman &> /dev/null; then
            pacman -Sy --noconfirm curl
        elif command -v apk &> /dev/null; then
            apk add curl
        else
            log_error "Could not install curl. Please install it manually."
            exit 1
        fi
    fi
}

# Optimize Sysctl (Universal approach)
optimize_sysctl() {
    log_info "Optimizing UDP buffer sizes..."
    
    # Apply runtime
    sysctl -w net.core.rmem_max=2500000 > /dev/null 2>&1
    sysctl -w net.core.wmem_max=2500000 > /dev/null 2>&1
    
    # Apply persistent
    if [[ -d "/etc/sysctl.d" ]]; then
        cat <<EOF > /etc/sysctl.d/99-titan-edge.conf
net.core.rmem_max=2500000
net.core.wmem_max=2500000
EOF
    else
        # Fallback for older systems or non-systemd
        if ! grep -q "net.core.rmem_max=2500000" /etc/sysctl.conf; then
            echo "net.core.rmem_max=2500000" >> /etc/sysctl.conf
            echo "net.core.wmem_max=2500000" >> /etc/sysctl.conf
        fi
    fi
    
    sysctl --system > /dev/null 2>&1 || sysctl -p > /dev/null 2>&1
    log_success "UDP buffer sizes updated."
}

start_docker_service() {
    if command -v systemctl &> /dev/null; then
        systemctl enable --now docker
    elif command -v service &> /dev/null; then
        service docker start
    elif command -v rc-service &> /dev/null; then # Alpine/OpenRC
        rc-service docker start
    fi
}

install_docker() {
    if ! command -v docker &> /dev/null; then
        log_info "Docker not found. Installing..."
        
        # Try official script first (Works for Debian, Ubuntu, CentOS, Fedora)
        if curl -fsSL https://get.docker.com | sh; then
            log_success "Docker installed via official script."
        else
            log_warn "Official script failed/unsupported. Trying package manager..."
            if command -v apk &> /dev/null; then
                apk add docker
            elif command -v pacman &> /dev/null; then
                pacman -Sy --noconfirm docker
            else
                log_error "Failed to install Docker. Please install manually."
                exit 1
            fi
        fi
    else
        log_success "Docker is already installed."
    fi
    
    start_docker_service
    
    # Double check
    if ! docker ps > /dev/null 2>&1; then
        log_error "Docker is installed but not running. Please check logs."
        exit 1
    fi
}

cleanup_resources() {
    log_warn "⚠️  Removing ALL Titan Edge resources..."
    
    local container_ids=$(docker ps -a -q --filter "name=titan-edge")
    if [[ -n "$container_ids" ]]; then
        echo "$container_ids" | xargs docker rm -f >/dev/null 2>&1
        log_success "Containers removed."
    fi

    if [[ -d "$BASE_DIR" ]]; then
        rm -rf "$BASE_DIR"
        log_success "Directory $BASE_DIR removed."
    fi
    
    if [[ -d "/root/.titanedge" ]]; then
        rm -rf /root/.titanedge
    fi

    local volume_ids=$(docker volume ls -q --filter "name=titan")
    if [[ -n "$volume_ids" ]]; then
        echo "$volume_ids" | xargs docker volume rm >/dev/null 2>&1
        log_success "Volumes removed."
    fi
    
    log_success "Cleanup complete!"
    exit 0
}

wait_for_config() {
    local config_path="$1"
    local max_attempts=20
    local attempt=1
    
    echo -ne "${YELLOW}Waiting for config...${NC}"
    while [[ ! -f "$config_path" ]]; do
        if [[ $attempt -ge $max_attempts ]]; then
            echo ""
            return 1
        fi
        echo -ne "."
        sleep 2
        ((attempt++))
    done
    echo ""
    return 0
}

# ==============================================================================
# MAIN LOGIC
# ==============================================================================

check_root
ensure_dependencies

# Parse arguments
case "$1" in
    rm|remove|-rm|--rm)
        cleanup_resources
        ;;
esac

HASH_VALUE="$1"
NODE_COUNT="${2:-$DEFAULT_NODE_COUNT}"

if [[ -z "$HASH_VALUE" ]]; then
    log_warn "Usage: $0 <hash_value> [node_count]"
    log_warn "       $0 rm"
    exit 1
fi

# Sanitize node count
if ! [[ "$NODE_COUNT" =~ ^[1-5]$ ]]; then
    log_warn "Invalid node count. Using default: $DEFAULT_NODE_COUNT"
    NODE_COUNT=$DEFAULT_NODE_COUNT
fi

optimize_sysctl
install_docker

log_info "Pulling Docker image..."
docker pull "$IMAGE_NAME" >/dev/null 2>&1

mkdir -p "$BASE_DIR"

# Determine existing nodes
existing_count=0
for ((i=1; i<=5; i++)); do
    if docker ps --format '{{.Names}}' | grep -q "^titan-edge-0${i}$"; then
        ((existing_count++))
    fi
done

nodes_to_create=$((NODE_COUNT - existing_count))
log_info "Existing: $existing_count. To Create: $nodes_to_create."

if [[ $nodes_to_create -le 0 ]]; then
    log_success "Desired node count reached."
    exit 0
fi

# Loop to create nodes
current_node=1
created=0

while [[ $created -lt $nodes_to_create && $current_node -le 5 ]]; do
    C_NAME="titan-edge-0${current_node}"
    
    # Check if container name exists (running or stopped)
    if docker ps -a --format '{{.Names}}' | grep -q "^$C_NAME$"; then
        if docker ps --format '{{.Names}}' | grep -q "^$C_NAME$"; then
            # Running, skip
            ((current_node++))
            continue
        else
            # Stopped/Dead, remove to recreate
            docker rm -f "$C_NAME" >/dev/null 2>&1
        fi
    fi

    C_PORT=$((START_PORT + current_node - 1))
    HOST_DATA_PATH="$BASE_DIR/$C_NAME/.titanedge"
    mkdir -p "$HOST_DATA_PATH"

    log_info "Setting up $C_NAME on port $C_PORT..."

    # Run container
    # NOTE: Added ':z' to volume mount for SELinux compatibility (CentOS/RHEL/Fedora)
    docker run -d \
        --name "$C_NAME" \
        -v "$HOST_DATA_PATH:/root/.titanedge:z" \
        -p "$C_PORT:$C_PORT/tcp" \
        -p "$C_PORT:$C_PORT/udp" \
        --restart always \
        "$IMAGE_NAME" >/dev/null

    # Wait and Configure
    if wait_for_config "$HOST_DATA_PATH/config.toml"; then
        # Universal sed (works on Linux GNU sed)
        sed -i "s/^[[:space:]]*#StorageGB = .*/StorageGB = $STORAGE_GB/" "$HOST_DATA_PATH/config.toml"
        sed -i "s/^[[:space:]]*#ListenAddress = \"0.0.0.0:1234\"/ListenAddress = \"0.0.0.0:$C_PORT\"/" "$HOST_DATA_PATH/config.toml"
        
        docker restart "$C_NAME" >/dev/null
        
        # Allow daemon time to initialize before binding
        sleep 5 
        
        log_info "Binding $C_NAME..."
        if docker exec "$C_NAME" titan-edge bind --hash="$HASH_VALUE" "$BIND_URL"; then
            log_success "$C_NAME bound successfully."
            ((created++))
        else
            log_error "Failed to bind $C_NAME. Please check logs manually."
        fi
    else
        log_error "Config timeout for $C_NAME."
    fi

    ((current_node++))
done

total_running=$(docker ps | grep -c titan-edge)
log_success "Done! Total active Titan nodes: $total_running"
