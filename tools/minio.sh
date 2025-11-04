#!/bin/bash
# MinIO Installer & Manager - Fixed Full Version (2025-11)
# Includes auto DNS check, dual-domain SSL, and webroot verification

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
  echo -e "${RED}❌ Vui lòng chạy script với quyền sudo.${NC}"
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
    echo -e "${GREEN}✅ Docker đã được cài đặt.${NC}"
  fi
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

  echo -e "${GREEN}✅ MinIO đã được khởi động.${NC}"
  echo -e "👉 Truy cập web: ${CYAN}http://$IP:9091${NC}"
  echo -e "Đăng nhập: ${YELLOW}$USER${NC} / ${YELLOW}$PASS${NC}"
}

mc_connect() {
  ADMIN_USER=$(grep MINIO_ROOT_USER $ENV_FILE | cut -d= -f2)
  ADMIN_PASS=$(grep MINIO_ROOT_PASSWORD $ENV_FILE | cut -d= -f2)
  if [ -f "$CERT_DIR/public.crt" ]; then
    docker exec minio mc alias set local https://localhost:9000 $ADMIN_USER $ADMIN_PASS --insecure >/dev/null 2>&1
  else
    docker exec minio mc alias set local http://localhost:9000 $ADMIN_USER $ADMIN_PASS >/dev/null 2>&1
  fi
}

enable_ssl_nginx() {
  show_header
  echo -e "${CYAN}[SSL] Reverse Proxy qua Nginx + Let’s Encrypt${NC}"
  read -p "Nhập domain (VD: s3.example.com): " DOMAIN

  echo -e "${YELLOW}→ Kiểm tra DNS cho $DOMAIN và api.$DOMAIN...${NC}"
  DOMAIN_IP=$(dig +short "$DOMAIN" A | tail -n1)
  API_IP=$(dig +short "api.$DOMAIN" A | tail -n1)
  SERVER_IP=$(curl -s4 ifconfig.me)
  echo -e "Server IP: ${CYAN}$SERVER_IP${NC}"

  if [ "$DOMAIN_IP" != "$SERVER_IP" ]; then
    echo -e "${RED}❌ Domain $DOMAIN chưa trỏ về IP server.${NC}"
    return
  fi
  if [ "$API_IP" != "$SERVER_IP" ]; then
    echo -e "${RED}❌ Subdomain api.$DOMAIN chưa trỏ về IP server.${NC}"
    return
  fi

  ufw allow 80,443/tcp >/dev/null 2>&1
  apt install -y nginx certbot python3-certbot-nginx

  mkdir -p /var/www/certbot

  # --- HTTP block cho s3 và api ---
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

# --- HTTPS Console ---
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

# --- HTTPS API ---
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

  ln -sf /etc/nginx/sites-available/minio.conf /etc/nginx/sites-enabled/minio.conf
  nginx -t && systemctl reload nginx

  echo -e "${YELLOW}→ Đang cấp chứng chỉ Let’s Encrypt...${NC}"
  certbot certonly --webroot -w /var/www/certbot -d "$DOMAIN" -d "api.$DOMAIN" --expand --agree-tos -m admin@"$DOMAIN" --non-interactive
  nginx -t && systemctl reload nginx

  echo -e "${GREEN}✅ SSL đã cấu hình hoàn chỉnh.${NC}"
  echo -e "🔹 Web Console: ${CYAN}https://$DOMAIN${NC}"
  echo -e "🔹 API cho Cyberduck: ${CYAN}https://api.$DOMAIN${NC}"
}

uninstall_minio() {
  read -p "Bạn có chắc muốn gỡ MinIO (y/n)? " c
  if [[ "$c" == "y" ]]; then
    docker compose -f $COMPOSE_FILE down
    rm -rf $MINIO_DIR
    rm -f /etc/nginx/sites-enabled/minio.conf /etc/nginx/sites-available/minio.conf
    echo -e "${GREEN}✅ MinIO và cấu hình Nginx đã được gỡ bỏ.${NC}"
  fi
}

# === MENU CHÍNH ===
while true; do
  show_header
  echo "1. Cài đặt MinIO (port 9090/9091)"
  echo "2. Cấu hình SSL (Reverse Proxy qua Nginx)"
  echo "3. Gỡ cài đặt MinIO"
  echo "0. Thoát"
  echo
  read -p "Chọn [0-3]: " c
  case "$c" in
    1) check_docker; install_minio ;;
    2) enable_ssl_nginx ;;
    3) uninstall_minio ;;
    0) echo "Thoát."; exit 0 ;;
    *) echo "Tùy chọn không hợp lệ!";;
  esac
  read -p "Nhấn Enter để quay lại menu..."
done
