#!/bin/bash

# Script Name: n8n-manager.sh
# Version: v0.1.9

SCRIPT_VERSION="v0.1.9"

BASE_DIR="/opt/n8n-instances"
CLOUDFLARED_ETC="/etc/cloudflared"
SYSTEMD_DIR="/etc/systemd/system"
DEFAULT_CONFIG="$BASE_DIR/default-config.json"

# Colors and Icons
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
CHECK="\u2705"
CROSS="\u274C"
INFO="\u2139\uFE0F"
WARNING="\u26A0\uFE0F"
ARROW="\u279C"

check_dependencies() {
    local missing=0
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}${CROSS} Error: Docker is not installed. Please install Docker first.${NC}"
        missing=1
    fi
    if ! command -v docker compose &> /dev/null; then
        echo -e "${RED}${CROSS} Error: Docker Compose is not installed. Please install it first.${NC}"
        missing=1
    fi
    if ! command -v cloudflared &> /dev/null; then
        echo -e "${RED}${CROSS} Error: Cloudflared is not installed. Please install it first.${NC}"
        missing=1
    fi
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}${CROSS} Error: jq is not installed. Please install jq for JSON handling (sudo apt install jq).${NC}"
        missing=1
    fi
    if [ $missing -eq 1 ]; then
        exit 1
    fi
}

save_config() {
    cat <<EOF > "$DEFAULT_CONFIG"
{
  "hostname": "$HOSTNAME",
  "timezone": "$TIMEZONE",
  "enable_auth": "$ENABLE_AUTH",
  "auth_user": "${AUTH_USER:-}",
  "auth_pass": "${AUTH_PASS:-}",
  "use_pg": "$USE_PG",
  "pg_db": "${PG_DB:-}",
  "pg_user": "${PG_USER:-}",
  "pg_pass": "${PG_PASS:-}",
  "n8n_port": "$N8N_PORT"
}
EOF
    echo -e "${GREEN}${CHECK} Default config saved to $DEFAULT_CONFIG.${NC}"
}

load_config() {
    if [ -f "$DEFAULT_CONFIG" ]; then
        HOSTNAME=$(jq -r '.hostname' "$DEFAULT_CONFIG")
        TIMEZONE=$(jq -r '.timezone' "$DEFAULT_CONFIG")
        ENABLE_AUTH=$(jq -r '.enable_auth' "$DEFAULT_CONFIG")
        AUTH_USER=$(jq -r '.auth_user' "$DEFAULT_CONFIG")
        AUTH_PASS=$(jq -r '.auth_pass' "$DEFAULT_CONFIG")
        USE_PG=$(jq -r '.use_pg' "$DEFAULT_CONFIG")
        PG_DB=$(jq -r '.pg_db' "$DEFAULT_CONFIG")
        PG_USER=$(jq -r '.pg_user' "$DEFAULT_CONFIG")
        PG_PASS=$(jq -r '.pg_pass' "$DEFAULT_CONFIG")
        N8N_PORT=$(jq -r '.n8n_port' "$DEFAULT_CONFIG")
        echo -e "${GREEN}${CHECK} Loaded default config. You can override any field.${NC}"
    else
        echo -e "${YELLOW}${WARNING} No default config found.${NC}"
    fi
}

install_instance() {
    read -p "$(echo -e "${BLUE}${ARROW} Enter instance name (e.g., myn8n, no spaces): ${NC}")" INSTANCE_NAME
    INSTANCE_DIR="$BASE_DIR/$INSTANCE_NAME"
    if [ -d "$INSTANCE_DIR" ]; then
        echo -e "${RED}${CROSS} Error: Instance $INSTANCE_NAME already exists.${NC}"
        return
    fi

    mkdir -p "$INSTANCE_DIR"
    cd "$INSTANCE_DIR" || exit

    read -p "$(echo -e "${BLUE}${ARROW} Load default config? (y/n): ${NC}")" LOAD_CONFIG
    if [ "$LOAD_CONFIG" == "y" ]; then
        load_config
    fi

    read -p "$(echo -e "${BLUE}${ARROW} Enter hostname (e.g., n8n.example.com) [${HOSTNAME:-}]: ${NC}")" INPUT
    HOSTNAME=${INPUT:-$HOSTNAME}
    DOMAIN=$(echo $HOSTNAME | cut -d'.' -f2-)
    read -p "$(echo -e "${BLUE}${ARROW} Enter timezone (e.g., Asia/Ho_Chi_Minh) [${TIMEZONE:-}]: ${NC}")" INPUT
    TIMEZONE=${INPUT:-$TIMEZONE}
    read -p "$(echo -e "${BLUE}${ARROW} Enable basic auth? (y/n) [${ENABLE_AUTH:-}]: ${NC}")" INPUT
    ENABLE_AUTH=${INPUT:-$ENABLE_AUTH}
    if [ "$ENABLE_AUTH" == "y" ]; then
        read -p "$(echo -e "${BLUE}${ARROW} Enter basic auth username [${AUTH_USER:-}]: ${NC}")" INPUT
        AUTH_USER=${INPUT:-$AUTH_USER}
        read -s -p "$(echo -e "${BLUE}${ARROW} Enter basic auth password [${AUTH_PASS:-hidden}]: ${NC}")" INPUT
        if [ ! -z "$INPUT" ]; then AUTH_PASS=$INPUT; fi
        echo
    fi
    read -p "$(echo -e "${BLUE}${ARROW} Use PostgreSQL for database? (y/n) [${USE_PG:-}]: ${NC}")" INPUT
    USE_PG=${INPUT:-$USE_PG}
    if [ "$USE_PG" == "y" ]; then
        read -p "$(echo -e "${BLUE}${ARROW} Enter PostgreSQL database name [${PG_DB:-}]: ${NC}")" INPUT
        PG_DB=${INPUT:-$PG_DB}
        read -p "$(echo -e "${BLUE}${ARROW} Enter PostgreSQL username [${PG_USER:-}]: ${NC}")" INPUT
        PG_USER=${INPUT:-$PG_USER}
        read -s -p "$(echo -e "${BLUE}${ARROW} Enter PostgreSQL password [${PG_PASS:-hidden}]: ${NC}")" INPUT
        if [ ! -z "$INPUT" ]; then PG_PASS=$INPUT; fi
        echo
    fi
    read -p "$(echo -e "${BLUE}${ARROW} Enter N8N port (default 5678) [${N8N_PORT:-5678}]: ${NC}")" INPUT
    N8N_PORT=${INPUT:-${N8N_PORT:-5678}}

    save_config

    cat <<EOF > docker-compose.yml
services:
  n8n:
    image: n8nio/n8n:latest
    container_name: ${INSTANCE_NAME}-n8n
    restart: always
    ports:
      - "127.0.0.1:${N8N_PORT}:5678"
    environment:
      - N8N_HOST=${HOSTNAME}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - N8N_EDITOR_BASE_URL=https://${HOSTNAME}/
      - WEBHOOK_URL=https://${HOSTNAME}/
      - TZ=${TIMEZONE}
EOF

    if [ "$ENABLE_AUTH" == "y" ]; then
        cat <<EOF >> docker-compose.yml
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=${AUTH_USER}
      - N8N_BASIC_AUTH_PASSWORD=${AUTH_PASS}
EOF
    fi

    if [ "$USE_PG" == "y" ]; then
        cat <<EOF >> docker-compose.yml
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_DATABASE=${PG_DB}
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_USER=${PG_USER}
      - DB_POSTGRESDB_PASSWORD=${PG_PASS}
    volumes:
      - ./n8n_data:/home/node/.n8n
    depends_on:
      - postgres

  postgres:
    image: postgres:16
    container_name: ${INSTANCE_NAME}-postgres
    restart: always
    environment:
      - POSTGRES_DB=${PG_DB}
      - POSTGRES_USER=${PG_USER}
      - POSTGRES_PASSWORD=${PG_PASS}
    volumes:
      - ./postgres_data:/var/lib/postgresql/data
EOF
    else
        cat <<EOF >> docker-compose.yml
    volumes:
      - ./n8n_data:/home/node/.n8n
EOF
    fi

    mkdir -p n8n_data
    chown 1000:1000 n8n_data
    if [ "$USE_PG" == "y" ]; then
        mkdir -p postgres_data
        chown 999:999 postgres_data
    fi

    docker compose up -d
    echo -e "${GREEN}${CHECK} n8n instance $INSTANCE_NAME started.${NC}"

    # Check if tunnel exists
    EXISTING_UUID=$(cloudflared tunnel list | grep "${INSTANCE_NAME}-tunnel" | awk '{print $1}')
    if [ -n "$EXISTING_UUID" ]; then
        echo -e "${YELLOW}${INFO} Tunnel ${INSTANCE_NAME}-tunnel already exists. Using existing UUID: $EXISTING_UUID${NC}"
        UUID="$EXISTING_UUID"
    else
        CREATE_OUTPUT=$(cloudflared tunnel create ${INSTANCE_NAME}-tunnel 2>&1)
        if echo "$CREATE_OUTPUT" | grep -q "failed"; then
            echo -e "${RED}${CROSS} Error: Failed to create tunnel. $CREATE_OUTPUT${NC}"
            return
        fi
        sleep 5  # Wait for sync
        EXISTING_UUID=$(cloudflared tunnel list | grep "${INSTANCE_NAME}-tunnel" | awk '{print $1}')
        UUID="$EXISTING_UUID"
    fi

    cat <<EOF > $CLOUDFLARED_ETC/${INSTANCE_NAME}-tunnel.yml
tunnel: ${INSTANCE_NAME}-tunnel
credentials-file: /root/.cloudflared/${UUID}.json
ingress:
  - hostname: ${HOSTNAME}
    service: http://localhost:${N8N_PORT}
  - service: http_status:404
EOF

    # Handle DNS route
    ROUTE_OUTPUT=$(cloudflared tunnel route dns ${INSTANCE_NAME}-tunnel ${HOSTNAME} 2>&1)
    if echo "$ROUTE_OUTPUT" | grep -q "already exists"; then
        echo -e "${YELLOW}${WARNING} Existing CNAME detected for ${HOSTNAME}. To update it manually:${NC}"
        echo -e "1. Go to Cloudflare Dashboard > Select domain ${DOMAIN} > DNS tab."
        echo -e "2. Find the CNAME record for ${HOSTNAME} and delete it."
        echo -e "3. Rerun this script (install instance) to add the correct CNAME."
        echo -e "Alternatively, edit the existing CNAME to point to ${UUID}.cfargotunnel.com."
        echo -e "After updating DNS, restart the tunnel service: systemctl restart cloudflared-${INSTANCE_NAME}.service"
    else
        echo -e "${GREEN}${CHECK} DNS route created successfully.${NC}"
    fi

    cat <<EOF > $SYSTEMD_DIR/cloudflared-${INSTANCE_NAME}.service
[Unit]
Description=Cloudflare Tunnel - ${INSTANCE_NAME}-tunnel
After=network.target

[Service]
TimeoutStartSec=0
ExecStart=/usr/bin/cloudflared --no-autoupdate --config $CLOUDFLARED_ETC/${INSTANCE_NAME}-tunnel.yml tunnel run
Restart=on-failure
RestartSec=5s
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable cloudflared-${INSTANCE_NAME}.service
    systemctl start cloudflared-${INSTANCE_NAME}.service

    echo -e "${GREEN}${CHECK} Installation complete. Access at https://${HOSTNAME}${NC}"
    echo -e "${YELLOW}${INFO} To fix 'Connection lost' error, create a Cloudflare Transform Rule:${NC}"
    echo -e "1. Go to Cloudflare Dashboard > Rules > Transform Rules > Modify Request Header."
    echo -e "2. Create rule: When hostname equals ${HOSTNAME}, set Origin header to https://${HOSTNAME}."
    echo -e "3. Deploy."
}

update_instance() {
    read -p "$(echo -e "${BLUE}${ARROW} Enter instance name to update: ${NC}")" INSTANCE_NAME
    INSTANCE_DIR="$BASE_DIR/$INSTANCE_NAME"
    if [ ! -d "$INSTANCE_DIR" ]; then
        echo -e "${RED}${CROSS} Error: Instance $INSTANCE_NAME not found.${NC}"
        return
    fi

    cd "$INSTANCE_DIR" || exit
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}${CHECK} Update complete for $INSTANCE_NAME.${NC}"
}

edit_instance() {
    read -p "$(echo -e "${BLUE}${ARROW} Enter instance name to edit: ${NC}")" INSTANCE_NAME
    INSTANCE_DIR="$BASE_DIR/$INSTANCE_NAME"
    if [ ! -d "$INSTANCE_DIR" ]; then
        echo -e "${RED}${CROSS} Error: Instance $INSTANCE_NAME not found.${NC}"
        return
    fi

    echo -e "${YELLOW}${INFO} To edit, stop the instance, edit files manually (e.g., docker-compose.yml, tunnel.yml), then restart.${NC}"
    cd "$INSTANCE_DIR" || exit
    docker compose down
    systemctl stop cloudflared-${INSTANCE_NAME}.service

    read -p "$(echo -e "${BLUE}${ARROW} Press Enter after editing files...${NC}")"
    
    docker compose up -d
    systemctl start cloudflared-${INSTANCE_NAME}.service
    echo -e "${GREEN}${CHECK} Edit complete for $INSTANCE_NAME.${NC}"
}

remove_instance() {
    read -p "$(echo -e "${BLUE}${ARROW} Enter instance name to remove: ${NC}")" INSTANCE_NAME
    INSTANCE_DIR="$BASE_DIR/$INSTANCE_NAME"
    if [ ! -d "$INSTANCE_DIR" ]; then
        echo -e "${RED}${CROSS} Error: Instance $INSTANCE_NAME not found.${NC}"
        return
    fi

    cd "$INSTANCE_DIR" || exit
    docker compose down -v
    rm -rf "$INSTANCE_DIR"

    systemctl stop cloudflared-${INSTANCE_NAME}.service
    systemctl disable cloudflared-${INSTANCE_NAME}.service
    rm $SYSTEMD_DIR/cloudflared-${INSTANCE_NAME}.service
    systemctl daemon-reload

    rm $CLOUDFLARED_ETC/${INSTANCE_NAME}-tunnel.yml

    cloudflared tunnel delete ${INSTANCE_NAME}-tunnel --force

    echo -e "${GREEN}${CHECK} Removal complete for $INSTANCE_NAME.${NC}"
}

main_menu() {
    echo -e "${BLUE}======================================${NC}"
    echo -e "${BLUE} n8n Manager Script - Version $SCRIPT_VERSION ${NC}"
    echo -e "${BLUE}======================================${NC}"
    echo -e "${YELLOW}Select an action:${NC}"
    echo -e "1) ${GREEN}Install new instance${NC}"
    echo -e "2) ${GREEN}Update existing instance${NC}"
    echo -e "3) ${GREEN}Edit existing instance${NC}"
    echo -e "4) ${GREEN}Remove existing instance${NC}"
    echo -e "5) ${GREEN}List instances${NC}"
    echo -e "6) ${RED}Exit${NC}"
    echo -e "${BLUE}======================================${NC}"

    read -p "$(echo -e "${BLUE}${ARROW} Enter choice: ${NC}")" CHOICE
    case $CHOICE in
        1) install_instance ;;
        2) update_instance ;;
        3) edit_instance ;;
        4) remove_instance ;;
        5) ls -1 $BASE_DIR ;;
        6) exit 0 ;;
        *) echo -e "${RED}${CROSS} Invalid choice.${NC}" ;;
    esac
    main_menu
}

check_dependencies
mkdir -p $BASE_DIR
main_menu
