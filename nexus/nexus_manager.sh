#!/bin/bash
set -e

# Nexus Node Manager v2.11
# Installs and removes Nexus nodes in Docker containers
# Uses fixed binary URL and SHA256 verification to ensure correct binary installation

# Variables
VERSION="2.11"
BASE_CONTAINER_NAME="nexus-node"
IMAGE_NAME="nexus-node:latest"
LOG_DIR="/root/nexus_logs"
NEXUS_HOME="/root/.nexus"
NEXUS_BIN="$NEXUS_HOME/bin/nexus-network"
BINARY_URL="https://github.com/nexus-xyz/nexus-cli/releases/download/v0.8.11/nexus-network-linux-x86_64"
SHA256_URL="https://github.com/nexus-xyz/nexus-cli/releases/download/v0.8.11/nexus-network-linux-x86_64.sha256"
RETRY_COUNT=5
RETRY_DELAY=5

# Function to validate Wallet Address
validate_wallet_address() {
    [[ "$1" =~ ^0x[a-fA-F0-9]{40}$ ]] || { echo "Invalid Wallet Address"; exit 1; }
}

# Function to validate Node ID
validate_node_id() {
    [[ -z "$1" || "$1" =~ ^[0-9]+$ ]] || { echo "Invalid Node ID: Must be numeric"; exit 1; }
}

# Check and install Docker
check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "Installing Docker..."
        wget -O /docker.sh https://get.docker.com || { echo "Failed to download Docker script"; exit 1; }
        chmod +x /docker.sh
        /docker.sh || { echo "Docker installation failed"; exit 1; }
        rm -f /docker.sh
        systemctl enable docker
        systemctl start docker
    fi
}

# Check and install cron
check_cron() {
    if ! command -v cron >/dev/null 2>&1; then
        echo "Installing cron..."
        apt update
        apt install -y cron
        systemctl enable cron
        systemctl start cron
    fi
}

# Build Docker image
build_image() {
    docker rmi -f "$IMAGE_NAME" 2>/dev/null || true
    WORKDIR=$(mktemp -d)
    cd "$WORKDIR"

    cat > Dockerfile <<EOF
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PROVER_ID_FILE=/root/.nexus/node-id
ENV NEXUS_HOME=/root/.nexus
ENV BIN_DIR=/root/.nexus/bin

RUN apt-get update && apt-get install -y \
    curl build-essential pkg-config libssl-dev git protobuf-compiler ca-certificates file \
    && rm -rf /var/lib/apt/lists/* \
    && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
    && . /root/.cargo/env \
    && mkdir -p \$NEXUS_HOME \$BIN_DIR \
    && chmod 755 \$NEXUS_HOME \$BIN_DIR

COPY install_nexus.sh /install_nexus.sh
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /install_nexus.sh /entrypoint.sh
RUN /install_nexus.sh

ENTRYPOINT ["/entrypoint.sh"]
EOF

    cat > install_nexus.sh <<EOF
#!/bin/bash
set -e
set -x

NEXUS_HOME="/root/.nexus"
BIN_DIR="/root/.nexus/bin"
TEMP_BINARY="/tmp/nexus-network"
TEMP_SHA256="/tmp/nexus-network.sha256"
BINARY_URL="$BINARY_URL"
SHA256_URL="$SHA256_URL"
RETRY_COUNT=$RETRY_COUNT
RETRY_DELAY=$RETRY_DELAY

echo "Checking disk space..." >&2
df -h /tmp >&2
df -h /root >&2

echo "Verifying directory \$BIN_DIR..." >&2
ls -ld "\$BIN_DIR" >&2
if [ ! -w "\$BIN_DIR" ]; then
    echo "Error: Directory \$BIN_DIR is not writable" >&2
    exit 1
fi

fetch_binary() {
    local url=\$1
    local attempt=1
    while [ \$attempt -le \$RETRY_COUNT ]; do
        echo "Attempt \$attempt: Downloading from \$url..." >&2
        if curl -L --connect-timeout 20 --max-time 120 -o "\$TEMP_BINARY" "\$url" 2>/tmp/download_error.log; then
            return 0
        else
            echo "Download failed, retrying in \$RETRY_DELAY seconds..." >&2
            cat /tmp/download_error.log >&2
            sleep \$RETRY_DELAY
            attempt=\$((attempt + 1))
        fi
    done
    echo "Error: Failed to download binary from \$url after \$RETRY_COUNT attempts" >&2
    exit 1
}

fetch_sha256() {
    local url=\$1
    local attempt=1
    while [ \$attempt -le \$RETRY_COUNT ]; do
        echo "Attempt \$attempt: Downloading SHA256 from \$url..." >&2
        if curl -L --connect-timeout 20 --max-time 120 -o "\$TEMP_SHA256" "\$url" 2>/tmp/sha256_error.log; then
            return 0
        else
            echo "Download failed, retrying in \$RETRY_DELAY seconds..." >&2
            cat /tmp/sha256_error.log >&2
            sleep \$RETRY_DELAY
            attempt=\$((attempt + 1))
        fi
    done
    echo "Error: Failed to download SHA256 from \$url after \$RETRY_COUNT attempts" >&2
    exit 1
}

echo "Downloading Nexus CLI binary..." >&2
fetch_binary "\$BINARY_URL"

echo "Downloading SHA256 checksum..." >&2
fetch_sha256 "\$SHA256_URL"

if [ ! -s "\$TEMP_BINARY" ]; then
    echo "Error: Binary file \$TEMP_BINARY is empty or not found" >&2
    exit 1
fi

echo "Verifying binary format..." >&2
file "\$TEMP_BINARY" >&2

echo "Verifying SHA256 checksum..." >&2
EXPECTED_SHA256=\$(cat "\$TEMP_SHA256" | cut -d ' ' -f 1)
ACTUAL_SHA256=\$(sha256sum "\$TEMP_BINARY" | cut -d ' ' -f 1)
if [ "\$EXPECTED_SHA256" != "\$ACTUAL_SHA256" ]; then
    echo "Error: SHA256 checksum mismatch. Expected: \$EXPECTED_SHA256, Actual: \$ACTUAL_SHA256" >&2
    exit 1
fi

echo "Moving binary to \$BIN_DIR/nexus-network..." >&2
mv "\$TEMP_BINARY" "\$BIN_DIR/nexus-network" || { echo "Error: Failed to move binary to \$BIN_DIR/nexus-network" >&2; exit 1; }

chmod +x "\$BIN_DIR/nexus-network"
if [ ! -x "\$BIN_DIR/nexus-network" ]; then
    echo "Error: Binary file \$BIN_DIR/nexus-network is not executable" >&2
    exit 1
fi

echo "Verifying binary existence..." >&2
ls -l "\$BIN_DIR/nexus-network" >&2

echo "Nexus CLI installed successfully" >&2
EOF

    cat > entrypoint.sh <<EOF
#!/bin/bash
set -e
set -x

exec 2>>/root/nexus.log
echo "Container started at \$(date)" >&2

PROVER_ID_FILE="/root/.nexus/node-id"

if [ -z "\$WALLET_ADDRESS" ]; then
    echo "Error: WALLET_ADDRESS environment variable must be set" >&2
    exit 1
fi

echo "Checking network connectivity..." >&2
curl -s --head --connect-timeout 5 --max-time 10 https://www.google.com >/dev/null 2>&1 || {
    echo "Warning: Cannot connect to https://www.google.com. Proceeding, but Nexus CLI may fail." >&2
}

if [ ! -f "$NEXUS_BIN" ]; then
    echo "Error: Nexus CLI binary not found at $NEXUS_BIN" >&2
    ls -la /root/.nexus/bin >&2
    exit 1
fi

echo "Registering user with wallet address: \$WALLET_ADDRESS" >&2
$NEXUS_BIN register-user --wallet-address "\$WALLET_ADDRESS" 2>>/root/nexus.log || {
    echo "Error: Failed to register user" >&2
    tail -n 50 /root/nexus.log >&2
    exit 1
}

echo "Registering new node..." >&2
$NEXUS_BIN register-node 2>>/root/nexus.log || {
    echo "Error: Failed to register node" >&2
    tail -n 50 /root/nexus.log >&2
    exit 1
}

NODE_ID=\$(cat "\$PROVER_ID_FILE" 2>/dev/null || echo "")
if [ -z "\$NODE_ID" ]; then
    echo "Error: Failed to retrieve Node ID" >&2
    tail -n 50 /root/nexus.log >&2
    exit 1
fi
echo "Using node-id: \$NODE_ID" >&2

echo "Starting nexus-network node..." >&2
$NEXUS_BIN start --node-id "\$NODE_ID" &>> /root/nexus.log || {
    echo "Error: Failed to start nexus-network node" >&2
    tail -n 50 /root/nexus.log >&2
    exit 1
}

echo "Node started in background." >&2
echo "Log file: /root/nexus.log" >&2
tail -f /root/nexus.log
EOF

    docker build --no-cache -t "$IMAGE_NAME" .
    cd -
    rm -rf "$WORKDIR"
}

# Install node
install_node() {
    local node_id="$1"
    local wallet_address="$2"

    validate_wallet_address "$wallet_address"
    validate_node_id "$node_id"

    check_docker
    echo "Building image..."
    build_image
    echo "Installing and starting node with Wallet Address: $wallet_address${node_id:+ and Node ID: $node_id}..."
    run_container "$node_id" "$wallet_address"
}

# Remove node
remove_node() {
    local node_id="$1"
    validate_node_id "$node_id"
    uninstall_node "$node_id"
}

# Run container
run_container() {
    local node_id=$1
    local wallet_address=$2
    local container_name="${BASE_CONTAINER_NAME}${node_id:+-${node_id}}"
    local log_file="${LOG_DIR}/nexus${node_id:+-${node_id}}.log"

    if docker ps -a --format '{{.Names}}' | grep -qw "$container_name"; then
        echo "Removing old container $container_name..."
        docker rm -f "$container_name"
    fi

    mkdir -p "$LOG_DIR"
    touch "$log_file"
    chmod 644 "$log_file"

    docker run -d --name "$container_name" \
        -v "$log_file":/root/nexus.log \
        -e WALLET_ADDRESS="$wallet_address" \
        -e NODE_ID="$node_id" \
        -e CONTAINER_NAME="$container_name" \
        --network host \
        "$IMAGE_NAME"
    echo "Container $container_name started!"

    check_cron
    local cron_job="0 0 * * * rm -f $log_file"
    local cron_file="/etc/cron.d/nexus-log-cleanup${node_id:+-${node_id}}"
    [ -f "$cron_file" ] && rm -f "$cron_file"
    echo "$cron_job" > "$cron_file"
    chmod 0644 "$cron_file"
    echo "Set daily log cleanup cron job for node ${node_id:-default}"
}

# Uninstall node
uninstall_node() {
    local node_id=$1
    local container_name="${BASE_CONTAINER_NAME}${node_id:+-${node_id}}"
    local log_file="${LOG_DIR}/nexus${node_id:+-${node_id}}.log"
    local cron_file="/etc/cron.d/nexus-log-cleanup${node_id:+-${node_id}}"

    echo "Stopping and removing container $container_name..."
    docker rm -f "$container_name" 2>/dev/null || echo "Container not found"

    [ -f "$log_file" ] && { echo "Removing log file $log_file..."; rm -f "$log_file"; }
    [ -f "$cron_file" ] && { echo "Removing cron job $cron_file..."; rm -f "$cron_file"; }

    echo "Node ${node_id:-default} uninstalled."
}

# Parse arguments
REMOVE_NODE=false
while getopts "r" opt; do
    case $opt in
        r) REMOVE_NODE=true ;;
        *) echo "Usage: $0 [-r] [<NODE_ID>] [<WALLET_ADDRESS>]"; exit 1 ;;
    esac
done

shift $((OPTIND-1))

if [ "$REMOVE_NODE" = true ]; then
    if [ $# -eq 0 ]; then
        remove_node ""
    elif [ $# -eq 1 ]; then
        remove_node "$1"
    else
        echo "Usage: $0 -r [<NODE_ID>]"
        exit 1
    fi
    exit 0
fi

case $# in
    1)
        install_node "" "$1"
        ;;
    2)
        install_node "$1" "$2"
        ;;
    *)
        echo "Usage: $0 [-r] [<NODE_ID>] [<WALLET_ADDRESS>]"
        exit 1
        ;;
esac
