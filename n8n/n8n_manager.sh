#!/usr/bin/env bash
set -euo pipefail

### ============================
###  HÀM CHUNG
### ============================

require_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "❌ Vui lòng chạy script với quyền root (sudo su hoặc sudo ./n8n_manager.sh)"
    exit 1
  fi
}

dc() {
  # Wrapper cho docker compose / docker-compose
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  else
    docker-compose "$@"
  fi
}

ensure_base_packages() {
  echo "▶ Cập nhật hệ thống & cài gói phụ thuộc..."
  apt update -y
  apt install -y curl ca-certificates gnupg lsb-release wget >/dev/null 2>&1 || true
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "⚠ Không tìm thấy docker, tiến hành cài đặt Docker CE..."
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
    apt install -y docker-ce docker-ce-cli containerd.io >/dev/null 2>&1
  fi

  # docker compose plugin / binary
  if ! docker compose version >/dev/null 2>&1; then
    if ! command -v docker-compose >/dev/null 2>&1; then
      echo "▶ Cài docker-compose..."
      apt install -y docker-compose >/dev/null 2>&1 || true
    fi
  fi

  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker >/dev/null 2>&1 || true
}

ensure_cloudflared() {
  if ! command -v cloudflared >/dev/null 2>&1; then
    echo "▶ Cài cloudflared..."
    cd /tmp
    curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb
    dpkg -i cloudflared.deb || apt -f install -y
  fi

  if [ ! -f /root/.cloudflared/cert.pem ]; then
    echo
    echo "🔑 Cần login Cloudflare một lần để cấp quyền cho cloudflared."
    echo "   - Lệnh sau sẽ in ra 1 URL."
    echo "   - Copy URL, mở trong browser, đăng nhập Cloudflare."
    echo "   - Chọn zone chứa domain n8n (ví dụ: rawcode.io)."
    echo
    read -rp "Nhấn Enter để chạy 'cloudflared tunnel login'..." _
    cloudflared tunnel login
  else
    echo "ℹ️ Đã có cert Cloudflare tại /root/.cloudflared/cert.pem, bỏ qua bước 'cloudflared tunnel login'."
  fi
}

### ============================
###  HÀM N8N + DOCKER
### ============================

write_n8n_compose() {
  local install_dir="$1"
  local db_name="$2"
  local db_user="$3"
  local db_pass="$4"
  local timezone="$5"
  local n8n_image="$6"
  local n8n_host="$7"

  mkdir -p "$install_dir"

  cat >"$install_dir/docker-compose.yml" <<EOF
services:
  n8n-postgres:
    image: postgres:15
    container_name: n8n-postgres
    restart: always
    environment:
      - POSTGRES_USER=${db_user}
      - POSTGRES_PASSWORD=${db_pass}
      - POSTGRES_DB=${db_name}
    volumes:
      - n8n_db_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${db_user} -d ${db_name}"]
      interval: 10s
      timeout: 5s
      retries: 5

  n8n:
    image: ${n8n_image}
    container_name: n8n
    restart: always
    ports:
      - "127.0.0.1:5678:5678"
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=n8n-postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=${db_name}
      - DB_POSTGRESDB_USER=${db_user}
      - DB_POSTGRESDB_PASSWORD=${db_pass}
      - N8N_HOST=${n8n_host}
      - N8N_PORT=5678
      - N8N_PROTOCOL=http
      - N8N_BASIC_AUTH_ACTIVE=false
      - N8N_DIAGNOSTICS_ENABLED=false
      - N8N_USER_MANAGEMENT_DISABLED=false
      - TZ=${timezone}
    depends_on:
      n8n-postgres:
        condition: service_healthy
    volumes:
      - n8n_data:/home/node/.n8n

volumes:
  n8n_data:
  n8n_db_data:
EOF
}

deploy_n8n_stack() {
  local install_dir="$1"

  echo "▶ Triển khai stack n8n + PostgreSQL (dùng Docker volumes)..."
  cd "$install_dir"
  dc up -d

  sleep 5
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5678 || echo "000")
  if [ "$code" != "200" ] && [ "$code" != "302" ]; then
    echo "⚠ n8n chưa trả 200/302 (HTTP code hiện tại: $code). Có thể vẫn đang khởi động."
  fi
  echo "✅ n8n đã khởi động (local): http://127.0.0.1:5678"
}

### ============================
###  HÀM CLOUDFLARE TUNNEL
### ============================

# Kết quả sẽ ghi vào biến global:
#   N8N_TUNNEL_ID
#   N8N_TUNNEL_CRED
ensure_tunnel_for_app() {
  local tunnel_name="$1"

  echo "▶ Đảm bảo tunnel '${tunnel_name}' tồn tại..."
  local existing_id
  existing_id=$(cloudflared tunnel list 2>/dev/null | awk -v name="$tunnel_name" '$2 == name {print $1}' | head -n1 || true)

  if [ -z "$existing_id" ]; then
    echo "▶ Tạo tunnel mới '${tunnel_name}'..."
    cloudflared tunnel create "$tunnel_name"
    existing_id=$(cloudflared tunnel list 2>/dev/null | awk -v name="$tunnel_name" '$2 == name {print $1}' | head -n1 || true)
  else
    echo "ℹ️ Tunnel '${tunnel_name}' đã tồn tại, dùng lại."
  fi

  if [ -z "$existing_id" ]; then
    echo "❌ Không lấy được Tunnel ID cho '${tunnel_name}'."
    exit 1
  fi

  local cred="/root/.cloudflared/${existing_id}.json"
  if [ ! -f "$cred" ]; then
    # fallback: file json mới nhất
    cred=$(ls -t /root/.cloudflared/*.json 2>/dev/null | head -n1 || true)
  fi

  if [ -z "$cred" ] || [ ! -f "$cred" ]; then
    echo "❌ Không tìm thấy credentials file (.json) cho tunnel '${tunnel_name}'."
    exit 1
  fi

  N8N_TUNNEL_ID="$existing_id"
  N8N_TUNNEL_CRED="$cred"

  echo "   → Tunnel ID:   ${N8N_TUNNEL_ID}"
  echo "   → Credentials: ${N8N_TUNNEL_CRED}"
}

write_n8n_tunnel_config_and_service() {
  local n8n_host="$1"
  local tunnel_id="$2"
  local cred_file="$3"

  mkdir -p /etc/cloudflared

  local cfg="/etc/cloudflared/n8n-tunnel.yml"
  cat >"$cfg" <<EOF
tunnel: ${tunnel_id}
credentials-file: ${cred_file}

ingress:
  - hostname: ${n8n_host}
    service: http://127.0.0.1:5678
  - service: http_status:404
EOF
  echo "▶ Ghi file config tunnel: $cfg"

  local cf_bin
  cf_bin=$(command -v cloudflared || echo "/usr/local/bin/cloudflared")

  local svc="/etc/systemd/system/cloudflared-n8n.service"
  cat >"$svc" <<EOF
[Unit]
Description=Cloudflare Tunnel - n8n-tunnel (n8n)
After=network.target

[Service]
Type=simple
ExecStart=${cf_bin} --no-autoupdate --config /etc/cloudflared/n8n-tunnel.yml tunnel run
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

  echo "▶ Ghi systemd service: $svc"

  systemctl daemon-reload
  systemctl enable cloudflared-n8n.service >/dev/null 2>&1 || true
  systemctl restart cloudflared-n8n.service

  echo "✅ Cloudflare Tunnel đã chạy."
  systemctl status cloudflared-n8n.service --no-pager || true
}

route_dns_and_check() {
  local tunnel_id="$1"
  local n8n_host="$2"

  echo "▶ Tạo / cập nhật DNS record cho ${n8n_host} (dùng Tunnel ID)..."
  cloudflared tunnel route dns "$tunnel_id" "$n8n_host" || true

  # Cố gắng kiểm tra lại DNS sau khi route
  if ! command -v dig >/dev/null 2>&1; then
    apt install -y dnsutils >/dev/null 2>&1 || true
  fi

  if command -v dig >/dev/null 2>&1; then
    sleep 3
    local cname
    cname=$(dig +short "$n8n_host" | head -n1 || echo "")
    echo "   → DNS hiện tại của ${n8n_host}: ${cname:-<trống>}"

    local expected="${tunnel_id}.cfargotunnel.com."
    if printf '%s\n' "$cname" | grep -q "$tunnel_id.cfargotunnel.com"; then
      echo "✅ DNS của ${n8n_host} ĐÃ trỏ đúng tunnel (${tunnel_id})."
    else
      echo "⚠ CẢNH BÁO: DNS của ${n8n_host} KHÔNG trỏ tới ${expected}"
      echo "   - Hãy vào Cloudflare Dashboard → DNS,"
      echo "     chỉnh record CNAME:"
      echo "       Name  = $(echo "$n8n_host" | cut -d. -f1)"
      echo "       Type  = CNAME"
      echo "       Value = ${tunnel_id}.cfargotunnel.com"
      echo "       Proxy = Proxied (đám mây cam)"
    fi
  else
    echo "⚠ Không có lệnh 'dig', không kiểm tra được DNS tự động. Hãy kiểm tra bằng tay trên Cloudflare."
  fi
}

### ============================
###  ACTION 1: INSTALL / UPDATE
### ============================

install_or_update() {
  echo
  echo "=== CÀI ĐẶT / CẬP NHẬT n8n + PostgreSQL + Cloudflare Tunnel ==="

  read -rp "Hostname cho n8n [n8n.rawcode.io]: " N8N_HOST
  N8N_HOST=${N8N_HOST:-n8n.rawcode.io}

  read -rp "Tên tunnel [n8n-tunnel]: " TUNNEL_NAME
  TUNNEL_NAME=${TUNNEL_NAME:-n8n-tunnel}

  read -rp "Thư mục cài n8n [/opt/n8n]: " INSTALL_DIR
  INSTALL_DIR=${INSTALL_DIR:-/opt/n8n}

  read -rp "Timezone [Asia/Ho_Chi_Minh]: " TZ
  TZ=${TZ:-Asia/Ho_Chi_Minh}

  read -rp "Tên database PostgreSQL [n8n]: " DB_NAME
  DB_NAME=${DB_NAME:-n8n}

  read -rp "User database PostgreSQL [n8n]: " DB_USER
  DB_USER=${DB_USER:-n8n}

  local DB_PASS DB_PASS_CONFIRM
  while true; do
    read -srp "Mật khẩu database PostgreSQL: " DB_PASS
    echo
    read -srp "Nhập lại mật khẩu database PostgreSQL: " DB_PASS_CONFIRM
    echo
    if [ -n "$DB_PASS" ] && [ "$DB_PASS" = "$DB_PASS_CONFIRM" ]; then
      break
    fi
    echo "❌ Mật khẩu rỗng hoặc không khớp, hãy nhập lại."
  done

  read -rp "Image n8n [docker.n8n.io/n8nio/n8n]: " N8N_IMAGE
  N8N_IMAGE=${N8N_IMAGE:-docker.n8n.io/n8nio/n8n}

  echo
  echo "📌 Tóm tắt:"
  echo "   - Hostname:       $N8N_HOST"
  echo "   - Tunnel name:    $TUNNEL_NAME"
  echo "   - Install dir:    $INSTALL_DIR"
  echo "   - Timezone:       $TZ"
  echo "   - DB:             $DB_NAME"
  echo "   - DB user:        $DB_USER"
  echo "   - n8n image:      $N8N_IMAGE"
  echo "   - Service name:   cloudflared-n8n.service"
  echo
  read -rp "Tiếp tục cài đặt? [y/N]: " CONFIRM
  CONFIRM=${CONFIRM:-n}
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "⏹ Huỷ."
    return
  fi

  ensure_base_packages
  ensure_docker
  ensure_cloudflared

  write_n8n_compose "$INSTALL_DIR" "$DB_NAME" "$DB_USER" "$DB_PASS" "$TZ" "$N8N_IMAGE" "$N8N_HOST"
  deploy_n8n_stack "$INSTALL_DIR"

  ensure_tunnel_for_app "$TUNNEL_NAME"
  write_n8n_tunnel_config_and_service "$N8N_HOST" "$N8N_TUNNEL_ID" "$N8N_TUNNEL_CRED"
  route_dns_and_check "$N8N_TUNNEL_ID" "$N8N_HOST"

  echo
  echo "🎉 HOÀN TẤT CÀI n8n + TUNNEL!"
  echo "   - n8n qua Cloudflare:  https://${N8N_HOST}"
  echo "   - Local:               http://127.0.0.1:5678"
  echo
  echo "Lần đầu vào UI n8n, bạn sẽ tạo user owner."
}

### ============================
###  ACTION 2: STATUS
### ============================

show_status() {
  echo
  echo "=== TRẠNG THÁI n8n + TUNNEL ==="
  echo
  echo "▶ Docker containers (liên quan n8n):"
  docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E '^n8n|^n8n-postgres' || echo "Không thấy container n8n / n8n-postgres."

  echo
  echo "▶ Systemd service: cloudflared-n8n.service"
  if systemctl list-units --type=service --all | grep -q 'cloudflared-n8n.service'; then
    systemctl status cloudflared-n8n.service --no-pager || true
  else
    echo "Không có service cloudflared-n8n.service"
  fi

  echo
  echo "▶ Danh sách tunnel có chữ 'n8n':"
  cloudflared tunnel list 2>/dev/null | grep -i 'n8n' || echo "Không có tunnel nào chứa 'n8n'."

  echo
  echo "▶ Thử curl từ local tới n8n:"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5678 || echo "000")
  echo "HTTP code: $code"
}

### ============================
###  ACTION 3: UNINSTALL
### ============================

uninstall_all() {
  echo
  echo "=== GỠ n8n + TUNNEL ==="

  read -rp "Thư mục cài n8n hiện tại [/opt/n8n]: " INSTALL_DIR
  INSTALL_DIR=${INSTALL_DIR:-/opt/n8n}

  if [ -d "$INSTALL_DIR" ] && [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
    echo "▶ Dừng stack Docker n8n..."
    cd "$INSTALL_DIR"
    dc down || true
  else
    echo "ℹ️ Không tìm thấy docker-compose.yml trong $INSTALL_DIR, bỏ qua bước docker down."
  fi

  echo "▶ Dừng & disable service cloudflared-n8n..."
  if systemctl list-units --type=service --all | grep -q 'cloudflared-n8n.service'; then
    systemctl disable --now cloudflared-n8n.service || true
    rm -f /etc/systemd/system/cloudflared-n8n.service
    systemctl daemon-reload
  fi

  if [ -f /etc/cloudflared/n8n-tunnel.yml ]; then
    echo "▶ Xoá file config /etc/cloudflared/n8n-tunnel.yml"
    rm -f /etc/cloudflared/n8n-tunnel.yml
  fi

  read -rp "Bạn có muốn xoá luôn Docker volumes (n8n_data, n8n_db_data)? [y/N]: " RM_VOL
  RM_VOL=${RM_VOL:-n}
  if [[ "$RM_VOL" =~ ^[Yy]$ ]]; then
    docker volume rm n8n_data n8n_db_data 2>/dev/null || true
  fi

  read -rp "Bạn có muốn xoá luôn tunnel 'n8n-tunnel' khỏi Cloudflare? [y/N]: " RM_TUNNEL
  RM_TUNNEL=${RM_TUNNEL:-n}
  if [[ "$RM_TUNNEL" =~ ^[Yy]$ ]]; then
    cloudflared tunnel delete n8n-tunnel || true
  fi

  echo "✅ Đã gỡ n8n + tunnel (tuỳ theo lựa chọn)."
}

### ============================
###  MAIN MENU
### ============================

require_root

while true; do
  echo "=============================="
  echo " n8n MANAGER + CLOUDFLARE TUNNEL"
  echo "=============================="
  echo "1) Cài / cập nhật n8n + tunnel"
  echo "2) Kiểm tra trạng thái n8n + tunnel"
  echo "3) Gỡ n8n + service + (tuỳ chọn) xoá tunnel"
  echo "0) Thoát"
  echo "=============================="
  read -rp "Chọn chức năng (0-3): " CHOICE

  case "$CHOICE" in
    1) install_or_update ;;
    2) show_status ;;
    3) uninstall_all ;;
    0) echo "Bye!"; exit 0 ;;
    *) echo "❌ Lựa chọn không hợp lệ." ;;
  esac

  echo
done
