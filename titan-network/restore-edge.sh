#!/bin/bash

# Function to display colored text
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if the script is run as root
if [[ "$(id -u)" -ne "0" ]]; then
    echo -e "${YELLOW}This script requires root access.${NC}"
    echo -e "${YELLOW}Please enter root mode using 'sudo -i', then rerun this script.${NC}"
    exit 1
fi

# Configuration
IMAGE_NAME="nezha123/titan-edge"
TITAN_EDGE_DIR="/root/titan-edge"
BIND_URL="https://api-test1.container1.titannet.io/api/v2/device/binding"

# Function to check if a command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Function to install Docker
install_docker() {
    echo -e "${GREEN}Installing Docker...${NC}"

    if command_exists apt-get; then
        apt-get update && apt-get install -y ca-certificates curl gnupg lsb-release docker.io
    elif command_exists yum; then
        yum install -y yum-utils docker
    elif command_exists dnf; then
        dnf install -y docker
    elif command_exists pacman; then
        pacman -S --noconfirm docker
    else
        echo -e "${RED}Could not determine package manager. Please install Docker manually.${NC}"
        exit 1
    fi

    systemctl start docker
    systemctl enable docker

    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Failed to install or start Docker.${NC}"
        exit 1
    fi
}

# Check if the backup directory exists
if [[ ! -d "$TITAN_EDGE_DIR" ]]; then
    echo -e "${RED}Backup directory $TITAN_EDGE_DIR does not exist.${NC}"
    echo -e "${YELLOW}Please make sure you have copied the backup directory to this server.${NC}"
    exit 1
fi

# Check if Docker is installed
if ! command_exists docker; then
    install_docker
else
    echo -e "${GREEN}Docker is already installed.${NC}"
fi

# Pull the Docker image
echo -e "${GREEN}Pulling the Docker image ${IMAGE_NAME}...${NC}"
docker pull "$IMAGE_NAME"
if [[ $? -ne 0 ]]; then
    echo -e "${RED}Failed to pull Docker image.${NC}"
    exit 1
fi

# Function to check if container is ready
check_container_ready() {
    local container_name=$1
    local max_attempts=30
    local wait_seconds=2
    
    echo -e "${YELLOW}Waiting for container ${container_name} to be ready...${NC}"
    
    for ((i=1; i<=max_attempts; i++)); do
        # Check container status
        status=$(docker inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null)
        
        if [[ "$status" == "running" ]]; then
            echo -e "${GREEN}✓ Container ${container_name} is running!${NC}"
            return 0
        elif [[ "$status" == "restarting" ]]; then
            echo -e "${YELLOW}Container ${container_name} is restarting... Attempt $i/$max_attempts${NC}"
            
            # Show logs if container is restarting and we've waited a while
            if [[ $i -eq 10 ]]; then
                echo -e "${RED}Container is restarting. Showing logs:${NC}"
                docker logs "$container_name"
            fi
        else
            echo -e "${YELLOW}Container ${container_name} status: $status ... Attempt $i/$max_attempts${NC}"
        fi
        
        sleep $wait_seconds
    done
    
    echo -e "${RED}Container ${container_name} failed to become ready after $((max_attempts * wait_seconds)) seconds.${NC}"
    docker logs "$container_name"
    return 1
}

# Function to extract listen address from config.toml
extract_listen_address() {
    local config_file="$1"
    local listen_address=""
    
    if [[ -f "$config_file" ]]; then
        # First try the uncommented version
        listen_address=$(grep -E "^ListenAddress" "$config_file" | cut -d '"' -f 2)
        
        # If not found, try the commented version and extract the port
        if [[ -z "$listen_address" ]]; then
            listen_address=$(grep -E "^#ListenAddress" "$config_file" | cut -d '"' -f 2)
            # If still using default commented value, use the node number to determine port
            if [[ "$listen_address" == "0.0.0.0:1234" || -z "$listen_address" ]]; then
                node_num=$(echo "$config_file" | grep -o "titan-edge-0[0-9]" | grep -o "[0-9]$")
                if [[ -n "$node_num" ]]; then
                    listen_address="0.0.0.0:$((1234 + node_num))"
                else
                    listen_address="0.0.0.0:1234"  # Default fallback
                fi
            fi
        fi
    fi
    
    echo "$listen_address"
}

# Find all titan-edge directories
titan_dirs=$(find "$TITAN_EDGE_DIR" -type d -name "titan-edge-*" | sort)

if [[ -z "$titan_dirs" ]]; then
    echo -e "${RED}No Titan Edge backup directories found in $TITAN_EDGE_DIR${NC}"
    exit 1
fi

# Count of restored containers
restored_count=0

# Process each directory
for dir in $titan_dirs; do
    node_name=$(basename "$dir")
    
    echo -e "${BLUE}====== Processing $node_name ======${NC}"
    
    # Check if .titanedge directory exists
    if [[ ! -d "$dir/.titanedge" ]]; then
        echo -e "${YELLOW}Warning: No .titanedge directory found in $dir, skipping...${NC}"
        continue
    fi
    
    # Check if config.toml exists
    if [[ ! -f "$dir/.titanedge/config.toml" ]]; then
        echo -e "${YELLOW}Warning: No config.toml found in $dir/.titanedge, skipping...${NC}"
        continue
    fi
    
    # Extract port from config.toml
    listen_address=$(extract_listen_address "$dir/.titanedge/config.toml")
    
    if [[ -z "$listen_address" ]]; then
        echo -e "${YELLOW}Warning: Could not determine listen address from config.toml, using default port...${NC}"
        node_num=$(echo "$node_name" | grep -o "[0-9]$")
        listen_address="0.0.0.0:$((1234 + node_num))"
    fi
    
    # Extract port from listen address
    port=$(echo "$listen_address" | cut -d ':' -f 2)
    
    echo -e "${GREEN}Node: $node_name, Port: $port${NC}"
    
    # Check if container already exists
    if docker ps -a --format '{{.Names}}' | grep -q "^$node_name$"; then
        echo -e "${YELLOW}Container $node_name already exists. Removing it...${NC}"
        docker rm -f "$node_name" >/dev/null 2>&1
    fi
    
    # Run the container
    echo -e "${YELLOW}Starting container $node_name on port $port...${NC}"
    docker run -d \
        --name "$node_name" \
        -v "$dir/.titanedge:/root/.titanedge" \
        -p "$port:$port/tcp" \
        -p "$port:$port/udp" \
        --restart always \
        "$IMAGE_NAME"
    
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Failed to start container $node_name.${NC}"
        continue
    fi
    
    # Wait for container to be ready
    check_container_ready "$node_name"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Container $node_name failed to start properly.${NC}"
        continue
    fi
    
    echo -e "${GREEN}✓ Node $node_name has been successfully restored.${NC}"
    restored_count=$((restored_count + 1))
done

# Summary
if [[ $restored_count -gt 0 ]]; then
    echo -e "${GREEN}🚀 Restoration complete! Successfully restored $restored_count Titan Edge nodes.${NC}"
else
    echo -e "${RED}No Titan Edge nodes were restored.${NC}"
fi

# Display instructions for checking node status
echo -e "${YELLOW}To check the status of your nodes, run:${NC}"
echo -e "    docker ps -a"
echo -e "${YELLOW}To view logs of a specific node, run:${NC}"
echo -e "    docker logs <node-name>"
echo -e "${YELLOW}To enter a node's shell, run:${NC}"
echo -e "    docker exec -it <node-name> bash"

exit 0
