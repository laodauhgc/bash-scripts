#!/bin/bash

# Script to automate Kaisar Provider CLI installation and execution
# Usage: ./kaisar-auto-setup.sh [FLAGS]
# Version v0.2.0
# Function to display usage information
usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -s, --start                Start the Kaisar Provider App"
    echo "  -c, --create-wallet EMAIL  Create a new wallet with the specified email"
    echo "  -i, --import-wallet EMAIL KEY  Import an existing wallet with email and private key"
    echo "  -p, --password PASS        Password for importing wallet (required with -i)"
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

    # Check if expect is installed
    if ! command -v expect >/dev/null 2>&1; then
        echo "Installing expect for password automation..."
        if [[ "$ID" == "ubuntu" ]]; then
            sudo apt-get update
            sudo apt-get install -y expect
        elif [[ "$ID" == "centos" ]]; then
            sudo yum install -y expect
        fi
    fi

    echo "System requirements met."
}

# Function to install dependencies
install_dependencies() {
    echo "Installing dependencies..."
    # Update package list and install curl, tar, git
    if [[ "$ID" == "ubuntu" ]]; then
        sudo apt-get update
        sudo apt-get install -y curl tar git
    elif [[ "$ID" == "centos" ]]; then
        sudo yum install -y curl tar git
    fi

    # Install nvm and Node.js 22.17.1
    if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1 || [[ "$(node -v)" != "v22.17.1" ]]; then
        echo "Installing nvm and Node.js 22.17.1..."
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
        # Source nvm to make it available in the current session
        [ -s "$HOME/.nvm/nvm.sh" ] && \. "$HOME/.nvm/nvm.sh"
        # Install Node.js 22.17.1
        nvm install 22.17.1
        # Verify installation
        if [[ "$(node -v)" != "v22.17.1" ]]; then
            echo "Error: Failed to install Node.js 22.17.1."
            exit 1
        fi
        echo "Node.js $(node -v) and npm $(npm -v) installed successfully."
    else
        echo "Node.js $(node -v) and npm $(npm -v) already installed."
    fi

    # Install pm2
    if ! command -v pm2 >/dev/null 2>&1; then
        echo "Installing pm2..."
        npm install -g pm2
    fi
}

# Function to download and set up Kaisar Provider CLI
setup_kaisar() {
    echo "Downloading Kaisar Provider setup script..."
    curl -O https://raw.githubusercontent.com/Kaisar-Network/kaisar-releases/main/kaisar-provider-setup.sh
    chmod +x kaisar-provider-setup.sh
    echo "Running Kaisar setup script..."
    # Source nvm again before running the Kaisar setup script to ensure Node.js 22.17.1 is used
    [ -s "$HOME/.nvm/nvm.sh" ] && \. "$HOME/.nvm/nvm.sh"
    nvm use 22.17.1
    sudo ./kaisar-provider-setup.sh
}

# Function to verify installation
verify_installation() {
    echo "Verifying Kaisar CLI installation..."
    # Source nvm to ensure the correct Node.js version is used
    [ -s "$HOME/.nvm/nvm.sh" ] && \. "$HOME/.nvm/nvm.sh"
    nvm use 22.17.1
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
    # Source nvm to ensure the correct Node.js version is used
    [ -s "$HOME/.nvm/nvm.sh" ] && \. "$HOME/.nvm/nvm.sh"
    nvm use 22.17.1
    if kaisar status 2>/dev/null | grep -q "Kaisar Provider is not running"; then
        echo "Kaisar Provider is not running. Starting it now..."
        kaisar start || {
warden Provider CLI setup and execution completed."
    fi
}

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
    if [[ -z "$PASSWORD" ]]; then
        echo "Error: Password required for importing wallet. Use -p or --password flag."
        exit 1
    fi
    # Validate private key format
    if ! validate_private_key "$PRIVATE_KEY"; then
        echo "Skipping wallet import due to invalid private key."
    else
        echo "Importing wallet with email: $EMAIL..."
        # Try with the provided key first
        /usr/bin/expect <<EOF
            spawn kaisar import-wallet -e "$EMAIL" -k "$PRIVATE_KEY"
            expect "Enter password:"
            send "$PASSWORD\r"
            expect eof
EOF
        if [[ $? -ne 0 ]]; then
            echo "Retrying wallet import without '0x' prefix..."
            # Strip '0x' prefix if present and retry
            CLEAN_KEY=$(echo "$PRIVATE_KEY" | sed 's/^0x//')
            /usr/bin/expect <<EOF
                spawn kaisar import-wallet -e "$EMAIL" -k "$CLEAN_KEY"
                expect "Enter password:"
                send "$PASSWORD\r"
                expect eof
EOF
            if [[ $? -ne 0 ]]; then
                echo "Error: Failed to import wallet. Please verify the private key and password."
            fi
        fi
    fi
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
