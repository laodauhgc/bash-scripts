#!/usr/bin/env bash
# Ubuntu Core Setup Script v3.2.13 – 30-Jul-2025
# Installs core packages, Node.js v22.17.1, Bun.js, PM2, and Docker

set -Eeuo pipefail
trap 'echo "❌ Error at line $LINENO: $BASH_COMMAND" >&2' ERR

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8

# ---------- Metadata ----------------------------------------------------------
readonly SCRIPT_VERSION="3.2.13"
readonly SCRIPT_NAME="$(basename "$0")"
readonly NODE_VERSION="22.17.1"
readonly BUN_VERSION="1.2.19"

# ---------- Checks -----------------------------------------------------------
[[ $EUID -eq 0 ]] || { echo "❌ Please run as sudo/root."; exit 1; }

# ---------- Clear APT locks ---------------------------------------------------
rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock-frontend 2>/dev/null
dpkg --configure -a 2>/dev/null

# ---------- APT helpers ------------------------------------------------------
apt_update() {
  echo "Updating APT..."
  apt-get update -qq || { apt-get update --fix-missing -qq || { echo "❌ apt update failed."; exit 1; }; }
  echo "✅ APT updated."
}

apt_install() {
  echo "Installing packages: $@..."
  apt-get install -y --no-install-recommends "$@" || { echo "❌ Package installation failed."; exit 1; }
  echo "✅ Packages installed."
}

# ---------- Install JavaScript runtimes (Node.js, Bun, PM2) -------------------
install_js_runtimes() {
  echo "Installing Node.js, Bun.js, and PM2..."

  # Cài nvm và Node.js
  if [[ ! -d "$HOME/.nvm" ]]; then
    echo "Installing nvm..."
    curl --connect-timeout 30 -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash || { echo "❌ nvm installation failed."; exit 1; }
    echo "✅ nvm installed."
  fi

  # Nạp nvm
  [[ -s "$HOME/.nvm/nvm.sh" ]] && \. "$HOME/.nvm/nvm.sh"

  # Xóa cache nvm
  rm -rf "$HOME/.nvm/.cache" 2>/dev/null

  # Cài Node.js
  if ! command -v node >/dev/null 2>&1 || [[ $(node -v) != "v$NODE_VERSION" ]]; then
    echo "Installing Node.js v$NODE_VERSION..."
    nvm install "$NODE_VERSION" || { echo "❌ Node.js installation failed."; exit 1; }
    nvm use "$NODE_VERSION" || { echo "❌ Failed to use Node.js v$NODE_VERSION."; exit 1; }
    echo "✅ Node.js v$NODE_VERSION installed."
  fi
  echo "✅ Node.js version: $(node -v), npm version: $(npm -v)"

  # Cài PM2
  if ! command -v pm2 >/dev/null 2>&1; then
    echo "Installing PM2..."
    npm install -g pm2 || { echo "❌ PM2 installation failed."; exit 1; }
    echo "✅ PM2 installed, version: $(pm2 -v)"
  fi

  # Cài Bun.js
  if ! command -v bun >/dev/null 2>&1; then
    echo "Installing Bun v$BUN_VERSION..."
    curl --connect-timeout 30 -fsSL https://bun.sh/install | bash || { echo "❌ Bun installation failed."; exit 1; }
    # Cập nhật PATH
    [[ -s "$HOME/.bun/bin/bun" ]] && export PATH="$HOME/.bun/bin:$PATH"
    echo "✅ Bun v$BUN_VERSION installed, version: $(bun --version 2>/dev/null || echo 'not installed')"
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
      echo "✅ Added $SUDO_USER to docker group."
    fi
    echo "✅ Docker installed, version: $(docker --version 2>/dev/null || echo 'not installed')"
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
