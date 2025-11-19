#!/usr/bin/env bash
# Universal Server Setup Script
# Supports: Debian/Ubuntu, RHEL/CentOS/Alma, Fedora, Arch, Alpine
# Installs: Core Tools, Node.js (Latest LTS), Bun (Latest), PM2, Docker

set -Eeuo pipefail
trap 'echo "❌ Error at line $LINENO: $BASH_COMMAND" >&2' ERR

# ==============================================================================
# CONFIGURATION
# ==============================================================================
# Currently Node 22 is the Active LTS. Change this number when new LTS drops.
NODE_MAJOR_LTS="22" 

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

log_info()  { echo -e "${BLUE}[INFO] $1${NC}"; }
log_ok()    { echo -e "${GREEN}[OK] $1${NC}"; }
log_warn()  { echo -e "${YELLOW}[WARN] $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

check_root() {
    [[ $EUID -eq 0 ]] || log_error "This script must be run as root/sudo."
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME=$ID
        OS_LIKE=${ID_LIKE:-$ID}
    else
        log_error "Cannot detect OS. /etc/os-release not found."
    fi

    case "$OS_LIKE" in
        *debian*|ubuntu)
            PKG_MANAGER="apt"
            ;;
        *rhel*|*centos*|*fedora*)
            PKG_MANAGER="dnf"
            # Fallback to yum for older CentOS 7
            command -v dnf >/dev/null || PKG_MANAGER="yum"
            ;;
        *arch*)
            PKG_MANAGER="pacman"
            ;;
        *alpine*)
            PKG_MANAGER="apk"
            ;;
        *)
            log_error "Unsupported OS Family: $OS_LIKE"
            ;;
    esac
    
    log_info "Detected OS: $PRETTY_NAME ($PKG_MANAGER)"
}

get_real_user() {
    local user="${SUDO_USER:-}"
    if [[ -z "$user" || "$user" == "root" ]]; then
        user=$(awk -F: '$3 >= 1000 && $1 != "nobody" {print $1; exit}' /etc/passwd)
    fi
    echo "$user"
}

# ==============================================================================
# PACKAGE MANAGEMENT ABSTRACTION
# ==============================================================================

update_system() {
    log_info "Updating system repositories..."
    case "$PKG_MANAGER" in
        apt)
            apt-get update -qq
            ;;
        dnf|yum)
            # dnf check-update returns exit code 100 if updates available, which triggers set -e
            $PKG_MANAGER check-update >/dev/null 2>&1 || true 
            ;;
        pacman)
            pacman -Sy --noconfirm
            ;;
        apk)
            apk update
            ;;
    esac
}

install_dependencies() {
    log_info "Installing core dependencies..."
    
    case "$PKG_MANAGER" in
        apt)
            apt-get install -y -qq curl wget git unzip zip htop build-essential libssl-dev ca-certificates gnupg
            ;;
        dnf|yum)
            $PKG_MANAGER install -y curl wget git unzip zip htop make gcc gcc-c++ openssl-devel ca-certificates
            # 'Development Tools' group is often too heavy, installing basics manually
            ;;
        pacman)
            pacman -S --noconfirm --needed curl wget git unzip zip htop base-devel openssl
            ;;
        apk)
            # gcompat is needed for Bun to run on Alpine (musl libc vs glibc)
            apk add curl wget git unzip zip htop build-base openssl-dev ca-certificates gcompat
            ;;
    esac
    log_ok "Dependencies installed."
}

# ==============================================================================
# NODE.JS & BUN INSTALLATION
# ==============================================================================

install_nodejs() {
    log_info "Checking Node.js..."
    
    # Check if installed and version matches
    if command -v node >/dev/null 2>&1; then
        local current_ver=$(node -v | cut -d. -f1 | tr -d 'v')
        if [[ "$current_ver" == "$NODE_MAJOR_LTS" ]]; then
            log_ok "Node.js v$NODE_MAJOR_LTS is already installed."
            return
        fi
        log_warn "Node.js version mismatch or upgrade needed. Re-installing..."
    fi

    log_info "Installing Node.js v${NODE_MAJOR_LTS} (LTS)..."

    case "$PKG_MANAGER" in
        apt)
            # Remove old
            apt-get remove -y nodejs npm >/dev/null 2>&1 || true
            # NodeSource
            curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR_LTS}.x | bash - >/dev/null
            apt-get install -y -qq nodejs
            ;;
        dnf|yum)
            # NodeSource
            curl -fsSL https://rpm.nodesource.com/setup_${NODE_MAJOR_LTS}.x | bash - >/dev/null
            $PKG_MANAGER install -y nodejs
            ;;
        pacman)
            # Arch typically has 'nodejs' (latest) and 'nodejs-lts-iron' (v20), etc.
            # Since Arch is bleeding edge, standard 'nodejs' is usually very new.
            # To strictly follow LTS request, we try lts package first.
            pacman -S --noconfirm nodejs npm || pacman -S --noconfirm nodejs-lts-jod npm
            ;;
        apk)
            # Alpine repos are strict. usually 'nodejs' is reasonably new.
            apk add nodejs npm
            ;;
    esac

    # Install PM2 globally
    if command -v npm >/dev/null; then
        npm install -g pm2
        log_ok "Node.js $(node -v) and PM2 installed."
    else
        log_error "NPM not found. Node install failed."
    fi
}

install_bun() {
    log_info "Installing Bun (Latest)..."
    
    # Force installation to /usr/local to be system-wide accessible
    export BUN_INSTALL="/usr/local"
    
    if curl -fsSL https://bun.sh/install | bash; then
        log_ok "Bun $(bun --version) installed."
    else
        log_error "Bun installation failed."
    fi
}

# ==============================================================================
# DOCKER INSTALLATION
# ==============================================================================

install_docker() {
    if command -v docker >/dev/null 2>&1; then
        log_ok "Docker is already installed: $(docker --version)"
    else
        log_info "Installing Docker..."
        
        # Try official script first (Works for Debian, RHEL, Fedora, Arch)
        if curl -fsSL https://get.docker.com | sh; then
             log_ok "Docker installed via official script."
        else
             log_warn "Official script failed. Attempting native package install..."
             case "$PKG_MANAGER" in
                apk)
                    apk add docker
                    rc-update add docker boot
                    service docker start
                    ;;
                pacman)
                    pacman -S --noconfirm docker
                    ;;
                *)
                    log_error "Could not install Docker automatically."
                    ;;
             esac
        fi
    fi

    # Enable Service (systemd)
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now docker >/dev/null 2>&1 || true
    fi

    # Add user to group
    local real_user=$(get_real_user)
    if [[ -n "$real_user" ]]; then
        usermod -aG docker "$real_user" 2>/dev/null || true
        log_ok "User '$real_user' added to docker group."
    fi
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

log_info "🚀 Starting Universal Linux Setup..."

check_root
detect_os

# 1. Prepare System
update_system
install_dependencies

# 2. Runtimes
install_nodejs
install_bun

# 3. Containerization
install_docker

# 4. Cleanup
log_info "Cleaning up..."
case "$PKG_MANAGER" in
    apt) apt-get autoremove -y -qq >/dev/null ;;
    dnf|yum) $PKG_MANAGER clean all >/dev/null ;;
    pacman) pacman -Sc --noconfirm >/dev/null ;;
esac

# Summary
echo ""
echo "====================================================="
echo -e "${GREEN}🎉 Setup Complete!${NC}"
echo "====================================================="
echo -e " OS     : $PRETTY_NAME"
echo -e " Node.js: $(node -v 2>/dev/null || echo 'Err')"
echo -e " NPM    : $(npm -v 2>/dev/null || echo 'Err')"
echo -e " PM2    : $(pm2 -v 2>/dev/null || echo 'Err')"
echo -e " Bun    : $(bun --version 2>/dev/null || echo 'Err')"
echo -e " Docker : $(docker --version 2>/dev/null || echo 'Err')"
echo "====================================================="
echo -e "${YELLOW}NOTE: If you are using a non-root user, run 'newgrp docker' or re-login to use Docker.${NC}"
