#!/usr/bin/env bash
# ==============================================================================
# Ubuntu Development Environment Setup Script
# Version 2.1.1 – 2025‑07‑26
# ==============================================================================

set -Eeuo pipefail
trap 'err_report $LINENO "$BASH_COMMAND"' ERR

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8

# ==== Metadata ===============================================================
readonly SCRIPT_VERSION="2.1.1"
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/tmp/${SCRIPT_NAME%.*}.log"
readonly LOCK_FILE="/tmp/${SCRIPT_NAME%.*}.lock"
readonly BACKUP_DIR="/tmp/setup_backup_$(date +%Y%m%d_%H%M%S)"

# ==== Colours ================================================================
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'
    WHITE='\033[1;37m'; RESET='\033[0m'; BOLD='\033[1m'
else
    RED='' GREEN='' YELLOW='' BLUE='' PURPLE='' CYAN='' WHITE='' RESET='' BOLD=''
fi

# ==== Logging ================================================================
timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
log()      { echo -e "${2:-$GREEN}[ $(timestamp) ] $1${RESET}" | tee -a "$LOG_FILE"; }
info()     { log "ℹ️  $1" "$BLUE"; }
success()  { log "✅ $1" "$GREEN"; }
warn()     { log "⚠️  $1" "$YELLOW"; }
error()    { log "❌ $1" "$RED"; }
debug()    { [[ "${DEBUG:-0}" == 1 ]] && log "🐛 $1" "$PURPLE"; }
header()   { log "\n${BOLD}$1${RESET}" "$CYAN"; }

err_report() { error "Lỗi tại dòng $1: $2"; cleanup; exit 1; }

# ==== Cleanup & Lock =========================================================
cleanup() { [[ -f "$LOCK_FILE" ]] && rm -f "$LOCK_FILE"; }
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid; pid=$(cat "$LOCK_FILE" || true)
        if [[ -n "$pid" && -d /proc/$pid ]]; then
            die "Script đang chạy (PID $pid).  Xoá $LOCK_FILE hoặc đợi."
        else
            warn "Phát hiện lock cũ – xoá..."
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ >"$LOCK_FILE"
    trap cleanup EXIT
}
die() { error "$1"; exit 1; }

# ==== Argument parsing =======================================================
DRY_RUN=0; SKIP_NODEJS=0; UPDATE_ONLY=0; CREATE_BACKUP=0; NODEJS_VERSION="lts"
show_help() {
cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION  –  Ubuntu Dev Env Installer
  -h|--help              Trợ giúp
  -v|--verbose           Debug chi tiết
  -n|--dry-run           Chỉ mô phỏng, không thực thi
  -s|--skip-nodejs       Bỏ cài Node.js
  -u|--update-only       Chỉ update, không cài mới
  --nodejs-version <v>   Chọn version Node.js (mặc định: lts)
  --backup               Sao lưu file cấu hình
EOF
}
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)   show_help; exit 0 ;;
            -v|--verbose)DEBUG=1; set -x; shift ;;
            -n|--dry-run)DRY_RUN=1; shift ;;
            -s|--skip-nodejs)SKIP_NODEJS=1; shift ;;
            -u|--update-only)UPDATE_ONLY=1; shift ;;
            --nodejs-version) NODEJS_VERSION=$2; shift 2 ;;
            --backup)   CREATE_BACKUP=1; shift ;;
            *)          die "Tùy chọn không hợp lệ: $1" ;;
        esac
    done
}

# ==== System info & checks ===================================================
get_system_info() {
    info "🔍 Thu thập thông tin hệ thống..."
    source /etc/os-release
    OS_ID="$ID"; OS_NAME="$NAME"; OS_VERSION="$VERSION_ID"
    KERNEL_VERSION="$(uname -r)"; ARCHITECTURE="$(uname -m)"
    TOTAL_RAM="$(free -h | awk '/^Mem:/ {print $2}')"
    AVAILABLE_SPACE="$(df -h / | awk 'NR==2 {print $4}')"
    info "OS: $OS_NAME $OS_VERSION  •  Kernel: $KERNEL_VERSION  •  Arch: $ARCHITECTURE"
}
check_root()   { [[ $EUID -eq 0 ]] || die "Cần quyền root."; success "Đang chạy với quyền root"; }
check_ubuntu() { [[ "$OS_ID" == "ubuntu" ]] || die "Chỉ hỗ trợ Ubuntu."; }

# ==== APT helpers ============================================================
UPDATE_CMD="apt-get update"
INSTALL_CMD="apt-get install -y --no-install-recommends"

ensure_pkg_tools() {
    if ! command -v add-apt-repository &>/dev/null; then
        info "Cài software-properties-common (add-apt-repository)..."
        $INSTALL_CMD software-properties-common >/dev/null
    fi
}

enable_universe() {
    header "🛠️ Kích hoạt kho universe"
    if [[ $DRY_RUN == 1 ]]; then info "DRY‑RUN: add‑apt‑repository universe"; return 0; fi
    add-apt-repository universe -y || warn "Universe đã bật."
    $UPDATE_CMD
}

check_network() {
    info "🌐 Kiểm tra kết nối mạng..."
    if ping -c1 -W3 8.8.8.8 &>/dev/null || ping -c1 -W3 google.com &>/dev/null; then
        success "Kết nối mạng OK."
    else
        die "Không có kết nối mạng."
    fi
}

fix_apt() {
    header "🛠️ Sửa lỗi APT"
    if [[ $DRY_RUN == 1 ]]; then info "DRY‑RUN: dpkg/apt fix"; return 0; fi
    dpkg --configure -a || true
    apt-get update --fix-missing || true
    apt-get install -f -y     || true
    success "Hoàn tất sửa lỗi APT"
}

update_system() {
    header "🔄 Cập nhật hệ thống"
    if [[ $DRY_RUN == 1 ]]; then info "DRY‑RUN: apt update && upgrade"; return 0; fi
    $UPDATE_CMD
    apt-get upgrade -y
}

# ==== Core packages ==========================================================
CORE_PACKAGES=(
    build-essential git vim curl wget htop rsync zip unzip
    python3 python3-pip python3-venv
    openssh-client ca-certificates gnupg lsb-release software-properties-common
    plocate
)

install_core_packages() {
    if [[ $UPDATE_ONLY == 1 ]]; then return 0; fi
    header "📦 Cài đặt core packages"
    local missing=()
    for pkg in "${CORE_PACKAGES[@]}"; do
        dpkg -s "$pkg" &>/dev/null || missing+=("$pkg")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then success "Tất cả core packages đã có."; return 0; fi
    info "Sẽ cài ${#missing[@]} gói: ${missing[*]}"

    if [[ $DRY_RUN == 1 ]]; then
        printf '  • %s\n' "${missing[@]}"; return 0
    fi

    $INSTALL_CMD "${missing[@]}" || {
        warn "Cài batch thất bại – thử từng gói..."
        local fail=()
        for p in "${missing[@]}"; do $INSTALL_CMD "$p" || fail+=("$p"); done
        [[ ${#fail[@]} -eq 0 ]] || warn "Gói lỗi: ${fail[*]}"
    }
}

# ==== Node.js ================================================================
install_nodejs() {
    if [[ $SKIP_NODEJS == 1 ]]; then return 0; fi
    header "📦 Cài đặt Node.js ($NODEJS_VERSION)"
    if command -v node &>/dev/null; then warn "Node.js đã có: $(node -v)"; return 0; fi
    if [[ $DRY_RUN == 1 ]]; then info "DRY‑RUN: cài Node.js $NODEJS_VERSION"; return 0; fi

    curl -fsSL "https://deb.nodesource.com/setup_${NODEJS_VERSION}.x" | bash - || warn "Dùng repo Ubuntu."
    $INSTALL_CMD nodejs
    command -v npm &>/dev/null || $INSTALL_CMD npm

    if command -v node &>/dev/null; then
        success "Node.js $(node -v) / npm $(npm -v) đã cài."
        npm config set prefix /usr/local
    else
        error "Cài Node.js thất bại."
    fi
}

# ==== Optimise & post steps ==================================================
optimise_system() {
    header "⚡ Dọn dẹp & tối ưu"
    if [[ $DRY_RUN == 1 ]]; then info "DRY‑RUN: autoremove/autoclean"; return 0; fi
    apt-get autoremove -y && apt-get autoclean -y
    updatedb &>/dev/null || true
}

post_install() {
    header "🔧 Thiết lập sau cài đặt"
    if [[ $DRY_RUN == 1 ]]; then info "DRY‑RUN: post‑install"; return 0; fi

    if systemctl list-unit-files | grep -q '^ssh.service'; then
        systemctl enable --now ssh
        info "SSH service đã enable."
    fi

    if command -v ufw &>/dev/null; then
        ufw --force enable
        ufw allow ssh
        info "UFW bật với rule SSH."
    fi
}

# ==== Backup & report ========================================================
create_backup() {
    if [[ $CREATE_BACKUP != 1 ]]; then return 0; fi
    header "📦 Backup file cấu hình"
    mkdir -p "$BACKUP_DIR"
    local files=(/etc/apt/sources.list /etc/environment /etc/profile
                 "$HOME/.bashrc" "$HOME/.profile")
    for f in "${files[@]}"; do [[ -f "$f" ]] && cp -a "$f" "$BACKUP_DIR/"; done
    success "Đã backup vào $BACKUP_DIR"
}

generate_report() {
    local report="/tmp/setup_report_$(date +%Y%m%d_%H%M%S).txt"
    {
        echo "=== Ubuntu Setup Report ($SCRIPT_VERSION) ==="
        echo "Date: $(date)"
        echo "OS: $OS_NAME $OS_VERSION ($KERNEL_VERSION)  Arch: $ARCHITECTURE"
        command -v git   &>/dev/null && git --version
        command -v python3 &>/dev/null && python3 --version
        command -v node  &>/dev/null && node --version
        command -v npm   &>/dev/null && npm --version
        echo "Log: $LOG_FILE"
        [[ $CREATE_BACKUP == 1 ]] && echo "Backup: $BACKUP_DIR"
    } | tee "$report"
    info "📄 Report lưu tại $report"
}

# ==== Main ===================================================================
main() {
    acquire_lock
    parse_args "$@"

    cat <<EOF
${BOLD}${CYAN}
╔══════════════════════════════════════════════════════════╗
║                Ubuntu Setup Script v$SCRIPT_VERSION               ║
║       (Professional Development Environment Installer)   ║
╚══════════════════════════════════════════════════════════╝
${RESET}
EOF

    info "🚀 Bắt đầu quá trình setup…  (log: $LOG_FILE)"
    check_root; get_system_info; check_ubuntu
    ensure_pkg_tools; enable_universe; check_network
    fix_apt; update_system; create_backup
    install_core_packages; install_nodejs
    optimise_system; post_install; generate_report
    header "🎉 HOÀN TẤT!"; success "Môi trường phát triển Ubuntu đã sẵn sàng."
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
