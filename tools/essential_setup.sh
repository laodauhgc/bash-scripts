#!/usr/bin/env bash
# ==============================================================================
# Ubuntu Core Development Environment Setup Script
# Version 3.2.0  –  26‑Jul‑2025
# ==============================================================================

set -Eeuo pipefail
trap 'echo -e "\033[0;31m❌  Lỗi tại dòng $LINENO: $BASH_COMMAND\033[0m" >&2' ERR

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8

# ---------- Metadata ----------------------------------------------------------
readonly SCRIPT_VERSION="3.2.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/tmp/${SCRIPT_NAME%.*}.log"
readonly LOCK_FILE="/tmp/${SCRIPT_NAME%.*}.lock"
readonly BACKUP_DIR="/tmp/setup_backup_$(date +%Y%m%d_%H%M%S)"

# ---------- Colours (xanh lá chủ đạo) ----------------------------------------
if [[ -t 1 ]]; then
  CLR_INFO='\033[0;32m'     # green
  CLR_OK='\033[1;32m'       # bright green
  CLR_WARN='\033[1;33m'     # yellow
  CLR_ERR='\033[0;31m'      # red
  CLR_HL='\033[1;32m'       # header green bold
  CLR_RST='\033[0m'
else CLR_INFO=''; CLR_OK=''; CLR_WARN=''; CLR_ERR=''; CLR_HL=''; CLR_RST=''; fi

_strip() { sed -r 's/\x1b\[[0-9;]*[mK]//g'; }
_log()   { local ts; ts=$(date '+%F %T'); echo -e "${2}[ $ts ] $1${CLR_RST}";
           echo -e "$(_strip "$1")" >> "$LOG_FILE"; }
info()   { _log "ℹ️  $1" "$CLR_INFO"; }
ok()     { _log "✅ $1" "$CLR_OK"; }
warn()   { _log "⚠️  $1" "$CLR_WARN"; }
err()    { _log "❌ $1" "$CLR_ERR"; }
header() { _log "$1" "$CLR_HL"; }

# ---------- Argument parsing --------------------------------------------------
DEBUG=0; CREATE_BACKUP=0
parse_args(){
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v|--verbose) DEBUG=1; set -x; shift ;;
      --backup)     CREATE_BACKUP=1; shift ;;
      -h|--help) cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION
Cài đặt môi trường phát triển Core + Dev‑Headers cho Ubuntu.

Tùy chọn:
  --backup          Backup một số file cấu hình vào $BACKUP_DIR
  -v | --verbose    Bật debug (set -x)
  -h | --help       Hiển thị trợ giúp
EOF
                   exit 0 ;;
      *) err "Tùy chọn không hợp lệ: $1"; exit 1 ;;
    esac
  done
}

# ---------- Lock file ---------------------------------------------------------
[[ -e $LOCK_FILE ]] && { err "Đang chạy tiến trình khác.  Xóa $LOCK_FILE để tiếp tục."; exit 1; }
echo $$ >"$LOCK_FILE"; trap 'rm -f "$LOCK_FILE"' EXIT

# ---------- Banner -----------------------------------------------------------
banner(){
  if command -v figlet &>/dev/null; then
    echo -e "${CLR_HL}$(figlet -w 120 "Ubuntu Core Setup v$SCRIPT_VERSION")${CLR_RST}"
  else
    echo -e "${CLR_HL}
╔══════════════════════════════════════════════════════════╗
║            Ubuntu Core Setup Script  v$SCRIPT_VERSION             ║
╚══════════════════════════════════════════════════════════╝${CLR_RST}"
  fi
}
banner

# ---------- System checks -----------------------------------------------------
[[ $EUID -eq 0 ]] || { err "Cần chạy với sudo hoặc root."; exit 1; }
. /etc/os-release
[[ $ID == "ubuntu" ]] || { err "Hệ điều hành không phải Ubuntu."; exit 1; }

info "Phát hiện: $PRETTY_NAME – Kernel $(uname -r)"

# ---------- APT helpers -------------------------------------------------------
apt_update(){ info "Đang cập nhật package list… (có thể mất một lúc)"; apt-get update -y; ok "apt update hoàn tất."; }
apt_install(){ apt-get install -y --no-install-recommends "$@"; }

# ---------- Fix APT issues nếu có lock/dpkg lỗi --------------------------------
fix_apt(){
  info "Kiểm tra & sửa lỗi APT (nếu có)…"
  dpkg --configure -a  &>/dev/null || true
  apt-get update --fix-missing &>/dev/null || true
  apt-get install -f -y        &>/dev/null || true
  ok "APT health check xong."
}

# ---------- Package list ------------------------------------------------------
PACKAGE_LIST=(
  build-essential git curl wget vim htop rsync zip unzip bash-completion
  python3 python3-venv python3-pip ca-certificates gnupg software-properties-common
  plocate openssh-client
  libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev
  libffi-dev liblzma-dev libncursesw5-dev uuid-dev
)

# ---------- Main install flow -------------------------------------------------
main(){
  parse_args "$@"
  apt_update
  fix_apt

  # tính toán gói còn thiếu
  missing=(); for p in "${PACKAGE_LIST[@]}"; do dpkg -s "$p" &>/dev/null || missing+=("$p"); done

  if [[ ${#missing[@]} -gt 0 ]]; then
    header "📦  Cài đặt ${#missing[@]} gói cần thiết"
    apt_install "${missing[@]}"
  else
    ok "Tất cả gói đã được cài sẵn."
  fi

  # plocate DB
  info "Cập nhật CSDL plocate (updatedb)…"
  updatedb &>/dev/null || true

  # Backup nếu yêu cầu
  if [[ $CREATE_BACKUP == 1 ]]; then
    header "📦  Backup file cấu hình → $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    cp -a /etc/apt/sources.list{,.d} "$BACKUP_DIR/" 2>/dev/null || true
    cp -a "$HOME"/.{bashrc,profile}  "$BACKUP_DIR/" 2>/dev/null || true
    ok "Backup hoàn thành."
  fi

  # Clean APT cache
  info "Dọn dẹp cache APT…"
  apt-get autoremove -y -qq || true
  apt-get clean -qq

  # Report ngắn gọn
  header "📄  Tóm tắt:"
  echo   "  • Packages cài mới: ${#missing[@]}"
  echo   "  • Xem nhật ký chi tiết tại: $LOG_FILE"
  [[ $CREATE_BACKUP == 1 ]] && echo "  • Backup: $BACKUP_DIR"

  ok "🎉  Thiết lập môi trường Core Dev hoàn tất!"
}

main "$@"
