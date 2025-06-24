#!/bin/bash

# Variables
INSTALL_DIR="$HOME/.nexus"
SERVICE_NAME="nexus-network"
NEXUS_BIN="$INSTALL_DIR/bin/nexus-network"

# Function to validate Node ID (numeric)
validate_node_id() {
    [[ "$1" =~ ^[0-9]+$ ]] || { echo "Invalid Node ID: Must be numeric (e.g., 6878969)"; return 1; }
    return 0
}

# Function to validate Wallet Address (Ethereum address format)
validate_wallet_address() {
    [[ "$1" =~ ^0x[a-fA-F0-9]{40}$ ]] || { echo "Invalid Wallet Address: Must be a valid Ethereum address (e.g., 0x238a3a4ff431De579885D4cE0297af7A0d3a1b32)"; return 1; }
    return 0
}

# Check for remove option
REMOVE_NODE=false
while getopts "r" opt; do
    case $opt in
        r) REMOVE_NODE=true ;;
        *) echo "Usage: $0 [-r] [<NODE_ID> <WALLET_ADDRESS>]"; exit 1 ;;
    esac
done

# Shift past the options
shift $((OPTIND-1))

# Handle remove node option
if [ "$REMOVE_NODE" = true ]; then
    echo "Removing Nexus node..."
    sudo systemctl stop $SERVICE_NAME.service 2>/dev/null || true
    sudo systemctl disable $SERVICE_NAME.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/$SERVICE_NAME.service
    sudo systemctl daemon-reload
    rm -rf "$INSTALL_DIR"
    "$NEXUS_BIN" logout 2>/dev/null || true
    echo "Node removed. Credentials and data cleared."
    exit 0
fi

# Variables for installation
NODE_ID="$1"
WALLET_ADDRESS="$2"

# Prompt for Node ID if not provided or invalid
while [ -z "$NODE_ID" ] || ! validate_node_id "$NODE_ID"; do
    read -p "Enter Node ID (e.g., 6878969): " NODE_ID
    validate_node_id "$NODE_ID" || continue
done

# Prompt for Wallet Address if not provided or invalid
while [ -z "$WALLET_ADDRESS" ] || ! validate_wallet_address "$WALLET_ADDRESS"; do
    read -p "Enter Wallet Address (e.g., 0x238a3a4ff431De579885D4cE0297af7A0d3a1b32): " WALLET_ADDRESS
    validate_wallet_address "$WALLET_ADDRESS" || continue
done

# Check if Nexus binary exists
if [ ! -f "$NEXUS_BIN" ]; then
    echo "Nexus CLI binary not found at $NEXUS_BIN. Please run 'install_nexus_deps.sh' first and ensure PATH is updated."
    exit 1
fi

# Configure Nexus CLI using direct binary path
echo "Registering with Wallet Address: $WALLET_ADDRESS"
"$NEXUS_BIN" register-user --wallet-address "$WALLET_ADDRESS" || { echo "Failed to register user. Aborting."; exit 1; }
"$NEXUS_BIN" register-node || { echo "Failed to register node. Aborting."; exit 1; }
START_CMD="$NEXUS_BIN start --node-id $NODE_ID"

# Create systemd service
echo "Setting up systemd service..."
sudo tee /etc/systemd/system/$SERVICE_NAME.service > /dev/null <<EOF
[Unit]
Description=Nexus Network CLI Service
After=network.target

[Service]
ExecStart=$START_CMD
Restart=always
User=$USER
Environment=HOME=$HOME
WorkingDirectory=$INSTALL_DIR

[Install]
WantedBy=multi-user.target
EOF

# Enable and start service
sudo systemctl daemon-reload
sudo systemctl enable $SERVICE_NAME.service
sudo systemctl start $SERVICE_NAME.service

# Check service status
sudo systemctl status $SERVICE_NAME.service --no-pager

# Verify and notify about credentials
if [ -f "$INSTALL_DIR/credentials.json" ]; then
    echo "Credentials saved to $INSTALL_DIR/credentials.json"
    echo "Please back up the contents of $INSTALL_DIR/credentials.json for future reference."
else
    echo "No credentials file generated."
fi
