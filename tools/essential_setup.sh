#!/usr/bin/env bash
# ==============================================================================
# Ubuntu Development Environment Setup Script
# Optimized version with enhanced features and error handling
# ==============================================================================

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8

# ==== Script Configuration ====
readonly SCRIPT_VERSION="2.0.2"  # Updated version
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
${BOLD}$SCRIPT_NAME v$SCRIPT_VERSION${RESET}
Ubuntu Development Environment Setup Script

${BOLD}USAGE:${RESET}
    $SCRIPT_NAME [OPTIONS]

${BOLD}OPTIONS:${RESET}
    -h, --help          Hiển thị help này
    -v, --verbose       Bật chế độ debug verbose
    -n, --dry-run       Chỉ hiển thị những gì sẽ được cài đặt
    -s, --skip-nodejs   Bỏ qua cài đặt Node.js
    -u, --update-only   Chỉ update hệ thống, không cài package mới
    --nodejs-version    Chỉ định version Node.js (mặc định: lts)
    --backup            Tạo backup trước khi thay đổi

${BOLD}EXAMPLES:${RESET}
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
    
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        readonly OS_ID="$ID"
        readonly OS_NAME="$NAME"
        readonly OS_VERSION="$VERSION_ID"
    else
        die "Không thể xác định hệ điều hành!"
    fi

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
    readonly UPDATE_CMD="apt update -qq"
    readonly INSTALL_CMD="apt install -y --no-install-recommends"
    readonly SEARCH_CMD="apt list --installed"
    
    success "✅ Package manager: apt"
}

# ==== Enable Additional Repositories ====
enable_repositories() {
    header "🛠️ Kích hoạt các kho lưu trữ cần thiết"
    
    if [[ $DRY_RUN -eq 1 ]]; then
        info "DRY RUN: Sẽ kích hoạt universe và multiverse repositories"
        return 0
    fi
    
    info "Kích hoạt universe repository..."
    add-apt-repository universe -y >/dev/null 2>&1 || warn "⚠️ Universe repository đã được kích hoạt"
    
    info "Kích hoạt multiverse repository..."
    add-apt-repository multiverse -y >/dev/null 2>&1 || warn "⚠️ Multiverse repository đã được kích hoạt"
    
    eval "$UPDATE_CMD" || die "❌ Không thể update package list sau khi kích hoạt repositories"
    
    success "✅ Các kho lưu trữ đã được kích hoạt"
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

# ==== Enhanced Package Lists ====
readonly CORE_PACKAGES=(
    # Build essentials
    "build-essential" "gcc" "g++" "make" "cmake" "autoconf" "automake" "libtool"
    
    # Development tools
    "git" "vim" "nano" "tree" "jq" "xmlstarlet"
    
    # Network tools
    "curl" "wget" "net-tools" "dnsutils" "traceroute" "nmap" "tcpdump" "netstat-nat"
    
    # System monitoring
    "htop" "iotop" "lsof" "strace" "sysstat" "ncdu"
    
    # Archive tools
    "zip" "unzip" "p7zip-full" "rar" "unrar"
    
    # Terminal multiplexers
    "tmux" "screen"
    
    # File sync and transfer
    "rsync"
    
    # Security and certificates
    "openssl" "ca-certificates" "gnupg" "software-properties-common"
    
    # Python ecosystem
    "python3" "python3-pip" "python3-venv" "python3-dev"
    
    # SSH and remote access
    "openssh-server" "openssh-client"
)

readonly OPTIONAL_PACKAGES=(
    # Additional development
    "docker.io" "docker-compose"
    
    # Database clients
    "mysql-client" "postgresql-client" "sqlite3"
    
    # Media tools
    "ffmpeg" "imagemagick"
    
    # Additional utilities
    "ranger" "fzf" "ripgrep" "fd-find"
)

# ==== Check Package Installation Status ====
is_package_installed() {
    local package="$1"
    dpkg -l "$package" 2>/dev/null | grep -q "^ii"
}

# ==== Get Packages to Install ====
get_packages_to_install() {
    local -n packages_ref=$1
    local -n result_ref=$2
    
    result_ref=()
    for package in "${packages_ref[@]}"; do
        if ! is_package_installed "$package"; then
            if apt-cache show "$package" >/dev/null 2>&1; then
                result_ref+=("$package")
            else
                warn "⚠️ Package $package không tồn tại trong kho lưu trữ, bỏ qua..."
            fi
        else
            debug "Package already installed: $package"
        fi
    done
}

# ==== Install yq via pip3 ====
install_yq() {
    [[ $DRY_RUN -eq 1 ]] && return 0
    
    header "📦 Cài đặt yq qua pip3"
    
    if command -v yq >/dev/null 2>&1; then
        local current_version=$(yq --version 2>/dev/null || echo "unknown")
        warn "yq đã được cài đặt: $current_version"
        return 0
    fi
    
    if [[ $DRY_RUN -eq 1 ]]; then
        info "DRY RUN: Sẽ cài đặt yq qua pip3"
        return 0
    fi
    
    info "Cài đặt yq..."
    pip3 install yq || {
        error "❌ Không thể cài đặt yq qua pip3"
        return 1
    }
    
    success "✅ yq đã được cài đặt"
}

# ==== System Update ====
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
    
    local packages_to_install
    get_packages_to_install CORE_PACKAGES packages_to_install
    
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
    
    local batch_size=10
    local installed_count=0
    local failed_packages=()
    
    for ((i=0; i<${#packages_to_install[@]}; i+=batch_size)); do
        local batch=("${packages_to_install[@]:i:batch_size}")
        info "Installing batch $((i/batch_size + 1)): ${batch[*]}"
        
        if timeout 300 eval "$INSTALL_CMD ${batch[*]}"; then
            installed_count=$((installed_count + ${#batch[@]}))
            success "✅ Batch installed successfully"
        else
            warn "⚠️ Batch installation failed, trying individual packages..."
            for package in "${batch[@]}"; do
                if timeout 300 eval "$INSTALL_CMD $package"; then
                    installed_count=$((installed_count + 1))
                    debug "✅ $package installed"
                else
                    failed_packages+=("$package")
                    error "❌ Failed to install: $package"
                fi
            done
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
            timeout 300 eval "$INSTALL_CMD nodejs npm" || error "❌ Failed to install nodejs npm"
        }
        timeout 300 eval "$INSTALL_CMD nodejs" || error "❌ Failed to install nodejs"
    else
        timeout 300 eval "$INSTALL_CMD nodejs npm" || error "❌ Failed to install nodejs npm"
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
        command -v yq >/dev/null && echo "yq: $(yq --version)"
        command -v node >/dev/null && echo "Node.js: $(node --version)"
        command -v npm >/dev/null && echo "npm: $(npm --version)"
        command -v docker >/dev/null && echo "Docker: $(docker --version)"
        
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
    update_system
    install_packages
    install_yq
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
