#!/usr/bin/env bash
# n8n_manager.sh v1.0.0
# Versioning note: v1.0.0 is the baseline. Future revisions should increment patch (v1.0.1, v1.0.2, ...).

set -Eeuo pipefail

# -------------------------------
# Config / defaults
# -------------------------------
VERSION="1.0.0"

DEFAULT_HOSTNAME="n8n.rawcode.io"
DEFAULT_TUNNEL_NAME="n8n-tunnel"
DEFAULT_INSTALL_DIR="/opt/n8n"
DEFAULT_TZ="Asia/Ho_Chi_Minh"
DEFAULT_DB_NAME="n8n"
DEFAULT_DB_USER="n8n"
DEFAULT_N8N_IMAGE="docker.n8n.io/n8nio/n8n"
DEFAULT_PG_IMAGE="postgres:16"
DEFAULT_DATA_DIR="/root/.n8n"
DEFAULT_PROXY_HOPS="1"

# Push backend options: websocket (best if allowed) or sse (most compatible when WS is flaky)
DEFAULT_PUSH_BACKEND="websocket" # or "sse"
DEFAULT_CF_PROTOCOL="quic"       # or "http2" if QUIC is unstable in your environment

CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
CLOUDFLARED_DIR="/etc/cloudflared"
CLOUDFLARED_CONFIG="${CLOUDFLARED_DIR}/n8n-tunnel.yml"
SYSTEMD_SERVICE="/etc/systemd/system/cloudflared-n8n.service"

COMPOSE_PROJECT="n8n"
ENV_FILE_NAME=".env"
COMPOSE_FILE_NAME="docker-compose.yml"

# -------------------------------
# UI helpers
# -------------------------------
COLOR_RESET=$'\033[0m'
COLOR_RED=$'\033[0;31m'
COLOR_GREEN=$'\033[0;32m'
COLOR_YELLOW=$'\033[0;33m'
COLOR_BLUE=$'\033[0;34m'
BOLD=$'\033[1m'

info()  { echo "${COLOR_BLUE}ℹ️  $*${COLOR_RESET}"; }
ok()    { echo "${COLOR_GREEN}✅ $*${COLOR_RESET}"; }
warn()  { echo "${COLOR_YELLOW}⚠️  $*${COLOR_RESET}"; }
err()   { echo "${COLOR_RED}❌ $*${COLOR_RESET}" >&2; }

die() { err "$*"; exit 1; }

pause() { read -r -p "Nhấn Enter để tiếp tục..." _; }

banner() {
  echo "============================================================"
  echo " n8n MANAGER + CLOUDFLARE TUNNEL (v${VERSION})"
  echo "============================================================"
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Vui lòng chạy script bằng root (sudo)."
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Prefer docker compose plugin, fallback to docker-compose.
compose() {
  local install_dir="$1"
  shift
  if docker compose version >/dev/null 2>&1; then
    docker compose --project-name "${COMPOSE_PROJECT}" -f "${install_dir}/${COMPOSE_FILE_NAME}" "$@"
  elif have_cmd docker-compose; then
    docker-compose --project-name "${COMPOSE_PROJECT}" -f "${install_dir}/${COMPOSE_FILE_NAME}" "$@"
  else
    die "Không tìm thấy 'docker compose' hoặc 'docker-compose'."
  fi
}

# -------------------------------
# System checks / deps
# -------------------------------
ensure_deps() {
  local missing=()
  have_cmd curl || missing+=("curl")
  have_cmd openssl || missing+=("openssl")
  have_cmd awk || missing+=("awk")
  have_cmd sed || missing+=("sed")

  if ((${#missing[@]} > 0)); then
    warn "Thiếu tool: ${missing[*]}"
    if have_cmd apt-get; then
      info "Cài đặt dependencies qua apt..."
      apt-get update -y
      apt-get install -y curl openssl gawk sed
      ok "Đã cài dependencies cơ bản."
    else
      die "Hệ thống không có apt-get. Vui lòng tự cài: ${missing[*]}"
    fi
  fi

  if ! have_cmd docker; then
    warn "Chưa có Docker."
    die "Vui lòng cài Docker trước (hoặc tự cài) rồi chạy lại."
  fi

  # jq is optional but makes cloudflared parsing safer
  if ! have_cmd jq; then
    if have_cmd apt-get; then
      info "Cài jq (khuyến nghị)..."
      apt-get update -y
      apt-get install -y jq
      ok "Đã cài jq."
    else
      warn "Không có jq. Script vẫn chạy nhưng parsing tunnel id sẽ kém chắc chắn hơn."
    fi
  fi
}

ensure_cloudflared() {
  if [[ -x "${CLOUDFLARED_BIN}" ]]; then
    return 0
  fi
  if have_cmd cloudflared; then
    CLOUDFLARED_BIN="$(command -v cloudflared)"
    return 0
  fi

  warn "Chưa có cloudflared."
  if have_cmd apt-get; then
    info "Thử cài cloudflared bằng apt (Cloudflare repo)..."
    apt-get update -y
    apt-get install -y ca-certificates gnupg lsb-release

    install -d -m 0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
      | gpg --dearmor -o /usr/share/keyrings/cloudflare-main.gpg

    local codename
    codename="$(lsb_release -cs 2>/dev/null || echo "stable")"
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared ${codename} main" \
      > /etc/apt/sources.list.d/cloudflared.list

    apt-get update -y
    apt-get install -y cloudflared

    if have_cmd cloudflared; then
      CLOUDFLARED_BIN="$(command -v cloudflared)"
      ok "Đã cài cloudflared: ${CLOUDFLARED_BIN}"
      return 0
    fi
  fi

  die "Không cài được cloudflared tự động. Vui lòng cài cloudflared rồi chạy lại."
}

# -------------------------------
# Utilities
# -------------------------------
prompt_default() {
  local prompt="$1"
  local def="$2"
  local val
  read -r -p "${prompt} [${def}]: " val
  if [[ -z "${val}" ]]; then
    echo "${def}"
  else
    echo "${val}"
  fi
}

prompt_secret() {
  local prompt="$1"
  local v1 v2
  while true; do
    echo "ℹ️ Lưu ý: khi nhập mật khẩu, terminal sẽ KHÔNG hiện ký tự."
    read -r -s -p "${prompt}: " v1; echo
    read -r -s -p "Nhập lại ${prompt}: " v2; echo
    [[ -n "${v1}" ]] || { warn "Mật khẩu không được rỗng."; continue; }
    [[ "${v1}" == "${v2}" ]] || { warn "Mật khẩu không khớp, thử lại."; continue; }
    echo "${v1}"
    return 0
  done
}

gen_hex() { openssl rand -hex "$1"; }

ensure_dir() {
  local d="$1"
  mkdir -p "${d}"
}

# Wait until local n8n is actually ready
wait_for_n8n() {
  local tries="${1:-60}"
  local delay="${2:-2}"
  local url="http://127.0.0.1:5678/healthz"

  info "Chờ n8n sẵn sàng (${tries} lần thử)..."
  local i code
  for ((i=1; i<=tries; i++)); do
    code="$(curl -sS -o /dev/null -w "%{http_code}" "${url}" 2>/dev/null || true)"
    if [[ "${code}" == "200" ]]; then
      ok "n8n healthz OK (200)."
      return 0
    fi
    sleep "${delay}"
  done

  warn "n8n chưa sẵn sàng sau ${tries} lần (curl code=${code})."
  warn "Gợi ý: xem log: docker logs -n 200 n8n"
  return 1
}

# -------------------------------
# Compose generation
# -------------------------------
write_compose_and_env() {
  local install_dir="$1"
  local data_dir="$2"
  local tz="$3"
  local db_name="$4"
  local db_user="$5"
  local db_pass="$6"
  local n8n_image="$7"
  local pg_image="$8"
  local hostname="$9"
  local push_backend="${10}"
  local proxy_hops="${11}"

  ensure_dir "${install_dir}"
  ensure_dir "${data_dir}"

  local env_path="${install_dir}/${ENV_FILE_NAME}"
  local compose_path="${install_dir}/${COMPOSE_FILE_NAME}"

  # Persist encryption key: never regenerate if present (prevents weird auth/session issues after redeploy)
  local enc_key=""
  if [[ -f "${env_path}" ]] && grep -q '^N8N_ENCRYPTION_KEY=' "${env_path}"; then
    enc_key="$(grep '^N8N_ENCRYPTION_KEY=' "${env_path}" | head -n1 | cut -d= -f2-)"
  else
    enc_key="$(gen_hex 32)"
  fi

  # Some UI “loop to setup / connection lost” cases are caused by proxy/header confusion.
  # These settings are defensive for reverse proxy (Cloudflare Tunnel).
  cat > "${env_path}" <<EOF
# n8n stack env (generated by n8n_manager.sh v${VERSION})
TZ=${tz}
GENERIC_TIMEZONE=${tz}

# Database
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=n8n-postgres
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=${db_name}
DB_POSTGRESDB_USER=${db_user}
DB_POSTGRESDB_PASSWORD=${db_pass}

# Public URL (reverse proxy / tunnel)
N8N_HOST=${hostname}
N8N_PORT=5678
N8N_PROTOCOL=https
WEBHOOK_URL=https://${hostname}
N8N_EDITOR_BASE_URL=https://${hostname}

# Reverse proxy trust
N8N_PROXY_HOPS=${proxy_hops}

# Push backend (websocket recommended; fallback to sse if WS is problematic)
N8N_PUSH_BACKEND=${push_backend}

# Hardening / reduce “phone home”
N8N_DIAGNOSTICS_ENABLED=false
N8N_PERSONALIZATION_ENABLED=false
N8N_VERSION_NOTIFICATIONS_ENABLED=false

# Encryption key (must be stable)
N8N_ENCRYPTION_KEY=${enc_key}

# Data dir on host
N8N_DATA_DIR=${data_dir}
EOF

  cat > "${compose_path}" <<'EOF'
services:
  n8n-postgres:
    image: ${PG_IMAGE}
    container_name: n8n-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_DB=${DB_POSTGRESDB_DATABASE}
      - POSTGRES_USER=${DB_POSTGRESDB_USER}
      - POSTGRES_PASSWORD=${DB_POSTGRESDB_PASSWORD}
      - TZ=${TZ}
    volumes:
      - n8n_postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $$POSTGRES_USER -d $$POSTGRES_DB"]
      interval: 5s
      timeout: 5s
      retries: 30

  n8n:
    image: ${N8N_IMAGE}
    container_name: n8n
    restart: unless-stopped
    depends_on:
      n8n-postgres:
        condition: service_healthy
    ports:
      - "127.0.0.1:5678:5678"
    environment:
      - TZ=${TZ}
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}

      - DB_TYPE=${DB_TYPE}
      - DB_POSTGRESDB_HOST=${DB_POSTGRESDB_HOST}
      - DB_POSTGRESDB_PORT=${DB_POSTGRESDB_PORT}
      - DB_POSTGRESDB_DATABASE=${DB_POSTGRESDB_DATABASE}
      - DB_POSTGRESDB_USER=${DB_POSTGRESDB_USER}
      - DB_POSTGRESDB_PASSWORD=${DB_POSTGRESDB_PASSWORD}

      - N8N_HOST=${N8N_HOST}
      - N8N_PORT=${N8N_PORT}
      - N8N_PROTOCOL=${N8N_PROTOCOL}
      - WEBHOOK_URL=${WEBHOOK_URL}
      - N8N_EDITOR_BASE_URL=${N8N_EDITOR_BASE_URL}

      - N8N_PROXY_HOPS=${N8N_PROXY_HOPS}
      - N8N_PUSH_BACKEND=${N8N_PUSH_BACKEND}

      - N8N_DIAGNOSTICS_ENABLED=${N8N_DIAGNOSTICS_ENABLED}
      - N8N_PERSONALIZATION_ENABLED=${N8N_PERSONALIZATION_ENABLED}
      - N8N_VERSION_NOTIFICATIONS_ENABLED=${N8N_VERSION_NOTIFICATIONS_ENABLED}

      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}

    volumes:
      - ${N8N_DATA_DIR}:/home/node/.n8n

volumes:
  n8n_postgres_data:
EOF

  # Replace placeholders that we couldn't expand inside single-quoted heredoc
  sed -i "s|\${N8N_IMAGE}|${DEFAULT_N8N_IMAGE}|g" "${compose_path}"
  sed -i "s|\${PG_IMAGE}|${DEFAULT_PG_IMAGE}|g" "${compose_path}"

  ok "Đã ghi ${compose_path}"
  ok "Đã ghi ${env_path}"
}

# -------------------------------
# Cloudflare Tunnel setup
# -------------------------------
ensure_cloudflared_login() {
  # cloudflared tunnel route dns requires cert (or token) depending on setup.
  local cert="${HOME}/.cloudflared/cert.pem"
  if [[ -f "${cert}" ]]; then
    return 0
  fi

  warn "Chưa thấy cert Cloudflare (${cert})."
  info "Bạn cần chạy: cloudflared tunnel login (sẽ mở URL để authorize)."
  info "Chạy lệnh bên dưới trên server này (SSH):"
  echo
  echo "  ${CLOUDFLARED_BIN} tunnel login"
  echo
  die "Sau khi login xong, chạy lại chức năng cài đặt."
}

get_tunnel_id_by_name() {
  local tunnel_name="$1"

  if have_cmd jq; then
    "${CLOUDFLARED_BIN}" tunnel list --output json 2>/dev/null \
      | jq -r --arg NAME "${tunnel_name}" '.[] | select(.name==$NAME) | .id' \
      | head -n1
  else
    # Fallback: parse table output (less robust)
    "${CLOUDFLARED_BIN}" tunnel list 2>/dev/null \
      | awk -v name="${tunnel_name}" '$0 ~ name {print $1; exit}'
  fi
}

create_tunnel_if_missing() {
  local tunnel_name="$1"
  local tunnel_id
  tunnel_id="$(get_tunnel_id_by_name "${tunnel_name}" || true)"

  if [[ -n "${tunnel_id}" && "${tunnel_id}" != "null" ]]; then
    ok "Tunnel đã tồn tại: ${tunnel_name} (ID: ${tunnel_id})"
    echo "${tunnel_id}"
    return 0
  fi

  info "Tạo tunnel mới '${tunnel_name}'..."
  local out
  out="$("${CLOUDFLARED_BIN}" tunnel create "${tunnel_name}" 2>&1)" || {
    echo "${out}" >&2
    die "Tạo tunnel thất bại."
  }

  # Extract UUID
  tunnel_id="$(echo "${out}" | grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -n1 || true)"
  [[ -n "${tunnel_id}" ]] || die "Không parse được Tunnel ID từ output: ${out}"

  ok "Tunnel ID: ${tunnel_id}"
  echo "${tunnel_id}"
}

write_cloudflared_config() {
  local tunnel_id="$1"
  local hostname="$2"

  ensure_dir "${CLOUDFLARED_DIR}"

  local cred="${HOME}/.cloudflared/${tunnel_id}.json"
  [[ -f "${cred}" ]] || die "Không thấy credentials file: ${cred}"

  cat > "${CLOUDFLARED_CONFIG}" <<EOF
tunnel: ${tunnel_id}
credentials-file: ${cred}

ingress:
  - hostname: ${hostname}
    service: http://127.0.0.1:5678
    originRequest:
      httpHostHeader: ${hostname}
  - service: http_status:404
EOF

  ok "Đã ghi config tunnel: ${CLOUDFLARED_CONFIG}"
}

route_dns() {
  local tunnel_id="$1"
  local hostname="$2"

  info "Tạo / cập nhật DNS record cho ${hostname} ..."
  # This creates/updates CNAME to the tunnel
  "${CLOUDFLARED_BIN}" tunnel route dns "${tunnel_id}" "${hostname}" >/dev/null
  ok "Đã tạo/cập nhật DNS cho ${hostname}"
}

write_systemd_service() {
  local cf_protocol="$1" # quic|http2

  cat > "${SYSTEMD_SERVICE}" <<EOF
[Unit]
Description=Cloudflare Tunnel - n8n (cloudflared-n8n)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${CLOUDFLARED_BIN} --no-autoupdate --protocol ${cf_protocol} --config ${CLOUDFLARED_CONFIG} tunnel run
Restart=always
RestartSec=3
TimeoutStartSec=0
KillMode=process
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable cloudflared-n8n >/dev/null
  systemctl restart cloudflared-n8n
  ok "Cloudflare Tunnel service đã chạy: cloudflared-n8n.service"
}

# -------------------------------
# Actions
# -------------------------------
action_install_or_update() {
  echo "============================================================"
  echo "=== CÀI ĐẶT / CẬP NHẬT n8n + PostgreSQL + Cloudflare Tunnel ==="
  echo "============================================================"

  local hostname tunnel_name install_dir tz db_name db_user db_pass n8n_image pg_image data_dir push_backend proxy_hops cf_protocol

  hostname="$(prompt_default "Hostname cho n8n" "${DEFAULT_HOSTNAME}")"
  tunnel_name="$(prompt_default "Tên tunnel" "${DEFAULT_TUNNEL_NAME}")"
  install_dir="$(prompt_default "Thư mục cài n8n" "${DEFAULT_INSTALL_DIR}")"
  tz="$(prompt_default "Timezone" "${DEFAULT_TZ}")"
  db_name="$(prompt_default "Tên database PostgreSQL" "${DEFAULT_DB_NAME}")"
  db_user="$(prompt_default "User database PostgreSQL" "${DEFAULT_DB_USER}")"
  db_pass="$(prompt_secret "Mật khẩu database PostgreSQL")"
  n8n_image="$(prompt_default "Image n8n" "${DEFAULT_N8N_IMAGE}")"
  pg_image="$(prompt_default "Image PostgreSQL" "${DEFAULT_PG_IMAGE}")"
  data_dir="$(prompt_default "Data dir (host) cho n8n" "${DEFAULT_DATA_DIR}")"
  push_backend="$(prompt_default "N8N_PUSH_BACKEND (websocket|sse)" "${DEFAULT_PUSH_BACKEND}")"
  proxy_hops="$(prompt_default "N8N_PROXY_HOPS (thường 1)" "${DEFAULT_PROXY_HOPS}")"
  cf_protocol="$(prompt_default "Cloudflared protocol (quic|http2)" "${DEFAULT_CF_PROTOCOL}")"

  # Basic validation
  [[ "${push_backend}" == "websocket" || "${push_backend}" == "sse" ]] || die "N8N_PUSH_BACKEND chỉ nhận websocket hoặc sse."
  [[ "${cf_protocol}" == "quic" || "${cf_protocol}" == "http2" ]] || die "Cloudflared protocol chỉ nhận quic hoặc http2."

  echo
  echo "============================================================"
  echo "📌 Tóm tắt:"
  echo "   - Hostname:        ${hostname}"
  echo "   - Tunnel name:     ${tunnel_name}"
  echo "   - Install dir:     ${install_dir}"
  echo "   - Timezone:        ${tz}"
  echo "   - DB:              ${db_name}"
  echo "   - DB user:         ${db_user}"
  echo "   - DB password:     (ẩn)"
  echo "   - Postgres image:  ${pg_image}"
  echo "   - n8n image:       ${n8n_image}"
  echo "   - Data dir:        ${data_dir} (mount -> /home/node/.n8n)"
  echo "   - Push backend:    ${push_backend}"
  echo "   - Proxy hops:      ${proxy_hops}"
  echo "   - CF protocol:     ${cf_protocol}"
  echo "============================================================"

  read -r -p "Tiếp tục cài đặt? [y/N]: " yn
  [[ "${yn}" =~ ^[Yy]$ ]] || { info "Huỷ."; return 0; }

  info "Ghi docker-compose + env..."
  # Write compose using defaults; then patch in chosen images
  write_compose_and_env "${install_dir}" "${data_dir}" "${tz}" "${db_name}" "${db_user}" "${db_pass}" "${n8n_image}" "${pg_image}" "${hostname}" "${push_backend}" "${proxy_hops}"

  # Patch compose images to the chosen ones (compose file had defaults replaced earlier)
  sed -i "s|image: ${DEFAULT_N8N_IMAGE}|image: ${n8n_image}|g" "${install_dir}/${COMPOSE_FILE_NAME}"
  sed -i "s|image: ${DEFAULT_PG_IMAGE}|image: ${pg_image}|g" "${install_dir}/${COMPOSE_FILE_NAME}"

  info "Triển khai stack n8n + PostgreSQL..."
  (cd "${install_dir}" && compose "${install_dir}" --env-file "${install_dir}/${ENV_FILE_NAME}" up -d) >/dev/null
  ok "Compose up -d OK"

  wait_for_n8n 90 2 || warn "n8n chưa ready, nhưng vẫn tiếp tục tunnel (bạn nên kiểm tra log nếu UI lỗi)."

  # Cloudflare tunnel
  ensure_cloudflared
  ensure_cloudflared_login

  local tunnel_id
  tunnel_id="$(create_tunnel_if_missing "${tunnel_name}")"
  route_dns "${tunnel_id}" "${hostname}"
  write_cloudflared_config "${tunnel_id}" "${hostname}"
  write_systemd_service "${cf_protocol}"

  echo
  ok "HOÀN TẤT!"
  echo "   - n8n qua Cloudflare:  https://${hostname}"
  echo "   - Local:              http://127.0.0.1:5678"
  echo
  echo "Gợi ý nếu vẫn gặp 'Connection lost' / bị quay lại setup:"
  echo "  - Thử đổi N8N_PUSH_BACKEND sang 'sse' (ổn định hơn khi WS bị chặn/flaky)"
  echo "  - Nếu cloudflared dùng QUIC không ổn, đổi Cloudflared protocol sang 'http2'"
  echo "  - Xoá cookies/site data của https://${hostname} và thử lại"
  echo
  pause
}

action_status() {
  echo "============================================================"
  echo "=== TRẠNG THÁI n8n + tunnel ==="
  echo "============================================================"

  local install_dir
  install_dir="$(prompt_default "Thư mục cài n8n" "${DEFAULT_INSTALL_DIR}")"

  if [[ -f "${install_dir}/${COMPOSE_FILE_NAME}" ]]; then
    info "Docker containers:"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | sed 's/^/  /'
    echo
    info "Local healthz:"
    curl -sS -i http://127.0.0.1:5678/healthz 2>/dev/null | sed 's/^/  /' || true
    echo
  else
    warn "Không thấy compose file tại ${install_dir}/${COMPOSE_FILE_NAME}"
  fi

  echo
  info "Cloudflared service:"
  systemctl --no-pager -l status cloudflared-n8n 2>/dev/null || warn "Không có service cloudflared-n8n."
  echo
  info "Cloudflared logs (tail 50):"
  journalctl -u cloudflared-n8n -n 50 --no-pager 2>/dev/null | sed 's/^/  /' || true

  echo
  pause
}

action_update_n8n_image() {
  echo "============================================================"
  echo "=== UPDATE n8n (pull image mới nhất, giữ data) ==="
  echo "============================================================"
  local install_dir
  install_dir="$(prompt_default "Thư mục cài n8n" "${DEFAULT_INSTALL_DIR}")"
  [[ -f "${install_dir}/${COMPOSE_FILE_NAME}" ]] || die "Không thấy compose file."

  info "Pull image n8n..."
  (cd "${install_dir}" && compose "${install_dir}" --env-file "${install_dir}/${ENV_FILE_NAME}" pull n8n) >/dev/null
  info "Restart service n8n..."
  (cd "${install_dir}" && compose "${install_dir}" --env-file "${install_dir}/${ENV_FILE_NAME}" up -d) >/dev/null
  ok "Đã update & restart n8n."

  wait_for_n8n 60 2 || true
  pause
}

action_uninstall() {
  echo "============================================================"
  echo "=== GỠ n8n + service + (tuỳ chọn) xoá data & volume & tunnel ==="
  echo "============================================================"

  local install_dir
  install_dir="$(prompt_default "Thư mục cài n8n" "${DEFAULT_INSTALL_DIR}")"

  if [[ -f "${install_dir}/${COMPOSE_FILE_NAME}" ]]; then
    info "Dừng stack..."
    (cd "${install_dir}" && compose "${install_dir}" --env-file "${install_dir}/${ENV_FILE_NAME}" down) >/dev/null || true
    ok "Đã dừng stack."
  else
    warn "Không thấy compose file, bỏ qua docker down."
  fi

  if systemctl list-unit-files | grep -q '^cloudflared-n8n\.service'; then
    info "Stop & disable cloudflared service..."
    systemctl stop cloudflared-n8n || true
    systemctl disable cloudflared-n8n || true
    rm -f "${SYSTEMD_SERVICE}"
    systemctl daemon-reload
    ok "Đã gỡ service cloudflared-n8n."
  fi

  read -r -p "Bạn có muốn xoá data dir & postgres volume không? [y/N]: " yn
  if [[ "${yn}" =~ ^[Yy]$ ]]; then
    local data_dir="${DEFAULT_DATA_DIR}"
    if [[ -f "${install_dir}/${ENV_FILE_NAME}" ]]; then
      data_dir="$(grep '^N8N_DATA_DIR=' "${install_dir}/${ENV_FILE_NAME}" | head -n1 | cut -d= -f2- || echo "${DEFAULT_DATA_DIR}")"
    fi
    warn "Xoá data dir: ${data_dir}"
    rm -rf "${data_dir}" || true
    warn "Xoá volume: n8n_postgres_data"
    docker volume rm n8n_postgres_data >/dev/null 2>&1 || true
    ok "Đã xoá data & volume."
  fi

  read -r -p "Bạn có muốn xoá Cloudflare tunnel + DNS route không? (nguy hiểm) [y/N]: " yn2
  if [[ "${yn2}" =~ ^[Yy]$ ]]; then
    ensure_cloudflared
    ensure_cloudflared_login

    local tunnel_name hostname tunnel_id
    hostname="$(prompt_default "Hostname" "${DEFAULT_HOSTNAME}")"
    tunnel_name="$(prompt_default "Tunnel name" "${DEFAULT_TUNNEL_NAME}")"
    tunnel_id="$(get_tunnel_id_by_name "${tunnel_name}" || true)"

    if [[ -n "${tunnel_id}" && "${tunnel_id}" != "null" ]]; then
      info "Xoá DNS route..."
      "${CLOUDFLARED_BIN}" tunnel route dns delete "${tunnel_id}" "${hostname}" >/dev/null 2>&1 || true
      info "Xoá tunnel..."
      "${CLOUDFLARED_BIN}" tunnel delete "${tunnel_id}" -f >/dev/null 2>&1 || true
      ok "Đã xoá tunnel + DNS (nếu quyền cho phép)."
    else
      warn "Không tìm thấy tunnel '${tunnel_name}'."
    fi
  fi

  ok "Gỡ xong."
  pause
}

# -------------------------------
# Main menu
# -------------------------------
main_menu() {
  while true; do
    banner
    cat <<EOF
1) Cài / cập nhật n8n + tunnel
2) Kiểm tra trạng thái n8n + tunnel
3) Gỡ n8n + service + (tuỳ chọn) xoá data & volume & tunnel
4) Update n8n (pull image mới nhất, giữ data)
0) Thoát
============================================================
EOF
    read -r -p "Chọn chức năng (0-4): " choice
    case "${choice}" in
      1) action_install_or_update ;;
      2) action_status ;;
      3) action_uninstall ;;
      4) action_update_n8n_image ;;
      0) exit 0 ;;
      *) warn "Lựa chọn không hợp lệ." ;;
    esac
  done
}

# -------------------------------
# Entry
# -------------------------------
need_root
ensure_deps
main_menu
