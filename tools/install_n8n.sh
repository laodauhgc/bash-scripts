#!/bin/bash

# Hàm tạo mật khẩu ngẫu nhiên
generate_password() {
  tr -dc A-Za-z0-9 </dev/urandom | head -c 12
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

# Hàm kiểm tra và giải phóng cổng 80
check_and_free_ports() {
  for port in 80; do
    if ss -tulnp 2>/dev/null | grep -q ":$port "; then
      echo "Cổng $port đang được sử dụng. Kiểm tra tiến trình..."
      pids=$(ss -tulnp 2>/dev/null | grep ":$port " | awk '{print $NF}' | grep -oP 'pid=\K\d+' | sort -u)
      for pid in $pids; do
        process_name=$(ps -p "$pid" -o comm= 2>/dev/null)
        echo "PID: $pid - Chương trình: $process_name"
        echo "Dừng tiến trình $process_name (PID: $pid) để giải phóng cổng $port..."
        kill -9 "$pid"
      done
    fi
  done
  # Kiểm tra lại xem cổng đã được giải phóng chưa
  for port in 80; do
    if ss -tulnp 2>/dev/null | grep -q ":$port "; then
      echo "Lỗi: Không thể giải phóng cổng $port. Vui lòng kiểm tra và dừng tiến trình thủ công."
      exit 1
    fi
  done
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

# Xử lý đối số dòng lệnh
BASE_DOMAIN="n8n.works"  # Mặc định base domain
INCLUDE_REDIS=true      # Đặt thành false nếu không muốn sử dụng Redis
REINIT=false            # Tùy chọn khởi tạo lại
LIST=false              # Tùy chọn liệt kê instance
UPDATE_ALL=false        # Tùy chọn cập nhật tất cả instance
N8N_IMAGE=${N8N_IMAGE:-"docker.n8n.io/n8nio/n8n:latest"}  # Giá trị mặc định cho image n8n

while getopts "d:rlu" opt; do
  case $opt in
    d) BASE_DOMAIN="$OPTARG" ;;
    r) REINIT=true ;;
    l) LIST=true ;;
    u) UPDATE_ALL=true ;;
    \?) echo "Tùy chọn không hợp lệ: -$OPTARG" >&2; exit 1 ;;
  esac
done
shift $((OPTIND-1))

# Kiểm tra biến môi trường BASE_DOMAIN_ENV, ưu tiên hơn giá trị mặc định
BASE_DOMAIN=${BASE_DOMAIN_ENV:-$BASE_DOMAIN}

# Tạo thư mục gốc dựa trên base domain
ROOT_DIR="/root/$(echo $BASE_DOMAIN | tr '.' '-')"

# Kiểm tra quyền truy cập thư mục gốc
if ! mkdir -p "$ROOT_DIR" || ! [ -w "$ROOT_DIR" ]; then
  echo "Lỗi: Không thể tạo hoặc ghi vào thư mục $ROOT_DIR. Vui lòng kiểm tra quyền."
  exit 1
fi

# Tạo thư mục cho Nginx
mkdir -p "$ROOT_DIR/nginx/conf.d"

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
  echo "Cách sử dụng: $0 [-d base_domain] [-r] [-l] [-u] [subdomain1 subdomain2 ...]"
  echo "  -d: Chỉ định base domain (mặc định: n8n.works)"
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

# Giải phóng cổng 80
check_and_free_ports

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
done

# Thêm dịch vụ Nginx
compose_file+="  nginx:\n    image: nginx:latest\n    ports:\n      - \"80:80\"\n    volumes:\n      - $ROOT_DIR/nginx/conf.d:/etc/nginx/conf.d\n"

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

# Kiểm tra trạng thái container
echo "Kiểm tra trạng thái container sau khi khởi động..."
docker ps

# Cấu hình Nginx để proxy đến n8n (chỉ HTTP, vì Cloudflare xử lý HTTPS)
for subdomain in "${subdomains[@]}"; do
  domain="$subdomain.$BASE_DOMAIN"
  nginx_conf="$ROOT_DIR/nginx/conf.d/$domain.conf"
  n8n_service_name="n8n-${subdomain}"
  cat << EOF > "$nginx_conf"
server {
    listen 80;
    server_name $domain;

    location / {
        proxy_pass http://$n8n_service_name:5678;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
done

# Khởi động lại container Nginx để áp dụng cấu hình
cd "$ROOT_DIR"
docker compose restart nginx
cd - >/dev/null

# Cập nhật danh sách instance và tạo file info
for subdomain in "${subdomains[@]}"; do
  SUBDOMAIN_DIR="$ROOT_DIR/$subdomain-$(echo $BASE_DOMAIN | tr '.' '-')"
  mkdir -p "$SUBDOMAIN_DIR"

  # Kiểm tra subdomain đã tồn tại
  POSTGRES_PASSWORD=$(get_postgres_password "$SUBDOMAIN_DIR")
  if [ -f "$SUBDOMAIN_DIR/postgres-credentials.txt" ] && [ "$REINIT" = false ]; then
    continue
  fi

  # Lưu mật khẩu vào file credentials
  echo "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" > "$SUBDOMAIN_DIR/postgres-credentials.txt"
  chmod 600 "$SUBDOMAIN_DIR/postgres-credentials.txt"

  # Cập nhật danh sách instance
  if ! grep -Fx "$subdomain" "$ROOT_DIR/instances.txt" >/dev/null 2>&1; then
    echo "$subdomain" >> "$ROOT_DIR/instances.txt"
  fi

  # Tạo file info.md với hậu tố thời gian
  info_file="$SUBDOMAIN_DIR/info-$(date +%F-%H%M%S).md"
  n8n_port=${port_mapping[$subdomain]}
  cat << EOF > "$info_file"
# Thông tin cài đặt n8n cho $subdomain.$BASE_DOMAIN

## Thông tin chung
- **Subdomain**: $subdomain.$BASE_DOMAIN
- **URL truy cập**: https://$subdomain.$BASE_DOMAIN
- **Thư mục dữ liệu**: $SUBDOMAIN_DIR
- **Docker Compose file**: $ROOT_DIR/docker-compose.yml
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
  echo "- Cổng nội bộ: $n8n_port"
  echo
done
