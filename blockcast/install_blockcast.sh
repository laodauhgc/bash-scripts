#!/usr/bin/env bash

###############################################################################
# Blockcast BEACON Setup Script - v3.0 (Hardened & Portable)
# Supported OS  : Ubuntu 18.04+/Debian 10+/RHEL/CentOS 7+/Fedora 33+
# Architectures : x86_64/amd64, arm64/aarch64
# Requirements  : root privileges (sudo), internet access (for install path)
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
readonly MIN_COMPOSE_VERSION="2.0.0"   # v2 plugin preferred
readonly DISK_MIN_GB=10
readonly MEM_MIN_GB=2

# Colors
readonly RED='\033[0;31m'; readonly GREEN='\033[0;32m'; readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'; readonly PURPLE='\033[0;35m'; readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Globals (mutable)
OS=""; OS_VERSION=""; OS_CODENAME=""; ARCH=""; COMPOSE_CMD=""
DEBUG_LEVEL=${DEBUG:-0}

#--------------------------------------
# Logging helpers
#--------------------------------------
log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"

  # color prefix
  local color=""; local tag="[$level]"
  case "$level" in
    INFO)  color="$GREEN";;
    WARN)  color="$YELLOW";;
    ERROR) color="$RED";;
    DEBUG) color="$PURPLE";;
  esac

  # Respect DEBUG level
  if [[ "$level" == DEBUG && "$DEBUG_LEVEL" -ne 1 ]]; then
    echo "[$ts] [DEBUG] $msg" >>"$LOG_FILE"
    return
  fi

  echo -e "${color}${tag}${NC} $msg" | tee -a "$LOG_FILE" >&2
  [[ "$level" == DEBUG ]] || echo "[$ts] [$level] $msg" >>"$LOG_FILE"
}

fatal() { log ERROR "$*"; exit 1; }

cleanup() {
  local code=$?
  if (( code != 0 )); then
    log ERROR "Script failed with exit code $code. See $LOG_FILE"
  fi
  tput sgr0 2>/dev/null || true
  exit $code
}
trap cleanup EXIT

#--------------------------------------
# Utility functions
#--------------------------------------
# Return 0 if v1 >= v2
version_ge() {
  local v1="$1" v2="$2"
  if command -v dpkg >/dev/null 2>&1; then
    dpkg --compare-versions "$v1" ge "$v2"
  else
    [[ "$(printf '%s\n' "$v2" "$v1" | sort -V | head -n1)" == "$v2" ]]
  fi
}

# Curl with sane defaults
_fetch() {
  curl -fsSL --proto '=https' --tlsv1.2 "$@"
}

# Detect docker compose command (plugin or legacy)
set_compose_cmd() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
  else
    COMPOSE_CMD=""   # will install later
  fi
}

#--------------------------------------
# Pretty banner / help
#--------------------------------------
print_banner() {
  echo -e "${CYAN}"
  echo "╔══════════════════════════════════════════════════════════════════════╗"
  echo "║                    Blockcast BEACON Setup Script v3.0               ║"
  echo "║                     Hardened, Portable, Reliable                    ║"
  echo "╚══════════════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

usage() {
  cat <<EOF
Usage: sudo ./${SCRIPT_NAME} [OPTIONS]

Actions (pick one):
  -i, --install              Install Blockcast BEACON (default)
  -u, --uninstall            Uninstall Blockcast BEACON
  -b, --backup               Create backup of current installation
  -r, --restore <FILE>       Restore from backup tar.gz file
  -c, --check                Only check system requirements

Flags:
  -v, --verbose              Enable debug logging
      --dry-run              Print what would be done, don't execute
  -h, --help                 Show this help

Examples:
  sudo ./${SCRIPT_NAME}
  sudo ./${SCRIPT_NAME} --uninstall
  sudo ./${SCRIPT_NAME} --backup
  sudo ./${SCRIPT_NAME} --restore ./blockcast_backup_20250101_120000.tar.gz
EOF
}

#--------------------------------------
# Detection & requirement checks
#--------------------------------------

detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    OS="$ID"; OS_VERSION="$VERSION_ID"; OS_CODENAME="${VERSION_CODENAME:-}"
  elif [[ -f /etc/redhat-release ]]; then
    OS="centos"
    OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | head -1)
  else
    fatal "Unsupported operating system"
  fi
  ARCH=$(uname -m)
  log INFO "Detected OS: $OS $OS_VERSION ($ARCH)"
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    fatal "Run as root. Example: sudo $SCRIPT_NAME"
  fi
}

check_requirements() {
  log INFO "Checking system requirements…"
  check_root

  # arch
  if [[ ! "$ARCH" =~ ^(x86_64|amd64|arm64|aarch64)$ ]]; then
    fatal "Unsupported architecture: $ARCH"
  fi

  # disk
  local avail_kb
  avail_kb=$(df --output=avail -k / | tail -1 | tr -d ' ')
  local need_kb=$((DISK_MIN_GB * 1024 * 1024))
  if (( avail_kb < need_kb )); then
    fatal "Need at least ${DISK_MIN_GB}GB free on /"
  fi

  # memory
  local mem_kb
  if grep -q MemAvailable /proc/meminfo; then
    mem_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
  else
    mem_kb=$(free -k | awk '/^Mem:/ {print $2}')
  fi
  local need_mem_kb=$((MEM_MIN_GB * 1024 * 1024))
  if (( mem_kb < need_mem_kb )); then
    log WARN "Detected < ${MEM_MIN_GB}GB RAM. Proceeding anyway."
  fi
  log INFO "System requirements OK"
}

#--------------------------------------
# Package install helpers
#--------------------------------------
update_pkg_index() {
  log INFO "Updating package index…"
  case "$OS" in
    ubuntu|debian) apt-get update -qq ;;
    centos|rhel)   yum makecache -q    ;;
    fedora)        dnf makecache -q    ;;
    *) fatal "Unsupported OS for package manager updates";;
  esac
}

install_pkgs() {
  local pkgs=("$@")
  (( ${#pkgs[@]} == 0 )) && return 0
  log INFO "Installing packages: ${pkgs[*]}"
  case "$OS" in
    ubuntu|debian)
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" ;;
    centos|rhel)
      yum install -y -q "${pkgs[@]}" ;;
    fedora)
      dnf install -y -q "${pkgs[@]}" ;;
    *) fatal "Unsupported OS for package installation";;
  esac
}

#--------------------------------------
# Docker & Compose
#--------------------------------------
install_docker() {
  if command -v docker >/dev/null 2>&1; then
    local cur
    cur=$(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    if [[ -n "$cur" ]] && version_ge "$cur" "$MIN_DOCKER_VERSION"; then
      log INFO "Docker $cur OK"
      return
    else
      log WARN "Docker $cur < $MIN_DOCKER_VERSION, upgrading"
    fi
  fi

  log INFO "Installing Docker Engine…"
  case "$OS" in
    ubuntu|debian)
      install_pkgs ca-certificates curl gnupg lsb-release
      install_pkgs apt-transport-https software-properties-common
      install_pkgs gnupg-agent
      install_pkgs uidmap # rootless option later if needed

      _fetch https://download.docker.com/linux/$OS/gpg | gpg --dearmor -o /usr/share/keyrings/docker.gpg
      echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/$OS $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list
      apt-get update -qq
      install_pkgs docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;
    centos|rhel|fedora)
      install_pkgs ca-certificates curl gnupg2
      if [[ "$OS" == fedora ]]; then
        dnf -y config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
        install_pkgs docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      else
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        install_pkgs docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      fi
      ;;
    *) fatal "Docker auto-install not implemented for $OS" ;;
  esac

  # Start service if systemd
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker || fatal "Could not enable/start docker"
  else
    service docker start || true
  fi

  # Add invoking user to docker group
  if [[ -n "${SUDO_USER:-}" ]]; then
    usermod -aG docker "$SUDO_USER" || log WARN "Could not add $SUDO_USER to docker group"
    log INFO "User $SUDO_USER added to docker group. Re-login required to take effect."
  fi
}

install_compose() {
  set_compose_cmd
  if [[ -n "$COMPOSE_CMD" ]]; then
    local cur
    if [[ "$COMPOSE_CMD" == "docker compose" ]]; then
      cur=$(docker compose version --short | tr -d 'v' || true)
    else
      cur=$(docker-compose --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    fi
    if version_ge "${cur:-0}" "$MIN_COMPOSE_VERSION"; then
      log INFO "Docker Compose $cur OK"
      return
    fi
  fi

  log INFO "Installing Docker Compose plugin v2…"
  # If docker-compose-plugin not installed above, install manually
  local plugin_dir="/usr/local/libexec/docker/cli-plugins"
  mkdir -p "$plugin_dir"
  local os_lower=linux arch_lower
  case "$ARCH" in
    x86_64|amd64) arch_lower=amd64 ;;
    aarch64|arm64) arch_lower=arm64 ;;
    *) fatal "Unsupported arch for compose plugin: $ARCH" ;;
  esac
  local ver="v2.27.1"  # pin or update regularly
  _fetch "https://github.com/docker/compose/releases/download/${ver}/docker-compose-${os_lower}-${arch_lower}" \
    -o "${plugin_dir}/docker-compose" || fatal "Failed download compose"
  chmod +x "${plugin_dir}/docker-compose"
  set_compose_cmd
  [[ -z "$COMPOSE_CMD" ]] && fatal "Failed to install docker compose"
}

#--------------------------------------
# Backup / Restore
#--------------------------------------
create_backup() {
  log INFO "Creating backup…"

  if [[ ! -d "$BEACON_DIR_NAME" && ! -d "$HOME/.blockcast" ]]; then
    log WARN "No installation found to backup"
    return 0
  fi

  mkdir -p "$BACKUP_STAGING_DIR"
  [[ -d "$HOME/.blockcast" ]] && cp -a "$HOME/.blockcast" "$BACKUP_STAGING_DIR/"
  [[ -d "$BEACON_DIR_NAME" ]] && cp -a "$BEACON_DIR_NAME" "$BACKUP_STAGING_DIR/"

  cat >"$BACKUP_STAGING_DIR/backup_info.txt" <<EOF
Backup created: $(date)
Script version: 3.0
OS: $OS $OS_VERSION
Docker: $(docker --version 2>/dev/null || echo 'not installed')
Compose: $($COMPOSE_CMD version 2>/dev/null || echo 'not installed')
EOF

  local tar_file="${SCRIPT_DIR}/${BACKUP_TAR_PREFIX}.tar.gz"
  tar -czf "$tar_file" -C "$(dirname "$BACKUP_STAGING_DIR")" "$(basename "$BACKUP_STAGING_DIR")"
  rm -rf "$BACKUP_STAGING_DIR"

  log INFO "Backup created: $tar_file"
  echo -e "${GREEN}Backup file: $tar_file${NC}"
}

restore_backup() {
  local tar_file="$1"
  [[ -z "$tar_file" ]] && fatal "--restore requires a file"
  [[ -f "$tar_file" ]] || fatal "Backup file not found: $tar_file"

  log INFO "Restoring from $tar_file …"
  local tmp_dir="/tmp/blockcast_restore_$$"
  mkdir -p "$tmp_dir"
  tar -xzf "$tar_file" -C "$tmp_dir"

  # Detect dir pattern we stored (starts with .blockcast_backup_) or any single dir
  local inner_dir
  inner_dir=$(find "$tmp_dir" -maxdepth 1 -type d -name "*.blockcast_backup_*" -o -type d -mindepth 1 -print | head -1)
  [[ -z "$inner_dir" ]] && fatal "Invalid backup structure"

  [[ -d "$inner_dir/.blockcast" ]] && cp -a "$inner_dir/.blockcast" "$HOME/"
  if [[ -d "$inner_dir/$BEACON_DIR_NAME" ]]; then
    rm -rf "$BEACON_DIR_NAME"
    cp -a "$inner_dir/$BEACON_DIR_NAME" ./
  fi

  rm -rf "$tmp_dir"
  log INFO "Restore complete."
}

#--------------------------------------
# Clone / start services
#--------------------------------------
clone_repo() {
  log INFO "Cloning Blockcast repo…"
  if [[ -d "$BEACON_DIR_NAME" ]]; then
    local bak="${BEACON_DIR_NAME}.bak.$(date +%s)"
    mv "$BEACON_DIR_NAME" "$bak"
    log INFO "Existing repo moved to $bak"
  fi

  git clone "$BEACON_REPO_URL" "$BEACON_DIR_NAME" || fatal "git clone failed"
  [[ -f "$BEACON_DIR_NAME/docker-compose.yml" ]] || fatal "docker-compose.yml missing in repo"
  log INFO "Repository cloned"
}

start_blockcast() {
  pushd "$BEACON_DIR_NAME" >/dev/null
  log INFO "Pulling images…"
  $COMPOSE_CMD pull || fatal "Compose pull failed"

  log INFO "Starting services…"
  $COMPOSE_CMD up -d || fatal "Compose up failed"

  # Wait for containers to come up (healthcheck aware if defined)
  log INFO "Waiting for services to initialize…"
  local max_wait=180 step=5 waited=0 ok=0
  while (( waited < max_wait )); do
    if $COMPOSE_CMD ps --format json 2>/dev/null | grep -q '"State":"running"'; then
      ok=1; break
    fi
    sleep $step; waited=$((waited+step))
    log DEBUG "Waiting… ${waited}/${max_wait}s"
  done
  (( ok == 1 )) || { $COMPOSE_CMD ps; fatal "Services failed to start in $max_wait seconds"; }
  popd >/dev/null
  log INFO "Services started"
}

#--------------------------------------
# Key generation
#--------------------------------------
extract_field() { # extract 'Hardware ID: xxxx' style
  grep -i "$1" | sed "s/.*$1[[:space:]]*:[[:space:]]*//" | tr -d '\r' | sed 's/[[:space:]]*$//' 
}

generate_keys() {
  pushd "$BEACON_DIR_NAME" >/dev/null
  log INFO "Generating hardware and challenge keys…"

  local try=0 max=3 out=""
  until (( try==max )); do
    if out=$($COMPOSE_CMD exec -T blockcastd blockcastd init 2>&1); then
      break
    fi
    try=$((try+1))
    log WARN "Init attempt $try failed, retrying in 10s…"
    sleep 10
  done
  (( try==max )) && fatal "Failed to generate keys after $max attempts. Last output:\n$out"
  [[ -n "$out" ]] || fatal "Empty init output"

  local hwid challenge_key reg_url
  hwid=$(echo "$out" | extract_field "Hardware ID")
  challenge_key=$(echo "$out" | extract_field "Challenge Key")
  reg_url=$(echo "$out" | extract_field "Registration URL")
  [[ -n "$hwid" && -n "$challenge_key" ]] || fatal "Could not parse keys from init output"

  popd >/dev/null

  echo -e "\n${GREEN}╔══════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║                     Blockcast BEACON Setup Complete!                ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════════╝${NC}\n"

  echo -e "${CYAN}====== BACK UP THIS INFORMATION ======${NC}"
  echo -e "${YELLOW}Hardware ID:${NC} $hwid"
  echo -e "${YELLOW}Challenge Key:${NC} $challenge_key"
  [[ -n "$reg_url" ]] && echo -e "${YELLOW}Registration URL:${NC} $reg_url"

  echo -e "\n${CYAN}Build Information:${NC}"
  echo "$out" | grep -i -E "commit|build|version" | sed 's/^/  /'

  echo -e "\n${RED}⚠  SECURITY WARNING: Keep the following private keys secure!${NC}"
  echo -e "${CYAN}Private Keys Location:${NC}"
  local cert_dir="${HOME}/.blockcast/certs"
  for f in gw_challenge.key gateway.key gateway.crt; do
    local p="$cert_dir/$f"
    if [[ -f "$p" ]]; then
      echo -e "\n${YELLOW}$f${NC}\nLocation: $p"
      [[ $f == *.key ]] && { echo -e "${RED}Content:${NC}"; cat "$p"; }
    fi
  done
  echo -e "${CYAN}====== END BACKUP INFORMATION ======${NC}\n"

  cat >"${SCRIPT_DIR}/blockcast_node_info_$(date +%Y%m%d_%H%M%S).txt" <<EOF
Blockcast BEACON Node Information
Generated: $(date)

Hardware ID: $hwid
Challenge Key: $challenge_key
Registration URL: $reg_url

Build Information:
$(echo "$out" | grep -i -E "commit|build|version")

Certificate Files Location: $cert_dir
EOF
  log INFO "Node info saved to script directory"

  echo -e "${BLUE}Next Steps:${NC}"
  echo "1. Visit https://app.blockcast.network/ and log in"
  echo "2. Manage Nodes > Register Node"
  echo "3. Enter the Hardware ID & Challenge Key above (or use Registration URL)"
  echo "4. Provide VM location"
  echo "5. Store the info/keys securely"
  echo "\n${GREEN}Notes:${NC}"
  echo "• Node should show 'Healthy' after a few minutes"
  echo "• First connectivity test ~6h, rewards ~24h"
  echo "• Monitor logs: $COMPOSE_CMD logs -f"
}

#--------------------------------------
# Uninstall
#--------------------------------------
uninstall_blockcast() {
  log INFO "Uninstalling Blockcast BEACON…"
  if [[ -d "$BEACON_DIR_NAME" ]]; then
    pushd "$BEACON_DIR_NAME" >/dev/null
    if [[ -f docker-compose.yml || -f compose.yml ]]; then
      log INFO "Stopping containers…"
      $COMPOSE_CMD down --volumes --remove-orphans || log WARN "Couldn't stop containers cleanly"
    fi
    popd >/dev/null
    rm -rf "$BEACON_DIR_NAME"
    log INFO "Removed repo dir"
  else
    log WARN "Repo dir not found"
  fi

  read -r -p "Remove Blockcast Docker images? [y/N]: " ans
  if [[ $ans =~ ^[Yy]$ ]]; then
    docker images --format '{{.Repository}} {{.ID}}' | awk '/blockcast|beacon/ {print $2}' | xargs -r docker rmi -f
    log INFO "Images removed"
  fi
  log INFO "Uninstall complete"
}

#--------------------------------------
# Dry-run helper
#--------------------------------------
print_plan() {
  cat <<EOF
DRY RUN – actions that would be executed:
  1. detect_os & check_requirements
  2. update_pkg_index & install docker + compose plugin if missing
  3. install git/curl
  4. clone $BEACON_REPO_URL into $BEACON_DIR_NAME
  5. pull images & start services via docker compose
  6. run blockcastd init to generate keys
  7. save node info to file
EOF
}

#--------------------------------------
# Main installer
#--------------------------------------
install_blockcast() {
  detect_os
  check_requirements
  update_pkg_index
  install_pkgs git curl gnupg
  install_docker
  install_compose
  clone_repo
  start_blockcast
  generate_keys
  log INFO "Installation completed successfully!"
}

#--------------------------------------
# CLI parsing & dispatch
#--------------------------------------
main() {
  touch "$LOG_FILE"
  print_banner

  local action="install" dry_run=0 backup_file=""
  while (( $# )); do
    case "$1" in
      -i|--install)   action="install" ; shift ;;
      -u|--uninstall) action="uninstall" ; shift ;;
      -b|--backup)    action="backup" ; shift ;;
      -r|--restore)   action="restore" ; backup_file="${2:-}"; [[ -z "$backup_file" ]] && fatal "--restore needs a file"; shift 2 ;;
      -c|--check)     action="check" ; shift ;;
      -v|--verbose)   DEBUG_LEVEL=1 ; shift ;;
      --dry-run)      dry_run=1 ; shift ;;
      -h|--help)      usage; exit 0 ;;
      *) fatal "Unknown option: $1" ;;
    esac
  done

  case "$action" in
    install)
      if (( dry_run )); then
        detect_os; check_requirements; print_plan; exit 0
      fi
      install_blockcast ;;
    uninstall)
      (( dry_run )) && { log INFO "DRY RUN: would uninstall"; exit 0; }
      set_compose_cmd
      uninstall_blockcast ;;
    backup)
      detect_os
      create_backup ;;
    restore)
      detect_os
      restore_backup "$backup_file" ;;
    check)
      detect_os; check_requirements; log INFO "System check completed" ;;
  esac
}

main "$@"
