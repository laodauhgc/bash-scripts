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
    PKG_LIST_CMD="apt list --installed"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
    UPDATE_CMD="dnf makecache"
    INSTALL_CMD="dnf install -y"
    QUERY_CMD="rpm -q"
    PKG_LIST_CMD="dnf list installed"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
    UPDATE_CMD="yum makecache"
    INSTALL_CMD="yum install -y"
    QUERY_CMD="rpm -q"
    PKG_LIST_CMD="yum list installed"
  else
    die "Không tìm thấy package manager apt, dnf, hoặc yum!"
  fi
}

# ==== Hàm kiểm tra và cài đặt một package ====
try_install_pkg() {
  local pkg_alt="$1"
  shift
  local alt_names=("$@")
  local found_pkg=""
  # Check if already installed (by binary or package)
  for name in "$pkg_alt" "${alt_names[@]}"; do
    # Check by binary
    if command -v "$name" >/dev/null 2>&1; then
      warn "$name đã được cài đặt. Bỏ qua."
      return
    fi
    # Check by package manager
    if [ "$PKG_MANAGER" = "apt" ]; then
      if dpkg -s "$name" >/dev/null 2>&1; then
        warn "Gói $name đã được cài đặt. Bỏ qua."
        return
      fi
    else
      if rpm -q "$name" >/dev/null 2>&1; then
        warn "Gói $name đã được cài đặt. Bỏ qua."
        return
      fi
    fi
  done

  # Chọn tên gói khả dụng
  for name in "$pkg_alt" "${alt_names[@]}"; do
    if [ "$PKG_MANAGER" = "apt" ]; then
      if apt-cache show "$name" >/dev/null 2>&1; then
        found_pkg="$name"
        break
      fi
    else
      if "$PKG_MANAGER" info "$name" >/dev/null 2>&1; then
        found_pkg="$name"
        break
      fi
    fi
  done

  if [ -z "$found_pkg" ]; then
    warn "Không tìm thấy package nào phù hợp cho $pkg_alt (${alt_names[*]}) trên $OS_NAME."
    return 1
  fi

  log "Cài đặt $found_pkg..."
  if ! eval "$INSTALL_CMD $found_pkg" >/dev/null 2>&1; then
    error "Cài đặt $found_pkg thất bại."
    return 2
  fi
  log "Đã cài đặt $found_pkg thành công!"
}

# ==== Danh sách package ====
# Dạng: ["main_name" "alt1" "alt2"...]
ALL_PACKAGES=(
  # 1. Dev & build
  "gcc"
  "g++"
  "make"
  "clang"
  "man-db" "man"
  "shellcheck"
  # 2. System/network
  "lsof"
  "sysstat"
  "traceroute"
  "tcpdump"
  "ncdu"
  "screen"
  # 3. Nén/giải nén
  "unzip"
  "zip"
  "p7zip-full" "p7zip"
  "unrar"
  # 4. Dev tiện ích
  "fzf"
  "ripgrep" "rg"
  "fd-find" "fd"
  "bat" "batcat"
  # 5. Python-related
  "python3-pip" "pip"
  "python3-venv"
  "python3-virtualenv" "virtualenv"
  "ipython"
  # 6. File manager
  "mc"
  "dos2unix"
  # 7. Khác
  "gparted"
  "zsh"
  "neofetch"
  "fortune"
  # Đã có sẵn từ script cũ:
  "vim"
  "curl"
  "wget"
  "git"
  "htop"
  "net-tools"
  "tmux"
  "build-essential" "Development Tools" # (yum group)
  "cmake"
  "openjdk-11-jdk" "java-11-openjdk-devel"
  "npm"
  "nano"
  "openssh-server"
  "iotop"
  "iftop"
  "rsync"
  "jq"
  "pwgen"
  "nginx"
  "openssl"
  "ca-certificates"
)

# ==== Cài đặt toàn bộ package ====
install_all_packages() {
  log "Cập nhật hệ thống..."
  eval "$UPDATE_CMD" >/dev/null 2>&1

  local pkg_array=("${ALL_PACKAGES[@]}")
  local idx=0
  local total=${#pkg_array[@]}

  while [ $idx -lt $total ]; do
    local pkg="${pkg_array[$idx]}"
    local alt=()
    # Lấy các alt name tiếp theo (nếu có) cho đến khi gặp package mới
    while [ $((idx+1)) -lt $total ] && [[ "${pkg_array[$((idx+1))]}" != [a-zA-Z0-9]* ]]; do
      idx=$((idx+1))
      alt+=("${pkg_array[$idx]}")
    done

    try_install_pkg "$pkg" "${alt[@]}"
    idx=$((idx+1))
  done

  log "Cài đặt các gói cơ bản đã hoàn tất."
}

# ==== Cài đặt NVM ====
install_nvm() {
  if [ -d "$HOME/.nvm" ]; then
    warn "NVM đã được cài đặt. Bỏ qua."
    return
  fi
  log "Cài đặt NVM..."
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.2/install.sh | bash
  local nvm_init="
export NVM_DIR=\"\$HOME/.nvm\"
[ -s \"\$NVM_DIR/nvm.sh\" ] && \. \"\$NVM_DIR/nvm.sh\"
[ -s \"\$NVM_DIR/bash_completion\" ] && \. \"\$NVM_DIR/bash_completion\"
"
  if ! grep -q 'nvm.sh' "$HOME/.bashrc"; then
    echo "$nvm_init" >> "$HOME/.bashrc"
  fi
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
}

# ==== Cài đặt Node.js (qua NVM) ====
install_nodejs() {
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  if nvm ls 22 >/dev/null 2>&1; then
    warn "Node.js v22 đã được cài đặt. Bỏ qua."
  else
    log "Cài đặt Node.js v22..."
    nvm install 22
    nvm alias default 22
  fi
  nvm use 22
}

# ==== Cài Bun.js ====
install_bun() {
  if [ -d "$HOME/.bun" ]; then
    warn "Bun.js đã được cài đặt. Bỏ qua."
    return
  fi
  log "Cài đặt Bun.js..."
  curl -fsSL https://bun.sh/install | bash
  if ! grep -q '.bun/bin' "$HOME/.bashrc"; then
    echo 'export PATH="$PATH:$HOME/.bun/bin"' >> "$HOME/.bashrc"
  fi
  export PATH="$PATH:$HOME/.bun/bin"
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
install_all_packages
install_nvm
install_nodejs
install_bun
install_speedtest_cli

log "HOÀN TẤT! Hãy chạy: source ~/.bashrc để cập nhật biến môi trường."
