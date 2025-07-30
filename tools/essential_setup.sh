#!/usr/bin/env bash
# ==============================================================================
# Ubuntu Core Development Environment Setup Script
# Version 3.2.2  –  30‑Jul‑2025
# ==============================================================================

set -Eeuo pipefail
trap 'echo -e "\033[0;31m❌  Lỗi tại dòng $LINENO: $BASH_COMMAND\033[0m" >&2' ERR

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8

# ---------- Metadata ----------------------------------------------------------
readonly SCRIPT_VERSION="3.2.2"
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/tmp/${SCRIPT_NAME%.*}.log"
readonly LOCK_FILE="/tmp/${SCRIPT_NAME%.*}.lock"
readonly BACKUP_DIR="/tmp/setup_backup_$(date +%Y%m%d_%H%M%S)"

# ---------- Colours (green theme) --------------------------------------------
if [[ -t 1 ]]; then
  CI='\033[0;32m'; CB='\033[1;32m'; CY='\033[1;33m'; CR='\033[0;31m'; CH='\033[1;32m'; CN='\033[0m'
else CI=''; CB=''; CY=''; CR=''; CH=''; CN=''; fi

strip() { sed -E 's/\x1B\[([0-9]{1,3}(;[0-9]{1,3})*)?[mK]//g'; }
log() {
  local t; t=$(date '+%F %T')
  echo -e "${2}[ $t ] $1${CN}"
  echo "[ $t ] $(strip "$1")" >> "$LOG_FILE"
  # Xoay log nếu quá lớn (>10MB)
  if [[ $(stat -f %z "$LOG_FILE" 2>/dev/null || stat -c %s "$LOG_FILE") -gt 10485760 ]]; then
    mv "$LOG_FILE" "${LOG_FILE}.old"
    touch "$LOG_FILE"
  fi
}
info() { log "ℹ️  $1" "$CI"; }
ok()   { log "✅ $1" "$CB"; }
warn() { log "⚠️  $1" "$CY"; }
err()  { log "❌ $1" "$CR"; }
header(){ log "$1" "$CH"; }

# ---------- Parse args --------------------------------------------------------
DEBUG=0; BACKUP=0; DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case $1 in
    -v|--verbose) DEBUG=1; set -x; shift ;;
    --backup)     BACKUP=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)    cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION
Cài đặt bộ Core + Dev headers cho Ubuntu.

Tùy chọn:
  --backup     Sao lưu cấu hình về $BACKUP_DIR
  -v|--verbose Bật debug
  --dry-run    Mô phỏng mà không thực hiện thay đổi
EOF
                  exit 0 ;;
    *) err "Tùy chọn không hợp lệ: $1"; exit 1 ;;
  esac
done

# ---------- Lock -------------------------------------------------------------
touch "$LOCK_FILE" || { err "Không thể tạo lock file $LOCK_FILE."; exit 1; }
exec 200>"$LOCK_FILE"
flock -n 200 || { err "Script đang chạy ở tiến trình khác. Xóa $LOCK_FILE nếu cần."; exit 1; }
trap 'rm -f "$LOCK_FILE"' EXIT

# ---------- Banner -----------------------------------------------------------
echo -e "${CH}
╔════════════════════════════════════════════════════════╗
║            Ubuntu Core Setup Script  v$SCRIPT_VERSION            ║
╚════════════════════════════════════════════════════════╝${CN}"

# ---------- Checks -----------------------------------------------------------
[[ $EUID -eq 0 ]] || { err "Hãy chạy bằng sudo/root."; exit 1; }
. /etc/os-release
[[ $ID == ubuntu ]] || { err "Chỉ hỗ trợ Ubuntu."; exit 1; }
[[ ${VERSION_ID%%.*} -ge 20 ]] || { err "Yêu cầu Ubuntu 20.04 hoặc mới hơn."; exit 1; }
info "Phát hiện: $PRETTY_NAME – Kernel $(uname -r)"

# ---------- APT helpers ------------------------------------------------------
apt_update() {
  info "Đang chạy apt update..."
  local retries=3
  for ((i=1; i<=retries; i++)); do
    if [[ $DRY_RUN -eq 1 ]]; then
      info "[DRY-RUN] Sẽ chạy: apt-get update"
      return 0
    fi
    if apt-get update -qq; then
      ok "apt update hoàn tất."
      return 0
    elif [[ $i -lt $retries ]]; then
      warn "apt update thất bại, thử lại ($i/$retries)..."
      sleep 2
    else
      warn "Thử lại với --fix-missing..."
      if apt-get update --fix-missing -qq; then
        ok "apt update (fix-missing) hoàn tất."
        return 0
      else
        err "apt update thất bại. Kiểm tra kết nối mạng hoặc /etc/apt/sources.list."
        exit 1
      fi
    fi
  done
}

apt_install() {
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[DRY-RUN] Sẽ cài: $@"
    return 0
  fi
  if apt-get install -y --no-install-recommends "$@"; then
    ok "Cài đặt gói hoàn tất."
  else
    err "Cài đặt gói thất bại."
    exit 1
  fi
}

# ---------- Fix dpkg/apt khóa nếu cần ----------------------------------------
if [[ $DRY_RUN -eq 0 ]]; then
  if dpkg --configure -a 2>/dev/null; then
    info "Đã sửa cấu hình dpkg (nếu cần)."
  else
    warn "Không thể sửa cấu hình dpkg, tiếp tục..."
  fi
fi

# ---------- Danh sách gói ----------------------------------------------------
PKGS_CORE=(build-essential git curl wget vim htop rsync bash-completion python3 python3-venv python3-pip ca-certificates gnupg software-properties-common plocate openssh-client)
PKGS_DEV=(libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev libffi-dev liblzma-dev libncursesw5-dev uuid-dev)
PKGS=("${PKGS_CORE[@]}" "${PKGS_DEV[@]}")

# ---------- Tiến trình chính -------------------------------------------------
touch "$LOG_FILE" || { err "Không thể ghi vào $LOG_FILE."; exit 1; }
apt_update

missing=(); for p in "${PKGS[@]}"; do dpkg -s "$p" &>/dev/null || missing+=("$p"); done
if [[ ${#missing[@]} -gt 0 ]]; then
  header "📦  Cài ${#missing[@]} gói thiếu..."
  apt_install "${missing[@]}"
else
  ok "Tất cả gói đã có."
fi

if [[ $DRY_RUN -eq 0 ]]; then
  info "Regenerating plocate DB..."
  if updatedb >/dev/null 2>&1; then
    ok "plocate DB updated."
  else
    warn "Không thể cập nhật plocate DB."
  fi
fi

if [[ $BACKUP -eq 1 ]]; then
  header "📂  Đang backup file cấu hình → $BACKUP_DIR"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[DRY-RUN] Sẽ backup: /etc/apt/sources.list{,.d} và $HOME/.{bashrc,profile} → $BACKUP_DIR"
  else
    mkdir -p "$BACKUP_DIR" || { err "Không thể tạo thư mục backup $BACKUP_DIR."; exit 1; }
    cp -a /etc/apt/sources.list{,.d} "$BACKUP_DIR/" 2>/dev/null || warn "Không thể backup sources.list."
    cp -a "$HOME"/.{bashrc,profile} "$BACKUP_DIR/" 2>/dev/null || warn "Không thể backup .bashrc hoặc .profile."
    ok "Backup xong."
  fi
fi

if [[ $DRY_RUN -eq 0 ]]; then
  info "Dọn dẹp APT cache..."
  apt-get autoremove -y -qq
  apt-get clean -qq
  ok "Dọn dẹp hoàn tất."
fi

header "🎉  Hoàn tất cài đặt!"
echo "  • Packages mới cài: ${#missing[@]}"
echo "  • Log chi tiết    : $LOG_FILE"
[[ $BACKUP -eq 1 ]] && echo "  • Backup          : $BACKUP_DIR"
