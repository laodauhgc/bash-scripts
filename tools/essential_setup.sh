#!/usr/bin/env bash
# ==============================================================================
# Ubuntu Development Environment Setup Script
# Optimized version with essential packages and robust error handling
# Version 2.0.12 (sử dụng dpkg-query để lấy list installed, <<< để feed grep)
# ==============================================================================

set -euo pipefail
trap 'error "Error on line $LINENO: $BASH_COMMAND"' ERR

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8

# ==== Script Configuration ====
readonly SCRIPT_VERSION="2.0.12"
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/tmp/${SCRIPT_NAME%.*}.log"
readonly LOCK_FILE="/tmp/${SCRIPT_NAME%.*}.lock"
readonly BACKUP_DIR="/tmp/setup_backup_$(date +%Y%m%d_%H%M%S)"

# ==== Colors and Formatting ====
if [[ -t 1 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly PURPLE='\033[0;35m'
    readonly CYAN='\033[0;36m'
    readonly WHITE='\033[1;37m'
    readonly RESET='\033[0m'
    readonly BOLD='\033[1m'
else
    readonly RED='' GREEN='' YELLOW='' BLUE='' PURPLE='' CYAN='' WHITE='' RESET='' BOLD=''
fi

# ==== Logging Functions ====
log() { 
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${2:-$GREEN}[$timestamp] $1${RESET}" | tee -a "$LOG_FILE"
}

info()     { log "ℹ️  $1" "$BLUE"; }
success()  { log "✅ $1" "$GREEN"; }
warn()     { log "⚠️  $1" "$YELLOW"; }
error()    { log "❌ $1" "$RED"; }
debug()    { [[ "${DEBUG:-0}" -eq 1 ]] && log "🐛 $1" "$PURPLE"; }
header()   { log "\n${BOLD}$1${RESET}" "$CYAN"; }

die() {
    error "$1"
    cleanup
    exit 1
}

# ==== Cleanup Function ====
cleanup() {
    debug "Cleaning up..."
    [[ -f "$LOCK_FILE" ]] && rm -f "$LOCK_FILE"
    trap - EXIT
}

# ==== Lock File Management ====
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            die "Script đang chạy với PID $pid. Vui lòng đợi hoặc xóa file lock: $LOCK_FILE"
        else
            warn "Tìm thấy lock file cũ, đang xóa..."
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    trap cleanup EXIT
}

# ==== Help Function ====
show_help() {
    cat << EOF
$SCRIPT_NAME v$SCRIPT_VERSION
Ubuntu Development Environment Setup Script

USAGE:
    $SCRIPT_NAME [OPTIONS]

OPTIONS:
    -h, --help          Hiển thị help này
    -v, --verbose       Bật chế độ debug verbose
    -n, --dry-run       Chỉ hiển thị những gì sẽ được cài đặt
    -s, --skip-nodejs   Bỏ qua cài đặt Node.js
    -u, --update-only   Chỉ update hệ thống, không cài package mới
    --nodejs-version    Chỉ định version Node.js (mặc định: lts)
    --backup            Tạo backup trước khi thay đổi

EXAMPLES:
    $SCRIPT_NAME                           # Cài đặt mặc định
    $SCRIPT_NAME --verbose --backup        # Verbose mode với backup
    $SCRIPT_NAME --nodejs-version 18      # Cài Node.js v18
    $SCRIPT_NAME --dry-run                 # Xem trước những gì sẽ cài

EOF
}

# ==== Parse Arguments ====
DRY_RUN=0
SKIP_NODEJS=0
UPDATE_ONLY=0
CREATE_BACKUP=0
NODEJS_VERSION="lts"

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--verbose)
                DEBUG=1
                set -x
                shift
                ;;
            -n|--dry-run)
                DRY_RUN=1
                info "🔍 Chế độ dry-run được bật"
                shift
                ;;
            -s|--skip-nodejs)
                SKIP_NODEJS=1
                shift
                ;;
            -u|--update-only)
                UPDATE_ONLY=1
                shift
                ;;
            --nodejs-version)
                if [[ $# -lt 2 ]]; then
                    error "Option --nodejs-version requires a value"
                    exit 1
                fi
                NODEJS_VERSION="$2"
                shift 2
                ;;
            --backup)
                CREATE_BACKUP=1
                shift
                ;;
            *)
                error "Tùy chọn không hợp lệ: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# ==== System Information ====
get_system_info() {
    info "🔍 Đang thu thập thông tin hệ thống..."
    
    OS_ID="unknown"
    OS_NAME="unknown"
    OS_VERSION="unknown"
    
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_NAME="${NAME:-unknown}"
        OS_VERSION="${VERSION_ID:-unknown}"
    fi
    
    if [[ "$OS_VERSION" == "unknown" && -f /etc/lsb-release ]]; then
        . /etc/lsb-release
        OS_VERSION="${DISTRIB_RELEASE:-unknown}"
    fi
    
    if [[ "$OS_VERSION" == "unknown" ]]; then
        warn "⚠️ Không thể xác định phiên bản OS. Giả định Ubuntu 22.04."
        OS_VERSION="22.04"
    fi
    
    readonly OS_ID
    readonly OS_NAME
    readonly OS_VERSION

    readonly KERNEL_VERSION="$(uname -r)"
    readonly ARCHITECTURE="$(uname -m)"
    readonly TOTAL_RAM="$(free -h | awk '/^Mem:/ {print $2}')"
    readonly AVAILABLE_SPACE="$(df -h / | awk 'NR==2 {print $4}')"

    info "OS: $OS_NAME ($OS_VERSION)"
    info "Kernel: $KERNEL_VERSION"
    info "Architecture: $ARCHITECTURE"
    info "RAM: $TOTAL_RAM"
    info "Available space: $AVAILABLE_SPACE"
}

# ==== Root Check ====
check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "❌ Script cần quyền root. Vui lòng chạy: sudo $0"
    fi
    success "✅ Đang chạy với quyền root"
}

# ==== Check Ubuntu Version ====
check_ubuntu_version() {
    if [[ "$OS_ID" != "ubuntu" ]]; then
        die "Script này chỉ hỗ trợ Ubuntu. OS hiện tại: $OS_NAME"
    fi
    
    local version_number=$(echo "$OS_VERSION" | cut -d. -f1)
    if [[ $version_number -lt 18 ]]; then
        die "Script yêu cầu Ubuntu 18.04 trở lên. Version hiện tại: $OS_VERSION"
    fi
    
    success "✅ Ubuntu version hợp lệ: $OS_VERSION"
}

# ==== Package Manager Setup ====
setup_package_manager() {
    if ! command -v apt >/dev/null 2>&1; then
        die "Không tìm thấy apt package manager!"
    fi
    
    readonly PKG_MANAGER="apt"
    readonly UPDATE_CMD="apt update"
    readonly INSTALL_CMD="apt install -y --no-install-recommends"
    
    success "✅ Package manager: apt"
}

# ==== Enable Universe Repository ====
enable_repositories() {
    header "🛠️ Kích hoạt kho universe"
    
    if [[ $DRY_RUN -eq 1 ]]; then
        info "DRY RUN: Sẽ kích hoạt universe repository"
        return 0
    fi
    
    info "Kích hoạt universe repository..."
    add-apt-repository universe -y || warn "⚠️ Universe repository đã được kích hoạt"
    
    eval "$UPDATE_CMD" || die "❌ Không thể update package list sau khi kích hoạt repository"
    
    success "✅ Kho universe đã được kích hoạt"
}

# ==== Network Connectivity Check ====
check_network() {
    info "🌐 Kiểm tra kết nối mạng..."
    
    local test_urls=(
        "8.8.8.8"
        "google.com"
        "archive.ubuntu.com"
    )
    
    for url in "${test_urls[@]}"; do
        if ping -c 1 -W 5 "$url" >/dev/null 2>&1; then
            success "✅ Kết nối mạng OK"
            return 0
        fi
    done
    
    die "❌ Không có kết nối mạng!"
}

# ==== Backup Function ====
create_backup() {
    [[ $CREATE_BACKUP -eq 0 ]] && return 0
    
    info "📦 Tạo backup trong $BACKUP_DIR..."
    mkdir -p "$BACKUP_DIR"
    
    local backup_files=(
        "/etc/apt/sources.list"
        "/etc/environment"
        "/etc/profile"
        "${HOME}/.bashrc"
        "${HOME}/.profile"
    )
    
    for file in "${backup_files[@]}"; do
        if [[ -f "$file" ]]; then
            cp "$file" "$BACKUP_DIR/" 2>/dev/null || true
            debug "Backed up: $file"
        fi
    done
    
    success "✅ Backup completed: $BACKUP_DIR"
}

# ==== Essential Package List ====
readonly CORE_PACKAGES=(
    "build-essential"
    "git"
    "vim"
    "curl"
    "wget"
    "htop"
    "zip"
    "unzip"
    "rsync"
    "python3"
    "python3-pip"
    "python3-venv"
    "openssh-client"
)

# ==== Fix APT Issues ====
fix_apt() {
    header "🛠️ Sửa lỗi APT nếu có"
    
    if [[ $DRY_RUN -eq 1 ]]; then
        info "DRY RUN: Sẽ sửa lỗi APT"
        return 0
    fi
    
    info "Chạy dpkg --configure -a để fix interrupted nếu có..."
    dpkg --configure -a || warn "⚠️ Không thể configure dpkg, có thể hang hoặc không cần"

    info "Chạy apt update --fix-missing..."
    apt-get update --fix-missing || warn "⚠️ Không thể sửa lỗi missing packages"
    
    info "Chạy apt install -f..."
    apt-get install -f -y || warn "⚠️ Không thể sửa lỗi dependencies"
    
    success "✅ Hoàn tất sửa lỗi APT"
}

# ==== Update System ====
update_system() {
    header "🔄 Cập nhật hệ thống"
    
    if [[ $DRY_RUN -eq 1 ]]; then
        info "DRY RUN: Sẽ chạy apt update && apt upgrade"
        return 0
    fi
    
    info "Updating package lists..."
    eval "$UPDATE_CMD" || die "❌ Không thể update package list"
    
    info "Upgrading installed packages..."
    apt upgrade -y || warn "⚠️ Một số packages không thể upgrade"
    
    success "✅ System update completed"
}

# ==== Install Packages ====
install_packages() {
    [[ $UPDATE_ONLY -eq 1 ]] && return 0
    
    header "📦 Cài đặt packages cần thiết"
    
    info "Thu thập danh sách packages đã cài đặt..."
    local installed_packages=$(dpkg-query -l 2>/dev/null | awk '/^ii/ {print $2}')
    
    local packages_to_install=()
    
    for package in "${CORE_PACKAGES[@]}"; do
        info "Kiểm tra package: $package"
        if grep -q "^$package$" <<< "$installed_packages"; then
            debug "Package already installed: $package"
        else
            packages_to_install+=("$package")
        fi
    done
    
    if [[ ${#packages_to_install[@]} -eq 0 ]]; then
        success "✅ Tất cả core packages đã được cài đặt"
        return 0
    fi
    
    info "Packages cần cài đặt: ${#packages_to_install[@]} packages"
    info "Danh sách: ${packages_to_install[*]}"
    debug "Package list: ${packages_to_install[*]}"
    
    if [[ $DRY_RUN -eq 1 ]]; then
        info "DRY RUN: Sẽ cài đặt các packages sau:"
        printf '  - %s\n' "${packages_to_install[@]}"
        return 0
    fi
    
    local installed_count=0
    local failed_packages=()
    
    for package in "${packages_to_install[@]}"; do
        info "Cài đặt package: $package"
        if eval "$INSTALL_CMD $package"; then
            installed_count=$((installed_count + 1))
            success "✅ $package installed"
        else
            failed_packages+=("$package")
            error "❌ Failed to install: $package"
        fi
    done
    
    success "✅ Installed $installed_count/${#packages_to_install[@]} packages"
    
    if [[ ${#failed_packages[@]} -gt 0 ]]; then
        warn "⚠️ Failed packages: ${failed_packages[*]}"
        warn "Vui lòng kiểm tra và cài đặt thủ công các package trên nếu cần."
    fi
}

# ==== Node.js Installation ====
install_nodejs() {
    [[ $SKIP_NODEJS -eq 1 ]] && return 0
    
    header "📦 Cài đặt Node.js và npm"
    
    if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
        local current_version=$(node --version 2>/dev/null || echo "unknown")
        warn "Node.js đã được cài đặt: $current_version"
        return 0
    fi
    
    if [[ $DRY_RUN -eq 1 ]]; then
        info "DRY RUN: Sẽ cài đặt Node.js version $NODEJS_VERSION"
        return 0
    fi
    
    info "Cài đặt Node.js $NODEJS_VERSION..."
    
    if [[ "$NODEJS_VERSION" != "system" ]]; then
        info "Adding NodeSource repository..."
        curl -fsSL https://deb.nodesource.com/setup_${NODEJS_VERSION}.x | bash - || {
            warn "⚠️ Không thể thêm NodeSource repo, cài đặt từ Ubuntu repo..."
            eval "$INSTALL_CMD nodejs npm" || error "❌ Failed to install nodejs npm"
        }
        eval "$INSTALL_CMD nodejs" || error "❌ Failed to install nodejs"
    else
        eval "$INSTALL_CMD nodejs npm" || error "❌ Failed to install nodejs npm"
    fi
    
    if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
        local node_version=$(node --version)
        local npm_version=$(npm --version)
        success "✅ Node.js $node_version và npm $npm_version đã được cài đặt"
        
        info "Configuring npm global directory..."
        mkdir -p /usr/local/lib/node_modules
        npm config set prefix /usr/local
    else
        error "❌ Node.js installation failed"
    fi
}

# ==== System Optimization ====
optimize_system() {
    header "⚡ Tối ưu hóa hệ thống"
    
    if [[ $DRY_RUN -eq 1 ]]; then
        info "DRY RUN: Sẽ thực hiện tối ưu hóa hệ thống"
        return 0
    fi
    
    info "Cleaning package cache..."
    apt autoremove -y >/dev/null 2>&1 || true
    apt autoclean >/dev/null 2>&1 || true
    
    if command -v updatedb >/dev/null 2>&1; then
        info "Updating locate database..."
        updatedb &
    fi
    
    success "✅ System optimization completed"
}

# ==== Generate Summary Report ====
generate_report() {
    header "📋 Báo cáo cài đặt"
    
    local report_file="/tmp/setup_report_$(date +%Y%m%d_%H%M%S).txt"
    
    {
        echo "Ubuntu Setup Script - Installation Report"
        echo "========================================"
        echo "Date: $(date)"
        echo "Script Version: $SCRIPT_VERSION"
        echo "System: $OS_NAME $OS_VERSION"
        echo "Kernel: $KERNEL_VERSION"
        echo "Architecture: $ARCHITECTURE"
        echo ""
        
        echo "Installed Software Versions:"
        echo "----------------------------"
        command -v git >/dev/null && echo "Git: $(git --version)"
        command -v python3 >/dev/null && echo "Python: $(python3 --version)"
        command -v node >/dev/null && echo "Node.js: $(node --version)"
        command -v npm >/dev/null && echo "npm: $(npm --version)"
        
        echo ""
        echo "Log file: $LOG_FILE"
        [[ $CREATE_BACKUP -eq 1 ]] && echo "Backup: $BACKUP_DIR"
        
    } | tee "$report_file"
    
    info "📄 Report saved: $report_file"
}

# ==== Post-installation Setup ====
post_installation_setup() {
    header "🔧 Thiết lập sau cài đặt"
    
    if [[ $DRY_RUN -eq 1 ]]; then
        info "DRY RUN: Sẽ thực hiện post-installation setup"
        return 0
    fi
    
    if systemctl is-available ssh >/dev/null 2>&1; then
        systemctl enable ssh >/dev/null 2>&1 || true
        info "✅ SSH service enabled"
    fi
    
    if command -v ufw >/dev/null 2>&1; then
        info "Setting up basic firewall rules..."
        ufw --force enable >/dev/null 2>&1 || true
        ufw allow ssh >/dev/null 2>&1 || true
    fi
    
    success "✅ Post-installation setup completed"
}

# ==== Main Function ====
main() {
    acquire_lock
    parse_args "$@"
    
    cat << EOF
${BOLD}${CYAN}
╔══════════════════════════════════════════════════════════╗
║                Ubuntu Setup Script v$SCRIPT_VERSION                ║
║            Professional Development Environment          ║
╚══════════════════════════════════════════════════════════╝
${RESET}
EOF
    
    info "🚀 Starting Ubuntu setup process..."
    info "📝 Log file: $LOG_FILE"
    
    check_root
    get_system_info
    check_ubuntu_version
    setup_package_manager
    enable_repositories
    check_network
    create_backup
    fix_apt
    update_system
    install_packages
    install_nodejs
    optimize_system
    post_installation_setup
    generate_report
    
    header "🎉 HOÀN THÀNH!"
    success "✅ Ubuntu development environment đã được setup thành công!"
    info "📝 Vui lòng chạy 'source ~/.bashrc' hoặc mở terminal mới"
    info "📄 Xem report chi tiết tại: /tmp/setup_report_*.txt"
    
    [[ $CREATE_BACKUP -eq 1 ]] && info "💾 Backup files: $BACKUP_DIR"
}

# ==== Script Entry Point ====
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
    main "$@"
fi
