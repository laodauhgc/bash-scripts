#!/bin/bash
set -e

# Version: v1.5.0 | Update 16/08/2025
# Profile: Smart cron (watchdog + only-update-when-new), idempotent, safe on node_id

# =====================
# Biến cấu hình
# =====================
CONTAINER_NAME="nexus-node"
IMAGE_NAME="nexus-node:latest"

LOG_DIR="/root/nexus_logs"
LOG_FILE="$LOG_DIR/nexus.log"
CRON_LOG="$LOG_DIR/cronjob.log"
WATCHDOG_LOG="$LOG_DIR/watchdog.log"

CREDENTIALS_DIR="/root/nexus_credentials"
NODE_ID_FILE="/root/nexus_node_id.txt"   # GIỮ NGUYÊN - KHÔNG XÓA
SWAP_FILE="/swapfile"

STATE_DIR="/root/nexus_state"
CLI_TAG_FILE="$STATE_DIR/cli_tag.txt"    # Lưu phiên bản CLI đã build lần gần nhất

WALLET_ADDRESS="${1-}"
NO_SWAP=0
LANGUAGE="vi"
SETUP_CRON=0
MODE="normal"   # normal | watchdog | smart-update

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
  case "$arg" in
    --en) LANGUAGE="en" ;;
    --ru) LANGUAGE="ru" ;;
    --cn) LANGUAGE="cn" ;;
  esac
done

# =====================
# Thông điệp theo ngôn ngữ (vi/en rút gọn)
# =====================
case $LANGUAGE in
  vi)
    BANNER="===== Cài Đặt Node Nexus v1.5.0 (Smart Cron) ====="
    ERR_NO_WALLET="Lỗi: Vui lòng cung cấp wallet address. Cách dùng: $0 <wallet_address> [--no-swap] [--en|--ru|--cn] [--setup-cron] [--watchdog|--smart-update]"
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
    CRON_SETUP="Thiết lập cron thông minh: watchdog (5') + updater (12h). Dọn cron cũ nếu có."
    CRON_DONE="Cron job đã thiết lập."
    ;;

  *)
    BANNER="===== Nexus Node Setup v1.5.0 (Smart Cron) ====="
    ERR_NO_WALLET="Error: Please provide wallet address. Usage: $0 <wallet_address> [--no-swap] [--en|--ru|--cn] [--setup-cron] [--watchdog|--smart-update]"
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
    CRON_SETUP="Setting smart cron: watchdog (5') + updater (12h). Cleaning old cron if present."
    CRON_DONE="Cron jobs configured."
    ;;
esac

print_info "$BANNER"

# =====================
# Kiểm tra wallet
# =====================
if [ -z "$WALLET_ADDRESS" ]; then
  print_error "$ERR_NO_WALLET"
  exit 1
fi

# =====================
# Parse các cờ còn lại
# =====================
for arg in "$@"; do
  case "$arg" in
    --no-swap) NO_SWAP=1 ;;
    --setup-cron) SETUP_CRON=1 ;;
    --watchdog) MODE="watchdog" ;;
    --smart-update) MODE="smart-update" ;;
    --en|--ru|--cn) : ;;  # đã xử lý ở trên
    *) print_warning "$(printf "$WARN_INVALID_FLAG" "$arg")" ;;
  esac
done

# =====================
# Chuẩn bị thư mục/log
# =====================
mkdir -p "$LOG_DIR" "$CREDENTIALS_DIR" "$STATE_DIR"

# =====================
# Kiến trúc & công cụ
# =====================
ARCH=$(uname -m)
print_info "$(printf "$ARCH_DETECTED" "$ARCH")"
CLI_SUFFIX="linux-x86_64"
if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
  CLI_SUFFIX="linux-arm64"
fi

ensure_pkgs() {
  # curl, jq, util-linux (flock), cron
  apt update
  apt install -y curl jq util-linux cron
  systemctl enable cron 2>/dev/null || true
  systemctl start cron 2>/dev/null || true
}

# =====================
# Swap (tùy chọn)
# =====================
create_swap() {
  if [ "$(uname -s)" != "Linux" ]; then print_warning "$NOT_LINUX"; return 0; fi
  total_ram=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "")
  if [ -z "$total_ram" ] || [ "$total_ram" -le 0 ]; then total_ram=$(free -m | awk '/^Mem:/{print $2}'); fi
  if [ -z "$total_ram" ] || [ "$total_ram" -le 0 ]; then print_warning "$WARN_NO_RAM"; return 0; fi
  print_info "$(printf "$RAM_DETECTED" "$total_ram")"
  if swapon --show | grep -q "$SWAP_FILE"; then
    current_swap=$(free -m | awk '/^Swap:/{print $2}')
    if [ -n "$current_swap" ] && [ "$current_swap" -ge "$total_ram" ]; then
      print_info "$(printf "$SWAP_EXISTS" "$current_swap")"
      return 0
    fi
    swapoff "$SWAP_FILE" || true
  fi
  min_swap=$total_ram; max_swap=$((total_ram*2))
  available_disk=$(df -BM --output=avail "$(dirname "$SWAP_FILE")" | tail -n1 | grep -o '[0-9]\+')
  if [ -z "$available_disk" ] || [ "$available_disk" -lt "$min_swap" ]; then
    print_warning "$(printf "$INSUFFICIENT_DISK" "$available_disk" "$min_swap")"
    return 0
  fi
  if [ "$available_disk" -ge "$max_swap" ]; then swap_size=$max_swap; else swap_size=$min_swap; fi
  print_progress "$(printf "$CREATING_SWAP" "$swap_size")"
  fallocate -l "${swap_size}M" "$SWAP_FILE" 2>/dev/null || dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$swap_size"
  chmod 600 "$SWAP_FILE"; mkswap "$SWAP_FILE"; swapon "$SWAP_FILE"
  grep -q "$SWAP_FILE" /etc/fstab 2>/dev/null || echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
  print_success "$(printf "$SWAP_CREATED" "$swap_size")"
}
if [ "$NO_SWAP" = 1 ]; then print_warning "$SKIP_SWAP_FLAG"; else create_swap; fi

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
# Helpers: lấy tag mới nhất & URL
# =====================
fetch_latest_tag() {
  # Trả về tag hoặc chuỗi rỗng nếu lỗi
  local tag
  tag="$(curl -fsSL https://api.github.com/repos/nexus-xyz/nexus-cli/releases/latest | jq -r '.tag_name // empty' 2>/dev/null || true)"
  echo -n "$tag"
}
cli_url_for_tag() {
  local tag="$1"
  echo -n "https://github.com/nexus-xyz/nexus-cli/releases/download/${tag}/nexus-network-${CLI_SUFFIX}"
}

# =====================
# Build image (có --pull + CACHE_BUST) — cho 1 tag chỉ định
# =====================
build_image_for_tag() {
  local build_tag="$1"
  local target_cli_url; target_cli_url="$(cli_url_for_tag "$build_tag")"

  print_progress "$(printf "$BUILDING_IMAGE" "$IMAGE_NAME")"
  local workdir; workdir="$(mktemp -d)"; cd "$workdir"

  cat > Dockerfile <<EOF
FROM ubuntu:24.04
ARG CACHE_BUST=1
ENV DEBIAN_FRONTEND=noninteractive
RUN echo "\$CACHE_BUST" >/dev/null
RUN apt-get update && apt-get install -y curl screen bash jq procps ca-certificates && rm -rf /var/lib/apt/lists/*
RUN curl -L "$target_cli_url" -o /usr/local/bin/nexus-network && chmod +x /usr/local/bin/nexus-network
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

NODE_ID_VAL="${NODE_ID:-}"
if [ -z "$NODE_ID_VAL" ] && [ -f /root/.nexus/node_id ]; then
  NODE_ID_VAL="$(tr -d ' \t\r\n' < /root/.nexus/node_id 2>/dev/null || true)"
fi
if [ -z "$NODE_ID_VAL" ] && [ -f /root/.nexus/config.json ]; then
  NODE_ID_VAL="$(jq -r '.node_id // empty' /root/.nexus/config.json 2>/dev/null || true)"
fi

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

echo -n "$NODE_ID_VAL" > /root/.nexus/node_id

detect_cpus() {
  local cpus
  if command -v nproc >/dev/null 2>&1; then cpus="$(nproc 2>/dev/null || echo 1)"; else cpus=1; fi
  if [ -r /sys/fs/cgroup/cpu.max ]; then
    read -r quota period < /sys/fs/cgroup/cpu.max || true
    if [ "${quota:-max}" != "max" ] && [ -n "$quota" ] && [ -n "$period" ] && [ "$period" -gt 0 ] 2>/dev/null; then
      local ceil=$(( (quota + period - 1) / period ))
      if [ "$ceil" -gt 0 ] && [ "$ceil" -lt "$cpus" ] 2>/dev/null; then cpus=$ceil; fi
    fi
  elif [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ] && [ -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]; then
    local q p; q="$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null || echo -1)"
    p="$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null || echo -1)"
    if [ "$q" -gt 0 ] && [ "$p" -gt 0 ] 2>/dev/null; then
      local ceil=$(( (q + p - 1) / p ))
      if [ "$ceil" -gt 0 ] && [ "$ceil" -lt "$cpus" ] 2>/dev/null; then cpus=$ceil; fi
    fi
  fi
  case "$cpus" in ''|*[!0-9]*) cpus=1 ;; esac
  if [ "$cpus" -le 0 ] 2>/dev/null; then cpus=1; fi
  echo "$cpus"
}

CPU_COUNT="$(detect_cpus)"
MAX_THREADS="$CPU_COUNT"; if [ "$MAX_THREADS" -gt 8 ] 2>/dev/null; then MAX_THREADS=8; fi
echo "ℹ️ CPU available: $CPU_COUNT -> using --max-threads $MAX_THREADS"

screen -dmS nexus bash -lc "nexus-network start --node-id \$NODE_ID_VAL --max-threads \$MAX_THREADS &>> /root/nexus.log"

sleep 3
if screen -list | grep -q "nexus"; then
  echo "🚀 Node started. Log: /root/nexus.log"
else
  echo "❌ Startup failed"; cat /root/nexus.log; exit 1
fi

tail -f /root/nexus.log
ENTRYPOINT

  local BUILD_TS; BUILD_TS="$(date +%s)"
  if ! docker build --pull -t "$IMAGE_NAME" --build-arg CACHE_BUST="$BUILD_TS" .; then
    print_error "$(printf "$ERR_BUILD_IMAGE" "$IMAGE_NAME")"
    cd - >/dev/null; rm -rf "$workdir"; exit 1
  fi
  cd - >/dev/null; rm -rf "$workdir"
  print_success "$(printf "$BUILD_IMAGE_SUCCESS" "$IMAGE_NAME")"
}

# =====================
# Run container (idempotent)
# =====================
run_container() {
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  mkdir -p "$(dirname "$LOG_FILE")" "$CREDENTIALS_DIR"
  chmod 700 "$CREDENTIALS_DIR" || true
  : > "$LOG_FILE"; chmod 644 "$LOG_FILE"

  local NODE_ID=""
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

  if [ -z "$NODE_ID" ]; then
    local TIMEOUT=120; local WAIT_TIME=0
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
# Watchdog: chỉ restart khi unhealthy hoặc container không chạy
# =====================
watchdog() {
  ensure_pkgs
  local status
  status="$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "notfound")"
  local health="unknown"
  if [ "$status" != "notfound" ]; then
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER_NAME" 2>/dev/null || echo "none")"
  fi

  {
    echo "[$(date -Is)] status=$status health=$health"
    if [ "$status" = "running" ] && [ "$health" = "healthy" ]; then
      echo "OK: container healthy."
      exit 0
    fi
    if [ "$status" = "running" ] && [ "$health" = "starting" ]; then
      echo "OK: container starting, no action."
      exit 0
    fi
    if [ "$status" = "running" ] && [ "$health" = "unhealthy" ]; then
      echo "Action: docker restart $CONTAINER_NAME"
      docker restart "$CONTAINER_NAME" >/dev/null 2>&1 || true
      exit 0
    fi
    echo "Action: (re)create container"
    # Nếu container không tồn tại/đã dừng → tạo lại từ image hiện có
    run_container
  } >> "$WATCHDOG_LOG" 2>&1
}

# =====================
# Smart update: chỉ rebuild khi có tag mới
# =====================
smart_update() {
  ensure_pkgs
  local latest; latest="$(fetch_latest_tag)"
  if [ -z "$latest" ]; then
    echo "[$(date -Is)] WARN: cannot fetch latest tag — skip." >> "$CRON_LOG"
    return 0
  fi
  local current=""; [ -f "$CLI_TAG_FILE" ] && current="$(tr -d ' \t\r\n' < "$CLI_TAG_FILE" 2>/dev/null || true)"
  if [ "$latest" = "$current" ] && docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "[$(date -Is)] No update (latest=$latest)." >> "$CRON_LOG"
    return 0
  fi

  {
    echo "[$(date -Is)] Update detected: $current -> $latest"
    build_image_for_tag "$latest"
    run_container
    echo -n "$latest" > "$CLI_TAG_FILE"
    echo "[$(date -Is)] Update done."
  } >> "$CRON_LOG" 2>&1
}

# =====================
# Cron (idempotent): dọn cron cũ + tạo watchdog/updater
# =====================
ensure_cron_installed() { ensure_pkgs; }

setup_smart_cron() {
  print_info "$CRON_SETUP"
  ensure_cron_installed

  local SCRIPT_PATH; SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
  local LANG_FLAG=""
  case "$LANGUAGE" in en|ru|cn) LANG_FLAG="--$LANGUAGE" ;; esac

  local DOCKER_BIN; DOCKER_BIN="$(command -v docker)"
  local BASH_BIN;   BASH_BIN="$(command -v bash)"
  local FLOCK_BIN;  FLOCK_BIN="$(command -v flock || true)"

  mkdir -p "$LOG_DIR"

  local OLD_MARK="# NEXUS_NODE_RECREATE:$WALLET_ADDRESS"      # marker cũ (bản trước)
  local WD_MARK="# NEXUS_NODE_WATCHDOG:$WALLET_ADDRESS"       # marker mới
  local UP_MARK="# NEXUS_NODE_UPDATER:$WALLET_ADDRESS"        # marker mới

  local PATHS="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

  # Lệnh cron
  local LOCK_WD="/var/lock/nexus-watchdog.lock"
  local LOCK_UP="/var/lock/nexus-update.lock"

  local WD_CMD="$PATHS; "
  if [ -n "$FLOCK_BIN" ]; then
    WD_CMD+="$FLOCK_BIN -n $LOCK_WD $BASH_BIN $SCRIPT_PATH \"$WALLET_ADDRESS\" --no-swap $LANG_FLAG --watchdog >> $WATCHDOG_LOG 2>&1"
  else
    WD_CMD+="$BASH_BIN $SCRIPT_PATH \"$WALLET_ADDRESS\" --no-swap $LANG_FLAG --watchdog >> $WATCHDOG_LOG 2>&1"
  fi
  local WD_EXPR="*/5 * * * *"
  local WD_JOB="$WD_EXPR $WD_CMD"

  local UP_CMD="$PATHS; "
  if [ -n "$FLOCK_BIN" ]; then
    UP_CMD+="$FLOCK_BIN -n $LOCK_UP $BASH_BIN $SCRIPT_PATH \"$WALLET_ADDRESS\" --no-swap $LANG_FLAG --smart-update >> $CRON_LOG 2>&1"
  else
    UP_CMD+="$BASH_BIN $SCRIPT_PATH \"$WALLET_ADDRESS\" --no-swap $LANG_FLAG --smart-update >> $CRON_LOG 2>&1"
  fi
  local UP_EXPR="0 */12 * * *"
  local UP_JOB="$UP_EXPR $UP_CMD"

  # Dọn cron cũ (restart mỗi giờ) & các bản cũ liên quan
  local TMP; TMP="$(mktemp)"
  {
    crontab -l 2>/dev/null \
      | grep -Fv "$OLD_MARK" \
      | grep -Fv "$SCRIPT_PATH $WALLET_ADDRESS" \
      | grep -Ev "docker[[:space:]]+restart[[:space:]]+$CONTAINER_NAME" \
      | grep -Fv "NEXUS_NODE_WATCHDOG:" \
      | grep -Fv "NEXUS_NODE_UPDATER:" \
      || true
    echo "$WD_MARK"
    echo "$WD_JOB"
    echo "$UP_MARK"
    echo "$UP_JOB"
  } > "$TMP"

  crontab "$TMP"
  rm -f "$TMP"

  print_success "$CRON_DONE"
  print_log "Watchdog log: $WATCHDOG_LOG"
  print_log "Updater  log: $CRON_LOG"
}

# =====================
# Luồng chính theo MODE
# =====================
case "$MODE" in
  watchdog)
    watchdog
    exit 0
    ;;
  smart-update)
    smart_update
    exit 0
    ;;
  *)
    # Chạy cài đặt đầy đủ (cài pkgs cần thiết, build initial theo tag hiện tại, run, set cron nếu yêu cầu)
    ensure_pkgs
    latest_now="$(fetch_latest_tag)"
    if [ -z "$latest_now" ]; then
      print_warning "Không lấy được latest tag từ GitHub, vẫn tiến hành build theo latest tại thời điểm base image."
      latest_now="manual-$(date +%s)"
    fi
    build_image_for_tag "$latest_now"
    echo -n "$latest_now" > "$CLI_TAG_FILE"
    run_container
    if [ "$SETUP_CRON" = 1 ]; then setup_smart_cron; fi
    print_success "===== Hoàn Tất Cài Đặt (Smart) ====="
    ;;
esac
