#!/bin/bash
set -e

# Version: v1.4.5 | Update 14/08/2025

# =====================
# Biến cấu hình
# =====================
CONTAINER_NAME="nexus-node"
IMAGE_NAME="nexus-node:latest"
LOG_FILE="/root/nexus_logs/nexus.log"
CREDENTIALS_DIR="/root/nexus_credentials"   # host mount -> /root/.nexus
NODE_ID_FILE="/root/nexus_node_id.txt"      # nguồn 'chân lý' ngoài container
SWAP_FILE="/swapfile"

WALLET_ADDRESS="${1-}"
NO_SWAP=0
LANGUAGE="vi"
SETUP_CRON=0

# =====================
# Màu sắc & helpers
# =====================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
print_success(){ echo -e "${GREEN}✅ $1${NC}"; }
print_error(){   echo -e "${RED}❌ $1${NC}"; }
print_warning(){ echo -e "${YELLOW}⚠️ $1${NC}"; }
print_info(){    echo -e "${BLUE}ℹ️ $1${NC}"; }
print_progress(){echo -e "${CYAN}⏳ $1${NC}"; }
print_node(){    echo -e "${GREEN}🚀 $1${NC}"; }
print_log(){     echo -e "${CYAN}📜 $1${NC}"; }

# =====================
# Bắt cờ ngôn ngữ sớm
# =====================
shift || true
for arg in "$@"; do
  case "$arg" in --en) LANGUAGE="en";; --ru) LANGUAGE="ru";; --cn) LANGUAGE="cn";; esac
done

# =====================
# Thông điệp theo ngôn ngữ (rút gọn vi/en)
# =====================
case $LANGUAGE in
  vi)
    BANNER="===== Cài Đặt Node Nexus v1.4.4 (Hỗ trợ ARM) ====="
    ERR_NO_WALLET="Lỗi: Vui lòng cung cấp wallet address. Cách dùng: $0 <wallet_address> [--no-swap] [--en|--ru|--cn] [--setup-cron]"
    WARN_INVALID_FLAG="Cảnh báo: Flag không hợp lệ: %s. Bỏ qua."
    SKIP_SWAP_FLAG="Bỏ qua tạo swap theo yêu cầu (--no-swap)."
    INSTALLING_DOCKER="Cài đặt Docker..."
    ERR_INSTALL_DOCKER="Lỗi: Không thể cài đặt Docker."
    ERR_DOCKER_NOT_RUNNING="Lỗi: Docker daemon không chạy."
    ERR_DOCKER_PERMISSION="Lỗi: Không có quyền chạy Docker."
    BUILDING_IMAGE="Bắt đầu xây dựng image %s…"
    ERR_BUILD_IMAGE="Lỗi: Không thể xây dựng image %s."
    BUILD_IMAGE_SUCCESS="Xây dựng image %s thành công."
    NODE_STARTED="Đã chạy node với wallet_address=%s."
    LOG_FILE_MSG="Log: %s"
    VIEW_LOG="Xem log theo thời gian thực: docker logs -f %s"
    NOT_LINUX="Hệ thống không phải Linux, bỏ qua tạo swap."
    WARN_NO_RAM="Không thể xác định RAM. Bỏ qua tạo swap."
    RAM_DETECTED="Tổng RAM phát hiện: %s MB."
    SWAP_EXISTS="Swap đã tồn tại (%s MB), bỏ qua."
    INSUFFICIENT_DISK="Không đủ dung lượng ổ cứng (%s MB < %s MB). Bỏ qua."
    WARN_INVALID_SWAP_SIZE="Kích thước swap không hợp lệ (%s MB). Bỏ qua."
    CREATING_SWAP="Tạo swap %s MB..."
    WARN_CREATE_SWAP_FAIL="Không thể tạo file swap. Bỏ qua."
    SWAP_CREATED="Swap đã được tạo và kích hoạt (%s MB)."
    ERR_MISSING_WALLET="Thiếu wallet address hoặc node ID."
    REGISTERING_WALLET="Đăng ký ví với: %s"
    ERR_REGISTER_WALLET="Không thể đăng ký ví. Xem log:"
    REGISTERING_NODE="Đăng ký node..."
    ERR_REGISTER_NODE="Không thể đăng ký node. Xem log:"
    NODE_ID_SAVED="Node ID đã được lưu: %s"
    USING_EXISTING_NODE_ID="Sử dụng node ID hiện có: %s"
    ARCH_DETECTED="Phát hiện kiến trúc: %s."
    WAIT_NODE_ID="Đang chờ node ID... (timeout sau %s giây)"
    ERR_NO_NODE_ID="Không lấy được node ID sau thời gian chờ."
    CRON_SETUP="Thiết lập cron job để tự khởi tạo lại container mỗi giờ."
    CRON_DONE="Cron job đã thiết lập: %s"
    ;;
  *) # en
    BANNER="===== Nexus Node Setup v1.4.4 (ARM Support) ====="
    ERR_NO_WALLET="Error: Please provide wallet address. Usage: $0 <wallet_address> [--no-swap] [--en|--ru|--cn] [--setup-cron]"
    WARN_INVALID_FLAG="Warning: Invalid flag: %s. Skipping."
    SKIP_SWAP_FLAG="Skipping swap creation (--no-swap)."
    INSTALLING_DOCKER="Installing Docker..."
    ERR_INSTALL_DOCKER="Error: Unable to install Docker."
    ERR_DOCKER_NOT_RUNNING="Error: Docker daemon is not running."
    ERR_DOCKER_PERMISSION="Error: No permission to run Docker."
    BUILDING_IMAGE="Starting to build image %s..."
    ERR_BUILD_IMAGE="Error: Unable to build image %s."
    BUILD_IMAGE_SUCCESS="Built image %s successfully."
    NODE_STARTED="Node started with wallet_address=%s."
    LOG_FILE_MSG="Log: %s"
    VIEW_LOG="View real-time log: docker logs -f %s"
    NOT_LINUX="System is not Linux, skipping swap."
    WARN_NO_RAM="Unable to determine RAM. Skipping swap."
    RAM_DETECTED="Detected total RAM: %s MB."
    SWAP_EXISTS="Swap already exists (%s MB), skipping."
    INSUFFICIENT_DISK="Insufficient disk space (%s MB < %s MB). Skipping."
    WARN_INVALID_SWAP_SIZE="Invalid swap size (%s MB). Skipping."
    CREATING_SWAP="Creating swap %s MB..."
    WARN_CREATE_SWAP_FAIL="Unable to create swap file. Skipping."
    SWAP_CREATED="Swap created and activated (%s MB)."
    ERR_MISSING_WALLET="Missing wallet address or node ID."
    REGISTERING_WALLET="Registering wallet: %s"
    ERR_REGISTER_WALLET="Unable to register wallet. Check log:"
    REGISTERING_NODE="Registering node..."
    ERR_REGISTER_NODE="Unable to register node. Check log:"
    NODE_ID_SAVED="Node ID saved: %s"
    USING_EXISTING_NODE_ID="Using existing node ID: %s"
    ARCH_DETECTED="Detected architecture: %s."
    WAIT_NODE_ID="Waiting for node ID... (timeout after %s seconds)"
    ERR_NO_NODE_ID="Unable to get node ID after waiting."
    CRON_SETUP="Setting up hourly container recreation."
    CRON_DONE="Cron job set: %s"
    ;;
esac

print_info "$BANNER"

# =====================
# Kiểm tra wallet
# =====================
if [ -z "$WALLET_ADDRESS" ]; then print_error "$ERR_NO_WALLET"; exit 1; fi

# =====================
# Parse các cờ còn lại
# =====================
for arg in "$@"; do
  case "$arg" in
    --no-swap) NO_SWAP=1 ;;
    --setup-cron) SETUP_CRON=1 ;;
    --en|--ru|--cn) : ;;
    *) print_warning "$(printf "$WARN_INVALID_FLAG" "$arg")" ;;
  esac
done

# =====================
# Kiến trúc & CLI URL
# =====================
ARCH=$(uname -m)
print_info "$(printf "$ARCH_DETECTED" "$ARCH")"
CLI_SUFFIX="linux-x86_64"; [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ] && CLI_SUFFIX="linux-arm64"

if ! command -v jq >/dev/null 2>&1; then apt update && apt install -y jq; fi
LATEST_TAG=$(curl -s https://api.github.com/repos/nexus-xyz/nexus-cli/releases/latest | jq -r .tag_name)
CLI_URL="https://github.com/nexus-xyz/nexus-cli/releases/download/${LATEST_TAG}/nexus-network-${CLI_SUFFIX}"

# =====================
# Swap (tùy chọn)
# =====================
create_swap(){
  if [ "$(uname -s)" != "Linux" ]; then print_warning "$NOT_LINUX"; return 0; fi
  total_ram=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "")
  [ -z "$total_ram" ] && total_ram=$(free -m | awk '/^Mem:/{print $2}')
  [ -z "$total_ram" ] && { print_warning "$WARN_NO_RAM"; return 0; }
  print_info "$(printf "$RAM_DETECTED" "$total_ram")"
  if swapon --show | grep -q "$SWAP_FILE"; then
    current_swap=$(free -m | awk '/^Swap:/{print $2}')
    [ -n "$current_swap" ] && [ "$current_swap" -ge "$total_ram" ] && { print_info "$(printf "$SWAP_EXISTS" "$current_swap")"; return 0; }
    swapoff "$SWAP_FILE" || true
  fi
  min_swap=$total_ram; max_swap=$((total_ram*2))
  available_disk=$(df -BM --output=avail "$(dirname "$SWAP_FILE")" | tail -n1 | grep -o '[0-9]\+')
  [ -z "$available_disk" ] || [ "$available_disk" -lt "$min_swap" ] && { print_warning "$(printf "$INSUFFICIENT_DISK" "$available_disk" "$min_swap")"; return 0; }
  swap_size=$([ "$available_disk" -ge "$max_swap" ] && echo "$max_swap" || echo "$min_swap")
  print_progress "$(printf "$CREATING_SWAP" "$swap_size")"
  fallocate -l "${swap_size}M" "$SWAP_FILE" 2>/dev/null || dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$swap_size"
  chmod 600 "$SWAP_FILE"; mkswap "$SWAP_FILE"; swapon "$SWAP_FILE"
  grep -q "$SWAP_FILE" /etc/fstab 2>/dev/null || echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
  print_success "$(printf "$SWAP_CREATED" "$swap_size")"
}
[ "$NO_SWAP" = 1 ] && print_warning "$SKIP_SWAP_FLAG" || create_swap

# =====================
# Docker
# =====================
if ! command -v docker >/dev/null 2>&1; then
  print_progress "$INSTALLING_DOCKER"
  apt update && apt install -y docker.io || { print_error "$ERR_INSTALL_DOCKER"; exit 1; }
  systemctl enable docker || true; systemctl start docker || true
  systemctl is-active --quiet docker || { print_error "$ERR_DOCKER_NOT_RUNNING"; exit 1; }
fi
docker ps >/dev/null 2>&1 || { print_error "$ERR_DOCKER_PERMISSION"; exit 1; }

# =====================
# Build image (here-doc TÁCH RIÊNG)
# =====================
build_image(){
  print_progress "$(printf "$BUILDING_IMAGE" "$IMAGE_NAME")"
  workdir=$(mktemp -d); cd "$workdir"

  cat > Dockerfile <<EOF
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y curl screen bash jq procps ca-certificates && rm -rf /var/lib/apt/lists/*
RUN curl -L "$CLI_URL" -o /usr/local/bin/nexus-network && chmod +x /usr/local/bin/nexus-network
RUN mkdir -p /root/.nexus
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
EOF

  cat > entrypoint.sh <<'ENTRYPOINT'
#!/bin/bash
set -e

mkdir -p /root/.nexus
touch /root/nexus.log || true

# Ưu tiên NODE_ID: env -> file -> config.json
NODE_ID_VAL="${NODE_ID:-}"
if [ -z "$NODE_ID_VAL" ] && [ -f /root/.nexus/node_id ]; then
  NODE_ID_VAL="$(tr -d ' \t\r\n' < /root/.nexus/node_id 2>/dev/null || true)"
fi
if [ -z "$NODE_ID_VAL" ] && [ -f /root/.nexus/config.json ]; then
  NODE_ID_VAL="$(jq -r '.node_id // empty' /root/.nexus/config.json 2>/dev/null || true)"
fi

# Cần ít nhất WALLET hoặc NODE_ID
if [ -z "$WALLET_ADDRESS" ] && [ -z "$NODE_ID_VAL" ]; then
  echo "❌ Missing wallet address or node ID"
  exit 1
fi

if [ -n "$NODE_ID_VAL" ]; then
  echo "ℹ️ Using node ID: $NODE_ID_VAL"
else
  echo "⏳ Registering wallet: $WALLET_ADDRESS"
  if ! nexus-network register-user --wallet-address "$WALLET_ADDRESS" &>> /root/nexus.log; then
    echo "❌ Unable to register wallet"; cat /root/nexus.log; exit 1
  fi
  echo "⏳ Registering node..."
  if ! nexus-network register-node &>> /root/nexus.log; then
    echo "❌ Unable to register node"; cat /root/nexus.log; exit 1
  fi
  NODE_ID_VAL="$(jq -r '.node_id // empty' /root/.nexus/config.json 2>/dev/null || true)"
  if [ -z "$NODE_ID_VAL" ]; then
    echo "❌ Cannot extract node ID"; cat /root/nexus.log; exit 1
  fi
  echo "ℹ️ Node ID created: $NODE_ID_VAL"
fi

# Persist node_id để lần sau luôn có
echo -n "$NODE_ID_VAL" > /root/.nexus/node_id

# Start prover
screen -dmS nexus bash -lc "nexus-network start --node-id $NODE_ID_VAL &>> /root/nexus.log"

sleep 3
if screen -list | grep -q "nexus"; then
  echo "🚀 Node started. Log: /root/nexus.log"
else
  echo "❌ Startup failed"; cat /root/nexus.log; exit 1
fi

tail -f /root/nexus.log
ENTRYPOINT

  docker build -t "$IMAGE_NAME" . || { print_error "$(printf "$ERR_BUILD_IMAGE" "$IMAGE_NAME")"; cd - >/dev/null; rm -rf "$workdir"; exit 1; }
  cd - >/dev/null; rm -rf "$workdir"
  print_success "$(printf "$BUILD_IMAGE_SUCCESS" "$IMAGE_NAME")"
}

# =====================
# Run container
# =====================
run_container(){
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  mkdir -p "$(dirname "$LOG_FILE")" "$CREDENTIALS_DIR"
  chmod 700 "$CREDENTIALS_DIR" || true
  : > "$LOG_FILE"; chmod 644 "$LOG_FILE"

  NODE_ID=""
  if [ -f "$NODE_ID_FILE" ]; then NODE_ID="$(tr -d ' \t\r\n' < "$NODE_ID_FILE" 2>/dev/null || true)"; fi
  if [ -z "$NODE_ID" ] && [ -f "$CREDENTIALS_DIR/node_id" ]; then NODE_ID="$(tr -d ' \t\r\n' < "$CREDENTIALS_DIR/node_id" 2>/dev/null || true)"; fi
  if [ -z "$NODE_ID" ] && [ -f "$CREDENTIALS_DIR/config.json" ]; then NODE_ID="$(jq -r '.node_id // empty' "$CREDENTIALS_DIR/config.json" 2>/dev/null || true)"; fi
  if [ -n "$NODE_ID" ]; then echo -n "$NODE_ID" > "$NODE_ID_FILE"; print_info "$(printf "$USING_EXISTING_NODE_ID" "$NODE_ID")"; fi

  docker run -d --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -v "$LOG_FILE":/root/nexus.log:rw \
    -v "$CREDENTIALS_DIR":/root/.nexus:rw \
    -e WALLET_ADDRESS="$WALLET_ADDRESS" \
    -e NODE_ID="$NODE_ID" \
    --health-cmd='pidof nexus-network || exit 1' \
    --health-interval=30s \
    --health-retries=3 \
    "$IMAGE_NAME"

  print_node "$(printf "$NODE_STARTED" "$WALLET_ADDRESS")"
  print_log  "$(printf "$LOG_FILE_MSG" "$LOG_FILE")"
  print_info "$(printf "$VIEW_LOG" "$CONTAINER_NAME")"

  # Nếu NODE_ID trống lúc run -> đợi entrypoint tạo /root/.nexus/node_id
  if [ -z "$NODE_ID" ]; then
    TIMEOUT=120; WAIT_TIME=0
    print_progress "$(printf "$WAIT_NODE_ID" "$TIMEOUT")"
    while [ $WAIT_TIME -lt $TIMEOUT ]; do
      if [ -f "$CREDENTIALS_DIR/node_id" ]; then
        NODE_ID="$(tr -d ' \t\r\n' < "$CREDENTIALS_DIR/node_id" 2>/dev/null || true)"
      elif [ -f "$CREDENTIALS_DIR/config.json" ]; then
        NODE_ID="$(jq -r '.node_id // empty' "$CREDENTIALS_DIR/config.json" 2>/dev/null || true)"
      fi
      if [ -n "$NODE_ID" ]; then
        echo -n "$NODE_ID" > "$NODE_ID_FILE"
        print_success "$(printf "$NODE_ID_SAVED" "$NODE_ID")"
        return
      fi
      sleep 5; WAIT_TIME=$((WAIT_TIME+5))
    done
    print_error "$ERR_NO_NODE_ID"; exit 1
  fi
}

# =====================
# Cron (idempotent)
# =====================
ensure_cron_installed(){ command -v crontab >/dev/null 2>&1 || { apt update && apt install -y cron; systemctl enable cron || true; systemctl start cron || true; }; }
setup_hourly_cron(){
  print_info "$CRON_SETUP"
  ensure_cron_installed
  SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
  LANG_FLAG=""; case "$LANGUAGE" in en|ru|cn) LANG_FLAG="--$LANGUAGE";; esac
  CRON_MARK="# NEXUS_NODE_RECREATE:$WALLET_ADDRESS - managed by $SCRIPT_PATH"
  CRON_EXPR="0 * * * *"
  CRON_JOB="$CRON_EXPR (docker restart $CONTAINER_NAME >/dev/null 2>&1 || (docker rm -f $CONTAINER_NAME >/dev/null 2>&1; /bin/bash $SCRIPT_PATH $WALLET_ADDRESS --no-swap $LANG_FLAG))"
  TMP="$(mktemp)"; crontab -l 2>/dev/null > "$TMP" || true
  grep -Fv "$CRON_MARK" "$TMP" | grep -Fv "$SCRIPT_PATH $WALLET_ADDRESS" > "${TMP}.new" || true
  { cat "${TMP}.new"; echo "$CRON_MARK"; echo "$CRON_JOB"; } | crontab -
  rm -f "$TMP" "${TMP}.new"
  print_success "$(printf "$CRON_DONE" "$CRON_JOB")"
}

# =====================
# Build & Run
# =====================
build_image
run_container
[ "$SETUP_CRON" = 1 ] && setup_hourly_cron
print_success "===== Hoàn Tất Cài Đặt ====="
