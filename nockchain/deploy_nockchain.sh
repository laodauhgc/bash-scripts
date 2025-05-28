#!/bin/bash

# Configuration
IMAGE_NAME="laodauhgc/nockchain"
IMAGE_TAG="latest"
NOCKCHAIN_DIR="/root/nockchain"
PEER_NODES="/ip4/95.216.102.60/udp/3006/quic-v1,/ip4/65.108.123.225/udp/3006/quic-v1,/ip4/65.109.156.108/udp/3006/quic-v1,/ip4/65.21.67.175/udp/3006/quic-v1,/ip4/65.109.156.172/udp/3006/quic-v1,/ip4/34.174.22.166/udp/3006/quic-v1,/ip4/34.95.155.151/udp/30000/quic-v1,/ip4/34.18.98.38/udp/30000/quic-v1"

# Hàm kiểm tra lỗi
check_error() {
    if [ $? -ne 0 ]; then
        echo "Lỗi: $1"
        exit 1
    fi
}

# Hàm dừng và xóa container
remove_workers() {
    echo "Dừng và xóa tất cả container Nockchain..."
    for container in $(docker ps -a -q -f "name=nockchain-worker-"); do
        echo "Dừng container $container..."
        docker stop "$container" >/dev/null 2>&1
        docker rm "$container" >/dev/null 2>&1
    done
    echo "Xóa thư mục worker..."
    rm -rf "$NOCKCHAIN_DIR"/worker-* 2>/dev/null
    echo "Đã xóa tất cả container và thư mục worker"
    exit 0
}

# Hàm triển khai container worker
deploy_workers() {
    local num_workers=$1
    local mining_key=$2

    # Kiểm tra MINING_PUBKEY
    if [ -z "$mining_key" ]; then
        echo "Lỗi: Tham số -k <mining_key> là bắt buộc"
        exit 1
    fi

    echo "Triển khai $num_workers container worker..."
    for ((i=1; i<=num_workers; i++)); do
        WORKER_DIR="$NOCKCHAIN_DIR/worker-$(printf "%02d" $i)"
        WORKER_NAME="nockchain-worker-$(printf "%02d" $i)"
        PEER_PORT=$((30300 + i))

        # Tạo thư mục worker và file .env
        mkdir -p "$WORKER_DIR"
        cat > "$WORKER_DIR/.env" << EOF
RUST_LOG=info,nockchain=info,nockchain_libp2p_io=info,libp2p=info,libp2p_quic=info
MINIMAL_LOG_FORMAT=true
MINING_PUBKEY=$mining_key
PEER_PORT=$PEER_PORT
PEER_NODES=$PEER_NODES
EOF
        check_error "Tạo .env cho $WORKER_DIR thất bại"

        # Dừng container cũ nếu tồn tại
        docker stop "$WORKER_NAME" >/dev/null 2>&1
        docker rm "$WORKER_NAME" >/dev/null 2>&1

        # Chạy container worker
        echo "Khởi động container $WORKER_NAME..."
        docker run -d \
            --name "$WORKER_NAME" \
            --network host \
            -v "$WORKER_DIR:/root/nockchain/worker-$(printf "%02d" $i)" \
            -e WORKER_ID=$i \
            -e MINING_PUBKEY="$mining_key" \
            "$IMAGE_NAME:$IMAGE_TAG"
        check_error "Khởi động container $WORKER_NAME thất bại"
    done
}

# Xử lý tùy chọn
NUM_WORKERS=$(nproc)
MINING_KEY=""
REMOVE_WORKERS=0
while getopts "c:k:r" opt; do
    case $opt in
        c) NUM_WORKERS="$OPTARG" ;;
        k) MINING_KEY="$OPTARG" ;;
        r) REMOVE_WORKERS=1 ;;
        *) echo "Tùy chọn không hợp lệ. Dùng: $0 [-c <số_container>] [-k <mining_key>] [-r]" && exit 1 ;;
    esac
done

# Kiểm tra Docker
if ! command -v docker >/dev/null 2>&1; then
    echo "Lỗi: Docker chưa được cài đặt. Vui lòng cài Docker trước."
    exit 1
fi

# Xóa worker nếu yêu cầu
if [ "$REMOVE_WORKERS" -eq 1 ]; then
    remove_workers
fi

# Kéo image từ Docker Hub
echo "Kéo image $IMAGE_NAME:$IMAGE_TAG từ Docker Hub..."
docker pull "$IMAGE_NAME:$IMAGE_TAG"
check_error "Kéo image thất bại"

# Triển khai worker
deploy_workers "$NUM_WORKERS" "$MINING_KEY"

echo "Hoàn tất! Kiểm tra log container bằng: docker logs nockchain-worker-XX"
echo "Dùng 'docker ps' để xem container đang chạy"
echo "Dùng '$0 -r' để dừng và xóa tất cả container worker"
