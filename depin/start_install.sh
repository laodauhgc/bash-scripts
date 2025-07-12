#!/usr/bin/env bash
# Script tự động cài đặt Titan Edge, Nexus Node, và SOCKS5 Proxy trên Ubuntu bằng Docker
# Phiên bản: 1.0.0 (Ngày: 12/07/2025 - Đã gộp titan-edge, nexus-node, socks5-proxy; tối ưu gói và xử lý UFW an toàn)
set -euo pipefail

# ==== Màu sắc cho log ====
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RESET='\033[0m'

log()    { echo -e "${2:-$GREEN}$1${RESET}"; }
error()  { log "$1" "$RED"; }
warn()   { log "$1" "$YELLOW"; }
die()    { error "$1"; exit 1; }

# ==== Kiểm tra quyền root ====
check_root() {
  if [ "$EUID" -ne 0 ]; then
    die "Vui lòng chạy script với quyền root (sudo)."
  fi
}

# ==== Phát hiện hệ điều hành và package manager (tối ưu cho Ubuntu) ====
detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    OS_NAME=$NAME
  else
    die "Không thể xác định hệ điều hành!"
  fi

  if command -v apt >/dev/null 2>&1; then
    PKG_MANAGER="apt"
    UPDATE_CMD="apt update -y"
    INSTALL_CMD="apt install -y --no-install-recommends"
    QUERY_CMD="dpkg -s"
  else
    die "Không tìm thấy package manager apt trên Ubuntu!"
  fi
}

# ==== Danh sách package cần thiết (tối ưu, chỉ giữ cốt lõi) ====
ESSENTIAL_PACKAGES=(
  # Dev & build cơ bản
  gcc make
  # System/network
  lsof traceroute tcpdump screen
  # Nén/giải nén
  unzip
  # Python-related (cơ bản)
  python3-pip
  # Khác
  curl wget git htop net-tools build-essential nano openssh-server jq openssl ca-certificates
  # Thêm cho SOCKS5 (nếu cần)
  ufw
)

# ==== Cài đặt package cần thiết ====
install_essential_packages() {
  log "Cập nhật hệ thống..."
  eval "$UPDATE_CMD" >/dev/null 2>&1

  log "Bắt đầu cài đặt các gói cần thiết..."
  local to_install=()
  for pkg in "${ESSENTIAL_PACKAGES[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      to_install+=("$pkg")
    else
      warn "Gói $pkg đã được cài đặt. Bỏ qua."
    fi
  done

  if [ ${#to_install[@]} -gt 0 ]; then
    eval "$INSTALL_CMD ${to_install[*]}" || warn "Có lỗi khi cài đặt một số gói."
    log "Đã cài đặt các gói: ${to_install[*]}"
  else
    log "Tất cả các gói cần thiết đã được cài đặt."
  fi
}

# ==== Cài đặt Docker nếu chưa có ====
install_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    log "Cài đặt Docker..."
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt update
    apt install -y --no-install-recommends docker-ce docker-ce-cli containerd.io
    systemctl start docker
    systemctl enable docker
  else
    log "Docker đã được cài đặt."
  fi

  # Kiểm tra quyền chạy Docker
  if ! docker ps >/dev/null 2>&1; then
    die "Lỗi: Không có quyền chạy Docker. Kiểm tra cài đặt hoặc thêm user vào nhóm docker."
  fi
}

# ==== Cài đặt Docker Compose nếu chưa có ====
install_docker_compose() {
  if ! command -v docker-compose >/dev/null 2>&1; then
    log "Cài đặt Docker Compose..."
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
  else
    log "Docker Compose đã được cài đặt."
  fi
}

# ==== Tăng UDP buffer sizes cho titan-edge ====
increase_udp_buffers() {
  log "Increasing UDP buffer sizes for better performance..."
  
  # Current values
  echo -e "${BLUE}Current UDP buffer values:${RESET}"
  echo "net.core.rmem_max: $(sysctl -n net.core.rmem_max)"
  echo "net.core.wmem_max: $(sysctl -n net.core.wmem_max)"
  
  # Increase UDP buffer sizes
  sysctl -w net.core.rmem_max=2500000 > /dev/null
  sysctl -w net.core.wmem_max=2500000 > /dev/null
  
  # Make changes persistent
  if ! grep -q "net.core.rmem_max" /etc/sysctl.conf; then
      echo "net.core.rmem_max=2500000" >> /etc/sysctl.conf
  else
      sed -i 's/net.core.rmem_max=[0-9]*/net.core.rmem_max=2500000/' /etc/sysctl.conf
  fi
  
  if ! grep -q "net.core.wmem_max" /etc/sysctl.conf; then
      echo "net.core.wmem_max=2500000" >> /etc/sysctl.conf
  else
      sed -i 's/net.core.wmem_max=[0-9]*/net.core.wmem_max=2500000/' /etc/sysctl.conf
  fi
  
  # New values
  echo -e "${BLUE}New UDP buffer values:${RESET}"
  echo "net.core.rmem_max: $(sysctl -n net.core.rmem_max)"
  echo "net.core.wmem_max: $(sysctl -n net.core.wmem_max)"
  
  log "✓ UDP buffer sizes increased."
}

# ==== Tạo swap tự động cho nexus-node ====
create_swap() {
  local SWAP_FILE="/swapfile"
  # Lấy tổng RAM hệ thống (MB)
  local total_ram=$(free -m | awk '/^Mem:/{print $2}')
  if [ -z "$total_ram" ] || [ "$total_ram" -le 0 ]; then
      warn "Không thể xác định RAM hệ thống. Bỏ qua tạo swap."
      return
  fi

  if swapon --show | grep -q "$SWAP_FILE"; then
      local current_swap=$(free -m | awk '/^Swap:/{print $2}')
      if [ -n "$current_swap" ] && [ "$current_swap" -ge "$total_ram" ]; then
          warn "Swap đã tồn tại ($current_swap MB), bỏ qua tạo swap."
          return
      fi
      swapoff "$SWAP_FILE" 2>/dev/null || true
  fi

  local min_swap=$total_ram
  local max_swap=$((total_ram * 2))
  local available_disk=$(df -BM --output=avail "$(dirname "$SWAP_FILE")" | tail -n 1 | grep -o '[0-9]\+')
  if [ -z "$available_disk" ] || [ "$available_disk" -lt "$min_swap" ]; then
      warn "Không đủ dung lượng ổ cứng ($available_disk MB) để tạo swap tối thiểu ($min_swap MB). Bỏ qua."
      return
  fi

  local swap_size=$min_swap
  if [ "$available_disk" -ge "$max_swap" ]; then
      swap_size=$max_swap
  fi

  if [ "$swap_size" -le 0 ]; then
      warn "Kích thước swap không hợp lệ ($swap_size MB). Bỏ qua tạo swap."
      return
  fi

  log "Tạo swap $swap_size MB..."
  if ! fallocate -l "${swap_size}M" "$SWAP_FILE" 2>/dev/null; then
      dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$swap_size"
  fi
  chmod 600 "$SWAP_FILE"
  mkswap "$SWAP_FILE"
  swapon "$SWAP_FILE"
  if ! grep -q "$SWAP_FILE" /etc/fstab; then
      echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
  fi
  log "✓ Swap đã được tạo và kích hoạt ($swap_size MB)."
}

# ==== Xóa tất cả (bao gồm titan-edge, nexus-node và socks5-proxy) ====
remove_all() {
  log "⚠️ Removing all Titan Edge, Nexus Node, and SOCKS5 Proxy containers, volumes and directories..."

  # Remove titan-edge
  echo -e "${YELLOW}Stopping and removing Titan Edge containers...${RESET}"
  titan_containers=$(docker ps -a --filter "name=titan-edge" --format "{{.Names}}")
  
  if [[ -n "$titan_containers" ]]; then
      for container in $titan_containers; do
          echo -e "Removing container ${container}..."
          docker stop "$container" >/dev/null 2>&1
          docker rm -f "$container" >/dev/null 2>&1
      done
      log "✓ All Titan Edge containers removed."
  else
      warn "No Titan Edge containers found."
  fi
  
  echo -e "${YELLOW}Removing Titan Edge directories...${RESET}"
  if [[ -d "/root/titan-edge" ]]; then
      rm -rf /root/titan-edge
      log "✓ Directory /root/titan-edge removed."
  else
      warn "Directory /root/titan-edge not found."
  fi
  
  if [[ -d "/root/.titanedge" ]]; then
      rm -rf /root/.titanedge
      log "✓ Directory /root/.titanedge removed."
  fi
  
  echo -e "${YELLOW}Checking for Titan Edge related Docker volumes...${RESET}"
  titan_volumes=$(docker volume ls --filter "name=titan" --format "{{.Name}}" 2>/dev/null)
  
  if [[ -n "$titan_volumes" ]]; then
      for volume in $titan_volumes; do
          echo -e "Removing volume ${volume}..."
          docker volume rm "$volume" >/dev/null 2>&1
      done
      log "✓ All Titan Edge volumes removed."
  else
      warn "No Titan Edge volumes found."
  fi

  # Remove nexus-node
  echo -e "${YELLOW}Stopping and removing Nexus Node container...${RESET}"
  docker stop nexus-node >/dev/null 2>&1
  docker rm -f nexus-node >/dev/null 2>&1
  log "✓ Nexus Node container removed."

  if [[ -d "/root/nexus_logs" ]]; then
      rm -rf /root/nexus_logs
      log "✓ Directory /root/nexus_logs removed."
  fi

  docker rmi nexus-node:latest >/dev/null 2>&1 || true
  log "✓ Nexus Node image removed."

  # Remove socks5-proxy
  echo -e "${YELLOW}Stopping and removing SOCKS5 Proxy containers...${RESET}"
  socks_containers=$(docker ps -a --filter "name=socks5-proxy" --format "{{.Names}}")
  
  if [[ -n "$socks_containers" ]]; then
      for container in $socks_containers; do
          echo -e "Removing container ${container}..."
          docker stop "$container" >/dev/null 2>&1
          docker rm -f "$container" >/dev/null 2>&1
      done
      log "✓ All SOCKS5 Proxy containers removed."
  else
      warn "No SOCKS5 Proxy containers found."
  fi

  local WORK_DIR="/root/socks5-proxy"
  if [[ -d "$WORK_DIR" ]]; then
      rm -rf "$WORK_DIR"
      log "✓ Directory $WORK_DIR removed."
  fi

  local OUTPUT_FILE="/root/socks5proxy.txt"
  if [[ -f "$OUTPUT_FILE" ]]; then
      rm -f "$OUTPUT_FILE"
      log "✓ File $OUTPUT_FILE removed."
  fi

  # Close UFW ports for socks5
  if command -v ufw >/dev/null 2>&1; then
      for i in $(seq 0 9); do
          PORT=$((5000 + i))
          ufw delete allow $PORT/tcp >/dev/null 2>&1
      done
      log "✓ Closed SOCKS5 UFW ports (if any)."
  fi

  log "🧹 Cleanup complete! All resources have been removed."
  exit 0
}

# ==== Cài đặt titan-edge ====
install_titan_edge() {
  local hash_value="$1"
  local node_count="${2:-5}"
  local IMAGE_NAME="laodauhgc/titan-edge"
  local STORAGE_GB=50
  local START_PORT=1235
  local TOTAL_NODES=$node_count
  local TITAN_EDGE_DIR="/root/titan-edge"
  local BIND_URL="https://api-test1.container1.titannet.io/api/v2/device/binding"

  # Validate node count
  if ! [[ "$node_count" =~ ^[1-5]$ ]]; then
      warn "Invalid node count provided. Using default: 5."
      node_count=5
  fi

  # Pull the Docker image
  log "Pulling the Docker image ${IMAGE_NAME}..."
  docker pull "$IMAGE_NAME"
  if [[ $? -ne 0 ]]; then
      die "Failed to pull Docker image."
  fi

  # Create Titan Edge directory
  mkdir -p "$TITAN_EDGE_DIR"
  if [[ $? -ne 0 ]]; then
      die "Failed to create Titan Edge directory."
  fi

  # Function to check if container is ready
  check_container_ready() {
      local container_name=$1
      local max_attempts=30
      local wait_seconds=2
      
      log "Waiting for container ${container_name} to be ready..."
      
      for ((i=1; i<=max_attempts; i++)); do
          status=$(docker inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null)
          
          if [[ "$status" == "running" ]]; then
              if docker exec "$container_name" test -f /root/.titanedge/config.toml; then
                  log "✓ Container ${container_name} is ready with config.toml!"
                  return 0
              else
                  warn "Container ${container_name} is running but config.toml not found yet... Attempt $i/$max_attempts"
              fi
          elif [[ "$status" == "restarting" ]]; then
              warn "Container ${container_name} is restarting... Attempt $i/$max_attempts"
              
              if [[ $i -eq 10 ]]; then
                  error "Container is restarting. Showing logs:"
                  docker logs "$container_name"
              fi
          else
              warn "Container ${container_name} status: $status ... Attempt $i/$max_attempts"
          fi
          
          sleep $wait_seconds
      done
      
      error "Container ${container_name} failed to become ready after $((max_attempts * wait_seconds)) seconds."
      docker logs "$container_name"
      return 1
  }

  # Check existing nodes
  existing_nodes=()
  for ((i=1; i<=5; i++)); do
      container_name="titan-edge-0${i}"
      if docker ps -a --format '{{.Names}}' | grep -q "^$container_name$"; then
          container_status=$(docker inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null)
          if [[ "$container_status" == "running" ]]; then
              existing_nodes+=($i)
              log "INFO: Node ${container_name} already exists and is running."
          fi
      fi
  done

  existing_count=${#existing_nodes[@]}
  nodes_to_create=$((TOTAL_NODES - existing_count))

  if [[ $nodes_to_create -le 0 ]]; then
      log "✓ You already have $existing_count nodes running, which meets or exceeds your requested count of $TOTAL_NODES."
      log "✓ No new nodes will be created."
      return
  fi

  log "INFO: Found $existing_count existing nodes. Will create $nodes_to_create additional nodes to reach a total of $TOTAL_NODES."

  # Find next available node number
  next_node=1
  for ((next_node=1; next_node<=5; next_node++)); do
      found=0
      for existing in "${existing_nodes[@]}"; do
          if [[ "$existing" -eq "$next_node" ]]; then
              found=1
              break
          fi
      done
      if [[ "$found" -eq 0 ]]; then
          break
      fi
  done

  # Create additional nodes
  created_count=0
  while [[ $created_count -lt $nodes_to_create && $next_node -le 5 ]]; do
      STORAGE_PATH="$TITAN_EDGE_DIR/titan-edge-0${next_node}"
      CONTAINER_NAME="titan-edge-0${next_node}"
      CURRENT_PORT=$((START_PORT + next_node - 1))

      log "Setting up node ${CONTAINER_NAME} on port ${CURRENT_PORT}..."

      if docker ps -a --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
          container_status=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)
          if [[ "$container_status" != "running" ]]; then
              warn "Container ${CONTAINER_NAME} exists but is not running. Removing it..."
              docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
          else
              warn "Container ${CONTAINER_NAME} already exists and is running. Skipping..."
              next_node=$((next_node + 1))
              continue
          fi
      fi

      mkdir -p "$STORAGE_PATH/.titanedge"
      if [[ $? -ne 0 ]]; then
          die "Failed to create storage path for container ${CONTAINER_NAME}."
      fi

      log "Starting container ${CONTAINER_NAME}..."
      docker run -d \
          --name "$CONTAINER_NAME" \
          -v "$STORAGE_PATH/.titanedge:/root/.titanedge" \
          -p "$CURRENT_PORT:$CURRENT_PORT/tcp" \
          -p "$CURRENT_PORT:$CURRENT_PORT/udp" \
          --restart always \
          "$IMAGE_NAME"

      if [[ $? -ne 0 ]]; then
          die "Failed to start container ${CONTAINER_NAME}."
      fi
      
      check_container_ready "$CONTAINER_NAME"
      if [[ $? -ne 0 ]]; then
          die "Failed to confirm container ${CONTAINER_NAME} is ready."
      fi

      log "Configuring port ${CURRENT_PORT} and storage for ${CONTAINER_NAME}..."
      docker exec "$CONTAINER_NAME" bash -c "sed -i 's/^[[:space:]]*#StorageGB = .*/StorageGB = $STORAGE_GB/' /root/.titanedge/config.toml && \
                                           sed -i 's/^[[:space:]]*#ListenAddress = \"0.0.0.0:1234\"/ListenAddress = \"0.0.0.0:$CURRENT_PORT\"/' /root/.titanedge/config.toml"
      if [[ $? -ne 0 ]]; then
          die "Failed to configure port and storage for ${CONTAINER_NAME}."
      fi

      log "Restarting ${CONTAINER_NAME} to apply configuration..."
      docker restart "$CONTAINER_NAME"
      if [[ $? -ne 0 ]]; then
          die "Failed to restart ${CONTAINER_NAME}."
      fi

      sleep 10
      check_container_ready "$CONTAINER_NAME"
      if [[ $? -ne 0 ]]; then
          die "Failed to confirm container ${CONTAINER_NAME} is ready after restart."
      fi

      log "Binding ${CONTAINER_NAME} to Titan network..."
      docker exec "$CONTAINER_NAME" titan-edge bind --hash="$hash_value" "$BIND_URL"
      if [[ $? -ne 0 ]]; then
          die "Failed to bind node ${CONTAINER_NAME}."
      fi

      log "✓ Node ${CONTAINER_NAME} has been successfully initialized."
      
      created_count=$((created_count + 1))
      next_node=$((next_node + 1))
  done

  local total_active_nodes=$((existing_count + created_count))
  log "🚀 All done! You now have ${total_active_nodes} Titan Edge nodes running."

  log "To check the status of your nodes, run: docker ps -a"
  log "To view logs of a specific node, run: docker logs titan-edge-0<number>"
  log "To enter a node's shell, run: docker exec -it titan-edge-0<number> bash"
}

# ==== Cài đặt nexus-node ====
install_nexus_node() {
  local WALLET_ADDRESS="$1"
  local CONTAINER_NAME="nexus-node"
  local IMAGE_NAME="nexus-node:latest"
  local LOG_FILE="/root/nexus_logs/nexus.log"
  local max_threads=$(nproc)

  # Xây dựng Docker image
  build_image() {
      log "Bắt đầu xây dựng image $IMAGE_NAME..."
      local workdir=$(mktemp -d)
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
if [ -z "\$WALLET_ADDRESS" ]; then
    echo "Lỗi: Thiếu wallet address"
    exit 1
fi
echo "Đăng ký ví với wallet: \$WALLET_ADDRESS"
nexus-network register-user --wallet-address "\$WALLET_ADDRESS" &>> /root/nexus.log
if [ \$? -ne 0 ]; then
    echo "Lỗi: Không thể đăng ký ví. Xem log:"
    cat /root/nexus.log
    nexus-network --help &>> /root/nexus.log
    cat /root/nexus.log
    exit 1
fi
echo "Đăng ký node..."
nexus-network register-node &>> /root/nexus.log
if [ \$? -ne 0 ]; then
    echo "Lỗi: Không thể đăng ký node. Xem log:"
    cat /root/nexus.log
    nexus-network register-node --help &>> /root/nexus.log
    cat /root/nexus.log
    exit 1
fi
screen -dmS nexus bash -c "nexus-network start --max-threads $max_threads &>> /root/nexus.log"
sleep 3
if screen -list | grep -q "nexus"; then
    echo "Node đã khởi động với wallet_address=\$WALLET_ADDRESS, max_threads=$max_threads. Log: /root/nexus.log"
else
    echo "Khởi động thất bại. Xem log:"
    cat /root/nexus.log
    exit 1
fi
tail -f /root/nexus.log
EOF

      if ! docker build -t "$IMAGE_NAME" .; then
          die "Lỗi: Không thể xây dựng image $IMAGE_NAME"
      fi
      cd -
      rm -rf "$workdir"
      log "Xây dựng image $IMAGE_NAME thành công."
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
      log "Đã chạy node với wallet_address=$WALLET_ADDRESS, max_threads=$max_threads"
      log "Log: $LOG_FILE"
      log "Xem log theo thời gian thực: docker logs -f $CONTAINER_NAME"
  }

  build_image
  run_container
}

# ==== Cài đặt SOCKS5 Proxy ====
install_socks5_proxy() {
  local START_PORT="${3:-5000}"
  local WORK_DIR="/root/socks5-proxy"
  local OUTPUT_FILE="/root/socks5proxy.txt"
  local PUBLIC_IP=$(curl -s ifconfig.me)
  if [ -z "$PUBLIC_IP" ]; then
      die "Lỗi: Không thể lấy IP công cộng. Kiểm tra kết nối mạng!"
  fi

  # Tính toán số proxy dựa trên RAM
  local TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
  local PROXY_COUNT=1
  if [ "$TOTAL_RAM" -ge 2048 ]; then
    PROXY_COUNT=10
  elif [ "$TOTAL_RAM" -ge 1024 ]; then
    PROXY_COUNT=5
  elif [ "$TOTAL_RAM" -ge 512 ]; then
    PROXY_COUNT=2
  fi
  log "Tổng RAM: ${TOTAL_RAM}MB. Sẽ tạo $PROXY_COUNT proxy SOCKS5 với cổng bắt đầu từ $START_PORT."

  # Kiểm tra cổng
  for i in $(seq 0 $((PROXY_COUNT - 1))); do
    local PORT=$((START_PORT + i))
    if netstat -tuln | grep -q ":$PORT\s"; then
        die "Lỗi: Cổng $PORT đã được sử dụng!"
    fi
  done

  # Kích hoạt ufw nếu chưa và cho phép SSH
  if ! ufw status | grep -q "Status: active"; then
      log "Kích hoạt ufw và cho phép SSH..."
      ufw allow 22/tcp comment 'Allow SSH' >/dev/null 2>&1
      ufw --force enable
  else
      ufw allow 22/tcp comment 'Allow SSH' >/dev/null 2>&1
  fi

  # Tạo thư mục
  mkdir -p "$WORK_DIR"
  cd "$WORK_DIR"

  # Tạo docker-compose.yml
  cat > docker-compose.yml <<EOF
version: '3'
services:
EOF

  # Tạo dịch vụ proxy
  for i in $(seq 1 $PROXY_COUNT); do
      local PORT=$((START_PORT + i - 1))
      local USERNAME=$(openssl rand -hex 4)
      local PASSWORD=$(openssl rand -hex 4)
      echo "  socks5-proxy-$i:" >> docker-compose.yml
      echo "    image: serjs/go-socks5-proxy:latest" >> docker-compose.yml
      echo "    container_name: socks5-proxy-$i" >> docker-compose.yml
      echo "    ports:" >> docker-compose.yml
      echo "      - \"$PORT:1080\"" >> docker-compose.yml
      echo "    environment:" >> docker-compose.yml
      echo "      - SOCKS_USER=$USERNAME" >> docker-compose.yml
      echo "      - SOCKS_PASS=$PASSWORD" >> docker-compose.yml
      echo "    restart: always" >> docker-compose.yml
      echo "    cap_add:" >> docker-compose.yml
      echo "      - NET_ADMIN" >> docker-compose.yml

      # Mở cổng ufw
      ufw allow $PORT/tcp comment "SOCKS5 Proxy $i" >/dev/null 2>&1

      # Lưu info
      local PROXY_INFO="Proxy $i: socks5://$PUBLIC_IP:$PORT@$USERNAME:$PASSWORD"
      if [ $i -eq 1 ]; then
          echo -e "\nDanh sách proxy SOCKS5:\n" > "$OUTPUT_FILE"
      fi
      echo "$PROXY_INFO" >> "$OUTPUT_FILE"
  done

  # Khởi chạy
  log "Khởi chạy $PROXY_COUNT proxy SOCKS5..."
  docker-compose up -d

  # Kiểm tra
  log "Kiểm tra trạng thái container..."
  docker ps
  log "Log của socks5-proxy-1:"
  docker logs socks5-proxy-1 || warn "Không thể lấy log của socks5-proxy-1"

  log "Hoàn tất! Thông tin proxy lưu tại $OUTPUT_FILE"
  cat "$OUTPUT_FILE"
}

# ==== Main ====
check_root
detect_os

# Xử lý tham số
if [[ "$1" == "rm" || "$1" == "remove" || "$1" == "-rm" || "$1" == "--rm" ]]; then
    remove_all
fi

hash_value="${1:-}"
wallet_address="${2:-}"
node_count="${3:-5}"
socks_port="${4:-5000}"

if [[ -z "$hash_value" || -z "$wallet_address" ]]; then
    die "Usage: $0 <hash_value> <wallet_address> [node_count] [socks_start_port] \nOr: $0 rm (to remove all)"
fi

install_essential_packages
install_docker
install_docker_compose
increase_udp_buffers
create_swap
install_titan_edge "$hash_value" "$node_count"
install_nexus_node "$wallet_address"
install_socks5_proxy "$socks_port"

log "HOÀN TẤT! Tất cả các thành phần đã được cài đặt và chạy trên Ubuntu."
