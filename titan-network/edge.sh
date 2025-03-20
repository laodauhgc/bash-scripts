#!/bin/bash

# Function to display colored text
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Check if the script is run as root
if [[ "$(id -u)" -ne "0" ]]; then
    echo -e "${YELLOW}This script requires root access.${NC}"
    echo -e "${YELLOW}Please enter root mode using 'sudo -i', then rerun this script.${NC}"
    exit 1
fi

# Get hash value from command line argument
hash_value="${1:-}"

# Get node count from command line argument, default to 5
node_count="${2:-5}"

# Check if hash_value is empty
if [[ -z "$hash_value" ]]; then
    echo -e "${YELLOW}No hash value provided via command line. Please provide a hash value when running this script. ${NC}"
    exit 1
fi

# Validate node count, ensure between 1 and 5
if ! [[ "$node_count" =~ ^[1-5]$ ]]; then
    echo -e "${YELLOW}Invalid node count provided. Please provide a node count between 1 and 5.${NC}"
    echo -e "${YELLOW}Running with default node count : 5.${NC}"
    node_count=5
fi

# Configuration
IMAGE_NAME="nezha123/titan-edge"
STORAGE_GB=50
START_PORT=1235
CONTAINER_COUNT=$node_count
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

# Create Titan Edge directory
mkdir -p "$TITAN_EDGE_DIR"
if [[ $? -ne 0 ]]; then
    echo -e "${RED}Failed to create Titan Edge directory.${NC}"
    exit 1
fi

# Function to check if container is ready by testing its port
check_container_ready() {
    local container_name=$1
    local port=$2
    local max_attempts=30
    local wait_seconds=2
    
    echo -e "${YELLOW}Waiting for container ${container_name} to be ready...${NC}"
    
    for ((i=1; i<=max_attempts; i++)); do
        # Check if the process is running and listening on the port
        if docker exec "$container_name" bash -c "ss -tulnp | grep -q :$port"; then
            echo -e "${GREEN}✓ Container ${container_name} is ready!${NC}"
            return 0
        fi
        
        echo -e "${YELLOW}Waiting for container to be ready... Attempt $i/$max_attempts${NC}"
        sleep $wait_seconds
    done
    
    echo -e "${RED}Container ${container_name} failed to become ready after $((max_attempts * wait_seconds)) seconds.${NC}"
    return 1
}

# Loop through container count
for ((i=1; i<=$CONTAINER_COUNT; i++)); do
    # Define storage path, container name and current port
    STORAGE_PATH="$TITAN_EDGE_DIR/titan-edge-0${i}"
    CONTAINER_NAME="titan-edge-0${i}"
    CURRENT_PORT=$((START_PORT + i - 1))

    echo -e "${GREEN}Setting up node ${CONTAINER_NAME} on port ${CURRENT_PORT}...${NC}"

    # Ensure storage path exists
    mkdir -p "$STORAGE_PATH/.titanedge"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Failed to create storage path for container ${CONTAINER_NAME}.${NC}"
        exit 1
    fi

    # Run the container
    docker run -d \
        --name "$CONTAINER_NAME" \
        -v "$STORAGE_PATH/.titanedge:/root/.titanedge" \
        -p "$CURRENT_PORT:$CURRENT_PORT" \
        --restart always \
        "$IMAGE_NAME" \
        daemon start --listen-address="0.0.0.0:$CURRENT_PORT" --url https://cassini-locator.titannet.io:5000/rpc/v0

    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Failed to start container ${CONTAINER_NAME}.${NC}"
        exit 1
    fi

    echo -e "${GREEN}Container ${CONTAINER_NAME} is starting...${NC}"

    # Check if the container is ready before binding
    check_container_ready "$CONTAINER_NAME" "$CURRENT_PORT"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Failed to confirm container ${CONTAINER_NAME} is ready. Continuing anyway...${NC}"
    fi

    # Bind the node
    echo -e "${YELLOW}Binding ${CONTAINER_NAME} to Titan network...${NC}"
    docker exec "$CONTAINER_NAME" titan-edge bind --hash="$hash_value" "$BIND_URL"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Failed to bind node ${CONTAINER_NAME}.${NC}"
        exit 1
    fi

    echo -e "${GREEN}✓ Node ${CONTAINER_NAME} has been successfully initialized.${NC}"
done

echo -e "${GREEN}🚀 All nodes are up and running!${NC}"

# Display instructions for checking node status
echo -e "${YELLOW}To check the status of your nodes, run:${NC}"
echo -e "    docker ps -a"
echo -e "${YELLOW}To view logs of a specific node, run:${NC}"
echo -e "    docker logs titan-edge-0<number>"
echo -e "${YELLOW}To enter a node's shell, run:${NC}"
echo -e "    docker exec -it titan-edge-0<number> bash"

exit 0
