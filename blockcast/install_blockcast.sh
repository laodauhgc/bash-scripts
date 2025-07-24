#!/usr/bin/env bash
###############################################################################
# Blockcast BEACON Setup Script - v3.1 (Hardened & Portable)
# - Uses official Docker installer from https://get.docker.com
# - Prefer official docker-compose-plugin on Ubuntu/Debian
# Supported OS  : Ubuntu 18.04+/Debian 10+/RHEL/CentOS 7+/Fedora 33+
# Architectures : x86_64/amd64, arm64/aarch64
###############################################################################

set -eEuo pipefail
IFS=$'\n\t'

#--------------------------------------
# Constants / Defaults
#--------------------------------------
readonly SCRIPT_NAME="$(basename "$0")"
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
defaults
readonly RED='\033[0;31m'; readonly GREEN='\033[0;32m'; readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'; readonly PURPLE='\033[0;35m'; readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Globals
OS=""; OS_VERSION=""; OS_CODENAME=""; ARCH=""; COMPOSE_CMD=""
DEBUG_LEVEL=${DEBUG:-0}

#--------------------------------------
# Logging
#--------------------------------------
log() {
  local level="$1"; shift
  local msg="$*"
  local ts=$(date '+%Y-%m-%d %H:%M:%S')
  local color=""
  case "$level" in
    INFO)  color="$GREEN" ;; WARN)  color="$YELLOW" ;; ERROR) color="$RED" ;; DEBUG) color="$PURPLE" ;;
  esac
  if [[ "$level" == DEBUG && "$DEBUG_LEVEL" -ne 1 ]]; then
    echo "[$ts] [DEBUG] $msg" >>"$LOG_FILE"
    return
  fi
  echo -e "${color}[$level]${NC} $msg" | tee -a "$LOG_FILE" >&2
  [[ "$level" == DEBUG ]] || echo "[$ts] [$level] $msg" >>"$LOG_FILE"
}

fatal(){ log ERROR "$*"; exit 1; }
cleanup(){ local code=$?; ((code!=0)) && log ERROR "Script failed ($code). See $LOG_FILE"; tput sgr0 2>/dev/null||true; exit $code; }
trap cleanup EXIT

#--------------------------------------
# Utils
#--------------------------------------
version_ge(){ dpkg --compare-versions "$1" ge "$2" 2>/dev/null || [[ "$(printf '%s\n' "$2" "$1"|sort -V|head -n1)"=="$2" ]]; }
_fetch(){ curl -fsSL --proto '=https' --tlsv1.2 "$@"; }
set_compose_cmd(){ if command -v docker &>/dev/null && docker compose version &>/dev/null; then COMPOSE_CMD="docker compose"; elif command -v docker-compose &>/dev/null; then COMPOSE_CMD="docker-compose"; else COMPOSE_CMD=""; fi; }

print_banner(){ echo -e "${CYAN}"; cat <<'EOF'
╔══════════════════════════════════════════════════════════════════════╗
║                    Blockcast BEACON Setup Script v3.1               ║
║                     Hardened, Portable, Reliable                    ║
╚══════════════════════════════════════════════════════════════════════╝
EOF; echo -e "${NC}"; }
usage(){ cat <<EOF
Usage: sudo ./${SCRIPT_NAME} [OPTIONS]

Actions:
  -i, --install       Install Blockcast BEACON (default)
  -u, --uninstall     Uninstall Blockcast BEACON
  -b, --backup        Backup current installation
  -r, --restore FILE  Restore from backup tar.gz
  -c, --check         Check system requirements

Flags:
  -v, --verbose       Enable debug logs
      --dry-run       Show actions without executing
  -h, --help          Show this help
EOF
}

#--------------------------------------
# Environment Checks
#--------------------------------------
detect_os(){
  if [[ -f /etc/os-release ]]; then source /etc/os-release; OS="$ID"; OS_VERSION="$VERSION_ID"; OS_CODENAME="${VERSION_CODENAME:-}";
  elif [[ -f /etc/redhat-release ]]; then OS="centos"; OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release|head -1);
  else fatal "Unsupported OS"; fi;
  ARCH=$(uname -m); log INFO "OS: $OS $OS_VERSION ($ARCH)";
}
check_root(){ [[ $EUID -ne 0 ]] && fatal "Run as root (sudo $SCRIPT_NAME)"; }
check_requirements(){ log INFO "Checking reqs..."; check_root;
  [[ "$ARCH" =~ ^(x86_64|amd64|arm64|aarch64)$ ]] || fatal "Arch $ARCH unsupported";
  local avail=$(df --output=avail -k /|tail -1); local need=$((DISK_MIN_GB*1024*1024)); ((avail<need))&&fatal"Need $DISK_MIN_GB GB free";
  local mem=$(awk '/MemTotal/ {print $2}' /proc/meminfo); local needm=$((MEM_MIN_GB*1024*1024)); ((mem<needm))&&log WARN"<${MEM_MIN_GB}GB RAM";
  log INFO"Requirements OK";
}

#--------------------------------------
# Docker Installation
#--------------------------------------
install_docker(){
  if command -v docker &>/dev/null; then
    local cur=$(docker --version|grep -oE '[0-9]+\.[0-9]+\.[0-9]+'|head -1||echo);
    if [[ -n "$cur" ]] && version_ge "$cur" "$MIN_DOCKER_VERSION"; then log INFO"Docker $cur OK"; return; fi;
    log WARN"Docker $cur < $MIN_DOCKER_VERSION, using get.docker.com";
  fi
  log INFO"Installing Docker via get.docker.com";
  _fetch https://get.docker.com | sh || fatal"Docker install failed";
  set_compose_cmd; systemctl enable --now docker &>/dev/null || service docker start &>/dev/null;
  [[ -n "${SUDO_USER:-}" ]] && usermod -aG docker "$SUDO_USER" && log INFO"$SUDO_USER added to docker group";
}

#--------------------------------------
# Docker Compose Installation
#--------------------------------------
install_compose(){
  set_compose_cmd;
  if [[ -n "$COMPOSE_CMD" ]]; then
    local cur=$($COMPOSE_CMD version --short 2>/dev/null||echo);
    if [[ -n "$cur" ]] && version_ge "$cur" "$MIN_COMPOSE_VERSION"; then log INFO"Compose $cur OK"; return; fi;
  fi
  log INFO"Installing Compose plugin";
  case "$OS" in
    ubuntu|debian) apt-get update -qq && apt-get install -y docker-buildx-plugin docker-compose-plugin -qq;;
    centos|rhel) yum install -y docker-buildx-plugin docker-compose-plugin -q;;
    fedora) dnf install -y docker-buildx-plugin docker-compose-plugin -q;;
    *) fatal"Compose install unsupported on $OS";;
  esac
  set_compose_cmd; [[ -n "$COMPOSE_CMD" ]]||fatal"Compose not found";
  log INFO"Compose ready ($($COMPOSE_CMD version --short 2>/dev/null))";
}

#--------------------------------------
# Backup/Restore
#--------------------------------------
create_backup(){ log INFO"Backing up...";
  [[ ! -d "$BEACON_DIR_NAME" && ! -d "$HOME/.blockcast" ]]&&log WARN"Nothing to backup"&&return;
  mkdir -p "$BACKUP_STAGING_DIR";
  cp -a "$HOME/.blockcast" "$BACKUP_STAGING_DIR/" 2>/dev/null||true;
  cp -a "$BEACON_DIR_NAME" "$BACKUP_STAGING_DIR/" 2>/dev/null||true;
  cat>"$BACKUP_STAGING_DIR/info.txt"<<EOF
Backup: $(date)
Script: v3.1
OS: $OS $OS_VERSION
Docker: $(docker --version||echo none)
Compose: $($COMPOSE_CMD version --short||echo none)
EOF
  local tf="$SCRIPT_DIR/${BACKUP_TAR_PREFIX}.tar.gz";
  tar -czf "$tf" -C "$(dirname "$BACKUP_STAGING_DIR")" "$(basename "$BACKUP_STAGING_DIR")";
  rm -rf "$BACKUP_STAGING_DIR";
  log INFO"Backup saved: $tf";
}
restore_backup(){ local f="$1"; [[ -f "$f" ]]||fatal"Backup $f missing";
  log INFO"Restoring $f";
  local tmp="/tmp/restore_$$"; mkdir -p "$tmp"; tar -xzf "$f" -C "$tmp";
  cp -a "$tmp"/*/ .; rm -rf "$tmp";
  log INFO"Restore complete";
}

#--------------------------------------
# Clone & Start Services
#--------------------------------------
clone_repo(){ log INFO"Cloning repo";
  [[ -d "$BEACON_DIR_NAME" ]]&&mv "$BEACON_DIR_NAME" "${BEACON_DIR_NAME}.bak.$(date +%s)";
  git clone "$BEACON_REPO_URL" "$BEACON_DIR_NAME"||fatal"git clone failed";
}
start_blockcast(){ log INFO"Starting Blockcast";
  pushd "$BEACON_DIR_NAME"&>/dev/null;
  $COMPOSE_CMD pull||fatal"Pull failed";
  $COMPOSE_CMD up -d||fatal"Up failed";
  popd&>/dev/null;
}

#--------------------------------------
# Key Generation
#--------------------------------------
extract_field(){ grep -i "$1"|cut -d: -f2- | xargs; }
generate_keys(){
  pushd "$BEACON_DIR_NAME"&>/dev/null;
  local out=$( $COMPOSE_CMD exec -T blockcastd blockcastd init 2>&1 )||fatal"Init failed";
  popd&>/dev/null;
  local hw=$(echo "$out"|extract_field "Hardware ID");
  local ck=$(echo "$out"|extract_field "Challenge Key");
  local ru=$(echo "$out"|extract_field "Registration URL");
  [[ -n "$hw" && -n "$ck" ]]||fatal"Parse keys failed";
  echo -e "\n${GREEN}Setup Complete!${NC}\nHardware ID: $hw\nChallenge Key: $ck\nRegistration URL: $ru";
  echo "$out"|grep -iE "commit|build|version";
}

#--------------------------------------
# Uninstall
#--------------------------------------
uninstall_blockcast(){ set_compose_cmd; log INFO"Uninstalling";
  [[ -d "$BEACON_DIR_NAME" ]]&&pushd "$BEACON_DIR_NAME"&>/dev/null&&$COMPOSE_CMD down --volumes --remove-orphans&>/dev/null&&popd&>/dev/null&&rm -rf "$BEACON_DIR_NAME";
  read -p"Remove images? [y/N]:" ans;
  [[ $ans =~ ^[Yy] ]]&&docker image prune -af;
  log INFO"Uninstall done";
}

#--------------------------------------
# Main
#--------------------------------------
main(){ print_banner; local action="install" dry=0 file="";
  while (( $# )); do case "$1" in
    -i|--install) action="install";; -u|--uninstall) action="uninstall";;
    -b|--backup) action="backup";; -r|--restore) action="restore"; file="$2"; shift;;
    -c|--check) action="check";; -v|--verbose) DEBUG_LEVEL=1;;
    --dry-run) dry=1;; -h|--help) usage; exit;; *) fatal"$1 unknown";; esac; shift; done
  detect_os; check_requirements;
  case "$action" in
    install) ((dry))&&{ log INFO"Dry run install"; exit; }; install_docker; install_compose; clone_repo; start_blockcast; generate_keys;;
    uninstall) ((dry))&&{ log INFO"Dry run uninstall"; exit; }; uninstall_blockcast;;
    backup) create_backup;; restore) restore_backup "$file";; check) log INFO"Check OK";;
  esac
}
main "$@"
