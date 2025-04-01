#!/bin/bash

# -----------------------------------------------------------------------------
# Configuration Variables
# -----------------------------------------------------------------------------

WIREGUARD_DIR="/etc/wireguard"
SERVER_IP="10.0.0.1"
WIREGUARD_PORT="51820"
CLIENT_IP="10.0.0.2"
INTERFACE_NAME="wg0" # Name of the WireGuard interface
SSH_PORT="22" # Standard SSH Port

# -----------------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------------

# install_wireguard: Installs WireGuard and iptables-persistent
install_wireguard() {
  echo "Installing WireGuard and iptables-persistent..."
  sudo apt update
  # Preseed the answers to the debconf questions
  sudo debconf-set-selections <<< "iptables-persistent iptables-persistent/autosave_v4 boolean true"
  sudo debconf-set-selections <<< "iptables-persistent iptables-persistent/autosave_v6 boolean true"
  DEBIAN_FRONTEND=noninteractive sudo apt install -y wireguard iptables-persistent
  echo "Installation complete."
}

# generate_keys: Generates WireGuard key pair
generate_keys() {
  echo "Generating WireGuard key pair..."
  mkdir -p "$WIREGUARD_DIR"

  if [[ ! -f "$WIREGUARD_DIR/private.key" ]]; then
    wg genkey | tee "$WIREGUARD_DIR/private.key" | wg pubkey > "$WIREGUARD_DIR/public.key"
    echo "Key pair generated successfully in $WIREGUARD_DIR"
  else
    echo "Key pair already exists in $WIREGUARD_DIR. Skipping key generation."
  fi
  echo "Client Public Key: $(cat "$WIREGUARD_DIR/public.key")"
}

# show_info: Displays WireGuard configuration information
show_info() {
  echo "--------------------------------------"
  echo "WireGuard Configuration Information"
  echo "--------------------------------------"
  echo "Public Key: $(cat "$WIREGUARD_DIR/public.key")"

  if [[ "$1" == "server" ]]; then
    echo "Server Public IP: $(curl -s ifconfig.me)"
  fi
  echo "--------------------------------------"
}

# configure_firewall: Configures the firewall to allow SSH and WireGuard
configure_firewall() {
  echo "Configuring the firewall (ufw) to allow SSH and WireGuard..."
  # Allow SSH
  sudo ufw allow "${SSH_PORT}/tcp"
  # Allow WireGuard (only on the server)
  if [[ "$1" == "server" ]]; then
     sudo ufw allow "${WIREGUARD_PORT}/udp"
  fi

  # Enable ufw if it's not already enabled
  if ! sudo ufw status | grep -q "Status: active"; then
    sudo ufw enable --force yes
  fi

  echo "Firewall configuration complete."
}

# setup_server: Configures the WireGuard server
setup_server() {
  local client_public_key="$1"
  local server_private_key=$(cat "$WIREGUARD_DIR/private.key")

  echo "Setting up WireGuard server..."

  # Configure wg0.conf
  cat <<EOL | sudo tee "$WIREGUARD_DIR/$INTERFACE_NAME.conf" > /dev/null
[Interface]
Address = $SERVER_IP/24
PrivateKey = $server_private_key
ListenPort = $WIREGUARD_PORT

# Client Configuration (if provided)
EOL

  if [[ -n "$client_public_key" ]]; then
    echo -e "[Peer]\nPublicKey = $client_public_key\nAllowedIPs = $CLIENT_IP/32" | sudo tee -a "$WIREGUARD_DIR/$INTERFACE_NAME.conf" > /dev/null
  fi

  # Enable IP forwarding and apply changes
  sudo sysctl -w net.ipv4.ip_forward=1
  sudo sysctl -p

  # Configure NAT
  sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE # Adjust eth0 if needed
  sudo netfilter-persistent save

  # Start and enable WireGuard
  sudo systemctl start wg-quick@"${INTERFACE_NAME}"
  sudo systemctl enable wg-quick@"${INTERFACE_NAME}"

  echo "WireGuard server setup complete."
  show_info "server"
}

# setup_client: Configures the WireGuard client
setup_client() {
  local server_public_ip="$1"
  local server_public_key="$2"
  local client_private_key=$(cat "$WIREGUARD_DIR/private.key")

  echo "Setting up WireGuard client..."

  # Configure wg0.conf
  cat <<EOL | sudo tee "$WIREGUARD_DIR/$INTERFACE_NAME.conf" > /dev/null
[Interface]
PrivateKey = $client_private_key
Address = $CLIENT_IP/24

[Peer]
PublicKey = $server_public_key
Endpoint = $server_public_ip:$WIREGUARD_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOL

  # Start and enable WireGuard
  sudo systemctl start wg-quick@"${INTERFACE_NAME}"
  sudo systemctl enable wg-quick@"${INTERFACE_NAME}"

  echo "WireGuard client setup complete."
  show_info "client"
}

# rm_wireguard: Removes WireGuard and its configuration
rm_wireguard() {
  echo "Removing WireGuard and its configuration..."

  # Stop WireGuard interface
  sudo systemctl stop wg-quick@"${INTERFACE_NAME}"

  # Disable WireGuard interface
  sudo systemctl disable wg-quick@"${INTERFACE_NAME}"

  # Remove WireGuard configuration file
  sudo rm -f "$WIREGUARD_DIR/$INTERFACE_NAME.conf"

  # Remove WireGuard key files
  sudo rm -f "$WIREGUARD_DIR/private.key"
  sudo rm -f "$WIREGUARD_DIR/public.key"

  # Remove WireGuard directory (if empty)
  sudo rmdir "$WIREGUARD_DIR" 2>/dev/null # Ignore error if not empty

  # Remove NAT rules
  sudo iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null # Ignore error if rule doesn't exist
  sudo netfilter-persistent save

  # Remove firewall rules
  sudo ufw delete allow "${SSH_PORT}/tcp" 2>/dev/null # Ignore error if rule doesn't exist
  sudo ufw delete allow "${WIREGUARD_PORT}/udp" 2>/dev/null # Ignore error if rule doesn't exist

  # Purge WireGuard package
  sudo apt purge -y wireguard iptables-persistent

  echo "WireGuard removal complete."
}

# -----------------------------------------------------------------------------
# Main Script Logic
# -----------------------------------------------------------------------------

# Check for correct number of arguments
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 [server|client|rm] [optional: server-ip server-public-key | client-public-key]"
  exit 1
fi

# Install WireGuard
if [[ "$1" != "rm" ]]; then
  install_wireguard
fi

# Generate keys
if [[ "$1" != "rm" ]]; then
  generate_keys
fi

# Configure firewall
if [[ "$1" == "server" ]]; then
  configure_firewall "$1"
elif [[ "$1" == "client" ]]; then
  configure_firewall "$1"
fi

# Process server or client setup
case "$1" in
  server)
    setup_server "$2"
    ;;
  client)
    if [[ -z "$2" || -z "$3" ]]; then
      echo "Missing server public IP and server public key for client setup."
      exit 1
    fi
    setup_client "$2" "$3"
    ;;
  rm)
    rm_wireguard
    ;;
  *)
    echo "Invalid argument. Use 'server', 'client', or 'rm'."
    exit 1
    ;;
esac

echo "WireGuard setup completed successfully."
