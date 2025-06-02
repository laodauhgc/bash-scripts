#!/bin/bash

# Script to automate Blockcast BEACON setup with Docker installation check for Ubuntu

# Ensure script runs with sudo privileges
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script as root (use sudo)"
    exit 1
fi

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo "Docker not found. Installing Docker..."
    wget -O /docker.sh https://get.docker.com && chmod +x /docker.sh && /docker.sh
    if [ $? -ne 0 ]; then
        echo "Error: Failed to install Docker"
        exit 1
    fi
    # Add user to docker group to run docker without sudo
    usermod -aG docker $SUDO_USER
    echo "Docker installed successfully. Please log out and log back in to apply docker group changes."
else
    echo "Docker is already installed."
fi

# Check if Docker service is running
if ! systemctl is-active --quiet docker; then
    echo "Starting Docker service..."
    systemctl start docker
    systemctl enable docker
    if [ $? -ne 0 ]; then
        echo "Error: Failed to start Docker service"
        exit 1
    fi
fi

# Install git if not present
if ! command -v git &> /dev/null; then
    echo "Installing git..."
    apt-get update && apt-get install -y git
    if [ $? -ne 0 ]; then
        echo "Error: Failed to install git"
        exit 1
    fi
fi

# Clone the Blockcast BEACON docker-compose repository
echo "Cloning Blockcast BEACON repository..."
git clone https://github.com/Blockcast/beacon-docker-compose.git
cd beacon-docker-compose || { echo "Failed to enter directory"; exit 1; }

# Start Blockcast BEACON
echo "Starting Blockcast BEACON..."
docker compose up -d || { echo "Failed to start Blockcast BEACON"; exit 1; }

# Wait for BEACON to initialize
sleep 10

# Generate hardware and challenge key
echo "Generating hardware and challenge key..."
INIT_OUTPUT=$(docker compose exec -T blockcastd blockcastd init 2>&1)
if [ $? -ne 0 ]; then
    echo "Error: Failed to generate keys"
    echo "$INIT_OUTPUT"
    exit 1
fi

# Extract Hardware ID, Challenge Key, and Registration URL
HWID=$(echo "$INIT_OUTPUT" | grep "Hardware ID" | cut -d ':' -f 2 | tr -d '[:space:]')
CHALLENGE_KEY=$(echo "$INIT_OUTPUT" | grep "Challenge Key" | cut -d ':' -f 2 | tr -d '[:space:]')
REG_URL=$(echo "$INIT_OUTPUT" | grep "Registration URL" | cut -d ':' -f 2- | tr -d '[:space:]')

# Check if keys were extracted successfully
if [ -z "$HWID" ] || [ -z "$CHALLENGE_KEY" ] || [ -z "$REG_URL" ]; then
    echo "Error: Failed to extract keys or URL from init output"
    exit 1
fi

# Output results
echo -e "\nBlockcast BEACON Setup Complete!"
echo "Hardware ID: $HWID"
echo "Challenge Key: $CHALLENGE_KEY"
echo "Registration URL: $REG_URL"
echo -e "\nNext Steps:"
echo "1. Visit https://app.blockcast.network/ and log in"
echo "2. Paste the Registration URL in your browser or manually enter the Hardware ID and Challenge Key at Manage Nodes > Register Node"
echo "3. Enable location in your browser"
echo "4. Backup your private key at ~$HOME/certs/gateway.key"
echo -e "\nNote: Check node status at /manage-nodes after a few minutes. Node should show 'Healthy'."
echo "First connectivity test runs after 6 hours. Rewards start after 24 hours."
