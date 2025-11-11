#!/bin/bash

# Nockpool Miner Launcher Installer (Full Auto - Ubuntu/Debian)
# One-liner: curl -sSL https://raw.githubusercontent.com/laodauhgc/bash-scripts/refs/heads/main/nockchain/nockpool.sh | sudo bash -s -- YOUR_TOKEN_HERE
# Tự động cài deps + Rust + miner-launcher + systemd service (tên: nockpool.service)

set -e

if [ $# -ne 1 ]; then
    echo "Sử dụng: sudo $0 <token>"
    echo "One-liner: curl -sSL https://raw.githubusercontent.com/laodauhgc/bash-scripts/refs/heads/main/nockchain/nockpool.sh | sudo bash -s -- YOUR_TOKEN_HERE"
    exit 1
fi

TOKEN="$1"
SCRIPT_DIR="/opt/nockpool"
MINER_BINARY="$SCRIPT_DIR/miner-launcher"
SERVICE_FILE="/etc/systemd/system/nockpool.service"

echo "=== NOCKPOOL AUTO INSTALLER ==="
echo "Token: ${TOKEN:0:10}..."

# Tạo thư mục nếu chưa có
sudo mkdir -p "$SCRIPT_DIR"
sudo chown $(whoami):$(whoami) "$SCRIPT_DIR"
cd "$SCRIPT_DIR"

# 1. Cài phụ thuộc hệ thống
echo "Cài phụ thuộc hệ thống (clang, protobuf, make...)"
sudo apt update -y
sudo apt install -y clang llvm-dev libclang-dev make protobuf-compiler curl build-essential pkg-config libssl-dev

# 2. Cài Rust (non-interactive)
echo "Cài Rust nếu chưa có..."
if ! command -v rustc &> /dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
    source "$HOME/.cargo/env"
    echo "Rust installed: $(rustc --version)"
else
    source "$HOME/.cargo/env" 2>/dev/null || true
    echo "Rust đã có: $(rustc --version)"
fi

# 3. Tải miner-launcher
echo "Tải miner-launcher..."
if [ ! -f "$MINER_BINARY" ]; then
    curl -L -o "$MINER_BINARY" https://github.com/SWPSCO/nockpool-miner-launcher/releases/latest/download/miner-launcher_linux_x64
    chmod +x "$MINER_BINARY"
else
    echo "miner-launcher đã tồn tại, bỏ qua tải."
fi

# 4. Tạo/ghi đè service systemd
echo "Tạo service nockpool.service..."
sudo tee "$SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=Nockpool Miner Launcher
After=network.target

[Service]
Type=simple
User=$(whoami)
WorkingDirectory=$SCRIPT_DIR
Environment="PATH=$PATH:$HOME/.cargo/bin"
ExecStart=$MINER_BINARY --account-token $TOKEN
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# 5. Khởi động service
echo "Khởi động service..."
sudo systemctl daemon-reload
sudo systemctl enable nockpool.service
sudo systemctl restart nockpool.service

echo "=== HOÀN TẤT! ==="
echo "Service đang chạy: sudo systemctl status nockpool.service"
echo "Xem log realtime: sudo journalctl -u nockpool.service -f"
echo "Dừng: sudo systemctl stop nockpool.service"
echo "Gỡ cài đặt: sudo systemctl disable --now nockpool.service && sudo rm -rf $SCRIPT_DIR $SERVICE_FILE && sudo systemctl daemon-reload"
echo "Miner đặt tại: $SCRIPT_DIR"
