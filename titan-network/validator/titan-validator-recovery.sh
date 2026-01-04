#!/bin/bash

# Script for automatic installation and restoration of Titan Chain validator on new machine
# Assumes backup folder: /root/titan_backup (contains config folder and titan_snapshot.zst file)
# Run as root: sudo bash script.sh
# Modifications: Ask for backup path (default /root/titan_backup); check for titan_snapshot.zst file and config folder; default moniker my-monikey; snapshot name titan_snapshot.zst

# Step 1: Update system and install required packages
sudo apt update && sudo apt upgrade -y
sudo apt install git build-essential wget curl jq zstd pv rsync -y  # Add pv for progress

# Step 2: Check and install Go if not present or version old
GO_REQUIRED="1.21"
GO_LATEST="1.25.5"
if command -v go &> /dev/null; then
  CURRENT_GO_VERSION=$(go version | awk '{print $3}' | sed 's/go//')
  if [[ "$CURRENT_GO_VERSION" < "$GO_REQUIRED" ]]; then
    echo "Go version $CURRENT_GO_VERSION is lower than $GO_REQUIRED, installing new $GO_LATEST..."
    wget https://go.dev/dl/go${GO_LATEST}.linux-amd64.tar.gz
    sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf go${GO_LATEST}.linux-amd64.tar.gz
    echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
    source ~/.bashrc
  else
    echo "Go version $CURRENT_GO_VERSION is sufficient, skipping installation."
  fi
else
  echo "Go not installed, installing version $GO_LATEST..."
  wget https://go.dev/dl/go${GO_LATEST}.linux-amd64.tar.gz
  sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf go${GO_LATEST}.linux-amd64.tar.gz
  echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
  source ~/.bashrc
fi
go version  # Check

# Step 3: Download titand binary from release v0.3.0
wget https://github.com/Titannet-dao/titan-chain/releases/download/v0.3.0/titand_0.3.0-1_g167b7fd6.tar.gz
tar -zxvf titand_0.3.0-1_g167b7fd6.tar.gz --strip-components=1 -C /usr/local/bin
titand version  # Check

# Step 4: Download and install libwasmvm
wget https://github.com/Titannet-dao/titan-chain/releases/download/v0.3.0/libwasmvm.x86_64.so
sudo mv libwasmvm.x86_64.so /usr/local/lib/
sudo ldconfig

# Step 5: Ask user to enter backup path (default: /root/titan_backup)
read -p "Enter path to titan_backup folder (default: /root/titan_backup): " BACKUP_DIR
BACKUP_DIR=${BACKUP_DIR:-/root/titan_backup}

# Check folder exists, has titan_snapshot.zst file and config folder
if [ ! -d "$BACKUP_DIR" ]; then
  echo "Error: Folder $BACKUP_DIR does not exist."
  exit 1
fi
if [ ! -f "$BACKUP_DIR/titan_snapshot.zst" ]; then
  echo "Error: File titan_snapshot.zst does not exist in $BACKUP_DIR."
  exit 1
fi
if [ ! -d "$BACKUP_DIR/config" ]; then
  echo "Error: Config folder does not exist in $BACKUP_DIR."
  exit 1
fi
echo "Backup folder OK."

# Step 6: Ask user to enter moniker for init (default: my-monikey if not entered)
read -p "Enter moniker for validator (default: my-monikey): " MONIKER
MONIKER=${MONIKER:-my-monikey}
titand init "$MONIKER" --chain-id titan-test-4 --home /root/.titan

# Step 7: Copy all from backup/config, override into /root/.titan/config (with progress)
rsync -av --progress "$BACKUP_DIR/config/" /root/.titan/config/

# Step 8: Unpack data snapshot into ~/.titan/data (with pv for progress)
rm -rf /root/.titan/data/*  # Delete default data
zstd -d "$BACKUP_DIR/titan_snapshot.zst" -o temp.tar
if [ -f temp.tar ]; then
  pv temp.tar | tar -xvf - -C /root/.titan/
  rm temp.tar
else
  echo "Error: Unpacking zst failed, check titan_snapshot.zst file."
  exit 1
fi
# Check
du -sh /root/.titan/data

# Step 9: Set ownership (if needed)
chown -R root:root /root/.titan

# Step 10: Create systemd service
cat <<EOF | sudo tee /etc/systemd/system/titan.service
[Unit]
Description=Titan Daemon
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/titand start --home /root/.titan
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

# Reload and start service
sudo systemctl daemon-reload
sudo systemctl enable titan
sudo systemctl start titan

# Step 11: Check log for 3 minutes
journalctl -u titan -f & sleep 180; kill $!

# Step 12: Check status
titand status

echo "Check until you see \"catching_up\":false, which means synchronization is complete. Then you can use the command:"
echo "titand tx slashing unjail --from=\"your_wallet_name\" --chain-id=\"titan-test-4\" --gas=100000 --fees=50000uttnt"
echo "to unjail."
