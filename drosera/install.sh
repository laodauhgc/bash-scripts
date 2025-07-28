#!/usr/bin/env bash
# drosera.sh version v0.1.9
# Automated installer for Drosera Operator on VPS
set -euo pipefail

# ANSI color codes
GREEN="\e[1;32m"
YELLOW="\e[1;33m"
BLUE="\e[1;34m"
RED="\e[1;31m"
RESET="\e[0m"

# Banner
echo -e "${BLUE}🛠️  drosera.sh v0.1.7 - Automated Installer for Drosera Operator 🛠️${RESET}"

# Print functions
title() { echo -e "\n${YELLOW}➤ ${1}${RESET}"; }
error() { echo -e "${RED}❌ ${1}${RESET}" >&2; }
info()  { echo -e "${GREEN}✅ ${1}${RESET}"; }
usage() {
  echo -e "${BLUE}Usage:${RESET} $0 --pk <private_key> [--rpc <rpc_url>] [--backup-rpc <backup_rpc_url>]"
  echo -e "         [--contract <drosera_address>] [--chain-id <chain_id>] [--p2p-port <p2p_port>] [--rpc-port <rpc_port>] [--db-dir <db_directory>] [--help]"
  exit 1
}

# Defaults (can override via environment)
: "${DRO_ETH_PRIVATE_KEY:=}"
: "${DRO_DROSERA_ADDRESS:=0x91cB447BaFc6e0EA0F4Fe056F5a9b1F14bb06e5D}"
: "${DRO_RPC_URL:=https://ethereum-hoodi-rpc.publicnode.com}"
: "${DRO_BACKUP_RPC_URL:=https://1rpc.io/hoodi}"
: "${DRO_CHAIN_ID:=56048}"
: "${DRO_P2P_PORT:=31313}"
: "${DRO_SERVER_PORT:=31314}"
: "${DRO_DB_DIR:=/var/lib/drosera-data}"
: "${DRO_DROSERA_SEED_URL:=https://relay.hoodi.drosera.io}"
LISTEN_ADDR="0.0.0.0"
# You can override the seed node RPC endpoint with --seed-rpc-url <url> if needed
: "${DRO_ETH_PRIVATE_KEY:=}"
: "${DRO_DROSERA_ADDRESS:=0x91cB447BaFc6e0EA0F4Fe056F5a9b1F14bb06e5D}"
: "${DRO_RPC_URL:=https://ethereum-hoodi-rpc.publicnode.com}"
: "${DRO_BACKUP_RPC_URL:=https://1rpc.io/hoodi}"
: "${DRO_CHAIN_ID:=56048}"
: "${DRO_P2P_PORT:=31313}"
: "${DRO_SERVER_PORT:=31314}"
: "${DRO_DB_DIR:=/var/lib/drosera-data}"
LISTEN_ADDR="0.0.0.0"

# Parse flags
title "Parsing flags"
while [[ $# -gt 0 ]]; do
  case $1 in
    --pk)           DRO_ETH_PRIVATE_KEY="$2";    shift 2 ;;  
    --rpc)          DRO_RPC_URL="$2";            shift 2 ;;  
    --backup-rpc)   DRO_BACKUP_RPC_URL="$2";     shift 2 ;;  
    --contract)     DRO_DROSERA_ADDRESS="$2";   shift 2 ;;  
    --chain-id)     DRO_CHAIN_ID="$2";           shift 2 ;;  
    --p2p-port)     DRO_P2P_PORT="$2";           shift 2 ;;  
    --rpc-port)     DRO_SERVER_PORT="$2";        shift 2 ;;  
    --db-dir)       DRO_DB_DIR="$2";             shift 2 ;;  
    --seed-rpc-url) DRO_DROSERA_SEED_URL="$2";   shift 2 ;;  
    --help)         usage ;;  
    *) error "Unknown flag: $1"; usage ;;  
  esac
done
title "Parsing flags"
while [[ $# -gt 0 ]]; do
  case $1 in
    --pk)         DRO_ETH_PRIVATE_KEY="$2"; shift 2 ;;  
    --rpc)        DRO_RPC_URL="$2";         shift 2 ;;  
    --backup-rpc) DRO_BACKUP_RPC_URL="$2";  shift 2 ;;  
    --contract)   DRO_DROSERA_ADDRESS="$2"; shift 2 ;;  
    --chain-id)   DRO_CHAIN_ID="$2";        shift 2 ;;  
    --p2p-port)   DRO_P2P_PORT="$2";        shift 2 ;;  
    --rpc-port)   DRO_SERVER_PORT="$2";     shift 2 ;;  
    --db-dir)     DRO_DB_DIR="$2";          shift 2 ;;  
    --help)       usage ;;  
    *) error "Unknown flag: $1"; usage ;;  
  esac
done

# Validate private key
title "Validating private key"
if [[ -z "${DRO_ETH_PRIVATE_KEY}" ]]; then
  read -rp "🔑 Enter your Ethereum private key (hex, with 0x prefix): " DRO_ETH_PRIVATE_KEY
  if [[ -z "${DRO_ETH_PRIVATE_KEY}" ]]; then
    error "Private key required. Exiting."
    exit 1
  fi
fi
info "Using provided private key: ${DRO_ETH_PRIVATE_KEY}"

# 1. Install dependencies
title "Installing dependencies"
info "Updating package list"
apt-get update -qq
info "Installing required packages"
apt-get install -y curl clang libssl-dev tar ufw >/dev/null

# 2. Install/Update Drosera CLI
title "Installing/Updating Drosera CLI"
if [[ ! -x "${HOME}/.drosera/bin/droseraup" ]]; then
  info "Installing droseraup"
  curl -sL https://app.drosera.io/install | bash
else
  info "droseraup found, updating"
fi

# Configure path for CLI
title "Configuring PATH for Drosera CLI"
export PATH="${HOME}/.drosera/bin:$PATH"
hash -r

# Update CLI
title "Running droseraup"
droseraup >/dev/null || { error "droseraup installation failed"; exit 1; }
info "Drosera CLI installed/updated"

# 3. Register operator
# *** Updated: added handling for already-registered operator ***
title "Registering operator"
info "RPC endpoint: ${DRO_RPC_URL}"
if ! command -v drosera-operator &>/dev/null; then
  error "drosera-operator CLI not found. Exiting.";
  exit 1
fi

# Attempt registration, handle already-registered case
set +e
REGISTER_OUTPUT=$(drosera-operator register \
  --eth-rpc-url "${DRO_RPC_URL}" \
  --eth-private-key "${DRO_ETH_PRIVATE_KEY}" 2>&1)
REGISTER_EXIT=$?
set -e
if [ $REGISTER_EXIT -eq 0 ]; then
  info "Operator registration complete"
elif echo "$REGISTER_OUTPUT" | grep -q "OperatorAlreadyRegistered"; then
  info "Operator already registered, skipping registration"
else
  error "Failed to register operator:"
  echo "$REGISTER_OUTPUT" >&2
  exit $REGISTER_EXIT
fi

# 4. Prepare database directory. Prepare database directory" Prepare database directory
title "Preparing database directory"
info "Creating ${DRO_DB_DIR}"
mkdir -p "${DRO_DB_DIR}"
chmod 700 "${DRO_DB_DIR}"
info "Database directory ready"

# 5. Retrieve external IP (IPv4 only)
title "Retrieving external IPv4"
# Try primary endpoint with IPv4 forcing
EXTERNAL_IP=$(curl -4 -s https://ifconfig.co)
# Fallback to icanhazip if empty
default_ip="$(curl -4 -s https://ipv4.icanhazip.com)"
if [[ -z "${EXTERNAL_IP}" ]]; then
  EXTERNAL_IP=${default_ip}
fi
# Remove any whitespace or newline
EXTERNAL_IP=$(echo "${EXTERNAL_IP}" | tr -d '[:space:]')
if [[ -z "${EXTERNAL_IP}" ]]; then
  error "Failed to retrieve external IPv4 address. Exiting.";
  exit 1
fi
info "External IPv4 is ${EXTERNAL_IP}"

# 6. Create systemd service file
title "Creating systemd service file"
SERVICE_FILE="/etc/systemd/system/drosera-operator.service"
cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Drosera Operator Service
Requires=network.target
After=network.target

[Service]
Type=simple
Restart=always
Environment="DRO__DB_FILE_PATH=${DRO_DB_DIR}/drosera.db"
Environment="DRO__DROSERA_ADDRESS=${DRO_DROSERA_ADDRESS}"
Environment="DRO__DROSERA__RPC_URL=${DRO_DROSERA_SEED_URL}"
Environment="DRO__ETH__CHAIN_ID=${DRO_CHAIN_ID}"
Environment="DRO__ETH__RPC_URL=${DRO_RPC_URL}"
Environment="DRO__ETH__BACKUP_RPC_URL=${DRO_BACKUP_RPC_URL}"
Environment="DRO__ETH__PRIVATE_KEY=${DRO_ETH_PRIVATE_KEY}"
Environment="DRO__NETWORK__P2P_PORT=${DRO_P2P_PORT}"
Environment="DRO__NETWORK__EXTERNAL_P2P_ADDRESS=${EXTERNAL_IP}"
Environment="DRO__SERVER__PORT=${DRO_SERVER_PORT}"
ExecStart=${HOME}/.drosera/bin/drosera-operator node=${HOME}/.drosera/bin/drosera-operator node

[Install]
WantedBy=multi-user.target
EOF
info "Service file written to ${SERVICE_FILE}"

# 7. Start & enable service & enable service
title "Starting and enabling service"
info "Reloading systemd daemon"
systemctl daemon-reload
info "Starting drosera-operator.service"
systemctl start drosera-operator.service
info "Enabling drosera-operator.service on boot"
systemctl enable drosera-operator.service
info "Service is running"

# 8. Configure UFW firewall
title "Configuring UFW firewall"
info "Allowing SSH (22)"
ufw allow 22/tcp
info "Allowing P2P port (${DRO_P2P_PORT})"
ufw allow "${DRO_P2P_PORT}"/tcp
info "Allowing RPC port (${DRO_SERVER_PORT})"
ufw allow "${DRO_SERVER_PORT}"/tcp
info "Enabling UFW"
yes | ufw enable
info "Firewall configured"

# Done
title "Installation complete"
info "Drosera Operator is installed and running"
info "Check status: systemctl status drosera-operator.service"
info "View logs: journalctl -u drosera-operator.service -f"
