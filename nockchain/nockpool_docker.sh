#!/bin/bash

# Script tối ưu: Cài Nvidia Docker & chạy nockpool-miner với auto-restart
# Phiên bản này dành cho WSL sử dụng GPU, nếu bạn chạy CPU xem file nockpool.sh
# Hỗ trợ arg cho ACCOUNT_TOKEN, lưu vào ~/.profile (chuẩn cho WSL login shell)

set -euo pipefail  # Strict mode: Exit on error, undefined vars, pipe failures

# Colors cho output đẹp
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Divider cho headers
header() { echo -e "${BLUE}=== $1 ===${NC}"; }
success() { echo -e "${GREEN}✓ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
error() { echo -e "${RED}✗ $1${NC}"; >&2; }

# Function: Xử lý ACCOUNT_TOKEN (arg ưu tiên > env > input)
handle_token() {
    local token="${1:-${ACCOUNT_TOKEN:-}}"
    if [[ -z "$token" ]]; then
        echo -e "${YELLOW}Nhập ACCOUNT_TOKEN (ví dụ: nockacct_...):${NC}"
        read -r token
        if [[ -z "$token" ]]; then
            error "ACCOUNT_TOKEN không được để trống. Thoát."
            exit 1
        fi
    fi

    # Kiểm tra và lưu vào ~/.profile nếu chưa có
    local profile_line="export ACCOUNT_TOKEN=$token"
    if ! grep -q '^export ACCOUNT_TOKEN=' ~/.profile 2>/dev/null; then
        echo "$profile_line" >> ~/.profile
        success "Đã lưu ACCOUNT_TOKEN vào ~/.profile (sẽ load khi WSL khởi động)."
    else
        warn "ACCOUNT_TOKEN đã tồn tại trong ~/.profile, bỏ qua."
    fi

    # Load ngay lập tức
    export ACCOUNT_TOKEN="$token"
    source ~/.profile 2>/dev/null || true
    success "Sử dụng ACCOUNT_TOKEN: ${YELLOW}$ACCOUNT_TOKEN${NC}"
}

# Function: Cài Nvidia Container Toolkit (idempotent)
install_toolkit() {
    if [[ ! -f /etc/apt/sources.list.d/nvidia-container-toolkit.list ]]; then
        header "Cài Nvidia Container Toolkit"
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
        && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
        sudo apt-get update -qq
        local version=1.17.8-1
        sudo apt-get install -y \
            "nvidia-container-toolkit=$version" \
            "nvidia-container-toolkit-base=$version" \
            "libnvidia-container-tools=$version" \
            "libnvidia-container1=$version"
        sudo nvidia-ctk runtime configure --runtime=docker
        sudo systemctl restart docker
        success "Nvidia Toolkit installed."
    else
        warn "Nvidia Toolkit đã tồn tại."
    fi
}

# Function: Khởi động Docker nếu cần
ensure_docker() {
    if ! systemctl is-active --quiet docker; then
        header "Khởi động Docker"
        sudo systemctl start docker
        success "Docker started."
    fi
}

# Function: Quản lý container (start nếu exist, run nếu không)
manage_container() {
    local name="nockpool-miner"
    header "Quản lý container $name"

    if docker ps -a --format '{{.Names}}' | grep -q "^$name$"; then
        if docker ps --format '{{.Names}}' | grep -q "^$name$"; then
            warn "Container $name đang chạy."
        else
            docker start "$name"
            success "Container $name started."
        fi
    else
        docker run -d --name "$name" \
            --gpus all \
            --runtime=nvidia \
            -e NVIDIA_VISIBLE_DEVICES=all \
            -e NVIDIA_DRIVER_CAPABILITIES=all \
            --net=host \
            -e ACCOUNT_TOKEN="$ACCOUNT_TOKEN" \
            --restart=unless-stopped \
            swpsco/miner-launcher:latest
        success "Container $name created & running."
    fi
}

# Main execution
header "Setup Nvidia Docker & nockpool-miner"
handle_token "$1"
install_toolkit
ensure_docker
manage_container

# Tóm tắt cuối
echo -e "\n${GREEN}=== Hoàn tất! ===${NC}"
echo "Trạng thái container:"
docker ps --filter "name=nockpool-miner" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || true
echo -e "\n${YELLOW}Lưu ý:${NC}"
echo "- Chạy: ./nockpool_docker.sh [token] để truyền token mới."
echo "- Container auto-restart khi WSL reboot (nhờ --restart=unless-stopped)."
echo "- Dừng: docker stop nockpool-miner | Xóa: docker rm -f nockpool-miner."
echo "- Env load từ ~/.profile khi WSL start. Kiểm tra: echo \$ACCOUNT_TOKEN."
