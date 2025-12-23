#!/usr/bin/env bash
# n8n_manager.sh v1.0.2
# Changelog v1.0.2:
# - Fix: Cloudflared DNS route command mismatch (no --overwrite-dns on some versions) -> auto-detect + fallback delete+create
# - Fix: Prevent script from aborting on DNS route failure (continue with clear warnings)
# - Keep: Tunnel ID clean (no stdout contamination), compose uses .env (no YAML password corruption)
# - Keep: N8N_EDITOR_BASE_URL + N8N_PROXY_HOPS=1 to reduce setup loop / logout / invalid origin behind Tunnel

set -Eeuo pipefail

VERSION="1.0.2"

# ---------- UI ----------
hr() { printf "%s\n" "============================================================"; }
title() {
  hr
  printf " n8n MANAGER + CLOUDFLARE TUNNEL (v%s)\n" "$VERSION"
  hr
}
log()  { printf "%b\n" "$*" >&2; }
ok()   { log "✅ $*"; }
warn() { log "⚠ $*"; }
die()  { log "❌ $*"; exit 1; }

pause() { read -r -p "Nhấn Enter để tiếp tục..." _ || true; }

need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Vui lòng chạy bằng root."; }

# ---------- Defaults ----------
DEFAULT_HOST="n8n.rawcode.io"
DEFAULT_TUNNEL_NAME="n8n-tunnel"
DEFAULT_INSTALL_DIR="/opt/n8n"
DEFAULT_TZ="Asia/Ho_Chi_Minh"

DEFAULT_DB_NAME="n8n"
DEFAULT_DB_USER="n8n"

DEFAULT_N8N_IMAGE="docker.n8n.io/n8nio/n8n"
DEFAULT_POSTGRES_IMAGE="postgres:16"

DEFAULT_DATA_DIR="/root/.n8n"
DEFAULT_PG_VOLUME="n8n_postgres_data"
LOCAL_PORT="5678"

# ---------- Helpers ----------
prompt_default() {
  local q="$1" def="$2" __var="$3"
  local val
  read -r -p "$q [$def]: " val
  val="${val:-$def}"
  printf -v "$__var" "%s" "$val"
}

read_password_confirm() {
  local prompt="$1" __var="$2"
  local p1="" p2=""
  while true; do
    read -r -s -p "$prompt: " p1; echo >&2
    read -r -s -p "Nhập lại mật khẩu PostgreSQL: " p2; echo >&2
    [[ -n "$p1" ]] || { warn "Mật khẩu không được rỗng."; continue; }
    [[ "$p1" == "$p2" ]] || { warn "Mật khẩu không khớp, thử lại."; continue; }
    printf -v "$__var" "%s" "$p1"
    return 0
  done
}

dotenv_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf "%s" "$s"
}

ensure_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y curl ca-certificates jq gnupg lsb-release >/dev/null 2>&1 || true
}

ensure_docker() {
  command -v docker >/dev/null 2>&1 || die "Chưa có docker. Hãy cài Docker trước."
  docker compose version >/dev/null 2>&1 || die "Chưa có docker compose plugin. Hãy cài docker-compose-plugin."
}

install_cloudflared_if_missing() {
  if command -v cloudflared >/dev/null 2>&1; then return 0; fi

  ensure_packages
  local arch deb
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) deb="cloudflared-linux-amd64.deb" ;;
    aarch64|arm64) deb="cloudflared-linux-arm64.deb" ;;
    *) die "Không hỗ trợ arch: $arch" ;;
  esac

  log "▶ Cài cloudflared ($arch)..."
  curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/${deb}" -o "/tmp/${deb}"
  dpkg -i "/tmp/${deb}" >/dev/null 2>&1 || apt-get -f install -y >/dev/null 2>&1
  rm -f "/tmp/${deb}"
  command -v cloudflared >/dev/null 2>&1 || die "Cài cloudflared thất bại."
  ok "Đã cài cloudflared."
}

ensure_cloudflared_cert() {
  local cert="/root/.cloudflared/cert.pem"
  if [[ ! -f "$cert" ]]; then
    warn "Không thấy $cert."
    warn "Hãy chạy: cloudflared tunnel login"
    warn "Sau khi login xong (tạo cert.pem), chạy lại script."
    return 1
  fi
  return 0
}

compose_cmd() {
  local dir="$1"; shift
  docker compose -f "$dir/docker-compose.yml" --env-file "$dir/.env" "$@"
}

# ---------- Cloudflared tunnel ----------
get_tunnel_id_by_name() {
  local name="$1"
  cloudflared tunnel list 2>/dev/null | awk -v n="$name" '$2==n {print $1; exit}'
}

ensure_tunnel() {
  local name="$1"
  local id
  id="$(get_tunnel_id_by_name "$name" || true)"
  if [[ -n "${id:-}" ]]; then
    printf "%s" "$id"
    return 0
  fi

  log "▶ Tạo tunnel mới '$name'..."
  cloudflared tunnel create "$name" >/dev/null 2>&1 || true
  id="$(get_tunnel_id_by_name "$name" || true)"
  [[ -n "${id:-}" ]] || die "Không lấy được Tunnel ID sau khi tạo tunnel."
  printf "%s" "$id"
}

find_credentials_file() {
  local tunnel_id="$1"
  local p
  for p in "/root/.cloudflared/${tunnel_id}.json" "/etc/cloudflared/${tunnel_id}.json"; do
    [[ -f "$p" ]] && { printf "%s" "$p"; return 0; }
  done
  p="$(find /root -maxdepth 3 -type f -name "${tunnel_id}.json" 2>/dev/null | head -n1 || true)"
  [[ -n "${p:-}" ]] && { printf "%s" "$p"; return 0; }
  return 1
}

cloudflared_supports_flag() {
  local help_txt="$1" flag="$2"
  echo "$help_txt" | grep -q -- "$flag"
}

route_dns_safely() {
  local tunnel_id="$1"
  local hostname="$2"

  log "▶ Tạo / cập nhật DNS record cho ${hostname} (trỏ về ${tunnel_id}.cfargotunnel.com)..."

  local help_dns help_del
  help_dns="$(cloudflared tunnel route dns --help 2>&1 || true)"
  help_del="$(cloudflared tunnel route dns delete --help 2>&1 || true)"

  # 1) Nếu có overwrite flag -> dùng luôn
  if cloudflared_supports_flag "$help_dns" "--overwrite-dns"; then
    if cloudflared tunnel route dns "$tunnel_id" "$hostname" --overwrite-dns; then
      ok "Đã tạo/cập nhật CNAME cho ${hostname} (overwrite-dns)."
      return 0
    fi
    warn "Không overwrite được DNS bằng --overwrite-dns. Sẽ thử fallback."
  fi

  # 2) Thử tạo route không overwrite
  if cloudflared tunnel route dns "$tunnel_id" "$hostname"; then
    ok "Đã tạo/cập nhật CNAME cho ${hostname}."
    return 0
  fi

  warn "Không tạo được route DNS (có thể record đã tồn tại hoặc permission). Thử xoá route cũ rồi tạo lại..."

  # 3) Fallback: delete route cũ theo syntax mà CLI hỗ trợ
  # Một số bản: `cloudflared tunnel route dns delete <hostname>`
  # Một số bản khác: `cloudflared tunnel route dns delete <tunnel> <hostname>`
  if echo "$help_del" | grep -qE "delete.*<hostname>"; then
    cloudflared tunnel route dns delete "$hostname" >/dev/null 2>&1 || true
  elif echo "$help_del" | grep -qE "delete.*<tunnel"; then
    cloudflared tunnel route dns delete "$tunnel_id" "$hostname" >/dev/null 2>&1 || true
  else
    warn "Không nhận diện được cú pháp delete route DNS trên cloudflared bản này. Bạn cần xoá CNAME thủ công trong Cloudflare Dashboard."
    return 1
  fi

  # 4) Tạo lại
  if cloudflared tunnel route dns "$tunnel_id" "$hostname"; then
    ok "Đã tạo lại CNAME cho ${hostname} sau khi xoá route cũ."
    return 0
  fi

  warn "Vẫn không tạo được CNAME qua cloudflared. Hãy kiểm tra quyền account hoặc sửa trong Cloudflare Dashboard:"
  warn " - Record: ${hostname}  ->  ${tunnel_id}.cfargotunnel.com"
  return 1
}

write_tunnel_config_and_service() {
  local tunnel_id="$1" cred_file="$2" hostname="$3"

  mkdir -p /etc/cloudflared

  local cfg="/etc/cloudflared/n8n-tunnel.yml"
  cat >"$cfg" <<EOF
tunnel: ${tunnel_id}
credentials-file: ${cred_file}

ingress:
  - hostname: ${hostname}
    service: http://127.0.0.1:${LOCAL_PORT}
  - service: http_status:404
EOF

  local svc="/etc/systemd/system/cloudflared-n8n.service"
  cat >"$svc" <<EOF
[Unit]
Description=Cloudflare Tunnel - ${hostname} (n8n)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared --no-autoupdate --config ${cfg} tunnel run
Restart=on-failure
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now cloudflared-n8n.service >/dev/null 2>&1 || true
}

# ---------- n8n deploy ----------
write_compose() {
  local dir="$1"
  mkdir -p "$dir"
  cat >"$dir/docker-compose.yml" <<'EOF'
services:
  n8n-postgres:
    image: ${POSTGRES_IMAGE}
    container_name: n8n-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
      TZ: ${TZ}
    volumes:
      - n8n_postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $$POSTGRES_USER -d $$POSTGRES_DB"]
      interval: 10s
      timeout: 5s
      retries: 15

  n8n:
    image: ${N8N_IMAGE}
    container_name: n8n
    restart: unless-stopped
    depends_on:
      n8n-postgres:
        condition: service_healthy
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: n8n-postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: ${POSTGRES_DB}
      DB_POSTGRESDB_USER: ${POSTGRES_USER}
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}

      N8N_HOST: ${N8N_HOST}
      N8N_PROTOCOL: https
      N8N_PORT: 5678
      N8N_EDITOR_BASE_URL: ${N8N_EDITOR_BASE_URL}
      WEBHOOK_URL: ${WEBHOOK_URL}
      N8N_PROXY_HOPS: 1

      TZ: ${TZ}
      GENERIC_TIMEZONE: ${TZ}
      N8N_DIAGNOSTICS_ENABLED: "false"
    ports:
      - "127.0.0.1:5678:5678"
    volumes:
      - "${N8N_DATA_DIR}:/home/node/.n8n"

volumes:
  n8n_postgres_data:
    name: ${POSTGRES_VOLUME}
EOF
  ok "Đã ghi $dir/docker-compose.yml"
}

write_env() {
  local dir="$1"
  local esc_db_pass esc_host esc_tz esc_db esc_user esc_n8n_image esc_pg_image esc_data esc_editor esc_webhook esc_pgvol

  esc_db_pass="$(dotenv_escape "$POSTGRES_PASSWORD")"
  esc_host="$(dotenv_escape "$N8N_HOST")"
  esc_tz="$(dotenv_escape "$TZ")"
  esc_db="$(dotenv_escape "$POSTGRES_DB")"
  esc_user="$(dotenv_escape "$POSTGRES_USER")"
  esc_n8n_image="$(dotenv_escape "$N8N_IMAGE")"
  esc_pg_image="$(dotenv_escape "$POSTGRES_IMAGE")"
  esc_data="$(dotenv_escape "$N8N_DATA_DIR")"
  esc_editor="$(dotenv_escape "$N8N_EDITOR_BASE_URL")"
  esc_webhook="$(dotenv_escape "$WEBHOOK_URL")"
  esc_pgvol="$(dotenv_escape "$POSTGRES_VOLUME")"

  cat >"$dir/.env" <<EOF
N8N_IMAGE="${esc_n8n_image}"
POSTGRES_IMAGE="${esc_pg_image}"

N8N_HOST="${esc_host}"
N8N_EDITOR_BASE_URL="${esc_editor}"
WEBHOOK_URL="${esc_webhook}"

TZ="${esc_tz}"

POSTGRES_DB="${esc_db}"
POSTGRES_USER="${esc_user}"
POSTGRES_PASSWORD="${esc_db_pass}"
POSTGRES_VOLUME="${esc_pgvol}"

N8N_DATA_DIR="${esc_data}"
EOF

  chmod 600 "$dir/.env"
  ok "Đã ghi $dir/.env"
}

ensure_data_dir() {
  local d="$1"
  mkdir -p "$d"
  chown 1000:1000 "$d" || true
  chmod 700 "$d" || true
}

wait_local_n8n() {
  local tries=30 code=""
  while ((tries>0)); do
    code="$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${LOCAL_PORT}/" || true)"
    if [[ "$code" != "000" ]]; then
      log "▶ Thử curl local n8n: HTTP code: $code"
      return 0
    fi
    sleep 1
    tries=$((tries-1))
  done
  warn "Không curl được local n8n (có thể vẫn đang khởi động)."
}

# ---------- Actions ----------
action_install() {
  hr
  log "=== CÀI ĐẶT / CẬP NHẬT n8n + PostgreSQL + Cloudflare Tunnel ==="
  hr

  prompt_default "Hostname cho n8n" "$DEFAULT_HOST" N8N_HOST
  prompt_default "Tên tunnel" "$DEFAULT_TUNNEL_NAME" TUNNEL_NAME
  prompt_default "Thư mục cài n8n" "$DEFAULT_INSTALL_DIR" INSTALL_DIR
  prompt_default "Timezone" "$DEFAULT_TZ" TZ
  prompt_default "Tên database PostgreSQL" "$DEFAULT_DB_NAME" POSTGRES_DB
  prompt_default "User database PostgreSQL" "$DEFAULT_DB_USER" POSTGRES_USER

  log "ℹ️ Lưu ý: khi nhập mật khẩu, terminal sẽ KHÔNG hiện ký tự."
  read_password_confirm "Mật khẩu database PostgreSQL" POSTGRES_PASSWORD

  prompt_default "Image n8n" "$DEFAULT_N8N_IMAGE" N8N_IMAGE
  prompt_default "Image PostgreSQL" "$DEFAULT_POSTGRES_IMAGE" POSTGRES_IMAGE

  POSTGRES_VOLUME="$DEFAULT_PG_VOLUME"
  N8N_DATA_DIR="$DEFAULT_DATA_DIR"
  N8N_EDITOR_BASE_URL="https://${N8N_HOST}"
  WEBHOOK_URL="https://${N8N_HOST}/"

  hr
  log "📌 Tóm tắt:"
  log "   - Hostname:        ${N8N_HOST}"
  log "   - Tunnel name:     ${TUNNEL_NAME}"
  log "   - Install dir:     ${INSTALL_DIR}"
  log "   - Timezone:        ${TZ}"
  log "   - DB:              ${POSTGRES_DB}"
  log "   - DB user:         ${POSTGRES_USER}"
  log "   - DB password:     (ẩn)"
  log "   - Postgres image:  ${POSTGRES_IMAGE}"
  log "   - n8n image:       ${N8N_IMAGE}"
  log "   - Data dir:        ${N8N_DATA_DIR} (mount vào /home/node/.n8n)"
  log "   - Postgres volume: ${POSTGRES_VOLUME}"
  hr

  read -r -p "Tiếp tục cài đặt? [y/N]: " yn
  [[ "${yn:-N}" =~ ^[yY]$ ]] || { warn "Hủy."; return 0; }

  ensure_packages
  ensure_docker
  install_cloudflared_if_missing

  log "▶ Đảm bảo thư mục data ${N8N_DATA_DIR} tồn tại..."
  ensure_data_dir "$N8N_DATA_DIR"

  write_compose "$INSTALL_DIR"
  write_env "$INSTALL_DIR"

  log "ℹ️ Triển khai stack n8n + PostgreSQL..."
  compose_cmd "$INSTALL_DIR" pull >/dev/null 2>&1 || true
  compose_cmd "$INSTALL_DIR" up -d

  ok "n8n đã khởi động local: http://127.0.0.1:${LOCAL_PORT}"
  wait_local_n8n || true

  if ! ensure_cloudflared_cert; then
    warn "Bỏ qua bước tạo tunnel/DNS vì chưa có cert.pem."
    warn "Sau khi chạy 'cloudflared tunnel login', chạy lại option (1)."
    return 0
  fi

  local TUNNEL_ID CRED_FILE
  TUNNEL_ID="$(ensure_tunnel "$TUNNEL_NAME")"
  ok "Tunnel ID: ${TUNNEL_ID}"

  if ! CRED_FILE="$(find_credentials_file "$TUNNEL_ID")"; then
    die "Thiếu credentials file: ${TUNNEL_ID}.json (thường ở /root/.cloudflared/)."
  fi
  ok "Credentials: ${CRED_FILE}"

  # DNS route: không được phép làm script chết giữa chừng nữa
  route_dns_safely "$TUNNEL_ID" "$N8N_HOST" || warn "DNS route chưa cập nhật được tự động. Bạn có thể cập nhật thủ công trong Cloudflare Dashboard."

  # Ghi YAML + systemd
  write_tunnel_config_and_service "$TUNNEL_ID" "$CRED_FILE" "$N8N_HOST"
  systemctl restart cloudflared-n8n.service >/dev/null 2>&1 || true

  ok "Cloudflare Tunnel service đã chạy: cloudflared-n8n.service"
  hr
  ok "HOÀN TẤT!"
  log "   - n8n qua Cloudflare:  https://${N8N_HOST}"
  log "   - Local:              http://127.0.0.1:${LOCAL_PORT}"
  log "   - CNAME đúng phải trỏ: ${TUNNEL_ID}.cfargotunnel.com"
  hr
  pause
}

action_status() {
  hr
  log "=== TRẠNG THÁI n8n + TUNNEL ==="
  hr

  log ""
  log "▶ Docker containers:"
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | sed 's/\t/  /g' || true

  log ""
  log "▶ Docker volumes (grep n8n):"
  docker volume ls --format "table {{.Driver}}\t{{.Name}}" | grep -i n8n || true

  log ""
  log "▶ Systemd service cloudflared-n8n:"
  systemctl status cloudflared-n8n.service -n 40 --no-pager || true

  if command -v cloudflared >/dev/null 2>&1; then
    log ""
    log "▶ Tunnel list (grep n8n):"
    cloudflared tunnel list 2>/dev/null | grep -i n8n || true
  fi

  log ""
  if [[ -f /etc/cloudflared/n8n-tunnel.yml ]]; then
    log "▶ /etc/cloudflared/n8n-tunnel.yml:"
    sed 's/^/   /' /etc/cloudflared/n8n-tunnel.yml || true
  fi

  pause
}

action_uninstall() {
  hr
  log "=== GỠ n8n + Cloudflare Tunnel (local) ==="
  hr

  read -r -p "Bạn chắc chắn muốn gỡ n8n (container + service tunnel local)? [y/N]: " yn
  [[ "${yn:-N}" =~ ^[yY]$ ]] || { warn "Hủy."; return 0; }

  local INSTALL_DIR="$DEFAULT_INSTALL_DIR"
  if [[ -f "$INSTALL_DIR/.env" ]]; then
    set +u
    # shellcheck disable=SC1090
    source "$INSTALL_DIR/.env" || true
    set -u
  fi

  log "▶ Dừng & xoá container n8n / n8n-postgres (nếu có)..."
  if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    compose_cmd "$INSTALL_DIR" down >/dev/null 2>&1 || true
  else
    docker rm -f n8n n8n-postgres >/dev/null 2>&1 || true
  fi

  log "▶ Dừng & xoá systemd service cloudflared-n8n..."
  systemctl disable --now cloudflared-n8n.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/cloudflared-n8n.service
  systemctl daemon-reload >/dev/null 2>&1 || true

  local data_dir="${N8N_DATA_DIR:-$DEFAULT_DATA_DIR}"
  read -r -p "Bạn có muốn XOÁ thư mục data '${data_dir}' (mất workflows/credentials/settings)? [y/N]: " yn
  if [[ "${yn:-N}" =~ ^[yY]$ ]]; then
    rm -rf "$data_dir"
    ok "Đã xoá $data_dir"
  fi

  read -r -p "Bạn có muốn XOÁ thư mục cài đặt '${INSTALL_DIR}' (compose/.env)? [y/N]: " yn
  if [[ "${yn:-N}" =~ ^[yY]$ ]]; then
    rm -rf "$INSTALL_DIR"
    ok "Đã xoá $INSTALL_DIR"
  fi

  local pgvol="${POSTGRES_VOLUME:-$DEFAULT_PG_VOLUME}"
  local vols=()
  while IFS= read -r v; do vols+=("$v"); done < <(docker volume ls --format '{{.Name}}' | grep -E "^${pgvol}$|^n8n_.*postgres.*data$|^n8n_n8n_postgres_data$" || true)

  if ((${#vols[@]} > 0)); then
    log "Các Docker volume Postgres liên quan đến n8n được tìm thấy:"
    for v in "${vols[@]}"; do log "   - $v"; done
    read -r -p "Bạn có muốn XOÁ các volume này (XOÁ TOÀN BỘ DB n8n)? [y/N]: " yn
    if [[ "${yn:-N}" =~ ^[yY]$ ]]; then
      docker volume rm "${vols[@]}" >/dev/null 2>&1 || true
      ok "Đã xoá volume DB."
    fi
  fi

  if [[ -f /etc/cloudflared/n8n-tunnel.yml ]]; then
    local tid
    tid="$(awk '/^tunnel:/ {print $2}' /etc/cloudflared/n8n-tunnel.yml | tr -d '\r' || true)"
    log ""
    log "▶ Tunnel ID từ config: ${tid:-N/A}"
    read -r -p "Bạn có muốn XOÁ Cloudflare Tunnel khỏi account (cloudflared tunnel delete)? [y/N]: " yn
    if [[ "${yn:-N}" =~ ^[yY]$ ]]; then
      command -v cloudflared >/dev/null 2>&1 || warn "Thiếu cloudflared."
      [[ -n "${tid:-}" ]] && cloudflared tunnel delete "$tid" || true
    fi

    read -r -p "Bạn có muốn XOÁ file cấu hình local '/etc/cloudflared/n8n-tunnel.yml'? [y/N]: " yn
    if [[ "${yn:-N}" =~ ^[yY]$ ]]; then
      rm -f /etc/cloudflared/n8n-tunnel.yml
      ok "Đã xoá file cấu hình tunnel local."
    fi
  fi

  warn "Về Cloudflare DNS: nếu không dùng nữa, hãy xoá CNAME n8n.rawcode.io trong Cloudflare Dashboard."
  ok "Đã gỡ n8n + tunnel local (theo lựa chọn của bạn)."
  pause
}

action_update() {
  hr
  log "=== UPDATE n8n (pull image mới nhất, GIỮ DATA) ==="
  hr

  local INSTALL_DIR="$DEFAULT_INSTALL_DIR"
  [[ -f "$INSTALL_DIR/docker-compose.yml" ]] || die "Không thấy $INSTALL_DIR/docker-compose.yml"

  read -r -p "Update n8n ngay bây giờ (pull + recreate n8n, giữ DB & ~/.n8n)? [y/N]: " yn
  [[ "${yn:-N}" =~ ^[yY]$ ]] || { warn "Hủy."; return 0; }

  log "▶ Pull image n8n..."
  compose_cmd "$INSTALL_DIR" pull n8n

  log "▶ Recreate container n8n (không đụng DB volume)..."
  compose_cmd "$INSTALL_DIR" up -d --no-deps n8n

  ok "Đã update n8n."
  pause
}

main() {
  need_root
  while true; do
    title
    echo "1) Cài / cập nhật n8n + tunnel"
    echo "2) Kiểm tra trạng thái n8n + tunnel"
    echo "3) Gỡ n8n + service + (tuỳ chọn) xoá data & volume & tunnel"
    echo "4) Update n8n (pull image mới nhất, giữ data)"
    echo "0) Thoát"
    hr
    read -r -p "Chọn chức năng (0-4): " choice
    case "${choice:-}" in
      1) action_install ;;
      2) action_status ;;
      3) action_uninstall ;;
      4) action_update ;;
      0) exit 0 ;;
      *) warn "Lựa chọn không hợp lệ." ; sleep 1 ;;
    esac
  done
}

main "$@"
