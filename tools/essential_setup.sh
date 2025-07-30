#!/usr/bin/env bash
# Ubuntu Core Setup Script v3.2.12 – 30-Jul-2025
# Installs core packages, Node.js, Bun.js, PM2, and Docker

set -Eeuo pipefail
trap 'echo "❌ Error at line $LINENO: $BASH_COMMAND" >&2' ERR

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8

# ---------- Metadata ----------------------------------------------------------
readonly SCRIPT_VERSION="3.2.12"
readonly SCRIPT_NAME="$(basename "$0")"
readonly NVM_VERSION="0.40.3"
readonly NODE_VERSION="22.17.1"
readonly BUN_VERSION="1.2.19"

# ---------- Checks -----------------------------------------------------------
[[ $EUID -eq 0 ]] || { echo "❌ Please run as sudo/root."; exit 1; }

# ---------- Clear APT locks ---------------------------------------------------
rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock-frontend 2>/dev/null
dpkg --configure -a 2>/dev/null

# ---------- APT helpers ------------------------------------------------------
apt_update() {
  apt-get update -qq || { apt-get update --fix-missing -qq || { echo "❌ apt update failed."; exit 1; }; }
}

apt_install() {
  apt-get install -y --no-install-recommends "$@" || { echo "❌ Package installation failed."; exit 1; }
}

# ---------- Install JavaScript runtimes (Node.js, Bun, PM2) -------------------
install_js_runtimes() {
  echo "Installing Node.js, Bun.js, and PM2..."

  # Cài nvm và Node.js
  if [[ ! -d "$HOME/.nvm" ]]; then
    curl --connect-timeout 30 -o- https://raw.githubusercontent.com/nvm-sh/nvm/v$NVM_VERSION/install.sh | bash || { echo "❌ nvm installation failed."; exit 1; }
  fi

  # Nạp nvm
  [[ -s "$HOME/.nvm/nvm.sh" ]] && \. "$HOME/.nvm/nvm.sh"

  # Cài Node.js
  if ! command -v node >/dev/null 2>&1 || [[ $(nvm current) != "v$NODE_VERSION" ]]; then
    nvm install "$NODE_VERSION" || { echo "❌ Node.js installation failed."; exit 1; }
  fi

  # Cài PM2
  if ! command -v pm2 >/dev/null 2>&1; then
    npm install -g pm2 || { echo "❌ PM2 installation failed."; exit 1; }
  fi

  # Cài Bun.js
  if ! command -v bun >/dev/null 2>&1; then
    curl --connect-timeout 30 -fsSL https://bun.sh/install | bash || { echo "❌ Bun installation failed."; exit 1; }
  fi
}

# ---------- Install Docker ---------------------------------------------------
install_docker() {
  echo "Installing Docker..."

  if ! command -v docker >/dev/null 2>&1; then
    local docker_script="/root/install_docker.sh"
    touch "$docker_script" || { echo "❌ Cannot create $docker_script."; exit 1; }
    curl --connect-timeout 30 -sSL https://get.docker.com -o "$docker_script" || { rm -f "$docker_script"; echo "❌ Docker script download failed."; exit 1; }
    chmod +x "$docker_script"
    /bin/bash "$docker_script" || { rm -f "$docker_script"; echo "❌ Docker installation failed."; exit 1; }
    rm -f "$docker_script"
    if [[ -n "$SUDO_USER" ]]; then
      usermod -aG docker "$SUDO_USER" 2>/dev/null || echo "⚠️ Cannot add user to docker group."
    fi
  fi
}

# ---------- Main process -----------------------------------------------------
echo "🚀 Starting Ubuntu Core Setup Script v$SCRIPT_VERSION..."
command -v curl >/dev/null 2>&1 || { echo "❌ 'curl' is required. Install it first."; exit 1; }

apt_update
PKGS=(build-essential git curl wget vim htop rsync bash-completion python3 python3-venv python3-pip ca-certificates gnupg software-properties-common plocate openssh-client libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev libffi-dev liblzma-dev libncursesw5-dev uuid-dev zip unzip)
missing=(); for p in "${PKGS[@]}"; do dpkg -s "$p" &>/dev/null || missing+=("$p"); done
if [[ ${#missing[@]} -gt 0 ]]; then
  apt_install "${missing[@]}"
fi
install_js_runtimes
install_docker
apt-get autoremove -y -qq
apt-get clean -qq

# ---------- Final report -----------------------------------------------------
echo "🎉 Installation complete!"
echo "  • System packages installed: ${#missing[@]}"
echo "  • Node.js: $(node -v 2>/dev/null || echo 'not installed')"
echo "  • Bun.js: $(bun --version 2>/dev/null || echo 'not installed')"
echo "  • PM2: $(pm2 -v 2>/dev/null || echo 'not installed')"
echo "  • Docker: $(docker --version 2>/dev/null || echo 'not installed')"
