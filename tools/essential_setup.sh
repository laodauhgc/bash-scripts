#!/usr/bin/env bash
# ==============================================================================
# Ubuntu Development Environment Setup Script
# Version 3.0.0 – 26‑Jul‑2025
# ==============================================================================

set -Eeuo pipefail
trap 'echo -e "\033[0;31m❌ Lỗi tại dòng $LINENO: $BASH_COMMAND\033[0m"; exit 1' ERR

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8

# -------- Metadata -----------------------------------------------------------
SCRIPT_VERSION="3.0.0"
SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/tmp/${SCRIPT_NAME%.*}.log"
LOCK_FILE="/tmp/${SCRIPT_NAME%.*}.lock"
BACKUP_DIR="/tmp/setup_backup_$(date +%Y%m%d_%H%M%S)"

# -------- Colour -------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED='\033[0;31m'; C_GRN='\033[0;32m'; C_YLW='\033[1;33m'
  C_BLU='\033[0;34m'; C_CYA='\033[0;36m'; C_MAG='\033[0;35m'
  C_RST='\033[0m'; C_BOLD='\033[1m'
else C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_CYA=''; C_MAG=''; C_RST=''; C_BOLD=''; fi

# -------- Logger (màu ra màn hình, log sạch) ---------------------------------
_strip() { sed -r 's/\x1b\[[0-9;]*[mK]//g'; }
_log()   { local t; t=$(date '+%F %T'); echo -e "${2}[ ${t} ] $1${C_RST}"
           echo -e "$(_log_color_off "$1")" >> "$LOG_FILE"; }
_log_color_off(){ echo -e "$1" | _strip; }
info()   { _log "ℹ️  $1" "$C_BLU"; }
ok()     { _log "✅ $1" "$C_GRN"; }
warn()   { _log "⚠️  $1" "$C_YLW"; }
err()    { _log "❌ $1" "$C_RED"; }

# -------- Arg parse ----------------------------------------------------------
PROFILE="core" ; SKIP_NODE=0 ; BACKUP=0 ; DEBUG=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --profile)        PROFILE=${2,,}; shift 2 ;;
    -s|--skip-nodejs) SKIP_NODE=1; shift ;;
    --backup)         BACKUP=1; shift ;;
    -v|--verbose)     DEBUG=1; set -x; shift ;;
    -h|--help) cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION
Options:
  --profile {core|full}   Chế độ cài (core: mặc định, full: nhiều gói hơn)
  -s | --skip-nodejs      Bỏ qua cài Node.js
  --backup                Backup file cấu hình quan trọng
  -v | --verbose          Debug chi tiết
EOF
                exit 0 ;;
    *) err "Tùy chọn không hợp lệ: $1"; exit 1 ;;
  esac
done

# -------- Lock ---------------------------------------------------------------
[[ -e $LOCK_FILE ]] && { err "Đã chạy trước đó. Xoá $LOCK_FILE để tiếp tục."; exit 1; }
echo $$ > "$LOCK_FILE"; trap 'rm -f "$LOCK_FILE"' EXIT

# -------- Banner -------------------------------------------------------------
print_banner(){
  if command -v figlet >/dev/null 2>&1; then
    echo -e "${C_CYA}$(figlet -w 120 "Ubuntu Setup v$SCRIPT_VERSION")${C_RST}"
  else cat <<EOF
${C_CYA}${C_BOLD}
╔══════════════════════════════════════════════════════════╗
║                Ubuntu Setup Script v$SCRIPT_VERSION      ║
╚══════════════════════════════════════════════════════════╝
${C_RST}
EOF
  fi
}
print_banner

# -------- System checks ------------------------------------------------------
[[ $EUID -eq 0 ]] || { err "Cần chạy với sudo/root."; exit 1; }
. /etc/os-release
[[ $ID == ubuntu ]] || { err "Chỉ hỗ trợ Ubuntu."; exit 1; }

info "OS: $PRETTY_NAME – Kernel $(uname -r)"

# -------- APT helpers --------------------------------------------------------
apt_update(){ apt-get update -y -qq; }
apt_install(){ apt-get install -y --no-install-recommends "$@"; }

info "Cập nhật danh sách gói…"; apt_update

# -------- Package lists ------------------------------------------------------
CORE_PACKAGES=(
  build-essential git vim curl wget htop rsync zip unzip
  python3 python3-pip python3-venv
  openssh-client ca-certificates gnupg lsb-release software-properties-common
  plocate bash-completion
)

EXTRA_PACKAGES_FULL=(
  # CLI / debug
  tree tmux jq lsof iotop iproute2 net-tools dnsutils traceroute telnet nmap
  # build & libs
  make cmake pkg-config gcc g++ clang gdb autoconf automake libtool gettext
  libssl-dev libbz2-dev zlib1g-dev libreadline-dev libsqlite3-dev libffi-dev
  liblzma-dev libncurses5-dev libncursesw5-dev
  # compression
  p7zip-full rar unrar
  # fonts & comfort
  fonts-powerline nano less
  # docker
  docker.io docker-compose
  # ssh server & firewall
  openssh-server ufw
)

[[ $PROFILE == "full" ]] && PACKAGE_LIST=("${CORE_PACKAGES[@]}" "${EXTRA_PACKAGES_FULL[@]}") \
                         || PACKAGE_LIST=("${CORE_PACKAGES[@]}")

# -------- Install packages ---------------------------------------------------
to_install=()
for pkg in "${PACKAGE_LIST[@]}"; do dpkg -s "$pkg" &>/dev/null || to_install+=("$pkg"); done
if [[ ${#to_install[@]} -gt 0 ]]; then
  info "Cài ${#to_install[@]} gói (${PROFILE} profile)…"
  apt_install "${to_install[@]}"
else ok "Tất cả gói (${PROFILE}) đã cài."; fi

# -------- Node.js ------------------------------------------------------------
if [[ $SKIP_NODE -eq 0 ]]; then
  if command -v node >/dev/null; then warn "Node.js đã có: $(node -v)"
  else
    info "Cài Node.js LTS…"
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
    apt_install nodejs
    ok "Node.js $(node -v) / npm $(npm -v) đã sẵn sàng."
  fi
fi

# -------- Docker post step ---------------------------------------------------
if [[ $PROFILE == "full" && $SKIP_NODE -eq 0 ]]; then
  usermod -aG docker "${SUDO_USER:-root}" || true
  ok "Thêm user $(whoami) vào nhóm docker (cần logout/login)."
fi

# -------- Backup -------------------------------------------------------------
if [[ $BACKUP -eq 1 ]]; then
  info "Backup cấu hình về $BACKUP_DIR…"
  mkdir -p "$BACKUP_DIR"
  cp -a /etc/apt/sources.list{,.d} "$BACKUP_DIR/" 2>/dev/null || true
  cp -a "$HOME"/.{bashrc,profile} "$BACKUP_DIR/" 2>/dev/null || true
  ok "Backup hoàn tất."
fi

# -------- Clean up -----------------------------------------------------------
info "Dọn dẹp APT cache…"; apt-get autoremove -y -qq; apt-get clean -qq

ok "🎉 Hoàn tất – Môi trường $PROFILE đã sẵn sàng!"
echo "→ Xem log chi tiết: $LOG_FILE"
