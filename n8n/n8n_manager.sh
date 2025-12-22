#!/usr/bin/env bash
set -euo pipefail

########################################
# CẤU HÌNH MẶC ĐỊNH
########################################

if [[ "$EUID" -ne 0 ]]; then
  echo "❌ Vui lòng chạy script với quyền root (sudo su hoặc sudo ./n8n_manager.sh)"
  exit 1
fi

DEFAULT_N8N_HOST="n8n.rawcode.io"
DEFAULT_TUNNEL_NAME="n8n-tunnel"
DEFAULT_INSTALL_DIR="/opt/n8n"
DEFAULT_TIMEZONE="Asia/Ho_Chi_Minh"
DEFAULT_DB_NAME="n8n"
DEFAULT_DB_USER="n8n"
DEFAULT_N8N_IMAGE="docker.n8n.io/n8nio/n8n"

TUNNEL_CONFIG="/etc/cloudflared/n8n-tunnel.yml"
TUNNEL_SERVICE="/etc/systemd/system/cloudflared-n8n.service"
HOST_N8N_DIR="${HOME}/.n8n"  # VD: /root/.n8n (như bạn yêu cầu)

########################################
# HÀM TIỆN ÍCH
########################################

detect_compose() {
  if command -v docker &>/dev/null && docker compose version &>/dev/null; then
    DOCKER_COMPOSE_CMD="docker compose"
  elif command -v docker-compose &>/dev/null; then
    DOCKER_COMPOSE_CMD="docker-compose"
  else
    echo "⚠ Không tìm thấy docker compose, tiến hành cài docker-compose..."
    apt update -y
    apt install -y docker-compose
    DOCKER_COMPOSE_CMD="docker-compose"
  fi
}

ensure_docker() {
  if ! command -v docker &>/dev/null; then
    echo "▶ Không thấy Docker, tiến hành cài đặt Docker CE..."
    apt update -y
    apt install -y ca-certificates curl gnupg lsb-release

    install -m 0755 -d /etc/apt/keyrings
    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
      echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
        $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list >/dev/null
    fi

    apt update -y
    apt install -y docker-ce docker-ce-cli containerd.io
  fi

  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker
}

ensure_cloudflared_installed() {
  if ! command -v cloudflared &>/dev/null; then
    echo "▶ Cài đặt cloudflared..."
    apt update -y
    apt install -y wget
    cd /tmp
    wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -O cloudflared.deb
    dpkg -i cloudflared.deb || apt -f install -y
  fi
}

ensure_cf_cert() {
  echo
  if [ -f /root/.cloudflared/cert.pem ]; then
    echo "ℹ️ Đã có cert Cloudflare tại /root/.cloudflared/cert.pem, bỏ qua bước 'cloudflared tunnel login'."
  else
    echo "🔑 Bước tiếp theo: ĐĂNG NHẬP CLOUDFLARE ĐỂ CẤP QUYỀN CHO TUNNEL."
    echo "   - Lệnh sau sẽ in ra 1 URL."
    echo "   - Copy URL đó, mở trong trình duyệt, đăng nhập Cloudflare."
    echo "   - Chọn zone chứa domain n8n (vd: ${DEFAULT_N8N_HOST})."
    echo "   - Sau khi báo thành công, quay lại terminal."
    read -rp "Nhấn Enter để chạy 'cloudflared tunnel login'..." _
    cloudflared tunnel login
  fi
}

ensure_tunnel() {
  local TUNNEL_NAME="$1"

  echo "▶ Đảm bảo tunnel '${TUNNEL_NAME}' tồn tại..."

  # Kiểm tra tunnel theo tên (dùng JSON + jq cho sạch)
  local TUNNEL_JSON_BASE64
  TUNNEL_JSON_BASE64=$(cloudflared tunnel list --output json 2>/dev/null | jq -r ".[] | select(.name==\"${TUNNEL_NAME}\") | @base64" || true)

  if [ -z "$TUNNEL_JSON_BASE64" ]; then
    echo "▶ Tạo tunnel mới '${TUNNEL_NAME}'..."
    # Tạo tunnel (output ghi log, không nhét vào biến để tránh hỏng YAML)
    cloudflared tunnel create "${TUNNEL_NAME}" >/tmp/cloudflared_create_${TUNNEL_NAME}.log 2>&1

    # Lấy lại JSON sau khi tạo
    TUNNEL_JSON_BASE64=$(cloudflared tunnel list --output json 2>/dev/null | jq -r ".[] | select(.name==\"${TUNNEL_NAME}\") | @base64" || true)
  else
    echo "ℹ️ Tunnel '${TUNNEL_NAME}' đã tồn tại, dùng lại."
  fi

  if [ -z "$TUNNEL_JSON_BASE64" ]; then
    echo "❌ Không tìm thấy tunnel '${TUNNEL_NAME}' sau khi tạo."
    echo "   Hãy thử: cloudflared tunnel list"
    exit 1
  fi

  _jq() {
    echo "$TUNNEL_JSON_BASE64" | base64 --decode | jq -r "$1"
  }

  TUNNEL_ID=$(_jq '.id')
  CRED_FILE="/root/.cloudflared/${TUNNEL_ID}.json"

  echo "   → Tunnel ID:   ${TUNNEL_ID}"
  echo "   → Credentials: ${CRED_FILE}"

  if [ ! -f "$CRED_FILE" ]; then
    echo "⚠ Không tìm thấy file credentials ${CRED_FILE}"
    echo "   Hãy ls /root/.cloudflared để kiểm tra:"
    ls -l /root/.cloudflared || true
  fi
}

########################################
# CÀI / UPDATE n8n + TUNNEL
########################################

install_or_update_n8n() {
  echo
  echo "=== CÀI ĐẶT / CẬP NHẬT n8n + PostgreSQL + Cloudflare Tunnel ==="

  read -rp "Hostname cho n8n [${DEFAULT_N8N_HOST}]: " N8N_HOST
  N8N_HOST=${N8N_HOST:-$DEFAULT_N8N_HOST}

  read -rp "Tên tunnel [${DEFAULT_TUNNEL_NAME}]: " TUNNEL_NAME
  TUNNEL_NAME=${TUNNEL_NAME:-$DEFAULT_TUNNEL_NAME}

  read -rp "Thư mục cài n8n [${DEFAULT_INSTALL_DIR}]: " INSTALL_DIR
  INSTALL_DIR=${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}

  read -rp "Timezone [${DEFAULT_TIMEZONE}]: " TIMEZONE
  TIMEZONE=${TIMEZONE:-$DEFAULT_TIMEZONE}

  read -rp "Tên database PostgreSQL [${DEFAULT_DB_NAME}]: " DB_NAME
  DB_NAME=${DB_NAME:-$DEFAULT_DB_NAME}

  read -rp "User database PostgreSQL [${DEFAULT_DB_USER}]: " DB_USER
  DB_USER=${DB_USER:-$DEFAULT_DB_USER}

  echo "ℹ️ Lưu ý: khi nhập mật khẩu DB, terminal sẽ KHÔNG hiện ký tự."
  local DB_PASSWORD DB_PASSWORD_CONFIRM
  while true; do
    read -srp "Mật khẩu database PostgreSQL: " DB_PASSWORD
    echo
    read -srp "Nhập lại mật khẩu database PostgreSQL: " DB_PASSWORD_CONFIRM
    echo
    if [[ -n "$DB_PASSWORD" && "$DB_PASSWORD" == "$DB_PASSWORD_CONFIRM" ]]; then
      break
    else
      echo "❌ Mật khẩu không trùng hoặc rỗng, hãy nhập lại."
    fi
  done

  read -rp "Image n8n [${DEFAULT_N8N_IMAGE}]: " N8N_IMAGE
  N8N_IMAGE=${N8N_IMAGE:-$DEFAULT_N8N_IMAGE}

  echo
  echo "📌 Tóm tắt:"
  echo "   - Hostname:       ${N8N_HOST}"
  echo "   - Tunnel name:    ${TUNNEL_NAME}"
  echo "   - Install dir:    ${INSTALL_DIR}"
  echo "   - Timezone:       ${TIMEZONE}"
  echo "   - DB:             ${DB_NAME}"
  echo "   - DB user:        ${DB_USER}"
  echo "   - n8n image:      ${N8N_IMAGE}"
  echo "   - Service name:   cloudflared-n8n.service"
  echo "   - Data dir:       ${HOST_N8N_DIR} (mount vào /home/node/.n8n)"
  echo "   * Nếu đã cài trước đó, KHÔNG nên đổi DB password nếu chưa xoá volume DB."
  echo
  read -rp "Tiếp tục cài đặt? [y/N]: " CONFIRM
  CONFIRM=${CONFIRM:-n}
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "⏹ Hủy."
    return
  fi

  echo "▶ Cập nhật hệ thống & cài gói phụ thuộc..."
  apt update -y
  apt install -y curl ca-certificates gnupg lsb-release wget jq

  ensure_docker
  detect_compose
  ensure_cloudflared_installed
  ensure_cf_cert

  mkdir -p "$INSTALL_DIR"
  mkdir -p "$HOST_N8N_DIR"
  # n8n trong container thường chạy với uid 1000
  chown -R 1000:1000 "$HOST_N8N_DIR" || true

  echo "▶ Ghi file docker-compose.yml trong ${INSTALL_DIR}"
  cat > "${INSTALL_DIR}/docker-compose.yml" <<EOF
services:
  n8n-postgres:
    image: postgres:16
    container_name: n8n-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_DB=${DB_NAME}
      - POSTGRES_USER=${DB_USER}
      - POSTGRES_PASSWORD=${DB_PASSWORD}
    volumes:
      - n8n_postgres_data:/var/lib/postgresql/data

  n8n:
    image: ${N8N_IMAGE}
    container_name: n8n
    restart: unless-stopped
    depends_on:
      - n8n-postgres
    environment:
      - TZ=${TIMEZONE}
      - GENERIC_TIMEZONE=${TIMEZONE}
      - N8N_HOST=${N8N_HOST}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=https://${N8N_HOST}/
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=n8n-postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=${DB_NAME}
      - DB_POSTGRESDB_USER=${DB_USER}
      - DB_POSTGRESDB_PASSWORD=${DB_PASSWORD}
    ports:
      - "127.0.0.1:5678:5678"
    volumes:
      - ${HOST_N8N_DIR}:/home/node/.n8n

volumes:
  n8n_postgres_data:
EOF

  echo "▶ Triển khai stack n8n + PostgreSQL (dùng Postgres 16, data mount ${HOST_N8N_DIR})..."
  cd "$INSTALL_DIR"
  $DOCKER_COMPOSE_CMD up -d

  echo "✅ n8n đã khởi động (local): http://127.0.0.1:5678"
  echo "   (Đợi vài giây cho container n8n & postgres ổn định...)"
  sleep 5

  echo
  ensure_tunnel "$TUNNEL_NAME"

  echo "▶ Tạo / cập nhật DNS record cho ${N8N_HOST}..."
  if cloudflared tunnel route dns "$TUNNEL_NAME" "$N8N_HOST"; then
    echo "   → Đã tạo/cập nhật CNAME cho ${N8N_HOST}."
  else
    echo "⚠ Không tạo được DNS cho ${N8N_HOST} (có thể record đã tồn tại). Hãy kiểm tra lại trong Cloudflare."
  fi

  mkdir -p "$(dirname "$TUNNEL_CONFIG")"
  echo "▶ Ghi file config tunnel: ${TUNNEL_CONFIG}"
  cat > "$TUNNEL_CONFIG" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CRED_FILE}

ingress:
  - hostname: ${N8N_HOST}
    service: http://127.0.0.1:5678
  - service: http_status:404
EOF

  echo "▶ Ghi systemd service: ${TUNNEL_SERVICE}"
  cat > "$TUNNEL_SERVICE" <<EOF
[Unit]
Description=Cloudflare Tunnel - ${TUNNEL_NAME} (n8n)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared --no-autoupdate --config ${TUNNEL_CONFIG} tunnel run
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable cloudflared-n8n.service >/dev/null 2>&1 || true
  systemctl restart cloudflared-n8n.service

  echo "✅ Cloudflare Tunnel đã chạy. Kiểm tra nhanh:"
  systemctl status cloudflared-n8n.service --no-pager || true

  echo
  echo "🎉 HOÀN TẤT CÀI n8n + TUNNEL!"
  echo "   - n8n qua Cloudflare:  https://${N8N_HOST}"
  echo "   - Local:               http://127.0.0.1:5678"
  echo
  echo "Lần đầu vào UI n8n, bạn sẽ tạo user owner."
}

########################################
# TRẠNG THÁI
########################################

status_n8n() {
  echo
  echo "=== TRẠNG THÁI n8n + TUNNEL ==="
  echo

  echo "▶ Docker containers (liên quan n8n):"
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | awk 'NR==1 || /n8n/'

  echo
  echo "▶ Systemd service: cloudflared-n8n.service"
  if systemctl list-unit-files | grep -q "^cloudflared-n8n.service"; then
    systemctl status cloudflared-n8n.service --no-pager || true
  else
    echo "Không có service cloudflared-n8n.service"
  fi

  echo
  echo "▶ Danh sách tunnel có chữ 'n8n':"
  cloudflared tunnel list | grep -i "n8n" || echo "Không có tunnel nào chứa 'n8n'"

  echo
  echo "▶ Thử curl từ local tới n8n:"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5678/ || true)
  echo "HTTP code: ${code}"
}

########################################
# GỠ n8n + SERVICE + (TUỲ CHỌN) DATA
########################################

uninstall_n8n() {
  echo
  echo "=== GỠ n8n + Cloudflare Tunnel (local) ==="
  read -rp "Bạn chắc chắn muốn gỡ n8n (container + service tunnel local)? [y/N]: " CONFIRM
  CONFIRM=${CONFIRM:-n}
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "⏹ Hủy."
    return
  fi

  # Dừng & xoá container
  echo "▶ Dừng & xoá container n8n / n8n-postgres (nếu có)..."
  docker rm -f n8n n8n-postgres 2>/dev/null || true

  # Hỏi xoá volume Postgres
  if docker volume ls -q | grep -qx "n8n_postgres_data"; then
    read -rp "Bạn có muốn XOÁ volume PostgreSQL 'n8n_postgres_data' (xoá toàn bộ DB)? [y/N]: " DROP_VOL
    DROP_VOL=${DROP_VOL:-n}
    if [[ "$DROP_VOL" =~ ^[Yy]$ ]]; then
      docker volume rm n8n_postgres_data || echo "⚠ Không xoá được volume n8n_postgres_data."
    else
      echo "ℹ️ Giữ lại volume DB n8n_postgres_data."
    fi
  fi

  # Hỏi xoá thư mục ~/.n8n
  if [ -d "$HOST_N8N_DIR" ]; then
    read -rp "Bạn có muốn XOÁ thư mục dữ liệu n8n tại '${HOST_N8N_DIR}'? [y/N]: " DROP_DIR
    DROP_DIR=${DROP_DIR:-n}
    if [[ "$DROP_DIR" =~ ^[Yy]$ ]]; then
      rm -rf "$HOST_N8N_DIR"
      echo "   → Đã xoá ${HOST_N8N_DIR}"
    else
      echo "ℹ️ Giữ lại thư mục dữ liệu ${HOST_N8N_DIR}."
    fi
  fi

  # Lưu lại TUNNEL_ID trước khi xoá config (nếu có)
  local OLD_TUNNEL_ID=""
  if [ -f "$TUNNEL_CONFIG" ]; then
    OLD_TUNNEL_ID=$(grep '^tunnel:' "$TUNNEL_CONFIG" 2>/dev/null | awk '{print $2}' || true)
  fi

  # Tắt & xoá service cloudflared-n8n
  echo "▶ Dừng & xoá systemd service cloudflared-n8n..."
  if systemctl list-unit-files | grep -q "^cloudflared-n8n.service"; then
    systemctl stop cloudflared-n8n.service 2>/dev/null || true
    systemctl disable cloudflared-n8n.service 2>/dev/null || true
  fi
  rm -f "$TUNNEL_SERVICE" "$TUNNEL_CONFIG"
  systemctl daemon-reload

  echo
  echo "⚠ Về Cloudflare Tunnel & DNS:"
  echo "   - Script KHÔNG tự xoá tunnel trên Cloudflare, cũng KHÔNG xoá CNAME DNS."
  echo "   - Nếu muốn xoá tunnel, bạn có thể chạy (trên máy chủ này):"
  echo "       cloudflared tunnel list"
  echo "       cloudflared tunnel delete <name-hoặc-id>"
  if [[ -n "$OLD_TUNNEL_ID" ]]; then
    echo "     (Tunnel ID từng dùng trong config: ${OLD_TUNNEL_ID})"
  fi
  echo "   - Sau đó, hãy vào Cloudflare Dashboard để xoá CNAME n8n (vd: ${DEFAULT_N8N_HOST}) nếu không dùng nữa."

  echo
  echo "✅ Đã gỡ n8n (container) + service cloudflared-n8n trên máy chủ."
}

########################################
# MENU CHÍNH
########################################

while true; do
  echo "=============================="
  echo " n8n MANAGER + CLOUDFLARE TUNNEL"
  echo "=============================="
  echo "1) Cài / cập nhật n8n + tunnel"
  echo "2) Kiểm tra trạng thái n8n + tunnel"
  echo "3) Gỡ n8n + service + (tuỳ chọn) xoá data"
  echo "0) Thoát"
  echo "=============================="
  read -rp "Chọn chức năng (0-3): " CHOICE
  case "$CHOICE" in
    1) install_or_update_n8n ;;
    2) status_n8n ;;
    3) uninstall_n8n ;;
    0) echo "Bye ~"; exit 0 ;;
    *) echo "❌ Lựa chọn không hợp lệ."; sleep 1 ;;
  esac
done
