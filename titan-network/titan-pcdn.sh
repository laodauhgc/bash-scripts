#!/bin/bash
# titan-pcdn.sh - Automatic installation of Titan PCDN using a custom image

# Exit immediately if a command exits with a non-zero status.
set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Function to check for Root privileges ---
check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error: This script requires root privileges to run.${NC}"
    echo -e "${YELLOW}Please use 'sudo ./titan-pcdn.sh [ACCESS_TOKEN]' or run as root.${NC}"
    exit 1
  fi
  echo -e "${GREEN}* Root privileges confirmed.${NC}"
}

# --- Function to install Docker ---
install_docker() {
  # Check if Docker and Docker Compose plugin are already installed
  if command -v docker &> /dev/null && docker compose version &> /dev/null; then
    echo -e "${GREEN}* Docker and Docker Compose plugin are already installed.${NC}"
    return 0
  fi

  echo -e "${BLUE}* Starting installation of Docker and Docker Compose plugin...${NC}"
  export DEBIAN_FRONTEND=noninteractive
  # Update package list
  apt-get update -y > /dev/null
  # Install necessary packages
  apt-get install -y apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release > /dev/null
  # Add Docker GPG key
  mkdir -p /usr/share/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --batch --yes --output /usr/share/keyrings/docker-archive-keyring.gpg --dearmor
  # Add Docker repository
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  # Install Docker Engine and Compose plugin
  apt-get update -y > /dev/null
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin > /dev/null
  # Start and enable Docker service
  systemctl start docker
  systemctl enable docker
  echo -e "${GREEN}* Docker and Docker Compose plugin have been installed and started.${NC}"
}

# --- Main function to set up PCDN ---
setup_pcdn() {
  local access_token="$1"
  local project_dir=~/titan-pcdn # Installation directory
  # *** Set the correct image name here ***
  # Make sure this matches the image you built (e.g., latest-secured)
  local target_image="laodauhgc/titan-pcdn:latest-secured"

  echo -e "${BLUE}* Starting Titan PCDN configuration in directory: ${project_dir}${NC}"

  # Create directory and change into it
  mkdir -p "${project_dir}/data/docker"
  cd "${project_dir}" || exit 1

  # Create .env file
  echo -e "${BLUE}  - Creating .env file containing ACCESS_TOKEN...${NC}"
  echo "ACCESS_TOKEN=${access_token}" > .env
  chmod 600 .env # Restrict read permissions for security

  # Create docker-compose.yaml file
  echo -e "${BLUE}  - Creating docker-compose.yaml file...${NC}"
  cat > docker-compose.yaml << EOF
services:
  titan-pcdn:
    image: ${target_image} # <<< Use the variable containing the correct image name
    container_name: titan-pcdn
    privileged: true
    restart: always
    tty: true
    stdin_open: true
    security_opt:
      - apparmor:unconfined
    network_mode: host
    volumes:
      - ./data:/app/data                     
      - ./data/docker:/var/lib/docker       
      # - /etc/docker:/etc/docker:ro        
      - /var/run/docker.sock:/var/run/docker.sock 
    environment:
      - ACCESS_TOKEN=\${ACCESS_TOKEN} 
      - TARGETARCH=amd64             
      - OS=linux
      # - RUST_LOG=debug               
EOF

  # Pull the latest image
  echo -e "${BLUE}* Pulling the latest image: ${target_image}...${NC}" # <<< Use variable
  if docker compose pull; then # Compose will read the image from the yaml file
    echo -e "${GREEN}* Image pulled successfully.${NC}"
  else
    echo -e "${RED}Error: Could not pull image ${target_image}. Please check network connection and image name.${NC}" # <<< Use variable
    exit 1
  fi

  # Start the container
  echo -e "${BLUE}* Starting Titan PCDN container...${NC}"
  if docker compose up -d; then
    echo -e "${GREEN}* Container started successfully!${NC}"
    echo -e "=================================================="
    echo -e "${GREEN}=== Installation and Startup Complete! ===${NC}"
    echo -e "  - Installation directory: ${project_dir}"
    echo -e "  - ACCESS_TOKEN has been configured (saved in .env file)."
    echo -e "  - Check logs: ${YELLOW}cd ${project_dir} && docker compose logs -f${NC}"
    echo -e "  - Current container status:"
    sleep 2 # Give container a moment to appear in ps
    docker compose ps
    echo ""
    echo -e "  Management commands:"
    echo -e "  - Start:   ${YELLOW}cd ${project_dir} && docker compose up -d${NC}"
    echo -e "  - Stop:    ${YELLOW}cd ${project_dir} && docker compose down${NC}"
    echo -e "  - Restart: ${YELLOW}cd ${project_dir} && docker compose restart${NC}"
    echo -e "=================================================="
  else
    echo -e "${RED}Error: Could not start container. Please check logs using the command:${NC}"
    echo -e "${YELLOW}cd ${project_dir} && docker compose logs${NC}"
    exit 1
  fi
}

# --- Main Program ---

echo "=================================================="
echo "     Welcome to the Titan PCDN Installation Script     "
echo "=================================================="

# 1. Check for root privileges
check_root

# 2. Get ACCESS_TOKEN
USER_ACCESS_TOKEN=""
if [ -z "$1" ]; then
  read -p "Please enter your ACCESS_TOKEN: " USER_ACCESS_TOKEN
else
  USER_ACCESS_TOKEN=$1
fi

if [ -z "$USER_ACCESS_TOKEN" ]; then
  echo -e "${RED}Error: ACCESS_TOKEN cannot be empty.${NC}"
  exit 1
fi
echo -e "${GREEN}* Received ACCESS_TOKEN.${NC}"

# 3. Install Docker (if needed)
install_docker

# 4. Set up and run PCDN
setup_pcdn "$USER_ACCESS_TOKEN"

exit 0
