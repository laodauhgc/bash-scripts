#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Blockcast BEACON – installer / un‑installer for Ubuntu 20.04+ (x86_64 / arm64)
# -----------------------------------------------------------------------------
#   •  ./beacon.sh             # cài đặt / khởi động
#   •  ./beacon.sh -r          # gỡ cài đặt
# -----------------------------------------------------------------------------
set -euo pipefail

# -----------------------------  MÀU & ICON  ----------------------------------
NC="\033[0m"
RED="\033[31m";     ERR="❌"
GRN="\033[32m";     OK="✅"
YEL="\033[33m";     WARN="⚠️ "
BLU="\033[34m";     INF="ℹ️ "

log()       { printf "${BLU}${INF}  %s${NC}\n"  "$*"; }
success()   { printf "${GRN}${OK}  %s${NC}\n"   "$*"; }
warning()   { printf "${YEL}${WARN} %s${NC}\n"  "$*"; }
error()     { printf "${RED}${ERR}  %s${NC}\n"  "$*" >&2; }

# ---------------------------------  HÀM  -------------------------------------
usage() {
  cat <<EOF
Blockcast BEACON setup
  -r    Uninstall BEACON (docker‑compose down & xoá repo)
  -h    Show this help
EOF
  exit 1
}

need_root() {
  if [[ $EUID -ne 0 ]]; then
    error "Vui lòng chạy script bằng sudo hoặc với quyền root."
    exit 1
  fi
}

pkg_install() {
  # $1 = gói cần cài
  if ! command -v "$1" &>/dev/null; then
    log "Cài đặt gói $1 ..."
    apt-get update -qq && apt-get install -y "$1"
    success "$1 đã được cài."
  else
    log "$1 đã có sẵn."
  fi
}

install_docker() {
  if ! command -v docker &>/dev/null; then
    log "Docker chưa có. Tiến hành cài đặt..."
    wget -qO /tmp/docker.sh https://get.docker.com
    chmod +x /tmp/docker.sh
    /tmp/docker.sh
    usermod -aG docker "$SUDO_USER"
    success "Docker cài xong. Vui lòng đăng xuất & đăng nhập lại để áp dụng nhóm docker."
  else
    log "Docker đã cài."
  fi

  if ! systemctl is-active --quiet docker; then
    log "Khởi động dịch vụ Docker..."
    systemctl enable --now docker
    success "Docker service chạy."
  fi
}

install_compose() {
  pkg_install docker-compose
}

install_git() {
  pkg_install git
}

clone_repo() {
  local repo="beacon-docker-compose"
  if [[ -d $repo ]]; then
    warning "Thư mục $repo đã tồn tại – xoá để lấy bản mới."
    rm -rf "$repo"
  fi
  log "Cloning Blockcast BEACON repository..."
  git clone --depth=1 https://github.com/Blockcast/beacon-docker-compose.git "$repo"
  cd "$repo"
}

start_beacon() {
  log "Khởi động Blockcast BEACON (docker‑compose)..."
  docker-compose up -d
  success "BEACON containers đang chạy."
}

generate_keys() {
  log "Tạo hardware ID & challenge key..."
  sleep 15
  local out
  if ! out=$(docker-compose exec -T blockcastd blockcastd init 2>&1); then
    error "Không tạo được khóa."
    echo "$out"
    exit 1
  fi

  local hwid=$(echo "$out" | grep -i "Hardware ID"    | cut -d ':' -f2- | xargs)
  local chal=$(echo "$out" | grep -i "Challenge Key"  | cut -d ':' -f2- | xargs)
  local url=$( echo "$out" | grep -i "Registration URL" | cut -d ':' -f2- | xargs)
  [[ -z $hwid || -z $chal || -z $url ]] && { error "Không trích xuất được khoá."; echo "$out"; exit 1; }

  success "Blockcast BEACON setup hoàn tất!"
  cat <<EOF

====== Backup Blockcast ======
Hardware ID    : $hwid
Challenge Key  : $chal
Registration URL: $url

Build info:
$(echo "$out" | grep -iE "Commit|Build" | sed 's/^/  /')

Private keys (đừng chia sẻ):
  ~/.blockcast/certs/gw_challenge.key
  ~/.blockcast/certs/gateway.key
  ~/.blockcast/certs/gateway.crt
================================

Next steps:
  1. Truy cập https://app.blockcast.network/
  2. Dán Registration URL, hoặc nhập HWID & Challenge Key trong Manage Nodes > Register Node
  3. Nhập vị trí máy chủ (ví dụ: US, India, Indonesia...)
  4. Lưu lại thông tin Backup Blockcast ở trên.

Chú ý:
  • Node sẽ hiện trạng thái “Healthy” sau vài phút.
  • Bài test kết nối đầu tiên chạy sau ~6 giờ; phần thưởng bắt đầu tính sau 24 h.
EOF
}

uninstall_beacon() {
  need_root
  log "Gỡ cài đặt Blockcast BEACON..."
  if [[ -d beacon-docker-compose ]]; then
    (cd beacon-docker-compose && docker-compose down)
    rm -rf beacon-docker-compose
    success "Blockcast BEACON đã được gỡ."
  else
    warning "Không tìm thấy thư mục beacon-docker-compose – bỏ qua."
  fi
  exit 0
}

# ---------------------------  XỬ LÝ THAM SỐ  ---------------------------------
while getopts ":rh" opt; do
  case $opt in
    r) uninstall_beacon ;;
    h) usage ;;
    *) usage ;;
  esac
done

# -----------------------------  CHẠY CHÍNH  ----------------------------------
need_root
install_git
install_docker
install_compose
clone_repo
start_beacon
generate_keys
