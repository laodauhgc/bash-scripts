#!/bin/bash
set -e

# Version: v1.5.2 | Update 16/08/2025

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
NODE_ID_FILE="/root/nexus_node_id.txt"   # KHÔNG XÓA
SWAP_FILE="/swapfile"

STATE_DIR="/root/nexus_state"
CLI_TAG_FILE="$STATE_DIR/cli_tag.txt"    # Lưu tag CLI đã build gần nhất

WALLET_ADDRESS="${1-}"
NO_SWAP=0
LANGUAGE="vi"
SETUP_CRON=0
MODE="normal"     # normal | watchdog | update

# =====================
# Màu sắc & helpers
# =====================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
ok(){ echo -e "${GREEN}✅ $1${NC}"; }
err(){ echo -e "${RED}❌ $1${NC}"; }
warn(){ echo -e "${YELLOW}⚠️ $1${NC}"; }
inf(){ echo -e "${BLUE}ℹ️ $1${NC}"; }

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
# Thông điệp (ngắn gọn)
# =====================
case $LANGUAGE in
  vi)
    BANNER="===== Cài Đặt Node Nexus v1.5.2 ====="
    USE_INFO_CRON="Thiết lập cron định kỳ: kiểm tra container (5') và cập nhật nếu có phiên bản mới (12h)."
    CRON_DONE="Đã thiết lập cron."
    ERR_NO_WALLET="Lỗi: Vui lòng cung cấp wallet address. Dùng: $0 <wallet> [--no-swap] [--setup-cron]"
    ;;
  *)
    BANNER="===== Nexus Node Setup v1.5.2 ====="
    USE_INFO_CRON="Set up periodic cron: watchdog (5') and updater if new version (12h)."
    CRON_DONE="Cron configured."
    ERR_NO_WALLET="Error: Please provide wallet address. Usage: $0 <wallet> [--no-swap] [--setup-cron]"
    ;;
esac

inf "$BANNER"

# =====================
# Kiểm tra wallet
# =====================
if [ -z "$WALLET_ADDRESS" ]; then
  err "$ERR_NO_WALLET"; exit 1
fi

# =====================
# Parse cờ còn lại
# =====================
for arg in "$@"; do
  case "$arg" in
    --no-swap) NO_SWAP=1 ;;
    --setup-cron) SETUP_CRON=1 ;;
    --watchdog) MODE="watchdog" ;;   # nội bộ cho cron
    --smart-update|--update) MODE="update" ;;  # tên cũ vẫn hỗ trợ
    --en|--ru|--cn) : ;;
    *) warn "Bỏ qua flag không hợp lệ: $arg" ;;
  esac
done

# =====================
# Chuẩn bị thư mục/log
# =====================
mkdir -p "$LOG_DIR" "$CREDENTIALS_DIR" "$STATE_DIR"

# =====================
# Kiến trúc & tool
# =====================
ARCH=$(uname -m)
inf "Phát hiện kiến trúc: $ARCH."
CLI_SUFFIX="linux-x86_64"; [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ] && CLI_SUFFIX="linux-arm64"

ensure_pkgs() {
  apt update
  apt install -y curl jq util-linux cron
  systemctl enable cron 2>/dev/null || true
  systemctl start  cron 2>/dev/null || true
}

# =====================
# Swap (tùy chọn)
# =====================
create_swap() {
  if [ "$(uname -s)" != "Linux" ]; then warn "Hệ thống không phải Linux, bỏ qua swap."; return 0; fi
  total_ram=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || true)
  [ -z "$total_ram" ] && total_ram=$(free -m | awk '/^Mem:/{print $2}')
  if [ -z "$total_ram" ] || [ "$total_ram" -le 0 ]; then warn "Không xác định được RAM, bỏ qua swap."; return 0; fi
  inf "Tổng RAM phát hiện: ${total_ram} MB."
  if swapon --show | grep -q "$SWAP_FILE"; then
    current_swap=$(free -m | awk '/^Swap:/{print $2}')
    [ -n "$current_swap" ] && [ "$current_swap" -ge "$total_ram" ] && { inf "Swap đã tồn tại (${current_swap} MB), bỏ qua."; return 0; }
    swapoff "$SWAP_FILE" || true
  fi
  min_swap=$total_ram; max_swap=$((total_ram*2))
  available_disk=$(df -BM --output=avail "$(dirname "$SWAP_FILE")" | tail -n1 | grep -o '[0-9]\+')
  [ -z "$available_disk" ] && available_disk=0
  if [ "$available_disk" -lt "$min_swap" ]; then warn "Không đủ dung lượng (${available_disk} MB < ${min_swap} MB), bỏ qua swap."; return 0; fi
  swap_size=$min_swap; [ "$available_disk" -ge "$max_swap" ] && swap_size=$max_swap
  inf "Tạo swap ${swap_size} MB..."
  fallocate -l "${swap_size}M" "$SWAP_FILE" 2>/dev/null || dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$swap_size"
  chmod 600 "$SWAP_FILE"; mkswap "$SWAP_FILE" >/dev/null; swapon "$SWAP_FILE"
  grep -q "$SWAP_FILE" /etc/fstab 2>/dev/null || echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
  ok "Swap đã được tạo và kích hoạt (${swap_size} MB)."
}
[ "$NO_SWAP" = 1 ] && warn "Bỏ qua tạo swap theo yêu cầu (--no-swap)." || create_swap

# =====================
# Docker
# =====================
if ! command -v docker >/dev/null 2>&1; then
  inf "Cài đặt Docker..."
  apt update && apt install -y docker.io || { err "Không thể cài đặt Docker."; exit 1; }
  systemctl enable docker || true; systemctl start docker || true
  systemctl is-active --quiet docker || { err "Docker daemon không chạy."; exit 1; }
fi
docker ps >/dev/null 2>&1 || { err "Không có quyền chạy Docker."; exit 1; }

# =====================
# Helper tag & URL
# =====================
fetch_latest_tag() {
  curl -fsSL https://api.github.com/repos/nexus-xyz/nexus-cli/releases/latest \
    | jq -r '.tag_name // empty' 2>/dev/null || true
}
cli_url_for_tag() { echo -n "https://github.com/nexus-xyz/nexus-cli/releases/download/$1/nexus-network-${CLI_SUFFIX}"; }

# =====================
# Build image (theo tag)
# =====================
build_image_for_tag() {
  local build_tag="$1"
  local target_cli_url; target_cli_url="$(cli_url_for_tag "$build_tag")"
  inf "Bắt đầu xây dựng image $IMAGE_NAME…"

  local wd; wd="$(mktemp -d)"; cd "$wd"
  cat > Dockerfile <<EOF
FROM ubuntu:24.04
ARG CACHE_BUST=1
ENV DEBIAN_FRONTEND=noninteractive
RUN echo "\$CACHE_BUST" >/dev/null
RUN apt-get update && apt-get install -y curl bash jq procps ca-certificates && rm -rf /var/lib/apt/lists/*
RUN curl -L "$target_cli_url" -o /usr/local/bin/nexus-network && chmod +x /usr/local/bin/nexus-network
RUN mkdir -p /root/.nexus
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
EOF

  # ENTRYPOINT: KHÔNG dùng screen; chạy trực tiếp, log vào file, healthcheck dùng pidof.
  cat > entrypoint.sh <<'ENTRYPOINT'
#!/bin/bash
set -e

mkdir -p /root/.nexus
touch /root/nexus.log || true

# Lấy NODE_ID theo ưu tiên: env -> file -> config.json
NODE_ID_VAL="${NODE_ID:-}"
if [ -z "$NODE_ID_VAL" ] && [ -f /root/.nexus/node_id ]; then
  NODE_ID_VAL="$(tr -d ' \t\r\n' < /root/.nexus/node_id 2>/dev/null || true)"
fi
if [ -z "$NODE_ID_VAL" ] && [ -f /root/.nexus/config.json ]; then
  NODE_ID_VAL="$(jq -r '.node_id // empty' /root/.nexus/config.json 2>/dev/null || true)"
fi

if [ -z "$WALLET_ADDRESS" ] && [ -z "$NODE_ID_VAL" ]; then
  echo "❌ Missing wallet address or node ID" | tee -a /root/nexus.log
  exit 1
fi

if [ -n "$NODE_ID_VAL" ]; then
  echo "ℹ️ Using node ID: $NODE_ID_VAL" | tee -a /root/nexus.log
else
  echo "⏳ Registering wallet: $WALLET_ADDRESS" | tee -a /root/nexus.log
  if ! nexus-network register-user --wallet-address "$WALLET_ADDRESS" >>/root/nexus.log 2>&1; then
    echo "❌ Unable to register wallet" | tee -a /root/nexus.log; exit 1
  fi
  echo "⏳ Registering node..." | tee -a /root/nexus.log
  if ! nexus-network register-node >>/root/nexus.log 2>&1; then
    echo "❌ Unable to register node" | tee -a /root/nexus.log; exit 1
  fi
  NODE_ID_VAL="$(jq -r '.node_id // empty' /root/.nexus/config.json 2>/dev/null || true)"
  if [ -z "$NODE_ID_VAL" ]; then
    echo "❌ Cannot extract node ID" | tee -a /root/nexus.log; exit 1
  fi
  echo -n "$NODE_ID_VAL" > /root/.nexus/node_id
  echo "ℹ️ Node ID created: $NODE_ID_VAL" | tee -a /root/nexus.log
fi

# Tính threads: min(CPU khả dụng, 8)
detect_cpus() {
  local cpus=1
  if command -v nproc >/dev/null 2>&1; then cpus="$(nproc 2>/dev/null || echo 1)"; fi
  if [ -r /sys/fs/cgroup/cpu.max ]; then
    read -r quota period < /sys/fs/cgroup/cpu.max || true
    if [ "${quota:-max}" != "max" ] && [ -n "$quota" ] && [ -n "$period" ] && [ "$period" -gt 0 ] 2>/dev/null; then
      local ceil=$(( (quota + period - 1) / period ))
      [ "$ceil" -gt 0 ] && [ "$ceil" -lt "$cpus" ] 2>/dev/null && cpus=$ceil
    fi
  elif [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ] && [ -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]; then
    local q p; q="$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null || echo -1)"
    p="$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null || echo -1)"
    if [ "$q" -gt 0 ] && [ "$p" -gt 0 ] 2>/dev/null; then
      local ceil=$(( (q + p - 1) / p ))
      [ "$ceil" -gt 0 ] && [ "$ceil" -lt "$cpus" ] 2>/dev/null && cpus=$ceil
    fi
  fi
  case "$cpus" in ''|*[!0-9]*) cpus=1 ;; esac
  [ "$cpus" -le 0 ] && cpus=1
  echo "$cpus"
}
CPU_COUNT="$(detect_cpus)"
MAX_THREADS="$CPU_COUNT"; [ "$MAX_THREADS" -gt 8 ] && MAX_THREADS=8
echo "ℹ️ CPU available: $CPU_COUNT -> using --max-threads $MAX_THREADS" | tee -a /root/nexus.log

# Chạy tiến trình chính (nền), log vào file
nexus-network start --node-id "$NODE_ID_VAL" --max-threads "$MAX_THREADS" >> /root/nexus.log 2>&1 &
sleep 2

# Kiểm tra đã lên PID chưa
if pidof nexus-network >/dev/null 2>&1; then
  echo "🚀 Node started. Log: /root/nexus.log" | tee -a /root/nexus.log
else
  echo "❌ Startup failed" | tee -a /root/nexus.log
  exit 1
fi

# Xuất log ra stdout để docker logs theo dõi
exec tail -f /root/nexus.log
ENTRYPOINT

  local BUILD_TS; BUILD_TS="$(date +%s)"
  docker build --pull -t "$IMAGE_NAME" --build-arg CACHE_BUST="$BUILD_TS" . >/dev/null
  cd - >/dev/null; rm -rf "$wd"
  ok "Xây dựng image $IMAGE_NAME thành công."
}

# =====================
# Run container
# =====================
run_container() {
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  mkdir -p "$(dirname "$LOG_FILE")" "$CREDENTIALS_DIR"
  chmod 700 "$CREDENTIALS_DIR" || true
  : > "$LOG_FILE"; chmod 644 "$LOG_FILE"

  local NODE_ID=""
  [ -f "$NODE_ID_FILE" ] && NODE_ID="$(tr -d ' \t\r\n' < "$NODE_ID_FILE" 2>/dev/null || true)"
  [ -z "$NODE_ID" ] && [ -f "$CREDENTIALS_DIR/node_id" ] && NODE_ID="$(tr -d ' \t\r\n' < "$CREDENTIALS_DIR/node_id" 2>/dev/null || true)"
  [ -z "$NODE_ID" ] && [ -f "$CREDENTIALS_DIR/config.json" ] && NODE_ID="$(jq -r '.node_id // empty' "$CREDENTIALS_DIR/config.json" 2>/dev/null || true)"
  [ -n "$NODE_ID" ] && echo -n "$NODE_ID" > "$NODE_ID_FILE" && inf "Dùng Node ID hiện có: $NODE_ID"

  docker run -d --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -v "$LOG_FILE":/root/nexus.log:rw \
    -v "$CREDENTIALS_DIR":/root/.nexus:rw \
    -e WALLET_ADDRESS="$WALLET_ADDRESS" \
    -e NODE_ID="$NODE_ID" \
    --health-cmd='pidof nexus-network || exit 1' \
    --health-interval=30s \
    --health-retries=3 \
    "$IMAGE_NAME" >/dev/null

  ok "Đã chạy node với wallet_address=$WALLET_ADDRESS."
  inf "Xem log: docker logs -f $CONTAINER_NAME"

  if [ -z "$NODE_ID" ]; then
    # Lần đầu cần chờ node_id sinh ra
    local TIMEOUT=120; local t=0
    inf "Đang chờ node ID... (timeout ${TIMEOUT}s)"
    while [ $t -lt $TIMEOUT ]; do
      if [ -f "$CREDENTIALS_DIR/node_id" ]; then
        NODE_ID="$(tr -d ' \t\r\n' < "$CREDENTIALS_DIR/node_id" 2>/dev/null || true)"
      elif [ -f "$CREDENTIALS_DIR/config.json" ]; then
        NODE_ID="$(jq -r '.node_id // empty' "$CREDENTIALS_DIR/config.json" 2>/dev/null || true)"
      fi
      if [ -n "$NODE_ID" ]; then
        echo -n "$NODE_ID" > "$NODE_ID_FILE"
        ok "Đã lưu Node ID: $NODE_ID"
        break
      fi
      sleep 5; t=$((t+5))
    done
    [ -z "$NODE_ID" ] && { err "Không lấy được node ID sau khi chờ."; exit 1; }
  fi
}

# =====================
# Watchdog: restart khi unhealthy/không chạy
# =====================
watchdog() {
  ensure_pkgs
  local status health
  status="$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "notfound")"
  if [ "$status" != "notfound" ]; then
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER_NAME" 2>/dev/null || echo "none")"
  else
    health="unknown"
  fi

  {
    echo "[$(date -Is)] status=$status health=$health"
    if [ "$status" = "running" ] && [ "$health" = "healthy" ]; then
      echo "OK"
      exit 0
    fi
    if [ "$status" = "running" ] && [ "$health" = "starting" ]; then
      echo "starting"
      exit 0
    fi
    if [ "$status" = "running" ] && [ "$health" = "unhealthy" ]; then
      echo "restart"
      docker restart "$CONTAINER_NAME" >/dev/null 2>&1 || true
      exit 0
    fi
    echo "(re)create"
    run_container
  } >> "$WATCHDOG_LOG" 2>&1
}

# =====================
# Cập nhật theo tag mới (12h/lần)
# =====================
update_if_new() {
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
    echo "[$(date -Is)] Update: $current -> $latest"
    build_image_for_tag "$latest"
    run_container
    echo -n "$latest" > "$CLI_TAG_FILE"
    echo "[$(date -Is)] Done."
  } >> "$CRON_LOG" 2>&1
}

# =====================
# Cron: gọn gàng, dọn cái cũ
# =====================
setup_cron() {
  inf "$USE_INFO_CRON"
  ensure_pkgs
  local SCRIPT_PATH; SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
  local LANG_FLAG=""
  case "$LANGUAGE" in en|ru|cn) LANG_FLAG="--$LANGUAGE" ;; esac
  local BASH_BIN; BASH_BIN="$(command -v bash)"
  local FLOCK_BIN; FLOCK_BIN="$(command -v flock || true)"

  mkdir -p "$LOG_DIR"
  local OLD_MARK="# NEXUS_NODE_RECREATE:$WALLET_ADDRESS"
  local WD_MARK="# NEXUS_NODE_WATCHDOG:$WALLET_ADDRESS"
  local UP_MARK="# NEXUS_NODE_UPDATER:$WALLET_ADDRESS"
  local PATHS="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
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
    UP_CMD+="$FLOCK_BIN -n $LOCK_UP $BASH_BIN $SCRIPT_PATH \"$WALLET_ADDRESS\" --no-swap $LANG_FLAG --update >> $CRON_LOG 2>&1"
  else
    UP_CMD+="$BASH_BIN $SCRIPT_PATH \"$WALLET_ADDRESS\" --no-swap $LANG_FLAG --update >> $CRON_LOG 2>&1"
  fi
  local UP_EXPR="0 */12 * * *"
  local UP_JOB="$UP_EXPR $UP_CMD"

  local TMP; TMP="$(mktemp)"
  {
    crontab -l 2>/dev/null \
      | grep -Fv "$OLD_MARK" \
      | grep -Ev "docker[[:space:]]+restart[[:space:]]+$CONTAINER_NAME" \
      | grep -Fv "NEXUS_NODE_WATCHDOG:" \
      | grep -Fv "NEXUS_NODE_UPDATER:" \
      || true
    echo "$WD_MARK"; echo "$WD_JOB"
    echo "$UP_MARK"; echo "$UP_JOB"
  } > "$TMP"
  crontab "$TMP"; rm -f "$TMP"

  ok "$CRON_DONE"
  inf "Watchdog log: $WATCHDOG_LOG"
  inf "Update  log: $CRON_LOG"
}

# =====================
# Luồng chính theo MODE
# =====================
case "$MODE" in
  watchdog)      watchdog; exit 0 ;;
  update|smart-update) update_if_new; exit 0 ;;
  *)
    ensure_pkgs
    latest_now="$(fetch_latest_tag)"
    if [ -z "$latest_now" ]; then
      warn "Không lấy được tag mới nhất, vẫn build theo thời điểm hiện tại."
      latest_now="manual-$(date +%s)"
    fi
    build_image_for_tag "$latest_now"
    echo -n "$latest_now" > "$CLI_TAG_FILE"
    run_container
    [ "$SETUP_CRON" = 1 ] && setup_cron
    ok "===== Hoàn tất cài đặt ====="
    ;;
esac
