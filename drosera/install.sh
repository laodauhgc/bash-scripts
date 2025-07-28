#!/usr/bin/env bash
# drosera.sh version v0.1.0
# Automated installer for Drosera Operator on VPS
set -euo pipefail

# ANSI color codes
GREEN="\e[1;32m"
YELLOW="\e[1;33m"
BLUE="\e[1;34m"
RED="\e[1;31m"
RESET="\e[0m"

# Header
echo -e "${BLUE}🛠️  drosera.sh v0.1.0 - Automated Installer for Drosera Operator 🛠️${RESET}"

title() {
  echo -e "\n${YELLOW}➤ ${1}${RESET}"
}
error() {
  echo -e "${RED}❌ ${1}${RESET}" >&2
}
info() {
  echo -e "${GREEN}✅ ${1}${RESET}"
}

usage() {
  echo -e "${BLUE}Usage:${RESET} $0 [--pk <private_key>] [--rpc <rpc_url>] [--backup-rpc <backup_rpc_url>]"
  echo -e "         [--contract <drosera_address>] [--chain-id <chain_id>] [--p2p-port <p2p_port>]"
  echo -e "         [--rpc-port <rpc_port>] [--db-dir <db_directory>] [--help]"
  echo
  echo -e "Flags:"
  echo -e "  --pk             Ethereum private key (hex, no 0x)"
  echo -e "  --rpc            Primary RPC endpoint (default: $DRO_RPC_URL)"
  echo -e "  --backup-rpc     Backup RPC endpoint (default: $DRO_BACKUP_RPC_URL)"
  echo -e "  --contract       Drosera contract address (default: $DRO_DROSERA_ADDRESS)"
  echo -e "  --chain-id       Chain ID (default: $DRO_CHAIN_ID)"
  echo -e "  --p2p-port       P2P port (default: $DRO_P2P_PORT)"
  echo -e "  --rpc-port       RPC/HTTP port (default: $DRO_SERVER_PORT)"
  echo -e "  --db-dir         Data directory (default: $DRO_DB_DIR)"
  echo -e "  --help           Display this help message"
  exit 1
}

# Defaults (can override via env)
: "${DRO_ETH_PRIVATE_KEY:=}" 
: "${DRO_DROSERA_ADDRESS:=0x91cB447BaFc6e0EA0F4Fe056F5a9b1F14bb06e5D}"
: "${DRO_RPC_URL:=https://1rpc.io/hoodi}"
: "${DRO_BACKUP_RPC_URL:=https://ethereum-hoodi-rpc.publicnode.com}"
: "${DRO_CHAIN_ID:=56048}"
: "${DRO_P2P_PORT:=31313}"
: "${DRO_SERVER_PORT:=31314}"
: "${DRO_DB_DIR:=/var/lib/drosera-data}"
LISTEN_ADDR="0.0.0.0"

# Parse flags
title "Parsing flags"
while [[ $# -gt 0 ]]; do
  case $1 in
    --pk)        DRO_ETH_PRIVATE_KEY="$2"; shift 2 ;;  
    --rpc)       DRO_RPC_URL="$2"; shift 2 ;;  
    --backup-rpc)DRO_BACKUP_RPC_URL="$2"; shift 2 ;;  
    --contract)  DRO_DROSERA_ADDRESS="$2"; shift 2 ;;  
    --chain-id)  DRO_CHAIN_ID="$2"; shift 2 ;;  
    --p2p-port)  DRO_P2P_PORT="$2"; shift 2 ;;  
    --rpc-port)  DRO_SERVER_PORT="$2"; shift 2 ;;  
    --db-dir)    DRO_DB_DIR="$2"; shift 2 ;;  
    --help)      usage ;;  
    *) error "Unknown flag: $1"; usage ;;  
  esac
done

# Check private key
title "Validating private key"
if [[ -z "${DRO_ETH_PRIVATE_KEY}" ]]; then
  read -rp "🔑 Enter your Ethereum private key (hex, no 0x): " DRO_ETH_PRIVATE_KEY
  if [[ -z "${DRO_ETH_PRIVATE_KEY}" ]]; then
    error "Private key required. Exiting."
    exit 1
  fi
fi

# 1. Install dependencies
title "Installing dependencies"
info "Updating package list"
apt-get update -qq
info "Installing curl, clang, libssl-dev, tar, ufw"
apt-get install -y curl clang libssl-dev tar ufw >/dev/null

# 2. Install Drosera CLI
title "Installing Drosera CLI"
if [[ ! -x "${HOME}/.drosera/bin/droseraup" ]]; then
  info "Installing droseraup"
  curl -sL https://app.drosera.io/install | bash
  source "${HOME}/.bashrc"
else
  info "droseraup found, updating"
fi
info "Running droseraup to update CLI"
droseraup >/dev/null

# 3. Register operator
title "Registering operator"
info "Register with RPC: ${DRO_RPC_URL}"
drosera-operator register \
  --eth-rpc-url "${DRO_RPC_URL}" \
  --eth-private-key "${DRO_ETH_PRIVATE_KEY}" >/dev/null

# 4. Prepare database folder
title "Preparing database directory"
info "Creating ${DRO_DB_DIR}"
mkdir -p "${DRO_DB_DIR}"
chmod 700 "${DRO_DB_DIR}"

# 5. Get external IP
title "Retrieving external IP"
EXTERNAL_IP=$(curl -s https://ifconfig.co)
if [[ -z "$EXTERNAL_IP" ]]; then
  error "Failed to get external IP. Exiting."
  exit 1
fi
info "External IP is ${EXTERNAL_IP}"

# 6. Create systemd service
title "Creating systemd service file"
SERVICE_FILE="/etc/systemd/system/drosera-operator.service"
cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Drosera Operator Service
Requires=network.target
After=network.target

[Service]
Type=simple
Restart=always
Environment="DRO__DB_FILE_PATH=${DRO_DB_DIR}/drosera.db"
Environment="DRO__DROSERA_ADDRESS=${DRO_DROSERA_ADDRESS}"
Environment="DRO__LISTEN_ADDRESS=${LISTEN_ADDR}"
Environment="DRO__ETH__CHAIN_ID=${DRO_CHAIN_ID}"
Environment="DRO__ETH__RPC_URL=${DRO_RPC_URL}"
Environment="DRO__ETH__BACKUP_RPC_URL=${DRO_BACKUP_RPC_URL}"
Environment="DRO__ETH__PRIVATE_KEY=${DRO_ETH_PRIVATE_KEY}"
Environment="DRO__NETWORK__P2P_PORT=${DRO_P2P_PORT}"
Environment="DRO__NETWORK__EXTERNAL_P2P_ADDRESS=${EXTERNAL_IP}"
Environment="DRO__SERVER__PORT=${DRO_SERVER_PORT}"
ExecStart=${HOME}/.drosera/bin/drosera-operator node

[Install]
WantedBy=multi-user.target
EOF
info "Service file written to ${SERVICE_FILE}"

# 7. Start & enable service
title "Starting and enabling service"
info "Reloading systemd daemon"
systemctl daemon-reload
info "Starting drosera-operator.service"
systemctl start drosera-operator.service
info "Enabling drosera-operator.service on boot"
systemctl enable drosera-operator.service

# 8. Configure firewall
title "Configuring UFW firewall"
info "Allowing SSH (22)"
ufw allow 22/tcp
info "Allowing P2P port (${DRO_P2P_PORT})"
ufw allow "${DRO_P2P_PORT}"/tcp
info "Allowing RPC port (${DRO_SERVER_PORT})"
ufw allow "${DRO_SERVER_PORT}"/tcp
info "Enabling UFW"
ye | ufw enable

# Done
title "Installation complete"
info "Drosera Operator is running"
info "Check status: systemctl status drosera-operator.service"
info "View logs: journalctl -u drosera-operator.service -f"
