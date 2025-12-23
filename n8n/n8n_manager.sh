#!/usr/bin/env bash
set -Eeuo pipefail

# =========================
# n8n MANAGER + CLOUDFLARE TUNNEL
# - Fix YAML by using .env (no secrets injected into YAML)
# - Fix route DNS: always use tunnel UUID + try overwrite
# - Add proxy/cookie env to avoid "Invalid origin", logout issues behind tunnel
# =========================

# ---------- UI ----------
line() { printf '%s\n' "============================================================"; }
die() { echo "❌ $*" >&2; exit 1; }
warn() { echo "⚠ $*" >&2; }
info() { echo "ℹ️ $*"; }
ok() { echo "✅ $*"; }

pause() { read -r -p "Nhấn Enter để tiếp tục..." _; }

# ---------- Commands ----------
dc() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    die "Không tìm thấy 'docker compose' hoặc 'docker-compose'. Hãy cài Docker + Compose trước."
  fi
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Thiếu lệnh: $1"; }

# ---------- Defaults ----------
DEFAULT_HOST="n8n.rawcode.io"
DEFAULT_TUNNEL="n8n-tunnel"
DEFAULT_INSTALL_DIR="/opt/n8n"
DEFAULT_TZ="Asia/Ho_Chi_Minh"
DEFAULT_DB_NAME="n8n"
DEFAULT_DB_USER="n8n"
DEFAULT_N8N_IMAGE="docker.n8n.io/n8nio/n8n"
DEFAULT_PG_IMAGE="postgres:16"

DATA_DIR="/root/.n8n"
PG_VOLUME_NAME="n8n_postgres_data"

CFD_CFG_DIR="/etc/cloudflared"
CFD_CFG_FILE="${CFD_CFG_DIR}/n8n-tunnel.yml"
CFD_SVC_FILE="/etc/systemd/system/cloudflared-n8n.service"

# ---------- Utils ----------
rand_str() {
  # 32 chars base64url-ish
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
}

read_default() {
  local prompt="$1" default="$2" varname="$3"
  local val
  read -r -p "${prompt} [${default}]: " val
  val="${val:-$default}"
  printf -v "$varname" '%s' "$val"
}

read_secret_confirm() {
  local prompt="$1" varname="$2"
  local p1 p2
  while true; do
    read -rsp "$prompt: " p1; echo
    read -rsp "Nhập lại mật khẩu PostgreSQL: " p2; echo
    [[ "$p1" == "$p2" ]] || { warn "Mật khẩu không khớp, nhập lại."; continue; }
    [[ -n "$p1" ]] || { warn "Không được để trống."; continue; }
    printf -v "$varname" '%s' "$p1"
    return 0
  done
}

ensure_dirs() {
  mkdir -p "$DATA_DIR"
  # n8n container runs as user 1000 (node)
  chown 1000:1000 "$DATA_DIR"
  chmod 700 "$DATA_DIR"
}

ensure_cloudflared_ready() {
  need_cmd cloudflared
  mkdir -p "$CFD_CFG_DIR"
  # Cloudflared needs cert.pem (login) for creating tunnels/routes unless token-based
  if [[ ! -f /root/.cloudflared/cert.pem ]]; then
    warn "Chưa thấy /root/.cloudflared/cert.pem."
    warn "Nếu thao tác tunnel/route DNS bị fail vì chưa login, hãy chạy: cloudflared tunnel login"
  fi
}

# Return tunnel id by name if exists, else empty
get_tunnel_id_by_name() {
  local name="$1"
  # Try JSON output first
  if cloudflared tunnel list --help 2>/dev/null | grep -q -- '--output'; then
    cloudflared tunnel list --output json 2>/dev/null | jq -r --arg n "$name" '.[] | select(.name==$n) | .id' | head -n1
    return 0
  fi
  # Fallback parse table: ID NAME CREATED CONNECTIONS
  cloudflared tunnel list 2>/dev/null | awk -v n="$name" 'NF>=2 && $2==n {print $1; exit}'
}

ensure_tunnel() {
  local name="$1"
  local id=""
  id="$(get_tunnel_id_by_name "$name" || true)"
  if [[ -n "${id:-}" ]]; then
    info "Tunnel '$name' đã tồn tại, dùng lại."
    echo "$id"
    return 0
  fi

  info "Tạo tunnel mới '$name'..."
  local out
  out="$(cloudflared tunnel create "$name" 2>&1 | tee /tmp/cloudflared_create_${name}.log || true)"
  # Parse UUID from output
  id="$(echo "$out" | grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -n1 || true)"
  [[ -n "${id:-}" ]] || die "Không parse được Tunnel ID. Xem log: /tmp/cloudflared_create_${name}.log"
  echo "$id"
}

route_dns() {
  local tunnel_id="$1"
  local hostname="$2"

  info "Tạo / cập nhật DNS record cho ${hostname} (trỏ về ${tunnel_id}.cfargotunnel.com)..."

  # Prefer overwrite if supported
  if cloudflared tunnel route dns --help 2>/dev/null | grep -q -- '--overwrite-dns'; then
    if cloudflared tunnel route dns --overwrite-dns "$tunnel_id" "$hostname" 2>&1; then
      ok "Đã tạo/cập nhật CNAME cho ${hostname} (trỏ đúng tunnel ${tunnel_id})."
      return 0
    fi
  fi

  # Fallback: try normal route
  if cloudflared tunnel route dns "$tunnel_id" "$hostname" 2>&1; then
    ok "Đã tạo/cập nhật CNAME cho ${hostname}."
    return 0
  fi

  warn "Không tự route/overwrite được DNS (có thể record đã tồn tại và cloudflared không overwrite)."
  warn "Bạn vào Cloudflare DNS và set:"
  warn "  CNAME  ${hostname}  ->  ${tunnel_id}.cfargotunnel.com"
  return 1
}

write_tunnel_config() {
  local tunnel_id="$1"
  local hostname="$2"
  local cred="/root/.cloudflared/${tunnel_id}.json"

  [[ -f "$cred" ]] || warn "Không thấy credentials file ${cred} (nếu cloudflared đặt chỗ khác, hãy sửa credentials-file trong YAML)."

  cat > "$CFD_CFG_FILE" <<EOF
tunnel: ${tunnel_id}
credentials-file: ${cred}

ingress:
  - hostname: ${hostname}
    service: http://127.0.0.1:5678
  - service: http_status:404
EOF

  ok "Đã ghi config tunnel: $CFD_CFG_FILE"
}

write_systemd_service() {
  cat > "$CFD_SVC_FILE" <<EOF
[Unit]
Description=Cloudflare Tunnel - n8n-tunnel (n8n)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared --no-autoupdate --config ${CFD_CFG_FILE} tunnel run
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now cloudflared-n8n.service >/dev/null 2>&1 || true
  ok "Cloudflare Tunnel service đã chạy: cloudflared-n8n.service"
}

write_compose_and_env() {
  local install_dir="$1"
  local tz="$2"
  local host="$3"
  local db_name="$4"
  local db_user="$5"
  local db_pass="$6"
  local n8n_image="$7"
  local pg_image="$8"

  mkdir -p "$install_dir"

  # .env (secrets live here) — keep perms tight
  cat > "${install_dir}/.env" <<EOF
# Generated by n8n_manager.sh
TZ=${tz}

N8N_HOST=${host}
WEBHOOK_URL=https://${host}/
N8N_DATA_DIR=${DATA_DIR}

POSTGRES_DB=${db_name}
POSTGRES_USER=${db_user}
POSTGRES_PASSWORD=${db_pass}

N8N_IMAGE=${n8n_image}
POSTGRES_IMAGE=${pg_image}
EOF
  chmod 600 "${install_dir}/.env"

  # docker-compose.yml — no raw secrets injected
  cat > "${install_dir}/docker-compose.yml" <<'EOF'
services:
  n8n-postgres:
    image: ${POSTGRES_IMAGE}
    container_name: n8n-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      TZ: ${TZ}
    volumes:
      - n8n_postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
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
    ports:
      - "127.0.0.1:5678:5678"
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: n8n-postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: ${POSTGRES_DB}
      DB_POSTGRESDB_USER: ${POSTGRES_USER}
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}

      # Base URL (for reverse proxy / tunnel)
      N8N_HOST: ${N8N_HOST}
      N8N_PORT: 5678
      N8N_PROTOCOL: https
      WEBHOOK_URL: ${WEBHOOK_URL}

      # Reverse proxy / cookies (fix Invalid origin / logout issues)
      N8N_SECURE_COOKIE: "true"
      N8N_PROXY_HOPS: "1"
      N8N_TRUST_PROXY: "true"

      N8N_DIAGNOSTICS_ENABLED: "false"
      TZ: ${TZ}
      GENERIC_TIMEZONE: ${TZ}
    volumes:
      - "${N8N_DATA_DIR}:/home/node/.n8n"

volumes:
  n8n_postgres_data:
    name: n8n_postgres_data
EOF

  ok "Đã ghi ${install_dir}/docker-compose.yml + ${install_dir}/.env"
}

compose_up() {
  local install_dir="$1"
  pushd "$install_dir" >/dev/null

  # Validate YAML before up
  if ! dc config >/dev/null 2>&1; then
    echo "----- docker-compose.yml (with line numbers) -----"
    nl -ba docker-compose.yml | sed -n '1,220p'
    echo "----- .env -----"
    sed 's/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=***hidden***/' .env || true
    popd >/dev/null
    die "docker compose config fail → YAML/.env lỗi. (Xem dump ở trên)"
  fi

  info "Triển khai stack n8n + PostgreSQL..."
  dc pull >/dev/null 2>&1 || true
  dc up -d

  popd >/dev/null
}

install_or_update() {
  line
  echo "=== CÀI ĐẶT / CẬP NHẬT n8n + PostgreSQL + Cloudflare Tunnel ==="
  line

  local host tunnel_name install_dir tz db_name db_user db_pass n8n_image pg_image

  read_default "Hostname cho n8n" "$DEFAULT_HOST" host
  read_default "Tên tunnel" "$DEFAULT_TUNNEL" tunnel_name
  read_default "Thư mục cài n8n" "$DEFAULT_INSTALL_DIR" install_dir
  read_default "Timezone" "$DEFAULT_TZ" tz
  read_default "Tên database PostgreSQL" "$DEFAULT_DB_NAME" db_name
  read_default "User database PostgreSQL" "$DEFAULT_DB_USER" db_user

  echo "ℹ️ Lưu ý: khi nhập mật khẩu, terminal sẽ KHÔNG hiện ký tự."
  read_secret_confirm "Mật khẩu database PostgreSQL" db_pass

  read_default "Image n8n" "$DEFAULT_N8N_IMAGE" n8n_image
  read_default "Image PostgreSQL" "$DEFAULT_PG_IMAGE" pg_image

  line
  echo "📌 Tóm tắt:"
  echo "   - Hostname:       $host"
  echo "   - Tunnel name:    $tunnel_name"
  echo "   - Install dir:    $install_dir"
  echo "   - Timezone:       $tz"
  echo "   - DB:             $db_name"
  echo "   - DB user:        $db_user"
  echo "   - DB password:    (ẩn)"
  echo "   - Postgres image: $pg_image"
  echo "   - n8n image:      $n8n_image"
  echo "   - Data dir:       $DATA_DIR (mount vào /home/node/.n8n)"
  echo "   - Postgres volume: n8n_postgres_data"
  line
  read -r -p "Tiếp tục cài đặt? [y/N]: " yn
  [[ "${yn:-N}" =~ ^[Yy]$ ]] || { info "Huỷ."; return 0; }

  need_cmd docker
  need_cmd jq
  ensure_cloudflared_ready
  ensure_dirs

  write_compose_and_env "$install_dir" "$tz" "$host" "$db_name" "$db_user" "$db_pass" "$n8n_image" "$pg_image"
  compose_up "$install_dir"

  ok "n8n đã khởi động local: http://127.0.0.1:5678"

  # Tunnel + DNS + systemd
  local tunnel_id
  tunnel_id="$(ensure_tunnel "$tunnel_name")"
  info "→ Tunnel ID:   $tunnel_id"
  info "→ Credentials: /root/.cloudflared/${tunnel_id}.json"

  route_dns "$tunnel_id" "$host" || true
  write_tunnel_config "$tunnel_id" "$host"
  write_systemd_service

  echo
  ok "HOÀN TẤT!"
  echo "   - n8n qua Cloudflare:  https://${host}"
  echo "   - Local:              http://127.0.0.1:5678"
  echo
  echo "Nếu bạn từng gặp lỗi setup loop/logout/Invalid origin:"
  echo "  1) Xoá cookies/site data của https://${host} trên trình duyệt"
  echo "  2) Đảm bảo CNAME ${host} trỏ đúng: ${tunnel_id}.cfargotunnel.com"
  echo "  3) Restart n8n: (cd ${install_dir} && docker compose restart n8n)"
}

status() {
  line
  echo "=== TRẠNG THÁI n8n + TUNNEL ==="
  line

  echo
  echo "▶ Docker containers:"
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | sed -n '1p;/\bn8n\b/p;/\bn8n-postgres\b/p' || true

  echo
  echo "▶ Volume n8n postgres:"
  docker volume ls | awk 'NR==1 || $2=="n8n_postgres_data"' || true

  echo
  echo "▶ Systemd service cloudflared-n8n:"
  systemctl status cloudflared-n8n.service --no-pager || true

  echo
  echo "▶ Tunnel list (grep n8n):"
  cloudflared tunnel list 2>/dev/null | (head -n1; grep -i n8n || true) || true
}

remove_stack() {
  line
  echo "=== GỠ n8n + Cloudflare Tunnel (local) ==="
  line

  read -r -p "Bạn chắc chắn muốn gỡ n8n (container + service tunnel local)? [y/N]: " yn
  [[ "${yn:-N}" =~ ^[Yy]$ ]] || { info "Huỷ."; return 0; }

  local install_dir="$DEFAULT_INSTALL_DIR"
  [[ -f "${DEFAULT_INSTALL_DIR}/docker-compose.yml" ]] || true
  read_default "Thư mục cài n8n" "$DEFAULT_INSTALL_DIR" install_dir

  # Stop stack
  if [[ -f "${install_dir}/docker-compose.yml" ]]; then
    info "Dừng & xoá container n8n / n8n-postgres..."
    pushd "$install_dir" >/dev/null
    dc down || true
    popd >/dev/null
  else
    warn "Không thấy ${install_dir}/docker-compose.yml, bỏ qua docker compose down."
  fi

  # Stop tunnel service
  info "Dừng & xoá systemd service cloudflared-n8n..."
  systemctl disable --now cloudflared-n8n.service >/dev/null 2>&1 || true
  rm -f "$CFD_SVC_FILE" || true
  systemctl daemon-reload || true

  # Ask remove data dir
  echo
  read -r -p "Bạn có muốn XOÁ thư mục data '${DATA_DIR}' (mất workflows/credentials/settings)? [y/N]: " yn_data
  if [[ "${yn_data:-N}" =~ ^[Yy]$ ]]; then
    rm -rf "$DATA_DIR"
    ok "Đã xoá $DATA_DIR"
  fi

  # Ask remove postgres volume
  echo
  if docker volume ls --format '{{.Name}}' | grep -qx 'n8n_postgres_data'; then
    echo "Các Docker volume Postgres liên quan đến n8n được tìm thấy:"
    echo "   - n8n_postgres_data"
    read -r -p "Bạn có muốn XOÁ volume này (XOÁ TOÀN BỘ DB n8n)? [y/N]: " yn_vol
    if [[ "${yn_vol:-N}" =~ ^[Yy]$ ]]; then
      docker volume rm n8n_postgres_data || true
      ok "Đã xoá volume n8n_postgres_data"
    fi
  else
    info "Không thấy volume n8n_postgres_data."
  fi

  # Ask remove install dir
  echo
  read -r -p "Bạn có muốn XOÁ thư mục cài đặt '${install_dir}' (docker-compose.yml, .env)? [y/N]: " yn_dir
  if [[ "${yn_dir:-N}" =~ ^[Yy]$ ]]; then
    rm -rf "$install_dir"
    ok "Đã xoá $install_dir"
  fi

  # Tunnel info (if config exists)
  local tunnel_id="" tunnel_name=""
  if [[ -f "$CFD_CFG_FILE" ]]; then
    tunnel_id="$(awk -F': *' '/^tunnel:/{print $2}' "$CFD_CFG_FILE" | head -n1 || true)"
    tunnel_name="$(get_tunnel_id_by_name "$DEFAULT_TUNNEL" >/dev/null 2>&1 && echo "$DEFAULT_TUNNEL" || true)"
  fi

  echo
  if [[ -f "$CFD_CFG_FILE" ]]; then
    echo "▶ Thông tin tunnel từ file cấu hình $CFD_CFG_FILE:"
    echo "   - Tunnel ID:   ${tunnel_id:-"(không đọc được)"}"
    echo "   - Tunnel name: $DEFAULT_TUNNEL"
    read -r -p "Bạn có muốn XOÁ file cấu hình local '${CFD_CFG_FILE}'? [y/N]: " yn_cfg
    if [[ "${yn_cfg:-N}" =~ ^[Yy]$ ]]; then
      rm -f "$CFD_CFG_FILE"
      ok "Đã xoá file cấu hình tunnel local."
    fi

    read -r -p "Bạn có muốn XOÁ Cloudflare Tunnel '$DEFAULT_TUNNEL' khỏi Cloudflare (cloudflared tunnel delete)? [y/N]: " yn_tun
    if [[ "${yn_tun:-N}" =~ ^[Yy]$ ]]; then
      if [[ -n "${tunnel_id:-}" ]]; then
        (cloudflared tunnel delete "$tunnel_id" --force >/dev/null 2>&1) || (yes | cloudflared tunnel delete "$tunnel_id" >/dev/null 2>&1) || warn "Không xoá được tunnel tự động. Hãy chạy: cloudflared tunnel delete ${tunnel_id}"
      else
        (cloudflared tunnel delete "$DEFAULT_TUNNEL" --force >/dev/null 2>&1) || (yes | cloudflared tunnel delete "$DEFAULT_TUNNEL" >/dev/null 2>&1) || warn "Không xoá được tunnel tự động. Hãy chạy: cloudflared tunnel delete $DEFAULT_TUNNEL"
      fi
      ok "Đã gửi lệnh xoá tunnel (nếu không có lỗi)."
    fi
  else
    warn "Không thấy $CFD_CFG_FILE để đọc tunnel id. Nếu cần xoá tunnel: cloudflared tunnel list && cloudflared tunnel delete <id>"
  fi

  # Ask delete DNS record
  echo
  read -r -p "Bạn có muốn XOÁ CNAME DNS n8n.rawcode.io (cloudflared tunnel route dns delete)? [y/N]: " yn_dns
  if [[ "${yn_dns:-N}" =~ ^[Yy]$ ]]; then
    if cloudflared tunnel route dns delete "$DEFAULT_HOST" >/dev/null 2>&1; then
      ok "Đã xoá DNS record cho $DEFAULT_HOST"
    else
      warn "Không xoá được DNS tự động. Hãy xoá trong Cloudflare Dashboard: CNAME $DEFAULT_HOST"
    fi
  fi

  ok "Đã gỡ n8n (container) + service cloudflared-n8n trên máy chủ."
}

update_n8n_only() {
  line
  echo "=== UPDATE n8n (pull image mới nhất, GIỮ DATA) ==="
  line

  local install_dir="$DEFAULT_INSTALL_DIR"
  read_default "Thư mục cài n8n" "$DEFAULT_INSTALL_DIR" install_dir
  [[ -f "${install_dir}/docker-compose.yml" ]] || die "Không thấy ${install_dir}/docker-compose.yml"

  pushd "$install_dir" >/dev/null
  info "Pull image mới nhất..."
  dc pull n8n
  info "Up lại service (không xoá data)..."
  dc up -d
  popd >/dev/null

  ok "Đã update n8n. Nếu cần, kiểm tra: docker logs -f n8n"
}

menu() {
  while true; do
    line
    echo " n8n MANAGER + CLOUDFLARE TUNNEL"
    line
    echo "1) Cài / cập nhật n8n + tunnel"
    echo "2) Kiểm tra trạng thái n8n + tunnel"
    echo "3) Gỡ n8n + service + (tuỳ chọn) xoá data & volume & tunnel & DNS"
    echo "4) Update n8n (pull image mới nhất, giữ data)"
    echo "0) Thoát"
    line
    read -r -p "Chọn chức năng (0-4): " c
    case "${c:-}" in
      1) install_or_update; pause;;
      2) status; pause;;
      3) remove_stack; pause;;
      4) update_n8n_only; pause;;
      0) exit 0;;
      *) warn "Chọn sai."; pause;;
    esac
  done
}

main() {
  need_cmd awk
  need_cmd sed
  need_cmd nl
  need_cmd head
  need_cmd grep
  need_cmd tr
  menu
}

main "$@"
