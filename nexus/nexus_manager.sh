#!/bin/bash
set -e

# Variables
BASE_CONTAINER_NAME="nexus-node"
IMAGE_NAME="nexus-node:latest"
LOG_DIR="/root/nexus_logs"
INSTALL_DIR="/root/.nexus"
NEXUS_BIN="/root/.nexus/bin/nexus-network"
SERVICE_NAME="nexus-network"

# Function to validate Wallet Address (Ethereum address format)
validate_wallet_address() {
    [[ "$1" =~ ^0x[a-fA-F0-9]{40}$ ]] || { echo "Invalid Wallet Address: Must be a valid Ethereum address (e.g., 0x238a3a4ff431De579885D4cE0297af7A0d3a1b32)"; return 1; }
    return 0
}

# Function to validate Node ID (if provided, must be numeric)
validate_node_id() {
    [[ -z "$1" || "$1" =~ ^[0-9]+$ ]] || { echo "Invalid Node ID: Must be numeric (e.g., 7300170)"; return 1; }
    return 0
}

# Check and install Docker using get.docker.com
check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "Docker not found, installing using get.docker.com..."
        wget -O /docker.sh https://get.docker.com || { echo "Failed to download Docker installation script"; exit 1; }
        chmod +x /docker.sh
        /docker.sh || { echo "Docker installation failed"; exit 1; }
        rm -f /docker.sh
        sudo systemctl enable docker
        sudo systemctl start docker
    fi
}

# Check and install cron
check_cron() {
    if ! command -v cron >/dev/null 2>&1; then
        echo "Cron not found, installing..."
        sudo apt update
        sudo apt install -y cron
        sudo systemctl enable cron
        sudo systemctl start cron
    fi
}

# Build Docker image
build_image() {
    WORKDIR=$(mktemp -d)
    cd "$WORKDIR"

    cat > Dockerfile <<EOF
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PROVER_ID_FILE=/root/.nexus/node-id

RUN apt-get update && apt-get install -y \
    curl build-essential pkg-config libssl-dev git protobuf-compiler \
    && rm -rf /var/lib/apt/lists/* \
    && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
    && . /root/.cargo/env \
    && echo Y | curl -sSL https://cli.nexus.xyz/ | sh \
    && ln -sf /root/.nexus/bin/nexus-network /usr/local/bin/nexus-network

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
EOF

    cat > entrypoint.sh <<EOF
#!/bin/bash
set -e

PROVER_ID_FILE="/root/.nexus/node-id"

if [ -z "\$WALLET_ADDRESS" ]; then
    echo "Error: WALLET_ADDRESS environment variable must be set"
    exit 1
fi

# Check network connectivity
ping -c 1 beta.orchestrator.nexus.xyz >/dev/null 2>&1 || {
    echo "Error: Cannot connect to Nexus server (beta.orchestrator.nexus.xyz). Check network, DNS, or firewall."
    exit 1
}

# Register user
echo "Registering user with wallet address: \$WALLET_ADDRESS"
/root/.nexus/bin/nexus-network register-user --wallet-address "\$WALLET_ADDRESS" || {
    echo "Error: Failed to register user"
    exit 1
}

# Register node
echo "Registering new node..."
/root/.nexus/bin/nexus-network register-node || {
    echo "Error: Failed to register node"
    exit 1
}

# Read Node ID from file
NODE_ID=\$(cat "\$PROVER_ID_FILE" 2>/dev/null || echo "")
if [ -z "\$NODE_ID" ]; then
    echo "Error: Failed to retrieve Node ID after registration"
    exit 1
fi
echo "Using node-id: \$NODE_ID"

echo "Starting nexus-network node..."
/root/.nexus/bin/nexus-network start --node-id "\$NODE_ID" &>> /root/nexus.log &

echo "Node started in background."
echo "Log file: /root/nexus.log"
echo "Use 'docker logs \$CONTAINER_NAME' to view logs"

tail -f /root/nexus.log
EOF

    docker build -t "$IMAGE_NAME" .
    cd -
    rm -rf "$WORKDIR"
}

# Run container with log mounting and cron for log cleanup
run_container() {
    local node_id=$1
    local wallet_address=$2
    local container_name="${BASE_CONTAINER_NAME}-${node_id:-new}"
    local log_file="${LOG_DIR}/nexus-${node_id:-new}.log"

    if docker ps -a --format '{{.Names}}' | grep -qw "$container_name"; then
        echo "Removing old container $container_name..."
        docker rm -f "$container_name"
    fi

    mkdir -p "$LOG_DIR"
    if [ ! -f "$log_file" ]; then
        touch "$log_file"
        chmod 644 "$log_file"
    fi

    docker run -d --name "$container_name" \
        -v "$log_file":/root/nexus.log \
        -e WALLET_ADDRESS="$wallet_address" \
        -e NODE_ID="$node_id" \
        "$IMAGE_NAME"
    echo "Container $container_name started!"

    check_cron
    local cron_job="0 0 * * * rm -f $log_file"
    local cron_file="/etc/cron.d/nexus-log-cleanup-${node_id:-new}"
    [ -f "$cron_file" ] && rm -f "$cron_file"
    echo "$cron_job" > "$cron_file"
    chmod 0644 "$cron_file"
    echo "Set daily log cleanup cron job for node ${node_id:-new}"
}

# Uninstall node
uninstall_node() {
    local node_id=$1
    local container_name="${BASE_CONTAINER_NAME}-${node_id}"
    local log_file="${LOG_DIR}/nexus-${node_id}.log"
    local cron_file="/etc/cron.d/nexus-log-cleanup-${node_id}"

    echo "Stopping and removing container $container_name..."
    docker rm -f "$container_name" 2>/dev/null || echo "Container not found or already stopped"

    [ -f "$log_file" ] && { echo "Removing log file $log_file..."; rm -f "$log_file"; } || echo "Log file not found: $log_file"
    [ -f "$cron_file" ] && { echo "Removing cron job $cron_file..."; rm -f "$cron_file"; } || echo "Cron job not found: $cron_file"

    echo "Node $node_id uninstalled."
}

# List all nodes
list_nodes() {
    echo "Current node status:"
    echo "----------------------------------------------------------------------------------------------------------------------"
    printf "%-6s %-20s %-10s %-15s %-15s %-15s %-20s\n" "No." "Node ID" "CPU Usage" "Memory Usage" "Memory Limit" "Status" "Created At"
    echo "----------------------------------------------------------------------------------------------------------------------"

    local all_nodes=($(get_all_nodes))
    for i in "${!all_nodes[@]}"; do
        local node_id=${all_nodes[$i]}
        local container_name="${BASE_CONTAINER_NAME}-${node_id}"
        local container_info=$(docker stats --no-stream --format "{{.CPUPerc}},{{.MemUsage}}" "$container_name" 2>/dev/null)

        if [ -n "$container_info" ]; then
            IFS=',' read -r cpu_usage mem_usage <<< "$container_info"
            local status=$(docker ps -a --filter "name=$container_name" --format "{{.Status}}")
            local created_time=$(docker ps -a --filter "name=$container_name" --format "{{.CreatedAt}}")
            printf "%-6d %-20s %-10s %-15s %-15s %-15s %-20s\n" \
                $((i+1)) "$node_id" "$cpu_usage" "$mem_usage" "N/A" "$(echo "$status" | cut -d' ' -f1)" "$created_time"
        else
            local status=$(docker ps -a --filter "name=$container_name" --format "{{.Status}}")
            local created_time=$(docker ps -a --filter "name=$container_name" --format "{{.CreatedAt}}")
            [ -n "$status" ] && printf "%-6d %-20s %-10s %-15s %-15s %-15s %-20s\n" \
                $((i+1)) "$node_id" "N/A" "N/A" "N/A" "$(echo "$status" | cut -d' ' -f1)" "$created_time"
        fi
    done
    echo "----------------------------------------------------------------------------------------------------------------------"
    echo "Notes:"
    echo "- CPU Usage: Container CPU usage percentage"
    echo "- Memory Usage: Current memory used by container"
    echo "- Status: Container running status"
    echo "- Created At: Container creation time"
    read -p "Press any key to return to menu"
}

# Get all node IDs
get_all_nodes() {
    docker ps -a --filter "name=${BASE_CONTAINER_NAME}" --format "{{.Names}}" | sed "s/${BASE_CONTAINER_NAME}-//"
}

# View node logs
view_node_logs() {
    local node_id=$1
    local container_name="${BASE_CONTAINER_NAME}-${node_id}"

    if docker ps -a --format '{{.Names}}' | grep -qw "$container_name"; then
        echo "Select log viewing mode:"
        echo "1. Raw logs (may include color codes)"
        echo "2. Cleaned logs (color codes removed)"
        read -rp "Select (1-2): " log_mode

        echo "Viewing logs, press Ctrl+C to exit"
        if [ "$log_mode" = "2" ]; then
            docker logs -f "$container_name" | sed 's/\x1b\[[0-9;]*m//g' | sed 's/\x1b\[?25l//g' | sed 's/\x1b\[?25h//g'
        else
            docker logs -f "$container_name"
        fi
    else
        echo "Container not running. Please install and start the node first (option 1)."
        read -p "Press any key to return to menu"
    fi
}

# Batch install nodes
batch_install_nodes() {
    echo "Enter Wallet Addresses (one per line, press Ctrl+D to finish):"

    local wallets=()
    while read -r wallet_address; do
        if [ -n "$wallet_address" ]; then
            validate_wallet_address "$wallet_address" || { echo "Skipping invalid Wallet Address: $wallet_address"; continue; }
            wallets+=("$wallet_address")
        fi
    done

    if [ ${#wallets[@]} -eq 0 ]; then
        echo "No valid Wallet Addresses entered, returning to main menu."
        read -p "Press any key to continue"
        return
    fi

    echo "Building image..."
    build_image

    echo "Starting nodes..."
    for wallet_address in "${wallets[@]}"; do
        echo "Starting node for Wallet Address $wallet_address..."
        run_container "" "$wallet_address"
        sleep 2
    done

    echo "All nodes started!"
    read -p "Press any key to return to menu"
}

# Select node to view logs
select_node_to_view() {
    local all_nodes=($(get_all_nodes))

    if [ ${#all_nodes[@]} -eq 0 ]; then
        echo "No nodes found."
        read -p "Press any key to return to menu"
        return
    fi

    echo "Select a node to view:"
    echo "0. Return to main menu"
    for i in "${!all_nodes[@]}"; do
        local node_id=${all_nodes[$i]}
        local container_name="${BASE_CONTAINER_NAME}-${node_id}"
        local status=$(docker ps -a --filter "name=$container_name" --format "{{.Status}}")
        if [[ $status == Up* ]]; then
            echo "$((i+1)). Node $node_id [Running]"
        else
            echo "$((i+1)). Node $node_id [Stopped]"
        fi
    done

    read -rp "Enter option (0-${#all_nodes[@]}): " choice
    if [ "$choice" = "0" ]; then
        return
    fi

    if [ "$choice" -ge 1 ] && [ "$choice" -le ${#all_nodes[@]} ]; then
        view_node_logs "${all_nodes[$((choice-1))]}"
    else
        echo "Invalid option."
        read -p "Press any key to continue"
    fi
}

# Batch uninstall nodes
batch_uninstall_nodes() {
    local all_nodes=($(get_all_nodes))

    if [ ${#all_nodes[@]} -eq 0 ]; then
        echo "No nodes found."
        read -p "Press any key to return to menu"
        return
    fi

    echo "Current node status:"
    echo "----------------------------------------"
    echo "No.  Node ID              Status"
    echo "----------------------------------------"
    for i in "${!all_nodes[@]}"; do
        local node_id=${all_nodes[$i]}
        local container_name="${BASE_CONTAINER_NAME}-${node_id}"
        local status=$(docker ps -a --filter "name=$container_name" --format "{{.Status}}")
        if [[ $status == Up* ]]; then
            printf "%-4d %-20s [Running]\n" $((i+1)) "$node_id"
        else
            printf "%-4d %-20s [Stopped]\n" $((i+1)) "$node_id"
        fi
    done
    echo "----------------------------------------"

    echo "Select nodes to uninstall (space-separated numbers, 0 to return):"
    read -rp "Enter options: " choices
    if [ "$choices" = "0" ]; then
        return
    fi

    read -ra selected_choices <<< "$choices"
    for choice in "${selected_choices[@]}"; do
        if [ "$choice" -ge 1 ] && [ "$choice" -le ${#all_nodes[@]} ]; then
            echo "Uninstalling node ${all_nodes[$((choice-1))]}..."
            uninstall_node "${all_nodes[$((choice-1))]}"
        else
            echo "Skipping invalid option: $choice"
        fi
    done

    echo "Batch uninstall complete!"
    read -p "Press any key to return to menu"
}

# Uninstall all nodes
uninstall_all_nodes() {
    local all_nodes=($(get_all_nodes))

    if [ ${#all_nodes[@]} -eq 0 ]; then
        echo "No nodes found."
        read -p "Press any key to return to menu"
        return
    fi

    echo "WARNING: This will uninstall ALL nodes!"
    echo "Total nodes: ${#all_nodes[@]}"
    for node_id in "${all_nodes[@]}"; do
        echo "- $node_id"
    done

    read -rp "Confirm deletion of all nodes? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Operation canceled."
        read -p "Press any key to return to menu"
        return
    fi

    echo "Uninstalling all nodes..."
    for node_id in "${all_nodes[@]}"; do
        echo "Uninstalling node $node_id..."
        uninstall_node "$node_id"
    done

    echo "All nodes uninstalled."
    read -p "Press any key to return to menu"
}

# Handle command-line arguments for auto-install
if [ $# -eq 1 ]; then
    WALLET_ADDRESS="$1"
    if validate_wallet_address "$WALLET_ADDRESS"; then
        check_docker
        echo "Building image..."
        build_image
        echo "Installing and starting node with Wallet Address: $WALLET_ADDRESS..."
        run_container "" "$WALLET_ADDRESS"
        exit 0
    else
        echo "Invalid Wallet Address. Usage: $0 <WALLET_ADDRESS>"
        exit 1
    fi
elif [ $# -eq 2 ]; then
    NODE_ID="$1"
    WALLET_ADDRESS="$2"
    if validate_node_id "$NODE_ID" && validate_wallet_address "$WALLET_ADDRESS"; then
        check_docker
        echo "Building image..."
        build_image
        echo "Installing and starting node with Node ID: $NODE_ID and Wallet Address: $WALLET_ADDRESS..."
        run_container "$NODE_ID" "$WALLET_ADDRESS"
        exit 0
    else
        echo "Invalid Node ID or Wallet Address. Usage: $0 [<NODE_ID>] <WALLET_ADDRESS>"
        exit 1
    fi
fi

# Main menu
while true; do
    clear
    echo "Nexus Node Manager"
    echo "==================================="
    echo "1. Install and start new node"
    echo "2. List all node statuses"
    echo "3. Batch uninstall nodes"
    echo "4. View node logs"
    echo "5. Uninstall all nodes"
    echo "6. Exit"
    echo "==================================="

    read -rp "Enter option (1-6): " choice
    case $choice in
        1)
            check_docker
            read -rp "Enter Wallet Address (e.g., 0x238a3a4ff431De579885D4cE0297af7A0d3a1b32): " wallet_address
            validate_wallet_address "$wallet_address" || { read -p "Press any key to continue"; continue; }
            read -rp "Enter Node ID (optional, e.g., 7300170, leave blank to auto-generate): " node_id
            validate_node_id "$node_id" || { read -p "Press any key to continue"; continue; }
            echo "Building image..."
            build_image
            echo "Starting node..."
            run_container "$node_id" "$wallet_address"
            read -p "Press any key to return to menu"
            ;;
        2)
            list_nodes
            ;;
        3)
            batch_uninstall_nodes
            ;;
        4)
            select_node_to_view
            ;;
        5)
            uninstall_all_nodes
            ;;
        6)
            echo "Exiting script."
            exit 0
            ;;
        *)
            echo "Invalid option, please try again."
            read -p "Press any key to continue"
            ;;
    esac
done
