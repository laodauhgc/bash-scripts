#!/bin/bash
set -euo pipefail

# Màu sắc
GREEN='\e[32m'
RED='\e[31m'
YELLOW='\e[33m'
RESET='\e[0m'

# Biến
LOG_FILE="/var/log/docker_install.log"
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
DOCKER_VERSION="latest" # Có thể thay đổi nếu cần
DOCKER_COMPOSE_VERSION="latest" # Có thể thay đổi nếu cần

# Hàm ghi log
log() {
    local msg="$1"
    local color="${2:-$GREEN}"
    echo -e "${color}${msg}${RESET}"
    echo "[$TIMESTAMP] $msg" >> "$LOG_FILE"
}

# Kiểm tra quyền root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log "Lỗi: Vui lòng chạy script với quyền root (sudo)." "$RED"
        exit 1
    fi
}

# Phát hiện OS và package manager
detect_os() {
    if command -v apt >/dev/null 2>&1; then
        PKG_MANAGER="apt"
        OS="debian"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
        OS="redhat"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
        OS="fedora"
    elif grep -q "SUSE" /etc/os-release; then
        PKG_MANAGER="zypper"
        OS="suse"
    else
        log "Lỗi: Hệ điều hành không được hỗ trợ!" "$RED"
        exit 1
    fi
}

# Cài đặt Docker trên Debian/Ubuntu
install_docker_debian() {
    log "Đang cài đặt Docker trên Debian/Ubuntu..."
    apt install -y apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release

    # Get the codename in a way that works on more systems.
    UBUNTU_CODENAME=$(lsb_release -cs)

    # Remove all existing files in /etc/apt/sources.list.d/
    sudo rm -f /etc/apt/sources.list.d/*

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian ${UBUNTU_CODENAME} stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Clean and update apt *after* adding the repo
    sudo apt clean
    sudo apt update -y

    apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    log "Cài đặt Docker thành công trên Debian/Ubuntu!"
}

# Cài đặt Docker trên RedHat/CentOS/Fedora
install_docker_redhat() {
    log "Đang cài đặt Docker trên RedHat/CentOS/Fedora..."
    yum update -y
    yum install -y yum-utils
    yum config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo # For Fedora
    yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin --nobest
    log "Cài đặt Docker thành công trên RedHat/CentOS/Fedora!"
}

# Cài đặt Docker trên SUSE
install_docker_suse() {
    log "Đang cài đặt Docker trên SUSE..."
    zypper refresh
    zypper install -y docker
    systemctl start docker
    systemctl enable docker
    log "Cài đặt Docker thành công trên SUSE!"
}


# Cài đặt Docker Compose (Sử dụng plugin docker compose)
install_docker_compose() {
    log "Đang cài đặt Docker Compose..."
    # Docker Compose is now a plugin, so we just ensure docker is configured correctly
    if ! docker compose version >/dev/null 2>&1; then
      log "Docker compose plugin is not installed correctly. Please check your docker installation." "$RED"
    else
      log "Docker Compose đã được cài đặt!"
    fi
}

# Cấu hình dịch vụ Docker
configure_docker() {
    log "Đang cấu hình Docker..."
    groupadd docker 2>/dev/null
    usermod -aG docker "$USER"
    systemctl enable docker
    systemctl start docker
    log "Cấu hình Docker hoàn tất!"
}


# Thực thi cài đặt Docker
install_docker() {
    case "$OS" in
        debian)
            install_docker_debian
            ;;
        redhat|fedora)
            install_docker_redhat
            ;;
        suse)
            install_docker_suse
            ;;
        *)
            log "Lỗi: Hệ điều hành không được hỗ trợ!" "$RED"
            exit 1
            ;;
    esac
}


# Thực thi
check_root
detect_os
install_docker
install_docker_compose
configure_docker

log "Hoàn tất cài đặt và cấu hình Docker và Docker Compose!"

# Update 30.03.2025
