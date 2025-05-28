#!/bin/bash

# Đường dẫn backup ví
BACKUP_DIR="/root/nockchain_backup"
KEYS_FILE="$BACKUP_DIR/keys.export"
WALLET_OUTPUT="$BACKUP_DIR/wallet_output.txt"

# Danh sách peer
PEER_NODES="/ip4/95.216.102.60/udp/3006/quic-v1,/ip4/65.108.123.225/udp/3006/quic-v1,/ip4/65.109.156.108/udp/3006/quic-v1,/ip4/65.21.67.175/udp/3006/quic-v1,/ip4/65.109.156.172/udp/3006/quic-v1,/ip4/34.174.22.166/udp/3006/quic-v1,/ip4/34.95.155.151/udp/30000/quic-v1,/ip4/34.18.98.38/udp/30000/quic-v1"

# Hàm kiểm tra lỗi
check_error() {
    if [ $? -ne 0 ]; then
        echo "Lỗi: $1"
        exit 1
    fi
}

# Hàm xóa worker
remove_workers() {
    echo "Xóa tất cả worker Nockchain..."

    # Dừng các tiến trình nockchain
    echo "Dừng các tiến trình nockchain..."
    pkill -f nockchain 2>/dev/null || echo "Không có tiến trình nockchain đang chạy"

    # Xóa thư mục worker, trừ thư mục backup
    for dir in /root/nockchain-worker-*; do
        if [ -d "$dir" ]; then
            echo "Xóa thư mục $dir..."
            rm -rf "$dir"
            check_error "Xóa thư mục $dir thất bại"
        fi
    done

    # Xóa cổng P2P trong ufw, giữ cổng 22 và các cổng khác
    if command -v ufw >/dev/null 2>&1; then
        echo "Xóa các cổng P2P trong ufw..."
        for port in $(ufw status | grep -o '303[0-9]\{2\}'); do
            ufw delete allow $port/udp 2>/dev/null
            ufw delete allow $port/tcp 2>/dev/null
            echo "Đã xóa cổng $port (UDP/TCP)"
        done
        ufw status | grep -q "22/tcp" || {
            ufw allow 22/tcp
            check_error "Mở lại cổng SSH thất bại"
        }
    fi

    echo "Đã xóa tất cả worker và cấu hình tường lửa (giữ cổng 22, 3005:3006, 30000 và thư mục $BACKUP_DIR)"
    exit 0
}

# Hàm kiểm tra thư mục nockchain-worker-01
check_worker_dir() {
    local dir="/root/nockchain-worker-01"
    local required_files=("Cargo.lock" "Cargo.toml" "LICENSE" "Makefile" "README.md" "rust-toolchain.toml")
    local required_dirs=("assets" "crates" "hoon" "scripts" "target")

    if [ ! -d "$dir" ]; then
        return 1
    fi

    for file in "${required_files[@]}"; do
        if [ ! -f "$dir/$file" ]; then
            return 1
        fi
    done

    for subdir in "${required_dirs[@]}"; do
        if [ ! -d "$dir/$subdir" ]; then
            return 1
        fi
    done

    return 0
}

# Kiểm tra tùy chọn
NO_BUILD=0
while getopts "c:rn" opt; do
    case $opt in
        c) NUM_WORKERS="$OPTARG" ;;
        r) remove_workers ;;
        n) NO_BUILD=1 ;;
        *) echo "Tùy chọn không hợp lệ. Dùng: $0 [-c <số_worker>] [-r] [-n]" && exit 1 ;;
    esac
done

# Lấy số CPU hoặc số worker từ tùy chọn -c
NUM_WORKERS=${NUM_WORKERS:-$(nproc)}
# Đảm bảo tối thiểu 1 worker
[ "$NUM_WORKERS" -lt 1 ] && NUM_WORKERS=1

# Cài đặt và cấu hình ufw
echo "Kiểm tra và cấu hình tường lửa (ufw)..."
if ! command -v ufw >/dev/null 2>&1; then
    echo "ufw chưa được cài đặt, đang cài..."
    apt update && apt install -y ufw
    check_error "Cài đặt ufw thất bại"
fi

# Kích hoạt ufw nếu chưa bật
ufw status | grep -q "Status: active" || {
    echo "Kích hoạt ufw..."
    ufw --force enable
    check_error "Kích hoạt ufw thất bại"
}

# Kiểm tra và mở cổng cần thiết
echo "Kiểm tra và mở các cổng cần thiết..."
# Mở cổng 22/tcp nếu chưa có
ufw status | grep -q "22/tcp.*ALLOW" || {
    ufw allow 22/tcp
    check_error "Mở cổng SSH thất bại"
}
# Mở cổng 3005:3006/tcp nếu chưa có
ufw status | grep -q "3005:3006/tcp.*ALLOW" || {
    ufw allow 3005:3006/tcp
    check_error "Mở cổng 3005:3006/tcp thất bại"
}
# Mở cổng 3005:3006/udp nếu chưa có
ufw status | grep -q "3005:3006/udp.*ALLOW" || {
    ufw allow 3005:3006/udp
    check_error "Mở cổng 3005:3006/udp thất bại"
}
# Mở cổng 30000/udp nếu chưa có
ufw status | grep -q "30000/udp.*ALLOW" || {
    ufw allow 30000/udp
    check_error "Mở cổng 30000/udp thất bại"
}
# Mở cổng P2P cho các worker
for ((i=1; i<=NUM_WORKERS; i++)); do
    PORT=$((30300 + i))
    ufw status | grep -q "$PORT/udp.*ALLOW" || {
        ufw allow $PORT/udp
        check_error "Mở cổng $PORT/udp thất bại"
    }
    ufw status | grep -q "$PORT/tcp.*ALLOW" || {
        ufw allow $PORT/tcp
        check_error "Mở cổng $PORT/tcp thất bại"
    }
done
echo "Đã mở cổng 22 (SSH), 3005:3006 (TCP/UDP), 30000 (UDP) và cổng P2P (30301-$((30300 + NUM_WORKERS))) cho UDP và TCP"

# Tạo thư mục backup nếu chưa có
mkdir -p "$BACKUP_DIR"
check_error "Tạo thư mục backup thất bại"

# Cài đặt môi trường
echo "Cài đặt môi trường..."
if ! command -v rustc >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    check_error "Cài đặt Rust thất bại"
fi
source $HOME/.cargo/env

apt update && apt install -y clang llvm-dev libclang-dev
check_error "Cài đặt phụ thuộc thất bại"

# Tải và build trong nockchain-worker-01
echo "Tải và build Nockchain..."
if [ ! -d "/root/nockchain-worker-01" ]; then
    git clone https://github.com/zorp-corp/nockchain.git /root/nockchain-worker-01
    check_error "Tải repository thất bại"
fi
cd /root/nockchain-worker-01

# Kiểm tra tùy chọn -n
if [ "$NO_BUILD" -eq 1 ]; then
    if check_worker_dir; then
        echo "Thư mục /root/nockchain-worker-01 hợp lệ, bỏ qua bước build."
    else
        echo "Thư mục /root/nockchain-worker-01 không hợp lệ hoặc thiếu tệp/thư mục cần thiết."
        read -p "Bạn có muốn bắt đầu quá trình build Nockchain không? (y/N): " response
        if [[ "$response" =~ ^[yY]$ ]]; then
            NO_BUILD=0
        else
            echo "Lỗi: Mã nguồn Nockchain không hợp lệ, không thể tiếp tục mà không build."
            exit 1
        fi
    fi
fi

# Tạo .env trước khi chạy make
cp .env_example .env
check_error "Tạo .env cho nockchain-worker-01 thất bại"

# Build Nockchain nếu không dùng -n hoặc thư mục không hợp lệ
if [ "$NO_BUILD" -eq 0 ] || ! command -v nockchain >/dev/null 2>&1; then
    make install-hoonc 2>&1 | tee -a /tmp/nockchain_build.log
    check_error "Cài hoonc thất bại. Xem log tại /tmp/nockchain_build.log"
    make build 2>&1 | tee -a /tmp/nockchain_build.log
    check_error "Build Nockchain thất bại. Xem log tại /tmp/nockchain_build.log"
    make install-nockchain-wallet 2>&1 | tee -a /tmp/nockchain_build.log
    check_error "Cài ví thất bại. Xem log tại /tmp/nockchain_build.log"
    make install-nockchain 2>&1 | tee -a /tmp/nockchain_build.log
    check_error "Cài Nockchain thất bại. Xem log tại /tmp/nockchain_build.log"
fi
export PATH="$HOME/.cargo/bin:$PATH"

# Kiểm tra nockchain-wallet có sẵn
if ! command -v nockchain-wallet >/dev/null 2>&1; then
    echo "Lỗi: nockchain-wallet không được cài đặt. Kiểm tra log build tại /tmp/nockchain_build.log"
    exit 1
fi

# Kiểm tra và nhập ví
echo "Kiểm tra ví backup..."
if [ -f "$KEYS_FILE" ]; then
    echo "Tìm thấy ví backup, đang nhập..."
    nockchain-wallet import-keys --input "$KEYS_FILE" 2>&1 | tee -a /tmp/nockchain_wallet.log
    check_error "Nhập ví thất bại. Xem log tại /tmp/nockchain_wallet.log"
    if [ -f "$WALLET_OUTPUT" ]; then
        PUBKEY=$(awk '/New Public Key/{getline; print $1}' "$WALLET_OUTPUT" | tr -d '"' | tr -d '\0')
        if [ -z "$PUBKEY" ]; then
            echo "Lỗi: Không tìm thấy khóa công khai trong $WALLET_OUTPUT"
            cat "$WALLET_OUTPUT"
            exit 1
        fi
    else
        echo "Lỗi: Tệp $WALLET_OUTPUT không tồn tại"
        exit 1
    fi
else
    echo "Không tìm thấy ví backup, tạo ví mới..."
    KEYGEN_OUTPUT=$(nockchain-wallet keygen 2>&1 | tr -d '\0')
    check_error "Tạo ví thất bại. Xem log tại /tmp/nockchain_wallet.log"
    echo "$KEYGEN_OUTPUT" > "$WALLET_OUTPUT"
    nockchain-wallet export-keys 2>&1 | tee -a /tmp/nockchain_wallet.log
    check_error "Backup ví thất bại. Xem log tại /tmp/nockchain_wallet.log"
    mv keys.export "$KEYS_FILE"
    check_error "Di chuyển keys.export thất bại"
    PUBKEY=$(echo "$KEYGEN_OUTPUT" | awk '/New Public Key/{getline; print $1}' | tr -d '"')
    if [ -z "$PUBKEY" ]; then
        echo "Lỗi: Không tìm thấy khóa công khai trong đầu ra của keygen"
        cat "$WALLET_OUTPUT"
        exit 1
    fi
fi

# Kiểm tra tính hợp lệ của PUBKEY
if ! echo "$PUBKEY" | grep -qE '^[0-9a-zA-Z]{100,}$'; then
    echo "Lỗi: Khóa công khai không hợp lệ: $PUBKEY"
    exit 1
fi

# Cập nhật .env với MINING_PUBKEY
echo "MINING_PUBKEY=$PUBKEY" >> .env
check_error "Cập nhật MINING_PUBKEY cho nockchain-worker-01 thất bại"

# Tạo và cấu hình worker
echo "Cấu hình $NUM_WORKERS worker..."
cd /root
for ((i=1; i<=NUM_WORKERS; i++)); do
    WORKER_DIR="/root/nockchain-worker-$(printf "%02d" $i)"
    if [ "$i" -ne 1 ]; then
        # Xóa thư mục worker cũ nếu tồn tại
        rm -rf "$WORKER_DIR"
        check_error "Xóa thư mục worker cũ $WORKER_DIR thất bại"
        # Sao chép toàn bộ nội dung từ nockchain-worker-01
        rsync -a --exclude 'worker-*.log' /root/nockchain-worker-01/ "$WORKER_DIR/"
        check_error "Sao chép thư mục cho $WORKER_DIR thất bại"
    fi
    mkdir -p "$WORKER_DIR"
    cat > "$WORKER_DIR/.env" << EOF
RUST_LOG=info,nockchain=info,nockchain_libp2p_io=info,libp2p=info,libp2p_quic=info
MINIMAL_LOG_FORMAT=true
MINING_PUBKEY=$PUBKEY
PEER_PORT=$((30300 + i))
PEER_NODES=$PEER_NODES
EOF
    check_error "Tạo .env cho $WORKER_DIR thất bại"
    # Xóa .data.nockchain nếu tồn tại
    rm -rf "$WORKER_DIR/.data.nockchain"
    check_error "Xóa .data.nockchain cho $WORKER_DIR thất bại"
done

# Chạy worker ngầm với nohup
echo "Khởi động $NUM_WORKERS worker..."
for ((i=1; i<=NUM_WORKERS; i++)); do
    WORKER_DIR="/root/nockchain-worker-$(printf "%02d" $i)"
    cd "$WORKER_DIR"
    # Kiểm tra MINING_PUBKEY
    if ! grep -q "MINING_PUBKEY" .env; then
        echo "Lỗi: MINING_PUBKEY không được thiết lập trong $WORKER_DIR/.env"
        cat .env
        exit 1
    fi
    nohup bash "$WORKER_DIR/scripts/run_nockchain_miner.sh" > "$WORKER_DIR/worker-$(printf "%02d" $i).log" 2>&1 &
    check_error "Khởi động $WORKER_DIR thất bại"
    sleep 1  # Đợi log được ghi
    # Kiểm tra log worker
    if grep -qi "error" "$WORKER_DIR/worker-$(printf "%02d" $i).log"; then
        echo "Lỗi: Worker $WORKER_DIR gặp vấn đề. Xem log:"
        cat "$WORKER_DIR/worker-$(printf "%02d" $i).log"
        exit 1
    fi
    echo "$WORKER_DIR đang chạy ngầm, log tại $WORKER_DIR/worker-$(printf "%02d" $i).log"
    cd /root
done

echo "Hoàn tất! Kiểm tra log tại /root/nockchain-worker-XX/worker-XX.log"
echo "Dùng 'tail -f /root/nockchain-worker-XX/worker-XX.log' để xem log"
echo "Dùng 'ps aux | grep nockchain' để kiểm tra tiến trình"
echo "Dùng '$0 -rm' để xóa tất cả worker (giữ thư mục $BACKUP_DIR)"
echo "Tường lửa đã được cấu hình với cổng 22 (SSH), 3005:3006 (TCP/UDP), 30000 (UDP) và 30301-$((30300 + NUM_WORKERS)) (UDP/TCP)"
echo "Nếu dùng NAT, cấu hình chuyển tiếp cổng 30301-$((30300 + NUM_WORKERS)) trên router"
