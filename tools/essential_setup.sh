#!/usr/bin/env bash
# Ubuntu Core Setup Script v3.2.14 – 04-Aug-2025
# Installs core packages, Node.js, Bun, PM2, and Docker

set -Eeuo pipefail
trap 'echo "❌ Error at line $LINENO: $BASH_COMMAND" >&2' ERR

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8

# ---------- Metadata ----------------------------------------------------------
readonly SCRIPT_VERSION="3.2.14"
readonly SCRIPT_NAME="$(basename "$0")"
readonly NODE_VERSION="22.17.1"   # Will fall back to latest LTS if not available
readonly BUN_VERSION="1.2.19"     # We attempt to upgrade to this version if possible

# ---------- Preconditions -----------------------------------------------------
[[ $EUID -eq 0 ]] || { echo "❌ Please run as sudo/root."; exit 1; }

# ---------- Clear APT locks ---------------------------------------------------
rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock-frontend 2>/dev/null || true
dpkg --configure -a 2>/dev/null || true

# ---------- Logging helpers ---------------------------------------------------
log()   { echo -e "[$(date +'%F %T')] $*"; }
ok()    { echo -e "✅ $*"; }
warn()  { echo -e "⚠️  $*" >&2; }
fail()  { echo -e "❌ $*" >&2; exit 1; }

# ---------- APT helpers -------------------------------------------------------
apt_update() {
  log "Updating APT indices..."
  local i
  for i in 1 2 3; do
    if apt-get update -qq; then
      ok "APT updated."
      return 0
    fi
    warn "apt-get update attempt #$i failed; retrying with --fix-missing..."
    apt-get update --fix-missing -qq || true
    sleep 2
  done
  fail "apt-get update failed after retries."
}

apt_fix() {
  apt-get -y -qq -f install || true
  dpkg --configure -a || true
}

apt_install() {
  local pkgs=("$@")
  [[ ${#pkgs[@]} -gt 0 ]] || return 0
  log "Installing packages: ${pkgs[*]}"
  local i
  for i in 1 2 3; do
    if apt-get install -y -qq --no-install-recommends "${pkgs[@]}"; then
      ok "Installed: ${pkgs[*]}"
      return 0
    fi
    warn "Install attempt #$i failed; trying fix-broken and retrying..."
    apt_fix
    sleep 2
  done
  fail "Package installation failed: ${pkgs[*]}"
}

# ---------- User selection helper --------------------------------------------
# Choose a non-root user to add to the docker group.
resolve_user() {
  if [[ -n "${SUDO_USER-}" && "${SUDO_USER}" != "root" ]]; then
    echo "${SUDO_USER}"
    return
  fi
  if [[ -n "${TARGET_USER-}" && "${TARGET_USER}" != "root" ]]; then
    echo "${TARGET_USER}"
    return
  fi
  # Pick the first human user (UID >= 1000, exclude nobody)
  local u
  u="$(getent passwd | awk -F: '$3>=1000 && $1!="nobody"{print $1; exit}')"
  if [[ -n "${u}" && "${u}" != "root" ]]; then
    echo "${u}"
    return
  fi
  echo ""
}

# ---------- Install JavaScript runtimes (Node.js, Bun, PM2) ------------------
install_js_runtimes() {
  log "Installing Node.js, Bun, and PM2..."

  # Ensure curl exists before using it (in case minimal image)
  if ! command -v curl >/dev/null 2>&1; then
    apt_update
    apt_install curl ca-certificates
  fi

  # nvm + Node.js
  if [[ ! -d "$HOME/.nvm" ]]; then
    log "Installing nvm..."
    curl --connect-timeout 30 -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash || fail "nvm installation failed."
    ok "nvm installed."
  fi
  # shellcheck disable=SC1091
  [[ -s "$HOME/.nvm/nvm.sh" ]] && \. "$HOME/.nvm/nvm.sh"

  # Clear nvm cache to avoid corrupted downloads in some environments
  rm -rf "$HOME/.nvm/.cache" 2>/dev/null || true

  # Install Node.js (try pinned version, fall back to latest LTS if unavailable)
  if ! command -v node >/dev/null 2>&1 || [[ "$(node -v || true)" != "v${NODE_VERSION}" ]]; then
    log "Installing Node.js v${NODE_VERSION} (will fall back to LTS if needed)..."
    if nvm install "${NODE_VERSION}"; then
      nvm alias default "${NODE_VERSION}"
      nvm use default
      ok "Node.js v${NODE_VERSION} installed."
    else
      warn "Requested Node.js ${NODE_VERSION} not available; installing latest LTS..."
      nvm install --lts || fail "Failed to install latest LTS Node.js."
      nvm alias default "lts/*"
      nvm use default
      ok "Node.js $(node -v) installed (LTS fallback)."
    fi
  fi

  # Ensure npm/pm2
  log "Ensuring PM2 is installed..."
  if ! command -v npm >/dev/null 2>&1; then
    fail "npm not found after Node install."
  fi
  if ! command -v pm2 >/dev/null 2>&1; then
    npm install -g pm2 || fail "PM2 installation failed."
    ok "PM2 installed: $(pm2 -v)"
  else
    ok "PM2 present: $(pm2 -v)"
  fi

  # Bun
  if ! command -v bun >/dev/null 2>&1; then
    log "Installing Bun..."
    curl --connect-timeout 30 -fsSL https://bun.sh/install | bash || fail "Bun installation failed."
    # Update PATH for current shell
    if [[ -s "$HOME/.bun/bin/bun" ]]; then
      export PATH="$HOME/.bun/bin:$PATH"
    fi
    ok "Bun installed: $(bun --version 2>/dev/null || echo 'unknown')"
  else
    ok "Bun present: $(bun --version)"
  fi

  # Try to align Bun version if BUN_VERSION is set (best-effort, non-fatal)
  if command -v bun >/dev/null 2>&1; then
    if [[ "$(bun --version || true)" != "${BUN_VERSION}" ]]; then
      log "Attempting to upgrade Bun to ${BUN_VERSION} (best-effort)..."
      bun upgrade --yes --version "${BUN_VERSION}" >/dev/null 2>&1 || true
      ok "Bun version now: $(bun --version || echo 'unknown')"
    fi
  fi

  ok "Node: $(node -v), npm: $(npm -v), PM2: $(pm2 -v), Bun: $(bun --version 2>/dev/null || echo 'not installed')"
}

# ---------- Install Docker ---------------------------------------------------
install_docker() {
  log "Installing Docker..."
  if command -v docker >/dev/null 2>&1; then
    ok "Docker already installed: $(docker --version 2>/dev/null || echo 'unknown')"
    return 0
  fi

  # Ensure curl exists before using it
  if ! command -v curl >/dev/null 2>&1; then
    apt_update
    apt_install curl ca-certificates
  fi

  local docker_script="/root/install_docker.sh"
  rm -f "$docker_script" 2>/dev/null || true
  touch "$docker_script" || fail "Cannot create $docker_script"
  curl --connect-timeout 30 -sSL https://get.docker.com -o "$docker_script" || { rm -f "$docker_script"; fail "Docker script download failed."; }
  chmod +x "$docker_script"
  /bin/bash "$docker_script" || { rm -f "$docker_script"; fail "Docker installation failed."; }
  rm -f "$docker_script"

  # Try to enable/start service if systemd is available
  if command -v systemctl >/dev/null 2>&1; then
    if ! systemctl is-active --quiet docker; then
      systemctl enable --now docker >/dev/null 2>&1 || warn "Could not enable/start docker service (non-systemd environment?)"
    fi
  fi

  # Add a non-root user to the docker group if present
  local add_user
  add_user="$(resolve_user)"
  if [[ -n "${add_user}" ]]; then
    if id -u "${add_user}" &>/dev/null; then
      usermod -aG docker "${add_user}" 2>/dev/null || warn "Cannot add ${add_user} to docker group."
      ok "Added ${add_user} to docker group. You may need to re-login for group changes to take effect."
    else
      warn "User '${add_user}' not found; skip adding to docker group."
    fi
  else
    log "No non-root user detected; skip adding to docker group."
  fi

  ok "Docker installed: $(docker --version 2>/dev/null || echo 'unknown')"
}

# ---------- Main process -----------------------------------------------------
log "🚀 Starting Ubuntu Core Setup Script v${SCRIPT_VERSION}..."
apt_update

# Core packages
PKGS=(
  build-essential git curl wget vim htop rsync bash-completion
  python3 python3-venv python3-pip
  ca-certificates gnupg software-properties-common plocate
  openssh-client
  libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev libffi-dev liblzma-dev libncursesw5-dev uuid-dev
  zip unzip
)

# Install missing packages only
missing=()
for p in "${PKGS[@]}"; do
  if ! dpkg -s "$p" &>/dev/null; then
    missing+=("$p")
  fi
done
if [[ ${#missing[@]} -gt 0 ]]; then
  apt_install "${missing[@]}"
else
  ok "All base packages already present."
fi

# JS runtimes & Docker
install_js_runtimes
install_docker

# Clean up
log "Cleaning up APT caches..."
apt-get autoremove -y -qq || true
apt-get clean -qq || true

# ---------- Final report -----------------------------------------------------
echo "🎉 Installation complete!"
echo "  • System packages newly installed: ${#missing[@]}"
echo "  • Node.js: $(node -v 2>/dev/null || echo 'not installed')"
echo "  • npm: $(npm -v 2>/dev/null || echo 'not installed')"
echo "  • Bun: $(bun --version 2>/dev/null || echo 'not installed')"
echo "  • PM2: $(pm2 -v 2>/dev/null || echo 'not installed')"
echo "  • Docker: $(docker --version 2>/dev/null || echo 'not installed')"
