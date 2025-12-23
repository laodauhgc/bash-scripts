#!/usr/bin/env bash
set -euo pipefail

MENU_TITLE="n8n MANAGER + CLOUDFLARE TUNNEL"

DEFAULT_HOSTNAME="n8n.rawcode.io"
DEFAULT_TUNNEL_NAME="n8n-tunnel"
DEFAULT_INSTALL_DIR="/opt/n8n"
DEFAULT_TZ="Asia/Ho_Chi_Minh"
DEFAULT_DB_NAME="n8n"
DEFAULT_DB_USER="n8n"
DEFAULT_N8N_IMAGE="docker.n8n.io/n8nio/n8n"
DATA_DIR="${HOME}/.n8n"
SYSTEMD_SERVICE_NAME="cloudflared-n8n.service"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"

# ======================= UTIL ==========================
line() { printf '%*s\n' "${COLUMNS:-60}" '' | tr ' ' '='; }

ensure_requirements() {
  echo "▶ Cập nhật hệ thống & cài gói phụ thuộc..."
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y curl ca-certificates gnupg lsb-release wget jq >/dev/null 2>&1 || true

  if ! command -v docker >/dev/null 2>&1; then
    echo "▶ Cài Docker..."
    curl -fsSL https://get.docker.com | sh
  fi

  if ! docker compose version >/dev/null 2>&1; then
    echo "▶ Cài Docker Compose plugin..."
    apt-get install -y docker-compose-plugin >/dev/null 2>&1 || true
  fi

  if ! command -v cloudflared >/dev/null 2>&1; then
    echo "▶ Cài cloudflared..."
    local CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
    curl -sSL "$CLOUDFLARED_URL" -o /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared
  fi

  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker >/dev/null 2>&1 || true
}

prompt_default() {
  local prompt="$1"
  local default="$2"
  local var
  read -r -p "$prompt [$default]: " var || true
  if [[ -z "$var" ]]; then
    echo "$default"
  else
    echo "$var"
  fi
}

prompt_password_twice() {
  local pass1 pass2
  while true; do
    echo "ℹ️  Khi nhập mật khẩu, terminal sẽ KHÔNG hiện ký tự."
    read -s -p "Mật khẩu database PostgreSQL: " pass1 || true
    echo
    read -s -p "Nhập lại mật khẩu PostgreSQL: " pass2 || true
    echo
    if [[ -z "$pass1" ]]; then
      echo "⚠ Mật khẩu không được để trống."
      continue
    fi
    if [[ "$pass1" != "$pass2" ]]; then
      echo "⚠ Mật khẩu không khớp, vui lòng nhập lại."
      continue
    fi
    echo "$pass1"
    return 0
  done
}

ensure_data_dir() {
  echo "▶ Đảm bảo thư mục data $DATA_DIR tồn tại..."
  mkdir -p "$DATA_DIR"
  chown 1000:1000 "$DATA_DIR" || true
  chmod 700 "$DATA_DIR" || true
}

# ==================== DOCKER COMPOSE ====================

write_docker_compose() {
  local install_dir="$1"
  local hostname="$2"
  local tz="$3"
  local db_name="$4"
  local db_user="$5"
  local db_password="$6"
  local n8n_image="$7"

  mkdir -p "$install_dir"
  cat > "${install_dir}/docker-compose.yml" <<EOF
name: n8n

services:
  n8n:
    image: ${n8n_image}
    container_name: n8n
    restart: unless-stopped
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=n8n-postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=${db_name}
      - DB_POSTGRESDB_USER=${db_user}
      - DB_POSTGRESDB_PASSWORD=${db_password}
      - N8N_HOST=${hostname}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - N8N_EDITOR_BASE_URL=https://${hostname}/
      - N8N_API_URL=https://${hostname}/
      - WEBHOOK_URL=https://${hostname}/
      - N8N_SECURE_COOKIE=false
      - TZ=${tz}
      - GENERIC_TIMEZONE=${tz}
      - N8N_DIAGNOSTICS_ENABLED=false
    ports:
      - "127.0.0.1:5678:5678"
    volumes:
      - "${DATA_DIR}:/home/node/.n8n"
    depends_on:
      - n8n-postgres

  n8n-postgres:
    image: postgres:16
    container_name: n8n-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_USER=${db_user}
      - POSTGRES_PASSWORD=${db_password}
      - POSTGRES_DB=${db_name}
      - TZ=${tz}
    volumes:
      - n8n_postgres_data:/var/lib/postgresql/data

volumes:
  n8n_postgres_data:
    name: n8n_postgres_data
EOF
}

deploy_stack() {
  local install_dir="$1"
  echo "▶ Triển khai stack n8n + PostgreSQL (Postgres 16, data mount ${DATA_DIR})..."
  (cd "$install_dir" && docker compose pull && docker compose up -d)
  echo "✅ n8n đã khởi động (local): http://127.0.0.1:5678"
}

# ==================== CLOUDFLARE TUNNEL ====================

ensure_cloudflared_login() {
  if [[ ! -f "/root/.cloudflared/cert.pem" ]]; then
    echo "⚠ Chưa tìm thấy /root/.cloudflared/cert.pem."
    echo "   Bạn cần chạy: cloudflared tunnel login"
    echo "   Sau đó quay lại chạy script này."
    exit 1
  fi
}

ensure_tunnel() {
  local tunnel_name="$1"
  local hostname="$2"
  echo "▶ Đảm bảo tunnel '${tunnel_name}' tồn tại..."
  local tunnel_id=""
  if cloudflared tunnel list 2>/dev/null | grep -qw "${tunnel_name}"; then
    tunnel_id="$(cloudflared tunnel list | awk -v name="${tunnel_name}" '$2==name {print $1; exit}')"
    echo "ℹ️  Tunnel '${tunnel_name}' đã tồn tại (ID: ${tunnel_id})."
  else
    echo "▶ Tạo tunnel mới '${tunnel_name}'..."
    local output
    output="$(cloudflared tunnel create "${tunnel_name}" 2>&1 || true)"
    echo "$output"
    tunnel_id="$(echo "$output" | awk '/Created tunnel/{print $NF}' | tr -d '\r')"
    if [[ -z "$tunnel_id" ]]; then
      tunnel_id="$(cloudflared tunnel list | awk -v name="${tunnel_name}" '$2==name {print $1; exit}')"
    fi
    echo "   → Tunnel ID:   ${tunnel_id}"
  fi

  if [[ -z "$tunnel_id" ]]; then
    echo "⚠ Không lấy được Tunnel ID cho '${tunnel_name}'."
  fi

  # Ghi file cấu hình local cho cloudflared
  mkdir -p /etc/cloudflared
  cat > "/etc/cloudflared/${tunnel_name}.yml" <<EOF
tunnel: ${tunnel_id}
credentials-file: /root/.cloudflared/${tunnel_id}.json

ingress:
  - hostname: ${hostname}
    service: http://127.0.0.1:5678
  - service: http_status:404
EOF

  # KHÔNG tự động route DNS nữa – in hướng dẫn rõ ràng để bạn set đúng Tunnel ID
  if [[ -n "$tunnel_id" ]]; then
    echo
    echo "⚠ BƯỚC THỦ CÔNG CẦN LÀM TRÊN CLOUDFLARE (đảm bảo CNAME đúng Tunnel ID):"
    echo "   Vào Cloudflare DNS và tạo/kiểm tra record:"
    echo "     - Type:   CNAME"
    echo "     - Name:   ${hostname}"
    echo "     - Target: ${tunnel_id}.cfargotunnel.com"
    echo "   Nếu record đã tồn tại nhưng target khác, sửa lại thành ${tunnel_id}.cfargotunnel.com"
    echo
  fi

  # Tạo systemd service
  cat > "/etc/systemd/system/${SYSTEMD_SERVICE_NAME}" <<EOF
[Unit]
Description=Cloudflare Tunnel - ${tunnel_name} (n8n)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${CLOUDFLARED_BIN} --no-autoupdate --config /etc/cloudflared/${tunnel_name}.yml tunnel run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${SYSTEMD_SERVICE_NAME}" >/dev/null 2>&1 || true
  systemctl restart "${SYSTEMD_SERVICE_NAME}"
  echo "✅ Cloudflare Tunnel đã chạy. Kiểm tra nhanh:"
  systemctl status "${SYSTEMD_SERVICE_NAME}" --no-pager || true
}

# ==================== ACTIONS ====================

install_or_update() {
  echo
  echo "=== CÀI ĐẶT / CẬP NHẬT n8n + PostgreSQL + Cloudflare Tunnel ==="
  local hostname tunnel_name install_dir tz db_name db_user db_password n8n_image

  hostname="$(prompt_default "Hostname cho n8n" "${DEFAULT_HOSTNAME}")"
  tunnel_name="$(prompt_default "Tên tunnel" "${DEFAULT_TUNNEL_NAME}")"
  install_dir="$(prompt_default "Thư mục cài n8n" "${DEFAULT_INSTALL_DIR}")"
  tz="$(prompt_default "Timezone" "${DEFAULT_TZ}")"
  db_name="$(prompt_default "Tên database PostgreSQL" "${DEFAULT_DB_NAME}")"
  db_user="$(prompt_default "User database PostgreSQL" "${DEFAULT_DB_USER}")"
  db_password="$(prompt_password_twice)"
  n8n_image="$(prompt_default "Image n8n" "${DEFAULT_N8N_IMAGE}")"

  echo
  echo "📌 Tóm tắt:"
  echo "   - Hostname:       ${hostname}"
  echo "   - Tunnel name:    ${tunnel_name}"
  echo "   - Install dir:    ${install_dir}"
  echo "   - Timezone:       ${tz}"
  echo "   - DB:             ${db_name}"
  echo "   - DB user:        ${db_user}"
  echo "   - n8n image:      ${n8n_image}"
  echo "   - Service name:   ${SYSTEMD_SERVICE_NAME}"
  echo "   - Data dir:       ${DATA_DIR} (mount vào /home/node/.n8n)"
  echo "   * Nếu đã cài trước đó, KHÔNG nên đổi DB password nếu chưa xoá volume DB/postgres."

  read -r -p "Tiếp tục cài đặt? [y/N]: " confirm || true
  if [[ "${confirm,,}" != "y" ]]; then
    echo "❌ Huỷ."
    return
  fi

  ensure_requirements
  ensure_data_dir
  write_docker_compose "${install_dir}" "${hostname}" "${tz}" "${db_name}" "${db_user}" "${db_password}" "${n8n_image}"
  deploy_stack "${install_dir}"

  if [[ -f "/root/.cloudflared/cert.pem" ]]; then
    ensure_cloudflared_login
    ensure_tunnel "${tunnel_name}" "${hostname}"
  else
    echo "⚠ Không tìm thấy cert Cloudflare, bỏ qua bước tunnel."
  fi

  echo
  echo "🎉 HOÀN TẤT CÀI n8n + TUNNEL!"
  echo "   - n8n qua Cloudflare:  https://${hostname}"
  echo "   - Local:               http://127.0.0.1:5678"
  echo
  echo "Lần đầu vào UI n8n, bạn sẽ tạo user owner."
}

status_n8n() {
  echo
  echo "=== TRẠNG THÁI n8n + TUNNEL ==="
  echo
  echo "▶ Docker containers (liên quan n8n):"
  docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E '^n8n|^n8n-postgres' || echo "(không có container n8n đang chạy)"
  echo
  echo "▶ Systemd service: ${SYSTEMD_SERVICE_NAME}"
  systemctl status "${SYSTEMD_SERVICE_NAME}" --no-pager || echo "(service không tồn tại)"
  echo
  echo "▶ Danh sách tunnel có chữ 'n8n':"
  cloudflared tunnel list 2>/dev/null | (grep -i 'n8n' || echo "(không có tunnel n8n trong danh sách)") || true
}

uninstall_n8n() {
  echo
  echo "=== GỠ n8n + Cloudflare Tunnel (local) ==="
  read -r -p "Bạn chắc chắn muốn gỡ n8n (container + service tunnel local)? [y/N]: " confirm || true
  if [[ "${confirm,,}" != "y" ]]; then
    echo "❌ Huỷ."
    return
  fi

  local install_dir
  install_dir="$(prompt_default "Thư mục cài n8n hiện tại" "${DEFAULT_INSTALL_DIR}")"

  echo "▶ Dừng & xoá container n8n / n8n-postgres (nếu có)..."
  if [[ -f "${install_dir}/docker-compose.yml" ]]; then
    (cd "$install_dir" && docker compose down) || true
  else
    docker rm -f n8n n8n-postgres >/dev/null 2>&1 || true
  fi

  echo "▶ Dừng & xoá systemd service ${SYSTEMD_SERVICE_NAME}..."
  systemctl stop "${SYSTEMD_SERVICE_NAME}" >/dev/null 2>&1 || true
  systemctl disable "${SYSTEMD_SERVICE_NAME}" >/dev/null 2>&1 || true

  if [[ -f "/etc/systemd/system/${SYSTEMD_SERVICE_NAME}" ]]; then
    read -r -p "Bạn có muốn XOÁ file service '/etc/systemd/system/${SYSTEMD_SERVICE_NAME}'? [y/N]: " ans_service || true
    if [[ "${ans_service,,}" == "y" ]]; then
      rm -f "/etc/systemd/system/${SYSTEMD_SERVICE_NAME}"
      systemctl daemon-reload || true
      echo "   → Đã xoá file service."
    fi
  fi

  if [[ -d "${DATA_DIR}" ]]; then
    read -r -p "Bạn có muốn XOÁ thư mục data '${DATA_DIR}' (mất toàn bộ workflows, credentials, settings)? [y/N]: " ans || true
    if [[ "${ans,,}" == "y" ]]; then
      rm -rf "${DATA_DIR}"
      echo "   → Đã xoá thư mục ${DATA_DIR}."
    fi
  fi

  if [[ -d "${install_dir}" ]]; then
    read -r -p "Bạn có muốn XOÁ thư mục cài đặt '${install_dir}' (docker-compose.yml, env...)? [y/N]: " ans2 || true
    if [[ "${ans2,,}" == "y" ]]; then
      rm -rf "${install_dir}"
      echo "   → Đã xoá thư mục ${install_dir}."
    fi
  fi

  local postgres_vols
  postgres_vols="$(docker volume ls --format '{{.Name}}' | grep -E '^n8n(_|-)postgres' || true)"
  if [[ -n "$postgres_vols" ]]; then
    echo
    echo "Các Docker volume Postgres liên quan đến n8n được tìm thấy:"
    echo "$postgres_vols"
    read -r -p "Bạn có muốn XOÁ các volume này (XOÁ TOÀN BỘ DB n8n)? [y/N]: " ans_vol || true
    if [[ "${ans_vol,,}" == "y" ]]; then
      echo "$postgres_vols" | xargs -r docker volume rm
    fi
  fi

  if [[ -f "/etc/cloudflared/${DEFAULT_TUNNEL_NAME}.yml" ]]; then
    local tunnel_id
    tunnel_id="$(awk '/^tunnel:/{print $2}' "/etc/cloudflared/${DEFAULT_TUNNEL_NAME}.yml" 2>/dev/null || true)"
    echo
    echo "▶ Thông tin tunnel từ file cấu hình /etc/cloudflared/${DEFAULT_TUNNEL_NAME}.yml:"
    echo "   - Tunnel ID:   ${tunnel_id:-N/A}"
    echo "   - Tunnel name: ${DEFAULT_TUNNEL_NAME}"

    read -r -p "Bạn có muốn XOÁ Cloudflare Tunnel '${DEFAULT_TUNNEL_NAME}' khỏi account Cloudflare (cloudflared tunnel delete)? [y/N]: " ans_tunnel || true
    if [[ "${ans_tunnel,,}" == "y" && -n "${tunnel_id}" ]]; then
      cloudflared tunnel delete "${DEFAULT_TUNNEL_NAME}" || true
    fi

    read -r -p "Bạn có muốn XOÁ file cấu hình local '/etc/cloudflared/${DEFAULT_TUNNEL_NAME}.yml'? [y/N]: " ans_cfg || true
    if [[ "${ans_cfg,,}" == "y" ]]; then
      rm -f "/etc/cloudflared/${DEFAULT_TUNNEL_NAME}.yml"
      echo "   → Đã xoá file cấu hình tunnel local."
    fi
  fi

  echo
  echo "⚠ Về Cloudflare DNS:"
  echo "   - Script KHÔNG tự xoá CNAME DNS trên Cloudflare."
  echo "   - Sau khi xoá tunnel (nếu có), hãy vào Cloudflare Dashboard để xoá record CNAME tương ứng (ví dụ: ${DEFAULT_HOSTNAME}) nếu không dùng nữa."
  echo
  echo "✅ Đã gỡ n8n (container) + service ${SYSTEMD_SERVICE_NAME} trên máy chủ (tuỳ chọn xoá data/volume/tunnel như bạn đã chọn)."
}

update_n8n_image() {
  echo
  echo "=== UPDATE n8n (pull image mới nhất, giữ data) ==="
  local install_dir
  install_dir="$(prompt_default "Thư mục cài n8n hiện tại" "${DEFAULT_INSTALL_DIR}")"

  if [[ ! -f "${install_dir}/docker-compose.yml" ]]; then
    echo "⚠ Không tìm thấy ${install_dir}/docker-compose.yml. Hãy chạy chức năng cài đặt trước."
    return
  fi

  echo "▶ Pull image n8n mới nhất & restart container..."
  (cd "$install_dir" && docker compose pull n8n && docker compose up -d n8n)
  echo "✅ Đã update n8n. Data trong ${DATA_DIR} và volume Postgres vẫn được giữ nguyên."
}

show_menu() {
  line
  echo " ${MENU_TITLE}"
  line
  echo "1) Cài / cập nhật n8n + tunnel"
  echo "2) Kiểm tra trạng thái n8n + tunnel"
  echo "3) Gỡ n8n + service + (tuỳ chọn) xoá data & volume & tunnel"
  echo "4) Update n8n (pull image mới nhất, giữ data)"
  echo "0) Thoát"
  line
}

main() {
  while true; do
    show_menu
    read -r -p "Chọn chức năng (0-4): " choice || true
    case "$choice" in
      1) install_or_update ;;
      2) status_n8n ;;
      3) uninstall_n8n ;;
      4) update_n8n_image ;;
      0) echo "Bye!"; exit 0 ;;
      *) echo "Lựa chọn không hợp lệ." ;;
    esac
    echo
  done
}

main "$@"
