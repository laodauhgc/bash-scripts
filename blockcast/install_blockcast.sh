#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Blockcast BEACON – installer / uninstaller for Ubuntu 20.04+ (x86_64 / arm64)
# BẢN TỐI ƯU HOÁ: giao diện terminal đẹp, gọn;
# -----------------------------------------------------------------------------
#   •  ./beacon.sh             # cài đặt / khởi động
#   •  ./beacon.sh -r          # gỡ cài đặt
#   •  ./beacon.sh -h          # trợ giúp
# -----------------------------------------------------------------------------
set -euo pipefail

# -------------------------  CHẾ ĐỘ KHÔNG HỎI (NO-POPUP)  ---------------------
# Tự đồng ý mọi prompt của apt/needrestart/ucf để tránh popup OS.
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export NEEDRESTART_MODE=a
export UCF_FORCE_CONFFNEW=1
APT_FLAGS=(-y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confnew)

# -----------------------------  MÀU & ICON  ----------------------------------
if [[ -t 1 ]]; then TTY=1; else TTY=0; fi
NC="\033[0m"
BOLD="\033[1m"; DIM="\033[2m"
RED="\033[31m";     ERR="❌"
GRN="\033[32m";     OK="✅"
YEL="\033[33m";     WARN="⚠️ "
BLU="\033[34m";     INF="ℹ️ "
PRP="\033[35m";     DOT="•"

say()      { printf "%b%b  %s%b\n"     "$BLU" "$INF"  "$*" "$NC"; }
success()  { printf "%b%b  %s%b\n"     "$GRN" "$OK"   "$*" "$NC"; }
warn()     { printf "%b%b %s%b\n"      "$YEL" "$WARN" "$*" "$NC"; }
fail()     { printf "%b%b  %s%b\n"     "$RED" "$ERR"  "$*" "$NC" >&2; }
hr()       { printf "%b%b%b\n" "$DIM" "────────────────────────────────────────────────────────" "$NC"; }
section()  { hr; printf "%b%s%b\n" "$BOLD" "$*" "$NC"; hr; }

# -------------------------------  TIỆN ÍCH  ----------------------------------
TARGET_USER=${SUDO_USER:-${USER:-root}}
need_root() {
  if [[ ${EUID:-0} -ne 0 ]]; then
    fail "Vui lòng chạy script bằng sudo hoặc với quyền root."
    exit 1
  fi
}

run() {
  # Hiển thị lệnh gọn đẹp; ghi log chi tiết vào file nếu cần
  local msg="$1"; shift
  say "$msg"
  if "$@"; then
    success "OK"
  else
    local code=$?
    fail "Thất bại (mã $code)"
    return $code
  fi
}

pkg_install() {
  # $1 = gói cần cài
  if ! dpkg -s "$1" &>/dev/null; then
    say "Cài đặt gói ${BOLD}$1${NC} ..."
    apt-get update -qq
    apt-get install "${APT_FLAGS[@]}" "$1"
    success "$1 đã được cài."
  else
    say "$1 đã có sẵn."
  fi
}

# ---------------------------  DOCKER & COMPOSE  ------------------------------
COMPOSE="docker compose"  # ưu tiên plugin v2
ensure_docker() {
  if ! command -v docker &>/dev/null; then
    section "Cài Docker Engine"
    run "Tải script cài Docker" bash -c "wget -qO /tmp/docker.sh https://get.docker.com && chmod +x /tmp/docker.sh"
    run "Chạy script cài Docker (không hỏi)" /tmp/docker.sh
  else
    say "Docker đã cài."
  fi

  # Bật dịch vụ Docker
  if command -v systemctl &>/dev/null; then
    if ! systemctl is-active --quiet docker; then
      run "Khởi động dịch vụ Docker" systemctl enable --now docker
    fi
  else
    # Hệ không có systemd (hiếm)
    run "Khởi động Docker (service)" service docker start || true
  fi

  # Compose plugin v2 (docker compose)
  if docker compose version &>/dev/null; then
    COMPOSE="docker compose"
  elif command -v docker-compose &>/dev/null; then
    COMPOSE="docker-compose"
  else
    section "Cài Docker Compose"
    pkg_install docker-compose-plugin || pkg_install docker-compose
    if docker compose version &>/dev/null; then COMPOSE="docker compose"; else COMPOSE="docker-compose"; fi
  fi

  # Cho phép người dùng hiện tại dùng docker không cần sudo
  usermod -aG docker "$TARGET_USER" || true
}

# ------------------------------  GIT & TOOLS  --------------------------------
ensure_tools() {
  pkg_install ca-certificates
  pkg_install curl
  pkg_install wget
  pkg_install git
}

# -------------------------------  REPO  --------------------------------------
REPO_DIR="beacon-docker-compose"
clone_repo() {
  section "Tải Blockcast BEACON"
  if [[ -d "$REPO_DIR" ]]; then
    warn "Thư mục $REPO_DIR đã tồn tại – xoá để lấy bản mới."
    rm -rf "$REPO_DIR"
  fi
  run "Cloning repository" git clone --depth=1 https://github.com/Blockcast/beacon-docker-compose.git "$REPO_DIR"
  cd "$REPO_DIR"
}

# ---------------------------  DOCKER COMPOSE RUN  ----------------------------
compose_up() {
  section "Khởi động BEACON"
  if [[ "$COMPOSE" == "docker compose" ]]; then
    run "Khởi động dịch vụ" docker compose up -d --remove-orphans
  else
    run "Khởi động dịch vụ" docker-compose up -d --remove-orphans
  fi
}

wait_for_service() {
  # Đợi container blockcastd sẵn sàng (health=healthy hoặc running)
  local svc="${1:-blockcastd}"; local tries=90; local cid
  say "Chờ ${svc} sẵn sàng..."
  while (( tries-- > 0 )); do
    if cid=$($COMPOSE ps -q "$svc" 2>/dev/null || true); then
      if [[ -n "$cid" ]]; then
        state=$(docker inspect -f '{{.State.Health.Status}}{{if .State.Running}}{{print " running"}}{{end}}' "$cid" 2>/dev/null || echo "")
        if [[ "$state" =~ healthy || "$state" =~ running ]]; then
          success "${svc} đã sẵn sàng."
          return 0
        fi
      fi
    fi
    sleep 2
  done
  warn "${svc} có thể chưa sẵn sàng, vẫn tiếp tục."
  return 0
}

# -----------------------------  TRÍCH XUẤT KHOÁ  -----------------------------
extract_field() {
  # $1: regex label (không phân biệt hoa thường), $2: văn bản
  local pat="$1"; local text="$2"
  printf "%s" "$text" | grep -iE "${pat}[[:space:]]*:" -m1 | sed -E 's/^[^:]*:[[:space:]]*//' | xargs || true
}

generate_keys() {
  section "Tạo Hardware ID & Challenge Key"
  wait_for_service blockcastd || true

  local out
  if ! out=$($COMPOSE exec -T blockcastd blockcastd init 2>&1); then
    fail "Không tạo được khoá.\n$out"
    exit 1
  fi

  # Cố gắng trích xuất thân thiện, không dừng nếu thiếu trường.
  local hwid chal url
  hwid=$(extract_field 'Hardware[[:space:]]*ID' "$out")
  chal=$(extract_field 'Challenge[[:space:]]*Key' "$out")
  url=$(extract_field 'Registration[[:space:]]*URL' "$out")

  success "Blockcast BEACON setup hoàn tất!"

  printf "\n%b====== Backup Blockcast ======%b\n" "$BOLD" "$NC"
  printf "Hardware ID       : %s\n" "${hwid:-<không tự động trích xuất>}"
  printf "Challenge Key     : %s\n" "${chal:-<không tự động trích xuất>}"
  printf "Registration URL  : %s\n" "${url:-<không tự động trích xuất>}"
  printf "\nBuild info:\n"
  printf "%s\n" "$out" | grep -iE "Commit|Build" | sed 's/^/  /' || true

  cat <<'EOF'

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
  • Bài test kết nối đầu tiên chạy sau ~6 giờ; phần thưởng bắt đầu tính sau 24h.
EOF

  # Nếu không trích xuất được, hiển thị toàn bộ output để người dùng tự lưu (NHƯNG KHÔNG CÒN THÔNG BÁO ❌)
  if [[ -z "${hwid}${chal}${url}" ]]; then
    warn "Không thể tự động trích xuất khoá – bên dưới là toàn bộ kết quả từ 'blockcastd init':"
    printf "%s\n" "$out"
  fi
}

# -------------------------------  GỠ CÀI  ------------------------------------
uninstall_beacon() {
  need_root
  section "Gỡ cài đặt Blockcast BEACON"
  if [[ -d "$REPO_DIR" ]]; then
    (cd "$REPO_DIR" && $COMPOSE down || true)
    rm -rf "$REPO_DIR"
    success "Đã gỡ Blockcast BEACON."
  else
    warn "Không tìm thấy thư mục $REPO_DIR – bỏ qua."
  fi
  exit 0
}

# --------------------------------  USAGE  ------------------------------------
usage() {
  cat <<EOF
Blockcast BEACON setup (tối ưu hoá)
  -r    Gỡ cài đặt BEACON (compose down & xoá repo)
  -h    Hiển thị trợ giúp
EOF
  exit 0
}

# ---------------------------  XỬ LÝ THAM SỐ  ---------------------------------
while getopts ":rh" opt; do
  case $opt in
    r) uninstall_beacon ;;
    h) usage ;;
    *) usage ;;
  esac
done

# ------------------------------  CHẠY CHÍNH  ---------------------------------
section "Blockcast BEACON – Cài đặt nhanh"
need_root
ensure_tools
ensure_docker
clone_repo
compose_up
generate_keys
