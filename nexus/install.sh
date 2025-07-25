#!/bin/bash
set -e

# Version: 1.3.2  # Cập nhật version sau khi sửa CLI tải binary mới nhất và hỗ trợ ARM

# Biến cấu hình
CONTAINER_NAME="nexus-node"
IMAGE_NAME="nexus-node:latest"
LOG_FILE="/root/nexus_logs/nexus.log"
CREDENTIALS_DIR="/root/nexus_credentials"  # Thư mục host để mount ~/.nexus
NODE_ID_FILE="/root/nexus_node_id.txt"      # File lưu node ID
SWAP_FILE="/swapfile"
WALLET_ADDRESS="$1"
NO_SWAP=0
LANGUAGE="vi"
SETUP_CRON=0  # Mặc định không tự động thiết lập cron

# Parse arguments
shift
while [ $# -gt 0 ]; do
    case "$1" in
        --no-swap) NO_SWAP=1; shift ;;
        --en) LANGUAGE="en"; shift ;;
        --ru) LANGUAGE="ru"; shift ;;
        --cn) LANGUAGE="cn"; shift ;;
        --setup-cron) SETUP_CRON=1; shift ;;
        *) print_warning "$(printf "$WARN_INVALID_FLAG" "$1")"; shift ;;
    esac
done

# Định nghĩa màu sắc và icon
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Hàm in output với màu và icon
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_error()   { echo -e "${RED}❌ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️ $1${NC}"; }
print_info()    { echo -e "${BLUE}ℹ️ $1${NC}"; }
print_progress() { echo -e "${CYAN}⏳ $1${NC}"; }
print_node()    { echo -e "${GREEN}🚀 $1${NC}"; }
print_log()     { echo -e "${CYAN}📜 $1${NC}"; }
print_swap()    { echo -e "${BLUE}💾 $1${NC}"; }
print_docker()  { echo -e "${BLUE}🐳 $1${NC}"; }

# Định nghĩa tất cả thông báo dựa trên ngôn ngữ
case $LANGUAGE in
    vi)
        BANNER="===== Cài Đặt Node Nexus v1.3.2 (Hỗ trợ ARM) ====="
        ERR_NO_WALLET="Lỗi: Vui lòng cung cấp wallet address. Cách dùng: \$0 <wallet_address> [--no-swap] [--en|--ru|--cn] [--setup-cron]"
        WARN_INVALID_FLAG="Cảnh báo: Flag không hợp lệ: %s. Bỏ qua."
        SKIP_SWAP_FLAG="Bỏ qua tạo swap theo yêu cầu (--no-swap)."
        INSTALLING_DOCKER="Cài đặt Docker..."
        ERR_INSTALL_DOCKER="Lỗi: Không thể cài đặt Docker."
        ERR_DOCKER_NOT_RUNNING="Lỗi: Docker daemon không chạy."
        ERR_DOCKER_PERMISSION="Lỗi: Không có quyền chạy Docker. Kiểm tra cài đặt hoặc thêm user vào nhóm docker."
        BUILDING_IMAGE="Bắt đầu xây dựng image %s…"
        ERR_BUILD_IMAGE="Lỗi: Không thể xây dựng image %s."
        BUILD_IMAGE_SUCCESS="Xây dựng image %s thành công."
        NODE_STARTED="Đã chạy node với wallet_address=%s."
        LOG_FILE_MSG="Log: %s"
        VIEW_LOG="Xem log theo thời gian thực: docker logs -f %s"
        NOT_LINUX="Hệ thống không phải Linux, bỏ qua tạo swap."
        WARN_NO_RAM="Cảnh báo: Không thể xác định RAM hệ thống. Bỏ qua tạo swap và tiếp tục chạy node."
        RAM_DETECTED="Tổng RAM phát hiện: %s MB. Tiếp tục kiểm tra swap..."
        SWAP_EXISTS="Swap đã tồn tại (%s MB), bỏ qua tạo swap."
        INSUFFICIENT_DISK="Không đủ dung lượng ổ cứng (%s MB) để tạo swap tối thiểu (%s MB). Bỏ qua."
        WARN_INVALID_SWAP_SIZE="Cảnh báo: Kích thước swap không hợp lệ (%s MB). Bỏ qua tạo swap."
        CREATING_SWAP="Tạo swap %s MB..."
        WARN_CREATE_SWAP_FAIL="Cảnh báo: Không thể tạo file swap. Bỏ qua."
        SWAP_CREATED="Swap đã được tạo và kích hoạt (%s MB)."
        ERR_MISSING_WALLET="Lỗi: Thiếu wallet address hoặc node ID."
        REGISTERING_WALLET="Đăng ký ví với wallet: %s"
        ERR_REGISTER_WALLET="Lỗi: Không thể đăng ký ví. Xem log:"
        SUPPORT_INFO="Thông tin hỗ trợ:"
        REGISTERING_NODE="Đăng ký node..."
        ERR_REGISTER_NODE="Lỗi: Không thể đăng ký node. Xem log:"
        NODE_STARTED_ENTRY="Node đã khởi động với wallet_address=%s. Log: /root/nexus.log"
        STARTUP_FAILED="Khởi động thất bại. Xem log:"
        NODE_ID_SAVED="Node ID đã được lưu: %s"
        USING_EXISTING_NODE_ID="Sử dụng node ID hiện có: %s"
        CRON_SETUP="Thiết lập cron job để khởi tạo lại container mỗi giờ."
        CRON_INSTRUCTION="Cron job đã được thêm: @hourly docker rm -f %s; /bin/bash %s %s"
        ARCH_DETECTED="Phát hiện kiến trúc hệ thống: %s. Sử dụng CLI phù hợp."
        ;;
    en)
        BANNER="===== Nexus Node Setup v1.3.2 (ARM Support) ====="
        ERR_NO_WALLET="Error: Please provide wallet address. Usage: \$0 <wallet_address> [--no-swap] [--en|--ru|--cn] [--setup-cron]"
        WARN_INVALID_FLAG="Warning: Invalid flag: %s. Skipping."
        SKIP_SWAP_FLAG="Skipping swap creation as per request (--no-swap)."
        INSTALLING_DOCKER="Installing Docker..."
        ERR_INSTALL_DOCKER="Error: Unable to install Docker."
        ERR_DOCKER_NOT_RUNNING="Error: Docker daemon is not running."
        ERR_DOCKER_PERMISSION="Error: No permission to run Docker. Check installation or add user to docker group."
        BUILDING_IMAGE="Starting to build image %s..."
        ERR_BUILD_IMAGE="Error: Unable to build image %s."
        BUILD_IMAGE_SUCCESS="Built image %s successfully."
        NODE_STARTED="Node started with wallet_address=%s."
        LOG_FILE_MSG="Log: %s"
        VIEW_LOG="View real-time log: docker logs -f %s"
        NOT_LINUX="System is not Linux, skipping swap creation."
        WARN_NO_RAM="Warning: Unable to determine system RAM. Skipping swap creation and continuing to run node."
        RAM_DETECTED="Detected total RAM: %s MB. Continuing to check swap..."
        SWAP_EXISTS="Swap already exists (%s MB), skipping swap creation."
        INSUFFICIENT_DISK="Insufficient disk space (%s MB) to create minimum swap (%s MB). Skipping."
        WARN_INVALID_SWAP_SIZE="Warning: Invalid swap size (%s MB). Skipping swap creation."
        CREATING_SWAP="Creating swap %s MB..."
        WARN_CREATE_SWAP_FAIL="Warning: Unable to create swap file. Skipping."
        SWAP_CREATED="Swap created and activated (%s MB)."
        ERR_MISSING_WALLET="Error: Missing wallet address or node ID."
        REGISTERING_WALLET="Registering wallet with: %s"
        ERR_REGISTER_WALLET="Error: Unable to register wallet. Check log:"
        SUPPORT_INFO="Support information:"
        REGISTERING_NODE="Registering node..."
        ERR_REGISTER_NODE="Error: Unable to register node. Check log:"
        NODE_STARTED_ENTRY="Node started with wallet_address=%s. Log: /root/nexus.log"
        STARTUP_FAILED="Startup failed. Check log:"
        NODE_ID_SAVED="Node ID saved: %s"
        USING_EXISTING_NODE_ID="Using existing node ID: %s"
        CRON_SETUP="Setting up cron job to recreate container every hour."
        CRON_INSTRUCTION="Cron job added: @hourly docker rm -f %s; /bin/bash %s %s"
        ARCH_DETECTED="Detected system architecture: %s. Using appropriate CLI."
        ;;
esac

# Hiển thị banner
print_info "$BANNER"

# Kiểm tra wallet address
if [ -z "$WALLET_ADDRESS" ]; then
    print_error "$ERR_NO_WALLET"
    exit 1
fi

# Tạo swap nếu cần
create_swap() {
    if [ "$(uname -s)" != "Linux" ]; then
        print_warning "$NOT_LINUX"
        return
    fi
    total_ram=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
    if [ "$total_ram" -le 0 ]; then
        print_warning "$WARN_NO_RAM"
        return
    fi
    print_info "$(printf "$RAM_DETECTED" "$total_ram")"
    if swapon --show | grep -q "$SWAP_FILE"; then
        print_info "$(printf "$SWAP_EXISTS" "$(free -m | awk '/^Swap:/ {print $2}' )")"
        return
    fi
    min_swap=$total_ram
    max_swap=$((total_ram*2))
    avail=$(df -BM --output=avail "$(dirname "$SWAP_FILE")" | tail -n1 | tr -dc '[0-9]')
    if [ "$avail" -lt "$min_swap" ]; then
        print_warning "$(printf "$INSUFFICIENT_DISK" "$avail" "$min_swap")"
        return
    fi
    size=$min_swap
    [ "$avail" -ge "$max_swap" ] && size=$max_swap
    print_progress "$(printf "$CREATING_SWAP" "$size")"
    fallocate -l "${size}M" "$SWAP_FILE" 2>/dev/null || dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$size" 2>/dev/null
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE"
    swapon "$SWAP_FILE"
    grep -q "$SWAP_FILE" /etc/fstab || echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    print_swap "$(printf "$SWAP_CREATED" "$size")"
}

if [ "$NO_SWAP" -ne 1 ]; then
    create_swap
else
    print_warning "$SKIP_SWAP_FLAG"
fi

# Cài Docker nếu chưa có
if ! command -v docker &>/dev/null; then
    print_progress "$INSTALLING_DOCKER"
    apt update && apt install -y docker.io
    systemctl enable docker && systemctl start docker
    if ! systemctl is-active --quiet docker; then
        print_error "$ERR_DOCKER_NOT_RUNNING"
        exit 1
    fi
fi
if ! docker ps &>/dev/null; then
    print_error "$ERR_DOCKER_PERMISSION"
    exit 1
fi

# Hàm build image
build_image() {
    print_progress "$(printf "$BUILDING_IMAGE" "$IMAGE_NAME")"
    tmp=$(mktemp -d) && cd "$tmp"
    cat > Dockerfile <<EOF
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y curl screen bash jq && rm -rf /var/lib/apt/lists/*
RUN curl -Ls https://api.github.com/repos/nexus-xyz/nexus-cli/releases/latest | jq -r .tarball_url | xargs curl -Ls | tar xz --strip-components=1 -C /usr/local/bin nexus-network-linux
RUN mkdir -p /root/.nexus
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
EOF
    cat > entrypoint.sh <<'EOF'
#!/bin/bash
set -e
if [ -z "$WALLET_ADDRESS" ] && [ -z "$NODE_ID" ]; then
    echo "❌ Missing wallet address or node ID."
    exit 1
fi
if [ -n "$NODE_ID" ]; then
    echo "⏳ Starting with node ID: $NODE_ID"
    screen -dmS nexus bash -c "nexus-network start --node-id $NODE_ID &>> /root/nexus.log"
else
    echo "⏳ Registering wallet: $WALLET_ADDRESS"
    nexus-network register-user --wallet-address "$WALLET_ADDRESS" &>> /root/nexus.log
    echo "⏳ Registering node"
    nexus-network register-node &>> /root/nexus.log
    screen -dmS nexus bash -c "nexus-network start &>> /root/nexus.log"
fi
sleep 3
if screen -list | grep -q nexus; then
    echo "🚀 Node started. Log: /root/nexus.log"
else
    echo "❌ Startup failed. Check /root/nexus.log"
    exit 1
fi
EOF
    docker build -t "$IMAGE_NAME" .
    cd - && rm -rf "$tmp"
    print_success "$(printf "$BUILD_IMAGE_SUCCESS" "$IMAGE_NAME")"
}

# Hàm run container
run_container() {
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    mkdir -p "$(dirname "$LOG_FILE")" "$CREDENTIALS_DIR"
    touch "$LOG_FILE" && chmod 644 "$LOG_FILE"
    NODE_ID=""
    [ -f "$NODE_ID_FILE" ] && NODE_ID=$(<"$NODE_ID_FILE") && print_info "Using existing Node ID: $NODE_ID"
    docker run -d --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        -v "$LOG_FILE":/root/nexus.log \
        -v "$CREDENTIALS_DIR":/root/.nexus \
        -e WALLET_ADDRESS="$WALLET_ADDRESS" \
        -e NODE_ID="$NODE_ID" \
        "$IMAGE_NAME"
    print_node "Node container started."
    print_log "$(printf "$LOG_FILE_MSG" "$LOG_FILE")"
    print_info "$(printf "$VIEW_LOG" "$CONTAINER_NAME")"
    if [ -z "$NODE_ID" ] && [ -f "$CREDENTIALS_DIR/credentials.json" ]; then
        sleep 10
        nid=$(jq -r .node_id "$CREDENTIALS_DIR/credentials.json" 2>/dev/null)
        [ -n "$nid" ] && echo "$nid" > "$NODE_ID_FILE" && print_success "Node ID saved: $nid"
    fi
}

# Thực thi
build_image
run_container

# Kết thúc
print_success "===== Hoàn Tất Cài Đặt ====="
