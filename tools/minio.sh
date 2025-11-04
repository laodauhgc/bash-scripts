#!/bin/bash
# MinIO S3 Installer & Manager - Full Production Edition
# Ubuntu 22.04+ | Docker + Nginx + Let's Encrypt
# Last update: 2025-11

MINIO_DIR="/opt/minio"
COMPOSE_FILE="$MINIO_DIR/docker-compose.yml"
ENV_FILE="$MINIO_DIR/.env"
CERT_DIR="$MINIO_DIR/certs"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}❌ Script cần chạy với quyền sudo.${NC}"
  exit 1
fi

show_header() {
  clear
  echo -e "${CYAN}============================================="
  echo -e "   Trình cài đặt & quản lý MinIO S3 - Ubuntu"
  echo -e "=============================================${NC}"
}

check_docker() {
  if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}Cài đặt Docker...${NC}"
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
  fi
  echo -e "${GREEN}✅ Docker sẵn sàng.${NC}"
}

install_minio() {
  show_header
  echo -e "${CYAN}[CÀI ĐẶT] Khởi tạo MinIO...${NC}"
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

  docker compose -f $COMPOSE_FILE up -d
  IP=$(hostname -I | awk '{print $1}')
  USER=$(grep MINIO_ROOT_USER $ENV_FILE | cut -d= -f2)
  PASS=$(grep MINIO_ROOT_PASSWORD $ENV_FILE | cut -d= -f2)

  echo -e "${GREEN}✅ MinIO đã chạy.${NC}"
  echo -e "👉 Truy cập: ${CYAN}http://$IP:9091${NC}"
  echo -e "Tài khoản: ${YELLOW}$USER${NC}"
  echo -e "Mật khẩu: ${YELLOW}$PASS${NC}"
}

mc_connect() {
  ADMIN_USER=$(grep MINIO_ROOT_USER $ENV_FILE | cut -d= -f2)
  ADMIN_PASS=$(grep MINIO_ROOT_PASSWORD $ENV_FILE | cut -d= -f2)
  docker exec minio mc alias set local http://localhost:9000 $ADMIN_USER $ADMIN_PASS >/dev/null 2>&1
}

# --- USER ---
list_users() { mc_connect; docker exec minio mc admin user list local; }
add_user() {
  mc_connect; read -p "Tên user: " U; read -sp "Mật khẩu: " P; echo
  docker exec minio mc admin user add local $U $P
  docker exec minio mc admin policy attach local readwrite --user $U
}
delete_user() {
  mc_connect; read -p "User cần xóa: " U
  docker exec minio mc admin user remove local $U
}

# --- BUCKET ---
list_buckets() { mc_connect; docker exec minio mc ls local; }
create_bucket() { mc_connect; read -p "Tên bucket: " B; docker exec minio mc mb local/$B; }
delete_bucket() { mc_connect; read -p "Bucket cần xóa: " B; docker exec minio mc rb --force local/$B; }
set_bucket_quota() {
  mc_connect
  read -p "Bucket: " B; read -p "Giới hạn (VD: 50GB): " S; read -p "Cảnh báo (%): " W
  docker exec minio mc admin bucket quota set local/$B --size $S --warn $W
}
show_bucket_quota() { mc_connect; read -p "Bucket: " B; docker exec minio mc admin bucket quota info local/$B; }

# --- SSL / NGINX ---
enable_ssl_nginx() {
  show_header
  echo -e "${CYAN}[SSL] Reverse Proxy + Let's Encrypt${NC}"
  read -p "Nhập domain (VD: s3.example.com): " DOMAIN

  DOMAIN_IP=$(dig +short "$DOMAIN" A | tail -n1)
  API_IP=$(dig +short "api.$DOMAIN" A | tail -n1)
  SERVER_IP=$(curl -s4 ifconfig.me)
  echo -e "Server IP: ${CYAN}$SERVER_IP${NC}"

  if [ "$DOMAIN_IP" != "$SERVER_IP" ]; then
    echo -e "${RED}❌ Domain $DOMAIN chưa trỏ đúng IP.${NC}"
    return
  fi
  if [ "$API_IP" != "$SERVER_IP" ]; then
    echo -e "${RED}❌ Subdomain api.$DOMAIN chưa trỏ đúng IP.${NC}"
    return
  fi

  ufw allow 80,443/tcp >/dev/null 2>&1
  apt install -y nginx certbot python3-certbot-nginx
  mkdir -p /var/www/certbot

  # Ghi cấu hình Nginx
  cat >/etc/nginx/sites-available/minio.conf <<NGX
server {
  listen 80;
  server_name $DOMAIN;
  location /.well-known/acme-challenge/ { root /var/www/certbot; }
  location / { return 301 https://\$host\$request_uri; }
}
server {
  listen 80;
  server_name api.$DOMAIN;
  location /.well-known/acme-challenge/ { root /var/www/certbot; }
  location / { return 301 https://\$host\$request_uri; }
}

# HTTPS Console
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

# HTTPS API
server {
  listen 443 ssl http2;
  server_name api.$DOMAIN;
  ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

  location / {
    proxy_pass http://127.0.0.1:9090;
    proxy_set_header Host $DOMAIN;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  }
}
NGX

  ln -sf /etc/nginx/sites-available/minio.conf /etc/nginx/sites-enabled/minio.conf
  nginx -t && systemctl reload nginx

  echo -e "${YELLOW}→ Cấp chứng chỉ Let's Encrypt...${NC}"
  certbot certonly --webroot -w /var/www/certbot -d "$DOMAIN" -d "api.$DOMAIN" --expand --agree-tos -m admin@"$DOMAIN" --non-interactive
  nginx -t && systemctl reload nginx

  echo -e "${GREEN}✅ SSL hoàn tất.${NC}"
  echo -e "🔹 Web Console: ${CYAN}https://$DOMAIN${NC}"
  echo -e "🔹 API / Cyberduck: ${CYAN}https://api.$DOMAIN${NC}"

  # Cập nhật ENV để fix redirect
  echo "MINIO_SERVER_URL=https://api.$DOMAIN" >> $ENV_FILE
  echo "MINIO_BROWSER_REDIRECT_URL=https://$DOMAIN" >> $ENV_FILE
  docker compose -f $COMPOSE_FILE restart
}

uninstall_minio() {
  read -p "Xác nhận gỡ MinIO (y/n)? " c
  [[ "$c" != "y" ]] && return
  docker compose -f $COMPOSE_FILE down
  rm -rf $MINIO_DIR
  rm -f /etc/nginx/sites-available/minio.conf /etc/nginx/sites-enabled/minio.conf
  echo -e "${GREEN}✅ Đã gỡ bỏ MinIO & cấu hình Nginx.${NC}"
}

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
    read -p "Nhấn Enter..."
  done
}

bucket_menu() {
  while true; do
    clear
    echo -e "${CYAN}--- QUẢN LÝ BUCKET & QUOTA ---${NC}"
    echo "1. Liệt kê bucket"
    echo "2. Tạo bucket"
    echo "3. Xóa bucket"
    echo "4. Đặt quota"
    echo "5. Xem quota"
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
    read -p "Nhấn Enter..."
  done
}

while true; do
  show_header
  echo "1. Cài đặt MinIO (port 9090/9091)"
  echo "2. Cấu hình SSL (Nginx + domain)"
  echo "3. Quản lý User"
  echo "4. Quản lý Bucket & Quota"
  echo "5. Gỡ cài đặt"
  echo "0. Thoát"
  read -p "Chọn [0-5]: " c
  case "$c" in
    1) check_docker; install_minio ;;
    2) enable_ssl_nginx ;;
    3) user_menu ;;
    4) bucket_menu ;;
    5) uninstall_minio ;;
    0) exit 0 ;;
    *) echo "Tùy chọn không hợp lệ!" ;;
  esac
  read -p "Nhấn Enter để quay lại menu..."
done
