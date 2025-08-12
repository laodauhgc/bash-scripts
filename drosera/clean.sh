#!/usr/bin/env bash
# Drosera cleaner v1.1
# Mặc định: giữ Docker, Bun, Foundry. Dùng --all nếu muốn xoá cả các tool này.

set -Eeuo pipefail
trap 'printf "[%(%F %T)T] ERROR at line %s: %s\n" -1 "$LINENO" "$BASH_COMMAND" >&2' ERR
[[ $EUID -eq 0 ]] || { echo "Cần chạy bằng root/sudo"; exit 1; }

# ====== Paths & defaults (khớp với installer của bạn) ======
TRAP_DIR="${TRAP_DIR:-/root/my-drosera-trap}"
OP_DIR="${OP_DIR:-/root/Drosera-Network}"
STATE_JSON="${STATE_JSON:-/root/drosera_state.json}"
SUMMARY_JSON="${SUMMARY_JSON:-/root/drosera_summary.json}"
DRO_HOME="${DRO_HOME:-/root/.drosera}"            # chứa drosera & droseraup
DRO_BIN_DIR="${DRO_BIN_DIR:-$DRO_HOME/bin}"
OP_CONTAINER="${OP_CONTAINER:-drosera-operator}"
OP_IMAGE_RE="${OP_IMAGE_RE:-ghcr.io/drosera-network/drosera-operator}"

# ====== Flags ======
YES=0
NUKE_ALL=0        # xoá Bun/Foundry + fallback /usr/local/bin/docker-compose
DRY_RUN=0
PURGE_DOCKER_REPO=0 # nguy hiểm: xóa repo Docker trong apt (không dùng mặc định)

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) YES=1; shift ;;
    --all) NUKE_ALL=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --purge-docker-repo) PURGE_DOCKER_REPO=1; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

log(){ printf '[%(%F %T)T] %s\n' -1 "$*"; }
run(){ if (( DRY_RUN )); then echo "DRY: $*"; else eval "$@"; fi; }
exists(){ command -v "$1" >/dev/null 2>&1; }

# ====== Confirm ======
if (( YES==0 )); then
  echo "Script sẽ xoá:"
  echo " - Container/image/volume Docker có tên hoặc repo chứa 'drosera'"
  echo " - Thư mục dự án: $OP_DIR"
  echo " - Thư mục trap:  $TRAP_DIR"
  echo " - Thư mục Drosera home/binary: $DRO_HOME"
  echo " - File state/log: $STATE_JSON, $SUMMARY_JSON, /root/drosera_setup_*.log"
  echo " - Gỡ các dòng PATH thêm vào ~/.bashrc trỏ tới ~/.drosera/bin ~/.bun/bin ~/.foundry/bin"
  if (( NUKE_ALL )); then
    echo " - (ALL) Xoá ~/.bun, ~/.foundry, ~/.cache/foundry, và /usr/local/bin/docker-compose nếu là bản fallback"
  fi
  read -rp "Bạn chắc chắn muốn tiếp tục? (gõ YES): " ans
  [[ "$ans" == "YES" ]] || { echo "Huỷ."; exit 1; }
fi

# ====== 1) Dừng & xoá Docker resources ======
if exists docker; then
  log "Dừng container $OP_CONTAINER (nếu có)..."
  run "docker ps -a --format '{{.Names}}' | grep -xq '$OP_CONTAINER' && docker rm -f '$OP_CONTAINER' || true"

  log "Xoá mọi container dùng image $OP_IMAGE_RE ..."
  run "docker ps -a --format '{{.ID}} {{.Image}}' | awk 'index(tolower(\$2), tolower(\"$OP_IMAGE_RE\")) {print \$1}' | xargs -r docker rm -f"

  log "Xoá các volume liên quan đến drosera..."
  run "docker volume ls -q | awk 'tolower(\$0) ~ /drosera/ {print}' | xargs -r docker volume rm -f"

  log "Xoá image $OP_IMAGE_RE ..."
  run "docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | awk 'index(tolower(\$1), tolower(\"$OP_IMAGE_RE\")) {print \$2}' | xargs -r docker rmi -f || true"
else
  log "Docker không có, bỏ qua bước Docker."
fi

# ====== 2) Xoá thư mục dự án & trap ======
log "Xoá thư mục dự án Operator: $OP_DIR"
run "rm -rf --one-file-system -- '$OP_DIR'"

log "Xoá thư mục trap/foundry: $TRAP_DIR"
run "rm -rf --one-file-system -- '$TRAP_DIR'"

# ====== 3) Xoá Drosera home/binary & logs/state ======
log "Xoá Drosera home/binary: $DRO_HOME"
run "rm -rf --one-file-system -- '$DRO_HOME'"

log "Xoá file state/json: $STATE_JSON, $SUMMARY_JSON"
run "rm -f -- '$STATE_JSON' '$SUMMARY_JSON'"

log "Xoá log cài đặt trước đó: /root/drosera_setup_*.log"
run "rm -f -- /root/drosera_setup_*.log"

# ====== 4) Dọn PATH đã thêm trong ~/.bashrc ======
if [[ -f /root/.bashrc ]]; then
  log "Gỡ các dòng PATH trỏ tới ~/.drosera/bin ~/.bun/bin ~/.foundry/bin trong /root/.bashrc"
  run "sed -i -e '/\\/root\\/\\.drosera\\/bin/d' -e '/\\/root\\/\\.bun\\/bin/d' -e '/\\/root\\/\\.foundry\\/bin/d' /root/.bashrc"
fi

# ====== 5) Tuỳ chọn: xoá toolchain & compose fallback ======
if (( NUKE_ALL )); then
  log "(ALL) Xoá Bun & Foundry (có thể cài lại sau)"
  run "rm -rf --one-file-system -- /root/.bun /root/.foundry /root/.cache/foundry"

  log "(ALL) Gỡ docker-compose fallback ở /usr/local/bin nếu có"
  if [[ -x /usr/local/bin/docker-compose ]]; then
    run "rm -f /usr/local/bin/docker-compose"
  fi
fi

# ====== 6) (tuỳ chọn) gỡ repo Docker khỏi APT ======
if (( PURGE_DOCKER_REPO )); then
  log "(Cẩn trọng) Gỡ repo Docker trong APT"
  run "rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.gpg || true"
  run "apt-get update -y || true"
fi

log "DONE. Môi trường Drosera/Operator đã được làm sạch."
if (( DRY_RUN )); then
  log "DRY-RUN: không có thay đổi thật sự nào được áp dụng."
else
  log "Bạn có thể chạy lại script cài đặt mới ngay bây giờ."
fi
