#!/bin/bash
set -e

BASE_CONTAINER_NAME="nexus-node"
IMAGE_NAME="nexus-node:latest"
LOG_DIR="/root/nexus_logs"
VERSION="v0.1.0"

# Check and install Node.js and pm2
check_node_pm2() {
    if ! command -v node >/dev/null 2>&1; then
        echo "Node.js not installed, installing..."
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt-get install -y nodejs
    fi

    if ! command -v pm2 >/dev/null 2>&1; then
        echo "pm2 not installed, installing..."
        npm install -g pm2
    fi
}

# Check Docker installation
check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "Docker not installed, installing..."
        apt update
        apt install -y apt-transport-https ca-certificates curl software-properties-common
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
        add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
        apt update
        apt install -y docker-ce
        systemctl enable docker
        systemctl start docker
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
    curl \
    screen \
    bash \
    && rm -rf /var/lib/apt/lists/*

RUN curl -sSL https://cli.nexus.xyz/ | NONINTERACTIVE=1 sh \
    && ln -sf /root/.nexus/bin/nexus-network /usr/local/bin/nexus-network

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
EOF

    cat > entrypoint.sh <<EOF
#!/bin/bash
set -e

PROVER_ID_FILE="/root/.nexus/node-id"

if [ -z "\$NODE_ID" ]; then
    echo "Error: NODE_ID environment variable not set"
    exit 1
fi

echo "\$NODE_ID" > "\$PROVER_ID_FILE"
echo "Using node-id: \$NODE_ID"

if ! command -v nexus-network >/dev/null 2>&1; then
    echo "Error: nexus-network not installed or unavailable"
    exit 1
fi

screen -S nexus -X quit >/dev/null 2>&1 || true

echo "Starting nexus-network node..."
screen -dmS nexus bash -c "nexus-network start --node-id \$NODE_ID &>> /root/nexus.log"

sleep 3

if screen -list | grep -q "nexus"; then
    echo "Node started in background."
    echo "Log file: /root/nexus.log"
    echo "View logs with: docker logs \$CONTAINER_NAME"
else
    echo "Node failed to start, check logs."
    cat /root/nexus.log
    exit 1
fi

tail -f /root/nexus.log
EOF

    docker build -t "$IMAGE_NAME" .

    cd -
    rm -rf "$WORKDIR"
}

# Run container with mounted host log file
run_container() {
    local node_id=$1
    local container_name="${BASE_CONTAINER_NAME}-${node_id}"
    local log_file="${LOG_DIR}/nexus-${node_id}.log"

    if docker ps -a --format '{{.Names}}' | grep -qw "$container_name"; then
        echo "Old container $container_name found, removing..."
        docker rm -f "$container_name"
    fi

    mkdir -p "$LOG_DIR"
    
    if [ ! -f "$log_file" ]; then
        touch "$log_file"
        chmod 644 "$log_file"
    fi

    docker run -d --name "$container_name" -v "$log_file":/root/nexus.log -e NODE_ID="$node_id" "$IMAGE_NAME"
    echo "Container $container_name started!"
}

# Stop and remove container, delete logs
uninstall_node() {
    local node_id=$1
    local container_name="${BASE_CONTAINER_NAME}-${node_id}"
    local log_file="${LOG_DIR}/nexus-${node_id}.log"

    echo "Stopping and removing container $container_name..."
    docker rm -f "$container_name" 2>/dev/null || echo "Container not found or already stopped"

    if [ -f "$log_file" ]; then
        echo "Deleting log file $log_file..."
        rm -f "$log_file"
    else
        echo "Log file not found: $log_file"
    fi

    echo "Node $node_id uninstalled."
}

# List all running nodes
list_nodes() {
    echo "Current node status:"
    echo "------------------------------------------------------------------------------------------------------------------------"
    printf "%-6s %-20s %-10s %-10s %-10s %-20s %-20s\n" "No." "Node ID" "CPU Usage" "Memory Usage" "Memory Limit" "Status" "Start Time"
    echo "------------------------------------------------------------------------------------------------------------------------"
    
    local all_nodes=($(get_all_nodes))
    for i in "${!all_nodes[@]}"; do
        local node_id=${all_nodes[$i]}
        local container_name="${BASE_CONTAINER_NAME}-${node_id}"
        local container_info=$(docker stats --no-stream --format "{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}}" $container_name 2>/dev/null)
        
        if [ -n "$container_info" ]; then
            IFS=',' read -r cpu_usage mem_usage mem_limit mem_perc <<< "$container_info"
            local status=$(docker ps -a --filter "name=$container_name" --format "{{.Status}}")
            local created_time=$(docker ps -a --filter "name=$container_name" --format "{{.CreatedAt}}")
            
            mem_usage=$(echo $mem_usage | sed 's/\([0-9.]*\)\([A-Za-z]*\)/\1 \2/')
            mem_limit=$(echo $mem_limit | sed 's/\([0-9.]*\)\([A-Za-z]*\)/\1 \2/')
            
            printf "%-6d %-20s %-10s %-10s %-10s %-20s %-20s\n" \
                $((i+1)) \
                "$node_id" \
                "$cpu_usage" \
                "$mem_usage" \
                "$mem_limit" \
                "$(echo $status | cut -d' ' -f1)" \
                "$created_time"
        else
            local status=$(docker ps -a --filter "name=$container_name" --format "{{.Status}}")
            local created_time=$(docker ps -a --filter "name=$container_name" --format "{{.CreatedAt}}")
            if [ -n "$status" ]; then
                printf "%-6d %-20s %-10s %-10s %-10s %-20s %-20s\n" \
                    $((i+1)) \
                    "$node_id" \
                    "N/A" \
                    "N/A" \
                    "N/A" \
                    "$(echo $status | cut -d' ' -f1)" \
                    "$created_time"
            fi
        fi
    done
    echo "------------------------------------------------------------------------------------------------------------------------"
    echo "Notes:"
    echo "- CPU Usage: Container CPU usage percentage"
    echo "- Memory Usage: Current memory usage of container"
    echo "- Memory Limit: Container memory limit"
    echo "- Status: Container running status"
    echo "- Start Time: Container creation time"
    read -p "Press any key to return to menu"
}

# Get running node IDs
get_running_nodes() {
    docker ps --filter "name=${BASE_CONTAINER_NAME}" --filter "status=running" --format "{{.Names}}" | sed "s/${BASE_CONTAINER_NAME}-//"
}

# Get all node IDs (including stopped)
get_all_nodes() {
    docker ps -a --filter "name=${BASE_CONTAINER_NAME}" --format "{{.Names}}" | sed "s/${BASE_CONTAINER_NAME}-//"
}

# View node logs
view_node_logs() {
    local node_id=$1
    local container_name="${BASE_CONTAINER_NAME}-${node_id}"
    
    if docker ps -a --format '{{.Names}}' | grep -qw "$container_name"; then
        echo "Select log view mode:"
        echo "1. Raw logs (may include color codes)"
        echo "2. Cleaned logs (color codes removed)"
        read -rp "Choose (1-2): " log_mode

        echo "Viewing logs, press Ctrl+C to exit"
        if [ "$log_mode" = "2" ]; then
            docker logs -f "$container_name" | sed 's/\x1b\[[0-9;]*m//g' | sed 's/\x1b\[?25l//g' | sed 's/\x1b\[?25h//g'
        else
            docker logs -f "$container_name"
        fi
    else
        echo "Container not running, install and start node first (option 1)"
        read -p "Press any key to return to menu"
    fi
}

# Batch start multiple nodes
batch_start_nodes() {
    echo "Enter node IDs, one per line, empty line to finish:"
    echo "(Press Enter after each, then Ctrl+D to end)"
    
    local node_ids=()
    while read -r line; do
        if [ -n "$line" ]; then
            node_ids+=("$line")
        fi
    done

    if [ ${#node_ids[@]} -eq 0 ]; then
        echo "No node IDs entered, returning to menu"
        read -p "Press any key to continue"
        return
    fi

    echo "Building image..."
    build_image

    echo "Starting nodes..."
    for node_id in "${node_ids[@]}"; do
        echo "Starting node $node_id..."
        run_container "$node_id"
        sleep 2
    done

    echo "All nodes started!"
    read -p "Press any key to return to menu"
}

# Select node to view logs
select_node_to_view() {
    local all_nodes=($(get_all_nodes))
    
    if [ ${#all_nodes[@]} -eq 0 ]; then
        echo "No nodes found"
        read -p "Press any key to return to menu"
        return
    fi

    echo "Select node to view:"
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
        local selected_node=${all_nodes[$((choice-1))]}
        view_node_logs "$selected_node"
    else
        echo "Invalid option"
        read -p "Press any key to continue"
    fi
}

# Batch stop and uninstall nodes
batch_uninstall_nodes() {
    local all_nodes=($(get_all_nodes))
    
    if [ ${#all_nodes[@]} -eq 0 ]; then
        echo "No nodes found"
        read -p "Press any key to return to menu"
        return
    fi

    echo "Current node status:"
    echo "----------------------------------------"
    echo "No.   Node ID               Status"
    echo "----------------------------------------"
    for i in "${!all_nodes[@]}"; do
        local node_id=${all_nodes[$i]}
        local container_name="${BASE_CONTAINER_NAME}-${node_id}"
        local status=$(docker ps -a --filter "name=$container_name" --format "{{.Status}}")
        if [[ $status == Up* ]]; then
            printf "%-6d %-20s [Running]\n" $((i+1)) "$node_id"
        else
            printf "%-6d %-20s [Stopped]\n" $((i+1)) "$node_id"
        fi
    done
    echo "----------------------------------------"

    echo "Select nodes to delete (multiple, space-separated):"
    echo "0. Return to main menu"
    
    read -rp "Enter options (0 or numbers, space-separated): " choices

    if [ "$choices" = "0" ]; then
        return
    fi

    read -ra selected_choices <<< "$choices"
    
    for choice in "${selected_choices[@]}"; do
        if [ "$choice" -ge 1 ] && [ "$choice" -le ${#all_nodes[@]} ]; then
            local selected_node=${all_nodes[$((choice-1))]}
            echo "Uninstalling node $selected_node..."
            uninstall_node "$selected_node"
        else
            echo "Skipping invalid option: $choice"
        fi
    done

    echo "Batch uninstall completed!"
    read -p "Press any key to return to menu"
}

# Uninstall all nodes
uninstall_all_nodes() {
    local all_nodes=($(get_all_nodes))
    
    if [ ${#all_nodes[@]} -eq 0 ]; then
        echo "No nodes found"
        read -p "Press any key to return to menu"
        return
    fi

    echo "Warning: This will delete all nodes!"
    echo "Total nodes: ${#all_nodes[@]}"
    for node_id in "${all_nodes[@]}"; do
        echo "- $node_id"
    done
    
    read -rp "Confirm deletion of all nodes? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Operation canceled"
        read -p "Press any key to return to menu"
        return
    fi

    echo "Deleting all nodes..."
    for node_id in "${all_nodes[@]}"; do
        echo "Uninstalling node $node_id..."
        uninstall_node "$node_id"
    done

    echo "All nodes deleted!"
    read -p "Press any key to return to menu"
}

# Set default auto cleanup task
setup_default_auto_cleanup() {
    local days=2
    
    echo "Setting up auto log cleanup (keeping last $days days)..."

    local script_dir="/root/nexus_scripts"
    mkdir -p "$script_dir"
    
    cat > "$script_dir/cleanup_logs.sh" <<EOF
#!/bin/bash
set -e

LOG_DIR="$LOG_DIR"
DAYS_TO_KEEP=$days

if [ -d "\$LOG_DIR" ]; then
    find "\$LOG_DIR" -name "*.log" -type f -mtime +\$DAYS_TO_KEEP -delete
fi
EOF

    chmod +x "$script_dir/cleanup_logs.sh"
    
    pm2 delete nexus-cleanup 2>/dev/null || true
    
    cat > "$script_dir/cleanup_scheduler.sh" <<EOF
#!/bin/bash
set -e
while true; do
    bash "$script_dir/cleanup_logs.sh"
    sleep 86400
done
EOF

    chmod +x "$script_dir/cleanup_scheduler.sh"
    
    pm2 start "$script_dir/cleanup_scheduler.sh" --name "nexus-cleanup" --no-autorestart
    pm2 save
    
    echo "Auto log cleanup task set! Will clean logs older than $days days daily."
}

# Batch rotate nodes
batch_rotate_nodes() {
    echo "Enter node IDs, one per line, empty line to finish:"
    echo "(Press Enter after each, then Ctrl+D to end)"
    
    local node_ids=()
    while read -r line; do
        if [ -n "$line" ]; then
            node_ids+=("$line")
        fi
    done

    if [ ${#node_ids[@]} -eq 0 ]; then
        echo "No node IDs entered, returning to menu"
        read -p "Press any key to continue"
        return
    fi

    read -rp "Enter nodes to start every 2 hours (default: half of ${#node_ids[@]}, rounded up): " nodes_per_round
    if [ -z "$nodes_per_round" ]; then
        nodes_per_round=$(( (${#node_ids[@]} + 1) / 2 ))
    fi

    if ! [[ "$nodes_per_round" =~ ^[0-9]+$ ]] || [ "$nodes_per_round" -lt 1 ] || [ "$nodes_per_round" -gt ${#node_ids[@]} ]; then
        echo "Invalid node count, enter a number between 1 and ${#node_ids[@]}"
        read -p "Press any key to return to menu"
        return
    fi

    local total_nodes=${#node_ids[@]}
    local num_groups=$(( (total_nodes + nodes_per_round - 1) / nodes_per_round ))
    echo "Nodes will be divided into $num_groups groups for rotation"

    check_node_pm2

    echo "Stopping old rotation process..."
    pm2 delete nexus-rotate 2>/dev/null || true

    echo "Building image..."
    build_image

    local script_dir="/root/nexus_scripts"
    mkdir -p "$script_dir"

    for ((group=1; group<=num_groups; group++)); do
        cat > "$script_dir/start_group${group}.sh" <<EOF
#!/bin/bash
set -e

docker ps -a --filter "name=${BASE_CONTAINER_NAME}" --format "{{.Names}}" | xargs -r docker rm -f
EOF
    done

    for i in "${!node_ids[@]}"; do
        local node_id=${node_ids[$i]}
        local container_name="${BASE_CONTAINER_NAME}-${node_id}"
        local log_file="${LOG_DIR}/nexus-${node_id}.log"
        
        local group_num=$(( i / nodes_per_round + 1 ))
        if [ $group_num -gt $num_groups ]; then
            group_num=$num_groups
        fi
        
        mkdir -p "$LOG_DIR"
        if [ -d "$log_file" ]; then
            rm -rf "$log_file"
        fi
        if [ ! -f "$log_file" ]; then
            touch "$log_file"
            chmod 644 "$log_file"
        fi

        echo "echo \"[$(date '+%Y-%m-%d %H:%M:%S')] Starting node $node_id ...\"" >> "$script_dir/start_group${group_num}.sh"
        echo "docker run -d --name $container_name -v $log_file:/root/nexus.log -e NODE_ID=$node_id $IMAGE_NAME" >> "$script_dir/start_group${group_num}.sh"
        echo "sleep 30" >> "$script_dir/start_group${group_num}.sh"
    done

    cat > "$script_dir/rotate.sh" <<EOF
#!/bin/bash
set -e

while true; do
EOF

    for ((group=1; group<=num_groups; group++)); do
        local start_idx=$(( (group-1) * nodes_per_round ))
        local end_idx=$(( group * nodes_per_round ))
        if [ $end_idx -gt $total_nodes ]; then
            end_idx=$total_nodes
        fi
        local current_group_nodes=$(( end_idx - start_idx ))

        cat >> "$script_dir/rotate.sh" <<EOF
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting group ${group} nodes (${current_group_nodes})..."
    bash "$script_dir/start_group${group}.sh"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting 2 hours..."
    sleep 7200

EOF
    done

    echo "done" >> "$script_dir/rotate.sh"

    chmod +x "$script_dir"/*.sh

    pm2 start "$script_dir/rotate.sh" --name "nexus-rotate"
    pm2 save

    echo "Node rotation started!"
    echo "Total $total_nodes nodes, divided into $num_groups groups"
    echo "Each group starts $nodes_per_round nodes (last may be fewer), rotating every 2 hours"
    echo "Check status: 'pm2 status'"
    echo "View logs: 'pm2 logs nexus-rotate'"
    echo "Stop rotation: 'pm2 stop nexus-rotate'"

    setup_default_auto_cleanup
    
    read -p "Press any key to return to menu"
}

# Main menu
set +e
while true; do
    clear
    echo "========== Nexus Multi-Node Management ($VERSION) =========="
    echo "1. Batch node rotation start"
    echo "2. Show all node status"
    echo "3. Batch stop and uninstall nodes"
    echo "4. View specific node logs"
    echo "5. Delete all nodes"
    echo "6. Exit"
    echo "==================================="

    read -rp "Enter option (1-6): " choice

    case $choice in
        1)
            check_docker
            batch_rotate_nodes
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
            echo "Invalid option, try again."
            read -p "Press any key to continue"
            ;;
    esac
done
