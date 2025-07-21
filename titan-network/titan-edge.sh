#!/bin/bash

# Titan Edge Node Management Script - Optimized Version
# Version: 2.0
# Description: Advanced deployment and management of Titan Edge nodes with enhanced security and reliability

set -euo pipefail  # Exit on error, undefined vars, pipe failures
IFS=

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="${SCRIPT_DIR}/titan-edge.log"
readonly CONFIG_FILE="${SCRIPT_DIR}/titan-edge.conf"
readonly LOCK_FILE="/tmp/titan-edge.lock"

# Default configuration
readonly DEFAULT_IMAGE_NAME="laodauhgc/titan-edge"
readonly DEFAULT_STORAGE_GB=50
readonly DEFAULT_START_PORT=1235
readonly DEFAULT_MAX_NODES=5
readonly DEFAULT_TITAN_EDGE_DIR="/opt/titan-edge"  # More appropriate than /root
readonly DEFAULT_BIND_URL="https://api-test1.container1.titannet.io/api/v2/device/binding"

# Resource limits
readonly DEFAULT_CPU_LIMIT="1"
readonly DEFAULT_MEMORY_LIMIT="1g"
readonly DEFAULT_SWAP_LIMIT="512m"

# Colors for output
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Global variables (loaded from config or defaults)
IMAGE_NAME="${DEFAULT_IMAGE_NAME}"
STORAGE_GB="${DEFAULT_STORAGE_GB}"
START_PORT="${DEFAULT_START_PORT}"
TITAN_EDGE_DIR="${DEFAULT_TITAN_EDGE_DIR}"
BIND_URL="${DEFAULT_BIND_URL}"
CPU_LIMIT="${DEFAULT_CPU_LIMIT}"
MEMORY_LIMIT="${DEFAULT_MEMORY_LIMIT}"

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "${YELLOW}$*${NC}"; }
log_error() { log "ERROR" "${RED}$*${NC}"; }
log_success() { log "SUCCESS" "${GREEN}$*${NC}"; }

# Cleanup function
cleanup() {
    local exit_code=$?
    if [[ -f "$LOCK_FILE" ]]; then
        rm -f "$LOCK_FILE"
    fi
    
    # Don't log error if it's a controlled exit
    if [[ $exit_code -ne 0 ]] && [[ -z "${controlled_exit_flag:-}" ]]; then
        log_error "Script exited with error code: $exit_code"
    fi
    
    # Clear deployment flag
    unset deployment_in_progress
}

# Set trap for cleanup
trap cleanup EXIT INT TERM

# Lock mechanism to prevent concurrent execution
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            log_error "Another instance is already running (PID: $pid)"
            exit 1
        else
            log_warn "Removing stale lock file"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

# Load configuration from file
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        log_info "Loading configuration from $CONFIG_FILE"
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    else
        log_info "No config file found, creating default configuration"
        create_default_config
    fi
}

# Create default configuration file
create_default_config() {
    cat > "$CONFIG_FILE" << EOF
# Titan Edge Configuration
IMAGE_NAME="$DEFAULT_IMAGE_NAME"
STORAGE_GB=$DEFAULT_STORAGE_GB
START_PORT=$DEFAULT_START_PORT
TITAN_EDGE_DIR="$DEFAULT_TITAN_EDGE_DIR"
BIND_URL="$DEFAULT_BIND_URL"
CPU_LIMIT="$DEFAULT_CPU_LIMIT"
MEMORY_LIMIT="$DEFAULT_MEMORY_LIMIT"

# Network optimization
UDP_RMEM_MAX=2500000
UDP_WMEM_MAX=2500000

# Monitoring
HEALTH_CHECK_INTERVAL=30
MAX_RESTART_ATTEMPTS=3
EOF
    log_success "Default configuration created at $CONFIG_FILE"
}

# Validate configuration
validate_config() {
    local errors=0
    
    if ! [[ "$STORAGE_GB" =~ ^[1-9][0-9]*$ ]] || [[ "$STORAGE_GB" -lt 10 ]] || [[ "$STORAGE_GB" -gt 1000 ]]; then
        log_error "Invalid STORAGE_GB: must be between 10-1000"
        ((errors++))
    fi
    
    if ! [[ "$START_PORT" =~ ^[1-9][0-9]*$ ]] || [[ "$START_PORT" -lt 1024 ]] || [[ "$START_PORT" -gt 65530 ]]; then
        log_error "Invalid START_PORT: must be between 1024-65530"
        ((errors++))
    fi
    
    if [[ $errors -gt 0 ]]; then
        log_error "Configuration validation failed with $errors errors"
        exit 1
    fi
}

# Enhanced root check
check_privileges() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script requires root privileges"
        log_info "Please run with sudo or as root user"
        exit 1
    fi
}

# Check system requirements
check_system_requirements() {
    log_info "Checking system requirements..."
    
    # Check available memory
    local total_mem=$(free -m | awk '/^Mem:/{print $2}')
    local required_mem=1024  # 1GB minimum (reduced from 2GB)
    
    if [[ "$total_mem" -lt "$required_mem" ]]; then
        log_warn "Low memory detected: ${total_mem}MB (recommended: 2GB+)"
    fi
    
    # Check if ports are available
    check_port_availability
    
    log_success "Basic system requirements check passed"
}

# Check port availability
check_port_availability() {
    local port_conflicts=()
    
    for ((i=0; i<DEFAULT_MAX_NODES; i++)); do
        local port=$((START_PORT + i))
        if netstat -tuln 2>/dev/null | grep -q ":${port} " || ss -tuln 2>/dev/null | grep -q ":${port} "; then
            # Check if it's our own container
            if ! docker ps --format '{{.Names}} {{.Ports}}' | grep -q "titan-edge.*:${port}->"; then
                port_conflicts+=("$port")
            fi
        fi
    done
    
    if [[ ${#port_conflicts[@]} -gt 0 ]]; then
        log_error "Port conflicts detected: ${port_conflicts[*]}"
        log_info "Please change START_PORT in configuration or stop services using these ports"
        exit 1
    fi
}

# Enhanced UDP buffer optimization
optimize_network() {
    log_info "Optimizing network settings..."
    
    local current_rmem=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "0")
    local current_wmem=$(sysctl -n net.core.wmem_max 2>/dev/null || echo "0")
    
    log_info "Current UDP buffer values - rmem_max: $current_rmem, wmem_max: $current_wmem"
    
    # Set new values
    local target_rmem=${UDP_RMEM_MAX:-2500000}
    local target_wmem=${UDP_WMEM_MAX:-2500000}
    
    if [[ "$current_rmem" -lt "$target_rmem" ]]; then
        sysctl -w "net.core.rmem_max=$target_rmem" >/dev/null
        update_sysctl_conf "net.core.rmem_max" "$target_rmem"
    fi
    
    if [[ "$current_wmem" -lt "$target_wmem" ]]; then
        sysctl -w "net.core.wmem_max=$target_wmem" >/dev/null
        update_sysctl_conf "net.core.wmem_max" "$target_wmem"
    fi
    
    # Additional network optimizations
    sysctl -w net.core.netdev_max_backlog=5000 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.udp_mem="102400 873800 16777216" >/dev/null 2>&1 || true
    
    log_success "Network optimization completed"
}

# Update sysctl.conf safely
update_sysctl_conf() {
    local key="$1"
    local value="$2"
    local sysctl_conf="/etc/sysctl.conf"
    
    if ! grep -q "^${key}=" "$sysctl_conf" 2>/dev/null; then
        echo "${key}=${value}" >> "$sysctl_conf"
        log_info "Added ${key}=${value} to $sysctl_conf"
    else
        sed -i "s|^${key}=.*|${key}=${value}|" "$sysctl_conf"
        log_info "Updated ${key}=${value} in $sysctl_conf"
    fi
}

# Enhanced Docker installation
install_docker() {
    log_info "Installing Docker..."
    
    if command -v docker >/dev/null 2>&1; then
        log_info "Docker is already installed"
        return 0
    fi
    
    local os_release=""
    if [[ -f /etc/os-release ]]; then
        os_release=$(. /etc/os-release && echo "$ID")
    fi
    
    case "$os_release" in
        ubuntu|debian)
            install_docker_debian
            ;;
        centos|rhel|rocky|almalinux)
            install_docker_rhel
            ;;
        fedora)
            install_docker_fedora
            ;;
        arch|manjaro)
            install_docker_arch
            ;;
        *)
            log_error "Unsupported operating system: $os_release"
            log_info "Please install Docker manually"
            exit 1
            ;;
    esac
    
    # Verify installation
    if ! systemctl is-active --quiet docker; then
        systemctl start docker
        systemctl enable docker
    fi
    
    # Test Docker
    if ! docker version >/dev/null 2>&1; then
        log_error "Docker installation failed"
        exit 1
    fi
    
    log_success "Docker installed and configured successfully"
}

# Docker installation methods
install_docker_debian() {
    apt-get update
    apt-get install -y ca-certificates curl gnupg lsb-release
    
    # Add Docker's official GPG key
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    
    # Set up repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
}

install_docker_rhel() {
    yum install -y yum-utils
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
}

install_docker_fedora() {
    dnf install -y dnf-plugins-core
    dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
    dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
}

install_docker_arch() {
    pacman -Sy --noconfirm docker docker-compose
}

# Enhanced container management
create_node() {
    local node_num="$1"
    local container_name="titan-edge-$(printf "%02d" "$node_num")"
    local port=$((START_PORT + node_num - 1))
    local storage_path="${TITAN_EDGE_DIR}/${container_name}"
    
    log_info "Creating node $container_name on port $port..."
    
    # Create storage directory with proper permissions
    if ! mkdir -p "${storage_path}/.titanedge"; then
        log_error "Failed to create storage directory: ${storage_path}/.titanedge"
        return 1
    fi
    
    chmod 755 "${storage_path}" || {
        log_warn "Could not set permissions on ${storage_path}"
    }
    
    # Remove existing container if it exists
    if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        log_warn "Removing existing container $container_name"
        docker stop "$container_name" >/dev/null 2>&1 || true
        docker rm "$container_name" >/dev/null 2>&1 || true
    fi
    
    # Create container with resource limits and health checks
    local docker_run_cmd=(
        docker run -d
        --name "$container_name"
        --restart=unless-stopped
        --log-driver=json-file
        --log-opt max-size=10m
        --log-opt max-file=3
        --cpus="$CPU_LIMIT"
        --memory="$MEMORY_LIMIT"
        --memory-swap="$MEMORY_LIMIT"
        --security-opt=no-new-privileges:true
        --read-only=false
        -v "${storage_path}/.titanedge:/root/.titanedge:rw"
        -p "${port}:${port}/tcp"
        -p "${port}:${port}/udp"
        --health-cmd="pgrep titan-edge || exit 1"
        --health-interval=30s
        --health-timeout=10s
        --health-retries=3
        "$IMAGE_NAME"
    )
    
    if ! "${docker_run_cmd[@]}"; then
        log_error "Failed to create container $container_name"
        return 1
    fi
    
    # Wait for container to be ready
    if ! wait_for_container_ready "$container_name"; then
        log_error "Container $container_name failed to become ready"
        return 1
    fi
    
    # Configure the node
    if ! configure_node "$container_name" "$port"; then
        log_error "Failed to configure node $container_name"
        return 1
    fi
    
    log_success "Node $container_name created successfully"
    return 0
}

# Enhanced container readiness check
wait_for_container_ready() {
    local container_name="$1"
    local max_attempts=60
    local wait_seconds=2
    
    log_info "Waiting for container $container_name to be ready..."
    
    for ((i=1; i<=max_attempts; i++)); do
        local status
        status=$(docker inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null || echo "not_found")
        
        case "$status" in
            running)
                if docker exec "$container_name" test -f /root/.titanedge/config.toml 2>/dev/null; then
                    log_success "Container $container_name is ready"
                    return 0
                fi
                ;;
            restarting)
                log_warn "Container $container_name is restarting... ($i/$max_attempts)"
                ;;
            exited)
                log_error "Container $container_name exited unexpectedly"
                docker logs --tail 20 "$container_name"
                return 1
                ;;
            not_found)
                log_error "Container $container_name not found"
                return 1
                ;;
            *)
                log_warn "Container $container_name status: $status ($i/$max_attempts)"
                ;;
        esac
        
        sleep $wait_seconds
    done
    
    log_error "Container $container_name failed to become ready after $((max_attempts * wait_seconds)) seconds"
    docker logs --tail 50 "$container_name"
    return 1
}

# Node configuration
configure_node() {
    local container_name="$1"
    local port="$2"
    
    log_info "Configuring node $container_name..."
    
    # Create configuration script
    local config_script=$(cat << EOF
#!/bin/bash
set -e

CONFIG_FILE="/root/.titanedge/config.toml"
if [[ ! -f "\$CONFIG_FILE" ]]; then
    echo "Config file not found"
    exit 1
fi

# Backup original config
cp "\$CONFIG_FILE" "\$CONFIG_FILE.backup"

# Update configuration
sed -i 's/^[[:space:]]*#*StorageGB = .*/StorageGB = $STORAGE_GB/' "\$CONFIG_FILE"
sed -i 's/^[[:space:]]*#*ListenAddress = .*/ListenAddress = "0.0.0.0:$port"/' "\$CONFIG_FILE"

# Verify changes
if ! grep -q "StorageGB = $STORAGE_GB" "\$CONFIG_FILE"; then
    echo "Failed to set StorageGB"
    exit 1
fi

if ! grep -q "ListenAddress = \"0.0.0.0:$port\"" "\$CONFIG_FILE"; then
    echo "Failed to set ListenAddress"
    exit 1
fi

echo "Configuration updated successfully"
EOF
)
    
    if ! docker exec "$container_name" bash -c "$config_script"; then
        log_error "Failed to configure $container_name"
        return 1
    fi
    
    # Restart container to apply configuration
    log_info "Restarting $container_name to apply configuration..."
    if ! docker restart "$container_name" >/dev/null; then
        log_error "Failed to restart $container_name"
        return 1
    fi
    
    # Wait for restart
    sleep 5
    if ! wait_for_container_ready "$container_name"; then
        log_error "Container $container_name failed to start after configuration"
        return 1
    fi
    
    return 0
}

# Bind node to network
bind_node() {
    local container_name="$1"
    local hash_value="$2"
    local max_attempts=3
    
    log_info "Binding $container_name to Titan network..."
    
    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        if docker exec "$container_name" titan-edge bind --hash="$hash_value" "$BIND_URL"; then
            log_success "Node $container_name bound successfully"
            return 0
        else
            log_warn "Bind attempt $attempt/$max_attempts failed for $container_name"
            sleep 5
        fi
    done
    
    log_error "Failed to bind node $container_name after $max_attempts attempts"
    return 1
}

# Enhanced cleanup function
cleanup_nodes() {
    log_info "Removing all Titan Edge containers and data..."
    
    local containers
    containers=$(docker ps -a --filter "name=titan-edge" --format "{{.Names}}" 2>/dev/null || true)
    
    if [[ -n "$containers" ]]; then
        echo "$containers" | while read -r container; do
            log_info "Stopping and removing container $container..."
            docker stop "$container" >/dev/null 2>&1 || true
            docker rm -f "$container" >/dev/null 2>&1 || true
        done
        log_success "All Titan Edge containers removed"
    else
        log_info "No Titan Edge containers found"
    fi
    
    # Remove data directories
    if [[ -d "$TITAN_EDGE_DIR" ]]; then
        log_info "Removing data directory $TITAN_EDGE_DIR..."
        rm -rf "$TITAN_EDGE_DIR"
        log_success "Data directory removed"
    fi
    
    # Remove docker volumes
    local volumes
    volumes=$(docker volume ls --filter "name=titan" --format "{{.Name}}" 2>/dev/null || true)
    
    if [[ -n "$volumes" ]]; then
        echo "$volumes" | while read -r volume; do
            log_info "Removing volume $volume..."
            docker volume rm "$volume" >/dev/null 2>&1 || true
        done
        log_success "All Titan Edge volumes removed"
    fi
    
    log_success "Cleanup completed successfully"
}

# Get node status
get_node_status() {
    local containers
    containers=$(docker ps -a --filter "name=titan-edge" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true)
    
    if [[ -n "$containers" ]]; then
        echo -e "${CYAN}Current Titan Edge Nodes:${NC}"
        echo "$containers"
        
        # Show resource usage
        echo -e "\n${CYAN}Resource Usage:${NC}"
        docker stats --no-stream --filter "name=titan-edge" --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}"
    else
        echo -e "${YELLOW}No Titan Edge containers found${NC}"
    fi
}

# Show usage information
show_usage() {
    cat << EOF
${CYAN}Titan Edge Node Management Script v2.0${NC}

${YELLOW}USAGE:${NC}
    $0 <command> [options]

${YELLOW}COMMANDS:${NC}
    deploy <hash> [count]    Deploy nodes with hash (default count: 5)
    remove                   Remove all nodes and data
    status                   Show node status and resource usage
    config                   Show current configuration
    logs <node_number>       Show logs for specific node
    restart <node_number>    Restart specific node
    update                   Update all nodes to latest image

${YELLOW}OPTIONS:${NC}
    -h, --help              Show this help message
    -c, --config <file>     Use custom configuration file
    -v, --verbose           Enable verbose logging
    --full-checks           Enable comprehensive system checks (disk, memory)

${YELLOW}EXAMPLES:${NC}
    $0 deploy abc123                # Deploy 5 nodes (default) with hash abc123
    $0 deploy abc123 3              # Deploy 3 nodes with hash abc123
    $0 deploy abc123 --full-checks  # Deploy with comprehensive system checks
    $0 status                       # Show current node status
    $0 logs 1                       # Show logs for node 01
    $0 remove                       # Remove all nodes

${YELLOW}FILES:${NC}
    Config: $CONFIG_FILE
    Logs:   $LOG_FILE

${YELLOW}NOTE:${NC}
    - Default deployment: 5 nodes without disk space checks
    - Use --full-checks for comprehensive system validation
EOF
}

# Main execution function
main() {
    # Parse options
    local full_checks=false
    local args=()
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --full-checks)
                full_checks=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done
    
    # Restore positional parameters
    set -- "${args[@]}"
    
    # Initialize
    acquire_lock
    load_config
    validate_config
    
    case "${1:-}" in
        deploy)
            check_privileges
            
            # Set flag for error handling
            deployment_in_progress=true
            
            # Always run basic checks, but skip disk check by default
            if [[ "$full_checks" == "true" ]]; then
                log_info "Running comprehensive system checks (including disk space)..."
                check_system_requirements_full
            else
                check_system_requirements
            fi
            
            install_docker
            optimize_network
            
            local hash_value="${2:-}"
            local node_count="${3:-5}"  # Default to 5 nodes
            
            if [[ -z "$hash_value" ]]; then
                log_error "Hash value is required for deployment"
                show_usage
                controlled_exit 1
            fi
            
            if ! [[ "$node_count" =~ ^[1-5]$ ]]; then
                log_error "Node count must be between 1 and 5"
                controlled_exit 1
            fi
            
            log_info "Deploying $node_count Titan Edge nodes..."
            
            # Pull latest image
            log_info "Pulling Docker image $IMAGE_NAME..."
            if ! docker pull "$IMAGE_NAME"; then
                log_error "Failed to pull Docker image"
                controlled_exit 1
            fi
            
            # Deploy nodes
            local success_count=0
            local failed_nodes=()
            
            for ((i=1; i<=node_count; i++)); do
                log_info "Processing node $i of $node_count..."
                
                if create_node "$i"; then
                    local container_name="titan-edge-$(printf "%02d" "$i")"
                    if bind_node "$container_name" "$hash_value"; then
                        ((success_count++))
                        log_success "Node $i deployed and bound successfully"
                    else
                        failed_nodes+=("$i (bind failed)")
                        log_error "Node $i created but binding failed"
                    fi
                else
                    failed_nodes+=("$i (creation failed)")
                    log_error "Failed to create node $i"
                fi
            done
            
            # Report results
            log_info "Deployment summary:"
            log_info "- Successfully deployed: $success_count/$node_count nodes"
            
            if [[ ${#failed_nodes[@]} -gt 0 ]]; then
                log_warn "- Failed nodes: ${failed_nodes[*]}"
            fi
            
            if [[ $success_count -gt 0 ]]; then
                log_success "Deployment completed with $success_count active nodes"
                get_node_status || true
                controlled_exit 0
            else
                log_error "No nodes were successfully deployed"
                controlled_exit 1
            fi
            ;;
            
        remove)
            check_privileges
            cleanup_nodes
            ;;
            
        status)
            get_node_status
            ;;
            
        config)
            echo -e "${CYAN}Current Configuration:${NC}"
            cat "$CONFIG_FILE"
            ;;
            
        logs)
            local node_num="${2:-}"
            if [[ -z "$node_num" ]]; then
                log_error "Node number is required"
                exit 1
            fi
            
            local container_name="titan-edge-$(printf "%02d" "$node_num")"
            docker logs -f "$container_name"
            ;;
            
        restart)
            local node_num="${2:-}"
            if [[ -z "$node_num" ]]; then
                log_error "Node number is required"
                exit 1
            fi
            
            local container_name="titan-edge-$(printf "%02d" "$node_num")"
            log_info "Restarting $container_name..."
            docker restart "$container_name"
            log_success "$container_name restarted"
            ;;
            
        update)
            log_info "Updating all nodes to latest image..."
            docker pull "$IMAGE_NAME"
            
            local containers
            containers=$(docker ps --filter "name=titan-edge" --format "{{.Names}}" 2>/dev/null || true)
            
            if [[ -n "$containers" ]]; then
                echo "$containers" | while read -r container; do
                    log_info "Updating $container..."
                    docker stop "$container"
                    docker rm "$container"
                    # Note: This is simplified - in production, you'd want to preserve data
                    docker run -d --name "$container" "$IMAGE_NAME"
                done
            fi
            log_success "All nodes updated"
            ;;
            
        -h|--help)
            show_usage
            ;;
            
        *)
            log_error "Unknown command: ${1:-}"
            show_usage
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"\n\t'       # Secure Internal Field Separator

# Trap function to handle errors but allow controlled exits
trap_handler() {
    local exit_code=$?
    local line_number=$1
    
    if [[ $exit_code -ne 0 ]] && [[ $exit_code -ne 130 ]] && [[ $exit_code -ne 141 ]]; then
        log_error "Script failed at line $line_number with exit code $exit_code"
        
        # Check if we're in deployment and show partial success
        if [[ -n "${deployment_in_progress:-}" ]]; then
            log_info "Checking for any successfully deployed nodes..."
            get_node_status || true
        fi
    fi
    
    cleanup
}

# Set better trap
trap 'trap_handler $LINENO' ERR

# Allow controlled exits without triggering error handler
controlled_exit() {
    local exit_code=${1:-0}
    local message="${2:-}"
    
    # Set flag to prevent error logging
    controlled_exit_flag=true
    
    if [[ -n "$message" ]]; then
        if [[ $exit_code -eq 0 ]]; then
            log_success "$message"
        else
            log_error "$message"
        fi
    fi
    
    cleanup
    exit $exit_code
}

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="${SCRIPT_DIR}/titan-edge.log"
readonly CONFIG_FILE="${SCRIPT_DIR}/titan-edge.conf"
readonly LOCK_FILE="/tmp/titan-edge.lock"

# Default configuration
readonly DEFAULT_IMAGE_NAME="laodauhgc/titan-edge"
readonly DEFAULT_STORAGE_GB=50
readonly DEFAULT_START_PORT=1235
readonly DEFAULT_MAX_NODES=5
readonly DEFAULT_TITAN_EDGE_DIR="/opt/titan-edge"  # More appropriate than /root
readonly DEFAULT_BIND_URL="https://api-test1.container1.titannet.io/api/v2/device/binding"

# Resource limits
readonly DEFAULT_CPU_LIMIT="1"
readonly DEFAULT_MEMORY_LIMIT="1g"
readonly DEFAULT_SWAP_LIMIT="512m"

# Colors for output
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Global variables (loaded from config or defaults)
IMAGE_NAME="${DEFAULT_IMAGE_NAME}"
STORAGE_GB="${DEFAULT_STORAGE_GB}"
START_PORT="${DEFAULT_START_PORT}"
TITAN_EDGE_DIR="${DEFAULT_TITAN_EDGE_DIR}"
BIND_URL="${DEFAULT_BIND_URL}"
CPU_LIMIT="${DEFAULT_CPU_LIMIT}"
MEMORY_LIMIT="${DEFAULT_MEMORY_LIMIT}"

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "${YELLOW}$*${NC}"; }
log_error() { log "ERROR" "${RED}$*${NC}"; }
log_success() { log "SUCCESS" "${GREEN}$*${NC}"; }

# Cleanup function
cleanup() {
    local exit_code=$?
    if [[ -f "$LOCK_FILE" ]]; then
        rm -f "$LOCK_FILE"
    fi
    if [[ $exit_code -ne 0 ]]; then
        log_error "Script exited with error code: $exit_code"
    fi
    exit $exit_code
}

# Set trap for cleanup
trap cleanup EXIT INT TERM

# Lock mechanism to prevent concurrent execution
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            log_error "Another instance is already running (PID: $pid)"
            exit 1
        else
            log_warn "Removing stale lock file"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

# Load configuration from file
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        log_info "Loading configuration from $CONFIG_FILE"
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    else
        log_info "No config file found, creating default configuration"
        create_default_config
    fi
}

# Create default configuration file
create_default_config() {
    cat > "$CONFIG_FILE" << EOF
# Titan Edge Configuration
IMAGE_NAME="$DEFAULT_IMAGE_NAME"
STORAGE_GB=$DEFAULT_STORAGE_GB
START_PORT=$DEFAULT_START_PORT
TITAN_EDGE_DIR="$DEFAULT_TITAN_EDGE_DIR"
BIND_URL="$DEFAULT_BIND_URL"
CPU_LIMIT="$DEFAULT_CPU_LIMIT"
MEMORY_LIMIT="$DEFAULT_MEMORY_LIMIT"

# Network optimization
UDP_RMEM_MAX=2500000
UDP_WMEM_MAX=2500000

# Monitoring
HEALTH_CHECK_INTERVAL=30
MAX_RESTART_ATTEMPTS=3
EOF
    log_success "Default configuration created at $CONFIG_FILE"
}

# Validate configuration
validate_config() {
    local errors=0
    
    if ! [[ "$STORAGE_GB" =~ ^[1-9][0-9]*$ ]] || [[ "$STORAGE_GB" -lt 10 ]] || [[ "$STORAGE_GB" -gt 1000 ]]; then
        log_error "Invalid STORAGE_GB: must be between 10-1000"
        ((errors++))
    fi
    
    if ! [[ "$START_PORT" =~ ^[1-9][0-9]*$ ]] || [[ "$START_PORT" -lt 1024 ]] || [[ "$START_PORT" -gt 65530 ]]; then
        log_error "Invalid START_PORT: must be between 1024-65530"
        ((errors++))
    fi
    
    if [[ $errors -gt 0 ]]; then
        log_error "Configuration validation failed with $errors errors"
        exit 1
    fi
}

# Enhanced root check
check_privileges() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script requires root privileges"
        log_info "Please run with sudo or as root user"
        exit 1
    fi
}

# Check system requirements
check_system_requirements() {
    log_info "Checking system requirements..."
    
    # Check available memory
    local total_mem=$(free -m | awk '/^Mem:/{print $2}')
    local required_mem=1024  # 1GB minimum (reduced from 2GB)
    
    if [[ "$total_mem" -lt "$required_mem" ]]; then
        log_warn "Low memory detected: ${total_mem}MB (recommended: 2GB+)"
    fi
    
    # Check if ports are available
    check_port_availability
    
    log_success "Basic system requirements check passed"
}

# Check port availability
check_port_availability() {
    local port_conflicts=()
    
    for ((i=0; i<DEFAULT_MAX_NODES; i++)); do
        local port=$((START_PORT + i))
        if netstat -tuln 2>/dev/null | grep -q ":${port} " || ss -tuln 2>/dev/null | grep -q ":${port} "; then
            # Check if it's our own container
            if ! docker ps --format '{{.Names}} {{.Ports}}' | grep -q "titan-edge.*:${port}->"; then
                port_conflicts+=("$port")
            fi
        fi
    done
    
    if [[ ${#port_conflicts[@]} -gt 0 ]]; then
        log_error "Port conflicts detected: ${port_conflicts[*]}"
        log_info "Please change START_PORT in configuration or stop services using these ports"
        exit 1
    fi
}

# Enhanced UDP buffer optimization
optimize_network() {
    log_info "Optimizing network settings..."
    
    local current_rmem=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "0")
    local current_wmem=$(sysctl -n net.core.wmem_max 2>/dev/null || echo "0")
    
    log_info "Current UDP buffer values - rmem_max: $current_rmem, wmem_max: $current_wmem"
    
    # Set new values
    local target_rmem=${UDP_RMEM_MAX:-2500000}
    local target_wmem=${UDP_WMEM_MAX:-2500000}
    
    if [[ "$current_rmem" -lt "$target_rmem" ]]; then
        sysctl -w "net.core.rmem_max=$target_rmem" >/dev/null
        update_sysctl_conf "net.core.rmem_max" "$target_rmem"
    fi
    
    if [[ "$current_wmem" -lt "$target_wmem" ]]; then
        sysctl -w "net.core.wmem_max=$target_wmem" >/dev/null
        update_sysctl_conf "net.core.wmem_max" "$target_wmem"
    fi
    
    # Additional network optimizations
    sysctl -w net.core.netdev_max_backlog=5000 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.udp_mem="102400 873800 16777216" >/dev/null 2>&1 || true
    
    log_success "Network optimization completed"
}

# Update sysctl.conf safely
update_sysctl_conf() {
    local key="$1"
    local value="$2"
    local sysctl_conf="/etc/sysctl.conf"
    
    if ! grep -q "^${key}=" "$sysctl_conf" 2>/dev/null; then
        echo "${key}=${value}" >> "$sysctl_conf"
        log_info "Added ${key}=${value} to $sysctl_conf"
    else
        sed -i "s|^${key}=.*|${key}=${value}|" "$sysctl_conf"
        log_info "Updated ${key}=${value} in $sysctl_conf"
    fi
}

# Enhanced Docker installation
install_docker() {
    log_info "Installing Docker..."
    
    if command -v docker >/dev/null 2>&1; then
        log_info "Docker is already installed"
        return 0
    fi
    
    local os_release=""
    if [[ -f /etc/os-release ]]; then
        os_release=$(. /etc/os-release && echo "$ID")
    fi
    
    case "$os_release" in
        ubuntu|debian)
            install_docker_debian
            ;;
        centos|rhel|rocky|almalinux)
            install_docker_rhel
            ;;
        fedora)
            install_docker_fedora
            ;;
        arch|manjaro)
            install_docker_arch
            ;;
        *)
            log_error "Unsupported operating system: $os_release"
            log_info "Please install Docker manually"
            exit 1
            ;;
    esac
    
    # Verify installation
    if ! systemctl is-active --quiet docker; then
        systemctl start docker
        systemctl enable docker
    fi
    
    # Test Docker
    if ! docker version >/dev/null 2>&1; then
        log_error "Docker installation failed"
        exit 1
    fi
    
    log_success "Docker installed and configured successfully"
}

# Docker installation methods
install_docker_debian() {
    apt-get update
    apt-get install -y ca-certificates curl gnupg lsb-release
    
    # Add Docker's official GPG key
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    
    # Set up repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
}

install_docker_rhel() {
    yum install -y yum-utils
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
}

install_docker_fedora() {
    dnf install -y dnf-plugins-core
    dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
    dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
}

install_docker_arch() {
    pacman -Sy --noconfirm docker docker-compose
}

# Enhanced container management
create_node() {
    local node_num="$1"
    local container_name="titan-edge-$(printf "%02d" "$node_num")"
    local port=$((START_PORT + node_num - 1))
    local storage_path="${TITAN_EDGE_DIR}/${container_name}"
    
    log_info "Creating node $container_name on port $port..."
    
    # Create storage directory with proper permissions
    mkdir -p "${storage_path}/.titanedge"
    chmod 755 "${storage_path}"
    
    # Remove existing container if it exists
    if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        log_warn "Removing existing container $container_name"
        docker stop "$container_name" >/dev/null 2>&1 || true
        docker rm "$container_name" >/dev/null 2>&1 || true
    fi
    
    # Create container with resource limits and health checks
    local docker_run_cmd=(
        docker run -d
        --name "$container_name"
        --restart=unless-stopped
        --log-driver=json-file
        --log-opt max-size=10m
        --log-opt max-file=3
        --cpus="$CPU_LIMIT"
        --memory="$MEMORY_LIMIT"
        --memory-swap="$MEMORY_LIMIT"
        --security-opt=no-new-privileges:true
        --read-only=false  # Titan edge needs write access
        -v "${storage_path}/.titanedge:/root/.titanedge:rw"
        -p "${port}:${port}/tcp"
        -p "${port}:${port}/udp"
        --health-cmd="pgrep titan-edge || exit 1"
        --health-interval=30s
        --health-timeout=10s
        --health-retries=3
        "$IMAGE_NAME"
    )
    
    if ! "${docker_run_cmd[@]}"; then
        log_error "Failed to create container $container_name"
        return 1
    fi
    
    # Wait for container to be ready
    if ! wait_for_container_ready "$container_name"; then
        log_error "Container $container_name failed to become ready"
        return 1
    fi
    
    # Configure the node
    if ! configure_node "$container_name" "$port"; then
        log_error "Failed to configure node $container_name"
        return 1
    fi
    
    log_success "Node $container_name created successfully"
    return 0
}

# Enhanced container readiness check
wait_for_container_ready() {
    local container_name="$1"
    local max_attempts=60
    local wait_seconds=2
    
    log_info "Waiting for container $container_name to be ready..."
    
    for ((i=1; i<=max_attempts; i++)); do
        local status
        status=$(docker inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null || echo "not_found")
        
        case "$status" in
            running)
                if docker exec "$container_name" test -f /root/.titanedge/config.toml 2>/dev/null; then
                    log_success "Container $container_name is ready"
                    return 0
                fi
                ;;
            restarting)
                log_warn "Container $container_name is restarting... ($i/$max_attempts)"
                ;;
            exited)
                log_error "Container $container_name exited unexpectedly"
                docker logs --tail 20 "$container_name"
                return 1
                ;;
            not_found)
                log_error "Container $container_name not found"
                return 1
                ;;
            *)
                log_warn "Container $container_name status: $status ($i/$max_attempts)"
                ;;
        esac
        
        sleep $wait_seconds
    done
    
    log_error "Container $container_name failed to become ready after $((max_attempts * wait_seconds)) seconds"
    docker logs --tail 50 "$container_name"
    return 1
}

# Node configuration
configure_node() {
    local container_name="$1"
    local port="$2"
    
    log_info "Configuring node $container_name..."
    
    # Create configuration script
    local config_script=$(cat << EOF
#!/bin/bash
set -e

CONFIG_FILE="/root/.titanedge/config.toml"
if [[ ! -f "\$CONFIG_FILE" ]]; then
    echo "Config file not found"
    exit 1
fi

# Backup original config
cp "\$CONFIG_FILE" "\$CONFIG_FILE.backup"

# Update configuration
sed -i 's/^[[:space:]]*#*StorageGB = .*/StorageGB = $STORAGE_GB/' "\$CONFIG_FILE"
sed -i 's/^[[:space:]]*#*ListenAddress = .*/ListenAddress = "0.0.0.0:$port"/' "\$CONFIG_FILE"

# Verify changes
if ! grep -q "StorageGB = $STORAGE_GB" "\$CONFIG_FILE"; then
    echo "Failed to set StorageGB"
    exit 1
fi

if ! grep -q "ListenAddress = \"0.0.0.0:$port\"" "\$CONFIG_FILE"; then
    echo "Failed to set ListenAddress"
    exit 1
fi

echo "Configuration updated successfully"
EOF
)
    
    if ! docker exec "$container_name" bash -c "$config_script"; then
        log_error "Failed to configure $container_name"
        return 1
    fi
    
    # Restart container to apply configuration
    log_info "Restarting $container_name to apply configuration..."
    if ! docker restart "$container_name" >/dev/null; then
        log_error "Failed to restart $container_name"
        return 1
    fi
    
    # Wait for restart
    sleep 5
    if ! wait_for_container_ready "$container_name"; then
        log_error "Container $container_name failed to start after configuration"
        return 1
    fi
    
    return 0
}

# Bind node to network
bind_node() {
    local container_name="$1"
    local hash_value="$2"
    local max_attempts=3
    
    log_info "Binding $container_name to Titan network..."
    
    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        if docker exec "$container_name" titan-edge bind --hash="$hash_value" "$BIND_URL"; then
            log_success "Node $container_name bound successfully"
            return 0
        else
            log_warn "Bind attempt $attempt/$max_attempts failed for $container_name"
            sleep 5
        fi
    done
    
    log_error "Failed to bind node $container_name after $max_attempts attempts"
    return 1
}

# Enhanced cleanup function
cleanup_nodes() {
    log_info "Removing all Titan Edge containers and data..."
    
    local containers
    containers=$(docker ps -a --filter "name=titan-edge" --format "{{.Names}}" 2>/dev/null || true)
    
    if [[ -n "$containers" ]]; then
        echo "$containers" | while read -r container; do
            log_info "Stopping and removing container $container..."
            docker stop "$container" >/dev/null 2>&1 || true
            docker rm -f "$container" >/dev/null 2>&1 || true
        done
        log_success "All Titan Edge containers removed"
    else
        log_info "No Titan Edge containers found"
    fi
    
    # Remove data directories
    if [[ -d "$TITAN_EDGE_DIR" ]]; then
        log_info "Removing data directory $TITAN_EDGE_DIR..."
        rm -rf "$TITAN_EDGE_DIR"
        log_success "Data directory removed"
    fi
    
    # Remove docker volumes
    local volumes
    volumes=$(docker volume ls --filter "name=titan" --format "{{.Name}}" 2>/dev/null || true)
    
    if [[ -n "$volumes" ]]; then
        echo "$volumes" | while read -r volume; do
            log_info "Removing volume $volume..."
            docker volume rm "$volume" >/dev/null 2>&1 || true
        done
        log_success "All Titan Edge volumes removed"
    fi
    
    log_success "Cleanup completed successfully"
}

# Get node status
get_node_status() {
    local containers
    containers=$(docker ps -a --filter "name=titan-edge" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true)
    
    if [[ -n "$containers" ]]; then
        echo -e "${CYAN}Current Titan Edge Nodes:${NC}"
        echo "$containers"
        
        # Show resource usage
        echo -e "\n${CYAN}Resource Usage:${NC}"
        docker stats --no-stream --filter "name=titan-edge" --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}"
    else
        echo -e "${YELLOW}No Titan Edge containers found${NC}"
    fi
}

# Show usage information
show_usage() {
    cat << EOF
${CYAN}Titan Edge Node Management Script v2.0${NC}

${YELLOW}USAGE:${NC}
    $0 <command> [options]

${YELLOW}COMMANDS:${NC}
    deploy <hash> [count]    Deploy nodes with hash (default count: 5)
    remove                   Remove all nodes and data
    status                   Show node status and resource usage
    config                   Show current configuration
    logs <node_number>       Show logs for specific node
    restart <node_number>    Restart specific node
    update                   Update all nodes to latest image

${YELLOW}OPTIONS:${NC}
    -h, --help              Show this help message
    -c, --config <file>     Use custom configuration file
    -v, --verbose           Enable verbose logging
    --full-checks           Enable comprehensive system checks (disk, memory)

${YELLOW}EXAMPLES:${NC}
    $0 deploy abc123                # Deploy 5 nodes (default) with hash abc123
    $0 deploy abc123 3              # Deploy 3 nodes with hash abc123
    $0 deploy abc123 --full-checks  # Deploy with comprehensive system checks
    $0 status                       # Show current node status
    $0 logs 1                       # Show logs for node 01
    $0 remove                       # Remove all nodes

${YELLOW}FILES:${NC}
    Config: $CONFIG_FILE
    Logs:   $LOG_FILE

${YELLOW}NOTE:${NC}
    - Default deployment: 5 nodes without disk space checks
    - Use --full-checks for comprehensive system validation
EOF
}

# Main execution function
main() {
    # Parse options
    local full_checks=false
    local args=()
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --full-checks)
                full_checks=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done
    
    # Restore positional parameters
    set -- "${args[@]}"
    
    # Initialize
    acquire_lock
    load_config
    validate_config
    
    case "${1:-}" in
        deploy)
            check_privileges
            
            # Always run basic checks, but skip disk check by default
            if [[ "$full_checks" == "true" ]]; then
                log_info "Running comprehensive system checks (including disk space)..."
                check_system_requirements_full
            else
                check_system_requirements
            fi
            
            install_docker
            optimize_network
            
            local hash_value="${2:-}"
            local node_count="${3:-5}"  # Default to 5 nodes
            
            if [[ -z "$hash_value" ]]; then
                log_error "Hash value is required for deployment"
                show_usage
                exit 1
            fi
            
            if ! [[ "$node_count" =~ ^[1-5]$ ]]; then
                log_error "Node count must be between 1 and 5"
                exit 1
            fi
            
            log_info "Deploying $node_count Titan Edge nodes..."
            
            # Pull latest image
            log_info "Pulling Docker image $IMAGE_NAME..."
            docker pull "$IMAGE_NAME"
            
            # Deploy nodes
            local success_count=0
            local failed_nodes=()
            
            for ((i=1; i<=node_count; i++)); do
                log_info "Processing node $i of $node_count..."
                
                if create_node "$i"; then
                    local container_name="titan-edge-$(printf "%02d" "$i")"
                    if bind_node "$container_name" "$hash_value"; then
                        ((success_count++))
                        log_success "Node $i deployed and bound successfully"
                    else
                        failed_nodes+=("$i (bind failed)")
                        log_error "Node $i created but binding failed"
                    fi
                else
                    failed_nodes+=("$i (creation failed)")
                    log_error "Failed to create node $i"
                fi
            done
            
            # Report results
            log_info "Deployment summary:"
            log_info "- Successfully deployed: $success_count/$node_count nodes"
            
            if [[ ${#failed_nodes[@]} -gt 0 ]]; then
                log_warn "- Failed nodes: ${failed_nodes[*]}"
            fi
            
            if [[ $success_count -gt 0 ]]; then
                log_success "Deployment completed with $success_count active nodes"
                get_node_status
            else
                log_error "No nodes were successfully deployed"
                exit 1
            fi
            ;;
            
        remove)
            check_privileges
            cleanup_nodes
            ;;
            
        status)
            get_node_status
            ;;
            
        config)
            echo -e "${CYAN}Current Configuration:${NC}"
            cat "$CONFIG_FILE"
            ;;
            
        logs)
            local node_num="${2:-}"
            if [[ -z "$node_num" ]]; then
                log_error "Node number is required"
                exit 1
            fi
            
            local container_name="titan-edge-$(printf "%02d" "$node_num")"
            docker logs -f "$container_name"
            ;;
            
        restart)
            local node_num="${2:-}"
            if [[ -z "$node_num" ]]; then
                log_error "Node number is required"
                exit 1
            fi
            
            local container_name="titan-edge-$(printf "%02d" "$node_num")"
            log_info "Restarting $container_name..."
            docker restart "$container_name"
            log_success "$container_name restarted"
            ;;
            
        update)
            log_info "Updating all nodes to latest image..."
            docker pull "$IMAGE_NAME"
            
            local containers
            containers=$(docker ps --filter "name=titan-edge" --format "{{.Names}}" 2>/dev/null || true)
            
            if [[ -n "$containers" ]]; then
                echo "$containers" | while read -r container; do
                    log_info "Updating $container..."
                    docker stop "$container"
                    docker rm "$container"
                    # Note: This is simplified - in production, you'd want to preserve data
                    docker run -d --name "$container" "$IMAGE_NAME"
                done
            fi
            log_success "All nodes updated"
            ;;
            
        -h|--help)
            show_usage
            ;;
            
        *)
            log_error "Unknown command: ${1:-}"
            show_usage
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"
