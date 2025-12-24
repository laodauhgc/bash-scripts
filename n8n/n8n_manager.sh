#!/bin/bash

# Script Name: n8n-manager.sh
# Version: v0.1.5

SCRIPT_VERSION="v0.1.5"

BASE_DIR="/opt/n8n-instances"
CLOUDFLARED_ETC="/etc/cloudflared"
SYSTEMD_DIR="/etc/systemd/system"
DEFAULT_CONFIG="$BASE_DIR/default-config.json"

check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo "Error: Docker is not installed. Please install Docker first."
        exit 1
    fi
    if ! command -v docker compose &> /dev/null; then
        echo "Error: Docker Compose is not installed. Please install it first."
        exit 1
    fi
    if ! command -v cloudflared &> /dev/null; then
        echo "Error: Cloudflared is not installed. Please install it first."
        exit 1
    fi
    if ! command -v jq &> /dev/null; then
        echo "Error: jq is not installed. Please install jq for JSON handling (sudo apt install jq)."
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
    echo "Default config saved to $DEFAULT_CONFIG."
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
        echo "Loaded default config. You can override any field."
    else
        echo "No default config found."
    fi
}

install_instance() {
    read -p "Enter instance name (e.g., myn8n, no spaces): " INSTANCE_NAME
    INSTANCE_DIR="$BASE_DIR/$INSTANCE_NAME"
    if [ -d "$INSTANCE_DIR" ]; then
        echo "Error: Instance $INSTANCE_NAME already exists."
        return
    fi

    mkdir -p "$INSTANCE_DIR"
    cd "$INSTANCE_DIR" || exit

    read -p "Load default config? (y/n): " LOAD_CONFIG
    if [ "$LOAD_CONFIG" == "y" ]; then
        load_config
    fi

    read -p "Enter hostname (e.g., n8n.example.com) [${HOSTNAME:-}]: " INPUT
    HOSTNAME=${INPUT:-$HOSTNAME}
    read -p "Enter timezone (e.g., Asia/Ho_Chi_Minh) [${TIMEZONE:-}]: " INPUT
    TIMEZONE=${INPUT:-$TIMEZONE}
    read -p "Enable basic auth? (y/n) [${ENABLE_AUTH:-}]: " INPUT
    ENABLE_AUTH=${INPUT:-$ENABLE_AUTH}
    if [ "$ENABLE_AUTH" == "y" ]; then
        read -p "Enter basic auth username [${AUTH_USER:-}]: " INPUT
        AUTH_USER=${INPUT:-$AUTH_USER}
        read -s -p "Enter basic auth password [${AUTH_PASS:-hidden}]: " INPUT
        if [ ! -z "$INPUT" ]; then AUTH_PASS=$INPUT; fi
        echo
    fi
    read -p "Use PostgreSQL for database? (y/n) [${USE_PG:-}]: " INPUT
    USE_PG=${INPUT:-$USE_PG}
    if [ "$USE_PG" == "y" ]; then
        read -p "Enter PostgreSQL database name [${PG_DB:-}]: " INPUT
        PG_DB=${INPUT:-$PG_DB}
        read -p "Enter PostgreSQL username [${PG_USER:-}]: " INPUT
        PG_USER=${INPUT:-$PG_USER}
        read -s -p "Enter PostgreSQL password [${PG_PASS:-hidden}]: " INPUT
        if [ ! -z "$INPUT" ]; then PG_PASS=$INPUT; fi
        echo
    fi
    read -p "Enter N8N port (default 5678) [${N8N_PORT:-5678}]: " INPUT
    N8N_PORT=${INPUT:-${N8N_PORT:-5678}}

    save_config  # Save after input for next time

    cat <<EOF > docker-compose.yml
services:
  n8n:
    image: n8nio/n8n:latest
    container_name: ${INSTANCE_NAME}-n8n
    restart: always
    ports:
      - "127.0.0.1:${N8N_PORT}:5678"
    environment:
      - N8N_HOST=localhost
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - N8N_EDITOR_BASE_URL=https://${HOSTNAME}/
      - WEBHOOK_TUNNEL_URL=https://${HOSTNAME}/
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
    echo "n8n instance $INSTANCE_NAME started."

    # Check if tunnel exists
    EXISTING_UUID=$(cloudflared tunnel list | grep "${INSTANCE_NAME}-tunnel" | awk '{print $1}')
    if [ -n "$EXISTING_UUID" ]; then
        echo "Tunnel ${INSTANCE_NAME}-tunnel already exists. Using existing UUID: $EXISTING_UUID"
        UUID="$EXISTING_UUID"
    else
        CREATE_OUTPUT=$(cloudflared tunnel create ${INSTANCE_NAME}-tunnel 2>&1)
        if echo "$CREATE_OUTPUT" | grep -q "failed"; then
            echo "Error: Failed to create tunnel. $CREATE_OUTPUT"
            return
        fi
        sleep 5  # Wait for sync
        INFO_OUTPUT=$(cloudflared tunnel info ${INSTANCE_NAME}-tunnel 2>&1)
        UUID=$(echo "$INFO_OUTPUT" | grep -oP 'ID:\s*\K[0-9a-f-]{36}')
        if [ -z "$UUID" ]; then
            echo "Error: Failed to get UUID from tunnel info."
            return
        fi
    fi

    cat <<EOF > $CLOUDFLARED_ETC/${INSTANCE_NAME}-tunnel.yml
tunnel: ${INSTANCE_NAME}-tunnel
credentials-file: /root/.cloudflared/${UUID}.json
ingress:
  - hostname: ${HOSTNAME}
    service: http://localhost:${N8N_PORT}
  - service: http_status:404
EOF

    # Route DNS only if not already routed
    if ! cloudflared tunnel route list | grep -q "${HOSTNAME}"; then
        cloudflared tunnel route dns ${INSTANCE_NAME}-tunnel ${HOSTNAME}
    else
        echo "CNAME for ${HOSTNAME} already exists. Skipping route dns."
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

    echo "Installation complete. Access at https://${HOSTNAME}"
}

update_instance() {
    read -p "Enter instance name to update: " INSTANCE_NAME
    INSTANCE_DIR="$BASE_DIR/$INSTANCE_NAME"
    if [ ! -d "$INSTANCE_DIR" ]; then
        echo "Error: Instance $INSTANCE_NAME not found."
        return
    fi

    cd "$INSTANCE_DIR" || exit
    docker compose pull
    docker compose up -d
    echo "Update complete for $INSTANCE_NAME."
}

edit_instance() {
    read -p "Enter instance name to edit: " INSTANCE_NAME
    INSTANCE_DIR="$BASE_DIR/$INSTANCE_NAME"
    if [ ! -d "$INSTANCE_DIR" ]; then
        echo "Error: Instance $INSTANCE_NAME not found."
        return
    fi

    echo "To edit, stop the instance, edit files manually (e.g., docker-compose.yml, tunnel.yml), then restart."
    cd "$INSTANCE_DIR" || exit
    docker compose down
    systemctl stop cloudflared-${INSTANCE_NAME}.service

    read -p "Press Enter after editing files..."
    
    docker compose up -d
    systemctl start cloudflared-${INSTANCE_NAME}.service
    echo "Edit complete for $INSTANCE_NAME."
}

remove_instance() {
    read -p "Enter instance name to remove: " INSTANCE_NAME
    INSTANCE_DIR="$BASE_DIR/$INSTANCE_NAME"
    if [ ! -d "$INSTANCE_DIR" ]; then
        echo "Error: Instance $INSTANCE_NAME not found."
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

    echo "Removal complete for $INSTANCE_NAME."
}

main_menu() {
    echo "n8n Manager Script - Version $SCRIPT_VERSION"
    echo "Select an action:"
    echo "1) Install new instance"
    echo "2) Update existing instance"
    echo "3) Edit existing instance"
    echo "4) Remove existing instance"
    echo "5) List instances"
    echo "6) Exit"

    read -p "Enter choice: " CHOICE
    case $CHOICE in
        1) install_instance ;;
        2) update_instance ;;
        3) edit_instance ;;
        4) remove_instance ;;
        5) ls -1 $BASE_DIR ;;
        6) exit 0 ;;
        *) echo "Invalid choice." ;;
    esac
    main_menu
}

check_dependencies
mkdir -p $BASE_DIR
main_menu
