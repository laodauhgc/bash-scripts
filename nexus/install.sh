#!/bin/bash
set -e

# Version: 1.3.2  # Cập nhật version sau khi sửa CLI tải binary mới nhất và hỗ trợ ARM
# Biến cấu hình
CONTAINER_NAME="nexus-node"
IMAGE_NAME="nexus-node:latest"
LOG_FILE="/root/nexus_logs/nexus.log"
CREDENTIALS_DIR="/root/nexus_credentials"  # Thư mục host để mount ~/.nexus
NODE_ID_FILE="/root/nexus_node_id.txt"  # File lưu node ID
SWAP_FILE="/swapfile"
WALLET_ADDRESS="$1"
NO_SWAP=0
LANGUAGE="vi"
SETUP_CRON=0  # Mặc định không tự động thiết lập cron

# Parse arguments
shift
while [ $# -gt 0 ]; do
    case "$1" in
        --no-swap) NO_SWAP=1; shift ;;
        --en) LANGUAGE="en"; shift ;;
        --ru) LANGUAGE="ru"; shift ;;
        --cn) LANGUAGE="cn"; shift ;;
        --setup-cron) SETUP_CRON=1; shift ;;
        *) print_warning "$(printf "$WARN_INVALID_FLAG" "$1")"; shift ;;
    esac
done

# Định nghĩa màu sắc và icon
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Hàm in output với màu và icon
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️ $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ️ $1${NC}"; }
print_progress() { echo -e "${CYAN}⏳ $1${NC}"; }
print_node() { echo -e "${GREEN}🚀 $1${NC}"; }
print_log() { echo -e "${CYAN}📜 $1${NC}"; }
print_swap() { echo -e "${BLUE}💾 $1${NC}"; }
print_docker() { echo -e "${BLUE}🐳 $1${NC}"; }

# Định nghĩa tất cả thông báo dựa trên ngôn ngữ
case $LANGUAGE in
    vi)
        BANNER="===== Cài Đặt Node Nexus v1.3.2 (Hỗ trợ ARM) ====="
        ERR_NO_WALLET="Lỗi: Vui lòng cung cấp wallet address. Cách dùng: $0 <wallet_address> [--no-swap] [--en|--ru|--cn] [--setup-cron]"
        WARN_INVALID_FLAG="Cảnh báo: Flag không hợp lệ: %s. Bỏ qua."
        SKIP_SWAP_FLAG="Bỏ qua tạo swap theo yêu cầu (--no-swap)."
        INSTALLING_DOCKER="Cài đặt Docker..."
        ERR_INSTALL_DOCKER="Lỗi: Không thể cài đặt Docker."
        ERR_DOCKER_NOT_RUNNING="Lỗi: Docker daemon không chạy."
        ERR_DOCKER_PERMISSION="Lỗi: Không có quyền chạy Docker. Kiểm tra cài đặt hoặc thêm user vào nhóm docker."
        BUILDING_IMAGE="Bắt đầu xây dựng image %s…"
        ERR_BUILD_IMAGE="Lỗi: Không thể xây dựng image %s."
        BUILD_IMAGE_SUCCESS="Xây dựng image %s thành công."
        NODE_STARTED="Đã chạy node với wallet_address=%s."
        LOG_FILE_MSG="Log: %s"
        VIEW_LOG="Xem log theo thời gian thực: docker logs -f %s"
        NOT_LINUX="Hệ thống không phải Linux, bỏ qua tạo swap."
        WARN_NO_RAM="Cảnh báo: Không thể xác định RAM hệ thống. Bỏ qua tạo swap và tiếp tục chạy node."
        RAM_DETECTED="Tổng RAM phát hiện: %s MB. Tiếp tục kiểm tra swap..."
        SWAP_EXISTS="Swap đã tồn tại (%s MB), bỏ qua tạo swap."
        INSUFFICIENT_DISK="Không đủ dung lượng ổ cứng (%s MB) để tạo swap tối thiểu (%s MB). Bỏ qua."
        WARN_INVALID_SWAP_SIZE="Cảnh báo: Kích thước swap không hợp lệ (%s MB). Bỏ qua tạo swap."
        CREATING_SWAP="Tạo swap %s MB..."
        WARN_CREATE_SWAP_FAIL="Cảnh báo: Không thể tạo file swap. Bỏ qua."
        SWAP_CREATED="Swap đã được tạo và kích hoạt (%s MB)."
        ERR_MISSING_WALLET="Lỗi: Thiếu wallet address hoặc node ID."
        REGISTERING_WALLET="Đăng ký ví với wallet: %s"
        ERR_REGISTER_WALLET="Lỗi: Không thể đăng ký ví. Xem log:"
        SUPPORT_INFO="Thông tin hỗ trợ:"
        REGISTERING_NODE="Đăng ký node..."
        ERR_REGISTER_NODE="Lỗi: Không thể đăng ký node. Xem log:"
        NODE_STARTED_ENTRY="Node đã khởi động với wallet_address=%s. Log: /root/nexus.log"
        STARTUP_FAILED="Khởi động thất bại. Xem log:"
        NODE_ID_SAVED="Node ID đã được lưu: %s"
        USING_EXISTING_NODE_ID="Sử dụng node ID hiện có: %s"
        CRON_SETUP="Thiết lập cron job để khởi tạo lại container mỗi giờ."
        CRON_INSTRUCTION="Cron job đã được thêm: @hourly docker rm -f %s; /bin/bash %s %s"
        ARCH_DETECTED="Phát hiện kiến trúc hệ thống: %s. Sử dụng CLI phù hợp."
        ;;
    en)
        BANNER="===== Nexus Node Setup v1.3.2 (ARM Support) ====="
        ERR_NO_WALLET="Error: Please provide wallet address. Usage: $0 <wallet_address> [--no-swap] [--en|--ru|--cn] [--setup-cron]"
        WARN_INVALID_FLAG="Warning: Invalid flag: %s. Skipping."
        SKIP_SWAP_FLAG="Skipping swap creation as per request (--no-swap)."
        INSTALLING_DOCKER="Installing Docker..."
        ERR_INSTALL_DOCKER="Error: Unable to install Docker."
        ERR_DOCKER_NOT_RUNNING="Error: Docker daemon is not running."
        ERR_DOCKER_PERMISSION="Error: No permission to run Docker. Check installation or add user to docker group."
        BUILDING_IMAGE="Starting to build image %s..."
        ERR_BUILD_IMAGE="Error: Unable to build image %s."
        BUILD_IMAGE_SUCCESS="Built image %s successfully."
        NODE_STARTED="Node started with wallet_address=%s."
        LOG_FILE_MSG="Log: %s"
        VIEW_LOG="View real-time log: docker logs -f %s"
        NOT_LINUX="System is not Linux, skipping swap creation."
        WARN_NO_RAM="Warning: Unable to determine system RAM. Skipping swap creation and continuing to run node."
        RAM_DETECTED="Detected total RAM: %s MB. Continuing to check swap..."
        SWAP_EXISTS="Swap already exists (%s MB), skipping swap creation."
        INSUFFICIENT_DISK="Insufficient disk space (%s MB) to create minimum swap (%s MB). Skipping."
        WARN_INVALID_SWAP_SIZE="Warning: Invalid swap size (%s MB). Skipping swap creation."
        CREATING_SWAP="Creating swap %s MB..."
        WARN_CREATE_SWAP_FAIL="Warning: Unable to create swap file. Skipping."
        SWAP_CREATED="Swap created and activated (%s MB)."
        ERR_MISSING_WALLET="Error: Missing wallet address or node ID."
        REGISTERING_WALLET="Registering wallet with: %s"
        ERR_REGISTER_WALLET="Error: Unable to register wallet. Check log:"
        SUPPORT_INFO="Support information:"
        REGISTERING_NODE="Registering node..."
        ERR_REGISTER_NODE="Error: Unable to register node. Check log:"
        NODE_STARTED_ENTRY="Node started with wallet_address=%s. Log: /root/nexus.log"
        STARTUP_FAILED="Startup failed. Check log:"
        NODE_ID_SAVED="Node ID saved: %s"
        USING_EXISTING_NODE_ID="Using existing node ID: %s"
        CRON_SETUP="Setting up cron job to recreate container every hour."
        CRON_INSTRUCTION="Cron job added: @hourly docker rm -f %s; /bin/bash %s %s"
        ARCH_DETECTED="Detected system architecture: %s. Using appropriate CLI."
        ;;
    ru)
        BANNER="===== Установка Узла Nexus v1.3.2 (Поддержка ARM) ====="
        ERR_NO_WALLET="Ошибка: Пожалуйста, укажите адрес кошелька. Использование: $0 <wallet_address> [--no-swap] [--en|--ru|--cn] [--setup-cron]"
        WARN_INVALID_FLAG="Предупреждение: Недопустимый флаг: %s. Пропускаю."
        SKIP_SWAP_FLAG="Пропуск создания swap по запросу (--no-swap)."
        INSTALLING_DOCKER="Установка Docker..."
        ERR_INSTALL_DOCKER="Ошибка: Не удается установить Docker."
        ERR_DOCKER_NOT_RUNNING="Ошибка: Daemon Docker не запущен."
        ERR_DOCKER_PERMISSION="Ошибка: Нет разрешения на запуск Docker. Проверьте установку или добавьте пользователя в группу docker."
        BUILDING_IMAGE="Начало сборки изображения %s..."
        ERR_BUILD_IMAGE="Ошибка: Не удается собрать изображение %s."
        BUILD_IMAGE_SUCCESS="Изображение %s собрано успешно."
        NODE_STARTED="Узел запущен с wallet_address=%s."
        LOG_FILE_MSG="Лог: %s"
        VIEW_LOG="Просмотр лога в реальном времени: docker logs -f %s"
        NOT_LINUX="Система не Linux, пропуск создания swap."
        WARN_NO_RAM="Предупреждение: Не удается определить RAM системы. Пропуск создания swap и продолжение запуска узла."
        RAM_DETECTED="Обнаружено всего RAM: %s МБ. Продолжение проверки swap..."
        SWAP_EXISTS="Swap уже существует (%s МБ), пропуск создания swap."
        INSUFFICIENT_DISK="Недостаточно места на диске (%s МБ) для создания минимального swap (%s МБ). Пропуск."
        WARN_INVALID_SWAP_SIZE="Предупреждение: Недопустимый размер swap (%s МБ). Пропуск создания swap."
        CREATING_SWAP="Создание swap %s МБ..."
        WARN_CREATE_SWAP_FAIL="Предупреждение: Не удается создать файл swap. Пропуск."
        SWAP_CREATED="Swap создан и активирован (%s МБ)."
        ERR_MISSING_WALLET="Ошибка: Отсутствует адрес кошелька или node ID."
        REGISTERING_WALLET="Регистрация кошелька с: %s"
        ERR_REGISTER_WALLET="Ошибка: Не удается зарегистрировать кошелек. Проверьте лог:"
        SUPPORT_INFO="Информация поддержки:"
        REGISTERING_NODE="Регистрация узла..."
        ERR_REGISTER_NODE="Ошибка: Не удается зарегистрировать узел. Проверьте лог:"
        NODE_STARTED_ENTRY="Узел запущен с wallet_address=%s. Лог: /root/nexus.log"
        STARTUP_FAILED="Запуск неудачен. Проверьте лог:"
        NODE_ID_SAVED="Node ID сохранен: %s"
        USING_EXISTING_NODE_ID="Использование существующего node ID: %s"
        ARCH_DETECTED="Обнаруженная архитектура системы: %s. Использование соответствующего CLI."
        ;;
    cn)
        BANNER="===== Nexus 节点设置 v1.3.2 (ARM 支持) ====="
        ERR_NO_WALLET="错误：请提供钱包地址。用法：$0 <wallet_address> [--no-swap] [--en|--ru|--cn] [--setup-cron]"
        WARN_INVALID_FLAG="警告：无效标志：%s。跳过。"
        SKIP_SWAP_FLAG="根据请求跳过swap创建 (--no-swap)。"
        INSTALLING_DOCKER="正在安装Docker..."
        ERR_INSTALL_DOCKER="错误：无法安装Docker。"
        ERR_DOCKER_NOT_RUNNING="错误：Docker守护进程未运行。"
        ERR_DOCKER_PERMISSION="错误：没有运行Docker的权限。请检查安装或将用户添加到docker组。"
        BUILDING_IMAGE="开始构建图像 %s..."
        ERR_BUILD_IMAGE="错误：无法构建图像 %s。"
        BUILD_IMAGE_SUCCESS="图像 %s 构建成功。"
        NODE_STARTED="节点已启动，wallet_address=%s。"
        LOG_FILE_MSG="日志：%s"
        VIEW_LOG="查看实时日志：docker logs -f %s"
        NOT_LINUX="系统不是Linux，跳过swap创建。"
        WARN_NO_RAM="警告：无法确定系统RAM。跳过swap创建并继续运行节点。"
        RAM_DETECTED="检测到总RAM：%s MB。继续检查swap..."
        SWAP_EXISTS="Swap已存在（%s MB），跳过swap创建。"
        INSUFFICIENT_DISK="磁盘空间不足（%s MB）来创建最小swap（%s MB）。跳过。"
        WARN_INVALID_SWAP_SIZE="警告：无效的swap大小（%s MB）。跳过swap创建。"
        CREATING_SWAP="创建swap %s MB..."
        WARN_CREATE_SWAP_FAIL="警告：无法创建swap文件。跳过。"
        SWAP_CREATED="Swap已创建并激活（%s MB）。"
        ERR_MISSING_WALLET="错误：缺少钱包地址或node ID。"
        REGISTERING_WALLET="正在注册钱包：%s"
        ERR_REGISTER_WALLET="错误：无法注册钱包。检查日志："
        SUPPORT_INFO="支持信息："
        REGISTERING_NODE="正在注册节点..."
        ERR_REGISTER_NODE="错误：无法注册节点。检查日志："
        NODE_STARTED_ENTRY="节点已启动，wallet_address=%s。日志：/root/nexus.log"
        STARTUP_FAILED="启动失败。检查日志："
        NODE_ID_SAVED="Node ID 已保存：%s"
        USING_EXISTING_NODE_ID="使用现有的 node ID：%s"
        ARCH_DETECTED="检测到系统架构：%s。使用适当的 CLI。"
        ;;
esac

# In banner đầu tiên
print_info "$BANNER"

# Kiểm tra wallet address
if [ -z "$WALLET_ADDRESS" ]; then
    print_error "$ERR_NO_WALLET"
    exit 1
fi

# Phát hiện kiến trúc hệ thống để chọn CLI suffix
ARCH=$(uname -m)
print_info "$(printf "$ARCH_DETECTED" "$ARCH")"
CLI_SUFFIX="linux-x86_64"
if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    CLI_SUFFIX="linux-arm64"
fi

# Tải latest tag từ GitHub API (cài jq nếu chưa có)
if ! command -v jq > /dev/null 2>&1; then
    apt update && apt install -y jq
fi
LATEST_TAG=$(curl -s https://api.github.com/repos/nexus-xyz/nexus-cli/releases/latest | jq -r .tag_name)
CLI_URL="https://github.com/nexus-xyz/nexus-cli/releases/download/${LATEST_TAG}/nexus-network-${CLI_SUFFIX}"

# Hàm tạo swap tự động
create_swap() {
    if [ "$(uname -s)" != "Linux" ]; then
        print_warning "$NOT_LINUX"
        return 0
    fi

    total_ram=""
    if [ -f /proc/meminfo ]; then
        total_ram=$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null) || true
    fi
    if [ -z "$total_ram" ] || [ "$total_ram" -le 0 ]; then
        total_ram=$(free -m | awk '/^Mem:/{print $2}' 2>/dev/null) || true
    fi
    if [ -z "$total_ram" ] || [ "$total_ram" -le 0 ]; then
        total_ram=$(vmstat -s | awk '/total memory/{print int($1 / 1024)}' 2>/dev/null) || true
    fi
    if [ -z "$total_ram" ] || [ "$total_ram" -le 0 ]; then
        print_warning "$WARN_NO_RAM"
        return 0
    fi

    print_info "$(printf "$RAM_DETECTED" "$total_ram")"

    if swapon --show | grep -q "$SWAP_FILE"; then
        current_swap=$(free -m | awk '/^Swap:/{print $2}' 2>/dev/null) || true
        if [ -n "$current_swap" ] && [ "$current_swap" -ge "$total_ram" ]; then
            print_info "$(printf "$SWAP_EXISTS" "$current_swap")"
            return 0
        fi
        swapoff "$SWAP_FILE" 2>/dev/null || true
    fi

    min_swap=$total_ram
    max_swap=$((total_ram * 2))
    available_disk=$(df -BM --output=avail "$(dirname "$SWAP_FILE")" | tail -n 1 | grep -o '[0-9]\+' 2>/dev/null) || true
    if [ -z "$available_disk" ] || [ "$available_disk" -lt "$min_swap" ]; then
        print_warning "$(printf "$INSUFFICIENT_DISK" "$available_disk" "$min_swap")"
        return 0
    fi

    swap_size=$min_swap
    if [ "$available_disk" -ge "$max_swap" ]; then
        swap_size=$max_swap
    fi

    if [ "$swap_size" -le 0 ]; then
        print_warning "$(printf "$WARN_INVALID_SWAP_SIZE" "$swap_size")"
        return 0
    fi

    print_progress "$(printf "$CREATING_SWAP" "$swap_size")"
    if ! fallocate -l "${swap_size}M" "$SWAP_FILE" 2>/dev/null; then
        dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$swap_size" 2>/dev/null || true
    fi
    if [ ! -f "$SWAP_FILE" ] || [ $(stat -c %s "$SWAP_FILE" 2>/dev/null) -le 0 ]; then
        print_warning "$WARN_CREATE_SWAP_FAIL"
        return 0
    fi
    chmod 600 "$SWAP_FILE" 2>/dev/null || true
    mkswap "$SWAP_FILE" 2>/dev/null || true
    swapon "$SWAP_FILE" 2>/dev/null || true
    if ! grep -q "$SWAP_FILE" /etc/fstab; then
        echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab 2>/dev/null || true
    fi
    print_swap "$(printf "$SWAP_CREATED" "$swap_size")"
    return 0
}

# Kiểm tra và cài đặt Docker
if ! command -v docker >/dev/null 2>&1; then
    print_progress "$INSTALLING_DOCKER"
    apt update
    if ! apt install -y docker.io; then
        print_error "$ERR_INSTALL_DOCKER"
        exit 1
    fi
    systemctl enable docker
    systemctl start docker
    if ! systemctl is-active --quiet docker; then
        print_error "$ERR_DOCKER_NOT_RUNNING"
        exit 1
    fi
fi

if ! docker ps >/dev/null 2>&1; then
    print_error "$ERR_DOCKER_PERMISSION"
    exit 1
fi

# Xây dựng Docker image
build_image() {
    print_progress "$(printf "$BUILDING_IMAGE" "$IMAGE_NAME")"
    workdir=$(mktemp -d)
    cd "$workdir"

    cat > Dockerfile <<EOF
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y curl screen bash jq && rm -rf /var/lib/apt/lists/*
RUN curl -L $CLI_URL -o /usr/local/bin/nexus-network && chmod +x /usr/local/bin/nexus-network
RUN mkdir -p /root/.nexus # Tạo thư mục nếu CLI cần
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
EOF

    cat > entrypoint.sh <<EOF
#!/bin/bash
set -e
if [ -z "\$WALLET_ADDRESS" ] && [ -z "\$NODE_ID" ]; then
    echo "${RED}❌ $ERR_MISSING_WALLET${NC}"
    exit 1
fi

if [ -n "\$NODE_ID" ]; then
    echo "${CYAN}⏳ Khởi động với node ID: \$NODE_ID${NC}"
    screen -dmS nexus bash -c "nexus-network start --node-id \$NODE_ID &>> /root/nexus.log"
else
    printf "${CYAN}⏳ $REGISTERING_WALLET\n${NC}" "\$WALLET_ADDRESS"
    nexus-network register-user --wallet-address "\$WALLET_ADDRESS" &>> /root/nexus.log
    if [ \$? -ne 0 ]; then
        echo "${RED}❌ $ERR_REGISTER_WALLET${NC}"
        cat /root/nexus.log
        echo "${BLUE}ℹ️ $SUPPORT_INFO${NC}"
        nexus-network --help &>> /root/nexus.log
        cat /root/nexus.log
        exit 1
    fi
    echo "${CYAN}⏳ $REGISTERING_NODE${NC}"
    nexus-network register-node &>> /root/nexus.log
    if [ \$? -ne 0 ]; then
        echo "${RED}❌ $ERR_REGISTER_NODE${NC}"
        cat /root/nexus.log
        echo "${BLUE}ℹ️ $SUPPORT_INFO${NC}"
        nexus-network register-node --help &>> /root/nexus.log
        cat /root/nexus.log
        exit 1
    fi
    screen -dmS nexus bash -c "nexus-network start &>> /root/nexus.log"
fi
sleep 3
if screen -list | grep -q "nexus"; then
    printf "${GREEN}🚀 $NODE_STARTED_ENTRY\n${NC}" "\$WALLET_ADDRESS"
else
    echo "${RED}❌ $STARTUP_FAILED${NC}"
    cat /root/nexus.log
    exit 1
fi
tail -f /root/nexus.log
EOF

    if ! docker build -t "$IMAGE_NAME" .; then
        print_error "$(printf "$ERR_BUILD_IMAGE" "$IMAGE_NAME")"
        cd -
        rm -rf "$workdir"
        exit 1
    fi
    cd -
    rm -rf "$workdir"
    print_success "$(printf "$BUILD_IMAGE_SUCCESS" "$IMAGE_NAME")"
}

# Hàm chạy container
run_container() {
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    mkdir -p "$(dirname "$LOG_FILE")" "$CREDENTIALS_DIR"
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"

    NODE_ID=""
    if [ -f "$NODE_ID_FILE" ]; then
        NODE_ID=$(cat "$NODE_ID_FILE")
        print_info "$(printf "$USING_EXISTING_NODE_ID" "$NODE_ID")"
    fi

    docker run -d --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        -v "$LOG_FILE":/root/nexus.log \
        -v "$CREDENTIALS_DIR":/root/.nexus \
        -e WALLET_ADDRESS="$WALLET_ADDRESS" \
        -e NODE_ID="$NODE_ID" \
        "$IMAGE_NAME"
    print_node "$(printf "$NODE_STARTED" "$WALLET_ADDRESS")"
    print_log "$(printf "$LOG_FILE_MSG" "$LOG_FILE")"
    print_info "$(printf "$VIEW_LOG" "$CONTAINER_NAME")"

    if [ -z "$NODE_ID" ]; then
        sleep 10
        if [ -f "$CREDENTIALS_DIR/credentials.json" ]; then
            NODE_ID=$(jq -r '.node_id' "$CREDENTIALS_DIR/credentials.json" 2>/dev/null)
            if [ -n "$NODE_ID" ]; then
                echo "$NODE_ID" > "$NODE_ID_FILE"
                print_success "$(printf "$NODE_ID_SAVED" "$NODE_ID")"
            else
                print_warning "Không thể extract node ID từ credentials.json"
            fi
        fi
    fi
}

# Tạo swap trước khi chạy node
if [ "$NO_SWAP" = 1 ]; then
    print_warning "$SKIP_SWAP_FLAG"
else
    create_swap
fi

# Xây dựng và chạy
build_image
run_container

# In footer
print_success "===== Hoàn Tất Cài Đặt ====="
