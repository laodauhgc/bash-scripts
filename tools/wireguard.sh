#!/bin/bash

# -----------------------------------------------------------------------------
# Configuration Variables
# -----------------------------------------------------------------------------

WIREGUARD_DIR="/etc/wireguard"
SERVER_IP="10.0.0.1"
WIREGUARD_PORT="51820"
CLIENT_IP="10.0.0.2"
INTERFACE_NAME="wg0" # Name of the WireGuard interface

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

# -----------------------------------------------------------------------------
# Main Script Logic
# -----------------------------------------------------------------------------

# Check for correct number of arguments
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 [server|client] [optional: server-ip server-public-key | client-public-key]"
  exit 1
fi

# Install WireGuard
install_wireguard

# Generate keys
generate_keys

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
  *)
    echo "Invalid argument. Use 'server' or 'client'."
    exit 1
    ;;
esac

echo "WireGuard setup completed successfully."
