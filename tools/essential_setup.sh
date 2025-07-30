#!/usr/bin/env bash
# ==============================================================================
# 🚀 Ubuntu Core Development Environment Setup Script
# 📦 Version 3.2.5  –  30‑Jul‑2025
# 🌟 Installs core packages, Node.js, Bun.js, PM2, and Docker
# ==============================================================================

set -Eeuo pipefail
trap 'echo -e "\033[0;31m❌  Lỗi tại dòng $LINENO: $BASH_COMMAND\033[0m" >&2' ERR

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8

# ---------- Metadata ----------------------------------------------------------
readonly SCRIPT_VERSION="3.2.5"
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/tmp/${SCRIPT_NAME%.*}.log"
readonly LOCK_FILE="/tmp/${SCRIPT_NAME%.*}.lock"
readonly BACKUP_DIR="/tmp/setup_backup_$(date +%Y%m%d_%H%M%S)"
readonly NVM_VERSION="0.40.3"
readonly NODE_VERSION="22.17.1"
readonly BUN_VERSION="1.2.19"

# ---------- Colours (green theme) --------------------------------------------
if [[ -t 1 ]]; then
  CI='\033[0;32m'  # Info (Green)
  CB='\033[1;32m'  # Success (Bold Green)
  CY='\033[1;33m'  # Warning (Yellow)
  CR='\033[0;31m'  # Error (Red)
  CH='\033[1;32m'  # Header (Bold Green)
  CN='\033[0m'     # No Color
else
  CI=''; CB=''; CY=''; CR=''; CH=''; CN=''
fi

strip() { sed -E 's/\x1B\[([0-9]{1,3}(;[0-9]{1,3})*)?[mK]//g'; }
log() {
  local t; t=$(date '+%F %T')
  echo -e "${2}[$t] $1${CN}"
  echo "[$t] $(strip "$1")" >> "$LOG_FILE"
  # Rotate log if too large (>10MB)
  if [[ $(stat -f %z "$LOG_FILE" 2>/dev/null || stat -c %s "$LOG_FILE") -gt 10485760 ]]; then
    mv "$LOG_FILE" "${LOG_FILE}.old"
    touch "$LOG_FILE"
  fi
}
info() { log "ℹ️  $1" "$CI"; }
ok() { log "✅ $1" "$CB"; }  # Sửa lỗi cú pháp: thay "ok)" bằng "ok()"
warn() { log "⚠️  $1" "$CY"; }
err() { log "❌ $1" "$CR"; }
header() { log "🌟 $1" "$CH"; }

# ---------- Parse args --------------------------------------------------------
DEBUG=0; BACKUP=0; DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case $1 in
    -v|--verbose) DEBUG=1; set -x; shift ;;
    --backup)     BACKUP=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)    cat <<EOF
${CH}$SCRIPT_NAME v$SCRIPT_VERSION${CN}
Cài đặt bộ Core, Dev headers, Node.js, Bun.js, PM2, và Docker cho Ubuntu.

Tùy chọn:
  --backup     📂 Sao lưu cấu hình về $BACKUP_DIR
  -v|--verbose 🛠️ Bật chế độ debug
  --dry-run    🔍 Mô phỏng mà không thực hiện thay đổi
EOF
                  exit 0 ;;
    *) err "Tùy chọn không hợp lệ: $1"; exit 1 ;;
  esac
done

# ---------- Lock -------------------------------------------------------------
touch "$LOCK_FILE" || { err "🔐 Không thể tạo lock file $LOCK_FILE."; exit 1; }
exec 200>"$LOCK_FILE"
flock -n 200 || { err "🔒 Script đang chạy ở tiến trình khác. Xóa $LOCK_FILE nếu cần."; exit 1; }
trap 'rm -f "$LOCK_FILE"' EXIT

# ---------- Banner -----------------------------------------------------------
echo -e "${CH}
╔════════════════════════════════════════════════════════╗
║ 🚀  Ubuntu Core Setup Script  v$SCRIPT_VERSION  🚀            ║
╚════════════════════════════════════════════════════════╝${CN}"

# ---------- Checks -----------------------------------------------------------
[[ $EUID -eq 0 ]] || { err "🔐 Hãy chạy bằng sudo/root."; exit 1; }
. /etc/os-release
[[ $ID == ubuntu ]] || { err "🐧 Chỉ hỗ trợ Ubuntu."; exit 1; }
[[ ${VERSION_ID%%.*} -ge 20 ]] || { err "📋 Yêu cầu Ubuntu 20.04 hoặc mới hơn."; exit 1; }
info "🔍 Phát hiện: $PRETTY_NAME – Kernel $(uname -r)"

# ---------- Network check ----------------------------------------------------
if ! ping -c 1 google.com >/dev/null 2>&1; then
  err "🌐 Không có kết nối mạng. Vui lòng kiểm tra kết nối."
  exit 1
fi

# ---------- Disk space check -------------------------------------------------
if [[ $(df -h / | awk 'NR==2 {print $4}' | grep -o '[0-9]\+') -lt 5 ]]; then
  err "💾 Không đủ dung lượng đĩa (yêu cầu ít nhất 5GB)."
  exit 1
fi

# ---------- APT helpers ------------------------------------------------------
apt_update() {
  info "🔄 Đang chạy apt update..."
  local retries=3
  for ((i=1; i<=retries; i++)); do
    if [[ $DRY_RUN -eq 1 ]]; then
      info "[DRY-RUN] Sẽ chạy: apt-get update"
      return 0
    fi
    if apt-get update -qq; then
      ok "✅ apt update hoàn tất."
      return 0
    elif [[ $i -lt $retries ]]; then
      warn "⚠️ apt update thất bại, thử lại ($i/$retries)..."
      sleep 2
    else
      warn "⚠️ Thử lại với --fix-missing..."
      if apt-get update --fix-missing -qq; then
        ok "✅ apt update (fix-missing) hoàn tất."
        return 0
      else
        err "❌ apt update thất bại. Kiểm tra kết nối mạng hoặc /etc/apt/sources.list."
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
    ok "✅ Cài đặt gói hoàn tất."
  else
    err "❌ Cài đặt gói thất bại."
    exit 1
  fi
}

# ---------- Install JavaScript runtimes (Node.js, Bun, PM2) -------------------
install_js_runtimes() {
  header "🌐 Cài đặt Node.js, Bun.js, và PM2..."

  # Cài đặt nvm và Node.js
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[DRY-RUN] Sẽ cài nvm v$NVM_VERSION và Node.js v$NODE_VERSION"
  else
    if [[ ! -d "$HOME/.nvm" ]]; then
      info "📦 Cài đặt nvm v$NVM_VERSION..."
      if curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v$NVM_VERSION/install.sh | bash; then
        ok "✅ nvm cài đặt xong."
      else
        err "❌ Cài đặt nvm thất bại."
        exit 1
      fi
    else
      ok "✅ nvm đã được cài đặt."
    fi

    # Nạp nvm vào shell hiện tại
    [[ -s "$HOME/.nvm/nvm.sh" ]] && \. "$HOME/.nvm/nvm.sh"

    # Cài Node.js
    if ! command -v node >/dev/null 2>&1 || [[ $(nvm current) != "v$NODE_VERSION" ]]; then
      info "📦 Cài đặt Node.js v$NODE_VERSION..."
      if nvm install "$NODE_VERSION"; then
        ok "✅ Node.js v$NODE_VERSION cài đặt xong."
        node -v | grep -q "$NODE_VERSION" && ok "✅ Node.js version: $(node -v)"
        npm -v && ok "✅ npm version: $(npm -v)"
      else
        err "❌ Cài đặt Node.js thất bại."
        exit 1
      fi
    else
      ok "✅ Node.js v$NODE_VERSION đã được cài đặt."
    fi
  fi

  # Cài đặt PM2
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[DRY-RUN] Sẽ cài PM2 toàn cục"
  else
    if ! command -v pm2 >/dev/null 2>&1; then
      info "📦 Cài đặt PM2..."
      if npm install -g pm2; then
        ok "✅ PM2 cài đặt xong."
        pm2 -v && ok "✅ PM2 version: $(pm2 -v)"
      else
        err "❌ Cài đặt PM2 thất bại."
        exit 1
      fi
    else
      ok "✅ PM2 đã được cài đặt."
    fi
  fi

  # Cài đặt Bun.js
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[DRY-RUN] Sẽ cài Bun v$BUN_VERSION"
  else
    if ! command -v bun >/dev/null 2>&1; then
      info "📦 Cài đặt Bun v$BUN_VERSION..."
      if curl -fsSL https://bun.sh/install | bash; then
        ok "✅ Bun v$BUN_VERSION cài đặt xong."
        bun --version | grep -q "$BUN_VERSION" && ok "✅ Bun version: $(bun --version)"
      else
        err "❌ Cài đặt Bun thất bại."
        exit 1
      fi
    else
      ok "✅ Bun v$BUN_VERSION đã được cài đặt."
    fi
  fi
}

# ---------- Install Docker ---------------------------------------------------
install_docker() {
  header "🐳 Cài đặt Docker..."

  if [[ $DRY_RUN -eq 1 ]]; then
    info "[DRY-RUN] Sẽ cài Docker"
  else
    if command -v docker >/dev/null 2>&1; then
      ok "✅ Docker đã được cài đặt: $(docker --version)"
    else
      info "📦 Tải và cài đặt Docker..."
      local docker_script="/root/install_docker.sh"
      touch "$docker_script" || { err "❌ Không thể tạo file $docker_script."; exit 1; }
      if curl -sSL https://get.docker.com -o "$docker_script"; then
        chmod +x "$docker_script"
        if /bin/bash "$docker_script"; then
          rm -f "$docker_script"
          ok "✅ Docker cài đặt xong."
          docker --version && ok "✅ Docker version: $(docker --version)"
          # Thêm user vào nhóm docker
          if [[ -n "$SUDO_USER" ]]; then
            usermod -aG docker "$SUDO_USER" 2>/dev/null || warn "⚠️ Không thể thêm user vào nhóm docker."
            ok "✅ Đã thêm $SUDO_USER vào nhóm docker."
          fi
        else
          rm -f "$docker_script"
          err "❌ Cài đặt Docker thất bại."
          exit 1
        fi
      else
        rm -f "$docker_script"
        err "❌ Tải script Docker thất bại."
        exit 1
      fi
    fi
  fi
}

# ---------- Fix dpkg/apt khóa nếu cần ----------------------------------------
if [[ $DRY_RUN -eq 0 ]]; then
  if dpkg --configure -a 2>/dev/null; then
    info "🔧 Đã sửa cấu hình dpkg (nếu cần)."
  else
    warn "⚠️ Không thể sửa cấu hình dpkg, tiếp tục..."
  fi
fi

# ---------- Danh sách gói ----------------------------------------------------
PKGS_CORE=(build-essential git curl wget vim htop rsync bash-completion python3 python3-venv python3-pip ca-certificates gnupg software-properties-common plocate openssh-client)
PKGS_DEV=(libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev libffi-dev liblzma-dev libncursesw5-dev uuid-dev)
PKGS=("${PKGS_CORE[@]}" "${PKGS_DEV[@]}")

# ---------- Tiến trình chính -------------------------------------------------
touch "$LOG_FILE" || { err "📜 Không thể ghi vào $LOG_FILE."; exit 1; }
apt_update

missing=(); for p in "${PKGS[@]}"; do dpkg -s "$p" &>/dev/null || missing+=("$p"); done
if [[ ${#missing[@]} -gt 0 ]]; then
  header "📦 Cài ${#missing[@]} gói thiếu..."
  apt_install "${missing[@]}"
else
  ok "✅ Tất cả gói hệ thống đã có."
fi

if [[ $DRY_RUN -eq 0 ]]; then
  info "🔄 Regenerating plocate DB..."
  if updatedb >/dev/null 2>&1; then
    ok "✅ plocate DB updated."
  else
    warn "⚠️ Không thể cập nhật plocate DB."
  fi
fi

install_js_runtimes
install_docker

if [[ $BACKUP -eq 1 ]]; then
  header "📂 Sao lưu cấu hình → $BACKUP_DIR"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[DRY-RUN] Sẽ backup: /etc/apt/sources.list{,.d}, /etc/docker, $HOME/.{bashrc,profile,nvm} → $BACKUP_DIR"
  else
    mkdir -p "$BACKUP_DIR" || { err "❌ Không thể tạo thư mục backup $BACKUP_DIR."; exit 1; }
    cp -a /etc/apt/sources.list{,.d} "$BACKUP_DIR/" 2>/dev/null || warn "⚠️ Không thể backup sources.list."
    cp -a /etc/docker "$BACKUP_DIR/docker" 2>/dev/null || warn "⚠️ Không thể backup cấu hình Docker."
    cp -a "$HOME"/.{bashrc,profile,nvm} "$BACKUP_DIR/" 2>/dev/null || warn "⚠️ Không thể backup .bashrc, .profile, hoặc .nvm."
    ok "✅ Backup hoàn tất."
  fi
fi

if [[ $DRY_RUN -eq 0 ]]; then
  info "🧹 Dọn dẹp APT cache..."
  apt-get autoremove -y -qq
  apt-get clean -qq
  ok "✅ Dọn dẹp hoàn tất."
fi

# ---------- Báo cáo hoàn tất -------------------------------------------------
header "🎉 Hoàn tất cài đặt!"
echo -e "${CB}  • Gói hệ thống mới cài : ${#missing[@]}${CN}"
echo -e "${CB}  • Node.js             : $(node -v 2>/dev/null || echo 'chưa cài')${CN}"
echo -e "${CB}  • Bun.js             : $(bun --version 2>/dev/null || echo 'chưa cài')${CN}"
echo -e "${CB}  • PM2               : $(pm2 -v 2>/dev/null || echo 'chưa cài')${CN}"
echo -e "${CB}  • Docker            : $(docker --version 2>/dev/null || echo 'chưa cài')${CN}"
echo -e "${CB}  • Log chi tiết      : $LOG_FILE${CN}"
[[ $BACKUP -eq 1 ]] && echo -e "${CB}  • Backup            : $BACKUP_DIR${CN}"
