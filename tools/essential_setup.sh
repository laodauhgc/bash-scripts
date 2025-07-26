#!/usr/bin/env bash
# ==============================================================================
# Ubuntu Core Dev Environment Setup Script
# Version 3.1.0 – 2025‑07‑26
# ==============================================================================

set -Eeuo pipefail
trap 'echo -e "\033[0;31m❌  Error on line $LINENO: $BASH_COMMAND\033[0m" >&2' ERR

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8

# ---------- Metadata ----------------------------------------------------------
SCRIPT_VERSION="3.1.0"
SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/tmp/${SCRIPT_NAME%.*}.log"
LOCK_FILE="/tmp/${SCRIPT_NAME%.*}.lock"

# ---------- Colour (màu ra terminal, log file không màu) ----------------------
if [[ -t 1 ]]; then
  C_RED='\033[0;31m'; C_GRN='\033[0;32m'; C_YLW='\033[1;33m'
  C_BLU='\033[0;34m'; C_CYA='\033[0;36m'; C_RST='\033[0m'
else C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_CYA=''; C_RST=''; fi

_strip() { sed -r 's/\x1b\[[0-9;]*[mK]//g'; }
_log()   { local ts; ts=$(date '+%F %T'); echo -e "${2}[ $ts ] $1${C_RST}";
           echo -e "$(_strip "$1")" >> "$LOG_FILE"; }
info()   { _log "ℹ️  $1" "$C_BLU"; }
ok()     { _log "✅ $1" "$C_GRN"; }
warn()   { _log "⚠️  $1" "$C_YLW"; }
err()    { _log "❌ $1" "$C_RED"; }

# ---------- Lock to avoid concurrent runs ------------------------------------
[[ -e $LOCK_FILE ]] && { err "Another instance is running. Remove $LOCK_FILE to continue."; exit 1; }
echo $$ >"$LOCK_FILE"; trap 'rm -f "$LOCK_FILE"' EXIT

# ---------- Pretty banner ----------------------------------------------------
if command -v figlet &>/dev/null; then
  echo -e "${C_CYA}$(figlet -w 120 "Ubuntu Core Setup v$SCRIPT_VERSION")${C_RST}"
else
  echo -e "${C_CYA}╔══════════════════════════════════════════════════════════╗
║            Ubuntu Core Setup Script  v$SCRIPT_VERSION            ║
╚══════════════════════════════════════════════════════════╝${C_RST}"
fi

# ---------- Basic checks -----------------------------------------------------
[[ $EUID -eq 0 ]] || { err "Please run as root or with sudo."; exit 1; }
. /etc/os-release
[[ $ID == "ubuntu" ]] || { err "This script supports Ubuntu only."; exit 1; }
info "Detected: $PRETTY_NAME – Kernel $(uname -r)"

# ---------- Package manager helpers -----------------------------------------
apt_update()  { apt-get update -qq; }
apt_install() { apt-get install -y --no-install-recommends "$@"; }

info "Updating package lists…"; apt_update

# ---------- Package list (core + dev headers) --------------------------------
PACKAGE_LIST=(
  build-essential git curl wget vim htop rsync zip unzip bash-completion
  python3 python3-venv python3-pip ca-certificates gnupg software-properties-common
  plocate openssh-client
  libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev
  libffi-dev liblzma-dev libncursesw5-dev uuid-dev
)

# ---------- Install missing packages ----------------------------------------
missing=()
for pkg in "${PACKAGE_LIST[@]}"; do dpkg -s "$pkg" &>/dev/null || missing+=("$pkg"); done

if [[ ${#missing[@]} -gt 0 ]]; then
  info "Installing ${#missing[@]} packages…"
  apt_install "${missing[@]}"
else
  ok "All required packages are already installed."
fi

# ---------- Post steps -------------------------------------------------------
info "Running plocate database build in background…"
updatedb &>/dev/null || true

info "Cleaning APT cache…"
apt-get autoremove -y -qq || true
apt-get clean -qq

ok "🎉  Core development environment ready!"
echo    "→ Detailed log: $LOG_FILE"
