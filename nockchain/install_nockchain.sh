#!/bin/bash

# Script to automate Nockchain installation with Systemd service
# Usage: ./install_nockchain.sh [--branch BRANCH] [--mining-pubkey PUBKEY]

# Default values
BRANCH="master"
MINING_PUBKEY=""
INSTALL_DIR="$HOME/nockchain"
REPO_URL="https://github.com/zorp-corp/nockchain.git"
ENV_FILE="$INSTALL_DIR/.env"
BACKUP_DIR="$HOME/nockchain_backup"

# Function to display usage
usage() {
    echo "Usage: $0 [--branch BRANCH] [--mining-pubkey PUBKEY]"
    echo "  --branch: Git branch to clone (default: master)"
    echo "  --mining-pubkey: Public key for mining (optional)"
    exit 1
}

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --branch) BRANCH="$2"; shift ;;
        --mining-pubkey) MINING_PUBKEY="$2"; shift ;;
        *) usage ;;
    esac
    shift
done

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
sudo apt install -y curl git make clang llvm-dev libclang-dev
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
    if [ -f "$HOME/.cargo/env" ]; then
        . "$HOME/.cargo/env"
    else
        log "Error: Rust environment file not found at $HOME/.cargo/env."
        exit 1
    fi
    export PATH="$HOME/.cargo/bin:$PATH"
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

# Step 7: Copy .env file
log "Copying .env file..."
if [ ! -f ".env" ]; then
    cp .env_example .env
    if [ $? -ne 0 ]; then
        log "Error: Failed to copy .env_example to .env."
        exit 1
    fi
else
    log ".env file already exists. Skipping copy."
fi

# Step 8: Check if build is needed
log "Checking if build is needed..."
if [ -f "target/release/nockchain-wallet" ] && [ -f "target/release/nockchain" ]; then
    log "nockchain-wallet and nockchain binaries found. Skipping build to save time."
else
    log "Building Nockchain (this may take a while)..."
    make install-hoonc
    if [ $? -ne 0 ]; then
        log "Warning: Failed to run 'make install-hoonc'. Continuing..."
    fi

    make build
    if [ $? -ne 0 ]; then
        log "Error: Failed to run 'make build'."
        exit 1
    fi

    make install-nockchain-wallet
    if [ $? -ne 0 ]; then
        log "Error: Failed to install nockchain-wallet."
        exit 1
    fi

    make install-nockchain
    if [ $? -ne 0 ]; then
        log "Error: Failed to install nockchain."
        exit 1
    fi

    log "Checking build output..."
    ls -l target/release
    if [ ! -f "target/release/nockchain-wallet" ] || [ ! -f "target/release/nockchain" ]; then
        log "Error: nockchain-wallet or nockchain binary not found in target/release."
        exit 1
    fi
fi

# Step 9: Generate or reuse wallet
log "Checking for existing wallet..."
if [ -f "wallet_output.txt" ]; then
    log "Existing wallet found at wallet_output.txt. Skipping wallet generation to preserve it."
    log "Wallet details:"
    cat wallet_output.txt
    log "Please ensure MINING_PUBKEY matches the public key in wallet_output.txt."
else
    log "No existing wallet found. Generating new wallet..."
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
    log "New wallet generated. Details saved in wallet_output.txt."
    cat wallet_output.txt
fi

# Step 10: Export wallet keys for backup
log "Exporting wallet keys for backup..."
mkdir -p "$BACKUP_DIR"
export PATH="$PATH:$(pwd)/target/release"
nockchain-wallet export-keys
if [ $? -ne 0 ]; then
    log "Warning: Failed to export wallet keys. Ensure wallet is generated."
else
    log "Wallet keys exported to keys.export."
    cp keys.export "$BACKUP_DIR/keys.export"
    cp wallet_output.txt "$BACKUP_DIR/wallet_output.txt"
    chmod 600 "$BACKUP_DIR/keys.export" "$BACKUP_DIR/wallet_output.txt"
    log "Keys backed up to $BACKUP_DIR/keys.export and $BACKUP_DIR/wallet_output.txt."
fi
log "Important: Back up $BACKUP_DIR/keys.export and $BACKUP_DIR/wallet_output.txt securely, as they contain your private key."

# Step 11: Configure mining public key
if [ -n "$MINING_PUBKEY" ]; then
    log "Configuring mining public key in .env..."
    if grep -q "MINING_PUBKEY=" "$ENV_FILE"; then
        sed -i "s/MINING_PUBKEY=.*/MINING_PUBKEY=$MINING_PUBKEY/" "$ENV_FILE"
    else
        echo "MINING_PUBKEY=$MINING_PUBKEY" >> "$ENV_FILE"
    fi
    if [ $? -ne 0 ]; then
        log "Error: Failed to update MINING_PUBKEY in .env."
        exit 1
    fi
else
    log "Warning: No mining public key provided. You need to manually set MINING_PUBKEY in .env."
fi

# Step 12: Check for .data.nockchain
log "Checking for .data.nockchain..."
if [ -f ".data.nockchain" ]; then
    log "Warning: .data.nockchain found. For mainnet, run in a clean directory. Backing up and removing..."
    mv .data.nockchain "$BACKUP_DIR/data.nockchain.bak"
fi

# Step 13: Create Systemd service
log "Creating Systemd service for Nockchain miner..."
cat << EOF | sudo tee /etc/systemd/system/nockchaind.service
[Unit]
Description=Nockchain Miner Service
After=network.target

[Service]
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/make run-nockchain
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

# Step 14: Open firewall ports
log "Opening ports 3005 and 3006..."
sudo ufw allow 22/tcp && sudo ufw allow 3005:3006/tcp && sudo ufw --force enable
if [ $? -ne 0 ]; then
    log "Warning: Failed to open ports. Ensure 3005 and 3006 are accessible."
fi

# Check service status
log "Checking service status..."
sudo systemctl status nockchaind --no-pager

log "Nockchain miner installed and running as a Systemd service!"
log "View logs with: journalctl -u nockchaind -f"
log "Wallet details are in $INSTALL_DIR/wallet_output.txt"
log "Backup keys are in $BACKUP_DIR/keys.export and $BACKUP_DIR/wallet_output.txt"
