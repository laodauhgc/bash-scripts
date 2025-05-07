#!/bin/bash

# Hàm tạo mật khẩu ngẫu nhiên
generate_password() {
  tr -dc A-Za-z0-9 </dev/urandom | head -c 12
}

# Hàm kiểm tra và yêu cầu email nếu LETSENCRYPT_EMAIL không tồn tại
prompt_email() {
  if [ -z "$LETSENCRYPT_EMAIL" ]; then
    read -p "Nhập email cho Let's Encrypt: " LETSENCRYPT_EMAIL
    if [ -z "$LETSENCRYPT_EMAIL" ]; then
      echo "Lỗi: Email không được để trống."
      exit 1
    fi
  fi
}

# Hàm kiểm tra DNS cho subdomain
check_dns() {
  local subdomain=$1
  local base_domain=$2
  if ! nslookup "$subdomain.$base_domain" 8.8.8.8 >/dev/null 2>&1; then
    echo "Lỗi: Không thể giải quyết DNS cho $subdomain.$base_domain. Vui lòng kiểm tra cấu hình DNS và đợi truyền bá."
    exit 1
  fi
}

# Hàm kiểm tra cổng có thể truy cập từ bên ngoài
check_port_access() {
  local port=$1
  if command -v nc >/dev/null 2>&1; then
    if ! nc -zv 127.0.0.1 $port >/dev/null 2>&1; then
      echo "Cảnh báo: Cổng $port không thể truy cập. Certbot có thể thất bại nếu cổng không mở từ bên ngoài."
    fi
  fi
}

# Hàm đọc mật khẩu PostgreSQL từ file credentials
get_postgres_password() {
  local subdomain_dir=$1
  local creds_file="$subdomain_dir/postgres-credentials.txt"
  if [ -f "$creds_file" ]; then
    grep POSTGRES_PASSWORD "$creds_file" | cut -d '=' -f 2
  else
    generate_password
  fi
}

# Kiểm tra lệnh docker compose
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  echo "Lỗi: Yêu cầu Docker và Docker Compose V2. Cài đặt bằng: sudo apt update && sudo apt install -y docker.io docker-compose-plugin"
  exit 1
fi

# Kiểm tra và cài đặt nginx nếu chưa có
if ! command -v nginx >/dev/null 2>&1; then
  echo "Cài đặt Nginx..."
  apt update
  apt install -y nginx
  if [ $? -ne 0 ]; then
    echo "Lỗi: Không thể cài đặt Nginx. Vui lòng kiểm tra kết nối mạng hoặc cài đặt thủ công."
    exit 1
  fi
fi

# Kiểm tra và cài đặt certbot nếu chưa có
if ! command -v certbot >/dev/null 2>&1; then
  echo "Cài đặt Certbot..."
  apt update
  apt install -y certbot python3-certbot-nginx
  if [ $? -ne 0 ]; then
    echo "Lỗi: Không thể cài đặt Certbot. Vui lòng kiểm tra kết nối mạng hoặc cài đặt thủ công."
    exit 1
  fi
fi

# Kiểm tra netcat (nc) để kiểm tra cổng
if ! command -v nc >/dev/null 2>&1; then
  echo "Cài đặt netcat để kiểm tra cổng..."
  apt update
  apt install -y netcat-openbsd
  if [ $? -ne 0 ]; then
    echo "Cảnh báo: Không thể cài đặt netcat. Script sẽ tiếp tục nhưng không thể kiểm tra cổng."
  fi
fi

# Xác định kiến trúc và chọn hình ảnh n8n phù hợp
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
  N8N_IMAGE="n8nio/n8n:latest"
elif [ "$ARCH" = "aarch64" ]; then
  N8N_IMAGE="n8nio/n8n:latest-rpi"
else
  echo "Lỗi: Kiến trúc không được hỗ trợ: $ARCH"
  exit 1
fi

# Xử lý đối số dòng lệnh
BASE_DOMAIN="n8n.works"  # Mặc định base domain
LETSENCRYPT_EMAIL=""    # Email Let's Encrypt mặc định là rỗng
INCLUDE_REDIS=true      # Đặt thành false nếu không muốn sử dụng Redis
REINIT=false            # Tùy chọn khởi tạo lại
LIST=false              # Tùy chọn liệt kê instance
UPDATE_ALL=false        # Tùy chọn cập nhật tất cả instance

while getopts "d:e:rlu" opt; do
  case $opt in
    d) BASE_DOMAIN="$OPTARG" ;;
    e) LETSENCRYPT_EMAIL="$OPTARG" ;;
    r) REINIT=true ;;
    l) LIST=true ;;
    u) UPDATE_ALL=true ;;
    \?) echo "Tùy chọn không hợp lệ: -$OPTARG" >&2; exit 1 ;;
  esac
done
shift $((OPTIND-1))

# Kiểm tra biến môi trường BASE_DOMAIN_ENV, ưu tiên hơn giá trị mặc định
BASE_DOMAIN=${BASE_DOMAIN_ENV:-$BASE_DOMAIN}

# Kiểm tra biến môi trường LETSENCRYPT_EMAIL nếu không được truyền qua tham số
LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL:-$LETSENCRYPT_EMAIL_ENV}

# Yêu cầu nhập email nếu không có giá trị
prompt_email

# Tạo thư mục gốc dựa trên base domain
ROOT_DIR="/root/$(echo $BASE_DOMAIN | tr '.' '-')"

# Kiểm tra quyền truy cập thư mục gốc
if ! mkdir -p "$ROOT_DIR" || ! [ -w "$ROOT_DIR" ]; then
  echo "Lỗi: Không thể tạo hoặc ghi vào thư mục $ROOT_DIR. Vui lòng kiểm tra quyền."
  exit 1
fi

# Xử lý tùy chọn liệt kê instance
if [ "$LIST" = true ]; then
  if [ -f "$ROOT_DIR/instances.txt" ]; then
    echo "Danh sách instance đã triển khai:"
    cat "$ROOT_DIR/instances.txt"
  else
    echo "Chưa có instance nào được triển khai."
  fi
  exit 0
fi

# Kiểm tra danh sách subdomain
if [ $# -eq 0 ] && [ "$UPDATE_ALL" = false ]; then
  echo "Cách sử dụng: $0 [-d base_domain] [-e letsencrypt_email] [-r] [-l] [-u] [subdomain1 subdomain2 ...]"
  echo "  -d: Chỉ định base domain (mặc định: n8n.works)"
  echo "  -e: Chỉ định email cho Let's Encrypt (có thể dùng biến môi trường LETSENCRYPT_EMAIL_ENV)"
  echo "  -r: Khởi tạo lại instance cho các subdomain chỉ định"
  echo "  -l: Liệt kê tất cả instance đã triển khai"
  echo "  -u: Cập nhật tất cả instance hiện có"
  exit 1
fi

subdomains=("$@")

# Tạo thư mục gốc và thư mục con
if [ "$INCLUDE_REDIS" = true ]; then
  mkdir -p "$ROOT_DIR/redis"
fi

# Xử lý tùy chọn cập nhật tất cả instance
if [ "$UPDATE_ALL" = true ]; then
  if [ -f "$ROOT_DIR/instances.txt" ]; then
    mapfile -t subdomains < "$ROOT_DIR/instances.txt"
    if [ ${#subdomains[@]} -eq 0 ]; then
      echo "Không có instance nào để cập nhật."
      exit 0
    fi
  else
    echo "Không có instance nào để cập nhật."
    exit 0
  fi
fi

# Kiểm tra DNS và xác nhận trước khi chạy
echo "Sẽ triển khai/cập nhật các instance sau: ${subdomains[*]}"
echo "Base domain: $BASE_DOMAIN"
echo "Thư mục gốc: $ROOT_DIR"
for subdomain in "${subdomains[@]}"; do
  check_dns "$subdomain" "$BASE_DOMAIN"
done
echo "Tiếp tục? (y/n)"
read -r confirm
if [ "$confirm" != "y" ]; then
  echo "Đã hủy."
  exit 0
fi

# Gán cổng động cho mỗi instance n8n
port=5678
declare -A port_mapping
for subdomain in "${subdomains[@]}"; do
  port_mapping[$subdomain]=$port
  ((port++))
done

# Xây dựng file docker-compose.yml
compose_file="services:\n"

# Thêm dịch vụ Redis nếu được kích hoạt
if [ "$INCLUDE_REDIS" = true ]; then
  compose_file+="  redis:\n    image: redis:7.2\n    volumes:\n      - $ROOT_DIR/redis:/data\n\n"
fi

# Thêm dịch vụ n8n và PostgreSQL cho mỗi subdomain
for subdomain in "${subdomains[@]}"; do
  SUBDOMAIN_DIR="$ROOT_DIR/$subdomain-$(echo $BASE_DOMAIN | tr '.' '-')"
  mkdir -p "$SUBDOMAIN_DIR/postgres"
  mkdir -p "$SUBDOMAIN_DIR"

  # Kiểm tra subdomain đã tồn tại
  POSTGRES_PASSWORD=$(get_postgres_password "$SUBDOMAIN_DIR")
  if [ -f "$SUBDOMAIN_DIR/postgres-credentials.txt" ] && [ "$REINIT" = false ]; then
    echo "Subdomain $subdomain đã tồn tại. Giữ cấu hình hiện có."
    continue
  fi

  # Lưu mật khẩu vào file credentials
  echo "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" > "$SUBDOMAIN_DIR/postgres-credentials.txt"
  chmod 600 "$SUBDOMAIN_DIR/postgres-credentials.txt"

  n8n_service_name="n8n-${subdomain}"
  postgres_service_name="postgres-${subdomain}"
  n8n_port=${port_mapping[$subdomain]}

  compose_file+="  $n8n_service_name:\n    image: $N8N_IMAGE\n    ports:\n      - \"$n8n_port:5678\"\n    environment:\n      - DB_TYPE=postgresdb\n      - DB_POSTGRESDB_HOST=$postgres_service_name\n      - DB_POSTGRESDB_PORT=5432\n      - DB_POSTGRESDB_USER=n8n-$subdomain\n      - DB_POSTGRESDB_PASSWORD=$POSTGRES_PASSWORD\n      - DB_POSTGRESDB_DATABASE=db-n8n-$subdomain"
  if [ "$INCLUDE_REDIS" = true ]; then
    compose_file+="\n      - REDIS_HOST=redis\n      - REDIS_PORT=6379\n      - REDIS_KEY_PREFIX=$subdomain"
  fi
  compose_file+="\n\n"

  compose_file+="  $postgres_service_name:\n    image: postgres:16.8\n    environment:\n      - POSTGRES_USER=n8n-$subdomain\n      - POSTGRES_PASSWORD=$POSTGRES_PASSWORD\n      - POSTGRES_DB=db-n8n-$subdomain\n    volumes:\n      - $SUBDOMAIN_DIR/postgres:/var/lib/postgresql/data\n\n"

  # Cập nhật danh sách instance
  if ! grep -Fx "$subdomain" "$ROOT_DIR/instances.txt" >/dev/null 2>&1; then
    echo "$subdomain" >> "$ROOT_DIR/instances.txt"
  fi

  # Tạo file info.md với hậu tố thời gian
  info_file="$SUBDOMAIN_DIR/info-$(date +%F-%H%M%S).md"
  cat << EOF > "$info_file"
# Thông tin cài đặt n8n cho $subdomain.$BASE_DOMAIN

## Thông tin chung
- **Subdomain**: $subdomain.$BASE_DOMAIN
- **URL truy cập**: https://$subdomain.$BASE_DOMAIN
- **Thư mục dữ liệu**: $SUBDOMAIN_DIR
- **Docker Compose file**: $ROOT_DIR/docker-compose.yml
- **Kiến trúc**: $ARCH
- **Hình ảnh n8n**: $N8N_IMAGE
- **Cổng nội bộ**: $n8n_port

## Cấu hình PostgreSQL
- **Database**: db-n8n-$subdomain
- **Username**: n8n-$subdomain
- **Password**: $POSTGRES_PASSWORD

## Cách quản lý
- Khởi động: \`cd $ROOT_DIR && docker compose up -d\`
- Dừng: \`cd $ROOT_DIR && docker compose stop $n8n_service_name $postgres_service_name\`
- Xóa container (giữ dữ liệu): \`cd $ROOT_DIR && docker compose rm -f $n8n_service_name $postgres_service_name\`
- Sao lưu dữ liệu: \`tar -czf $subdomain-backup.tar.gz $SUBDOMAIN_DIR\`

## Lưu ý
- Đảm bảo DNS được cấu hình đúng cho $subdomain.$BASE_DOMAIN.
- Sao lưu thư mục $SUBDOMAIN_DIR định kỳ để tránh mất dữ liệu.
- Để cập nhật n8n, chạy: \`cd $ROOT_DIR && docker compose pull && docker compose up -d\`.
EOF
done

# Ghi file docker-compose.yml vào thư mục gốc
echo -e "$compose_file" > "$ROOT_DIR/docker-compose.yml"

# Khởi động các dịch vụ
cd "$ROOT_DIR"
if [ "$REINIT" = true ]; then
  for subdomain in "${subdomains[@]}"; do
    n8n_service_name="n8n-${subdomain}"
    postgres_service_name="postgres-${subdomain}"
    docker compose stop "$n8n_service_name" "$postgres_service_name"
    docker compose rm -f "$n8n_service_name" "$postgres_service_name"
  done
fi
docker compose up -d
cd - >/dev/null

# Tạo file cấu hình Nginx tạm thời để lấy chứng chỉ
for subdomain in "${subdomains[@]}"; do
  nginx_conf="/etc/nginx/sites-available/$subdomain.$BASE_DOMAIN"
  nginx_link="/etc/nginx/sites-enabled/$subdomain.$BASE_DOMAIN"

  cat << EOF > "$nginx_conf"
server {
    listen 80;
    server_name $subdomain.$BASE_DOMAIN;

    location / {
        return 200 'Temporary server for Certbot';
    }
}
EOF

  ln -sf "$nginx_conf" "$nginx_link"
done

# Kiểm tra cấu hình Nginx
nginx -t
if [ $? -ne 0 ]; then
  echo "Lỗi: Cấu hình Nginx không hợp lệ. Vui lòng kiểm tra lại."
  exit 1
fi

# Khởi động lại Nginx để áp dụng cấu hình tạm thời
systemctl restart nginx

# Kiểm tra cổng 80
check_port_access 80

# Tải chứng chỉ Let's Encrypt bằng Certbot
for subdomain in "${subdomains[@]}"; do
  certbot certonly --nginx -d "$subdomain.$BASE_DOMAIN" --non-interactive --agree-tos --email "$LETSENCRYPT_EMAIL"
  if [ $? -ne 0 ]; then
    echo "Lỗi: Không thể lấy chứng chỉ Let's Encrypt cho $subdomain.$BASE_DOMAIN."
    echo "Kiểm tra:"
    echo "  - Cổng 80 có mở và truy cập được từ bên ngoài không? (ufw allow 80/tcp)"
    echo "  - DNS của $subdomain.$BASE_DOMAIN có trỏ đúng về IP máy chủ không? (dig $subdomain.$BASE_DOMAIN)"
    echo "  - Có thể cần liên hệ nhà cung cấp VPS để mở cổng 80."
    exit 1
  fi
done

# Cấu hình Nginx với chứng chỉ
for subdomain in "${subdomains[@]}"; do
  nginx_conf="/etc/nginx/sites-available/$subdomain.$BASE_DOMAIN"
  nginx_link="/etc/nginx/sites-enabled/$subdomain.$BASE_DOMAIN"
  n8n_port=${port_mapping[$subdomain]}

  cat << EOF > "$nginx_conf"
server {
    listen 80;
    server_name $subdomain.$BASE_DOMAIN;

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name $subdomain.$BASE_DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$subdomain.$BASE_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$subdomain.$BASE_DOMAIN/privkey.pem;

    location / {
        proxy_pass http://localhost:$n8n_port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

  ln -sf "$nginx_conf" "$nginx_link"
done

# Kiểm tra cấu hình Nginx
nginx -t
if [ $? -ne 0 ]; then
  echo "Lỗi: Cấu hình Nginx không hợp lệ. Vui lòng kiểm tra lại."
  exit 1
fi

# Khởi động lại Nginx
systemctl restart nginx

# In thông tin ra màn hình
for subdomain in "${subdomains[@]}"; do
  SUBDOMAIN_DIR="$ROOT_DIR/$subdomain-$(echo $BASE_DOMAIN | tr '.' '-')"
  POSTGRES_PASSWORD=$(get_postgres_password "$SUBDOMAIN_DIR")
  n8n_port=${port_mapping[$subdomain]}
  echo "Đã cài đặt/khởi tạo lại n8n cho $subdomain.$BASE_DOMAIN"
  echo "- URL: https://$subdomain.$BASE_DOMAIN"
  echo "- PostgreSQL Database: db-n8n-$subdomain"
  echo "- PostgreSQL Username: n8n-$subdomain"
  echo "- PostgreSQL Password: $POSTGRES_PASSWORD"
  echo "- Thư mục dữ liệu: $SUBDOMAIN_DIR"
  echo "- File info: $SUBDOMAIN_DIR/info-$(date +%F-%H%M%S).md"
  echo "- Kiến trúc: $ARCH"
  echo "- Hình ảnh n8n: $N8N_IMAGE"
  echo "- Cổng nội bộ: $n8n_port"
  echo
done
