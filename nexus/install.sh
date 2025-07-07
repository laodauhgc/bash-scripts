#!/bin/bash
set -e

# Version: 1.2.5
# Biến cấu hình
CONTAINER_NAME="nexus-node"
IMAGE_NAME="nexus-node:latest"
LOG_FILE="/root/nexus_logs/nexus.log"
SWAP_FILE="/swapfile"
WALLET_ADDRESS="$1"

# Kiểm tra wallet address
if [ -z "$WALLET_ADDRESS" ]; then
    echo "Lỗi: Vui lòng cung cấp wallet address. Cách dùng: $0 <wallet_address>"
    exit 1
fi

# Xác định số luồng dựa trên số vCPU
max_threads=$(nproc)

# Hàm tạo swap tự động
create_swap() {
    # Lấy tổng RAM hệ thống (MB)
    total_ram=$(free -m | awk '/^Mem:/{print $2}')
    if [ -z "$total_ram" ] || [ "$total_ram" -le 0 ]; then
        echo "Lỗi: Không thể xác định RAM hệ thống. Bỏ qua tạo swap."
        return 1
    fi

    if swapon --show | grep -q "$SWAP_FILE"; then
        current_swap=$(free -m | awk '/^Swap:/{print $2}')
        if [ -n "$current_swap" ] && [ "$current_swap" -ge "$total_ram" ]; then
            echo "Swap đã tồn tại ($current_swap MB), bỏ qua tạo swap."
            return
        fi
        swapoff "$SWAP_FILE" 2>/dev/null || true
    fi

    min_swap=$total_ram
    max_swap=$((total_ram * 2))
    available_disk=$(df -BM --output=avail "$(dirname "$SWAP_FILE")" | tail -n 1 | grep -o '[0-9]\+')
    if [ -z "$available_disk" ] || [ "$available_disk" -lt "$min_swap" ]; then
        echo "Không đủ dung lượng ổ cứng ($available_disk MB) để tạo swap tối thiểu ($min_swap MB). Bỏ qua."
        return
    fi

    swap_size=$min_swap
    if [ "$available_disk" -ge "$max_swap" ]; then
        swap_size=$max_swap
    fi

    if [ "$swap_size" -le 0 ]; then
        echo "Lỗi: Kích thước swap không hợp lệ ($swap_size MB). Bỏ qua tạo swap."
        return 1
    fi

    echo "Tạo swap $swap_size MB..."
    if ! fallocate -l "${swap_size}M" "$SWAP_FILE" 2>/dev/null; then
        dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$swap_size"
    fi
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE"
    swapon "$SWAP_FILE"
    if ! grep -q "$SWAP_FILE" /etc/fstab; then
        echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    fi
    echo "Swap đã được tạo và kích hoạt ($swap_size MB)."
}

# Kiểm tra và cài đặt Docker
if ! command -v docker >/dev/null 2>&1; then
    echo "Cài đặt Docker..."
    apt update
    if ! apt install -y docker.io; then
        echo "Lỗi: Không thể cài đặt Docker"
        exit 1
    fi
    systemctl enable docker
    systemctl start docker
    if ! systemctl is-active --quiet docker; then
        echo "Lỗi: Docker daemon không chạy"
        exit 1
    fi
fi

# Kiểm tra quyền chạy Docker
if ! docker ps >/dev/null 2>&1; then
    echo "Lỗi: Không có quyền chạy Docker. Kiểm tra cài đặt hoặc thêm user vào nhóm docker."
    exit 1
fi

# Xây dựng Docker image
build_image() {
    echo "Bắt đầu xây dựng image $IMAGE_NAME..."
    workdir=$(mktemp -d)
    cd "$workdir"

    cat > Dockerfile <<EOF
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y curl screen bash && rm -rf /var/lib/apt/lists/*
RUN curl -sSL https://cli.nexus.xyz/ | NONINTERACTIVE=1 sh && ln -sf /root/.nexus/bin/nexus-network /usr/local/bin/nexus-network
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
EOF

    cat > entrypoint.sh <<EOF
#!/bin/bash
set -e
# Kiểm tra wallet address
if [ -z "\$WALLET_ADDRESS" ]; then
    echo "Lỗi: Thiếu wallet address"
    exit 1
fi
# Đăng ký ví
echo "Đăng ký ví với wallet: \$WALLET_ADDRESS"
nexus-network register-user --wallet-address "\$WALLET_ADDRESS" &>> /root/nexus.log
if [ \$? -ne 0 ]; then
    echo "Lỗi: Không thể đăng ký ví. Xem log:"
    cat /root/nexus.log
    echo "Thông tin hỗ trợ:"
    nexus-network --help &>> /root/nexus.log
    cat /root/nexus.log
    exit 1
fi
# Đăng ký node
echo "Đăng ký node..."
nexus-network register-node &>> /root/nexus.log
if [ \$? -ne 0 ]; then
    echo "Lỗi: Không thể đăng ký node. Xem log:"
    cat /root/nexus.log
    echo "Thông tin hỗ trợ:"
    nexus-network register-node --help &>> /root/nexus.log
    cat /root/nexus.log
    exit 1
fi
# Chạy node
screen -dmS nexus bash -c "nexus-network start --max-threads $max_threads &>> /root/nexus.log"
sleep 3
if screen -list | grep -q "nexus"; then
    echo "Node đã khởi động với wallet_address=\$WALLET_ADDRESS, max_threads=$max_threads. Log: /root/nexus.log"
else
    echo "Khởi động thất bại. Xem log:"
    cat /root/nexus.log
    exit 1
fi
tail -f /root/nexus.log
EOF

    if ! docker build -t "$IMAGE_NAME" .; then
        echo "Lỗi: Không thể xây dựng image $IMAGE_NAME"
        cd -
        rm -rf "$workdir"
        exit 1
    fi
    cd -
    rm -rf "$workdir"
    echo "Xây dựng image $IMAGE_NAME thành công."
}

# Chạy container
run_container() {
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"

    docker run -d --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        -v "$LOG_FILE":/root/nexus.log \
        -e WALLET_ADDRESS="$WALLET_ADDRESS" \
        "$IMAGE_NAME"
    echo "Đã chạy node với wallet_address=$WALLET_ADDRESS, max_threads=$max_threads"
    echo "Log: $LOG_FILE"
    echo "Xem log theo thời gian thực: docker logs -f $CONTAINER_NAME"
}

# Tạo swap trước khi chạy node
create_swap

# Xây dựng Docker image
echo "Xây dựng Docker image..."
build_image

# Chạy container
run_container
