#!/bin/bash

MINIO_DIR="/opt/minio"
COMPOSE_FILE="$MINIO_DIR/docker-compose.yml"
ENV_FILE="$MINIO_DIR/.env"
CERT_DIR="$MINIO_DIR/certs"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${YELLOW}Vui lòng chạy script với quyền sudo.${NC}"
  exit 1
fi

check_docker() {
  if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}Docker chưa được cài. Đang tiến hành cài đặt...${NC}"
    apt update
    apt install -y ca-certificates curl gnupg lsb-release
    mkdir -m 0755 -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  fi
}

install_minio() {
  echo -e "${GREEN}=== CÀI ĐẶT MINIO ===${NC}"
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
  echo -e "${GREEN}MinIO đã được cài đặt và khởi động.${NC}"
  echo -e "Truy cập: ${YELLOW}http://$(hostname -I | awk '{print $1}'):9091${NC}"
  echo -e "Đăng nhập: $(grep MINIO_ROOT_USER $ENV_FILE | cut -d= -f2) / $(grep MINIO_ROOT_PASSWORD $ENV_FILE | cut -d= -f2)"
}

# --- Cấu hình alias mc thông minh (HTTPS hoặc HTTP) ---
mc_connect() {
  ADMIN_USER=$(grep MINIO_ROOT_USER $ENV_FILE | cut -d= -f2)
  ADMIN_PASS=$(grep MINIO_ROOT_PASSWORD $ENV_FILE | cut -d= -f2)

  if [ -f "$CERT_DIR/public.crt" ] && [ -f "$CERT_DIR/private.key" ]; then
    docker exec minio mc alias set local https://localhost:9000 $ADMIN_USER $ADMIN_PASS --insecure > /dev/null 2>&1
  else
    docker exec minio mc alias set local http://localhost:9000 $ADMIN_USER $ADMIN_PASS > /dev/null 2>&1
  fi
}

list_users() {
  mc_connect
  docker exec minio mc admin user list local
}

add_user() {
  mc_connect
  read -p "Nhập tên user mới: " USERNAME
  read -sp "Nhập mật khẩu: " PASSWORD
  echo
  docker exec minio mc admin user add local $USERNAME $PASSWORD
  docker exec minio mc admin policy attach local readwrite --user $USERNAME
  echo -e "${GREEN}Đã thêm user $USERNAME.${NC}"
}

delete_user() {
  mc_connect
  read -p "Nhập tên user cần xóa: " USERNAME
  docker exec minio mc admin user remove local $USERNAME
  echo -e "${GREEN}Đã xóa user $USERNAME.${NC}"
}

list_buckets() {
  mc_connect
  docker exec minio mc ls local
}

create_bucket() {
  mc_connect
  read -p "Nhập tên bucket cần tạo: " BUCKET
  docker exec minio mc mb local/$BUCKET
  echo -e "${GREEN}Đã tạo bucket $BUCKET.${NC}"
}

delete_bucket() {
  mc_connect
  read -p "Nhập tên bucket cần xóa: " BUCKET
  docker exec minio mc rb --force local/$BUCKET
  echo -e "${GREEN}Đã xóa bucket $BUCKET.${NC}"
}

set_bucket_quota() {
  mc_connect
  read -p "Nhập tên bucket: " BUCKET
  read -p "Giới hạn dung lượng (VD: 50GB): " SIZE
  read -p "Ngưỡng cảnh báo (VD: 90): " WARN
  docker exec minio mc admin bucket quota set local/$BUCKET --size $SIZE --warn $WARN
  echo -e "${GREEN}Đã đặt quota $SIZE cho bucket $BUCKET.${NC}"
}

show_bucket_quota() {
  mc_connect
  read -p "Nhập tên bucket: " BUCKET
  docker exec minio mc admin bucket quota info local/$BUCKET
}

set_global_quota() {
  mc_connect
  read -p "Giới hạn dung lượng chung cho tất cả bucket (VD: 100GB): " SIZE
  read -p "Ngưỡng cảnh báo (VD: 90): " WARN
  BUCKETS=$(docker exec minio mc ls local | awk '{print $5}')
  for b in $BUCKETS; do
    docker exec minio mc admin bucket quota set local/$b --size $SIZE --warn $WARN
  done
  echo -e "${GREEN}Đã đặt quota $SIZE cho toàn bộ bucket.${NC}"
}

enable_ssl() {
  echo -e "${GREEN}=== CẤU HÌNH SSL (MINIO SERVE TLS) ===${NC}"
  read -p "Nhập domain (VD: s3.example.com): " DOMAIN

  DOMAIN_IP=$(dig +short "$DOMAIN" A | tail -n1)
  PUBLIC_IP=$(curl -4 -s ifconfig.me)
  if [ -z "$DOMAIN_IP" ] || [ "$DOMAIN_IP" != "$PUBLIC_IP" ]; then
    echo -e "${YELLOW}DNS chưa trỏ đúng. Domain IP: $DOMAIN_IP, Server IP: $PUBLIC_IP${NC}"
    return
  fi

  ufw allow 80,9090,9091/tcp >/dev/null 2>&1 || true
  ufw reload >/dev/null 2>&1 || true
  systemctl stop nginx 2>/dev/null || true
  systemctl stop apache2 2>/dev/null || true

  apt install -y certbot
  certbot certonly --standalone -d "$DOMAIN" --agree-tos -m admin@"$DOMAIN" --non-interactive
  if [ $? -ne 0 ]; then
    echo -e "${YELLOW}Không thể cấp chứng chỉ. Kiểm tra DNS hoặc port 80.${NC}"
    return
  fi

  mkdir -p "$CERT_DIR"
  cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$CERT_DIR/public.crt"
  cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem"   "$CERT_DIR/private.key"
  docker compose -f "$COMPOSE_FILE" restart

  CRON_FILE="/etc/cron.d/minio_ssl_renew"
  echo "0 0,12 * * * root certbot renew --quiet && cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem $CERT_DIR/public.crt && cp /etc/letsencrypt/live/$DOMAIN/privkey.pem $CERT_DIR/private.key && docker compose -f $COMPOSE_FILE restart > /dev/null 2>&1" > "$CRON_FILE"
  chmod 644 "$CRON_FILE"
  systemctl restart cron

  echo -e "${GREEN}Hoàn tất. Truy cập: https://$DOMAIN:9091${NC}"
}

enable_ssl_with_nginx() {
  echo -e "${GREEN}=== CẤU HÌNH SSL VỚI NGINX (REVERSE PROXY) ===${NC}"
  read -p "Nhập domain (VD: s3.example.com): " DOMAIN

  DOMAIN_IP=$(dig +short "$DOMAIN" A | tail -n1)
  PUBLIC_IP=$(curl -4 -s ifconfig.me)
  if [ -z "$DOMAIN_IP" ] || [ "$DOMAIN_IP" != "$PUBLIC_IP" ]; then
    echo -e "${YELLOW}DNS chưa trỏ đúng. Domain IP: $DOMAIN_IP, Server IP: $PUBLIC_IP${NC}"
    return
  fi

  ufw allow 80,443/tcp >/dev/null 2>&1 || true
  ufw reload >/dev/null 2>&1 || true
  apt update
  apt install -y nginx certbot python3-certbot-nginx

  cat >/etc/nginx/sites-available/minio.conf <<NGX
server {
  listen 80;
  server_name $DOMAIN;
  location /.well-known/acme-challenge/ { root /var/www/certbot; }
  location / { return 301 https://\$host\$request_uri; }
}
server {
  listen 443 ssl http2;
  server_name $DOMAIN;

  ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

  location / {
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_pass http://127.0.0.1:9091;
  }
  location /s3/ {
    rewrite ^/s3/(.*)$ /$1 break;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_pass http://127.0.0.1:9090;
  }
}
NGX

  mkdir -p /var/www/certbot
  ln -sf /etc/nginx/sites-available/minio.conf /etc/nginx/sites-enabled/minio.conf
  nginx -t && systemctl reload nginx

  certbot certonly --webroot -w /var/www/certbot -d "$DOMAIN" --agree-tos -m admin@"$DOMAIN" --non-interactive
  nginx -t && systemctl reload nginx

  echo -e "${GREEN}Hoàn tất. Truy cập: https://$DOMAIN (console) hoặc https://$DOMAIN/s3/ (API).${NC}"
}

uninstall_minio() {
  echo -e "${YELLOW}Bạn có chắc muốn gỡ MinIO (y/n)?${NC}"
  read confirm
  if [[ "$confirm" == "y" ]]; then
    docker compose -f $COMPOSE_FILE down
    rm -rf $MINIO_DIR
    rm -f /etc/cron.d/minio_ssl_renew
    echo -e "${GREEN}Đã gỡ MinIO và cấu hình liên quan.${NC}"
  fi
}

user_menu() {
  while true; do
    clear
    echo -e "${CYAN}=== QUẢN LÝ USER ===${NC}"
    echo "1. Liệt kê user"
    echo "2. Thêm user"
    echo "3. Xóa user"
    echo "0. Quay lại"
    read -rp "Chọn: " u
    case $u in
      1) list_users ;;
      2) add_user ;;
      3) delete_user ;;
      0) break ;;
      *) echo "Sai lựa chọn!" ;;
    esac
    read -rp "Nhấn Enter để tiếp tục..."
  done
}

bucket_menu() {
  while true; do
    clear
    echo -e "${CYAN}=== QUẢN LÝ BUCKET & QUOTA ===${NC}"
    echo "1. Liệt kê bucket"
    echo "2. Tạo bucket"
    echo "3. Xóa bucket"
    echo "4. Đặt quota cho bucket"
    echo "5. Xem quota bucket"
    echo "6. Đặt quota cho toàn bộ bucket"
    echo "0. Quay lại"
    read -rp "Chọn: " b
    case $b in
      1) list_buckets ;;
      2) create_bucket ;;
      3) delete_bucket ;;
      4) set_bucket_quota ;;
      5) show_bucket_quota ;;
      6) set_global_quota ;;
      0) break ;;
      *) echo "Sai lựa chọn!" ;;
    esac
    read -rp "Nhấn Enter để tiếp tục..."
  done
}

while true; do
  clear
  echo -e "${GREEN}=============================="
  echo "  MINIO S3 INSTALLER MENU"
  echo -e "==============================${NC}"
  echo "1. Cài đặt MinIO (port 9090/9091)"
  echo "2. Khởi động MinIO"
  echo "3. Dừng MinIO"
  echo "4. Xem trạng thái MinIO"
  echo "5. Cấu hình SSL (MinIO tự phục vụ)"
  echo "9. Cấu hình SSL (Nginx reverse proxy 443)"
  echo "6. Quản lý User"
  echo "7. Quản lý Bucket & Quota"
  echo "8. Gỡ cài đặt MinIO"
  echo "0. Thoát"
  echo
  read -rp "Chọn [0-9]: " c

  case "$c" in
    1) check_docker; install_minio ;;
    2) docker compose -f "$COMPOSE_FILE" up -d ;;
    3) docker compose -f "$COMPOSE_FILE" down ;;
    4) docker ps | grep minio || echo "MinIO chưa chạy." ;;
    5) enable_ssl ;;
    9) enable_ssl_with_nginx ;;
    6) user_menu ;;
    7) bucket_menu ;;
    8) uninstall_minio ;;
    0) echo -e "${YELLOW}Thoát chương trình.${NC}"; exit 0 ;;
    *) echo -e "${YELLOW}Tùy chọn không hợp lệ!${NC}" ;;
  esac

  echo
  read -rp "Nhấn Enter để quay lại menu..."
done
