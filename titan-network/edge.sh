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

# Check for remove parameter
if [[ "$1" == "rm" || "$1" == "remove" || "$1" == "-rm" || "$1" == "--rm" ]]; then
    echo -e "${YELLOW}⚠️ Removing all Titan Edge containers, volumes and directories...${NC}"
    
    # Stop and remove all titan-edge containers
    echo -e "${YELLOW}Stopping and removing containers...${NC}"
    titan_containers=$(docker ps -a --filter "name=titan-edge" --format "{{.Names}}")
    
    if [[ -n "$titan_containers" ]]; then
        for container in $titan_containers; do
            echo -e "Removing container ${container}..."
            docker stop "$container" >/dev/null 2>&1
            docker rm -f "$container" >/dev/null 2>&1
        done
        echo -e "${GREEN}✓ All Titan Edge containers removed.${NC}"
    else
        echo -e "${YELLOW}No Titan Edge containers found.${NC}"
    fi
    
    # Remove the titan-edge directories
    echo -e "${YELLOW}Removing Titan Edge directories...${NC}"
    if [[ -d "/root/titan-edge" ]]; then
        rm -rf /root/titan-edge
        echo -e "${GREEN}✓ Directory /root/titan-edge removed.${NC}"
    else
        echo -e "${YELLOW}Directory /root/titan-edge not found.${NC}"
    fi
    
    # Check and remove any other titan edge related directories
    if [[ -d "/root/.titanedge" ]]; then
        rm -rf /root/.titanedge
        echo -e "${GREEN}✓ Directory /root/.titanedge removed.${NC}"
    fi
    
    # Remove titan-related docker volumes (if any)
    echo -e "${YELLOW}Checking for Titan Edge related Docker volumes...${NC}"
    titan_volumes=$(docker volume ls --filter "name=titan" --format "{{.Name}}" 2>/dev/null)
    
    if [[ -n "$titan_volumes" ]]; then
        for volume in $titan_volumes; do
            echo -e "Removing volume ${volume}..."
            docker volume rm "$volume" >/dev/null 2>&1
        done
        echo -e "${GREEN}✓ All Titan Edge volumes removed.${NC}"
    else
        echo -e "${YELLOW}No Titan Edge volumes found.${NC}"
    fi
    
    echo -e "${GREEN}🧹 Cleanup complete! All Titan Edge resources have been removed.${NC}"
    exit 0
fi

# Get hash value from command line argument
hash_value="${1:-}"

# Get node count from command line argument, default to 5
node_count="${2:-5}"

# Check if hash_value is empty
if [[ -z "$hash_value" ]]; then
    echo -e "${YELLOW}No hash value provided via command line. Please provide a hash value when running this script. ${NC}"
    echo -e "${YELLOW}Or use 'rm' parameter to remove all Titan Edge containers and directories. ${NC}"
    echo -e "${YELLOW}Usage: $0 <hash_value> [node_count]${NC}"
    echo -e "${YELLOW}       $0 rm${NC}"
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
            # Check if config.toml exists
            if docker exec "$container_name" test -f /root/.titanedge/config.toml; then
                echo -e "${GREEN}✓ Container ${container_name} is ready with config.toml!${NC}"
                return 0
            else
                echo -e "${YELLOW}Container ${container_name} is running but config.toml not found yet... Attempt $i/$max_attempts${NC}"
            fi
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

# Loop through container count
for ((i=1; i<=$CONTAINER_COUNT; i++)); do
    # Define storage path, container name and current port
    STORAGE_PATH="$TITAN_EDGE_DIR/titan-edge-0${i}"
    CONTAINER_NAME="titan-edge-0${i}"
    CURRENT_PORT=$((START_PORT + i - 1))

    echo -e "${GREEN}Setting up node ${CONTAINER_NAME} on port ${CURRENT_PORT}...${NC}"

    # Clean up if container already exists
    if docker ps -a --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
        echo -e "${YELLOW}Container ${CONTAINER_NAME} already exists. Removing it...${NC}"
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
    fi

    # Ensure storage path exists with proper permissions
    mkdir -p "$STORAGE_PATH/.titanedge"
    chmod -R 777 "$STORAGE_PATH/.titanedge"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Failed to create storage path for container ${CONTAINER_NAME}.${NC}"
        exit 1
    fi

    # Run the container with daemon start
    echo -e "${YELLOW}Starting container ${CONTAINER_NAME}...${NC}"
    docker run -d \
        --name "$CONTAINER_NAME" \
        -v "$STORAGE_PATH/.titanedge:/root/.titanedge" \
        -p "$CURRENT_PORT:$CURRENT_PORT" \
        --restart always \
        "$IMAGE_NAME"

    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Failed to start container ${CONTAINER_NAME}.${NC}"
        exit 1
    fi
    
    # Start the daemon
    echo -e "${YELLOW}Starting daemon in ${CONTAINER_NAME}...${NC}"
    docker exec "$CONTAINER_NAME" titan-edge daemon start --url https://cassini-locator.titannet.io:5000/rpc/v0
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Failed to start daemon in ${CONTAINER_NAME}.${NC}"
        docker logs "$CONTAINER_NAME"
        exit 1
    fi

    # Wait for container to be ready and config.toml to be generated
    check_container_ready "$CONTAINER_NAME"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Failed to confirm container ${CONTAINER_NAME} is ready. Stopping script.${NC}"
        exit 1
    fi

    # Modify config.toml to set the port and storage size
    echo -e "${YELLOW}Configuring port ${CURRENT_PORT} and storage for ${CONTAINER_NAME}...${NC}"
    docker exec "$CONTAINER_NAME" bash -c "sed -i 's/^[[:space:]]*#StorageGB = .*/StorageGB = $STORAGE_GB/' /root/.titanedge/config.toml && \
                                         sed -i 's/^[[:space:]]*#ListenAddress = \"0.0.0.0:1234\"/ListenAddress = \"0.0.0.0:$CURRENT_PORT\"/' /root/.titanedge/config.toml"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Failed to configure port and storage for ${CONTAINER_NAME}.${NC}"
        exit 1
    fi

    # Restart container to apply new configuration
    echo -e "${YELLOW}Restarting ${CONTAINER_NAME} to apply configuration...${NC}"
    docker restart "$CONTAINER_NAME"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Failed to restart ${CONTAINER_NAME}.${NC}"
        exit 1
    fi

    # Wait for container to be ready again
    sleep 10
    check_container_ready "$CONTAINER_NAME"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Failed to confirm container ${CONTAINER_NAME} is ready after restart. Stopping script.${NC}"
        exit 1
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
