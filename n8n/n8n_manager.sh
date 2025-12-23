#!/usr/bin/env bash
set -euo pipefail

# ==============================
# n8n MANAGER + CLOUDFLARE TUNNEL
# ==============================

DEFAULT_HOST="n8n.rawcode.io"
DEFAULT_TUNNEL_NAME="n8n-tunnel"
DEFAULT_INSTALL_DIR="/opt/n8n"
DEFAULT_TZ="Asia/Ho_Chi_Minh"
DEFAULT_DB_NAME="n8n"
DEFAULT_DB_USER="n8n"
DEFAULT_N8N_IMAGE="docker.n8n.io/n8nio/n8n"
DATA_DIR="/root/.n8n"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
CF_CONFIG_FILE="/etc/cloudflared/n8n-tunnel.yml"
CF_SERVICE_NAME="cloudflared-n8n.service"

DOCKER_COMPOSE_CMD=""

N8N_TUNNEL_ID=""
N8N_TUNNEL_CREDS=""

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "❌ Vui lòng chạy script với quyền root (sudo)."
    exit 1
  fi
}

choose_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD="docker compose"
  elif docker-compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD="docker-compose"
  else
    echo "❌ Không tìm thấy 'docker compose' hoặc 'docker-compose'."
    exit 1
  fi
}

install_dependencies() {
  echo "▶ Cập nhật hệ thống & cài gói phụ thuộc..."
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y curl ca-certificates gnupg lsb-release wget jq >/dev/null 2>&1 || true
}

ensure_cloudflared_login() {
  if [[ ! -x "$CLOUDFLARED_BIN" ]]; then
    echo "▶ Cài đặt cloudflared..."
    curl -sSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o "$CLOUDFLARED_BIN"
    chmod +x "$CLOUDFLARED_BIN"
  fi

  if [[ ! -f /root/.cloudflared/cert.pem ]]; then
    echo "ℹ️ Chưa có cert Cloudflare tại /root/.cloudflared/cert.pem"
    echo "   → Vui lòng chạy:  cloudflared tunnel login"
    echo "   rồi chạy lại script sau khi đã link tài khoản Cloudflare."
    exit 1
  else
    echo "ℹ️ Đã có cert Cloudflare tại /root/.cloudflared/cert.pem, bỏ qua bước 'cloudflared tunnel login'."
  fi
}

ensure_data_dir() {
  echo "▶ Đảm bảo thư mục data '$DATA_DIR' tồn tại..."
  mkdir -p "$DATA_DIR"
  chown 1000:1000 "$DATA_DIR"
  chmod 700 "$DATA_DIR"
}

ensure_tunnel() {
  local TUNNEL_NAME="$1"
  N8N_TUNNEL_ID=""
  N8N_TUNNEL_CREDS=""

  echo "▶ Đảm bảo tunnel '$TUNNEL_NAME' tồn tại..."

  # Kiểm tra tunnel đã tồn tại chưa
  if "$CLOUDFLARED_BIN" tunnel list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$TUNNEL_NAME"; then
    echo "ℹ️ Tunnel '$TUNNEL_NAME' đã tồn tại, dùng lại."
    N8N_TUNNEL_ID=$("$CLOUDFLARED_BIN" tunnel list 2>/dev/null | awk -v name="$TUNNEL_NAME" 'NR>1 && $2==name {print $1; exit}')
  else
    echo "▶ Tạo tunnel mới '$TUNNEL_NAME'..."
    local create_output
    create_output=$("$CLOUDFLARED_BIN" tunnel create "$TUNNEL_NAME" 2>&1)
    echo "$create_output"

    # Lấy ID từ dòng "Created tunnel ..."
    N8N_TUNNEL_ID=$(printf '%s\n' "$create_output" | awk '/Created tunnel/ {print $NF}' | tail -n 1)

    if [[ -z "${N8N_TUNNEL_ID:-}" ]]; then
      echo "❌ Không lấy được Tunnel ID từ output 'cloudflared tunnel create'."
      exit 1
    fi
  fi

  if [[ -z "${N8N_TUNNEL_ID:-}" ]]; then
    echo "❌ Không xác định được Tunnel ID cho '$TUNNEL_NAME'."
    exit 1
  fi

  # Tìm credentials-file
  if ls /root/.cloudflared/"$N8N_TUNNEL_ID"*.json >/dev/null 2>&1; then
    N8N_TUNNEL_CREDS=$(ls /root/.cloudflared/"$N8N_TUNNEL_ID"*.json | head -n 1)
  elif ls /root/.cloudflared/"$TUNNEL_NAME"*.json >/dev/null 2>&1; then
    N8N_TUNNEL_CREDS=$(ls /root/.cloudflared/"$TUNNEL_NAME"*.json | head -n 1)
  fi

  if [[ -z "${N8N_TUNNEL_CREDS:-}" ]]; then
    echo "❌ Không tìm thấy credentials-file cho tunnel $N8N_TUNNEL_ID trong /root/.cloudflared"
    exit 1
  fi

  echo "   → Tunnel ID:   $N8N_TUNNEL_ID"
  echo "   → Credentials: $N8N_TUNNEL_CREDS"
}

write_cf_config_and_service() {
  local HOST="$1"

  echo "▶ Ghi file config tunnel: $CF_CONFIG_FILE"
  mkdir -p /etc/cloudflared

  cat >"$CF_CONFIG_FILE" <<EOF
tunnel: $N8N_TUNNEL_ID
credentials-file: $N8N_TUNNEL_CREDS

ingress:
  - hostname: $HOST
    service: http://127.0.0.1:5678
  - service: http_status:404
EOF

  echo "▶ Ghi systemd service: /etc/systemd/system/$CF_SERVICE_NAME"

  cat >/etc/systemd/system/"$CF_SERVICE_NAME" <<EOF
[Unit]
Description=Cloudflare Tunnel - $DEFAULT_TUNNEL_NAME ($HOST)
After=network.target

[Service]
Type=simple
ExecStart=$CLOUDFLARED_BIN --no-autoupdate --config $CF_CONFIG_FILE tunnel run
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$CF_SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl restart "$CF_SERVICE_NAME"

  echo "✅ Cloudflare Tunnel đã chạy. Kiểm tra nhanh:"
  systemctl --no-pager --full -n 5 status "$CF_SERVICE_NAME" || true
}

create_docker_compose() {
  local INSTALL_DIR="$1"
  local HOST="$2"
  local TZ="$3"
  local DB_NAME="$4"
  local DB_USER="$5"
  local DB_PASS="$6"
  local N8N_IMAGE="$7"

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
      - N8N_HOST=$HOST
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=https://$HOST/
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
}

install_or_update_n8n_with_tunnel() {
  echo
  echo "=== CÀI ĐẶT / CẬP NHẬT n8n + PostgreSQL + Cloudflare Tunnel ==="

  read -rp "Hostname cho n8n [$DEFAULT_HOST]: " N8N_HOST
  N8N_HOST=${N8N_HOST:-$DEFAULT_HOST}

  read -rp "Tên tunnel [$DEFAULT_TUNNEL_NAME]: " TUNNEL_NAME
  TUNNEL_NAME=${TUNNEL_NAME:-$DEFAULT_TUNNEL_NAME}

  read -rp "Thư mục cài n8n [$DEFAULT_INSTALL_DIR]: " INSTALL_DIR
  INSTALL_DIR=${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}

  read -rp "Timezone [$DEFAULT_TZ]: " TZ
  TZ=${TZ:-$DEFAULT_TZ}

  read -rp "Tên database PostgreSQL [$DEFAULT_DB_NAME]: " DB_NAME
  DB_NAME=${DB_NAME:-$DEFAULT_DB_NAME}

  read -rp "User database PostgreSQL [$DEFAULT_DB_USER]: " DB_USER
  DB_USER=${DB_USER:-$DEFAULT_DB_USER}

  echo "ℹ️ Lưu ý: khi nhập mật khẩu DB, terminal sẽ KHÔNG hiện ký tự."

  local DB_PASS DB_PASS2
  while true; do
    read -rs -p "Mật khẩu database PostgreSQL: " DB_PASS
    echo
    read -rs -p "Nhập lại mật khẩu PostgreSQL: " DB_PASS2
    echo
    if [[ -z "$DB_PASS" ]]; then
      echo "❌ Mật khẩu không được để trống."
      continue
    fi
    if [[ "$DB_PASS" != "$DB_PASS2" ]]; then
      echo "❌ Mật khẩu không khớp, nhập lại."
      continue
    fi
    break
  done

  read -rp "Image n8n [$DEFAULT_N8N_IMAGE]: " N8N_IMAGE
  N8N_IMAGE=${N8N_IMAGE:-$DEFAULT_N8N_IMAGE}

  echo
  echo "📌 Tóm tắt:"
  echo "   - Hostname:       $N8N_HOST"
  echo "   - Tunnel name:    $TUNNEL_NAME"
  echo "   - Install dir:    $INSTALL_DIR"
  echo "   - Timezone:       $TZ"
  echo "   - DB:             $DB_NAME"
  echo "   - DB user:        $DB_USER"
  echo "   - n8n image:      $N8N_IMAGE"
  echo "   - Service name:   $CF_SERVICE_NAME"
  echo "   - Data dir:       $DATA_DIR (mount vào /home/node/.n8n)"
  echo "   * Nếu đã cài trước đó, KHÔNG nên đổi DB password nếu chưa xoá volume DB."
  echo

  read -rp "Tiếp tục cài đặt? [y/N]: " CONFIRM
  CONFIRM=${CONFIRM:-N}
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "❌ Huỷ cài đặt."
    return
  fi

  install_dependencies
  choose_compose_cmd
  ensure_data_dir

  create_docker_compose "$INSTALL_DIR" "$N8N_HOST" "$TZ" "$DB_NAME" "$DB_USER" "$DB_PASS" "$N8N_IMAGE"

  echo "▶ Triển khai stack n8n + PostgreSQL (dùng Postgres 16, data mount $DATA_DIR)..."
  (
    cd "$INSTALL_DIR"
    $DOCKER_COMPOSE_CMD up -d
  )

  echo "✅ n8n đã khởi động (local): http://127.0.0.1:5678"
  echo "   (Đợi vài giây cho container n8n & postgres ổn định...)"
  sleep 5

  if command -v curl >/dev/null 2>&1; then
    local HTTP_CODE
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:5678" || echo "000")
    echo "▶ Thử curl từ local tới n8n: HTTP code: $HTTP_CODE"
  fi

  ensure_cloudflared_login
  ensure_tunnel "$TUNNEL_NAME"

  echo "▶ Tạo / cập nhật DNS record cho $N8N_HOST..."
  local ROUTE_OUTPUT
  set +e
  ROUTE_OUTPUT=$("$CLOUDFLARED_BIN" tunnel route dns "$N8N_TUNNEL_ID" "$N8N_HOST" 2>&1)
  local ROUTE_EXIT=$?
  set -e
  echo "$ROUTE_OUTPUT"
  if [[ $ROUTE_EXIT -ne 0 ]]; then
    echo "⚠ Không tạo được DNS tự động. Có thể CNAME đã tồn tại hoặc conflict."
    echo "   → Hãy vào Cloudflare Dashboard kiểm tra record cho $N8N_HOST,"
    echo "     đảm bảo nó trỏ về tunnel có ID: $N8N_TUNNEL_ID"
  else
    echo "   → Đã tạo/cập nhật CNAME cho $N8N_HOST (tunnelID=$N8N_TUNNEL_ID)."
  fi

  write_cf_config_and_service "$N8N_HOST"

  echo
  echo "🎉 HOÀN TẤT CÀI n8n + TUNNEL!"
  echo "   - n8n qua Cloudflare:  https://$N8N_HOST"
  echo "   - Local:               http://127.0.0.1:5678"
  echo
  echo "Lần đầu vào UI n8n, bạn sẽ tạo user owner."
}

show_status() {
  echo
  echo "=== TRẠNG THÁI n8n + TUNNEL ==="
  choose_compose_cmd || true

  echo
  echo "▶ Docker containers (liên quan n8n):"
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "n8n|n8n-postgres" || echo "Không có container n8n đang chạy."

  echo
  echo "▶ Systemd service: $CF_SERVICE_NAME"
  if systemctl list-unit-files | grep -q "$CF_SERVICE_NAME"; then
    systemctl --no-pager --full -n 5 status "$CF_SERVICE_NAME" || true
  else
    echo "Không có (hoặc service đang failed) $CF_SERVICE_NAME"
  fi

  echo
  echo "▶ Danh sách tunnel có chữ 'n8n':"
  if command -v "$CLOUDFLARED_BIN" >/dev/null 2>&1; then
    "$CLOUDFLARED_BIN" tunnel list 2>/dev/null | grep -i "n8n" || echo "Không có tunnel tên chứa 'n8n'."
  else
    echo "cloudflared chưa cài hoặc không tìm thấy."
  fi

  if command -v curl >/dev/null 2>&1; then
    echo
    echo "▶ Thử curl từ local tới n8n:"
    local HTTP_CODE
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:5678" || echo "000")
    echo "HTTP code: $HTTP_CODE"
  fi
}

remove_n8n() {
  echo
  echo "=== GỠ n8n + Cloudflare Tunnel (local) ==="
  read -rp "Bạn chắc chắn muốn gỡ n8n (container + service tunnel local)? [y/N]: " CONFIRM
  CONFIRM=${CONFIRM:-N}
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "❌ Huỷ gỡ n8n."
    return
  fi

  choose_compose_cmd || true

  echo "▶ Dừng & xoá container n8n / n8n-postgres (nếu có)..."
  if [[ -f "$DEFAULT_INSTALL_DIR/docker-compose.yml" ]]; then
    ( cd "$DEFAULT_INSTALL_DIR" && $DOCKER_COMPOSE_CMD down ) || true
  fi
  docker rm -f n8n n8n-postgres >/dev/null 2>&1 || true

  echo "▶ Dừng & xoá systemd service $CF_SERVICE_NAME..."
  if systemctl list-unit-files | grep -q "$CF_SERVICE_NAME"; then
    systemctl stop "$CF_SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$CF_SERVICE_NAME" >/dev/null 2>&1 || true
  fi

  # Hỏi xoá data dir
  if [[ -d "$DATA_DIR" ]]; then
    read -rp "Bạn có muốn XOÁ thư mục data '$DATA_DIR' (mất toàn bộ workflows, credentials, settings)? [y/N]: " DEL_DATA
    DEL_DATA=${DEL_DATA:-N}
    if [[ "$DEL_DATA" =~ ^[Yy]$ ]]; then
      rm -rf "$DATA_DIR"
      echo "   → Đã xoá thư mục $DATA_DIR."
    fi
  fi

  # Hỏi xoá install dir
  if [[ -d "$DEFAULT_INSTALL_DIR" ]]; then
    read -rp "Bạn có muốn XOÁ thư mục cài đặt '$DEFAULT_INSTALL_DIR' (docker-compose.yml, env...)? [y/N]: " DEL_INSTALL
    DEL_INSTALL=${DEL_INSTALL:-N}
    if [[ "$DEL_INSTALL" =~ ^[Yy]$ ]]; then
      rm -rf "$DEFAULT_INSTALL_DIR"
      echo "   → Đã xoá thư mục $DEFAULT_INSTALL_DIR."
    fi
  fi

  # Hỏi xoá volume Postgres
  local VOLUMES
  VOLUMES=$(docker volume ls --format '{{.Name}}' | grep -E '^n8n_postgres_data$|^n8n_n8n_postgres_data$' || true)
  if [[ -n "$VOLUMES" ]]; then
    echo "Các Docker volume Postgres liên quan đến n8n được tìm thấy:"
    echo "$VOLUMES" | sed 's/^/   - /'
    read -rp "Bạn có muốn XOÁ các volume này (XOÁ TOÀN BỘ DB n8n)? [y/N]: " DEL_VOL
    DEL_VOL=${DEL_VOL:-N}
    if [[ "$DEL_VOL" =~ ^[Yy]$ ]]; then
      echo "$VOLUMES" | xargs -r docker volume rm
    fi
  fi

  # Tunnel & config
  if [[ -f "$CF_CONFIG_FILE" ]]; then
    echo
    echo "▶ Thông tin tunnel từ file cấu hình $CF_CONFIG_FILE:"
    local CFG_TUNNEL_ID CFG_TUNNEL_NAME
    CFG_TUNNEL_ID=$(awk '/^tunnel:/ {print $2; exit}' "$CF_CONFIG_FILE" || true)
    CFG_TUNNEL_NAME="(không rõ)"

    if [[ -n "$CFG_TUNNEL_ID" ]] && command -v "$CLOUDFLARED_BIN" >/dev/null 2>&1; then
      CFG_TUNNEL_NAME=$("$CLOUDFLARED_BIN" tunnel list 2>/dev/null | awk -v id="$CFG_TUNNEL_ID" 'NR>1 && $1==id {print $2; exit}')
    fi

    echo "   - Tunnel ID:   ${CFG_TUNNEL_ID:-unknown}"
    echo "   - Tunnel name: $CFG_TUNNEL_NAME"

    if [[ -n "$CFG_TUNNEL_ID" ]] && command -v "$CLOUDFLARED_BIN" >/dev/null 2>&1; then
      read -rp "Bạn có muốn XOÁ Cloudflare Tunnel '$CFG_TUNNEL_ID' khỏi account Cloudflare (cloudflared tunnel delete)? [y/N]: " DEL_TUNNEL
      DEL_TUNNEL=${DEL_TUNNEL:-N}
      if [[ "$DEL_TUNNEL" =~ ^[Yy]$ ]]; then
        "$CLOUDFLARED_BIN" tunnel delete "$CFG_TUNNEL_ID" || true
      fi
    fi

    read -rp "Bạn có muốn XOÁ file cấu hình local '$CF_CONFIG_FILE'? [y/N]: " DEL_CF_CFG
    DEL_CF_CFG=${DEL_CF_CFG:-N}
    if [[ "$DEL_CF_CFG" =~ ^[Yy]$ ]]; then
      rm -f "$CF_CONFIG_FILE"
      echo "   → Đã xoá file cấu hình tunnel local."
    fi
  fi

  echo
  echo "⚠ Về Cloudflare DNS:"
  echo "   - Script KHÔNG tự xoá CNAME DNS trên Cloudflare."
  echo "   - Sau khi xoá tunnel (nếu có), hãy vào Cloudflare Dashboard để xoá record CNAME tương ứng (ví dụ: $DEFAULT_HOST) nếu không dùng nữa."
  echo
  echo "✅ Đã gỡ n8n (container) + service $CF_SERVICE_NAME trên máy chủ (tuỳ chọn xoá data như bạn đã chọn)."
}

update_n8n_only() {
  echo
  echo "=== UPDATE n8n (pull image mới nhất, giữ data) ==="

  if [[ ! -f "$DEFAULT_INSTALL_DIR/docker-compose.yml" ]]; then
    echo "❌ Không tìm thấy $DEFAULT_INSTALL_DIR/docker-compose.yml."
    echo "   → Có vẻ n8n chưa được cài bằng script này."
    return
  fi

  choose_compose_cmd

  echo "▶ Pull image mới nhất..."
  (
    cd "$DEFAULT_INSTALL_DIR"
    $DOCKER_COMPOSE_CMD pull n8n
  )

  echo "▶ Khởi động lại stack n8n (giữ nguyên volume & data)..."
  (
    cd "$DEFAULT_INSTALL_DIR"
    $DOCKER_COMPOSE_CMD up -d
  )

  echo "✅ Đã update n8n (image mới nhất) và khởi động lại."
  echo "   Data (Postgres + /root/.n8n) vẫn được giữ nguyên."
}

show_menu() {
  echo "=============================="
  echo " n8n MANAGER + CLOUDFLARE TUNNEL"
  echo "=============================="
  echo "1) Cài / cập nhật n8n + tunnel"
  echo "2) Kiểm tra trạng thái n8n + tunnel"
  echo "3) Gỡ n8n + service + (tuỳ chọn) xoá data & volume & tunnel"
  echo "4) Update n8n (pull image mới nhất, giữ data)"
  echo "0) Thoát"
  echo "=============================="
}

main() {
  require_root

  while true; do
    show_menu
    read -rp "Chọn chức năng (0-4): " CHOICE
    case "$CHOICE" in
      1) install_or_update_n8n_with_tunnel ;;
      2) show_status ;;
      3) remove_n8n ;;
      4) update_n8n_only ;;
      0) exit 0 ;;
      *) echo "Lựa chọn không hợp lệ."; sleep 1 ;;
    esac
  done
}

main "$@"
