#!/bin/bash
set -euo pipefail

# Màu sắc cho thông báo
GREEN='\e[32m'
RED='\e[31m'
YELLOW='\e[33m'
RESET='\e[0m'

# Biến
LOG_FILE="/var/log/ubuntu_essential_install.log"
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
ESSENTIAL_PACKAGES=(
  "vim"
  "curl"
  "wget"
  "git"
  "htop"
  "net-tools"
  "ufw" # Note: UFW is installed but NOT configured
  "fail2ban" # Note: Fail2ban is NOT enabled
  "tmux"
  "build-essential"
  "cmake"
  "python3-pip"
  "python3-venv"
  "openjdk-11-jdk"
  "npm" # We will use npm from nvm
  "unzip"
  "zip"
  "tree"
  "nano"
  "openssh-server"
  "iotop"
  "iftop"
  "rsync"
  "jq"
  "pwgen"
  "nginx"
  "openssl"  # Added
  "ca-certificates" # Added
)

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

# Cập nhật hệ thống
update_system() {
  log "Bắt đầu cập nhật hệ thống..."
  apt update -y >/dev/null 2>&1 || { log "Lỗi: Cập nhật hệ thống thất bại!" "$RED"; exit 1; }
  apt upgrade -y >/dev/null 2>&1 || { log "Lỗi: Nâng cấp hệ thống thất bại!" "$RED"; exit 1; }
  log "Cập nhật hệ thống hoàn tất."
}

# Cài đặt các gói cần thiết (bao gồm các gói phụ thuộc cho NVM)
install_essential_packages() {
  log "Bắt đầu cài đặt các gói cần thiết..."

  # Gộp các gói vào một lệnh apt install
  local packages_string=$(IFS=$'\n'; echo "${ESSENTIAL_PACKAGES[*]}")
  apt install -y $packages_string >/dev/null 2>&1 || { log "Lỗi: Cài đặt các gói thất bại!" "$RED"; exit 1; }

  log "Cài đặt các gói cần thiết hoàn tất."
}

# Cài đặt NVM (Node Version Manager)
install_nvm() {
  # Kiểm tra xem NVM đã được cài đặt hay chưa
  if [ -d "$HOME/.nvm" ]; then
    log "NVM đã được cài đặt, bỏ qua bước cài đặt."
    return
  fi

  log "Cài đặt NVM..."
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.2/install.sh | bash >/dev/null 2>&1 || { log "Lỗi: Cài đặt NVM thất bại!" "$RED"; exit 1; }

  # Load NVM và thêm vào .profile để load khi khởi động shell
  NVM_DIR="$HOME/.nvm"

  # Kiểm tra xem ~/.profile đã chứa các lệnh NVM hay chưa
  if ! grep -q 'export NVM_DIR="$HOME/.nvm"' ~/.profile; then
    echo 'export NVM_DIR="$HOME/.nvm"' >> ~/.profile
    log "Đã thêm 'export NVM_DIR' vào ~/.profile."
  fi
  if ! grep -q '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"' ~/.profile; then
    echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm' >> ~/.profile
    log "Đã thêm lệnh load nvm.sh vào ~/.profile."
  fi
  if ! grep -q '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"' ~/.profile; then
    echo '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion' >> ~/.profile
    log "Đã thêm lệnh load bash_completion vào ~/.profile."
  fi

  # Thêm các lệnh vào ~/.bashrc (nếu chưa có)
   if ! grep -q 'export NVM_DIR="$HOME/.nvm"' ~/.bashrc; then
    echo 'export NVM_DIR="$HOME/.nvm"' >> ~/.bashrc
    log "Đã thêm 'export NVM_DIR' vào ~/.bashrc."
  fi
  if ! grep -q '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"' ~/.bashrc; then
    echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm' >> ~/.bashrc
    log "Đã thêm lệnh load nvm.sh vào ~/.bashrc."
  fi
  if ! grep -q '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"' ~/.bashrc; then
    echo '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion' >> ~/.bashrc
    log "Đã thêm lệnh load bash_completion vào ~/.bashrc."
  fi

  log "NVM đã được cài đặt và cấu hình để load khi khởi động shell."
}

# Cài đặt Node.js (sử dụng NVM)
install_nodejs() {
  log "Cài đặt Node.js (sử dụng NVM)..."

  # Load NVM
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
  [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion

  # Install Node.js version 22
  nvm install 22 >/dev/null 2>&1 || { log "Lỗi: Cài đặt Node.js 22 thất bại!" "$RED"; exit 1; }
  nvm use 22 >/dev/null 2>&1 || { log "Lỗi: Sử dụng Node.js 22 thất bại!" "$RED"; exit 1; }
  nvm alias default 22 >/dev/null 2>&1 || { log "Lỗi: Thiết lập Node.js 22 mặc định thất bại!" "$RED"; exit 1; }

  log "Node.js (phiên bản 22) đã được cài đặt và thiết lập làm mặc định."
}

# Cài đặt Bun.js
install_bun() {
  log "Bắt đầu cài đặt Bun.js..."
  curl -fsSL https://bun.sh/install | bash >/dev/null 2>&1 || { log "Lỗi: Cài đặt Bun.js thất bại!" "$RED"; exit 1; }
  log "Bun.js đã được cài đặt thành công."

  # Add Bun to PATH
  if grep -q 'export PATH="$PATH:$HOME/.bun/bin"' ~/.bashrc; then
    log "Bun đã có trong PATH, bỏ qua."
  else
    log "Thêm Bun vào PATH..."
    echo 'export PATH="$PATH:$HOME/.bun/bin"' >> ~/.bashrc
    PATH="$PATH:$HOME/.bun/bin"
    export PATH
    log "Đã thêm Bun vào PATH."
  fi
}

# Cài đặt speedtest-cli
install_speedtest-cli() {
  log "Bắt đầu cài đặt speedtest-cli..."
  curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | sudo bash >/dev/null 2>&1 || { log "Lỗi: Cài đặt repository speedtest-cli thất bại!" "$RED"; exit 1; }
  apt install -y speedtest >/dev/null 2>&1 || { log "Lỗi: Cài đặt speedtest-cli thất bại!" "$RED"; exit 1; }
  log "speedtest-cli đã được cài đặt thành công."
}

# Thực thi
check_root
update_system

# Cài đặt các gói phụ thuộc cho NVM
install_essential_packages

# Cài đặt NVM và Node.js
install_nvm
install_nodejs

install_speedtest-cli
install_bun

log "Hoàn tất cài đặt các gói cần thiết trên Ubuntu 22.04!"
log "Để đảm bảo các biến môi trường được cập nhật chính xác, hãy chạy lệnh: source ~/.bashrc"
