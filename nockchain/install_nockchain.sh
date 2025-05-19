#!/bin/bash

# Script to automate Nockchain installation with Systemd service
# Usage: ./install_nockchain.sh [--branch BRANCH] [--node-type TYPE] [--mining-pubkey PUBKEY]

# Default values
BRANCH="master"
NODE_TYPE="leader"
MINING_PUBKEY=""
INSTALL_DIR="$HOME/nockchain"
REPO_URL="https://github.com/zorp-corp/nockchain.git"

# Function to display usage
usage() {
    echo "Usage: $0 [--branch BRANCH] [--node-type TYPE] [--mining-pubkey PUBKEY]"
    echo "  --branch: Git branch to clone (default: master)"
    echo "  --node-type: Node type (leader or follower, default: leader)"
    echo "  --mining-pubkey: Public key for mining (optional)"
    exit 1
}

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --branch) BRANCH="$2"; shift ;;
        --node-type) NODE_TYPE="$2"; shift ;;
        --mining-pubkey) MINING_PUBKEY="$2"; shift ;;
        *) usage ;;
    esac
    shift
done

# Validate node type
if [[ "$NODE_TYPE" != "leader" && "$NODE_TYPE" != "follower" ]]; then
    echo "Error: Invalid node type. Must be 'leader' or 'follower'."
    exit 1
fi

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Step 1: Check network connectivity
log "Checking network connectivity..."
if ! ping -c 1 github.com >/dev/null 2>&1; then
    log "Error: Cannot connect to GitHub. Check your network."
    exit 1
fi

# Step 2: Update system
log "Updating system packages..."
sudo apt-get update && sudo apt-get upgrade -y
if [ $? -ne 0 ]; then
    log "Error: Failed to update system."
    exit 1
fi

# Step 3: Install dependencies
log "Installing dependencies..."
sudo apt install -y curl iptables build-essential git wget lz4 jq make gcc nano automake autoconf tmux htop nvme-cli libgbm1 pkg-config libssl-dev libleveldb-dev tar clang bsdmainutils ncdu unzip
if [ $? -ne 0 ]; then
    log "Error: Failed to install dependencies."
    exit 1
fi

# Step 4: Install Rust
if ! command_exists rustc; then
    log "Installing Rust..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    if [ $? -ne 0 ]; then
        log "Error: Failed to install Rust."
        exit 1
    fi
    # Kiểm tra và thêm Rust vào PATH
    if [ -f "$HOME/.cargo/env" ]; then
        . "$HOME/.cargo/env"
    else
        log "Error: Rust environment file not found at $HOME/.cargo/env."
        exit 1
    fi
    export PATH="$HOME/.cargo/bin:$PATH"
    # Xác nhận Rust được cài đặt
    if ! command_exists rustc; then
        log "Error: Rust is not properly installed."
        exit 1
    fi
else
    log "Rust is already installed."
fi

# Step 5: Verify repository and branch
log "Verifying repository and branch..."
if ! git ls-remote --heads "$REPO_URL" "$BRANCH" | grep -q "$BRANCH"; then
    log "Error: Branch $BRANCH not found in $REPO_URL."
    exit 1
fi

# Step 6: Clone Nockchain repository
log "Cloning Nockchain repository (branch: $BRANCH)..."
if [ -d "$INSTALL_DIR" ]; then
    log "Directory $INSTALL_DIR already exists. Pulling latest changes..."
    cd "$INSTALL_DIR" && git fetch origin && git checkout "$BRANCH" && git pull origin "$BRANCH"
else
    git clone --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
fi
cd "$INSTALL_DIR"
if [ $? -ne 0 ]; then
    log "Error: Failed to clone or update repository."
    exit 1
fi

# Step 7: Check if build is needed
log "Checking if build is needed..."
if [ -f "target/release/nockchain-wallet" ]; then
    log "nockchain-wallet binary found. Skipping build to save time."
else
    log "Building Nockchain (this may take a while)..."
    if grep -q "install-choo" Makefile; then
        make install-choo
        if [ $? -ne 0 ]; then
            log "Warning: Failed to run 'make install-choo'. Continuing..."
        fi
    else
        log "Note: 'make install-choo' not found in Makefile. Skipping..."
    fi

    make build-hoon-all
    if [ $? -ne 0 ]; then
        log "Error: Failed to run 'make build-hoon-all'."
        exit 1
    fi

    make build
    if [ $? -ne 0 ]; then
        log "Error: Failed to run 'make build'."
        exit 1
    fi

    # Debug: Kiểm tra target/release
    log "Checking build output..."
    ls -l target-pocket/release
    if [ ! -f "target/release/nockchain-wallet" ]; then
        log "Error: nockchain-wallet binary not found in target/release."
        exit 1
    fi
fi

# Step 8: Generate wallet
log "Generating wallet..."
export PATH="$PATH:$(pwd)/target/release"
if ! command_exists nockchain-wallet; then
    log "Error: nockchain-wallet command not found. Ensure build was successful."
    exit 1
fi
nockchain-wallet keygen > wallet_output.txt
if [ $? -ne 0 ]; then
    log "Error: Failed to generate wallet."
    exit 1
fi
log "Wallet generated. Details saved in wallet_output.txt."
cat wallet_output.txt

# Step 9: Configure mining public key
if [ -n "$MINING_PUBKEY" ]; then
    log "Configuring mining public key in Makefile..."
    sed -i "s/MINING_PUBKEY =.*/MINING_PUBKEY = $MINING_PUBKEY/" Makefile
    if [ $? -ne 0 ]; then
        log "Error: Failed to update MINING_PUBKEY in Makefile."
        exit 1
    fi
else
    log "Warning: No mining public key provided. You need to manually set MINING_PUBKEY in Makefile."
fi

# Step 10: Create Systemd service
log "Creating Systemd service for Nockchain $NODE_TYPE node..."
cat << EOF | sudo tee /etc/systemd/system/nockchaind.service
[Unit]
Description=Nockchain Node Service
After=network.target

[Service]
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/make run-nockchain-$NODE_TYPE
Restart=always
RestartSec=10
Environment="PATH=/root/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$INSTALL_DIR/target/release"
SyslogIdentifier=nockchaind
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

# Set permissions
sudo chmod 644 /etc/systemd/system/nockchaind.service
if [ $? -ne 0 ]; then
    log "Error: Failed to set permissions for Systemd service file."
    exit 1
fi

# Reload Systemd
sudo systemctl daemon-reload
if [ $? -ne 0 ]; then
    log "Error: Failed to reload Systemd."
    exit 1
fi

# Enable and start service
log "Enabling and starting nockchaind service..."
sudo systemctl enable nockchaind
sudo systemctl start nockchaind
if [ $? -ne 0 ]; then
    log "Error: Failed to start nockchaind service."
    exit 1
fi

# Check service status
log "Checking service status..."
sudo systemctl status nockchaind --no-pager

log "Nockchain $NODE_TYPE node installed and running as a Systemd service!"
log "View logs with: journalctl -u nockchaind -f"
log "Wallet details are in $INSTALL_DIR/wallet_output.txt"