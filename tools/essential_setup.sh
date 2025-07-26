#!/usr/bin/env bash
# ==============================================================================
# Ubuntu Core Development Environment Setup Script
# Version 3.2.1  –  26‑Jul‑2025
# ==============================================================================

set -Eeuo pipefail
trap 'echo -e "\033[0;31m❌  Lỗi tại dòng $LINENO: $BASH_COMMAND\033[0m" >&2' ERR

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8

# ---------- Metadata ----------------------------------------------------------
readonly SCRIPT_VERSION="3.2.1"
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/tmp/${SCRIPT_NAME%.*}.log"
readonly LOCK_FILE="/tmp/${SCRIPT_NAME%.*}.lock"
readonly BACKUP_DIR="/tmp/setup_backup_$(date +%Y%m%d_%H%M%S)"

# ---------- Colours (green theme) --------------------------------------------
if [[ -t 1 ]]; then
  CI='\033[0;32m'; CB='\033[1;32m'; CY='\033[1;33m'; CR='\033[0;31m'; CH='\033[1;32m'; CN='\033[0m'
else CI=''; CB=''; CY=''; CR=''; CH=''; CN=''; fi

strip(){ sed -r 's/\x1b\[[0-9;]*[mK]//g'; }
log(){ local t; t=$(date '+%F %T'); echo -e "${2}[ $t ] $1${CN}"; echo -e "$(strip "$1")" >> "$LOG_FILE"; }
info() { log "ℹ️  $1" "$CI"; }
ok()   { log "✅ $1" "$CB"; }
warn() { log "⚠️  $1" "$CY"; }
err()  { log "❌ $1" "$CR"; }
header(){ log "$1" "$CH"; }

# ---------- Parse args --------------------------------------------------------
DEBUG=0; BACKUP=0
while [[ $# -gt 0 ]]; do
  case $1 in
    -v|--verbose) DEBUG=1; set -x; shift ;;
    --backup)     BACKUP=1; shift ;;
    -h|--help) cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION
Cài đặt bộ Core + Dev headers cho Ubuntu.

Tùy chọn:
  --backup     Sao lưu cấu hình về $BACKUP_DIR
  -v|--verbose Bật debug
EOF
               exit 0 ;;
    *) err "Tùy chọn không hợp lệ: $1"; exit 1 ;;
  esac
done

# ---------- Lock -------------------------------------------------------------
[[ -e $LOCK_FILE ]] && { err "Script khác đang chạy.  Xoá $LOCK_FILE để tiếp tục."; exit 1; }
echo $$ >"$LOCK_FILE"; trap 'rm -f "$LOCK_FILE"' EXIT

# ---------- Banner -----------------------------------------------------------
echo -e "${CH}
╔════════════════════════════════════════════════════════╗
║            Ubuntu Core Setup Script  v$SCRIPT_VERSION            ║
╚════════════════════════════════════════════════════════╝${CN}"

# ---------- Checks -----------------------------------------------------------
[[ $EUID -eq 0 ]] || { err "Hãy chạy bằng sudo/root."; exit 1; }
. /etc/os-release
[[ $ID == ubuntu ]] || { err "Chỉ hỗ trợ Ubuntu."; exit 1; }
info "Phát hiện: $PRETTY_NAME – Kernel $(uname -r)"

# ---------- APT helpers ------------------------------------------------------
apt_update(){
  info "Đang chạy apt update…"
  if apt-get update -qq; then
    ok "apt update hoàn tất."
  else
    warn "apt update lỗi – thử lại với --fix-missing…"
    apt-get update --fix-missing -qq || { err "apt update thất bại. Kiểm tra kết nối mạng hoặc sources.list."; exit 1; }
    ok "apt update (fix-missing) hoàn tất."
  fi
}
apt_install(){ apt-get install -y --no-install-recommends "$@"; }

# ---------- Fix dpkg/apt khóa nếu cần ----------------------------------------
dpkg --configure -a  &>/dev/null || true

# ---------- Danh sách gói ----------------------------------------------------
PKGS=(
  build-essential git curl wget vim htop rsync zip unzip bash-completion
  python3 python3-venv python3-pip ca-certificates gnupg software-properties-common
  plocate openssh-client
  libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev
  libffi-dev liblzma-dev libncursesw5-dev uuid-dev
)

# ---------- Tiến trình chính -------------------------------------------------
apt_update

missing=(); for p in "${PKGS[@]}"; do dpkg -s "$p" &>/dev/null || missing+=("$p"); done
if [[ ${#missing[@]} -gt 0 ]]; then
  header "📦  Cài ${#missing[@]} gói thiếu…"
  apt_install "${missing[@]}"
else ok "Tất cả gói đã có."; fi

info "Regenerating plocate DB…"; updatedb &>/dev/null || true

if [[ $BACKUP -eq 1 ]]; then
  header "📂  Đang backup file cấu hình → $BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"
  cp -a /etc/apt/sources.list{,.d} "$BACKUP_DIR/" 2>/dev/null || true
  cp -a "$HOME"/.{bashrc,profile} "$BACKUP_DIR/" 2>/dev/null || true
  ok "Backup xong."
fi

info "Dọn dẹp APT cache…"; apt-get autoremove -y -qq; apt-get clean -qq

header "🎉  Hoàn tất cài đặt!"
echo  "  • Packages mới cài: ${#missing[@]}"
echo  "  • Log chi tiết    : $LOG_FILE"
[[ $BACKUP -eq 1 ]] && echo "  • Backup          : $BACKUP_DIR"
