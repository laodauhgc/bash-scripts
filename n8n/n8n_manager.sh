#!/usr/bin/env bash



# n8n_manager.sh - v1.0.2

set -o pipefail

SCRIPT_VERSION="v1.0.2"

# ---------- UI ----------
RED="\033[0;31m"
GRN="\033[0;32m"
YEL="\033[0;33m"
BLU="\033[0;34m"
NC="\033[0m"

log()  { echo -e "${GRN}$*${NC}" >&2; }
info() { echo -e "${BLU}$*${NC}" >&2; }
warn() { echo -e "${YEL}$*${NC}" >&2; }
err()  { echo -e "${RED}$*${NC}" >&2; }

pause() { read -r -p "Nhấn Enter để tiếp tục..." _; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Vui lòng chạy script bằng root."
    exit 1
  fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

compose_cmd() {
  if has_cmd docker && docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif has_cmd docker-compose; then
    echo "docker-compose"
  else
    echo ""
  fi
}

# ---------- Helpers ----------
sanitize_oneline() {
  # strip CR/LF
  printf "%s" "$1" | tr -d '\r\n'
}

rand_secret() {
  # 64-hex stable key
  if has_cmd openssl; then
    openssl rand -hex 32
  else
    tr -dc 'a-f0-9' </dev/urandom | head -c 64
  fi
}

prompt_default() {
  # usage: prompt_default "Question" "default" -> prints value (stdout)
  local q="$1" d="$2" v=""
  read -r -p "$q [$d]: " v
  v="$(sanitize_oneline "$v")"
  if [[ -z "$v" ]]; then v="$d"; fi
  printf "%s" "$v"
}

prompt_secret_twice() {
  # usage: prompt_secret_twice "Label" -> prints value (stdout)
  local label="$1"
  local a="" b=""
  while true; do
    info "ℹ️ Lưu ý: khi nhập mật khẩu, terminal sẽ KHÔNG hiện ký tự."
    read -r -s -p "${label}: " a; echo >&2
    read -r -s -p "Nhập lại ${label}: " b; echo >&2
    a="$(sanitize_oneline "$a")"
    b="$(sanitize_oneline "$b")"
    if [[ -z "$a" ]]; then
      warn "Mật khẩu không được rỗng. Nhập lại."
      continue
    fi
    if [[ "$a" != "$b" ]]; then
      warn "Hai lần nhập không khớp. Nhập lại."
      continue
    fi
    printf "%s" "$a"
    return 0
  done
}

ensure_packages() {
  # tối thiểu cho script
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y curl ca-certificates gnupg lsb-release >/dev/null 2>&1 || true
}

ensure_docker() {
  if has_cmd docker && [[ -n "$(compose_cmd)" ]]; then
    return 0
  fi
  warn "Docker/Docker Compose chưa có. Đang cài đặt (Ubuntu/Debian)..."
  ensure_packages
  if ! has_cmd docker; then
    apt-get install -y docker.io >/dev/null 2>&1 || true
    systemctl enable --now docker >/dev/null 2>&1 || true
  fi
  # compose plugin (nếu cần)
  if has_cmd docker && ! docker compose version >/dev/null 2>&1; then
    apt-get install -y docker-compose-plugin >/dev/null 2>&1 || true
  fi
  if [[ -z "$(compose_cmd)" ]]; then
    err "Không cài được docker compose. Hãy cài thủ công: docker + docker compose plugin."
    exit 1
  fi
}

ensure_cloudflared() {
  if has_cmd cloudflared; then
    return 0
  fi
  warn "cloudflared chưa có. Đang cài đặt..."
  ensure_packages
  # Cloudflare repo install (Ubuntu/Debian). Nếu fail, user tự cài.
  if curl -fsSL https://pkg.cloudflare.com/cloudflared-ascii.gpg | gpg --dearmor -o /usr/share/keyrings/cloudflare-cloudflared.gpg >/dev/null 2>&1; then
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-cloudflared.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" \
      > /etc/apt/sources.list.d/cloudflared.list
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y cloudflared >/dev/null 2>&1 || true
  fi
  if ! has_cmd cloudflared; then
    err "Không cài được cloudflared tự động. Hãy cài thủ công theo Cloudflare docs rồi chạy lại."
    exit 1
  fi
}

ensure_cf_login() {
  # cloudflared tunnel login tạo cert.pem trong ~/.cloudflared
  if [[ -f /root/.cloudflared/cert.pem ]]; then
    return 0
  fi
  err "Chưa thấy /root/.cloudflared/cert.pem (chưa cloudflared tunnel login)."
  echo >&2
  echo "Chạy lệnh sau trên server rồi đăng nhập Cloudflare 1 lần:" >&2
  echo "  cloudflared tunnel login" >&2
  echo >&2
  exit 1
}

normalize_no_trailing_slash() {
  local s="$1"
  # remove trailing slash
  while [[ "$s" == */ ]]; do s="${s%/}"; done
  printf "%s" "$s"
}

# ---------- Paths/Defaults ----------
DEFAULT_HOST="n8n.rawcode.io"
DEFAULT_TUNNEL="n8n-tunnel"
DEFAULT_DIR="/opt/n8n"
DEFAULT_TZ="Asia/Ho_Chi_Minh"
DEFAULT_DB="n8n"
DEFAULT_DBUSER="n8n"
DEFAULT_N8N_IMAGE="docker.n8n.io/n8nio/n8n"
DEFAULT_PG_IMAGE="postgres:16"
DEFAULT_DATA_DIR="/root/.n8n"
DEFAULT_PG_VOL="n8n_postgres_data"

# ---------- Core: write compose/env ----------
write_compose_and_env() {
  local install_dir="$1"
  local n8n_host="$2"
  local tz="$3"
  local db="$4"
  local dbuser="$5"
  local dbpass="$6"
  local n8n_image="$7"
  local pg_image="$8"
  local data_dir="$9"
  local pg_vol="${10}"

  local editor_base webhook_url enc_key push_backend
  editor_base="https://$(normalize_no_trailing_slash "$n8n_host")"
  webhook_url="https://$(normalize_no_trailing_slash "$n8n_host")"

  push_backend="sse" # FIX: ổn định sau proxy/tunnel :contentReference[oaicite:3]{index=3}

  mkdir -p "$install_dir"
  chmod 755 "$install_dir"

  # Ensure encryption key stable (ưu tiên giữ nếu đã có trong .env cũ)
  if [[ -f "$install_dir/.env" ]]; then
    local existing
    existing="$(grep -E '^N8N_ENCRYPTION_KEY=' "$install_dir/.env" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
    existing="$(sanitize_oneline "$existing")"
    if [[ -n "$existing" ]]; then
      enc_key="$existing"
    else
      enc_key="$(rand_secret)"
    fi
  else
    enc_key="$(rand_secret)"
  fi

  # data dir permissions
  info "▶ Đảm bảo thư mục data $data_dir tồn tại..."
  mkdir -p "$data_dir"
  chown 1000:1000 "$data_dir"
  chmod 700 "$data_dir"

  # Write docker-compose.yml (NO variable expansion by bash)
  cat >"$install_dir/docker-compose.yml" <<'YAML'
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

      # FIX: Push backend SSE để tránh “Connection lost / Invalid origin” sau proxy/tunnel
      N8N_PUSH_BACKEND: ${N8N_PUSH_BACKEND}

      # FIX: cố định encryption key để tránh auto-generate mỗi restart => vỡ session/logout/setup loop
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}

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
YAML

  # Write .env (không quote để compose đọc sạch)
  cat >"$install_dir/.env" <<EOF
N8N_IMAGE=$n8n_image
POSTGRES_IMAGE=$pg_image

N8N_HOST=$n8n_host
N8N_EDITOR_BASE_URL=$editor_base
WEBHOOK_URL=$webhook_url

N8N_PUSH_BACKEND=$push_backend
N8N_ENCRYPTION_KEY=$enc_key

TZ=$tz

POSTGRES_DB=$db
POSTGRES_USER=$dbuser
POSTGRES_PASSWORD=$dbpass
POSTGRES_VOLUME=$pg_vol

N8N_DATA_DIR=$data_dir
EOF

  chmod 600 "$install_dir/.env"

  log "✅ Đã ghi $install_dir/docker-compose.yml"
  log "✅ Đã ghi $install_dir/.env"
}

docker_up() {
  local install_dir="$1"
  local dc; dc="$(compose_cmd)"
  (cd "$install_dir" && $dc up -d)
}

docker_down() {
  local install_dir="$1"
  local dc; dc="$(compose_cmd)"
  (cd "$install_dir" && $dc down) || true
}

curl_local_n8n() {
  local code
  code="$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5678/ || true)"
  info "▶ Thử curl local n8n: HTTP code: $code"
}

# ---------- Cloudflare tunnel ----------
get_tunnel_id_by_name() {
  local name="$1"
  # output table: ID NAME CREATED
  cloudflared tunnel list 2>/dev/null \
    | awk -v n="$name" 'BEGIN{IGNORECASE=0} $1 ~ /^[0-9a-f-]{36}$/ && $2==n {print $1; exit}'
}

create_tunnel() {
  local name="$1"
  local out id
  out="$(cloudflared tunnel create "$name" 2>&1 || true)"
  # parse uuid from line containing "with id" or "Created tunnel"
  id="$(echo "$out" | awk 'match($0, /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/){print substr($0,RSTART,RLENGTH); exit}')"
  if [[ -z "$id" ]]; then
    err "Không tạo được tunnel. Output:"
    echo "$out" >&2
    return 1
  fi
  printf "%s" "$id"
}

find_cred_file() {
  local id="$1"
  local f="/root/.cloudflared/${id}.json"
  if [[ -f "$f" ]]; then
    printf "%s" "$f"
    return 0
  fi
  # fallback find
  f="$(find /root/.cloudflared -maxdepth 1 -type f -name "${id}.json" -print -quit 2>/dev/null || true)"
  if [[ -n "$f" && -f "$f" ]]; then
    printf "%s" "$f"
    return 0
  fi
  return 1
}

write_cloudflared_config() {
  local tunnel_id="$1"
  local cred_file="$2"
  local hostname="$3"
  local cfg="/etc/cloudflared/n8n-tunnel.yml"

  mkdir -p /etc/cloudflared

  cat >"$cfg" <<EOF
tunnel: $tunnel_id
credentials-file: $cred_file

ingress:
  - hostname: $hostname
    service: http://127.0.0.1:5678
    originRequest:
      httpHostHeader: $hostname
  - service: http_status:404
EOF

  log "✅ Đã ghi config tunnel: $cfg"
}

write_systemd_service() {
  local svc="/etc/systemd/system/cloudflared-n8n.service"
  cat >"$svc" <<'EOF'
[Unit]
Description=Cloudflare Tunnel - n8n (cloudflared-n8n)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared --no-autoupdate --config /etc/cloudflared/n8n-tunnel.yml tunnel run
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  # cloudflared binary path có thể là /usr/bin/cloudflared nếu cài bằng apt
  if [[ -x /usr/bin/cloudflared && ! -x /usr/local/bin/cloudflared ]]; then
    sed -i 's|/usr/local/bin/cloudflared|/usr/bin/cloudflared|g' "$svc"
  fi

  systemctl daemon-reload
  systemctl enable --now cloudflared-n8n.service >/dev/null 2>&1 || true
  systemctl restart cloudflared-n8n.service || true
  log "✅ Cloudflare Tunnel service đã chạy: cloudflared-n8n.service"
}

route_dns() {
  local tunnel_id="$1"
  local hostname="$2"

  info "▶ Tạo / cập nhật DNS record cho $hostname ..."
  # CÚ PHÁP ĐÚNG: cloudflared tunnel route dns <tunnel name/id> <hostname>
  local out rc
  out="$(cloudflared tunnel route dns "$tunnel_id" "$hostname" 2>&1)"; rc=$?
  if [[ $rc -ne 0 ]]; then
    warn "⚠ Route DNS thất bại (script vẫn tiếp tục để bạn tự xử lý DNS nếu cần)."
    echo "$out" >&2
    warn "Gợi ý: chạy tay:"
    warn "  cloudflared tunnel route dns $tunnel_id $hostname"
    return 1
  fi
  log "✅ Đã tạo/cập nhật CNAME cho $hostname"
  info "$out"
  return 0
}

setup_tunnel_and_service() {
  local tunnel_name="$1"
  local hostname="$2"

  ensure_cloudflared
  ensure_cf_login

  info "▶ Đảm bảo tunnel '$tunnel_name' tồn tại..."
  local tunnel_id
  tunnel_id="$(get_tunnel_id_by_name "$tunnel_name" || true)"
  if [[ -z "$tunnel_id" ]]; then
    info "▶ Tạo tunnel mới '$tunnel_name'..."
    tunnel_id="$(create_tunnel "$tunnel_name")" || return 1
  else
    info "ℹ️ Tunnel '$tunnel_name' đã tồn tại, dùng lại."
  fi

  local cred_file
  if ! cred_file="$(find_cred_file "$tunnel_id")"; then
    err "Không thấy credentials file cho tunnel id $tunnel_id trong /root/.cloudflared/"
    err "Hãy kiểm tra output 'cloudflared tunnel create' hoặc chạy:"
    err "  ls -la /root/.cloudflared/"
    return 1
  fi

  log "✅ Tunnel ID: $tunnel_id"
  log "✅ Credentials: $cred_file"

  route_dns "$tunnel_id" "$hostname" || true
  write_cloudflared_config "$tunnel_id" "$cred_file" "$hostname"
  write_systemd_service
}

# ---------- Actions ----------
install_or_update() {
  echo "============================================================"
  echo "=== CÀI ĐẶT / CẬP NHẬT n8n + PostgreSQL + Cloudflare Tunnel ==="
  echo "============================================================"

  local n8n_host tunnel_name install_dir tz db dbuser dbpass n8n_image pg_image data_dir pg_vol

  n8n_host="$(prompt_default "Hostname cho n8n" "$DEFAULT_HOST")"; echo >&2
  tunnel_name="$(prompt_default "Tên tunnel" "$DEFAULT_TUNNEL")"; echo >&2
  install_dir="$(prompt_default "Thư mục cài n8n" "$DEFAULT_DIR")"; echo >&2
  tz="$(prompt_default "Timezone" "$DEFAULT_TZ")"; echo >&2
  db="$(prompt_default "Tên database PostgreSQL" "$DEFAULT_DB")"; echo >&2
  dbuser="$(prompt_default "User database PostgreSQL" "$DEFAULT_DBUSER")"; echo >&2
  dbpass="$(prompt_secret_twice "Mật khẩu database PostgreSQL")"; echo >&2
  n8n_image="$(prompt_default "Image n8n" "$DEFAULT_N8N_IMAGE")"; echo >&2
  pg_image="$(prompt_default "Image PostgreSQL" "$DEFAULT_PG_IMAGE")"; echo >&2

  data_dir="$DEFAULT_DATA_DIR"
  pg_vol="$DEFAULT_PG_VOL"

  echo "============================================================" >&2
  echo "📌 Tóm tắt:" >&2
  echo "   - Hostname:        $n8n_host" >&2
  echo "   - Tunnel name:     $tunnel_name" >&2
  echo "   - Install dir:     $install_dir" >&2
  echo "   - Timezone:        $tz" >&2
  echo "   - DB:              $db" >&2
  echo "   - DB user:         $dbuser" >&2
  echo "   - DB password:     (ẩn)" >&2
  echo "   - Postgres image:  $pg_image" >&2
  echo "   - n8n image:       $n8n_image" >&2
  echo "   - Data dir:        $data_dir (mount vào /home/node/.n8n)" >&2
  echo "   - Postgres volume: $pg_vol" >&2
  echo "============================================================" >&2

  local go
  read -r -p "Tiếp tục cài đặt? [y/N]: " go
  go="$(sanitize_oneline "$go")"
  if [[ ! "$go" =~ ^[Yy]$ ]]; then
    warn "Đã huỷ."
    return 0
  fi

  ensure_docker
  ensure_packages

  write_compose_and_env "$install_dir" "$n8n_host" "$tz" "$db" "$dbuser" "$dbpass" "$n8n_image" "$pg_image" "$data_dir" "$pg_vol"

  info "ℹ️ Triển khai stack n8n + PostgreSQL..."
  docker_up "$install_dir"
  log "✅ n8n đã khởi động local: http://127.0.0.1:5678"
  curl_local_n8n

  setup_tunnel_and_service "$tunnel_name" "$n8n_host" || {
    err "Thiết lập tunnel thất bại. n8n local vẫn chạy. Bạn có thể sửa tunnel rồi chạy lại mục (1)."
    return 1
  }

  echo >&2
  log "✅ HOÀN TẤT!"
  echo "   - n8n qua Cloudflare:  https://$n8n_host" >&2
  echo "   - Local:              http://127.0.0.1:5678" >&2
  echo >&2
  info "Nếu vẫn còn 'Connection lost' trên UI:"
  info "  1) Xoá cookies/site data của https://$n8n_host trên trình duyệt"
  info "  2) Restart n8n: (cd $install_dir && $(compose_cmd) restart n8n)"
  info "  3) Xem log n8n: (docker logs -n 200 n8n)"
  pause
}

status_all() {
  echo "============================================================"
  echo "=== TRẠNG THÁI n8n + TUNNEL ==="
  echo "============================================================"

  echo >&2
  info "▶ Docker containers:"
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E '(^NAMES|n8n-postgres|^n8n\s)' || true

  echo >&2
  info "▶ Volume n8n postgres:"
  docker volume ls | grep -E 'n8n_postgres_data|n8n' || true

  echo >&2
  info "▶ Systemd service cloudflared-n8n:"
  systemctl --no-pager -l status cloudflared-n8n.service || true

  echo >&2
  info "▶ Tunnel list (grep n8n):"
  cloudflared tunnel list 2>/dev/null | grep -i n8n || true

  pause
}

uninstall_all() {
  echo "============================================================"
  echo "=== GỠ n8n + Cloudflare Tunnel (local) ==="
  echo "============================================================"

  local install_dir="$DEFAULT_DIR"
  if [[ -d /opt/n8n ]]; then install_dir="/opt/n8n"; fi

  local ok
  read -r -p "Bạn chắc chắn muốn gỡ n8n (containers)? [y/N]: " ok
  ok="$(sanitize_oneline "$ok")"
  if [[ ! "$ok" =~ ^[Yy]$ ]]; then
    warn "Đã huỷ."
    return 0
  fi

  ensure_docker

  info "▶ Dừng & xoá stack (nếu có)..."
  if [[ -f "$install_dir/docker-compose.yml" ]]; then
    docker_down "$install_dir"
  else
    docker rm -f n8n n8n-postgres >/dev/null 2>&1 || true
  fi

  # systemd service
  info "▶ Dừng & xoá systemd service cloudflared-n8n..."
  systemctl disable --now cloudflared-n8n.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/cloudflared-n8n.service
  systemctl daemon-reload >/dev/null 2>&1 || true

  # volume delete option
  local vols
  vols="$(docker volume ls --format '{{.Name}}' | grep -E '^n8n_postgres_data$|^n8n_.*postgres.*$' || true)"
  if [[ -n "$vols" ]]; then
    echo "Các Docker volume Postgres liên quan đến n8n được tìm thấy:" >&2
    echo "$vols" | sed 's/^/   - /' >&2
    local delv
    read -r -p "Bạn có muốn XOÁ các volume này (XOÁ TOÀN BỘ DB n8n)? [y/N]: " delv
    delv="$(sanitize_oneline "$delv")"
    if [[ "$delv" =~ ^[Yy]$ ]]; then
      echo "$vols" | xargs -r docker volume rm >/dev/null 2>&1 || true
      log "✅ Đã xoá volume DB."
    else
      info "Giữ lại volume DB."
    fi
  fi

  # data dir delete option
  local deld
  read -r -p "Bạn có muốn XOÁ data dir /root/.n8n (workflow binaryData, config...)? [y/N]: " deld
  deld="$(sanitize_oneline "$deld")"
  if [[ "$deld" =~ ^[Yy]$ ]]; then
    rm -rf /root/.n8n
    log "✅ Đã xoá /root/.n8n"
  else
    info "Giữ lại /root/.n8n"
  fi

  # tunnel file optional cleanup (không tự xoá tunnel trên cloud vì dễ xoá nhầm)
  warn "⚠ Cloudflare DNS/Tunnel:"
  warn "   - Script KHÔNG tự xoá tunnel trên Cloudflare Dashboard (tránh xoá nhầm)."
  warn "   - Nếu muốn xoá tunnel, dùng:"
  warn "       cloudflared tunnel list"
  warn "       cloudflared tunnel delete <tunnel-name-or-id>"
  warn "   - DNS CNAME xoá/sửa trong Cloudflare Dashboard nếu cần."

  log "✅ Đã gỡ n8n + service cloudflared-n8n (tuỳ chọn xoá data/volume theo bạn chọn)."
  pause
}

update_n8n_image() {
  echo "============================================================"
  echo "=== UPDATE n8n (pull image mới nhất, GIỮ DATA) ==="
  echo "============================================================"

  local install_dir="$DEFAULT_DIR"
  if [[ -d /opt/n8n ]]; then install_dir="/opt/n8n"; fi
  if [[ ! -f "$install_dir/docker-compose.yml" ]]; then
    err "Không thấy $install_dir/docker-compose.yml. Hãy cài đặt trước (menu 1)."
    pause
    return 1
  fi

  ensure_docker
  local dc; dc="$(compose_cmd)"

  info "▶ Pull image n8n mới nhất..."
  (cd "$install_dir" && $dc pull n8n)

  info "▶ Restart n8n (giữ volume + data)..."
  (cd "$install_dir" && $dc up -d)

  log "✅ Update xong. Kiểm tra version:"
  docker exec -it n8n n8n --version 2>/dev/null || docker logs -n 5 n8n || true

  info "Nếu sau update bị 'Connection lost', hãy xoá cookies site và reload."
  pause
}

# ---------- Main menu ----------
main_menu() {
  while true; do
    echo "============================================================"
    echo " n8n MANAGER + CLOUDFLARE TUNNEL (${SCRIPT_VERSION})"
    echo "============================================================"
    echo "1) Cài / cập nhật n8n + tunnel"
    echo "2) Kiểm tra trạng thái n8n + tunnel"
    echo "3) Gỡ n8n + service + (tuỳ chọn) xoá data & volume & tunnel"
    echo "4) Update n8n (pull image mới nhất, giữ data)"
    echo "0) Thoát"
    echo "============================================================"
    read -r -p "Chọn chức năng (0-4): " c
    c="$(sanitize_oneline "$c")"
    case "$c" in
      1) install_or_update ;;
      2) status_all ;;
      3) uninstall_all ;;
      4) update_n8n_image ;;
      0) exit 0 ;;
      *) warn "Chọn không hợp lệ." ;;
    esac
  done
}

need_root
main_menu
