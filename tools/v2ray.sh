#!/usr/bin/env bash

# install_v2ray.sh: Tự động cài đặt V2Ray trên Ubuntu 22.04 và cấu hình firewall
# Yêu cầu: Chạy với quyền root hoặc sudo
# version v0.2

set -euo pipefail

# 1. Cập nhật và cài đặt các công cụ cần thiết
apt update
apt install -y curl unzip uuid-runtime ufw

# 2. Chọn cổng ngẫu nhiên có khả năng trùng thấp (10000-60000)
PORT=$(shuf -i 10000-60000 -n 1)
# Đảm bảo cổng SSH luôn mở
SSH_PORT=22

# 3. Sinh UUID cho client
UUID=$(uuidgen)

# 4. Cài đặt V2Ray sử dụng script chính thức
bash <(curl -L -s https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)

# 5. Thiết lập cấu hình V2Ray
# Đường dẫn config mặc định của script cài tại /usr/local/etc/v2ray/config.json
CONFIG_FILE="/usr/local/etc/v2ray/config.json"
BACKUP_FILE="/usr/local/etc/v2ray/config.json.bak_$(date +%s)"

# backup file cũ nếu tồn tại
if [ -f "$CONFIG_FILE" ]; then
  mv "$CONFIG_FILE" "$BACKUP_FILE"
fi

# Viết cấu hình mới
cat > "$CONFIG_FILE" <<EOF
{
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/ray" }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "settings": {} }
  ]
}
EOF

# 6. Kiểm tra và cấu hình UFW, đảm bảo SSH và V2Ray mở port
ufw allow $SSH_PORT/tcp
ufw allow $PORT/tcp
ufw --force enable
ufw reload

# 7. Khởi động lại dịch vụ V2Ray
systemctl daemon-reload
systemctl enable v2ray
systemctl restart v2ray

# 8. Xuất thông tin kết nối ra file
INFO_FILE="/root/v2ray_info_$(date +%F_%H%M%S).txt"
cat > "$INFO_FILE" <<EOL
V2Ray connection info:

Address: $(curl -s ifconfig.me || echo "<server-ip>")
Port: $PORT
UUID: $UUID
AlterId: 0
Network: ws
WS Path: /ray
Security: tls (nếu cần cấu hình thêm TLS)

Config backup: $BACKUP_FILE
Info file: $INFO_FILE
EOL

chmod 600 "$INFO_FILE"

echo "Installation successful. Connection details saved to $INFO_FILE"

echo "============"
cat /root/v2ray_info_2025-07-27_105252.txt
echo "============"
