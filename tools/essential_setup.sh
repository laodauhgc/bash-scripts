#!/usr/bin/env bash

# Blockcast BEACON Setup Script - Optimized Version
# Author: Optimized for security, portability, and reliability
# Version: 2.0
# Supported OS: Ubuntu 18.04+, Debian 10+, CentOS 7+, RHEL 7+

set -euo pipefail  # Exit on error, undefined vars, pipe failures
IFS=$'\n\t'        # Secure Internal Field Separator

# ============================================================================
# CONFIGURATION AND CONSTANTS
# ============================================================================

readonly SCRIPT_NAME="$(basename "${0}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="${SCRIPT_DIR}/blockcast_setup.log"
readonly BACKUP_DIR="${HOME}/.blockcast_backup_$(date +%Y%m%d_%H%M%S)"
readonly BEACON_REPO_URL="https://github.com/Blockcast/beacon-docker-compose.git"
readonly BEACON_DIR_NAME="beacon-docker-compose"
readonly DOCKER_INSTALL_URL="https://get.docker.com"
readonly MIN_DOCKER_VERSION="20.10.0"
readonly MIN_COMPOSE_VERSION="1.25.0"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

log() {
    local level="${1}"
    local message="${2}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "${level}" in
        "INFO")  echo -e "${GREEN}[INFO]${NC} ${message}" | tee -a "${LOG_FILE}" ;;
        "WARN")  echo -e "${YELLOW}[WARN]${NC} ${message}" | tee -a "${LOG_FILE}" ;;
        "ERROR") echo -e "${RED}[ERROR]${NC} ${message}" | tee -a "${LOG_FILE}" ;;
        "DEBUG") [[ "${DEBUG:-0}" == "1" ]] && echo -e "${PURPLE}[DEBUG]${NC} ${message}" | tee -a "${LOG_FILE}" ;;
    esac
    
    echo "[${timestamp}] [${level}] ${message}" >> "${LOG_FILE}"
}

print_banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║                    Blockcast BEACON Setup Script v2.0               ║"
    echo "║                           Optimized Version                          ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Options:
    -u, --uninstall     Uninstall Blockcast BEACON
    -b, --backup        Create backup of existing installation
    -r, --restore FILE  Restore from backup file
    -c, --check         Check system requirements only
    -v, --verbose       Enable verbose logging
    -h, --help          Show this help message
    --dry-run           Show what would be done without executing

Examples:
    sudo ./${SCRIPT_NAME}                    # Install Blockcast BEACON
    sudo ./${SCRIPT_NAME} --uninstall        # Uninstall
    sudo ./${SCRIPT_NAME} --backup           # Create backup
    sudo ./${SCRIPT_NAME} --check            # Check requirements

EOF
}

cleanup() {
    local exit_code=$?
    if [[ ${exit_code} -ne 0 ]]; then
        log "ERROR" "Script failed with exit code ${exit_code}"
        log "INFO" "Check log file: ${LOG_FILE}"
    fi
    exit ${exit_code}
}

verify_checksum() {
    local file="${1}"
    local expected_sum="${2}"
    
    if command -v sha256sum >/dev/null 2>&1; then
        local actual_sum=$(sha256sum "${file}" | cut -d' ' -f1)
    elif command -v shasum >/dev/null 2>&1; then
        local actual_sum=$(shasum -a 256 "${file}" | cut -d' ' -f1)
    else
        log "WARN" "No checksum utility found. Skipping verification."
        return 0
    fi
    
    if [[ "${actual_sum}" != "${expected_sum}" ]]; then
        log "ERROR" "Checksum verification failed for ${file}"
        return 1
    fi
    
    log "INFO" "Checksum verified for ${file}"
}

version_compare() {
    # Compare version strings (returns 0 if v1 >= v2)
    local v1="${1}"
    local v2="${2}"
    
    printf '%s\n%s\n' "${v1}" "${v2}" | sort -V -C
}

# ============================================================================
# SYSTEM DETECTION AND REQUIREMENTS
# ============================================================================

detect_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS="${ID}"
        OS_VERSION="${VERSION_ID}"
        OS_CODENAME="${VERSION_CODENAME:-}"
    elif [[ -f /etc/redhat-release ]]; then
        OS="centos"
        OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | head -1)
    else
        log "ERROR" "Unsupported operating system"
        exit 1
    fi
    
    log "INFO" "Detected OS: ${OS} ${OS_VERSION}"
}

check_requirements() {
    log "INFO" "Checking system requirements..."
    
    # Check if running as root
    if [[ "${EUID}" -ne 0 ]]; then
        log "ERROR" "This script must be run as root. Use: sudo ${SCRIPT_NAME}"
        exit 1
    fi
    
    # Check architecture
    local arch=$(uname -m)
    if [[ ! "${arch}" =~ ^(x86_64|amd64|arm64|aarch64)$ ]]; then
        log "ERROR" "Unsupported architecture: ${arch}"
        exit 1
    fi
    
    # Check available disk space (minimum 10GB)
    local available_space=$(df / | awk 'NR==2 {print $4}')
    local min_space=$((10 * 1024 * 1024)) # 10GB in KB
    
    if [[ ${available_space} -lt ${min_space} ]]; then
        log "ERROR" "Insufficient disk space. Need at least 10GB free."
        exit 1
    fi
    
    # Check memory (minimum 2GB)
    local available_memory=$(free -k | awk '/^Mem:/ {print $2}')
    local min_memory=$((2 * 1024 * 1024)) # 2GB in KB
    
    if [[ ${available_memory} -lt ${min_memory} ]]; then
        log "WARN" "Low memory detected. Recommend at least 2GB RAM."
    fi
    
    log "INFO" "System requirements check passed"
}

# ============================================================================
# PACKAGE MANAGEMENT
# ============================================================================

update_package_manager() {
    log "INFO" "Updating package manager..."
    
    case "${OS}" in
        ubuntu|debian)
            apt-get update -qq || {
                log "ERROR" "Failed to update package manager"
                exit 1
            }
            ;;
        centos|rhel|fedora)
            if command -v dnf >/dev/null 2>&1; then
                dnf makecache -q || {
                    log "ERROR" "Failed to update package manager"
                    exit 1
                }
            else
                yum makecache -q || {
                    log "ERROR" "Failed to update package manager"
                    exit 1
                }
            fi
            ;;
    esac
}

install_package() {
    local package="${1}"
    log "INFO" "Installing ${package}..."
    
    case "${OS}" in
        ubuntu|debian)
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${package}" || {
                log "ERROR" "Failed to install ${package}"
                return 1
            }
            ;;
        centos|rhel|fedora)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y -q "${package}" || {
                    log "ERROR" "Failed to install ${package}"
                    return 1
                }
            else
                yum install -y -q "${package}" || {
                    log "ERROR" "Failed to install ${package}"
                    return 1
                }
            fi
            ;;
    esac
    
    log "INFO" "${package} installed successfully"
}

# ============================================================================
# DOCKER INSTALLATION AND MANAGEMENT
# ============================================================================

install_docker() {
    if command -v docker >/dev/null 2>&1; then
        local docker_version=$(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        if version_compare "${docker_version}" "${MIN_DOCKER_VERSION}"; then
            log "INFO" "Docker ${docker_version} is already installed and meets requirements"
            return 0
        else
            log "WARN" "Docker version ${docker_version} is below minimum ${MIN_DOCKER_VERSION}"
        fi
    fi
    
    log "INFO" "Installing Docker..."
    
    # Install prerequisites
    case "${OS}" in
        ubuntu|debian)
            install_package "ca-certificates"
            install_package "curl"
            install_package "gnupg"
            install_package "lsb-release"
            ;;
        centos|rhel|fedora)
            install_package "ca-certificates"
            install_package "curl"
            install_package "gnupg2"
            ;;
    esac
    
    # Download and verify Docker install script
    local docker_script="/tmp/docker_install.sh"
    log "INFO" "Downloading Docker installation script..."
    
    if ! curl -fsSL "${DOCKER_INSTALL_URL}" -o "${docker_script}"; then
        log "ERROR" "Failed to download Docker installation script"
        exit 1
    fi
    
    # Make script executable and run
    chmod +x "${docker_script}"
    if ! bash "${docker_script}"; then
        log "ERROR" "Docker installation failed"
        exit 1
    fi
    
    # Clean up
    rm -f "${docker_script}"
    
    # Start and enable Docker service
    systemctl start docker || {
        log "ERROR" "Failed to start Docker service"
        exit 1
    }
    
    systemctl enable docker || {
        log "ERROR" "Failed to enable Docker service"
        exit 1
    }
    
    # Add user to docker group
    if [[ -n "${SUDO_USER:-}" ]]; then
        usermod -aG docker "${SUDO_USER}"
        log "INFO" "Added ${SUDO_USER} to docker group"
    fi
    
    log "INFO" "Docker installed and configured successfully"
}

install_docker_compose() {
    if command -v docker-compose >/dev/null 2>&1; then
        local compose_version=$(docker-compose --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        if version_compare "${compose_version}" "${MIN_COMPOSE_VERSION}"; then
            log "INFO" "Docker Compose ${compose_version} is already installed and meets requirements"
            return 0
        fi
    fi
    
    log "INFO" "Installing Docker Compose..."
    
    case "${OS}" in
        ubuntu|debian)
            install_package "docker-compose"
            ;;
        centos|rhel|fedora)
            # Install via pip for better version control
            if ! command -v pip3 >/dev/null 2>&1; then
                install_package "python3-pip"
            fi
            pip3 install --upgrade docker-compose
            ;;
    esac
    
    log "INFO" "Docker Compose installed successfully"
}

# ============================================================================
# BACKUP AND RESTORE FUNCTIONS
# ============================================================================

create_backup() {
    log "INFO" "Creating backup..."
    
    if [[ ! -d "${BEACON_DIR_NAME}" ]]; then
        log "WARN" "No existing installation found to backup"
        return 0
    fi
    
    mkdir -p "${BACKUP_DIR}"
    
    # Backup configuration files
    if [[ -d "${HOME}/.blockcast" ]]; then
        cp -r "${HOME}/.blockcast" "${BACKUP_DIR}/" || {
            log "ERROR" "Failed to backup .blockcast directory"
            return 1
        }
    fi
    
    # Backup docker-compose files
    cp -r "${BEACON_DIR_NAME}" "${BACKUP_DIR}/" || {
        log "ERROR" "Failed to backup beacon directory"
        return 1
    }
    
    # Create backup info file
    cat > "${BACKUP_DIR}/backup_info.txt" << EOF
Backup created: $(date)
Script version: 2.0
OS: ${OS} ${OS_VERSION}
Docker version: $(docker --version 2>/dev/null || echo "Not installed")
Docker Compose version: $(docker-compose --version 2>/dev/null || echo "Not installed")
EOF
    
    # Create compressed backup
    local backup_file="${SCRIPT_DIR}/blockcast_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    tar -czf "${backup_file}" -C "$(dirname "${BACKUP_DIR}")" "$(basename "${BACKUP_DIR}")" || {
        log "ERROR" "Failed to create backup archive"
        return 1
    }
    
    # Clean up temporary backup directory
    rm -rf "${BACKUP_DIR}"
    
    log "INFO" "Backup created: ${backup_file}"
    echo -e "${GREEN}Backup file: ${backup_file}${NC}"
}

restore_backup() {
    local backup_file="${1}"
    
    if [[ ! -f "${backup_file}" ]]; then
        log "ERROR" "Backup file not found: ${backup_file}"
        exit 1
    fi
    
    log "INFO" "Restoring from backup: ${backup_file}"
    
    # Extract backup
    local temp_restore_dir="/tmp/blockcast_restore_$$"
    mkdir -p "${temp_restore_dir}"
    
    tar -xzf "${backup_file}" -C "${temp_restore_dir}" || {
        log "ERROR" "Failed to extract backup file"
        exit 1
    }
    
    # Find the backup directory (should be the only directory in temp_restore_dir)
    local backup_content_dir=$(find "${temp_restore_dir}" -maxdepth 1 -type d -name "*.blockcast_backup_*" | head -1)
    
    if [[ -z "${backup_content_dir}" ]]; then
        log "ERROR" "Invalid backup file structure"
        exit 1
    fi
    
    # Restore files
    if [[ -d "${backup_content_dir}/.blockcast" ]]; then
        cp -r "${backup_content_dir}/.blockcast" "${HOME}/" || {
            log "ERROR" "Failed to restore .blockcast directory"
            exit 1
        }
    fi
    
    if [[ -d "${backup_content_dir}/${BEACON_DIR_NAME}" ]]; then
        rm -rf "${BEACON_DIR_NAME}"
        cp -r "${backup_content_dir}/${BEACON_DIR_NAME}" ./ || {
            log "ERROR" "Failed to restore beacon directory"
            exit 1
        }
    fi
    
    # Clean up
    rm -rf "${temp_restore_dir}"
    
    log "INFO" "Backup restored successfully"
}

# ============================================================================
# BLOCKCAST BEACON FUNCTIONS
# ============================================================================

uninstall_blockcast() {
    log "INFO" "Starting Blockcast BEACON uninstallation..."
    
    # Stop and remove containers
    if [[ -d "${BEACON_DIR_NAME}" ]]; then
        cd "${BEACON_DIR_NAME}" || {
            log "ERROR" "Failed to enter beacon directory"
            exit 1
        }
        
        if [[ -f "docker-compose.yml" ]]; then
            log "INFO" "Stopping Blockcast BEACON containers..."
            docker-compose down --remove-orphans --volumes || {
                log "WARN" "Failed to gracefully stop containers"
            }
            
            # Force remove if necessary
            docker-compose rm -f || {
                log "WARN" "Failed to remove containers"
            }
        fi
        
        cd ..
        rm -rf "${BEACON_DIR_NAME}"
        log "INFO" "Removed beacon directory"
    else
        log "WARN" "Beacon directory not found"
    fi
    
    # Clean up Docker images (optional)
    read -p "Remove Blockcast Docker images? [y/N]: " -n 1 -r
    echo
    if [[ ${REPLY} =~ ^[Yy]$ ]]; then
        docker images | grep -E "(blockcast|beacon)" | awk '{print $3}' | xargs -r docker rmi -f
        log "INFO" "Removed Blockcast Docker images"
    fi
    
    log "INFO" "Blockcast BEACON uninstalled successfully"
}

install_dependencies() {
    log "INFO" "Installing dependencies..."
    
    # Install git
    if ! command -v git >/dev/null 2>&1; then
        install_package "git"
    fi
    
    # Install curl if not present
    if ! command -v curl >/dev/null 2>&1; then
        install_package "curl"
    fi
    
    # Install Docker
    install_docker
    
    # Install Docker Compose
    install_docker_compose
    
    log "INFO" "All dependencies installed successfully"
}

clone_repository() {
    log "INFO" "Cloning Blockcast BEACON repository..."
    
    if [[ -d "${BEACON_DIR_NAME}" ]]; then
        log "INFO" "Repository already exists. Creating backup and re-cloning..."
        local backup_name="${BEACON_DIR_NAME}.backup.$(date +%s)"
        mv "${BEACON_DIR_NAME}" "${backup_name}"
        log "INFO" "Existing repository backed up as ${backup_name}"
    fi
    
    if ! git clone "${BEACON_REPO_URL}" "${BEACON_DIR_NAME}"; then
        log "ERROR" "Failed to clone repository"
        exit 1
    fi
    
    # Verify repository structure
    if [[ ! -f "${BEACON_DIR_NAME}/docker-compose.yml" ]]; then
        log "ERROR" "Invalid repository structure - docker-compose.yml not found"
        exit 1
    fi
    
    log "INFO" "Repository cloned successfully"
}

start_blockcast() {
    log "INFO" "Starting Blockcast BEACON..."
    
    cd "${BEACON_DIR_NAME}" || {
        log "ERROR" "Failed to enter beacon directory"
        exit 1
    }
    
    # Pull latest images
    docker-compose pull || {
        log "ERROR" "Failed to pull Docker images"
        exit 1
    }
    
    # Start services
    docker-compose up -d || {
        log "ERROR" "Failed to start Blockcast BEACON"
        exit 1
    }
    
    # Wait for services to be ready with better health checking
    log "INFO" "Waiting for services to initialize..."
    local max_wait=120
    local wait_time=0
    
    while [[ ${wait_time} -lt ${max_wait} ]]; do
        if docker-compose ps | grep -q "Up"; then
            break
        fi
        sleep 5
        wait_time=$((wait_time + 5))
        log "DEBUG" "Waiting for services... (${wait_time}/${max_wait}s)"
    done
    
    if [[ ${wait_time} -ge ${max_wait} ]]; then
        log "ERROR" "Services failed to start within ${max_wait} seconds"
        docker-compose logs
        exit 1
    fi
    
    log "INFO" "Services started successfully"
}

generate_keys() {
    log "INFO" "Generating hardware and challenge keys..."
    
    local max_retries=3
    local retry=0
    local init_output=""
    
    while [[ ${retry} -lt ${max_retries} ]]; do
        init_output=$(docker-compose exec -T blockcastd blockcastd init 2>&1) || {
            retry=$((retry + 1))
            log "WARN" "Key generation attempt ${retry} failed. Retrying..."
            sleep 10
            continue
        }
        break
    done
    
    if [[ ${retry} -eq ${max_retries} ]]; then
        log "ERROR" "Failed to generate keys after ${max_retries} attempts"
        log "ERROR" "Last output: ${init_output}"
        exit 1
    fi
    
    if [[ -z "${init_output}" ]]; then
        log "ERROR" "No output from init command"
        exit 1
    fi
    
    # Extract information with better parsing
    local hwid=$(echo "${init_output}" | grep -i "Hardware ID" | sed 's/.*Hardware ID[[:space:]]*:[[:space:]]*//' | tr -d '[:space:]')
    local challenge_key=$(echo "${init_output}" | grep -i "Challenge Key" | sed 's/.*Challenge Key[[:space:]]*:[[:space:]]*//' | tr -d '[:space:]')
    local reg_url=$(echo "${init_output}" | grep -i "Registration URL" | sed 's/.*Registration URL[[:space:]]*:[[:space:]]*//')
    
    if [[ -z "${hwid}" ]] || [[ -z "${challenge_key}" ]]; then
        log "ERROR" "Failed to extract keys from init output"
        log "DEBUG" "Init output: ${init_output}"
        exit 1
    fi
    
    # Display results
    echo -e "\n${GREEN}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    Blockcast BEACON Setup Complete!                 ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════════╝${NC}\n"
    
    echo -e "${CYAN}====== BACKUP THIS INFORMATION ======${NC}"
    echo -e "${YELLOW}Hardware ID:${NC} ${hwid}"
    echo -e "${YELLOW}Challenge Key:${NC} ${challenge_key}"
    if [[ -n "${reg_url}" ]]; then
        echo -e "${YELLOW}Registration URL:${NC} ${reg_url}"
    fi
    
    # Display build info
    echo -e "\n${CYAN}Build Information:${NC}"
    echo "${init_output}" | grep -i -E "commit|build|version" | sed 's/^/  /'
    
    # Display private keys with proper security warning
    echo -e "\n${RED}⚠️  SECURITY WARNING: Keep the following private keys secure!${NC}"
    echo -e "${CYAN}Private Keys Location:${NC}"
    
    local cert_files=("gw_challenge.key" "gateway.key" "gateway.crt")
    for cert_file in "${cert_files[@]}"; do
        local cert_path="${HOME}/.blockcast/certs/${cert_file}"
        if [[ -f "${cert_path}" ]]; then
            echo -e "\n${YELLOW}${cert_file}:${NC}"
            echo "Location: ${cert_path}"
            if [[ "${cert_file}" == *.key ]]; then
                echo -e "${RED}Content:${NC}"
                cat "${cert_path}"
            fi
        fi
    done
    
    echo -e "${CYAN}====== END BACKUP INFORMATION ======${NC}\n"
    
    # Next steps
    echo -e "${BLUE}Next Steps:${NC}"
    echo "1. 🌐 Visit https://app.blockcast.network/ and log in"
    echo "2. 📝 Go to Manage Nodes > Register Node"
    echo "3. 🔑 Enter the Hardware ID and Challenge Key shown above"
    if [[ -n "${reg_url}" ]]; then
        echo "   Or paste the Registration URL directly: ${reg_url}"
    fi
    echo "4. 📍 Enter your VM location (e.g., US, India, Indonesia)"
    echo "5. 💾 Save the backup information shown above in a secure location"
    echo ""
    echo -e "${GREEN}Important Notes:${NC}"
    echo "• Check node status at /manage-nodes after a few minutes"
    echo "• Node should show 'Healthy' status"
    echo "• First connectivity test runs after 6 hours"
    echo "• Rewards start after 24 hours"
    echo "• Monitor logs with: docker-compose logs -f"
    
    # Save information to file
    local info_file="${SCRIPT_DIR}/blockcast_node_info_$(date +%Y%m%d_%H%M%S).txt"
    cat > "${info_file}" << EOF
Blockcast BEACON Node Information
Generated: $(date)

Hardware ID: ${hwid}
Challenge Key: ${challenge_key}
Registration URL: ${reg_url}

Build Information:
$(echo "${init_output}" | grep -i -E "commit|build|version")

Certificate Files Location: ${HOME}/.blockcast/certs/
EOF
    
    log "INFO" "Node information saved to: ${info_file}"
}

# ============================================================================
# MAIN INSTALLATION FUNCTION
# ============================================================================

install_blockcast() {
    log "INFO" "Starting Blockcast BEACON installation..."
    
    check_requirements
    detect_os
    update_package_manager
    install_dependencies
    clone_repository
    start_blockcast
    generate_keys
    
    log "INFO" "Installation completed successfully!"
}

# ============================================================================
# MAIN SCRIPT LOGIC
# ============================================================================

main() {
    # Initialize logging
    touch "${LOG_FILE}"
    
    # Set up cleanup trap
    trap cleanup EXIT
    
    print_banner
    
    # Parse command line arguments
    local action="install"
    local backup_file=""
    local dry_run=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -u|--uninstall)
                action="uninstall"
                shift
                ;;
            -b|--backup)
                action="backup"
                shift
                ;;
            -r|--restore)
                action="restore"
                backup_file="${2}"
                shift 2
                ;;
            -c|--check)
                action="check"
                shift
                ;;
            -v|--verbose)
                export DEBUG=1
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                print_usage
                exit 1
                ;;
        esac
    done
    
    # Execute based on action
    case "${action}" in
        "install")
            if [[ "${dry_run}" == true ]]; then
                log "INFO" "DRY RUN: Would install Blockcast BEACON"
                check_requirements
                detect_os
                exit 0
            fi
            install_blockcast
            ;;
        "uninstall")
            if [[ "${dry_run}" == true ]]; then
                log "INFO" "DRY RUN: Would uninstall Blockcast BEACON"
                exit 0
            fi
            uninstall_blockcast
            ;;
        "backup")
            create_backup
            ;;
        "restore")
            restore_backup "${backup_file}"
            ;;
        "check")
            check_requirements
            detect_os
            log "INFO" "System check completed"
            ;;
    esac
}

# Run main function with all arguments
main "$@"
