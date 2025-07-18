#!/bin/bash
set -e

# Version: 1.2.8  # Cập nhật version sau khi thêm hỗ trợ đa ngôn ngữ
# Biến cấu hình
CONTAINER_NAME="nexus-node"
IMAGE_NAME="nexus-node:latest"
LOG_FILE="/root/nexus_logs/nexus.log"
SWAP_FILE="/swapfile"
WALLET_ADDRESS="$1"
NO_SWAP=0  # Mặc định không skip swap
LANGUAGE="vi"  # Mặc định tiếng Việt

# Parse arguments
shift  # Bỏ qua $1 (wallet)
while [ $# -gt 0 ]; do
    case "$1" in
        --no-swap)
            NO_SWAP=1
            shift
            ;;
        --en)
            LANGUAGE="en"
            shift
            ;;
        --ru)
            LANGUAGE="ru"
            shift
            ;;
        --cn)
            LANGUAGE="cn"
            shift
            ;;
        *)
            echo "Cảnh báo: Flag không hợp lệ: $1. Bỏ qua."  # Sẽ thay bằng biến sau
            shift
            ;;
    esac
done

# Kiểm tra wallet address
if [ -z "$WALLET_ADDRESS" ]; then
    echo "Lỗi: Vui lòng cung cấp wallet address. Cách dùng: $0 <wallet_address> [--no-swap] [--en|--ru|--cn]"  # Sẽ thay bằng biến sau
    exit 1
fi

# Xác định số luồng dựa trên số vCPU
max_threads=$(nproc)

# Định nghĩa tất cả thông báo dựa trên ngôn ngữ
case $LANGUAGE in
    vi)
        ERR_NO_WALLET="Lỗi: Vui lòng cung cấp wallet address. Cách dùng: $0 <wallet_address> [--no-swap] [--en|--ru|--cn]"
        WARN_INVALID_FLAG="Cảnh báo: Flag không hợp lệ: %s. Bỏ qua."
        SKIP_SWAP_FLAG="Bỏ qua tạo swap theo yêu cầu (--no-swap)."
        INSTALLING_DOCKER="Cài đặt Docker..."
        ERR_INSTALL_DOCKER="Lỗi: Không thể cài đặt Docker"
        ERR_DOCKER_NOT_RUNNING="Lỗi: Docker daemon không chạy"
        ERR_DOCKER_PERMISSION="Lỗi: Không có quyền chạy Docker. Kiểm tra cài đặt hoặc thêm user vào nhóm docker."
        BUILDING_IMAGE="Bắt đầu xây dựng image %s…"
        ERR_BUILD_IMAGE="Lỗi: Không thể xây dựng image %s"
        BUILD_IMAGE_SUCCESS="Xây dựng image %s thành công."
        NODE_STARTED="Đã chạy node với wallet_address=%s, max_threads=%s"
        LOG_FILE_MSG="Log: %s"
        VIEW_LOG="Xem log theo thời gian thực: docker logs -f %s"
        NOT_LINUX="Hệ thống không phải Linux, bỏ qua tạo swap."
        WARN_NO_RAM="Cảnh báo: Không thể xác định RAM hệ thống (có thể do quyền truy cập hoặc hệ thống không hỗ trợ). Bỏ qua tạo swap và tiếp tục chạy node."
        RAM_DETECTED="Tổng RAM phát hiện: %s MB. Tiếp tục kiểm tra swap..."
        SWAP_EXISTS="Swap đã tồn tại (%s MB), bỏ qua tạo swap."
        INSUFFICIENT_DISK="Không đủ dung lượng ổ cứng (%s MB) để tạo swap tối thiểu (%s MB). Bỏ qua."
        WARN_INVALID_SWAP_SIZE="Cảnh báo: Kích thước swap không hợp lệ (%s MB). Bỏ qua tạo swap."
        CREATING_SWAP="Tạo swap %s MB..."
        WARN_CREATE_SWAP_FAIL="Cảnh báo: Không thể tạo file swap. Bỏ qua."
        SWAP_CREATED="Swap đã được tạo và kích hoạt (%s MB)."
        # Thông báo trong entrypoint.sh
        ERR_MISSING_WALLET="Lỗi: Thiếu wallet address"
        REGISTERING_WALLET="Đăng ký ví với wallet: %s"
        ERR_REGISTER_WALLET="Lỗi: Không thể đăng ký ví. Xem log:"
        SUPPORT_INFO="Thông tin hỗ trợ:"
        REGISTERING_NODE="Đăng ký node..."
        ERR_REGISTER_NODE="Lỗi: Không thể đăng ký node. Xem log:"
        NODE_STARTED_ENTRY="Node đã khởi động với wallet_address=%s, max_threads=%s. Log: /root/nexus.log"
        STARTUP_FAILED="Khởi động thất bại. Xem log:"
        ;;
    en)
        ERR_NO_WALLET="Error: Please provide wallet address. Usage: $0 <wallet_address> [--no-swap] [--en|--ru|--cn]"
        WARN_INVALID_FLAG="Warning: Invalid flag: %s. Skipping."
        SKIP_SWAP_FLAG="Skipping swap creation as per request (--no-swap)."
        INSTALLING_DOCKER="Installing Docker..."
        ERR_INSTALL_DOCKER="Error: Unable to install Docker"
        ERR_DOCKER_NOT_RUNNING="Error: Docker daemon is not running"
        ERR_DOCKER_PERMISSION="Error: No permission to run Docker. Check installation or add user to docker group."
        BUILDING_IMAGE="Starting to build image %s..."
        ERR_BUILD_IMAGE="Error: Unable to build image %s"
        BUILD_IMAGE_SUCCESS="Built image %s successfully."
        NODE_STARTED="Node started with wallet_address=%s, max_threads=%s"
        LOG_FILE_MSG="Log: %s"
        VIEW_LOG="View real-time log: docker logs -f %s"
        NOT_LINUX="System is not Linux, skipping swap creation."
        WARN_NO_RAM="Warning: Unable to determine system RAM (possibly due to access rights or unsupported system). Skipping swap creation and continuing to run node."
        RAM_DETECTED="Detected total RAM: %s MB. Continuing to check swap..."
        SWAP_EXISTS="Swap already exists (%s MB), skipping swap creation."
        INSUFFICIENT_DISK="Insufficient disk space (%s MB) to create minimum swap (%s MB). Skipping."
        WARN_INVALID_SWAP_SIZE="Warning: Invalid swap size (%s MB). Skipping swap creation."
        CREATING_SWAP="Creating swap %s MB..."
        WARN_CREATE_SWAP_FAIL="Warning: Unable to create swap file. Skipping."
        SWAP_CREATED="Swap created and activated (%s MB)."
        # Thông báo trong entrypoint.sh
        ERR_MISSING_WALLET="Error: Missing wallet address"
        REGISTERING_WALLET="Registering wallet with: %s"
        ERR_REGISTER_WALLET="Error: Unable to register wallet. Check log:"
        SUPPORT_INFO="Support information:"
        REGISTERING_NODE="Registering node..."
        ERR_REGISTER_NODE="Error: Unable to register node. Check log:"
        NODE_STARTED_ENTRY="Node started with wallet_address=%s, max_threads=%s. Log: /root/nexus.log"
        STARTUP_FAILED="Startup failed. Check log:"
        ;;
    ru)
        ERR_NO_WALLET="Ошибка: Пожалуйста, укажите адрес кошелька. Использование: $0 <wallet_address> [--no-swap] [--en|--ru|--cn]"
        WARN_INVALID_FLAG="Предупреждение: Недопустимый флаг: %s. Пропускаю."
        SKIP_SWAP_FLAG="Пропуск создания swap по запросу (--no-swap)."
        INSTALLING_DOCKER="Установка Docker..."
        ERR_INSTALL_DOCKER="Ошибка: Не удается установить Docker"
        ERR_DOCKER_NOT_RUNNING="Ошибка: Daemon Docker не запущен"
        ERR_DOCKER_PERMISSION="Ошибка: Нет разрешения на запуск Docker. Проверьте установку или добавьте пользователя в группу docker."
        BUILDING_IMAGE="Начало сборки изображения %s..."
        ERR_BUILD_IMAGE="Ошибка: Не удается собрать изображение %s"
        BUILD_IMAGE_SUCCESS="Изображение %s собрано успешно."
        NODE_STARTED="Узел запущен с wallet_address=%s, max_threads=%s"
        LOG_FILE_MSG="Лог: %s"
        VIEW_LOG="Просмотр лога в реальном времени: docker logs -f %s"
        NOT_LINUX="Система не Linux, пропуск создания swap."
        WARN_NO_RAM="Предупреждение: Не удается определить RAM системы (возможно, из-за прав доступа или неподдерживаемой системы). Пропуск создания swap и продолжение запуска узла."
        RAM_DETECTED="Обнаружено всего RAM: %s МБ. Продолжение проверки swap..."
        SWAP_EXISTS="Swap уже существует (%s МБ), пропуск создания swap."
        INSUFFICIENT_DISK="Недостаточно места на диске (%s МБ) для создания минимального swap (%s МБ). Пропуск."
        WARN_INVALID_SWAP_SIZE="Предупреждение: Недопустимый размер swap (%s МБ). Пропуск создания swap."
        CREATING_SWAP="Создание swap %s МБ..."
        WARN_CREATE_SWAP_FAIL="Предупреждение: Не удается создать файл swap. Пропуск."
        SWAP_CREATED="Swap создан и активирован (%s МБ)."
        # Thông báo trong entrypoint.sh
        ERR_MISSING_WALLET="Ошибка: Отсутствует адрес кошелька"
        REGISTERING_WALLET="Регистрация кошелька с: %s"
        ERR_REGISTER_WALLET="Ошибка: Не удается зарегистрировать кошелек. Проверьте лог:"
        SUPPORT_INFO="Информация поддержки:"
        REGISTERING_NODE="Регистрация узла..."
        ERR_REGISTER_NODE="Ошибка: Не удается зарегистрировать узел. Проверьте лог:"
        NODE_STARTED_ENTRY="Узел запущен с wallet_address=%s, max_threads=%s. Лог: /root/nexus.log"
        STARTUP_FAILED="Запуск неудачен. Проверьте лог:"
        ;;
    cn)
        ERR_NO_WALLET="错误：请提供钱包地址。用法：$0 <wallet_address> [--no-swap] [--en|--ru|--cn]"
        WARN_INVALID_FLAG="警告：无效标志：%s。跳过。"
        SKIP_SWAP_FLAG="根据请求跳过swap创建 (--no-swap)。"
        INSTALLING_DOCKER="正在安装Docker..."
        ERR_INSTALL_DOCKER="错误：无法安装Docker"
        ERR_DOCKER_NOT_RUNNING="错误：Docker守护进程未运行"
        ERR_DOCKER_PERMISSION="错误：没有运行Docker的权限。请检查安装或将用户添加到docker组。"
        BUILDING_IMAGE="开始构建图像 %s..."
        ERR_BUILD_IMAGE="错误：无法构建图像 %s"
        BUILD_IMAGE_SUCCESS="图像 %s 构建成功。"
        NODE_STARTED="节点已启动，wallet_address=%s, max_threads=%s"
        LOG_FILE_MSG="日志：%s"
        VIEW_LOG="查看实时日志：docker logs -f %s"
        NOT_LINUX="系统不是Linux，跳过swap创建。"
        WARN_NO_RAM="警告：无法确定系统RAM（可能由于访问权限或不支持的系统）。跳过swap创建并继续运行节点。"
        RAM_DETECTED="检测到总RAM：%s MB。继续检查swap..."
        SWAP_EXISTS="Swap已存在（%s MB），跳过swap创建。"
        INSUFFICIENT_DISK="磁盘空间不足（%s MB）来创建最小swap（%s MB）。跳过。"
        WARN_INVALID_SWAP_SIZE="警告：无效的swap大小（%s MB）。跳过swap创建。"
        CREATING_SWAP="创建swap %s MB..."
        WARN_CREATE_SWAP_FAIL="警告：无法创建swap文件。跳过。"
        SWAP_CREATED="Swap已创建并激活（%s MB）。"
        # Thông báo trong entrypoint.sh
        ERR_MISSING_WALLET="错误：缺少钱包地址"
        REGISTERING_WALLET="正在注册钱包：%s"
        ERR_REGISTER_WALLET="错误：无法注册钱包。检查日志："
        SUPPORT_INFO="支持信息："
        REGISTERING_NODE="正在注册节点..."
        ERR_REGISTER_NODE="错误：无法注册节点。检查日志："
        NODE_STARTED_ENTRY="节点已启动，wallet_address=%s, max_threads=%s。日志：/root/nexus.log"
        STARTUP_FAILED="启动失败。检查日志："
        ;;
esac

# Kiểm tra wallet address (sau khi định nghĩa biến)
if [ -z "$WALLET_ADDRESS" ]; then
    echo "$ERR_NO_WALLET"
    exit 1
fi

# Hàm tạo swap tự động (thay echo bằng biến)
create_swap() {
    # Kiểm tra nếu là Linux, nếu không thì skip swap
    if [ "$(uname -s)" != "Linux" ]; then
        echo "$NOT_LINUX"
        return 0
    fi

    # Thử lấy tổng RAM (MB) từ nhiều nguồn, fallback nếu fail
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
        echo "$WARN_NO_RAM"
        return 0
    fi

    printf "$RAM_DETECTED\n" "$total_ram"

    if swapon --show | grep -q "$SWAP_FILE"; then
        current_swap=$(free -m | awk '/^Swap:/{print $2}' 2>/dev/null) || true
        if [ -n "$current_swap" ] && [ "$current_swap" -ge "$total_ram" ]; then
            printf "$SWAP_EXISTS\n" "$current_swap"
            return 0
        fi
        swapoff "$SWAP_FILE" 2>/dev/null || true
    fi

    min_swap=$total_ram
    max_swap=$((total_ram * 2))
    available_disk=$(df -BM --output=avail "$(dirname "$SWAP_FILE")" | tail -n 1 | grep -o '[0-9]\+' 2>/dev/null) || true
    if [ -z "$available_disk" ] || [ "$available_disk" -lt "$min_swap" ]; then
        printf "$INSUFFICIENT_DISK\n" "$available_disk" "$min_swap"
        return 0
    fi

    swap_size=$min_swap
    if [ "$available_disk" -ge "$max_swap" ]; then
        swap_size=$max_swap
    fi

    if [ "$swap_size" -le 0 ]; then
        printf "$WARN_INVALID_SWAP_SIZE\n" "$swap_size"
        return 0
    fi

    printf "$CREATING_SWAP\n" "$swap_size"
    if ! fallocate -l "${swap_size}M" "$SWAP_FILE" 2>/dev/null; then
        dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$swap_size" 2>/dev/null || true
    fi
    if [ ! -f "$SWAP_FILE" ] || [ $(stat -c %s "$SWAP_FILE" 2>/dev/null) -le 0 ]; then
        echo "$WARN_CREATE_SWAP_FAIL"
        return 0
    fi
    chmod 600 "$SWAP_FILE" 2>/dev/null || true
    mkswap "$SWAP_FILE" 2>/dev/null || true
    swapon "$SWAP_FILE" 2>/dev/null || true
    if ! grep -q "$SWAP_FILE" /etc/fstab; then
        echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab 2>/dev/null || true
    fi
    printf "$SWAP_CREATED\n" "$swap_size"
    return 0
}

# Kiểm tra và cài đặt Docker
if ! command -v docker >/dev/null 2>&1; then
    echo "$INSTALLING_DOCKER"
    apt update
    if ! apt install -y docker.io; then
        echo "$ERR_INSTALL_DOCKER"
        exit 1
    fi
    systemctl enable docker
    systemctl start docker
    if ! systemctl is-active --quiet docker; then
        echo "$ERR_DOCKER_NOT_RUNNING"
        exit 1
    fi
fi

# Kiểm tra quyền chạy Docker
if ! docker ps >/dev/null 2>&1; then
    echo "$ERR_DOCKER_PERMISSION"
    exit 1
fi

# Xây dựng Docker image
build_image() {
    printf "$BUILDING_IMAGE\n" "$IMAGE_NAME"
    workdir=$(mktemp -d)
    cd "$workdir"

    cat > Dockerfile <<EOF
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y curl screen bash && rm -rf /var/lib/apt/lists/*
RUN curl -sSL https://cli.nexus.xyz/ | NONINTERACTIVE=1 sh && ln -sf /root/.nexus/bin/nexus-network /usr/local/bin/nexus-network
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
EOF

    cat > entrypoint.sh <<EOF
#!/bin/bash
set -e
# Kiểm tra wallet address
if [ -z "\$WALLET_ADDRESS" ]; then
    echo "$ERR_MISSING_WALLET"
    exit 1
fi
# Đăng ký ví
printf "$REGISTERING_WALLET\n" "\$WALLET_ADDRESS"
nexus-network register-user --wallet-address "\$WALLET_ADDRESS" &>> /root/nexus.log
if [ \$? -ne 0 ]; then
    echo "$ERR_REGISTER_WALLET"
    cat /root/nexus.log
    echo "$SUPPORT_INFO"
    nexus-network --help &>> /root/nexus.log
    cat /root/nexus.log
    exit 1
fi
# Đăng ký node
echo "$REGISTERING_NODE"
nexus-network register-node &>> /root/nexus.log
if [ \$? -ne 0 ]; then
    echo "$ERR_REGISTER_NODE"
    cat /root/nexus.log
    echo "$SUPPORT_INFO"
    nexus-network register-node --help &>> /root/nexus.log
    cat /root/nexus.log
    exit 1
fi
# Chạy node
screen -dmS nexus bash -c "nexus-network start --max-threads $max_threads &>> /root/nexus.log"
sleep 3
if screen -list | grep -q "nexus"; then
    printf "$NODE_STARTED_ENTRY\n" "\$WALLET_ADDRESS" "$max_threads"
else
    echo "$STARTUP_FAILED"
    cat /root/nexus.log
    exit 1
fi
tail -f /root/nexus.log
EOF

    if ! docker build -t "$IMAGE_NAME" .; then
        printf "$ERR_BUILD_IMAGE\n" "$IMAGE_NAME"
        cd -
        rm -rf "$workdir"
        exit 1
    fi
    cd -
    rm -rf "$workdir"
    printf "$BUILD_IMAGE_SUCCESS\n" "$IMAGE_NAME"
}

# Chạy container
run_container() {
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"

    docker run -d --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        -v "$LOG_FILE":/root/nexus.log \
        -e WALLET_ADDRESS="$WALLET_ADDRESS" \
        "$IMAGE_NAME"
    printf "$NODE_STARTED\n" "$WALLET_ADDRESS" "$max_threads"
    printf "$LOG_FILE_MSG\n" "$LOG_FILE"
    printf "$VIEW_LOG\n" "$CONTAINER_NAME"
}

# Tạo swap trước khi chạy node (nếu không có flag --no-swap)
if [ "$NO_SWAP" = 1 ]; then
    echo "$SKIP_SWAP_FLAG"
else
    create_swap
fi

# Xây dựng Docker image
build_image

# Chạy container
run_container
