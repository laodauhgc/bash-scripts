#!/usr/bin/env bash
# n8n_manager.sh v1.0.2

set -Eeuo pipefail

SCRIPT_VERSION="1.0.2"

# ---------- helpers ----------
log()  { echo -e "$*" >&2; }
die()  { echo -e "❌ $*" >&2; exit 1; }
ok()   { echo -e "✅ $*" >&2; }
warn() { echo -e "⚠️ $*" >&2; }

pause() { read -r -p "Nhấn Enter để tiếp tục..." _; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      exec sudo -E bash "$0" "$@"
    else
      die "Cần chạy bằng root (hoặc cài sudo)."
    fi
  fi
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

prompt_default() {
  local label="$1" def="$2" v=""
  read -r -p "${label} [${def}]: " v || true
  echo "${v:-$def}"
}

prompt_yesno() {
  local q="$1" def="${2:-N}" ans=""
  read -r -p "${q} [y/N]: " ans || true
  if [[ "$def" =~ ^[Yy]$ && -z "$ans" ]]; then ans="y"; fi
  [[ "$ans" =~ ^[Yy]$ ]]
}

prompt_secret_confirm_simple() {
  local label="$1" a="" b=""
  while true; do
    log "ℹ️ Lưu ý: khi nhập mật khẩu, terminal sẽ KHÔNG hiện ký tự."
    read -rs -p "${label}: " a || true; echo >&2
    read -rs -p "Nhập lại ${label}: " b || true; echo >&2
    if [[ -z "$a" ]]; then
      warn "Mật khẩu không được rỗng."
      continue
    fi
    if [[ "$a" != "$b" ]]; then
      warn "Mật khẩu không khớp, nhập lại."
      continue
    fi
    # hạn chế ký tự gây hỏng dotenv / compose
    if [[ ! "$a" =~ ^[A-Za-z0-9._-]+$ ]]; then
      warn "Mật khẩu chỉ nên dùng ký tự [A-Za-z0-9._-] để tránh lỗi .env/compose."
      warn "Ví dụ: Abc123._-"
      continue
    fi
    echo "$a"
    return 0
  done
}

sanitize_single_line() {
  # remove CR/LF just in case
  printf "%s" "$1" | tr -d '\r\n'
}

detect_arch() {
  local a
  a="$(uname -m)"
  case "$a" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv6l) echo "arm" ;;
    *) echo "amd64" ;;
  esac
}

# ---------- cloudflared ----------
install_cloudflared_if_needed() {
  if cmd_exists cloudflared; then return 0; fi
  log "▶ Cài cloudflared..."
  local arch url
  arch="$(detect_arch)"
  case "$arch" in
    amd64) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
    arm64) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
    arm)   url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm" ;;
    *)     url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
  esac
  curl -fsSL "$url" -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared
  ok "Đã cài cloudflared: $(cloudflared --version | head -n1 || true)"
}

ensure_cloudflared_login() {
  mkdir -p /root/.cloudflared
  if [[ -f /root/.cloudflared/cert.pem ]]; then
    return 0
  fi
  warn "Chưa thấy /root/.cloudflared/cert.pem"
  warn "Bạn cần login Cloudflare 1 lần: cloudflared tunnel login"
  if prompt_yesno "Bạn muốn chạy 'cloudflared tunnel login' ngay bây giờ?" "N"; then
    cloudflared tunnel login
  else
    die "Hãy chạy: cloudflared tunnel login rồi chạy lại script."
  fi
  [[ -f /root/.cloudflared/cert.pem ]] || die "Login xong vẫn chưa có cert.pem. Kiểm tra lại."
}

tunnel_id_by_name() {
  local name="$1"
  # Output format: UUID NAME CREATED ...
  cloudflared tunnel list 2>/dev/null | awk -v n="$name" 'NR>1 && $2==n {print $1}' | head -n1 || true
}

ensure_tunnel_uuid() {
  local name="$1"
  local id=""
  id="$(tunnel_id_by_name "$name")"
  if [[ -n "$id" ]]; then
    log "ℹ️ Tunnel '$name' đã tồn tại, dùng lại."
    echo "$id"
    return 0
  fi

  log "▶ Tạo tunnel mới '$name'..."
  local out uuid
  out="$(cloudflared tunnel create "$name" 2>&1 || true)"
  log "$out"
  uuid="$(echo "$out" | grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | tail -n1 || true)"
  [[ -n "$uuid" ]] || die "Không lấy được Tunnel ID từ output create tunnel."
  echo "$uuid"
}

credentials_path_for_uuid() {
  local uuid="$1"
  local p="/root/.cloudflared/${uuid}.json"
  if [[ -f "$p" ]]; then
    echo "$p"
    return 0
  fi
  # fallback search
  p="$(ls -1 "/root/.cloudflared/${uuid}"*.json 2>/dev/null | head -n1 || true)"
  [[ -n "$p" ]] && echo "$p" || echo ""
}

route_dns_to_tunnel() {
  local uuid="$1" host="$2"
  log "▶ Tạo / cập nhật DNS record cho ${host} (route tới tunnel ${uuid})..."
  if cloudflared tunnel route dns "$uuid" "$host"; then
    ok "Đã tạo/cập nhật DNS route cho $host."
    return 0
  fi

  warn "Không tạo/cập nhật được DNS route."
  warn "Thường do DNS record $host đã tồn tại (A/AAAA/CNAME) hoặc đang trỏ tunnel khác."
  if prompt_yesno "Bạn muốn thử XOÁ DNS record hiện tại của '$host' rồi tạo lại (overwrite)?" "N"; then
    # delete then create
    cloudflared tunnel route dns delete "$host" || true
    cloudflared tunnel route dns "$uuid" "$host" || die "Vẫn không route dns được. Hãy kiểm tra DNS trên Cloudflare Dashboard."
    ok "Đã overwrite DNS route cho $host."
  else
    warn "Bỏ qua bước DNS route. Bạn tự chỉnh CNAME trên Cloudflare: ${host} -> ${uuid}.cfargotunnel.com"
  fi
}

write_tunnel_config() {
  local host="$1" uuid="$2" cred="$3"
  mkdir -p /etc/cloudflared
  cat > /etc/cloudflared/n8n-tunnel.yml <<EOF
tunnel: ${uuid}
credentials-file: ${cred}

ingress:
  - hostname: ${host}
    service: http://localhost:5678
    originRequest:
      httpHostHeader: ${host}
  - service: http_status:404
EOF
  ok "Đã ghi config tunnel: /etc/cloudflared/n8n-tunnel.yml"
}

write_systemd_service() {
  cat > /etc/systemd/system/cloudflared-n8n.service <<'EOF'
[Unit]
Description=Cloudflare Tunnel - n8n (cloudflared-n8n)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared --no-autoupdate --config /etc/cloudflared/n8n-tunnel.yml tunnel run
Restart=always
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now cloudflared-n8n.service
  ok "Cloudflare Tunnel service đã enable & start: cloudflared-n8n.service"
}

# ---------- docker / compose ----------
ensure_docker() {
  cmd_exists docker || die "Chưa có docker. Hãy cài Docker trước."
  docker compose version >/dev/null 2>&1 || die "Chưa có docker compose plugin (docker compose)."
}

wait_http() {
  local url="$1" tries="${2:-20}" delay="${3:-2}"
  local code=""
  for _ in $(seq 1 "$tries"); do
    code="$(curl -k -s -o /dev/null -w "%{http_code}" "$url" || true)"
    if [[ "$code" =~ ^(200|302|401|404)$ ]]; then
      echo "$code"
      return 0
    fi
    sleep "$delay"
  done
  echo "$code"
  return 1
}

# ---------- n8n stack files ----------
write_compose_file() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "${dir}/docker-compose.yml" <<'EOF'
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

      # Public URL settings (IMPORTANT for reverse proxy / tunnel)
      N8N_HOST: ${N8N_HOST}
      N8N_PROTOCOL: https
      N8N_PORT: 5678
      N8N_EDITOR_BASE_URL: ${N8N_EDITOR_BASE_URL}
      WEBHOOK_URL: ${WEBHOOK_URL}

      # Proxy
      N8N_PROXY_HOPS: ${N8N_PROXY_HOPS}

      # Timezone
      TZ: ${TZ}
      GENERIC_TIMEZONE: ${TZ}

      # Telemetry
      N8N_DIAGNOSTICS_ENABLED: "false"
    ports:
      - "127.0.0.1:5678:5678"
    volumes:
      - "${N8N_DATA_DIR}:/home/node/.n8n"

volumes:
  n8n_postgres_data:
    name: ${POSTGRES_VOLUME}
EOF
  ok "Đã ghi ${dir}/docker-compose.yml"
}

write_env_file() {
  local dir="$1"
  local n8n_image="$2"
  local pg_image="$3"
  local host="$4"
  local tz="$5"
  local db="$6"
  local db_user="$7"
  local db_pass="$8"
  local pg_vol="$9"
  local data_dir="${10}"
  local proxy_hops="${11}"

  # ensure clean single-line values
  host="$(sanitize_single_line "$host")"
  tz="$(sanitize_single_line "$tz")"
  db="$(sanitize_single_line "$db")"
  db_user="$(sanitize_single_line "$db_user")"
  db_pass="$(sanitize_single_line "$db_pass")"
  pg_vol="$(sanitize_single_line "$pg_vol")"
  data_dir="$(sanitize_single_line "$data_dir")"
  proxy_hops="$(sanitize_single_line "$proxy_hops")"

  # IMPORTANT: no quotes in .env
  cat > "${dir}/.env" <<EOF
N8N_IMAGE=${n8n_image}
POSTGRES_IMAGE=${pg_image}

N8N_HOST=${host}
N8N_EDITOR_BASE_URL=https://${host}
WEBHOOK_URL=https://${host}

TZ=${tz}

POSTGRES_DB=${db}
POSTGRES_USER=${db_user}
POSTGRES_PASSWORD=${db_pass}
POSTGRES_VOLUME=${pg_vol}

N8N_DATA_DIR=${data_dir}
N8N_PROXY_HOPS=${proxy_hops}
EOF

  chmod 600 "${dir}/.env"
  ok "Đã ghi ${dir}/.env (chmod 600)"
}

ensure_n8n_data_dir() {
  local data_dir="$1"
  log "▶ Đảm bảo thư mục data ${data_dir} tồn tại..."
  mkdir -p "$data_dir"
  chown 1000:1000 "$data_dir" || true
  chmod 700 "$data_dir" || true
}

compose_up_stack() {
  local dir="$1"
  ( cd "$dir" && docker compose up -d )
}

compose_down_stack() {
  local dir="$1"
  ( cd "$dir" && docker compose down ) || true
}

# ---------- actions ----------
action_install_update() {
  ensure_docker
  install_cloudflared_if_needed
  ensure_cloudflared_login

  echo "============================================================"
  echo "=== CÀI ĐẶT / CẬP NHẬT n8n + PostgreSQL + Cloudflare Tunnel ==="
  echo "============================================================"

  local host tunnel_name install_dir tz db db_user db_pass n8n_image pg_image pg_vol data_dir proxy_hops

  host="$(prompt_default "Hostname cho n8n" "n8n.rawcode.io")"
  tunnel_name="$(prompt_default "Tên tunnel" "n8n-tunnel")"
  install_dir="$(prompt_default "Thư mục cài n8n" "/opt/n8n")"
  tz="$(prompt_default "Timezone" "Asia/Ho_Chi_Minh")"
  db="$(prompt_default "Tên database PostgreSQL" "n8n")"
  db_user="$(prompt_default "User database PostgreSQL" "n8n")"
  db_pass="$(prompt_secret_confirm_simple "Mật khẩu PostgreSQL")"
  n8n_image="$(prompt_default "Image n8n" "docker.n8n.io/n8nio/n8n")"
  pg_image="$(prompt_default "Image PostgreSQL" "postgres:16")"
  pg_vol="$(prompt_default "Tên volume Postgres" "n8n_postgres_data")"
  data_dir="$(prompt_default "Thư mục data n8n (mount /home/node/.n8n)" "/root/.n8n")"
  proxy_hops="$(prompt_default "N8N_PROXY_HOPS" "1")"

  # summary
  echo "============================================================"
  echo "📌 Tóm tắt:"
  echo "   - Hostname:        ${host}"
  echo "   - Tunnel name:     ${tunnel_name}"
  echo "   - Install dir:     ${install_dir}"
  echo "   - Timezone:        ${tz}"
  echo "   - DB:              ${db}"
  echo "   - DB user:         ${db_user}"
  echo "   - DB password:     (ẩn)"
  echo "   - Postgres image:  ${pg_image}"
  echo "   - n8n image:       ${n8n_image}"
  echo "   - Data dir:        ${data_dir}"
  echo "   - Postgres volume: ${pg_vol}"
  echo "   - N8N_PROXY_HOPS:  ${proxy_hops}"
  echo "============================================================"

  if ! prompt_yesno "Tiếp tục cài đặt?" "N"; then
    return 0
  fi

  ensure_n8n_data_dir "$data_dir"
  write_compose_file "$install_dir"
  write_env_file "$install_dir" "$n8n_image" "$pg_image" "$host" "$tz" "$db" "$db_user" "$db_pass" "$pg_vol" "$data_dir" "$proxy_hops"

  log "ℹ️ Triển khai stack n8n + PostgreSQL..."
  compose_up_stack "$install_dir"

  ok "n8n đã khởi động local: http://127.0.0.1:5678"
  local code
  code="$(wait_http "http://127.0.0.1:5678/" 25 2 || true)"
  log "▶ Thử curl local n8n: HTTP code: ${code:-N/A}"

  # tunnel
  local uuid cred
  uuid="$(ensure_tunnel_uuid "$tunnel_name")"
  uuid="$(sanitize_single_line "$uuid")"
  ok "Tunnel UUID: ${uuid}"

  cred="$(credentials_path_for_uuid "$uuid")"
  [[ -n "$cred" ]] || die "Không thấy credentials file cho tunnel ${uuid}. (Thường là /root/.cloudflared/${uuid}.json)"
  ok "Credentials: ${cred}"

  route_dns_to_tunnel "$uuid" "$host"
  write_tunnel_config "$host" "$uuid" "$cred"
  write_systemd_service

  # show status
  systemctl restart cloudflared-n8n.service || true
  sleep 1
  systemctl --no-pager --full status cloudflared-n8n.service || true

  echo
  ok "HOÀN TẤT!"
  echo "   - n8n qua Cloudflare:  https://${host}"
  echo "   - Local:              http://127.0.0.1:5678"
  echo
  echo "Nếu vẫn gặp 'Connection lost' / 'Invalid origin':"
  echo "  1) Xoá cookies/site data của https://${host} trên trình duyệt"
  echo "  2) Restart: (cd ${install_dir} && docker compose restart n8n)"
  echo "  3) Restart tunnel: systemctl restart cloudflared-n8n"
  echo
  pause
}

action_status() {
  ensure_docker
  echo "============================================================"
  echo "=== TRẠNG THÁI n8n + TUNNEL (v${SCRIPT_VERSION}) ==="
  echo "============================================================"
  echo
  echo "▶ Docker containers:"
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | (head -n1; grep -E '^(n8n|n8n-postgres)\b' || true)
  echo
  echo "▶ Volume n8n postgres (grep n8n):"
  docker volume ls | grep -i n8n || true
  echo
  echo "▶ Systemd service cloudflared-n8n:"
  systemctl --no-pager --full status cloudflared-n8n.service || true
  echo
  if cmd_exists cloudflared; then
    echo "▶ Tunnel list (grep n8n):"
    cloudflared tunnel list 2>/dev/null | grep -i n8n || true
  else
    warn "Chưa có cloudflared."
  fi
  echo
  pause
}

action_uninstall() {
  ensure_docker
  install_cloudflared_if_needed

  echo "============================================================"
  echo "=== GỠ n8n + Cloudflare Tunnel (local) ==="
  echo "============================================================"

  if ! prompt_yesno "Bạn chắc chắn muốn gỡ n8n (container + service tunnel local)?" "N"; then
    return 0
  fi

  local install_dir="/opt/n8n"
  if [[ -f /opt/n8n/docker-compose.yml ]]; then
    install_dir="/opt/n8n"
  fi
  install_dir="$(prompt_default "Thư mục cài n8n để gỡ" "$install_dir")"

  log "▶ Dừng & xoá container n8n / n8n-postgres (nếu có)..."
  if [[ -f "${install_dir}/docker-compose.yml" ]]; then
    compose_down_stack "$install_dir"
  else
    docker rm -f n8n n8n-postgres 2>/dev/null || true
  fi

  log "▶ Dừng & xoá systemd service cloudflared-n8n..."
  systemctl disable --now cloudflared-n8n.service 2>/dev/null || true
  rm -f /etc/systemd/system/cloudflared-n8n.service
  systemctl daemon-reload

  # optional remove postgres volume(s)
  local vols=()
  while IFS= read -r v; do [[ -n "$v" ]] && vols+=("$v"); done < <(docker volume ls -q | grep -E '(^n8n_postgres_data$|^n8n_.*postgres.*$)' || true)

  if (( ${#vols[@]} > 0 )); then
    echo "Các Docker volume Postgres liên quan đến n8n được tìm thấy:"
    for v in "${vols[@]}"; do echo "   - $v"; done
    if prompt_yesno "Bạn có muốn XOÁ các volume này (XOÁ TOÀN BỘ DB n8n)?" "N"; then
      docker volume rm "${vols[@]}" 2>/dev/null || true
      ok "Đã xoá volume DB."
    fi
  fi

  # optional remove data dir
  local data_dir="/root/.n8n"
  data_dir="$(prompt_default "Thư mục data n8n" "$data_dir")"
  if [[ -d "$data_dir" ]] && prompt_yesno "Bạn có muốn XOÁ thư mục data '${data_dir}' (mất workflows/credentials/settings)?" "N"; then
    rm -rf "$data_dir"
    ok "Đã xoá $data_dir."
  fi

  # optional remove install dir
  if [[ -d "$install_dir" ]] && prompt_yesno "Bạn có muốn XOÁ thư mục cài đặt '${install_dir}' (compose/env)?" "N"; then
    rm -rf "$install_dir"
    ok "Đã xoá $install_dir."
  fi

  # tunnel cleanup (read from config if exists)
  local host_in_cfg="" uuid_in_cfg=""
  if [[ -f /etc/cloudflared/n8n-tunnel.yml ]]; then
    uuid_in_cfg="$(awk '/^tunnel:/{print $2}' /etc/cloudflared/n8n-tunnel.yml | tr -d '\r\n' || true)"
    host_in_cfg="$(awk '/hostname:/{print $2; exit}' /etc/cloudflared/n8n-tunnel.yml | tr -d '\r\n' || true)"
    echo
    echo "▶ Thông tin tunnel từ /etc/cloudflared/n8n-tunnel.yml:"
    echo "   - Tunnel UUID: ${uuid_in_cfg:-N/A}"
    echo "   - Hostname:    ${host_in_cfg:-N/A}"
  fi

  if [[ -n "${host_in_cfg:-}" ]] && prompt_yesno "Bạn có muốn XOÁ DNS record route của '${host_in_cfg}' (cloudflared tunnel route dns delete)?" "N"; then
    cloudflared tunnel route dns delete "$host_in_cfg" || true
    ok "Đã yêu cầu xoá DNS route cho $host_in_cfg (nếu có quyền)."
  fi

  if [[ -n "${uuid_in_cfg:-}" ]] && prompt_yesno "Bạn có muốn XOÁ tunnel '${uuid_in_cfg}' khỏi Cloudflare (cloudflared tunnel delete)?" "N"; then
    cloudflared tunnel delete "$uuid_in_cfg" || true
    ok "Đã yêu cầu xoá tunnel."
  fi

  if [[ -f /etc/cloudflared/n8n-tunnel.yml ]] && prompt_yesno "Bạn có muốn XOÁ file cấu hình local '/etc/cloudflared/n8n-tunnel.yml'?" "N"; then
    rm -f /etc/cloudflared/n8n-tunnel.yml
    ok "Đã xoá config tunnel local."
  fi

  echo
  ok "Đã gỡ n8n + cloudflared-n8n (các mục tuỳ chọn theo lựa chọn của bạn)."
  pause
}

action_update_n8n_only() {
  ensure_docker
  local install_dir="/opt/n8n"
  install_dir="$(prompt_default "Thư mục cài n8n" "$install_dir")"
  [[ -f "${install_dir}/docker-compose.yml" ]] || die "Không thấy ${install_dir}/docker-compose.yml"

  log "▶ Update n8n (pull image mới nhất, giữ data/DB)..."
  ( cd "$install_dir" && docker compose pull n8n )
  ( cd "$install_dir" && docker compose up -d --no-deps n8n )
  ok "Đã update n8n. Kiểm tra: docker logs -f n8n"
  pause
}

# ---------- menu ----------
show_menu() {
  echo "============================================================"
  echo " n8n MANAGER + CLOUDFLARE TUNNEL (v${SCRIPT_VERSION})"
  echo "============================================================"
  echo "1) Cài / cập nhật n8n + tunnel"
  echo "2) Kiểm tra trạng thái n8n + tunnel"
  echo "3) Gỡ n8n + service + (tuỳ chọn) xoá data & volume & tunnel & DNS"
  echo "4) Update n8n (pull image mới nhất, giữ data)"
  echo "0) Thoát"
  echo "============================================================"
}

main() {
  need_root "$@"
  while true; do
    show_menu
    local choice=""
    read -r -p "Chọn chức năng (0-4): " choice || true
    case "${choice:-}" in
      1) action_install_update ;;
      2) action_status ;;
      3) action_uninstall ;;
      4) action_update_n8n_only ;;
      0) exit 0 ;;
      *) warn "Lựa chọn không hợp lệ." ;;
    esac
  done
}

main "$@"
