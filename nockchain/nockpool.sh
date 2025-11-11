#!/bin/bash

# Script để thiết lập và chạy miner-launcher ngầm qua systemd
# Sử dụng: sudo ./setup-miner-launcher.sh <token>
# Lưu ý: Chạy script này với sudo vì cần tạo service systemd.

set -e  # Thoát ngay nếu có lỗi

if [ $# -ne 1 ]; then
    echo "Sử dụng: sudo $0 <token>"
    echo "Ví dụ: sudo $0 YOUR_ACCOUNT_TOKEN_HERE"
    exit 1
fi

TOKEN="$1"
SCRIPT_DIR="$(pwd)"
MINER_BINARY="$SCRIPT_DIR/miner-launcher"
SERVICE_FILE="/etc/systemd/system/nockpool.service"

echo "Bắt đầu thiết lập miner-launcher với token: ${TOKEN:0:10}..."  # Chỉ hiển thị 10 ký tự đầu để bảo mật

# Tải miner-launcher nếu chưa tồn tại
if [ ! -f "$MINER_BINARY" ]; then
    echo "Đang tải miner-launcher..."
    curl -L -o "$MINER_BINARY" https://github.com/SWPSCO/nockpool-miner-launcher/releases/latest/download/miner-launcher_linux_x64
    chmod +x "$MINER_BINARY"
    echo "Tải và cấp quyền thực thi hoàn tất."
else
    echo "miner-launcher đã tồn tại, bỏ qua tải."
fi

# Tạo file service systemd
echo "Tạo file service systemd..."
cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Nockpool Miner Launcher
After=network.target

[Service]
Type=simple
User=$(whoami)  # Chạy dưới user hiện tại
WorkingDirectory=$SCRIPT_DIR
ExecStart=$MINER_BINARY --account-token $TOKEN
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd, enable và start service
echo "Cấu hình và khởi động service..."
systemctl daemon-reload
systemctl enable nockpool.service
systemctl start nockpool.service

echo "Hoàn tất! Miner-launcher đang chạy ngầm qua systemd với tên service 'nockpool'."
echo "Kiểm tra trạng thái: sudo systemctl status nockpool.service"
echo "Xem log: sudo journalctl -u nockpool.service -f"
echo "Dừng service: sudo systemctl stop nockpool.service"
echo "Xóa service (nếu cần): sudo rm $SERVICE_FILE && sudo systemctl daemon-reload"
