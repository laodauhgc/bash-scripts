#!/bin/bash
# MinIO Installer & Manager with Guided Logs
# Works on Ubuntu 22.04+ with Docker & Docker Compose

# === ĐỊNH NGHĨA BIẾN ===
MINIO_DIR="/opt/minio"
COMPOSE_FILE="$MINIO_DIR/docker-compose.yml"
ENV_FILE="$MINIO_DIR/.env"
CERT_DIR="$MINIO_DIR/certs"

# === MÀU SẮC ===
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# === KIỂM TRA QUYỀN ROOT ===
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[LỖI]${NC} Script cần chạy với quyền sudo hoặc root."
  exit 1
fi

# === HÀM HIỂN THỊ TIÊU ĐỀ ===
show_header() {
  clear
  echo -e "${CYAN}============================================="
  echo -e "   Trình cài đặt & quản lý MinIO S3 - Ubuntu"
  echo -e "=============================================${NC}"
}

# === CÀI ĐẶT DOCKER (NẾU CHƯA CÓ) ===
check_docker() {
  if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}Docker chưa được cài. Đang tiến hành cài đặt...${NC}"
    apt update -y
    apt install -y ca-certificates curl gnupg lsb-release
    mkdir -m 0755 -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt update -y
    apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    echo -e "${GREEN}✅ Docker đã được cài đặt thành công.${NC}"
  else
    echo -e "${GREEN}✅ Docker đã có sẵn.${NC}"
  fi
}

# === CÀI ĐẶT MINIO ===
install_minio() {
  show_header
  echo -e "${CYAN}[BẮT ĐẦU] Cài đặt MinIO...${NC}"
  mkdir -p $MINIO_DIR/{data,config,certs}
  chown -R $SUDO_USER:$SUDO_USER $MINIO_DIR

  if [ ! -f "$ENV_FILE" ]; then
    echo "MINIO_ROOT_USER=admin" > $ENV_FILE
    echo "MINIO_ROOT_PASSWORD=$(openssl rand -hex 12)" >> $ENV_FILE
  fi

  cat > $COMPOSE_FILE <<EOF
version: '3.8'
services:
  minio:
    image: quay.io/minio/minio:latest
    container_name: minio
    restart: always
    ports:
      - "9090:9000"
      - "9091:9001"
    env_file:
      - .env
    volumes:
      - ./data:/data
      - ./config:/root/.minio
      - ./certs:/root/.minio/certs
    command: server /data --console-address ":9001"
EOF

  echo -e "${YELLOW}Đang khởi động container MinIO...${NC}"
  docker compose -f $COMPOSE_FILE up -d

  IP=$(hostname -I | awk '{print $1}')
  USER=$(grep MINIO_ROOT_USER $ENV_FILE | cut -d= -f2)
  PASS=$(grep MINIO_ROOT_PASSWORD $ENV_FILE | cut -d= -f2)

  echo -e "${GREEN}✅ Cài đặt MinIO thành công!${NC}"
  echo -e "Truy cập trình duyệt tại: ${CYAN}http://$IP:9091${NC}"
  echo -e "Tên đăng nhập: ${YELLOW}$USER${NC}"
  echo -e "Mật khẩu: ${YELLOW}$PASS${NC}"
  echo -e "${CYAN}Bạn có thể bật SSL sau bằng menu (tùy chọn 5 hoặc 9).${NC}"
}

# === HÀM KẾT NỐI MINIO CLIENT ===
mc_connect() {
  ADMIN_USER=$(grep MINIO_ROOT_USER $ENV_FILE | cut -d= -f2)
  ADMIN_PASS=$(grep MINIO_ROOT_PASSWORD $ENV_FILE | cut -d= -f2)

  if [ -f "$CERT_DIR/public.crt" ] && [ -f "$CERT_DIR/private.key" ]; then
    docker exec minio mc alias set local https://localhost:9000 $ADMIN_USER $ADMIN_PASS --insecure > /dev/null 2>&1
  else
    docker exec minio mc alias set local http://localhost:9000 $ADMIN_USER $ADMIN_PASS > /dev/null 2>&1
  fi
}

# === QUẢN LÝ USER ===
list_users() { mc_connect; docker exec minio mc admin user list local; }
add_user() {
  mc_connect
  read -p "Nhập tên user: " U; read -sp "Mật khẩu: " P; echo
  docker exec minio mc admin user add local $U $P
  docker exec minio mc admin policy attach local readwrite --user $U
  echo -e "${GREEN}✅ Đã thêm user $U${NC}"
}
delete_user() {
  mc_connect
  read -p "Nhập user cần xóa: " U
  docker exec minio mc admin user remove local $U
  echo -e "${GREEN}✅ Đã xóa user $U${NC}"
}

# === QUẢN LÝ BUCKET ===
list_buckets() { mc_connect; docker exec minio mc ls local; }
create_bucket() { mc_connect; read -p "Tên bucket: " B; docker exec minio mc mb local/$B; }
delete_bucket() { mc_connect; read -p "Bucket cần xóa: " B; docker exec minio mc rb --force local/$B; }
set_bucket_quota() {
  mc_connect
  read -p "Bucket: " B; read -p "Giới hạn (VD: 50GB): " S; read -p "Cảnh báo (%): " W
  docker exec minio mc admin bucket quota set local/$B --size $S --warn $W
}
show_bucket_quota() { mc_connect; read -p "Bucket: " B; docker exec minio mc admin bucket quota info local/$B; }

# === SSL: MINIO TỰ PHỤC VỤ ===
enable_ssl() {
  show_header
  echo -e "${CYAN}[SSL] Cấu hình Let's Encrypt trực tiếp cho MinIO${NC}"
  read -p "Nhập domain (VD: s3.example.com): " DOMAIN

  DOMAIN_IP=$(dig +short "$DOMAIN" A | tail -n1)
  SERVER_IP=$(curl -s4 ifconfig.me)
  if [ "$DOMAIN_IP" != "$SERVER_IP" ]; then
    echo -e "${RED}[CẢNH BÁO]${NC} DNS domain chưa trỏ về IP server!"
    echo "Domain IP: $DOMAIN_IP / Server IP: $SERVER_IP"
    return
  fi

  ufw allow 80,9090,9091/tcp >/dev/null 2>&1
  apt install -y certbot

  systemctl stop nginx 2>/dev/null || true
  certbot certonly --standalone -d "$DOMAIN" --agree-tos -m admin@"$DOMAIN" --non-interactive

  mkdir -p "$CERT_DIR"
  cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem "$CERT_DIR/public.crt"
  cp /etc/letsencrypt/live/$DOMAIN/privkey.pem "$CERT_DIR/private.key"

  docker compose -f "$COMPOSE_FILE" restart
  echo -e "${GREEN}✅ SSL đã bật. Truy cập: https://$DOMAIN:9091${NC}"

  echo "0 0,12 * * * root certbot renew --quiet && cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem $CERT_DIR/public.crt && cp /etc/letsencrypt/live/$DOMAIN/privkey.pem $CERT_DIR/private.key && docker compose -f $COMPOSE_FILE restart > /dev/null 2>&1" > /etc/cron.d/minio_ssl_renew
}

# === SSL: NGINX REVERSE PROXY ===
enable_ssl_nginx() {
  show_header
  echo -e "${CYAN}[SSL] Reverse Proxy qua Nginx (HTTPS port 443)${NC}"
  read -p "Nhập domain (VD: s3.example.com): " DOMAIN

  ufw allow 80,443/tcp >/dev/null 2>&1
  apt install -y nginx certbot python3-certbot-nginx

  cat >/etc/nginx/sites-available/minio.conf <<NGX
server {
  listen 80;
  server_name $DOMAIN;
  location /.well-known/acme-challenge/ { root /var/www/certbot; }
  location / { return 301 https://\$host\$request_uri; }
}

# Console
server {
  listen 443 ssl http2;
  server_name $DOMAIN;
  ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

  location / {
    proxy_pass http://127.0.0.1:9091;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  }
}

# API cho Cyberduck / AWS CLI
server {
  listen 443 ssl http2;
  server_name api.$DOMAIN;
  ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

  location / {
    proxy_pass http://127.0.0.1:9090;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  }
}
NGX

  mkdir -p /var/www/certbot
  ln -sf /etc/nginx/sites-available/minio.conf /etc/nginx/sites-enabled/
  nginx -t && systemctl reload nginx
  certbot certonly --webroot -w /var/www/certbot -d "$DOMAIN" -d "api.$DOMAIN" --expand --agree-tos -m admin@"$DOMAIN" --non-interactive
  nginx -t && systemctl reload nginx
  echo -e "${GREEN}✅ SSL đã cấu hình. Truy cập:${NC}"
  echo -e "  - Web Console: ${CYAN}https://$DOMAIN${NC}"
  echo -e "  - API cho Cyberduck: ${CYAN}https://api.$DOMAIN${NC}"
}

# === GỠ CÀI ĐẶT MINIO ===
uninstall_minio() {
  read -p "Bạn có chắc muốn gỡ MinIO? (y/n): " c
  if [[ "$c" == "y" ]]; then
    docker compose -f $COMPOSE_FILE down
    rm -rf $MINIO_DIR
    echo -e "${GREEN}✅ Đã gỡ bỏ MinIO.${NC}"
  fi
}

# === MENU PHỤ ===
user_menu() {
  while true; do
    clear
    echo -e "${CYAN}--- QUẢN LÝ USER ---${NC}"
    echo "1. Liệt kê user"
    echo "2. Thêm user"
    echo "3. Xóa user"
    echo "0. Quay lại"
    read -p "Chọn: " x
    case $x in
      1) list_users ;;
      2) add_user ;;
      3) delete_user ;;
      0) break ;;
      *) echo "Sai lựa chọn!" ;;
    esac
    read -p "Nhấn Enter để tiếp tục..."
  done
}

bucket_menu() {
  while true; do
    clear
    echo -e "${CYAN}--- QUẢN LÝ BUCKET & QUOTA ---${NC}"
    echo "1. Liệt kê bucket"
    echo "2. Tạo bucket"
    echo "3. Xóa bucket"
    echo "4. Đặt quota cho bucket"
    echo "5. Xem quota bucket"
    echo "0. Quay lại"
    read -p "Chọn: " b
    case $b in
      1) list_buckets ;;
      2) create_bucket ;;
      3) delete_bucket ;;
      4) set_bucket_quota ;;
      5) show_bucket_quota ;;
      0) break ;;
    esac
    read -p "Nhấn Enter để tiếp tục..."
  done
}

# === MENU CHÍNH ===
while true; do
  show_header
  echo "1. Cài đặt MinIO (port 9090/9091)"
  echo "2. Khởi động MinIO"
  echo "3. Dừng MinIO"
  echo "4. Kiểm tra trạng thái"
  echo "5. Cấu hình SSL (MinIO trực tiếp)"
  echo "9. Cấu hình SSL (Nginx reverse proxy + domain API)"
  echo "6. Quản lý User"
  echo "7. Quản lý Bucket & Quota"
  echo "8. Gỡ cài đặt MinIO"
  echo "0. Thoát"
  echo
  read -p "Chọn [0-9]: " c
  case "$c" in
    1) check_docker; install_minio ;;
    2) docker compose -f "$COMPOSE_FILE" up -d ;;
    3) docker compose -f "$COMPOSE_FILE" down ;;
    4) docker ps | grep minio || echo "MinIO chưa chạy." ;;
    5) enable_ssl ;;
    9) enable_ssl_nginx ;;
    6) user_menu ;;
    7) bucket_menu ;;
    8) uninstall_minio ;;
    0) echo "Thoát."; exit 0 ;;
    *) echo "Tùy chọn không hợp lệ!" ;;
  esac
  read -p "Nhấn Enter để quay lại menu..."
done
