#!/usr/bin/env bash
set -euo pipefail

### ============================
###  HÀM CHUNG
### ============================

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "❌ Vui lòng chạy script với quyền root (sudo su hoặc sudo ./n8n_manager.sh)"
    exit 1
  fi
}

ensure_packages() {
  echo "▶ Cập nhật hệ thống & cài gói phụ thuộc..."
  apt update -y
  apt install -y curl ca-certificates gnupg lsb-release wget
}

ensure_docker() {
  if ! command -v docker &>/dev/null; then
    echo "⚠ Không tìm thấy docker, tiến hành cài đặt Docker CE..."
    install -m 0755 -d /etc/apt/keyrings
    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
    fi
    if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
      echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
        $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    fi
    apt update -y
    apt install -y docker-ce docker-ce-cli containerd.io
  fi

  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker
}

ensure_compose_cmd() {
  if docker compose version &>/dev/null; then
    COMPOSE_CMD="docker compose"
  elif command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
  else
    echo "⚠ Không tìm thấy docker compose, tiến hành cài docker-compose..."
    apt install -y docker-compose
    COMPOSE_CMD="docker-compose"
  fi
}

ensure_cloudflared() {
  if ! command -v cloudflared &>/dev/null; then
    echo "▶ Cài đặt cloudflared..."
    cd /tmp
    curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb
    dpkg -i cloudflared.deb || apt -f install -y
  fi
}

### ============================
###  HÀM CLOUDFLARE TUNNEL
### ============================

ensure_cf_cert() {
  local CERT="/root/.cloudflared/cert.pem"
  if [ -f "$CERT" ]; then
    echo "ℹ️ Đã có cert Cloudflare tại $CERT, bỏ qua bước 'cloudflared tunnel login'."
  else
    echo
    echo "🔑 Bước tiếp theo: ĐĂNG NHẬP CLOUDFLARE ĐỂ CẤP QUYỀN CHO TUNNEL."
    echo "   - Lệnh sau sẽ in ra một URL."
    echo "   - Bạn copy URL đó, mở trong trình duyệt, đăng nhập Cloudflare."
    echo "   - Chọn zone chứa domain n8n."
    echo "   - Sau khi màn hình báo thành công, quay lại terminal."
    echo
    read -rp "Nhấn Enter để chạy 'cloudflared tunnel login'..." _
    cloudflared tunnel login
  fi
}

ensure_tunnel_exists() {
  local TUNNEL_NAME="$1"
  local EXISTING_ID

  # Tìm tunnel theo tên
  EXISTING_ID=$(cloudflared tunnel list 2>/dev/null | awk -v name="$TUNNEL_NAME" 'NR>3 && $2==name {print $1}' | head -n1 || true)

  if [ -n "$EXISTING_ID" ]; then
    echo "ℹ️ Tunnel '$TUNNEL_NAME' đã tồn tại, dùng lại." >&2
    echo "$EXISTING_ID"
    return 0
  fi

  echo "▶ Tạo tunnel mới '$TUNNEL_NAME'..." >&2
  cloudflared tunnel create "$TUNNEL_NAME" >/tmp/n8n_tunnel_create.log 2>&1 || true

  EXISTING_ID=$(cloudflared tunnel list 2>/dev/null | awk -v name="$TUNNEL_NAME" 'NR>3 && $2==name {print $1}' | head -n1 || true)

  if [ -z "$EXISTING_ID" ]; then
    echo "❌ Không lấy được Tunnel ID cho '$TUNNEL_NAME'. Xem /tmp/n8n_tunnel_create.log để debug." >&2
    exit 1
  fi

  echo "$EXISTING_ID"
}

get_cred_file_for_tunnel() {
  local TUNNEL_ID="$1"
  local CRED="/root/.cloudflared/${TUNNEL_ID}.json"

  if [ ! -f "$CRED" ]; then
    # fallback: lấy file .json mới nhất
    CRED=$(ls -t /root/.cloudflared/*.json 2>/dev/null | head -n1 || true)
  fi

  if [ -z "$CRED" ] || [ ! -f "$CRED" ]; then
    echo "❌ Không tìm thấy credentials file (.json) cho tunnel $TUNNEL_ID trong /root/.cloudflared" >&2
    exit 1
  fi

  echo "$CRED"
}

### ============================
###  CÀI/UPDATE n8n
### ============================

install_or_update_n8n() {
  echo
  echo "=== CÀI ĐẶT / CẬP NHẬT n8n + PostgreSQL + Cloudflare Tunnel ==="

  read -rp "Hostname cho n8n [n8n.rawcode.io]: " N8N_HOST
  N8N_HOST=${N8N_HOST:-n8n.rawcode.io}

  read -rp "Tên tunnel [n8n-tunnel]: " TUNNEL_NAME
  TUNNEL_NAME=${TUNNEL_NAME:-n8n-tunnel}

  read -rp "Thư mục cài n8n [/opt/n8n]: " INSTALL_DIR
  INSTALL_DIR=${INSTALL_DIR:-/opt/n8n}

  read -rp "Timezone [Asia/Ho_Chi_Minh]: " N8N_TZ
  N8N_TZ=${N8N_TZ:-Asia/Ho_Chi_Minh}

  read -rp "Tên database PostgreSQL [n8n]: " N8N_DB
  N8N_DB=${N8N_DB:-n8n}

  read -rp "User database PostgreSQL [n8n]: " N8N_DB_USER
  N8N_DB_USER=${N8N_DB_USER:-n8n}

  while true; do
    read -srp "Mật khẩu database PostgreSQL: " N8N_DB_PASS
    echo
    read -srp "Nhập lại mật khẩu database PostgreSQL: " N8N_DB_PASS_CONFIRM
    echo
    if [ -n "$N8N_DB_PASS" ] && [ "$N8N_DB_PASS" = "$N8N_DB_PASS_CONFIRM" ]; then
      break
    else
      echo "❌ Mật khẩu không khớp hoặc rỗng, hãy nhập lại."
    fi
  done

  read -rp "Image n8n [docker.n8n.io/n8nio/n8n]: " N8N_IMAGE
  N8N_IMAGE=${N8N_IMAGE:-docker.n8n.io/n8nio/n8n}

  local SERVICE_NAME="cloudflared-n8n.service"

  echo
  echo "📌 Tóm tắt:"
  echo "   - Hostname:       $N8N_HOST"
  echo "   - Tunnel name:    $TUNNEL_NAME"
  echo "   - Install dir:    $INSTALL_DIR"
  echo "   - Timezone:       $N8N_TZ"
  echo "   - DB:             $N8N_DB"
  echo "   - DB user:        $N8N_DB_USER"
  echo "   - n8n image:      $N8N_IMAGE"
  echo "   - Service name:   $SERVICE_NAME"
  echo
  read -rp "Tiếp tục cài đặt? [y/N]: " CONFIRM
  CONFIRM=${CONFIRM:-n}
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "⏹ Hủy."
    return 0
  fi

  ensure_packages
  ensure_docker
  ensure_compose_cmd
  ensure_cloudflared

  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"

  # Local files dir cho node File
  mkdir -p "${INSTALL_DIR}/local-files"

  echo "▶ Triển khai stack n8n + PostgreSQL (dùng Docker volumes)..."

  cat > "${INSTALL_DIR}/docker-compose.yml" <<EOF
services:
  n8n-postgres:
    image: postgres:15
    container_name: n8n-postgres
    restart: always
    environment:
      - POSTGRES_DB=${N8N_DB}
      - POSTGRES_USER=${N8N_DB_USER}
      - POSTGRES_PASSWORD=${N8N_DB_PASS}
    volumes:
      - n8n_postgres_data:/var/lib/postgresql/data

  n8n:
    image: ${N8N_IMAGE}
    container_name: n8n
    restart: always
    depends_on:
      - n8n-postgres
    ports:
      - "127.0.0.1:5678:5678"
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_DATABASE=${N8N_DB}
      - DB_POSTGRESDB_HOST=n8n-postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_USER=${N8N_DB_USER}
      - DB_POSTGRESDB_PASSWORD=${N8N_DB_PASS}
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
      - N8N_HOST=${N8N_HOST}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - N8N_EDITOR_BASE_URL=https://${N8N_HOST}/
      - WEBHOOK_URL=https://${N8N_HOST}/
      - N8N_RUNNERS_ENABLED=true
      - NODE_ENV=production
      - GENERIC_TIMEZONE=${N8N_TZ}
      - TZ=${N8N_TZ}
    volumes:
      - n8n_data:/home/node/.n8n
      - ${INSTALL_DIR}/local-files:/files

volumes:
  n8n_data:
  n8n_postgres_data:
EOF

  # Dừng stack cũ (nếu có)
  ${COMPOSE_CMD} -f "${INSTALL_DIR}/docker-compose.yml" down >/dev/null 2>&1 || true

  ${COMPOSE_CMD} -f "${INSTALL_DIR}/docker-compose.yml" up -d

  echo "✅ n8n đã khởi động (local): http://127.0.0.1:5678"

  ### CLOUDFLARE ###
  ensure_cf_cert

  echo "▶ Đảm bảo tunnel '${TUNNEL_NAME}' tồn tại..."
  local TUNNEL_ID
  TUNNEL_ID=$(ensure_tunnel_exists "$TUNNEL_NAME")
  echo "   → Tunnel ID:   $TUNNEL_ID"
  local CRED_FILE
  CRED_FILE=$(get_cred_file_for_tunnel "$TUNNEL_ID")
  echo "   → Credentials: $CRED_FILE"

  echo "▶ Tạo / cập nhật DNS record cho ${N8N_HOST}..."
  # Dùng tên tunnel (Cloudflare chấp nhận name hoặc UUID)
  cloudflared tunnel route dns "$TUNNEL_NAME" "$N8N_HOST" || true

  mkdir -p /etc/cloudflared

  local CF_CONF="/etc/cloudflared/n8n-tunnel.yml"

  echo "▶ Ghi file config tunnel: $CF_CONF"
  cat > "$CF_CONF" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CRED_FILE}

ingress:
  - hostname: ${N8N_HOST}
    service: http://127.0.0.1:5678
  - service: http_status:404
EOF

  local SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"

  echo "▶ Ghi systemd service: $SERVICE_FILE"
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Cloudflare Tunnel - ${TUNNEL_NAME} (n8n)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared --no-autoupdate --config ${CF_CONF} tunnel run
Restart=always
RestartSec=5s
User=root

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
  systemctl restart "$SERVICE_NAME"

  echo "✅ Cloudflare Tunnel đã chạy."
  systemctl status "$SERVICE_NAME" --no-pager || true

  echo
  echo "🎉 HOÀN TẤT CÀI n8n + TUNNEL!"
  echo "   - n8n qua Cloudflare:  https://${N8N_HOST}"
  echo "   - Local:               http://127.0.0.1:5678"
  echo
  echo "Lần đầu vào UI n8n, bạn sẽ tạo user owner."
}

### ============================
###  TRẠNG THÁI
### ============================

status_n8n() {
  echo
  echo "=== TRẠNG THÁI n8n + TUNNEL ==="
  echo

  echo "▶ Docker containers (liên quan n8n):"
  docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E '^n8n(\s|$)|^n8n-postgres(\s|$)' || echo "Không tìm thấy container n8n/n8n-postgres."

  echo
  echo "▶ Systemd service: cloudflared-n8n.service"
  systemctl status cloudflared-n8n.service --no-pager || echo "Không có (hoặc service đang failed) cloudflared-n8n.service"

  echo
  echo "▶ Danh sách tunnel có chữ 'n8n':"
  cloudflared tunnel list 2>/dev/null | (head -n 3; grep -i 'n8n' || true)

  echo
  echo "▶ Thử curl từ local tới n8n:"
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5678/ || echo "000")
  echo "HTTP code: $HTTP_CODE"
  if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "302" ] && [ "$HTTP_CODE" != "301" ]; then
    echo "⚠ Không curl được http://127.0.0.1:5678 (code $HTTP_CODE)"
  fi
}

### ============================
###  GỠ CÀI ĐẶT
### ============================

uninstall_n8n() {
  echo
  echo "=== GỠ n8n + service + (tùy chọn) xoá tunnel ==="

  read -rp "Thư mục cài n8n hiện tại [/opt/n8n]: " INSTALL_DIR
  INSTALL_DIR=${INSTALL_DIR:-/opt/n8n}

  if [ -f "${INSTALL_DIR}/docker-compose.yml" ]; then
    echo "▶ Dừng stack n8n..."
    ensure_compose_cmd
    ${COMPOSE_CMD} -f "${INSTALL_DIR}/docker-compose.yml" down || true
  fi

  echo "▶ Xoá containers đơn lẻ (nếu còn)..."
  docker rm -f n8n n8n-postgres 2>/dev/null || true

  echo "▶ Dừng & xoá service cloudflared-n8n..."
  systemctl stop cloudflared-n8n.service 2>/dev/null || true
  systemctl disable cloudflared-n8n.service 2>/dev/null || true
  rm -f /etc/systemd/system/cloudflared-n8n.service
  systemctl daemon-reload

  echo "▶ Xoá file config tunnel n8n..."
  rm -f /etc/cloudflared/n8n-tunnel.yml

  read -rp "Bạn có muốn xoá thư mục cài đặt ${INSTALL_DIR}? [y/N]: " RM_DIR
  RM_DIR=${RM_DIR:-n}
  if [[ "$RM_DIR" =~ ^[Yy]$ ]]; then
    rm -rf "${INSTALL_DIR}"
    echo "✅ Đã xoá thư mục ${INSTALL_DIR}"
  else
    echo "⏩ Giữ lại thư mục ${INSTALL_DIR}"
  fi

  read -rp "Bạn có muốn xoá tunnel 'n8n-tunnel' khỏi Cloudflare luôn không? [y/N]: " RM_TUN
  RM_TUN=${RM_TUN:-n}
  if [[ "$RM_TUN" =~ ^[Yy]$ ]]; then
    cloudflared tunnel delete n8n-tunnel || true
    echo "✅ Đã cố gắng xoá tunnel n8n-tunnel (nếu tồn tại)."
  else
    echo "⏩ Giữ lại tunnel n8n-tunnel trên Cloudflare."
  fi

  echo
  echo "🎉 Đã gỡ xong n8n + service cloudflared-n8n."
}

### ============================
###  MAIN MENU
### ============================

main_menu() {
  require_root
  echo "=============================="
  echo " n8n MANAGER + CLOUDFLARE TUNNEL"
  echo "=============================="
  echo "1) Cài / cập nhật n8n + tunnel"
  echo "2) Kiểm tra trạng thái n8n + tunnel"
  echo "3) Gỡ n8n + service + (tuỳ chọn) xoá tunnel"
  echo "0) Thoát"
  echo "=============================="
  read -rp "Chọn chức năng (0-3): " choice

  case "$choice" in
    1) install_or_update_n8n ;;
    2) status_n8n ;;
    3) uninstall_n8n ;;
    0) echo "Bye."; exit 0 ;;
    *) echo "❌ Lựa chọn không hợp lệ."; exit 1 ;;
  esac
}

main_menu
