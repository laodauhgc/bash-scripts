#!/usr/bin/env bash
set -euo pipefail

# ==== Màu sắc cho log ====
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
RESET='\033[0m'

log()    { echo -e "${2:-$GREEN}$1${RESET}"; }
error()  { log "$1" "$RED"; }
warn()   { log "$1" "$YELLOW"; }
die()    { error "$1"; exit 1; }

# ==== Kiểm tra quyền root ====
check_root() {
  if [ "$EUID" -ne 0 ]; then
    die "Vui lòng chạy script với quyền root (sudo)."
  fi
}

# ==== Phát hiện hệ điều hành và package manager ====
detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    OS_NAME=$NAME
  else
    die "Không thể xác định hệ điều hành!"
  fi

  if command -v apt >/dev/null 2>&1; then
    PKG_MANAGER="apt"
    UPDATE_CMD="apt update -y"
    INSTALL_CMD="apt install -y"
    QUERY_CMD="dpkg -s"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
    UPDATE_CMD="dnf makecache"
    INSTALL_CMD="dnf install -y"
    QUERY_CMD="rpm -q"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
    UPDATE_CMD="yum makecache"
    INSTALL_CMD="yum install -y"
    QUERY_CMD="rpm -q"
  else
    die "Không tìm thấy package manager apt, dnf, hoặc yum!"
  fi
}

# ==== Danh sách package cơ bản ====
ESSENTIAL_PACKAGES=(
  # Dev & build
  gcc g++ make clang man-db shellcheck
  # System/network
  lsof sysstat traceroute tcpdump ncdu screen
  # Nén/giải nén
  unzip zip p7zip-full unrar
  # Dev tiện ích
  fzf ripgrep fd-find bat
  # Python-related
  python3-pip python3-venv python3-virtualenv ipython
  # File manager
  mc dos2unix
  # Khác
  gparted zsh neofetch fortune
  # Gói phổ biến khác
  vim curl wget git htop net-tools tmux build-essential cmake
  nano openssh-server iotop iftop rsync jq pwgen nginx openssl ca-certificates
)

# ==== Cài đặt package cơ bản ====
install_essential_packages() {
  log "Cập nhật hệ thống..."
  eval "$UPDATE_CMD" >/dev/null 2>&1

  log "Bắt đầu cài đặt các gói cần thiết..."
  local to_install=()
  for pkg in "${ESSENTIAL_PACKAGES[@]}"; do
    if [ "$PKG_MANAGER" = "apt" ]; then
      if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        to_install+=("$pkg")
      else
        warn "Gói $pkg đã được cài đặt. Bỏ qua."
      fi
    else
      if ! rpm -q "$pkg" >/dev/null 2>&1; then
        to_install+=("$pkg")
      else
        warn "Gói $pkg đã được cài đặt. Bỏ qua."
      fi
    fi
  done

  if [ ${#to_install[@]} -gt 0 ]; then
    eval "$INSTALL_CMD ${to_install[*]}" || warn "Có lỗi khi cài đặt một số gói."
    log "Đã cài đặt các gói: ${to_install[*]}"
  else
    log "Tất cả các gói cơ bản đã được cài đặt."
  fi
}

# ==== Đảm bảo Node.js và npm luôn có sẵn hệ thống ====
ensure_system_nodejs() {
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    warn "nodejs và npm đã có sẵn ở mức hệ thống."
    return
  fi
  log "Cài đặt nodejs và npm ở mức hệ thống..."
  if [ "$PKG_MANAGER" = "apt" ]; then
    apt install -y nodejs npm
  else
    $INSTALL_CMD nodejs npm || $INSTALL_CMD nodejs
  fi
  log "Đã cài đặt nodejs và npm hệ thống."
}

# ==== Cài đặt NVM (và Node.js dev - optional cho dev) ====
install_nvm_and_nodejs_dev() {
  # Nên chạy phần này dưới user chính, không phải root!
  local tgt_user="${SUDO_USER:-$USER}"
  local tgt_home
  tgt_home=$(eval echo "~$tgt_user")

  if [ ! -d "$tgt_home/.nvm" ]; then
    log "Cài đặt NVM cho user $tgt_user..."
    su - "$tgt_user" -c "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.2/install.sh | bash"
  else
    warn "NVM đã được cài cho $tgt_user. Bỏ qua."
  fi

  # Ghi biến môi trường vào .bashrc (nếu chưa có)
  if ! grep -q 'nvm.sh' "$tgt_home/.bashrc"; then
    echo 'export NVM_DIR="$HOME/.nvm"' >> "$tgt_home/.bashrc"
    echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"' >> "$tgt_home/.bashrc"
    echo '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"' >> "$tgt_home/.bashrc"
    log "Đã bổ sung cấu hình NVM vào $tgt_home/.bashrc"
  fi

  # Cài Node.js 22 qua nvm cho user dev
  su - "$tgt_user" -c "export NVM_DIR=\"$tgt_home/.nvm\"; [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"; nvm install 22 || true; nvm alias default 22 || true"
  log "Đã cài đặt Node.js v22 qua nvm cho user $tgt_user."
}

# ==== Cài Bun.js ====
install_bun() {
  local tgt_user="${SUDO_USER:-$USER}"
  local tgt_home
  tgt_home=$(eval echo "~$tgt_user")
  if [ -d "$tgt_home/.bun" ]; then
    warn "Bun.js đã được cài cho $tgt_user. Bỏ qua."
    return
  fi
  log "Cài đặt Bun.js cho $tgt_user..."
  su - "$tgt_user" -c "curl -fsSL https://bun.sh/install | bash"
  if ! grep -q '.bun/bin' "$tgt_home/.bashrc"; then
    echo 'export PATH="$PATH:$HOME/.bun/bin"' >> "$tgt_home/.bashrc"
    log "Đã bổ sung Bun vào PATH cho $tgt_home/.bashrc"
  fi
}

# ==== Cài speedtest-cli ====
install_speedtest_cli() {
  if command -v speedtest >/dev/null 2>&1; then
    warn "speedtest-cli đã được cài đặt. Bỏ qua."
    return
  fi
  log "Cài đặt speedtest-cli..."
  if [ "$PKG_MANAGER" = "apt" ]; then
    curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
    apt install -y speedtest || apt install -y speedtest-cli
  else
    $INSTALL_CMD speedtest-cli || $INSTALL_CMD speedtest || warn "Không tìm được gói speedtest-cli trên hệ thống này."
  fi
}

# ==== Main ====
check_root
detect_os
install_essential_packages
ensure_system_nodejs
install_nvm_and_nodejs_dev
install_bun
install_speedtest_cli

log "HOÀN TẤT! Hãy chạy: source ~/.bashrc (hoặc mở terminal mới) để các biến môi trường có hiệu lực."
log "Nếu muốn sử dụng Node.js nhiều phiên bản, dùng user thông thường (không phải root) và lệnh: nvm use 22"
