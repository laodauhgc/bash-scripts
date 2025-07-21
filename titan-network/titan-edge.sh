#!/bin/bash

# Simple Titan Edge Node Deployment Script
# Fixed version without complex error handling

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
IMAGE_NAME="laodauhgc/titan-edge"
STORAGE_GB=50
START_PORT=1235
TITAN_EDGE_DIR="/opt/titan-edge"
BIND_URL="https://api-test1.container1.titannet.io/api/v2/device/binding"

# Logging functions
log_info() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $*"; }
log_warn() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') [WARN] ${YELLOW}$*${NC}"; }
log_error() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] ${RED}$*${NC}"; }
log_success() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') [SUCCESS] ${GREEN}$*${NC}"; }

# Check root privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script requires root privileges"
        exit 1
    fi
}

# Install Docker if needed
install_docker() {
    if command -v docker >/dev/null 2>&1; then
        log_info "Docker is already installed"
        return 0
    fi
    
    log_info "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl start docker
    systemctl enable docker
    
    if ! docker version >/dev/null 2>&1; then
        log_error "Docker installation failed"
        exit 1
    fi
    
    log_success "Docker installed successfully"
}

# Optimize network
optimize_network() {
    log_info "Optimizing network settings..."
    
    sysctl -w net.core.rmem_max=2500000 >/dev/null 2>&1 || true
    sysctl -w net.core.wmem_max=2500000 >/dev/null 2>&1 || true
    
    # Make persistent
    if ! grep -q "net.core.rmem_max" /etc/sysctl.conf 2>/dev/null; then
        echo "net.core.rmem_max=2500000" >> /etc/sysctl.conf
    fi
    
    if ! grep -q "net.core.wmem_max" /etc/sysctl.conf 2>/dev/null; then
        echo "net.core.wmem_max=2500000" >> /etc/sysctl.conf
    fi
    
    log_success "Network optimization completed"
}

# Wait for container to be ready
wait_container_ready() {
    local container_name="$1"
    local max_attempts=30
    
    log_info "Waiting for container $container_name to be ready..."
    
    for ((i=1; i<=max_attempts; i++)); do
        if docker exec "$container_name" test -f /root/.titanedge/config.toml 2>/dev/null; then
            log_success "Container $container_name is ready"
            return 0
        fi
        
        local status=$(docker inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null || echo "unknown")
        if [[ "$status" == "exited" ]]; then
            log_error "Container $container_name exited unexpectedly"
            docker logs "$container_name"
            return 1
        fi
        
        echo -n "."
        sleep 2
    done
    
    log_error "Container $container_name failed to become ready"
    return 1
}

# Configure node
configure_node() {
    local container_name="$1"
    local port="$2"
    
    log_info "Configuring node $container_name for port $port..."
    
    # Update config.toml
    docker exec "$container_name" bash -c "
        sed -i 's/^[[:space:]]*#*StorageGB = .*/StorageGB = $STORAGE_GB/' /root/.titanedge/config.toml
        sed -i 's/^[[:space:]]*#*ListenAddress = .*/ListenAddress = \"0.0.0.0:$port\"/' /root/.titanedge/config.toml
    "
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to configure $container_name"
        return 1
    fi
    
    # Restart container
    log_info "Restarting $container_name to apply configuration..."
    docker restart "$container_name" >/dev/null
    
    sleep 5
    wait_container_ready "$container_name"
    return $?
}

# Bind node to network
bind_node() {
    local container_name="$1"
    local hash_value="$2"
    
    log_info "Binding $container_name to Titan network..."
    
    local attempts=3
    for ((i=1; i<=attempts; i++)); do
        if docker exec "$container_name" titan-edge bind --hash="$hash_value" "$BIND_URL"; then
            log_success "Node $container_name bound successfully"
            return 0
        fi
        
        if [[ $i -lt $attempts ]]; then
            log_warn "Bind attempt $i failed, retrying..."
            sleep 5
        fi
    done
    
    log_error "Failed to bind $container_name after $attempts attempts"
    return 1
}

# Create a single node
create_node() {
    local node_num="$1"
    local container_name="titan-edge-$(printf "%02d" "$node_num")"
    local port=$((START_PORT + node_num - 1))
    local storage_path="${TITAN_EDGE_DIR}/${container_name}"
    
    log_info "Creating node $container_name on port $port..."
    
    # Create storage directory
    mkdir -p "${storage_path}/.titanedge"
    
    # Remove existing container if exists
    if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        log_warn "Removing existing container $container_name"
        docker stop "$container_name" >/dev/null 2>&1 || true
        docker rm "$container_name" >/dev/null 2>&1 || true
    fi
    
    # Create container
    docker run -d \
        --name "$container_name" \
        --restart=unless-stopped \
        -v "${storage_path}/.titanedge:/root/.titanedge:rw" \
        -p "${port}:${port}/tcp" \
        -p "${port}:${port}/udp" \
        "$IMAGE_NAME"
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to create container $container_name"
        return 1
    fi
    
    # Wait for container to be ready
    if ! wait_container_ready "$container_name"; then
        return 1
    fi
    
    # Configure the node
    if ! configure_node "$container_name" "$port"; then
        return 1
    fi
    
    log_success "Node $container_name created successfully"
    return 0
}

# Deploy nodes
deploy_nodes() {
    local hash_value="$1"
    local node_count="$2"
    
    if [[ -z "$hash_value" ]]; then
        log_error "Hash value is required"
        return 1
    fi
    
    if [[ -z "$node_count" ]] || ! [[ "$node_count" =~ ^[1-5]$ ]]; then
        log_error "Node count must be between 1 and 5"
        return 1
    fi
    
    log_info "Starting deployment of $node_count nodes with hash: $hash_value"
    
    # Pull Docker image
    log_info "Pulling Docker image $IMAGE_NAME..."
    docker pull "$IMAGE_NAME"
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to pull Docker image"
        return 1
    fi
    
    # Deploy each node
    local success_count=0
    local failed_nodes=()
    
    for ((i=1; i<=node_count; i++)); do
        log_info "Deploying node $i of $node_count..."
        
        if create_node "$i"; then
            local container_name="titan-edge-$(printf "%02d" "$i")"
            if bind_node "$container_name" "$hash_value"; then
                ((success_count++))
                log_success "Node $i deployed successfully"
            else
                failed_nodes+=("$i")
                log_error "Node $i created but binding failed"
            fi
        else
            failed_nodes+=("$i")
            log_error "Failed to create node $i"
        fi
    done
    
    # Show summary
    echo
    log_info "=== DEPLOYMENT SUMMARY ==="
    log_info "Successfully deployed: $success_count/$node_count nodes"
    
    if [[ ${#failed_nodes[@]} -gt 0 ]]; then
        log_warn "Failed nodes: ${failed_nodes[*]}"
    fi
    
    if [[ $success_count -gt 0 ]]; then
        echo
        log_info "Current node status:"
        docker ps --filter "name=titan-edge" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        
        log_success "Deployment completed with $success_count active nodes"
        return 0
    else
        log_error "No nodes were successfully deployed"
        return 1
    fi
}

# Remove all nodes
remove_nodes() {
    log_info "Removing all Titan Edge nodes..."
    
    # Stop and remove containers
    local containers=$(docker ps -a --filter "name=titan-edge" --format "{{.Names}}" 2>/dev/null || true)
    
    if [[ -n "$containers" ]]; then
        echo "$containers" | while read -r container; do
            log_info "Removing container $container..."
            docker stop "$container" >/dev/null 2>&1 || true
            docker rm "$container" >/dev/null 2>&1 || true
        done
        log_success "All containers removed"
    fi
    
    # Remove data directory
    if [[ -d "$TITAN_EDGE_DIR" ]]; then
        log_info "Removing data directory $TITAN_EDGE_DIR..."
        rm -rf "$TITAN_EDGE_DIR"
        log_success "Data directory removed"
    fi
    
    log_success "Cleanup completed"
}

# Show node status
show_status() {
    local containers=$(docker ps -a --filter "name=titan-edge" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true)
    
    if [[ -n "$containers" ]]; then
        echo -e "${BLUE}Current Titan Edge Nodes:${NC}"
        echo "$containers"
        
        echo -e "\n${BLUE}Resource Usage:${NC}"
        docker stats --no-stream --filter "name=titan-edge" --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" 2>/dev/null || echo "No running containers"
    else
        log_info "No Titan Edge containers found"
    fi
}

# Show usage
show_usage() {
    cat << EOF
${BLUE}Simple Titan Edge Deployment Script${NC}

${YELLOW}USAGE:${NC}
    $0 deploy <hash> [node_count]    Deploy nodes (default: 5)
    $0 remove                        Remove all nodes
    $0 status                        Show node status
    $0 logs <node_number>           Show logs for node

${YELLOW}EXAMPLES:${NC}
    $0 deploy abc123                 Deploy 5 nodes
    $0 deploy abc123 3               Deploy 3 nodes
    $0 status                        Show status
    $0 logs 1                        Show logs for node 01
    $0 remove                        Remove all nodes
EOF
}

# Main function
main() {
    case "${1:-}" in
        deploy)
            check_root
            install_docker
            optimize_network
            
            local hash_value="${2:-}"
            local node_count="${3:-5}"  # Default to 5
            
            deploy_nodes "$hash_value" "$node_count"
            ;;
            
        remove)
            check_root
            remove_nodes
            ;;
            
        status)
            show_status
            ;;
            
        logs)
            local node_num="${2:-}"
            if [[ -z "$node_num" ]]; then
                log_error "Node number required"
                exit 1
            fi
            
            local container_name="titan-edge-$(printf "%02d" "$node_num")"
            docker logs -f "$container_name"
            ;;
            
        *)
            show_usage
            ;;
    esac
}

# Run main function
main "$@"
