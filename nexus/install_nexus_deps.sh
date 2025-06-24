#!/bin/bash

# Variables
INSTALL_DIR="$HOME/.nexus"
CLI_URL="https://cli.nexus.xyz/"

# Install dependencies
echo "Installing dependencies..."
sudo apt update
sudo apt upgrade -y
sudo apt install -y build-essential pkg-config libssl-dev git-all protobuf-compiler curl
command -v curl >/dev/null 2>&1 || { echo "curl installation failed. Aborting."; exit 1; }

# Install Rust
command -v rustc >/dev/null 2>&1 || {
    echo "Installing Rust..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
}

# Install Nexus CLI with auto-agree to Terms of Use
echo "Installing Nexus Network CLI..."
echo Y | curl -sSf "$CLI_URL" | sh

echo "Nexus CLI installation complete."
echo "Please run 'source ~/.bashrc' or restart your terminal to update PATH."
echo "Then run './configure_nexus.sh <NODE_ID> <WALLET_ADDRESS>' to continue."
