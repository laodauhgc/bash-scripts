#!/bin/bash

# Script to automate the update of Titan Guardian (titand systemd service)

# Define variables
TITAN_VERSION="v0.1.22"
TITAN_URL="https://github.com/Titannet-dao/titan-node/releases/download/${TITAN_VERSION}/titan-l1-guardian"
TITAN_BINARY="titan-l1-guardian"
SYSTEM_DIR="/usr/local/bin"
SERVICE_NAME="titand"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Function to check for errors
check_error() {
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: $1${NC}"
        exit 1
    fi
}

echo "Starting the update process for Titan Guardian version ${TITAN_VERSION}..."

# Step 0: Stop the titand service
echo "Stopping the $SERVICE_NAME service..."
systemctl stop $SERVICE_NAME
check_error "Failed to stop the $SERVICE_NAME service"
echo -e "${GREEN}The $SERVICE_NAME service has been stopped${NC}"

# Step 1: Remove the old version
echo "Removing the old version of $TITAN_BINARY..."
if [ -f "$(which $TITAN_BINARY)" ]; then
    rm -f "$(which $TITAN_BINARY)"
    check_error "Failed to remove the old version"
    echo -e "${GREEN}Old version removed successfully${NC}"
else
    echo "No old version found, skipping removal"
fi

# Step 2: Download the new version
echo "Downloading the new version from $TITAN_URL..."
wget -O $TITAN_BINARY "$TITAN_URL"
check_error "Failed to download the new version"
echo -e "${GREEN}New version downloaded successfully${NC}"

# Step 3: Move and set permissions
echo "Moving $TITAN_BINARY to $SYSTEM_DIR and setting permissions..."
mv $TITAN_BINARY $SYSTEM_DIR/
check_error "Failed to move $TITAN_BINARY to $SYSTEM_DIR"
chmod 0755 $SYSTEM_DIR/$TITAN_BINARY
check_error "Failed to set permissions for $TITAN_BINARY"
echo -e "${GREEN}Moved and set permissions successfully${NC}"

# Step 4: Start the service
echo "Starting the $SERVICE_NAME service..."
systemctl start $SERVICE_NAME
check_error "Failed to start the $SERVICE_NAME service"
echo -e "${GREEN}The $SERVICE_NAME service has been started${NC}"

# Step 5: Check the version
echo "Checking the version of $TITAN_BINARY..."
$TITAN_BINARY -v
check_error "Failed to check the version"
echo -e "${GREEN}Update to version ${TITAN_VERSION} completed!${NC}"

# Step 6: Sleep for 5 seconds and reboot the VM
echo "Waiting for 5 seconds before rebooting the VM..."
sleep 5
echo "Rebooting the VM now..."
reboot

exit 0
