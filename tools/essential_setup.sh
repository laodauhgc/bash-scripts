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
  "fail2ban" # Note: Fail2ban is installed but NOT enabled
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
  log "Cài đặt NVM..."
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.2/install.sh | bash >/dev/null 2>&1 || { log "Lỗi: Cài đặt NVM thất bại!" "$RED"; exit 1; }
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
  [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
  log "NVM đã được cài đặt."
}

# Cài đặt Node.js (sử dụng NVM)
install_nodejs() {
  log "Cài đặt Node.js (sử dụng NVM)..."
  # Install Node.js version 22
  nvm install 22 >/dev/null 2>&1 || { log "Lỗi: Cài đặt Node.js 22 thất bại!" "$RED"; exit 1; }
  nvm use 22 >/dev/null 2>&1 || { log "Lỗi: Sử dụng Node.js 22 thất bại!" "$RED"; exit 1; }
  nvm alias default 22 >/dev/null 2>&1 || { log "Lỗi: Thiết lập Node.js 22 mặc định thất bại!" "$RED"; exit 1; }

  log "Node.js (phiên bản 22) đã được cài đặt và thiết lập làm mặc định."
}

# Thêm repository cho Golang (phiên bản mới nhất)
# Lưu ý: Ubuntu thường có phiên bản Golang khá mới, nên có thể không cần thêm repo
# Nếu cần, bạn có thể thêm repo từ https://go.dev/dl/
# add_golang_repo() {
#   log "Thêm kho lưu trữ Golang..."
#   # Ví dụ (có thể cần điều chỉnh):
#   # add-apt-repository ppa:longsleep/golang-backports >/dev/null 2>&1 || { log "Lỗi: Thêm kho lưu trữ Golang thất bại!" "$RED"; exit 1; }
#   log "Kho lưu trữ Golang đã được thêm."
# }

# Cài đặt Bun.js
install_bun() {
  log "Bắt đầu cài đặt Bun.js..."
  curl -fsSL https://bun.sh/install | bash >/dev/null 2>&1 || { log "Lỗi: Cài đặt Bun.js thất bại!" "$RED"; exit 1; }
  log "Bun.js đã được cài đặt thành công."

  # Add Bun to PATH (required for it to work correctly)
  if grep -q 'export PATH="$PATH:$HOME/.bun/bin"' ~/.bashrc; then
    log "Bun đã có trong PATH, bỏ qua."
  else
    log "Thêm Bun vào PATH..."
    echo 'export PATH="$PATH:$HOME/.bun/bin"' >> ~/.bashrc
    # Source .bashrc only if it's an interactive shell
    if [ -n "$PS1" ]; then
      source ~/.bashrc
    fi
    log "Đã thêm Bun vào PATH."
  fi
}

# Cài đặt speedtest-cli
install_speedtest_cli() {
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

# Thêm các kho lưu trữ
#add_golang_repo # Uncomment nếu cần và đã điền thông tin

install_speedtest_cli
install_bun

log "Hoàn tất cài đặt các gói cần thiết trên Ubuntu 22.04!"

exit 0
