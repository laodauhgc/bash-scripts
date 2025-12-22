#!/usr/bin/env bash
set -euo pipefail

# ==============================
#  n8n MANAGER + CLOUDFLARE TUNNEL
# ==============================

# --------- DEFAULTS ----------
N8N_DEFAULT_HOST="n8n.rawcode.io"
N8N_DEFAULT_TUNNEL_NAME="n8n-tunnel"
N8N_DEFAULT_INSTALL_DIR="/opt/n8n"
N8N_DEFAULT_TZ="Asia/Ho_Chi_Minh"
N8N_DEFAULT_DB_NAME="n8n"
N8N_DEFAULT_DB_USER="n8n"
N8N_DEFAULT_N8N_IMAGE="docker.n8n.io/n8nio/n8n"
N8N_DEFAULT_DB_IMAGE="postgres:16"
N8N_DATA_DIR="/root/.n8n"
CF_CONFIG_FILE="/etc/cloudflared/n8n-tunnel.yml"
CF_SERVICE_NAME="cloudflared-n8n.service"

# --------- HELPERS ----------

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "❌ Thiếu lệnh bắt buộc: $1. Hãy cài trước rồi chạy lại."
    exit 1
  fi
}

pause() {
  read -rp "Nhấn Enter để tiếp tục..." _
}

ensure_basic_packages() {
  echo "▶ Cập nhật hệ thống & cài gói phụ thuộc..."
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y curl ca-certificates gnupg lsb-release wget jq >/dev/null 2>&1 || true

  # Docker
  if ! command -v docker >/dev/null 2>&1; then
    echo "▶ Cài Docker..."
    curl -fsSL https://get.docker.com | sh
  fi

  # docker compose (plugin)
  if ! docker compose version >/dev/null 2>&1; then
    echo "❌ Docker Compose (plugin) chưa sẵn, kiểm tra lại Docker cài đặt."
    exit 1
  fi

  # cloudflared
  if ! command -v cloudflared >/dev/null 2>&1; then
    echo "▶ Cài cloudflared..."
    # Ubuntu 24.04 (noble) – repo chính thức
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared noble main" \
      | tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y cloudflared >/dev/null 2>&1 || true
  fi
}

ensure_cloudflare_login() {
  if [ ! -f /root/.cloudflared/cert.pem ]; then
    echo "ℹ️ Chưa thấy cert Cloudflare tại /root/.cloudflared/cert.pem."
    echo "   Sẽ chạy 'cloudflared tunnel login' để link account."
    cloudflared tunnel login
  else
    echo "ℹ️ Đã có cert Cloudflare tại /root/.cloudflared/cert.pem, bỏ qua bước login."
  fi
}

ensure_tunnel() {
  local TUNNEL_NAME="$1"
  local TUNNEL_ID

  # Tìm tunnel theo tên
  TUNNEL_ID=$(cloudflared tunnel list 2>/dev/null | awk -v name="$TUNNEL_NAME" '$2 == name {print $1}' | head -n1 || true)

  if [[ -z "${TUNNEL_ID:-}" ]]; then
    echo "▶ Tạo tunnel mới '${TUNNEL_NAME}'..."
    # lệnh này in ra dòng: Created tunnel <name> with id <uuid>
    local create_log
    create_log=$(cloudflared tunnel create "$TUNNEL_NAME" 2>&1)
    echo "$create_log"
    TUNNEL_ID=$(printf '%s\n' "$create_log" | awk '/Created tunnel/ {print $NF}' | tail -n1)
  else
    echo "ℹ️ Tunnel '${TUNNEL_NAME}' đã tồn tại, dùng lại."
  fi

  if [[ -z "${TUNNEL_ID:-}" ]]; then
    echo "❌ Không lấy được Tunnel ID. Kiểm tra lại cloudflared."
    exit 1
  fi

  echo "$TUNNEL_ID"
}

setup_dns() {
  local TUNNEL_NAME="$1"
  local HOST="$2"

  echo "▶ Tạo / cập nhật DNS record cho ${HOST}..."
  # --overwrite-dns để luôn map hostname này về đúng tunnel hiện tại
  if cloudflared tunnel route dns --overwrite-dns "$TUNNEL_NAME" "$HOST"; then
    echo "   → Đã tạo/cập nhật CNAME cho ${HOST}."
  else
    echo "⚠ Không tạo/cập nhật được DNS cho ${HOST}."
    echo "   Hãy kiểm tra thủ công trên Cloudflare Dashboard."
  fi
}

write_cloudflared_config_and_service() {
  local TUNNEL_ID="$1"
  local HOST="$2"

  mkdir -p "$(dirname "$CF_CONFIG_FILE")"

  echo "▶ Ghi file config tunnel: ${CF_CONFIG_FILE}"
  cat > "$CF_CONFIG_FILE" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: /root/.cloudflared/${TUNNEL_ID}.json

ingress:
  - hostname: ${HOST}
    service: http://127.0.0.1:5678
  - service: http_status:404
EOF

  echo "▶ Ghi systemd service: /etc/systemd/system/${CF_SERVICE_NAME}"
  cat > "/etc/systemd/system/${CF_SERVICE_NAME}" <<EOF
[Unit]
Description=Cloudflare Tunnel - n8n-tunnel (n8n)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/cloudflared --no-autoupdate --config ${CF_CONFIG_FILE} tunnel run
Restart=always
RestartSec=5s
User=root
Environment=LOGLEVEL=info

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${CF_SERVICE_NAME}"

  echo "✅ Cloudflare Tunnel đã chạy. Kiểm tra nhanh:"
  systemctl status "${CF_SERVICE_NAME}" --no-pager -n 5 || true
}

write_docker_compose() {
  local INSTALL_DIR="$1"
  local N8N_HOST="$2"
  local TZ="$3"
  local DB_NAME="$4"
  local DB_USER="$5"
  local DB_PASSWORD="$6"
  local N8N_IMAGE="$7"
  local DB_IMAGE="$8"

  mkdir -p "$INSTALL_DIR"

  # Làm sạch password: bỏ newline, escape dấu "
  DB_PASSWORD=$(printf '%s' "$DB_PASSWORD" | tr -d '\r\n')
  local DB_PASSWORD_ESCAPED
  DB_PASSWORD_ESCAPED=${DB_PASSWORD//\"/\\\"}

  echo "▶ Ghi file docker-compose.yml trong ${INSTALL_DIR}"
  cat > "${INSTALL_DIR}/docker-compose.yml" <<EOF
services:
  n8n:
    image: ${N8N_IMAGE}
    container_name: n8n
    restart: unless-stopped
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: n8n-postgres
      DB_POSTGRESDB_PORT: "5432"
      DB_POSTGRESDB_DATABASE: "${DB_NAME}"
      DB_POSTGRESDB_USER: "${DB_USER}"
      DB_POSTGRESDB_PASSWORD: "${DB_PASSWORD_ESCAPED}"
      N8N_HOST: "${N8N_HOST}"
      N8N_PORT: "5678"
      N8N_PROTOCOL: "https"
      WEBHOOK_URL: "https://${N8N_HOST}/"
      TZ: "${TZ}"
      GENERIC_TIMEZONE: "${TZ}"
      N8N_DIAGNOSTICS_ENABLED: "false"
    ports:
      - "127.0.0.1:5678:5678"
    volumes:
      - "${N8N_DATA_DIR}:/home/node/.n8n"
    depends_on:
      - n8n-postgres

  n8n-postgres:
    image: ${DB_IMAGE}
    container_name: n8n-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: "${DB_USER}"
      POSTGRES_PASSWORD: "${DB_PASSWORD_ESCAPED}"
      POSTGRES_DB: "${DB_NAME}"
      TZ: "${TZ}"
    volumes:
      - n8n_postgres_data:/var/lib/postgresql/data

volumes:
  n8n_postgres_data:
    name: n8n_postgres_data
EOF
}

install_or_update_n8n() {
  ensure_basic_packages
  require_cmd docker
  require_cmd cloudflared

  echo "=== CÀI ĐẶT / CẬP NHẬT n8n + PostgreSQL + Cloudflare Tunnel ==="

  read -rp "Hostname cho n8n [${N8N_DEFAULT_HOST}]: " N8N_HOST
  N8N_HOST=${N8N_HOST:-$N8N_DEFAULT_HOST}

  read -rp "Tên tunnel [${N8N_DEFAULT_TUNNEL_NAME}]: " TUNNEL_NAME
  TUNNEL_NAME=${TUNNEL_NAME:-$N8N_DEFAULT_TUNNEL_NAME}

  read -rp "Thư mục cài n8n [${N8N_DEFAULT_INSTALL_DIR}]: " INSTALL_DIR
  INSTALL_DIR=${INSTALL_DIR:-$N8N_DEFAULT_INSTALL_DIR}

  read -rp "Timezone [${N8N_DEFAULT_TZ}]: " TZ
  TZ=${TZ:-$N8N_DEFAULT_TZ}

  read -rp "Tên database PostgreSQL [${N8N_DEFAULT_DB_NAME}]: " DB_NAME
  DB_NAME=${DB_NAME:-$N8N_DEFAULT_DB_NAME}

  read -rp "User database PostgreSQL [${N8N_DEFAULT_DB_USER}]: " DB_USER
  DB_USER=${DB_USER:-$N8N_DEFAULT_DB_USER}

  echo "ℹ️ Lưu ý: khi nhập mật khẩu DB, terminal sẽ KHÔNG hiện ký tự."
  local DB_PASS1 DB_PASS2
  while :; do
    read -rsp "Mật khẩu database PostgreSQL: " DB_PASS1; echo
    read -rsp "Nhập lại mật khẩu PostgreSQL: " DB_PASS2; echo
    if [[ -z "$DB_PASS1" ]]; then
      echo "❌ Mật khẩu không được để trống."
      continue
    fi
    if [[ "$DB_PASS1" != "$DB_PASS2" ]]; then
      echo "❌ Mật khẩu không khớp, thử lại."
      continue
    fi
    break
  done
  local DB_PASSWORD="$DB_PASS1"
  unset DB_PASS1 DB_PASS2

  read -rp "Image n8n [${N8N_DEFAULT_N8N_IMAGE}]: " N8N_IMAGE
  N8N_IMAGE=${N8N_IMAGE:-$N8N_DEFAULT_N8N_IMAGE}

  echo
  echo "📌 Tóm tắt:"
  echo "   - Hostname:       ${N8N_HOST}"
  echo "   - Tunnel name:    ${TUNNEL_NAME}"
  echo "   - Install dir:    ${INSTALL_DIR}"
  echo "   - Timezone:       ${TZ}"
  echo "   - DB:             ${DB_NAME}"
  echo "   - DB user:        ${DB_USER}"
  echo "   - n8n image:      ${N8N_IMAGE}"
  echo "   - Service name:   ${CF_SERVICE_NAME}"
  echo "   - Data dir:       ${N8N_DATA_DIR} (mount vào /home/node/.n8n)"
  echo "   * Nếu đã cài trước đó, KHÔNG nên đổi DB password nếu chưa xoá volume DB."
  echo
  read -rp "Tiếp tục cài đặt? [y/N]: " CONFIRM
  CONFIRM=${CONFIRM:-n}
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "❌ Huỷ cài đặt."
    return
  fi

  # Data dir cho n8n
  mkdir -p "${N8N_DATA_DIR}"
  chown 1000:1000 "${N8N_DATA_DIR}" || true
  chmod 700 "${N8N_DATA_DIR}" || true

  # Ghi docker-compose
  write_docker_compose "$INSTALL_DIR" "$N8N_HOST" "$TZ" "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$N8N_IMAGE" "$N8N_DEFAULT_DB_IMAGE"

  echo "▶ Triển khai stack n8n + PostgreSQL (dùng Postgres 16, data mount ${N8N_DATA_DIR})..."
  (cd "$INSTALL_DIR" && docker compose up -d)

  echo "✅ n8n đã khởi động (local): http://127.0.0.1:5678"
  echo "   (Đợi vài giây cho container n8n & postgres ổn định...)"
  sleep 5

  echo "▶ Thử curl từ local tới n8n:"
  local HTTP_CODE
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:5678" || echo "000")
  echo "   → HTTP code: ${HTTP_CODE} (404 trong vài giây đầu cũng có thể chấp nhận được nếu migrations đang chạy)"

  ensure_cloudflare_login

  echo "▶ Đảm bảo tunnel '${TUNNEL_NAME}' tồn tại..."
  local TUNNEL_ID
  TUNNEL_ID=$(ensure_tunnel "$TUNNEL_NAME")
  echo "   → Tunnel ID:   ${TUNNEL_ID}"
  echo "   → Credentials: /root/.cloudflared/${TUNNEL_ID}.json"

  setup_dns "$TUNNEL_NAME" "$N8N_HOST"
  write_cloudflared_config_and_service "$TUNNEL_ID" "$N8N_HOST"

  echo
  echo "🎉 HOÀN TẤT CÀI n8n + TUNNEL!"
  echo "   - n8n qua Cloudflare:  https://${N8N_HOST}"
  echo "   - Local:               http://127.0.0.1:5678"
  echo
  echo "Lần đầu vào UI n8n, bạn sẽ tạo user owner."
}

show_status() {
  echo "=== TRẠNG THÁI n8n + TUNNEL ==="
  echo
  echo "▶ Docker containers (liên quan n8n):"
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E '^NAMES|n8n' || echo "(Không có container n8n đang chạy)"

  echo
  echo "▶ Systemd service: ${CF_SERVICE_NAME}"
  if systemctl list-unit-files | grep -q "^${CF_SERVICE_NAME}"; then
    systemctl status "${CF_SERVICE_NAME}" --no-pager -n 5 || true
  else
    echo "Không có service ${CF_SERVICE_NAME}"
  fi

  echo
  echo "▶ Danh sách tunnel có chữ 'n8n':"
  cloudflared tunnel list 2>/dev/null | (grep -i 'n8n' || echo "(Không có tunnel chứa 'n8n')") || true
}

uninstall_n8n() {
  echo "=== GỠ n8n + Cloudflare Tunnel (local) ==="
  read -rp "Bạn chắc chắn muốn gỡ n8n (container + service tunnel local)? [y/N]: " CONFIRM
  CONFIRM=${CONFIRM:-n}
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "❌ Huỷ gỡ."
    return
  fi

  local INSTALL_DIR
  read -rp "Thư mục cài n8n hiện tại [/opt/n8n]: " INSTALL_DIR
  INSTALL_DIR=${INSTALL_DIR:-$N8N_DEFAULT_INSTALL_DIR}

  echo "▶ Dừng & xoá container n8n / n8n-postgres (nếu có)..."
  if [ -f "${INSTALL_DIR}/docker-compose.yml" ]; then
    (cd "$INSTALL_DIR" && docker compose down || true)
  else
    docker rm -f n8n n8n-postgres >/dev/null 2>&1 || true
  fi

  echo "▶ Dừng & xoá systemd service ${CF_SERVICE_NAME}..."
  systemctl stop "${CF_SERVICE_NAME}" >/dev/null 2>&1 || true
  systemctl disable "${CF_SERVICE_NAME}" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${CF_SERVICE_NAME}" || true
  systemctl daemon-reload || true

  # Hỏi xoá data dir
  if [ -d "${N8N_DATA_DIR}" ]; then
    read -rp "Bạn có muốn XOÁ thư mục data '${N8N_DATA_DIR}' (mất toàn bộ workflows, credentials, settings)? [y/N]: " DEL_DATA
    DEL_DATA=${DEL_DATA:-n}
    if [[ "$DEL_DATA" =~ ^[Yy]$ ]]; then
      rm -rf "${N8N_DATA_DIR}"
      echo "   → Đã xoá thư mục ${N8N_DATA_DIR}."
    fi
  fi

  # Hỏi xoá install dir
  if [ -d "${INSTALL_DIR}" ]; then
    read -rp "Bạn có muốn XOÁ thư mục cài đặt '${INSTALL_DIR}' (docker-compose.yml, env...)? [y/N]: " DEL_INSTALL
    DEL_INSTALL=${DEL_INSTALL:-n}
    if [[ "$DEL_INSTALL" =~ ^[Yy]$ ]]; then
      rm -rf "${INSTALL_DIR}"
      echo "   → Đã xoá thư mục ${INSTALL_DIR}."
    fi
  fi

  # Xử lý volume Postgres
  local VOLUMES
  VOLUMES=$(docker volume ls --format '{{.Name}}' | grep -E '^n8n(_postgres_data|_n8n_postgres_data)$' || true)
  if [[ -n "${VOLUMES}" ]]; then
    echo "Các Docker volume Postgres liên quan đến n8n được tìm thấy:"
    echo "${VOLUMES}" | sed 's/^/   - /'
    read -rp "Bạn có muốn XOÁ các volume này (XOÁ TOÀN BỘ DB n8n)? [y/N]: " DEL_VOL
    DEL_VOL=${DEL_VOL:-n}
    if [[ "$DEL_VOL" =~ ^[Yy]$ ]]; then
      echo "${VOLUMES}" | xargs -r docker volume rm
    fi
  fi

  # Thông tin tunnel từ file config
  local TUNNEL_ID TUNNEL_NAME
  if [ -f "${CF_CONFIG_FILE}" ]; then
    TUNNEL_ID=$(awk '/^tunnel:/ {print $2}' "${CF_CONFIG_FILE}" || true)
    if [[ -n "${TUNNEL_ID:-}" ]]; then
      TUNNEL_NAME=$(cloudflared tunnel list 2>/dev/null | awk -v id="$TUNNEL_ID" '$1 == id {print $2}' | head -n1 || echo "${N8N_DEFAULT_TUNNEL_NAME}")
      echo
      echo "▶ Thông tin tunnel từ file cấu hình ${CF_CONFIG_FILE}:"
      echo "   - Tunnel ID:   ${TUNNEL_ID}"
      echo "   - Tunnel name: ${TUNNEL_NAME}"

      read -rp "Bạn có muốn XOÁ Cloudflare Tunnel '${TUNNEL_NAME}' khỏi account Cloudflare (cloudflared tunnel delete)? [y/N]: " DEL_TUNNEL
      DEL_TUNNEL=${DEL_TUNNEL:-n}
      if [[ "$DEL_TUNNEL" =~ ^[Yy]$ ]]; then
        cloudflared tunnel delete "${TUNNEL_ID}" || cloudflared tunnel delete "${TUNNEL_NAME}" || true
      fi

      read -rp "Bạn có muốn XOÁ file cấu hình local '${CF_CONFIG_FILE}'? [y/N]: " DEL_CFG
      DEL_CFG=${DEL_CFG:-n}
      if [[ "$DEL_CFG" =~ ^[Yy]$ ]]; then
        rm -f "${CF_CONFIG_FILE}"
        echo "   → Đã xoá file cấu hình tunnel local."
      fi
    fi
  fi

  echo
  echo "⚠ Về Cloudflare DNS:"
  echo "   - Script KHÔNG tự xoá CNAME DNS trên Cloudflare."
  echo "   - Sau khi xoá tunnel (nếu có), hãy vào Cloudflare Dashboard để xoá record CNAME tương ứng (ví dụ: ${N8N_DEFAULT_HOST}) nếu không dùng nữa."
  echo
  echo "✅ Đã gỡ n8n (container) + service ${CF_SERVICE_NAME} trên máy chủ (tuỳ chọn xoá data/volume/tunnel như bạn đã chọn)."
}

update_n8n_image() {
  echo "=== UPDATE n8n (pull image mới nhất, giữ data) ==="
  local INSTALL_DIR
  read -rp "Thư mục cài n8n hiện tại [/opt/n8n]: " INSTALL_DIR
  INSTALL_DIR=${INSTALL_DIR:-$N8N_DEFAULT_INSTALL_DIR}

  if [ ! -f "${INSTALL_DIR}/docker-compose.yml" ]; then
    echo "❌ Không tìm thấy ${INSTALL_DIR}/docker-compose.yml. Không biết cấu hình để update."
    return
  fi

  echo "▶ Pull image mới nhất cho service n8n..."
  (cd "$INSTALL_DIR" && docker compose pull n8n)

  echo "▶ Khởi động lại n8n với image mới..."
  (cd "$INSTALL_DIR" && docker compose up -d n8n)

  echo "✅ Đã update n8n. Data trong Postgres & ${N8N_DATA_DIR} vẫn được giữ nguyên."
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
    read -rp "Chọn chức năng (0-4): " CHOICE

    case "$CHOICE" in
      1) install_or_update_n8n ;;
      2) show_status ;;
      3) uninstall_n8n ;;
      4) update_n8n_image ;;
      0) exit 0 ;;
      *) echo "❌ Lựa chọn không hợp lệ!";;
    esac
    echo
  done
}

main_menu
