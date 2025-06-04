#!/bin/bash

# Script to automate Blockcast BEACON setup with Docker installation check and uninstall option for Ubuntu

# Function to uninstall Blockcast BEACON
uninstall_blockcast() {
    echo "Uninstalling Blockcast BEACON..."
    # Navigate to repository directory if exists
    if [ -d "beacon-docker-compose" ]; then
        cd beacon-docker-compose || { echo "Failed to enter directory"; exit 1; }
        # Stop and remove containers
        docker-compose down || { echo "Failed to stop Blockcast BEACON"; exit 1; }
        cd ..
        # Remove repository directory
        rm -rf beacon-docker-compose
        echo "Blockcast BEACON uninstalled successfully."
    else
        echo "Blockcast BEACON repository not found. Nothing to uninstall."
    fi
    exit 0
}

# Check for -r flag to uninstall
while getopts "r" opt; do
    case $opt in
        r)
            uninstall_blockcast
            ;;
        *)
            echo "Usage: $0 [-r]"
            exit 1
            ;;
    esac
done

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

# Check if docker-compose is installed
if ! command -v docker-compose &> /dev/null; then
    echo "Docker Compose not found. Installing Docker Compose..."
    apt-get update && apt-get install -y docker-compose
    if [ $? -ne 0 ]; then
        echo "Error: Failed to install Docker Compose"
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
if [ -d "beacon-docker-compose" ]; then
    echo "Repository already exists. Removing and re-cloning..."
    rm -rf beacon-docker-compose
fi
git clone https://github.com/Blockcast/beacon-docker-compose.git
cd beacon-docker-compose || { echo "Failed to enter directory"; exit 1; }

# Start Blockcast BEACON
echo "Starting Blockcast BEACON..."
docker-compose up -d || { echo "Failed to start Blockcast BEACON"; exit 1; }

# Wait for BEACON to initialize
sleep 15

# Generate hardware and challenge key
echo "Generating hardware and challenge key..."
INIT_OUTPUT=$(docker-compose exec -T blockcastd blockcastd init 2>&1)
if [ $? -ne 0 ]; then
    echo "Error: Failed to generate keys"
    echo "Init command output:"
    echo "$INIT_OUTPUT"
    exit 1
fi

# Check if INIT_OUTPUT is empty
if [ -z "$INIT_OUTPUT" ]; then
    echo "Error: No output from init command"
    exit 1
fi

# Extract Hardware ID, Challenge Key, and Registration URL
HWID=$(echo "$INIT_OUTPUT" | grep -i "Hardware ID" | cut -d ':' -f 2- | tr -d '[:space:]')
CHALLENGE_KEY=$(echo "$INIT_OUTPUT" | grep -i "Challenge Key" | cut -d ':' -f 2- | tr -d '[:space:]')
REG_URL=$(echo "$INIT_OUTPUT" | grep -i "Registration URL" | cut -d ':' -f 2- | tr -d '[:space:]')

# Check if keys were extracted successfully
if [ -z "$HWID" ] || [ -z "$CHALLENGE_KEY" ] || [ -z "$REG_URL" ]; then
    echo "Error: Failed to extract keys or URL from init output"
    echo "Init command output:"
    echo "$INIT_OUTPUT"
    exit 1
fi

# Output results
echo -e "\nBlockcast BEACON Setup Complete!"
echo -e "====== Backup Blockcast ======"
echo "Hardware ID: $HWID"
echo "Challenge Key: $CHALLENGE_KEY"
echo "Registration URL: $REG_URL"
echo -e "\nBuild Info:"
echo "$INIT_OUTPUT" | grep -i "Commit\|Build" | sed 's/^/        /'
echo -e "\nPrivate Key:"
echo "cat ~/.blockcast/certs/gw_challenge.key"
cat ~/.blockcast/certs/gw_challenge.key
echo "cat ~/.blockcast/certs/gateway.key"
cat ~/.blockcast/certs/gateway.key
echo "cat ~/.blockcast/certs/gateway.crt"
cat ~/.blockcast/certs/gateway.crt
echo -e "====== End ======"
echo -e "\nNext Steps:"
echo "1. Visit https://app.blockcast.network/ and log in"
echo "2. Paste the Registration URL in your browser or manually enter the Hardware ID and Challenge Key at Manage Nodes > Register Node"
echo "3. Enter VM Location. Example: US, India, Indonesia..."
echo "4. Back up the content exported above."
echo -e "\nNote: Check node status at /manage-nodes after a few minutes. Node should show 'Healthy'."
echo "First connectivity test runs after 6 hours. Rewards start after 24 hours."
