#!/usr/bin/env bash
# n8n MANAGER + Cloudflare Tunnel

DATA_DIR_DEFAULT="/root/.n8n"
INSTALL_DIR_DEFAULT="/opt/n8n"
TUNNEL_NAME_DEFAULT="n8n-tunnel"
SERVICE_NAME="cloudflared-n8n.service"

# ---------- helper ----------

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "❌ Script này cần chạy với quyền root (sudo)."
    exit 1
  fi
}

ensure_base_packages() {
  # Các gói cơ bản, cài nếu thiếu
  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "▶ Cập nhật hệ thống & cài gói phụ thuộc (curl, jq...)..."
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y curl ca-certificates gnupg lsb-release wget jq >/dev/null 2>&1 || true
  fi
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "❌ Chưa có Docker. Hãy cài Docker trước rồi chạy lại script."
    exit 1
  fi
}

ensure_cloudflared() {
  if ! command -v cloudflared >/dev/null 2>&1; then
    echo "❌ Không tìm thấy 'cloudflared'. Hãy cài cloudflared trước rồi chạy lại."
    echo "   Tham khảo: https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/installation/"
    exit 1
  fi
}

dc() {
  # Wrapper cho docker compose
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    echo "❌ Không tìm thấy 'docker compose' hay 'docker-compose'."
    exit 1
  fi
}

prompt_default() {
  local prompt="$1"
  local default="$2"
  local value
  read -r -p "$prompt [$default]: " value
  if [[ -z "$value" ]]; then
    value="$default"
  fi
  echo "$value"
}

prompt_password_twice() {
  local var_name="$1"
  local pwd1 pwd2
  while true; do
    echo "ℹ️ Lưu ý: khi nhập mật khẩu, terminal sẽ KHÔNG hiện ký tự."
    read -s -p "Mật khẩu database PostgreSQL: " pwd1; echo
    read -s -p "Nhập lại mật khẩu PostgreSQL: " pwd2; echo
    if [[ -z "$pwd1" ]]; then
      echo "❌ Mật khẩu không được để trống."
      continue
    fi
    if [[ "$pwd1" != "$pwd2" ]]; then
      echo "❌ Mật khẩu nhập lại không khớp. Thử lại."
      continue
    fi
    printf -v "$var_name" '%s' "$pwd1"
    break
  done
}

ensure_cloudflared_login() {
  if [[ ! -f /root/.cloudflared/cert.pem ]]; then
    echo "⚠️ Chưa thấy /root/.cloudflared/cert.pem."
    echo "   Bạn cần chạy 'cloudflared tunnel login' 1 lần để liên kết tài khoản Cloudflare,"
    echo "   sau đó chạy lại script."
    exit 1
  fi
}

get_tunnel_id_by_name() {
  local name="$1"
  cloudflared tunnel list 2>/dev/null | awk -v t="$name" '$2 == t {print $1}' | head -n1
}

# ---------- chức năng chính ----------

install_or_update_n8n() {
  echo
  echo "=== CÀI ĐẶT / CẬP NHẬT n8n + PostgreSQL + Cloudflare Tunnel ==="

  local HOSTNAME TUNNEL_NAME INSTALL_DIR TZ DB_NAME DB_USER DB_PASS N8N_IMAGE
  HOSTNAME=$(prompt_default "Hostname cho n8n" "n8n.rawcode.io")
  TUNNEL_NAME=$(prompt_default "Tên tunnel" "$TUNNEL_NAME_DEFAULT")
  INSTALL_DIR=$(prompt_default "Thư mục cài n8n" "$INSTALL_DIR_DEFAULT")
  TZ=$(prompt_default "Timezone" "Asia/Ho_Chi_Minh")
  DB_NAME=$(prompt_default "Tên database PostgreSQL" "n8n")
  DB_USER=$(prompt_default "User database PostgreSQL" "n8n")
  prompt_password_twice DB_PASS
  N8N_IMAGE=$(prompt_default "Image n8n" "docker.n8n.io/n8nio/n8n")

  local DATA_DIR="$DATA_DIR_DEFAULT"

  echo
  echo "📌 Tóm tắt:"
  echo "   - Hostname:       $HOSTNAME"
  echo "   - Tunnel name:    $TUNNEL_NAME"
  echo "   - Install dir:    $INSTALL_DIR"
  echo "   - Timezone:       $TZ"
  echo "   - DB:             $DB_NAME"
  echo "   - DB user:        $DB_USER"
  echo "   - n8n image:      $N8N_IMAGE"
  echo "   - Service name:   $SERVICE_NAME"
  echo "   - Data dir:       $DATA_DIR (mount vào /home/node/.n8n)"
  echo "   * Nếu đã cài trước đó, KHÔNG nên đổi DB password nếu chưa xoá volume DB."
  echo

  read -r -p "Tiếp tục cài đặt? [y/N]: " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "❌ Huỷ."
    return
  fi

  ensure_base_packages
  ensure_docker
  ensure_cloudflared
  ensure_cloudflared_login

  echo "▶ Chuẩn bị thư mục data $DATA_DIR..."
  mkdir -p "$DATA_DIR"
  chown 1000:1000 "$DATA_DIR"
  chmod 700 "$DATA_DIR"

  echo "▶ Ghi file docker-compose.yml trong $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"

  cat >"$INSTALL_DIR/docker-compose.yml" <<EOF
name: n8n

services:
  n8n:
    image: $N8N_IMAGE
    container_name: n8n
    restart: unless-stopped
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=n8n-postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=$DB_NAME
      - DB_POSTGRESDB_USER=$DB_USER
      - DB_POSTGRESDB_PASSWORD=$DB_PASS
      - N8N_HOST=$HOSTNAME
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - N8N_EDITOR_BASE_URL=https://$HOSTNAME
      - N8N_API_BASE_URL=https://$HOSTNAME
      - WEBHOOK_URL=https://$HOSTNAME/
      - TZ=$TZ
      - GENERIC_TIMEZONE=$TZ
      - N8N_DIAGNOSTICS_ENABLED=false
    ports:
      - "127.0.0.1:5678:5678"
    volumes:
      - "$DATA_DIR:/home/node/.n8n"
    depends_on:
      - n8n-postgres

  n8n-postgres:
    image: postgres:16
    container_name: n8n-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_USER=$DB_USER
      - POSTGRES_PASSWORD=$DB_PASS
      - POSTGRES_DB=$DB_NAME
      - TZ=$TZ
    volumes:
      - n8n_postgres_data:/var/lib/postgresql/data

volumes:
  n8n_postgres_data:
    name: n8n_postgres_data
EOF

  echo "▶ Triển khai stack n8n + PostgreSQL (Postgres 16, data mount $DATA_DIR)..."
  cd "$INSTALL_DIR" || exit 1
  dc up -d

  echo "✅ n8n đã khởi động (local): http://127.0.0.1:5678"
  echo "   (Đợi vài giây cho container n8n & postgres ổn định...)"

  # Kiểm tra nhanh
  sleep 5
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5678 || echo "000")
  echo "▶ Thử curl từ local tới n8n: HTTP code: $http_code"

  # Cloudflare Tunnel
  echo
  echo "▶ Đảm bảo tunnel '$TUNNEL_NAME' tồn tại..."
  local TUNNEL_ID
  TUNNEL_ID=$(get_tunnel_id_by_name "$TUNNEL_NAME")

  if [[ -z "$TUNNEL_ID" ]]; then
    echo "▶ Tạo tunnel mới '$TUNNEL_NAME'..."
    cloudflared tunnel create "$TUNNEL_NAME"
    TUNNEL_ID=$(get_tunnel_id_by_name "$TUNNEL_NAME")
  else
    echo "ℹ️ Tunnel '$TUNNEL_NAME' đã tồn tại, dùng lại."
  fi

  if [[ -z "$TUNNEL_ID" ]]; then
    echo "❌ Không lấy được Tunnel ID cho '$TUNNEL_NAME'. Kiểm tra lại 'cloudflared tunnel list'."
    exit 1
  fi

  echo "   → Tunnel ID:   $TUNNEL_ID"
  echo "   → Credentials: /root/.cloudflared/${TUNNEL_ID}.json"

  echo "▶ Tạo / cập nhật DNS record cho $HOSTNAME..."
  # Lệnh đúng: cloudflared tunnel route dns <tunnel-name> <hostname>
  if cloudflared tunnel route dns "$TUNNEL_NAME" "$HOSTNAME"; then
    echo "   → Đã tạo/cập nhật CNAME cho $HOSTNAME (trỏ đúng tunnel $TUNNEL_NAME)."
  else
    echo "⚠ Không tạo được route DNS qua cloudflared. Có thể record đã tồn tại."
    echo "  Hãy kiểm tra lại DNS trong Cloudflare (CNAME $HOSTNAME trỏ về tunnel $TUNNEL_NAME)."
  fi

  echo "▶ Ghi file config tunnel: /etc/cloudflared/n8n-tunnel.yml"
  mkdir -p /etc/cloudflared
  cat >/etc/cloudflared/n8n-tunnel.yml <<EOF
tunnel: $TUNNEL_ID
credentials-file: /root/.cloudflared/${TUNNEL_ID}.json

ingress:
  - hostname: $HOSTNAME
    service: http://127.0.0.1:5678
  - service: http_status:404
EOF

  echo "▶ Ghi systemd service: /etc/systemd/system/$SERVICE_NAME"
  cat >/etc/systemd/system/$SERVICE_NAME <<EOF
[Unit]
Description=Cloudflare Tunnel - $TUNNEL_NAME (n8n)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared --no-autoupdate --config /etc/cloudflared/n8n-tunnel.yml tunnel run
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"

  echo "✅ Cloudflare Tunnel đã chạy. Kiểm tra nhanh:"
  systemctl --no-pager status "$SERVICE_NAME" || true

  echo
  echo "🎉 HOÀN TẤT CÀI n8n + TUNNEL!"
  echo "   - n8n qua Cloudflare:  https://$HOSTNAME"
  echo "   - Local:               http://127.0.0.1:5678"
  echo
  echo "Lần đầu vào UI n8n, bạn sẽ tạo user owner."
}

show_status() {
  echo
  echo "=== TRẠNG THÁI n8n + TUNNEL ==="
  echo
  echo "▶ Docker containers (liên quan n8n):"
  docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E '^n8n(|-postgres)' || echo "(không có container n8n nào)"

  echo
  echo "▶ Systemd service: $SERVICE_NAME"
  systemctl --no-pager status "$SERVICE_NAME" || echo "(service chưa tạo)"

  echo
  echo "▶ Danh sách tunnel có chữ 'n8n':"
  cloudflared tunnel list 2>/dev/null | grep -i n8n || echo "(không có tunnel n8n trong danh sách)"

  echo
  echo "▶ Thử curl từ local tới n8n:"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5678 || echo "000")
  echo "HTTP code: $code"
}

uninstall_n8n() {
  echo
  echo "=== GỠ n8n + Cloudflare Tunnel (local) ==="
  read -r -p "Bạn chắc chắn muốn gỡ n8n (container + service tunnel local)? [y/N]: " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "❌ Huỷ."
    return
  fi

  ensure_docker
  ensure_cloudflared

  # Stop containers
  if [[ -f "$INSTALL_DIR_DEFAULT/docker-compose.yml" ]]; then
    echo "▶ Dừng & xoá stack n8n bằng docker compose..."
    cd "$INSTALL_DIR_DEFAULT" || true
    dc down || true
  else
    echo "▶ Dừng & xoá container n8n / n8n-postgres (nếu có)..."
    docker rm -f n8n n8n-postgres 2>/dev/null || true
  fi

  echo "▶ Dừng & xoá systemd service $SERVICE_NAME..."
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  rm -f "/etc/systemd/system/$SERVICE_NAME"
  systemctl daemon-reload

  # Hỏi xoá data dir
  if [[ -d "$DATA_DIR_DEFAULT" ]]; then
    read -r -p "Bạn có muốn XOÁ thư mục data '$DATA_DIR_DEFAULT' (mất toàn bộ workflows, credentials, settings)? [y/N]: " del_data
    if [[ "$del_data" == "y" || "$del_data" == "Y" ]]; then
      rm -rf "$DATA_DIR_DEFAULT"
      echo "   → Đã xoá thư mục $DATA_DIR_DEFAULT."
    fi
  fi

  # Hỏi xoá thư mục cài đặt
  if [[ -d "$INSTALL_DIR_DEFAULT" ]]; then
    read -r -p "Bạn có muốn XOÁ thư mục cài đặt '$INSTALL_DIR_DEFAULT' (docker-compose.yml, env...)? [y/N]: " del_install
    if [[ "$del_install" == "y" || "$del_install" == "Y" ]]; then
      rm -rf "$INSTALL_DIR_DEFAULT"
      echo "   → Đã xoá thư mục $INSTALL_DIR_DEFAULT."
    fi
  fi

  # Volume Postgres
  local vols
  vols=$(docker volume ls --format '{{.Name}}' | grep -E '^n8n(_postgres_data|_n8n_postgres_data)$' || true)
  if [[ -n "$vols" ]]; then
    echo
    echo "Các Docker volume Postgres liên quan đến n8n được tìm thấy:"
    echo "$vols" | sed 's/^/   - /'
    read -r -p "Bạn có muốn XOÁ các volume này (XOÁ TOÀN BỘ DB n8n)? [y/N]: " del_vols
    if [[ "$del_vols" == "y" || "$del_vols" == "Y" ]]; then
      echo "$vols" | xargs -r docker volume rm
    fi
  fi

  # Thông tin tunnel từ config
  local cfg="/etc/cloudflared/n8n-tunnel.yml"
  local tunnel_id=""
  if [[ -f "$cfg" ]]; then
    tunnel_id=$(grep '^tunnel:' "$cfg" | awk '{print $2}')
  fi
  local tunnel_name="$TUNNEL_NAME_DEFAULT"

  if [[ -n "$tunnel_id" ]]; then
    echo
    echo "▶ Thông tin tunnel từ file cấu hình $cfg:"
    echo "   - Tunnel ID:   $tunnel_id"
    echo "   - Tunnel name: $tunnel_name"
    read -r -p "Bạn có muốn XOÁ Cloudflare Tunnel '$tunnel_name' khỏi account Cloudflare (cloudflared tunnel delete)? [y/N]: " del_tunnel
    if [[ "$del_tunnel" == "y" || "$del_tunnel" == "Y" ]]; then
      cloudflared tunnel delete "$tunnel_name" || cloudflared tunnel delete "$tunnel_id" || true
    fi

    read -r -p "Bạn có muốn XOÁ file cấu hình local '$cfg'? [y/N]: " del_cfg
    if [[ "$del_cfg" == "y" || "$del_cfg" == "Y" ]]; then
      rm -f "$cfg"
      echo "   → Đã xoá file cấu hình tunnel local."
    fi
  fi

  echo
  echo "⚠ Về Cloudflare DNS:"
  echo "   - Script KHÔNG tự xoá CNAME DNS trên Cloudflare."
  echo "   - Sau khi xoá tunnel (nếu có), hãy vào Cloudflare Dashboard để xoá record CNAME tương ứng (ví dụ: n8n.rawcode.io) nếu không dùng nữa."
  echo
  echo "✅ Đã gỡ n8n (container) + service $SERVICE_NAME trên máy chủ (tuỳ chọn xoá data/volume/tunnel theo lựa chọn của bạn)."
}

update_n8n_image() {
  echo
  echo "=== UPDATE n8n (pull image mới nhất, giữ data) ==="

  if [[ ! -f "$INSTALL_DIR_DEFAULT/docker-compose.yml" ]]; then
    echo "❌ Không tìm thấy $INSTALL_DIR_DEFAULT/docker-compose.yml"
    echo "   Có vẻ n8n chưa được cài bằng script này."
    return
  fi

  ensure_docker

  cd "$INSTALL_DIR_DEFAULT" || exit 1
  echo "▶ Pull image mới nhất..."
  dc pull n8n

  echo "▶ Khởi động lại stack với image mới..."
  dc up -d

  echo "✅ Đã update n8n. Kiểm tra log bằng:"
  echo "   docker logs -f n8n"
}

main_menu() {
  while true; do
    echo "=============================="
    echo " n8n MANAGER + CLOUDFLARE TUNNEL"
    echo "=============================="
    echo "1) Cài / cập nhật n8n + tunnel"
    echo "2) Kiểm tra trạng thái n8n + tunnel"
    echo "3) Gỡ n8n + service + (tuỳ chọn) xoá data & volume & tunnel"
    echo "4) Update n8n (pull image mới nhất, giữ data)"
    echo "0) Thoát"
    echo "=============================="
    read -r -p "Chọn chức năng (0-4): " choice

    case "$choice" in
      1) install_or_update_n8n ;;
      2) show_status ;;
      3) uninstall_n8n ;;
      4) update_n8n_image ;;
      0) exit 0 ;;
      *) echo "❌ Lựa chọn không hợp lệ." ;;
    esac
  done
}

# ---------- start ----------
require_root
main_menu
