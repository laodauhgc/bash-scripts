#!/bin/bash
# ===============================================
#  MinIO S3 Installer & Manager 
#  Author: 
#  Version: 3.0 - Advanced Admin Menu (Bucket & User Management + Quota Control)
# ===============================================

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

# --- Kiểm tra Docker ---
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

# --- Cài đặt MinIO ---
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
  echo -e "${GREEN}✅ MinIO đã được cài đặt và khởi động.${NC}"
  echo -e "👉 Truy cập giao diện: ${YELLOW}http://$(hostname -I | awk '{print $1}'):9091${NC}"
  echo -e "🔑 Đăng nhập: $(grep MINIO_ROOT_USER $ENV_FILE | cut -d= -f2) / $(grep MINIO_ROOT_PASSWORD $ENV_FILE | cut -d= -f2)"
}

# --- Kết nối MinIO client ---
mc_connect() {
  ADMIN_USER=$(grep MINIO_ROOT_USER $ENV_FILE | cut -d= -f2)
  ADMIN_PASS=$(grep MINIO_ROOT_PASSWORD $ENV_FILE | cut -d= -f2)
  docker exec minio mc alias set local http://localhost:9000 $ADMIN_USER $ADMIN_PASS > /dev/null 2>&1
}

# --- Quản lý user ---
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
  echo -e "${GREEN}✅ Đã thêm user $USERNAME với quyền readwrite.${NC}"
}

delete_user() {
  mc_connect
  read -p "Nhập tên user cần xóa: " USERNAME
  docker exec minio mc admin user remove local $USERNAME
  echo -e "${GREEN}🗑️  Đã xóa user $USERNAME.${NC}"
}

# --- Quản lý bucket ---
list_buckets() {
  mc_connect
  docker exec minio mc ls local
}

create_bucket() {
  mc_connect
  read -p "Nhập tên bucket cần tạo: " BUCKET
  docker exec minio mc mb local/$BUCKET
  echo -e "${GREEN}✅ Đã tạo bucket $BUCKET.${NC}"
}

delete_bucket() {
  mc_connect
  read -p "Nhập tên bucket cần xóa: " BUCKET
  docker exec minio mc rb --force local/$BUCKET
  echo -e "${GREEN}🗑️  Đã xóa bucket $BUCKET.${NC}"
}

# --- Quản lý quota ---
set_bucket_quota() {
  mc_connect
  read -p "Nhập tên bucket: " BUCKET
  read -p "Nhập giới hạn dung lượng (VD: 50GB): " SIZE
  read -p "Ngưỡng cảnh báo (VD: 90): " WARN
  docker exec minio mc admin bucket quota set local/$BUCKET --size $SIZE --warn $WARN
  echo -e "${GREEN}✅ Đã đặt quota $SIZE cho bucket $BUCKET.${NC}"
}

show_bucket_quota() {
  mc_connect
  read -p "Nhập tên bucket: " BUCKET
  docker exec minio mc admin bucket quota info local/$BUCKET
}

set_global_quota() {
  mc_connect
  read -p "Nhập giới hạn dung lượng chung cho tất cả bucket (VD: 100GB): " SIZE
  read -p "Ngưỡng cảnh báo (VD: 90): " WARN
  BUCKETS=$(docker exec minio mc ls local | awk '{print $5}')
  for b in $BUCKETS; do
    docker exec minio mc admin bucket quota set local/$b --size $SIZE --warn $WARN
  done
  echo -e "${GREEN}✅ Đã đặt quota $SIZE cho toàn bộ bucket.${NC}"
}

# --- Quản lý SSL ---
enable_ssl() {
  echo -e "${GREEN}=== CẤU HÌNH SSL CHO MINIO ===${NC}"
  read -p "Nhập tên miền (VD: s3.example.com): " DOMAIN
  apt install -y certbot
  certbot certonly --standalone -d $DOMAIN --agree-tos -m admin@$DOMAIN --non-interactive
  if [ $? -eq 0 ]; then
    mkdir -p $CERT_DIR
    cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem $CERT_DIR/public.crt
    cp /etc/letsencrypt/live/$DOMAIN/privkey.pem $CERT_DIR/private.key
    docker compose -f $COMPOSE_FILE restart
    CRON_FILE="/etc/cron.d/minio_ssl_renew"
    echo "0 0,12 * * * root certbot renew --quiet && cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem $CERT_DIR/public.crt && cp /etc/letsencrypt/live/$DOMAIN/privkey.pem $CERT_DIR/private.key && docker compose -f $COMPOSE_FILE restart > /dev/null 2>&1" > $CRON_FILE
    chmod 644 $CRON_FILE
    systemctl restart cron
    echo -e "${GREEN}✅ SSL đã được cấu hình và thiết lập tự động gia hạn.${NC}"
  else
    echo -e "${YELLOW}⚠️ Không thể lấy chứng chỉ SSL.${NC}"
  fi
}

# --- Gỡ MinIO ---
uninstall_minio() {
  echo -e "${YELLOW}Bạn có chắc muốn gỡ MinIO (y/n)?${NC}"
  read confirm
  if [[ "$confirm" == "y" ]]; then
    docker compose -f $COMPOSE_FILE down
    rm -rf $MINIO_DIR
    rm -f /etc/cron.d/minio_ssl_renew
    echo -e "${GREEN}✅ Đã gỡ cài đặt MinIO và dọn cấu hình.${NC}"
  fi
}

# --- Menu con: User & Bucket ---
user_menu() {
  while true; do
    clear
    echo -e "${CYAN}=== QUẢN LÝ USER MINIO ===${NC}"
    echo "1. Liệt kê user"
    echo "2. Thêm user"
    echo "3. Xóa user"
    echo "0. Quay lại"
    read -p "Chọn: " u
    case $u in
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
    echo -e "${CYAN}=== QUẢN LÝ BUCKET & QUOTA ===${NC}"
    echo "1. Liệt kê bucket"
    echo "2. Tạo bucket"
    echo "3. Xóa bucket"
    echo "4. Đặt quota cho bucket"
    echo "5. Xem quota bucket"
    echo "6. Đặt quota cho toàn bộ bucket"
    echo "0. Quay lại"
    read -p "Chọn: " b
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
    read -p "Nhấn Enter để tiếp tục..."
  done
}

# --- Menu chính ---
while true; do
  clear
  echo -e "${GREEN}=============================="
  echo "  MINIO S3 INSTALLER MENU"
  echo -e "==============================${NC}"
  echo "1. Cài đặt MinIO (port 9090/9091)"
  echo "2. Khởi động MinIO"
  echo "3. Dừng MinIO"
  echo "4. Xem trạng thái MinIO"
  echo "5. Cấu hình SSL (Let's Encrypt)"
  echo "6. Quản lý User"
  echo "7. Quản lý Bucket & Quota"
  echo "8. Gỡ cài đặt MinIO"
  echo "0. Thoát"
  read -p "Chọn [0-8]: " c
  case $c in
    1) check_docker; install_minio ;;
    2) docker compose -f $COMPOSE_FILE up -d ;;
    3) docker compose -f $COMPOSE_FILE down ;;
    4) docker ps | grep minio ;;
    5) enable_ssl ;;
    6) user_menu ;;
    7) bucket_menu ;;
    8) uninstall_minio ;;
    0) exit 0 ;;
    *) echo "Tùy chọn không hợp lệ!" ;;
  esac
  read -p "Nhấn Enter để quay lại menu..."
done
