#!/usr/bin/env bash
###############################################################################
# Blockcast BEACON Setup Script - v1.3.1 (Hardened & Portable)
# - Uses official Docker installer from https://get.docker.com
# - Prefers official docker-compose-plugin on Ubuntu/Debian
# Supported OS  : Ubuntu 18.04+/Debian 10+/RHEL/CentOS 7+/Fedora 33+
# Architectures : x86_64/amd64, arm64/aarch64
###############################################################################

set -eEuo pipefail
IFS=$'\n\t'

#--------------------------------------
# Constants / Defaults
#--------------------------------------
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="v1.3.1"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="${SCRIPT_DIR}/blockcast_setup.log"
readonly BACKUP_STAGING_DIR="${HOME}/.blockcast_backup_$(date +%Y%m%d_%H%M%S)"
readonly BACKUP_TAR_PREFIX="blockcast_backup_$(date +%Y%m%d_%H%M%S)"
readonly BEACON_REPO_URL="https://github.com/Blockcast/beacon-docker-compose.git"
readonly BEACON_DIR_NAME="beacon-docker-compose"
readonly MIN_DOCKER_VERSION="20.10.0"
readonly MIN_COMPOSE_VERSION="2.0.0"
readonly DISK_MIN_GB=10
readonly MEM_MIN_GB=2

# Colors
declare -r RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' BLUE='\033[0;34m' PURPLE='\033[0;35m' CYAN='\033[0;36m' NC='\033[0m'

# Globals
OS="" OS_VERSION="" OS_CODENAME="" ARCH="" COMPOSE_CMD="" DEBUG_LEVEL=${DEBUG:-0}

#--------------------------------------
# Logging
#--------------------------------------
log(){ local level="$1"; shift; local msg="$*"; local ts="$(date '+%Y-%m-%d %H:%M:%S')"; local color="";
  case "$level" in INFO) color="$GREEN";; WARN) color="$YELLOW";; ERROR) color="$RED";; DEBUG) color="$PURPLE";; esac
  if [[ "$level" == DEBUG && "$DEBUG_LEVEL" -ne 1 ]]; then echo "[$ts] [DEBUG] $msg" >>"$LOG_FILE"; return; fi
  echo -e "${color}[$level]${NC} $msg" | tee -a "$LOG_FILE" >&2
  [[ "$level" == DEBUG ]] || echo "[$ts] [$level] $msg" >>"$LOG_FILE"
}
fatal(){ log ERROR "$*"; exit 1; }
cleanup(){ local code=$?; ((code!=0)) && log ERROR "Script failed with exit code $code. See $LOG_FILE"; tput sgr0 2>/dev/null||true; exit $code; }
trap cleanup EXIT

#--------------------------------------
# Utils
#--------------------------------------
version_ge(){ local v1="$1" v2="$2"; command -v dpkg &>/dev/null && dpkg --compare-versions "$v1" ge "$v2" || [[ "$(printf '%s\n' "$v2" "$v1" | sort -V | head -n1)" == "$v2" ]]; }
_fetch(){ curl -sSL --proto '=https' --tlsv1.2 "$@"; }
set_compose_cmd(){ if command -v docker &>/dev/null && docker compose version &>/dev/null; then COMPOSE_CMD="docker compose"; elif command -v docker-compose &>/dev/null; then COMPOSE_CMD="docker-compose"; else COMPOSE_CMD=""; fi }

#--------------------------------------
# Banner & Usage
#--------------------------------------
print_banner(){ echo -e "${CYAN}"; cat <<EOF
╔══════════════════════════════════════════════════════════════════════╗
║               Blockcast BEACON Setup Script ${SCRIPT_VERSION}               ║
║                 Hardened, Portable, Reliable                         ║
╚══════════════════════════════════════════════════════════════════════╝
EOF; echo -e "${NC}"; }
usage(){ cat <<EOF
Usage: sudo ./${SCRIPT_NAME} [OPTIONS]

Actions:
  -i, --install           Install Blockcast BEACON (default)
  -u, --uninstall         Uninstall Blockcast BEACON
  -b, --backup            Backup current installation
  -r, --restore FILE      Restore from backup tar.gz
  -c, --check             Check system requirements

Flags:
  -v, --verbose           Enable debug logs
      --dry-run           Show actions without executing
  -h, --help              Show this help
EOF
}

#--------------------------------------
# Environment Checks
#--------------------------------------
detect_os(){ if [[ -f /etc/os-release ]]; then source /etc/os-release; OS="$ID"; OS_VERSION="$VERSION_ID"; OS_CODENAME="${VERSION_CODENAME:-}"; elif [[ -f /etc/redhat-release ]]; then OS="centos"; OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | head -1); else fatal "Unsupported OS"; fi; ARCH=$(uname -m); log INFO "Detected OS: $OS $OS_VERSION ($ARCH)"; }
check_root(){ [[ $EUID -ne 0 ]] && fatal "Run as root (sudo $SCRIPT_NAME)"; }
check_requirements(){ log INFO "Checking system requirements..."; check_root; [[ "$ARCH" =~ ^(x86_64|amd64|arm64|aarch64)$ ]] || fatal "Unsupported architecture: $ARCH"; local avail=$(df --output=avail -k / | tail -1); local need=$((DISK_MIN_GB*1024*1024)); ((avail<need)) && fatal "Need at least ${DISK_MIN_GB}GB free on /"; local mem=$(awk '/MemTotal/ {print $2}' /proc/meminfo); local needm=$((MEM_MIN_GB*1024*1024)); ((mem<needm)) && log WARN "Detected < ${MEM_MIN_GB}GB RAM. Proceeding anyway."; log INFO "System requirements OK"; }

#--------------------------------------
# Install Docker
#--------------------------------------
install_docker(){ if command -v docker &>/dev/null; then local cur=$(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1); if [[ -n "$cur" && $(version_ge "$cur" "$MIN_DOCKER_VERSION" && echo yes) == yes ]]; then log INFO "Docker $cur already meets requirement"; return; fi; log WARN "Docker $cur outdated, installing via get.docker.com"; fi; log INFO "Installing Docker via get.docker.com"; _fetch https://get.docker.com | sh || fatal "Failed to install Docker"; set_compose_cmd; if command -v systemctl &>/dev/null; then systemctl enable --now docker &>/dev/null; else service docker start &>/dev/null; fi; [[ -n "${SUDO_USER:-}" ]] && usermod -aG docker "$SUDO_USER" && log INFO "Added $SUDO_USER to docker group"; }

#--------------------------------------
# Install Docker Compose
#--------------------------------------
install_compose(){ set_compose_cmd; if [[ -n "$COMPOSE_CMD" ]]; then local cur=$($COMPOSE_CMD version --short 2>/dev/null); if [[ -n "$cur" && $(version_ge "$cur" "$MIN_COMPOSE_VERSION" && echo yes) == yes ]]; then log INFO "Docker Compose $cur OK"; return; fi; fi; log INFO "Installing docker-compose plugin"; case "$OS" in ubuntu|debian) apt-get update -qq && apt-get install -y docker-buildx-plugin docker-compose-plugin -qq ;; centos|rhel) yum install -y docker-buildx-plugin docker-compose-plugin -q ;; fedora) dnf install -y docker-buildx-plugin docker-compose-plugin -q ;; *) fatal "Compose plugin install unsupported on $OS" ;; esac; set_compose_cmd; [[ -n "$COMPOSE_CMD" ]] || fatal "docker-compose command not found"; log INFO "Docker Compose ready ($($COMPOSE_CMD version --short 2>/dev/null))"; }

#--------------------------------------
# Backup & Restore
#--------------------------------------
create_backup(){ log INFO "Creating backup..."; [[ ! -d "$BEACON_DIR_NAME" && ! -d "$HOME/.blockcast" ]] && log WARN "Nothing to backup" && return; mkdir -p "$BACKUP_STAGING_DIR"; [[ -d "$HOME/.blockcast" ]] && cp -a "$HOME/.blockcast" "$BACKUP_STAGING_DIR/"; [[ -d "$BEACON_DIR_NAME" ]] && cp -a "$BEACON_DIR_NAME" "$BACKUP_STAGING_DIR/"; cat >"$BACKUP_STAGING_DIR/info.txt" <<EOF
Backup created: $(date)
Script version: ${SCRIPT_VERSION}
OS: $OS $OS_VERSION
Docker: $(docker --version || echo none)
Compose: $($COMPOSE_CMD version --short || echo none)
EOF; local tarfile="$SCRIPT_DIR/${BACKUP_TAR_PREFIX}.tar.gz"; tar -czf "$tarfile" -C "$(dirname "$BACKUP_STAGING_DIR")" "$(basename "$BACKUP_STAGING_DIR")"; rm -rf "$BACKUP_STAGING_DIR"; log INFO "Backup saved to $tarfile"; }
restore_backup(){ local tarfile="$1"; [[ -f "$tarfile" ]] || fatal "Backup file not found: $tarfile"; log INFO "Restoring from $tarfile"; local tmpdir="/tmp/restore_$$"; mkdir -p "$tmpdir"; tar -xzf "$tarfile" -C "$tmpdir"; cp -a "$tmpdir"/*/ .; rm -rf "$tmpdir"; log INFO "Restore complete"; }

#--------------------------------------
# Clone & Start Services
#--------------------------------------
clone_repo(){ log INFO "Cloning repository..."; [[ -d "$BEACON_DIR_NAME" ]] && mv "$BEACON_DIR_NAME" "${BEACON_DIR_NAME}.bak.$(date +%s)"; git clone "$BEACON_REPO_URL" "$BEACON_DIR_NAME" || fatal "git clone failed"; }
start_blockcast(){ log INFO "Starting Blockcast BEACON services..."; pushd "$BEACON_DIR_NAME" &>/dev/null; $COMPOSE_CMD pull || fatal "Failed to pull images"; $COMPOSE_CMD up -d || fatal "Failed to start services"; popd &>/dev/null; }

#--------------------------------------
# Key Generation
#--------------------------------------
extract_field(){ grep -i "$1" | cut -d: -f2- | xargs; }
generate_keys(){ log INFO "Generating hardware and challenge keys..."; pushd "$BEACON_DIR_NAME" &>/dev/null; local out=$($COMPOSE_CMD exec -T blockcastd blockcastd init 2>&1) || fatal "Init command failed"; popd &>/dev/null; local hwid=$(echo "$out" | extract_field "Hardware ID"); local ck=$(echo "$out" | extract_field "Challenge Key"); local ru=$(echo "$out" | extract_field "Registration URL"); [[ -n "$hwid" && -n "$ck" ]] || fatal "Failed to parse init output"; echo -e "\n${GREEN}Setup Complete!${NC}\nHardware ID: $hwid\nChallenge Key: $ck\nRegistration URL: $ru"; echo "$out" | grep -iE "commit|build|version"; }

#--------------------------------------
# Uninstall
#--------------------------------------
uninstall_blockcast(){ set_compose_cmd; log INFO "Uninstalling Blockcast BEACON..."; if [[ -d "$BEACON_DIR_NAME" ]]; then pushd "$BEACON_DIR_NAME" &>/dev/null; $COMPOSE_CMD down --volumes --remove-orphans &>/dev/null; popd &>/dev/null; rm -rf "$BEACON_DIR_NAME"; fi; read -p "Remove Blockcast Docker images? [y/N]: " ans; [[ $ans =~ ^[Yy] ]] && docker image prune -af; log INFO "Uninstall complete"; }

#--------------------------------------
# Main
#--------------------------------------
main(){ print_banner; local action="install" dry_run=0 restore_file=""; while (( $# )); do case "$1" in -i|--install) action="install";; -u|--uninstall) action="uninstall";; -b|--backup) action="backup";; -r|--restore) action="restore"; restore_file="$2"; shift;; -c|--check) action="check";; -v|--verbose) DEBUG_LEVEL=1;; --dry-run) dry_run=1;; -h|--help) usage; exit 0;; *) fatal "Unknown option: $1";; esac; shift; done; detect_os; check_requirements; case "$action" in install) (( dry_run )) && { log INFO "DRY RUN: install"; exit 0; }; install_docker; install_compose; clone_repo; start_blockcast; generate_keys;; uninstall) (( dry_run )) && { log INFO "DRY RUN: uninstall"; exit 0; }; uninstall_blockcast;; backup) create_backup;; restore) restore_backup "$restore_file";; check) log INFO "System check passed";; esac; }
main "$@"
