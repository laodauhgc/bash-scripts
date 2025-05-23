#!/bin/bash

# Script to update nockchaind.service with new ExecStart
# Usage: ./update_nockchaind.sh

# ========= Màu sắc =========
RESET='\033[0m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'

# ========= Đường dẫn =========
ENV_FILE="/root/nockchain/.env"
SERVICE_FILE="/etc/systemd/system/nockchaind.service"

# ========= Ghi log =========
log() {
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Step 1: Kiểm tra file .env
log "${YELLOW}Kiểm tra file .env...${RESET}"
if [ ! -f "$ENV_FILE" ]; then
  log "${RED}Lỗi: Không tìm thấy $ENV_FILE. Đảm bảo Nockchain đã được cài đặt!${RESET}"
  exit 1
fi

# Step 2: Trích xuất MINING_PUBKEY
log "${YELLOW}Trích xuất MINING_PUBKEY từ .env...${RESET}"
MINING_PUBKEY=$(grep "^MINING_PUBKEY=" "$ENV_FILE" | cut -d'=' -f2-)
if [ -z "$MINING_PUBKEY" ]; then
  log "${RED}Lỗi: Không tìm thấy MINING_PUBKEY trong $ENV_FILE. Sửa file .env!${RESET}"
  exit 1
fi
log "${GREEN}MINING_PUBKEY: $MINING_PUBKEY${RESET}"

# Step 3: Dừng dịch vụ hiện tại
log "${YELLOW}Dừng dịch vụ nockchaind...${RESET}"
sudo systemctl stop nockchaind 2>/dev/null

# Step 4: Cập nhật file nockchaind.service
log "${YELLOW}Cập nhật file $SERVICE_FILE...${RESET}"
sudo bash -c "cat > $SERVICE_FILE" << EOF
[Unit]
Description=Nockchain Miner Service
After=network.target

[Service]
User=root
WorkingDirectory=/root/nockchain
ExecStart=/root/nockchain/target/release/nockchain --mining-pubkey $MINING_PUBKEY --mine --peer /ip4/95.216.102.60/udp/3006/quic-v1 --peer /ip4/65.108.123.225/udp/3006/quic-v1 --peer /ip4/65.109.156.108/udp/3006/quic-v1 --peer /ip4/65.21.67.175/udp/3006/quic-v1 --peer /ip4/65.109.156.172/udp/3006/quic-v1 --peer /ip4/34.174.22.166/udp/3006/quic-v1 --peer /ip4/34.95.155.151/udp/30000/quic-v1 --peer /ip4/34.18.98.38/udp/30000/quic-v1
Restart=always
RestartSec=10
Environment="PATH=/root/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/root/nockchain/target/release"
SyslogIdentifier=nockchaind
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

if [ $? -ne 0 ]; then
  log "${RED}Lỗi: Không thể cập nhật $SERVICE_FILE!${RESET}"
  exit 1
fi

# Step 5: Đặt quyền cho file dịch vụ
log "${YELLOW}Đặt quyền cho $SERVICE_FILE...${RESET}"
sudo chmod 644 "$SERVICE_FILE"
if [ $? -ne 0 ]; then
  log "${RED}Lỗi: Không thể đặt quyền cho $SERVICE_FILE!${RESET}"
  exit 1
fi

# Step 6: Tải lại Systemd
log "${YELLOW}Tải lại Systemd...${RESET}"
sudo systemctl daemon-reload
if [ $? -ne 0 ]; then
  log "${RED}Lỗi: Không thể tải lại Systemd!${RESET}"
  exit 1
fi

# Step 7: Mở cổng UDP
log "${YELLOW}Mở cổng 3006 và 30000 (UDP)...${RESET}"
sudo ufw allow 3006/udp && sudo ufw allow 30000/udp
if [ $? -ne 0 ]; then
  log "${YELLOW}Cảnh báo: Không thể mở cổng UDP. Kiểm tra firewall!${RESET}"
fi

# Step 8: Khởi động lại dịch vụ
log "${YELLOW}Khởi động lại dịch vụ nockchaind...${RESET}"
sudo systemctl enable nockchaind
sudo systemctl start nockchaind
if [ $? -ne 0 ]; then
  log "${RED}Lỗi: Không thể khởi động nockchaind!${RESET}"
  exit 1
fi

# Step 9: Kiểm tra trạng thái
log "${YELLOW}Kiểm tra trạng thái dịch vụ...${RESET}"
sudo systemctl status nockchaind --no-pager
log "${GREEN}Cập nhật nockchaind.service hoàn tất!${RESET}"
log "${YELLOW}Xem log: journalctl -u nockchaind -f${RESET}"
