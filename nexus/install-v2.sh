#!/bin/bash
set -e

# Version: v1.7.3 | Update 16/08/2025

# ===================== Cấu hình =====================
CONTAINER_NAME="nexus-node"             # basename
IMAGE_NAME="nexus-node:latest"

LOG_DIR="/root/nexus_logs"
LOG_FILE="$LOG_DIR/nexus.log"           # dùng khi chỉ 1 container
CRON_LOG="$LOG_DIR/cronjob.log"
WATCHDOG_LOG="$LOG_DIR/watchdog.log"

CREDENTIALS_DIR="/root/nexus_credentials"
NODE_ID_FILE="/root/nexus_node_id.txt"  # KHÔNG XÓA
SWAP_FILE="/swapfile"

STATE_DIR="/root/nexus_state"
CLI_TAG_FILE="$STATE_DIR/cli_tag.txt"   # tag CLI build gần nhất
REPLICA_FILE="$STATE_DIR/replicas.txt"  # số container
WALLET_FILE="$STATE_DIR/wallet.txt"     # wallet lưu lại cho cron

# Mặc định: luôn setup cron
SETUP_CRON=1

LANGUAGE="vi"
MODE="normal"      # normal | watchdog | update
REPLICAS=1
DO_CLEAN=0         # --rm

# ===================== Màu sắc & helpers =====================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok(){ echo -e "${GREEN}✅ $1${NC}"; }
err(){ echo -e "${RED}❌ $1${NC}"; }
warn(){ echo -e "${YELLOW}⚠️ $1${NC}"; }
inf(){ echo -e "${BLUE}ℹ️ $1${NC}"; }

# ===================== Bắt cờ ngôn ngữ sớm =====================
for arg in "$@"; do
  case "$arg" in --en) LANGUAGE="en" ;; --ru) LANGUAGE="ru" ;; --cn) LANGUAGE="cn" ;; esac
done

case $LANGUAGE in
  vi) BANNER="===== Cài Đặt Node Nexus v1.7.3 ====="
      USE_INFO_CRON="Cron: watchdog 5' và kiểm tra phiên bản mỗi 1h (chỉ update khi có tag mới)."
      CRON_DONE="Đã thiết lập cron."
      ERR_NO_INPUT="Lỗi: Cần cung cấp wallet hoặc node id. Dùng: $0 [<wallet|node-id>] [-n <số>] [--wallet <addr>] [--node-id <id>] [--rm]"
      PROMPT_NODE_ID="API Nexus có thể lỗi khi đăng ký. Nhập NODE_ID của bạn (Enter để bỏ qua): "
      ;;
  *)  BANNER="===== Nexus Node Setup v1.7.3 ====="
      USE_INFO_CRON="Cron: watchdog every 5m & hourly release check (update only on new tag)."
      CRON_DONE="Cron configured."
      ERR_NO_INPUT="Error: Provide a wallet or node id. Usage: $0 [<wallet|node-id>] [-n <num>] [--wallet <addr>] [--node-id <id>] [--rm]"
      PROMPT_NODE_ID="Nexus API may fail. Enter your NODE_ID (press Enter to skip): "
      ;;
esac
inf "$BANNER"

# ===================== Parse flags (KHÔNG shift sớm) =====================
WALLET_ADDRESS=""
NODE_ID_CLI=""
NO_SWAP=0
POSITIONAL=()

is_number(){ [[ "$1" =~ ^[0-9]+$ ]]; }
is_wallet_like(){ [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]] ; } # 0x + 40 hex
deduce_primary(){
  local s="$1"; [ -z "$s" ] && return 0
  if is_wallet_like "$s"; then WALLET_ADDRESS="$s"; else NODE_ID_CLI="$s"; fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wallet)
      [[ -z "${2-}" ]] && { err "Thiếu giá trị cho --wallet"; exit 1; }
      WALLET_ADDRESS="$2"; shift 2 ;;
    --wallet=*)
      WALLET_ADDRESS="${1#--wallet=}"; shift ;;
    --node-id)
      [[ -z "${2-}" ]] && { err "Thiếu giá trị cho --node-id"; exit 1; }
      NODE_ID_CLI="$2"; shift 2 ;;
    --node-id=*)
      NODE_ID_CLI="${1#--node-id=}"; shift ;;
    -n|--nodes)
      [[ -z "${2-}" ]] && { err "Thiếu giá trị cho $1"; exit 1; }
      is_number "$2" && [[ "$2" -gt 1 ]] || { err "$1 phải là số > 1"; exit 1; }
      REPLICAS="$2"; shift 2 ;;
    -n=*|--nodes=*)
      val="${1#*=}"; is_number "$val" && [[ "$val" -gt 1 ]] || { err "$1 phải là số > 1"; exit 1; }
      REPLICAS="$val"; shift ;;
    --no-swap) NO_SWAP=1; shift ;;
    --watchdog) MODE="watchdog"; shift ;;
    --smart-update|--update) MODE="update"; shift ;;
    --setup-cron) shift ;;   # luôn bật sẵn
    --rm) DO_CLEAN=1; shift ;;
    --en|--ru|--cn) shift ;; # đã xử lý
    --) shift; while [[ $# -gt 0 ]]; do POSITIONAL+=("$1"); shift; done ;;
    -*)
      warn "Bỏ qua flag không hỗ trợ: $1"; shift ;;
    *)
      POSITIONAL+=("$1"); shift ;;
  esac
done

# Positional đầu tiên có thể là wallet hoặc node-id nếu chưa truyền qua flag
if [[ ${#POSITIONAL[@]} -gt 0 && -z "$WALLET_ADDRESS" && -z "$NODE_ID_CLI" ]]; then
  deduce_primary "${POSITIONAL[0]}"
fi

# ===================== Thư mục/log =====================
mkdir -p "$LOG_DIR" "$CREDENTIALS_DIR" "$STATE_DIR"
[ -n "$WALLET_ADDRESS" ] && echo -n "$WALLET_ADDRESS" > "$WALLET_FILE"
echo -n "$REPLICAS" > "$REPLICA_FILE"

# ===================== Arch & tools =====================
ARCH=$(uname -m); inf "Phát hiện kiến trúc: $ARCH."
CLI_SUFFIX="linux-x86_64"; [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && CLI_SUFFIX="linux-arm64"

ensure_pkgs(){
  apt update
  apt install -y curl jq util-linux cron
  systemctl enable cron 2>/dev/null || true
  systemctl start  cron 2>/dev/null || true
}

# ===================== Swap (tùy chọn) =====================
create_swap(){
  if [[ "$(uname -s)" != "Linux" ]]; then warn "Không phải Linux, bỏ qua swap."; return 0; fi
  total_ram=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || true)
  [[ -z "$total_ram" ]] && total_ram=$(free -m | awk '/^Mem:/{print $2}')
  [[ -z "$total_ram" || "$total_ram" -le 0 ]] && { warn "Không xác định RAM, bỏ qua swap."; return 0; }
  inf "Tổng RAM phát hiện: ${total_ram} MB."
  if swapon --show | grep -q "$SWAP_FILE"; then
    current_swap=$(free -m | awk '/^Swap:/{print $2}')
    [[ -n "$current_swap" && "$current_swap" -ge "$total_ram" ]] && { inf "Swap đã tồn tại (${current_swap} MB), bỏ qua."; return 0; }
    swapoff "$SWAP_FILE" || true
  fi
  min_swap=$total_ram; max_swap=$((total_ram*2))
  available_disk=$(df -BM --output=avail "$(dirname "$SWAP_FILE")" | tail -n1 | grep -o '[0-9]\+')
  [[ -z "$available_disk" ]] && available_disk=0
  [[ "$available_disk" -lt "$min_swap" ]] && { warn "Không đủ dung lượng (${available_disk} MB < ${min_swap} MB), bỏ qua swap."; return 0; }
  swap_size=$min_swap; [[ "$available_disk" -ge "$max_swap" ]] && swap_size=$max_swap
  inf "Tạo swap ${swap_size} MB..."
  fallocate -l "${swap_size}M" "$SWAP_FILE" 2>/dev/null || dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$swap_size"
  chmod 600 "$SWAP_FILE"; mkswap "$SWAP_FILE" >/dev/null; swapon "$SWAP_FILE"
  grep -q "$SWAP_FILE" /etc/fstab 2>/dev/null || echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
  ok "Swap đã tạo & kích hoạt (${swap_size} MB)."
}
[[ "$NO_SWAP" == "1" ]] && warn "Bỏ qua tạo swap (--no-swap)." || create_swap

# ===================== Docker =====================
if ! command -v docker >/dev/null 2>&1; then
  inf "Cài đặt Docker..."
  apt update && apt install -y docker.io || { err "Không thể cài Docker."; exit 1; }
  systemctl enable docker || true; systemctl start docker || true
  systemctl is-active --quiet docker || { err "Docker daemon không chạy."; exit 1; }
fi
docker ps >/dev/null 2>&1 || { err "Không có quyền chạy Docker."; exit 1; }

# ===================== Tag & URL =====================
fetch_latest_tag(){ curl -fsSL https://api.github.com/repos/nexus-xyz/nexus-cli/releases/latest | jq -r '.tag_name // empty' 2>/dev/null || true; }
cli_url_for_tag(){ echo -n "https://github.com/nexus-xyz/nexus-cli/releases/download/$1/nexus-network-${CLI_SUFFIX}"; }

# ===================== Clean ( --rm ) =====================
purge_cron(){
  if command -v crontab >/dev/null 2>&1; then
    local TMP; TMP="$(mktemp)"
    crontab -l 2>/dev/null | grep -Fv "NEXUS_NODE_WATCHDOG" | grep -Fv "NEXUS_NODE_UPDATER" > "$TMP" || true
    crontab "$TMP" 2>/dev/null || true
    rm -f "$TMP"
    ok "Đã gỡ cron."
  else
    inf "Không tìm thấy 'crontab', bỏ qua gỡ cron."
  fi
}

clean_all(){
  warn "Đang dọn sạch containers & image (giữ $NODE_ID_FILE)..."
  # Xóa containers nexus-node & nexus-node-XX
  mapfile -t CNAMES < <(docker ps -a --format '{{.Names}}' | grep -E "^${CONTAINER_NAME}(-[0-9]+)?$" || true)
  if [[ ${#CNAMES[@]} -gt 0 ]]; then
    docker rm -f "${CNAMES[@]}" >/dev/null 2>&1 || true
  fi
  # Xóa image
  docker image rm -f "$IMAGE_NAME" >/dev/null 2>&1 || true
  # Xóa logs
  rm -rf "$LOG_DIR" 2>/dev/null || true; mkdir -p "$LOG_DIR"
  # Xóa state (trừ NODE_ID_FILE)
  rm -f "$CLI_TAG_FILE" "$REPLICA_FILE" "$WALLET_FILE" 2>/dev/null || true
  # Xóa credentials (để tránh rác), KHÔNG đụng NODE_ID_FILE
  rm -rf "$CREDENTIALS_DIR" 2>/dev/null || true; mkdir -p "$CREDENTIALS_DIR"
  ok "Đã dọn sạch."
}

# ===================== Build image =====================
build_image_for_tag(){
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

  cat > entrypoint.sh <<'ENTRYPOINT'
#!/bin/bash
set -e
mkdir -p /root/.nexus
touch /root/nexus.log || true

# Ưu tiên NODE_ID env -> file -> config.json
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

detect_cpus(){
  local cpus=1
  if command -v nproc >/dev/null 2>&1; then cpus="$(nproc 2>/dev/null || echo 1)"; fi
  if [ -r /sys/fs/cgroup/cpu.max ]; then
    read -r quota period < /sys/fs/cgroup/cpu.max || true
    if [ "${quota:-max}" != "max" ] && [ -n "$quota" ] && [ -n "$period" ] && [ "$period" -gt 0 ]; then
      local ceil=$(( (quota + period - 1) / period )); [ "$ceil" -gt 0 ] && [ "$ceil" -lt "$cpus" ] && cpus=$ceil
    fi
  elif [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ] && [ -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]; then
    local q p; q="$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null || echo -1)"
    p="$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null || echo -1)"
    if [ "$q" -gt 0 ] && [ "$p" -gt 0 ]; then
      local ceil=$(( (q + p - 1) / p )); [ "$ceil" -gt 0 ] && [ "$ceil" -lt "$cpus" ] && cpus=$ceil
    fi
  fi
  case "$cpus" in ''|*[!0-9]*) cpus=1 ;; esac
  [ "$cpus" -le 0 ] && cpus=1
  echo "$cpus"
}
CPU_COUNT="$(detect_cpus)"
MAX_THREADS="$CPU_COUNT"; [ "$MAX_THREADS" -gt 8 ] && MAX_THREADS=8
echo "ℹ️ CPU available: $CPU_COUNT -> using --max-threads $MAX_THREADS" | tee -a /root/nexus.log

nexus-network start --node-id "$NODE_ID_VAL" --max-threads "$MAX_THREADS" --headless >> /root/nexus.log 2>&1 &
sleep 2

if pidof nexus-network >/dev/null 2>&1; then
  echo "🚀 Node started. Log: /root/nexus.log" | tee -a /root/nexus.log
else
  echo "❌ Startup failed" | tee -a /root/nexus.log
  exit 1
fi

exec tail -f /root/nexus.log
ENTRYPOINT

  local BUILD_TS; BUILD_TS="$(date +%s)"
  docker build --pull -t "$IMAGE_NAME" --build-arg CACHE_BUST="$BUILD_TS" . >/dev/null
  cd - >/dev/null; rm -rf "$wd"
  ok "Xây dựng image $IMAGE_NAME thành công."
}

# ===================== Helpers đặt tên & replicas =====================
pad_width(){ local n="$1"; local w="${#n}"; [ "$w" -lt 2 ] && w=2; echo "$w"; }
container_name_for_index(){
  local idx="$1" total="$2"
  if [ "$total" -le 1 ]; then echo "$CONTAINER_NAME"; return; fi
  local w; w="$(pad_width "$total")"; printf "%s-%0${w}d" "$CONTAINER_NAME" "$idx"
}
log_file_for_index(){
  local idx="$1" total="$2"
  if [ "$total" -le 1 ]; then echo "$LOG_FILE"; return; fi
  local w; w="$(pad_width "$total")"; printf "%s/%s-%0${w}d.log" "$LOG_DIR" "$CONTAINER_NAME" "$idx"
}
get_replicas(){
  local n=""; [ -f "$REPLICA_FILE" ] && n="$(tr -d ' \t\r\n' < "$REPLICA_FILE" 2>/dev/null || true)"
  case "$n" in ''|*[!0-9]*) n="$REPLICAS" ;; esac; [ -z "$n" ] && n=1; echo "$n"
}

# ===================== Run 1 instance =====================
run_container_instance(){
  local NAME="$1"; local LOGPATH="$2"
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  mkdir -p "$(dirname "$LOGPATH")" "$CREDENTIALS_DIR"
  chmod 700 "$CREDENTIALS_DIR" || true
  : > "$LOGPATH"; chmod 644 "$LOGPATH"

  # Ưu tiên NODE_ID_FILE kể cả khi có wallet
  local WALLET=""; local NODE_ID=""
  if [ -n "$NODE_ID_CLI" ]; then NODE_ID="$NODE_ID_CLI"
  elif [ -f "$NODE_ID_FILE" ]; then NODE_ID="$(tr -d ' \t\r\n' < "$NODE_ID_FILE" 2>/dev/null || true)"
  fi
  # lấy wallet (nếu có)
  if [ -n "$WALLET_ADDRESS" ]; then WALLET="$WALLET_ADDRESS"
  elif [ -f "$WALLET_FILE" ]; then WALLET="$(tr -d ' \t\r\n' < "$WALLET_FILE" 2>/dev/null || true)"
  fi
  # fallback node id từ credentials
  [ -z "$NODE_ID" ] && [ -f "$CREDENTIALS_DIR/node_id" ] && NODE_ID="$(tr -d ' \t\r\n' < "$CREDENTIALS_DIR/node_id" 2>/dev/null || true)"
  [ -z "$NODE_ID" ] && [ -f "$CREDENTIALS_DIR/config.json" ] && NODE_ID="$(jq -r '.node_id // empty' "$CREDENTIALS_DIR/config.json" 2>/dev/null || true)"

  if [ -z "$WALLET" ] && [ -z "$NODE_ID" ]; then
    err "Thiếu WALLET hoặc NODE_ID. $ERR_NO_INPUT"; exit 1
  fi

  docker run -d --name "$NAME" \
    --restart unless-stopped \
    -v "$LOGPATH":/root/nexus.log:rw \
    -v "$CREDENTIALS_DIR":/root/.nexus:rw \
    -e WALLET_ADDRESS="$WALLET" \
    -e NODE_ID="$NODE_ID" \
    --health-cmd='pidof nexus-network || exit 1' \
    --health-interval=30s \
    --health-retries=3 \
    "$IMAGE_NAME" >/dev/null

  ok "Đã chạy container: $NAME"
  inf "Xem log: docker logs -f $NAME"

  # Nếu chưa có NODE_ID, chờ entrypoint tạo; nếu thất bại, hỏi tay (chỉ MODE normal)
  if [ -z "$NODE_ID" ]; then
    local TIMEOUT=120; local t=0
    inf "Đang chờ node ID... (timeout ${TIMEOUT}s)"
    while [ $t -lt $TIMEOUT ]; do
      if [ -f "$CREDENTIALS_DIR/node_id" ]; then
        NODE_ID="$(tr -d ' \t\r\n' < "$CREDENTIALS_DIR/node_id" 2>/dev/null || true)"
      elif [ -f "$CREDENTIALS_DIR/config.json" ]; then
        NODE_ID="$(jq -r '.node_id // empty' "$CREDENTIALS_DIR/config.json" 2>/dev/null || true)"
      fi
      if [ -n "$NODE_ID" ]; then
        echo -n "$NODE_ID" > "$NODE_ID_FILE"; ok "Đã lưu Node ID: $NODE_ID"; break
      fi
      sleep 5; t=$((t+5))
    done
    if [ -z "$NODE_ID" ]; then
      if [ "$MODE" = "normal" ]; then
        read -r -p "$PROMPT_NODE_ID" NODE_MANUAL
        if [ -n "$NODE_MANUAL" ]; then
          echo -n "$NODE_MANUAL" > "$NODE_ID_FILE"; ok "Đã nhận node id thủ công."
          docker rm -f "$NAME" >/dev/null 2>&1 || true
          NODE_ID_CLI="$NODE_MANUAL"
          run_container_instance "$NAME" "$LOGPATH"; return
        fi
      fi
      err "Không lấy được node ID tự động."; exit 1
    fi
  fi
}

# ===================== Run N instances =====================
run_containers(){
  local N="$1"; [ "$N" -le 0 ] && N=1
  if [ "$N" -eq 1 ]; then
    run_container_instance "$(container_name_for_index 1 1)" "$(log_file_for_index 1 1)"; return
  fi
  # Nếu chưa có node id => chạy instance đầu tiên lấy id
  local HAVE_ID=0
  if [ -s "$NODE_ID_FILE" ] || [ -n "$NODE_ID_CLI" ] || [ -s "$CREDENTIALS_DIR/node_id" ] || [ -s "$CREDENTIALS_DIR/config.json" ]; then
    HAVE_ID=1
  fi
  if [ "$HAVE_ID" -eq 0 ]; then
    local n1; n1="$(container_name_for_index 1 "$N")"; local l1; l1="$(log_file_for_index 1 "$N")"
    inf "Chưa có node ID — khởi chạy $n1 trước để tạo ID..."; run_container_instance "$n1" "$l1"
  fi
  local i; for i in $(seq 1 "$N"); do
    run_container_instance "$(container_name_for_index "$i" "$N")" "$(log_file_for_index "$i" "$N")"
  done
}

# ===================== Watchdog =====================
watchdog(){
  ensure_pkgs
  local N; N="$(get_replicas)"
  local i; for i in $(seq 1 "$N"); do
    local NAME; NAME="$(container_name_for_index "$i" "$N")"
    local status health
    status="$(docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null || echo "notfound")"
    if [ "$status" != "notfound" ]; then
      health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$NAME" 2>/dev/null || echo "none")"
    else health="unknown"; fi
    {
      echo "[$(date -Is)] $NAME status=$status health=$health"
      if [ "$status" = "running" ] && [ "$health" = "healthy" ]; then echo "OK"; continue; fi
      if [ "$status" = "running" ] && [ "$health" = "starting" ]; then echo "starting"; continue; fi
      if [ "$status" = "running" ] && [ "$health" = "unhealthy" ]; then echo "restart"; docker restart "$NAME" >/dev/null 2>&1 || true; continue; fi
      echo "(re)create $NAME"; run_container_instance "$NAME" "$(log_file_for_index "$i" "$N")"
    } >> "$WATCHDOG_LOG" 2>&1
  done

  # Dọn container thừa > N
  local extras; extras="$(docker ps -a --format '{{.Names}}' | grep -E "^${CONTAINER_NAME}-[0-9]+$" | sort || true)"
  if [ -n "$extras" ]; then
    local w; w="$(pad_width "$N")"
    local keep=""; local j; for j in $(seq 1 "$N"); do [ -z "$keep" ] && keep="$(printf "%0${w}d" "$j")" || keep="$keep|$(printf "%0${w}d" "$j")"; done
    while read -r nm; do echo "$nm" | grep -Eq "^${CONTAINER_NAME}-(${keep})$" && continue
      { echo "[$(date -Is)] remove extra $nm"; docker rm -f "$nm" >/dev/null 2>&1 || true; } >> "$WATCHDOG_LOG" 2>&1
    done <<< "$extras"
  fi
}

# ===================== Update nếu có tag mới =====================
update_if_new(){
  ensure_pkgs
  local latest; latest="$(fetch_latest_tag)"
  if [ -z "$latest" ]; then echo "[$(date -Is)] WARN: cannot fetch latest tag — skip." >> "$CRON_LOG"; return 0; fi
  local current=""; [ -f "$CLI_TAG_FILE" ] && current="$(tr -d ' \t\r\n' < "$CLI_TAG_FILE" 2>/dev/null || true)"
  if [ "$latest" = "$current" ] && docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "[$(date -Is)] No update (latest=$latest)." >> "$CRON_LOG"; return 0
  fi
  {
    local N; N="$(get_replicas)"
    echo "[$(date -Is)] Update: $current -> $latest"
    build_image_for_tag "$latest"
    echo -n "$latest" > "$CLI_TAG_FILE"
    run_containers "$N"
    echo "[$(date -Is)] Done."
  } >> "$CRON_LOG" 2>&1
}

# ===================== Cron (luôn bật) =====================
setup_cron(){
  inf "$USE_INFO_CRON"; ensure_pkgs
  mkdir -p "$LOG_DIR" "$STATE_DIR"

  local SCRIPT_PATH; SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
  local LANG_FLAG=""; case "$LANGUAGE" in en|ru|cn) LANG_FLAG="--$LANGUAGE" ;; esac
  local BASH_BIN; BASH_BIN="$(command -v bash)"
  local FLOCK_BIN; FLOCK_BIN="$(command -v flock || true)"

  # Ưu tiên node-id (nếu có), rồi wallet
  local ARG_ID=""; local ARG_WALLET=""
  [ -s "$NODE_ID_FILE" ] && ARG_ID="--node-id $(tr -d ' \t\r\n' < "$NODE_ID_FILE")"
  [ -s "$WALLET_FILE"  ] && ARG_WALLET="--wallet $(tr -d ' \t\r\n' < "$WALLET_FILE")"

  local WD_MARK="# NEXUS_NODE_WATCHDOG"
  local UP_MARK="# NEXUS_NODE_UPDATER"
  local PATHS="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  local LOCK_WD="/var/lock/nexus-watchdog.lock"
  local LOCK_UP="/var/lock/nexus-update.lock"

  local WD_CMD="$PATHS; "
  if [ -n "$FLOCK_BIN" ]; then
    WD_CMD+="$FLOCK_BIN -n $LOCK_WD $BASH_BIN $SCRIPT_PATH $ARG_ID $ARG_WALLET --no-swap $LANG_FLAG --watchdog >> $WATCHDOG_LOG 2>&1"
  else
    WD_CMD+="$BASH_BIN $SCRIPT_PATH $ARG_ID $ARG_WALLET --no-swap $LANG_FLAG --watchdog >> $WATCHDOG_LOG 2>&1"
  fi
  local WD_EXPR="*/5 * * * *"; local WD_JOB="$WD_EXPR $WD_CMD"

  local UP_CMD="$PATHS; "
  if [ -n "$FLOCK_BIN" ]; then
    UP_CMD+="$FLOCK_BIN -n $LOCK_UP $BASH_BIN $SCRIPT_PATH $ARG_ID $ARG_WALLET --no-swap $LANG_FLAG --update >> $CRON_LOG 2>&1"
  else
    UP_CMD+="$BASH_BIN $SCRIPT_PATH $ARG_ID $ARG_WALLET --no-swap $LANG_FLAG --update >> $CRON_LOG 2>&1"
  fi
  local UP_EXPR="0 * * * *"; local UP_JOB="$UP_EXPR $UP_CMD"

  local TMP; TMP="$(mktemp)"
  {
    crontab -l 2>/dev/null | grep -Fv "NEXUS_NODE_WATCHDOG" | grep -Fv "NEXUS_NODE_UPDATER" || true
    echo "$WD_MARK"; echo "$WD_JOB"
    echo "$UP_MARK"; echo "$UP_JOB"
  } > "$TMP"
  crontab "$TMP"; rm -f "$TMP"

  ok "$CRON_DONE"
  inf "Watchdog log: $WATCHDOG_LOG"
  inf "Update  log: $CRON_LOG"
}

# ===================== Main =====================
has_any_input(){
  [ -n "$NODE_ID_CLI" ] && return 0
  [ -s "$NODE_ID_FILE" ] && return 0
  [ -n "$WALLET_ADDRESS" ] && return 0
  [ -s "$WALLET_FILE" ] && return 0
  return 1
}

case "$MODE" in
  watchdog) ensure_pkgs; watchdog; exit 0 ;;
  update|smart-update) ensure_pkgs; update_if_new; exit 0 ;;
  *)
    # --rm: delete-only rồi thoát (không apt, không build/run, không setup_cron)
    if [ "$DO_CLEAN" = "1" ]; then
      purge_cron
      clean_all
      ok "Đã xóa xong theo --rm. Không cài lại."
      exit 0
    fi

    ensure_pkgs
    has_any_input || { err "$ERR_NO_INPUT"; exit 1; }
    latest_now="$(fetch_latest_tag)"; [ -z "$latest_now" ] && { warn "Không lấy được tag mới nhất, build theo thời điểm hiện tại."; latest_now="manual-$(date +%s)"; }
    build_image_for_tag "$latest_now"
    echo -n "$latest_now" > "$CLI_TAG_FILE"
    run_containers "$REPLICAS"
    setup_cron
    ok "===== Hoàn tất cài đặt (replicas=$REPLICAS) ====="
    ;;
esac
