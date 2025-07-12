#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

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

# ==== Phát hiện hệ điều hành và package manager (tối ưu cho Ubuntu) ====
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
    INSTALL_CMD="apt install -y --no-install-recommends"
    QUERY_CMD="dpkg -s"
  else
    die "Không tìm thấy package manager apt trên Ubuntu!"
  fi
}

# ==== Danh sách package cần thiết (tối ưu, chỉ giữ cốt lõi) ====
ESSENTIAL_PACKAGES=(
  # Dev & build cơ bản
  gcc make
  # System/network
  lsof traceroute tcpdump screen
  # Nén/giải nén
  unzip zip
  # Python-related (cơ bản)
  python3-pip
  # Khác
  curl wget git htop net-tools tmux build-essential cmake nano openssh-server rsync jq openssl ca-certificates
)

# ==== Cài đặt package cần thiết ====
install_essential_packages() {
  log "Cập nhật hệ thống..."
  eval "$UPDATE_CMD" >/dev/null 2>&1

  log "Bắt đầu cài đặt các gói cần thiết..."
  local to_install=()
  for pkg in "${ESSENTIAL_PACKAGES[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      to_install+=("$pkg")
    else
      warn "Gói $pkg đã được cài đặt. Bỏ qua."
    fi
  done

  if [ ${#to_install[@]} -gt 0 ]; then
    eval "$INSTALL_CMD ${to_install[*]}" || warn "Có lỗi khi cài đặt một số gói."
    log "Đã cài đặt các gói: ${to_install[*]}"
  else
    log "Tất cả các gói cần thiết đã được cài đặt."
  fi
}

# ==== Đảm bảo Node.js và npm luôn có sẵn hệ thống ====
ensure_system_nodejs() {
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    warn "nodejs và npm đã có sẵn ở mức hệ thống."
    return
  fi
  log "Cài đặt nodejs và npm ở mức hệ thống..."
  apt install -y --no-install-recommends nodejs npm
  log "Đã cài đặt nodejs và npm hệ thống."
}

# ==== Main ====
check_root
detect_os
install_essential_packages
ensure_system_nodejs

log "HOÀN TẤT! Hãy chạy: source ~/.bashrc (hoặc mở terminal mới) để các biến môi trường có hiệu lực."
