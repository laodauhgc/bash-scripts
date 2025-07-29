#!/bin/bash

# Script to automate Kaisar Provider CLI installation and execution
# Usage: ./kaisar-auto-setup.sh [FLAGS]
# Version: v0.1.0

# Function to display usage information
usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -s, --start                Start the Kaisar Provider App"
    echo "  -c, --create-wallet EMAIL  Create a new wallet with the specified email"
    echo "  -i, --import-wallet EMAIL KEY  Import an existing wallet with email and private key"
    echo "  -t, --status               Check node status"
    echo "  -l, --log                  Check detailed logs of the Provider App"
    echo "  -h, --help                 Display this help message"
    exit 1
}

# Function to check if the system meets requirements
check_requirements() {
    echo "Checking system requirements..."
    # Check if OS is Ubuntu 20.04+ or CentOS 8+
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        if [[ "$ID" == "ubuntu" && "$(echo "$VERSION_ID >= 20.04" | bc -l)" -eq 1 ]]; then
            echo "Supported OS: Ubuntu $VERSION_ID"
        elif [[ "$ID" == "centos" && "$(echo "$VERSION_ID >= 8" | bc -l)" -eq 1 ]]; then
            echo "Supported OS: CentOS $VERSION_ID"
        else
            echo "Error: Unsupported OS. Requires Ubuntu 20.04+ or CentOS 8+."
            exit 1
        fi
    else
        echo "Error: Cannot detect OS."
        exit 1
    fi

    # Check RAM (at least 4GB)
    total_mem=$(free -m | awk '/^Mem:/{print $2}')
    if [[ "$total_mem" -lt 4000 ]]; then
        echo "Error: Insufficient RAM. Requires at least 4GB, found ${total_mem}MB."
        exit 1
    fi

    # Check CPU virtualization support
    if ! grep -E 'vmx|svm' /proc/cpuinfo >/dev/null; then
        echo "Error: CPU does not support virtualization."
        exit 1
    fi

    # Check storage (at least 100GB free)
    free_space=$(df -h / | awk 'NR==2 {print $4}' | tr -d 'G')
    if [[ "$(echo "$free_space < 100" | bc -l)" -eq 1 ]]; then
        echo "Error: Insufficient storage. Requires at least 100GB, found ${free_space}G."
        exit 1
    fi

    # Check internet connectivity
    if ! ping -c 1 google.com >/dev/null 2>&1; then
        echo "Error: No internet connection detected."
        exit 1
    fi

    echo "System requirements met."
}

# Function to install dependencies
install_dependencies() {
    echo "Installing dependencies..."
    # Update package list
    if [[ "$ID" == "ubuntu" ]]; then
        sudo apt-get update
        sudo apt-get install -y curl tar git
    elif [[ "$ID" == "centos" ]]; then
        sudo yum install -y curl tar git
    fi

    # Install Node.js and npm
    if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
        curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
        if [[ "$ID" == "ubuntu" ]]; then
            sudo apt-get install -y nodejs
        elif [[ "$ID" == "centos" ]]; then
            sudo yum install -y nodejs
        fi
    fi

    # Install pm2
    if ! command -v pm2 >/dev/null 2>&1; then
        sudo npm install -g pm2
    fi
}

# Function to download and set up Kaisar Provider CLI
setup_kaisar() {
    echo "Downloading Kaisar Provider setup script..."
    curl -O https://raw.githubusercontent.com/Kaisar-Network/kaisar-releases/main/kaisar-provider-setup.sh
    chmod +x kaisar-provider-setup.sh
    echo "Running Kaisar setup script..."
    sudo ./kaisar-provider-setup.sh
}

# Function to verify installation
verify_installation() {
    echo "Verifying Kaisar CLI installation..."
    if command -v kaisar >/dev/null 2>&1; then
        echo "Kaisar CLI installed successfully. Version: $(kaisar --version 2>/dev/null || echo 'unknown')"
        return 0
    else
        echo "Error: Kaisar CLI installation failed. The 'kaisar' command is not available."
        exit 1
    fi
}

# Function to ensure Kaisar Provider is running
ensure_provider_running() {
    echo "Checking if Kaisar Provider is running..."
    if kaisar status 2>/dev/null | grep -q "Kaisar Provider is not running"; then
        echo "Kaisar Provider is not running. Starting it now..."
        kaisar start || {
            echo "Error: Failed to start Kaisar Provider App."
            exit 1
        }
        # Wait a few seconds to ensure the provider starts
        sleep 5
    else
        echo "Kaisar Provider is already running."
    fi
}

# Parse command-line flags
START=false
CREATE_WALLET=false
IMPORT_WALLET=false
CHECK_STATUS=false
CHECK_LOG=false
EMAIL=""
PRIVATE_KEY=""

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -s|--start) START=true ;;
        -c|--create-wallet) CREATE_WALLET=true; EMAIL="$2"; shift ;;
        -i|--import-wallet) IMPORT_WALLET=true; EMAIL="$2"; PRIVATE_KEY="$3"; shift 2 ;;
        -t|--status) CHECK_STATUS=true ;;
        -l|--log) CHECK_LOG=true ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
    shift
done

# Main execution
check_requirements
install_dependencies
setup_kaisar
verify_installation

# Start the provider if any dependent command is requested
if $CREATE_WALLET || $IMPORT_WALLET || $CHECK_STATUS || $CHECK_LOG; then
    ensure_provider_running
fi

# Execute user-specified commands
if $START; then
    echo "Starting Kaisar Provider App..."
    kaisar start || echo "Error: Failed to start Kaisar Provider App."
fi

if $CREATE_WALLET; then
    if [[ -z "$EMAIL" ]]; then
        echo "Error: Email required for creating wallet."
        exit 1
    fi
    echo "Creating wallet with email: $EMAIL..."
    kaisar create-wallet -e "$EMAIL" || echo "Error: Failed to create wallet."
fi

if $IMPORT_WALLET; then
    if [[ -z "$EMAIL" || -z "$PRIVATE_KEY" ]]; then
        echo "Error: Email and private key required for importing wallet."
        exit 1
    fi
    echo "Importing wallet with email: $EMAIL..."
    kaisar import-wallet -e "$EMAIL" -k "$PRIVATE_KEY" || echo "Error: Failed to import wallet."
fi

if $CHECK_STATUS; then
    echo "Checking node status..."
    kaisar status || echo "Error: Failed to check node status."
fi

if $CHECK_LOG; then
    echo "Checking Provider App logs..."
    kaisar log || echo "Error: Failed to retrieve logs."
fi

echo "Kaisar Provider CLI setup and execution completed."
