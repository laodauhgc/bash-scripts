#!/usr/bin/env bash
# Force UTF-8 để tránh lỗi hiển thị ký tự
export LC_ALL=C.UTF-8 LANG=C.UTF-8
# Garage Menu Installer for Ubuntu 22.04 — dùng menu tương tác
SCRIPT_VERSION="v1.6.2-2025-11-09"
# Cách chạy: sudo bash garage.sh

set -euo pipefail

# ====== THIẾT LẬP MẶC ĐỊNH / ĐƯỜNG DẪN ======
STATE_FILE="/etc/garage-installer.env"
BASE_DIR="/opt/garage"
CFG_FILE="/etc/garage.toml"
SERVICE_NAME="garage"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
NGINX_SITE="/etc/nginx/sites-available/garage_s3"
GARAGE_IMAGE_TAG_DEFAULT="dxflrs/garage:v2.1.0"
REGION_DEFAULT="garage"
BUCKET_DEFAULT="default"
KEY_NAME_DEFAULT="df-key"

# ====== HÀM TIỆN ÍCH ======
color() { echo -e "\e[1;${2}m$1\e[0m"; }
info()  { color "[INFO] $1" 34; }
warn()  { color "[WARN] $1" 33; }
err()   { color "[ERR ] $1" 31; }

need_root() {
  if [[ $(id -u) -ne 0 ]]; then err "Hãy chạy với quyền root (sudo)."; exit 1; fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

load_state() {
  [[ -f "$STATE_FILE" ]] && source "$STATE_FILE"
  S3_DOMAIN=${S3_DOMAIN:-"s3.example.com"}
  EMAIL=${EMAIL:-"admin@example.com"}
  BUCKET_NAME=${BUCKET_NAME:-"$BUCKET_DEFAULT"}
  KEY_NAME=${KEY_NAME:-"$KEY_NAME_DEFAULT"}
  REGION=${REGION:-"$REGION_DEFAULT"}
  GARAGE_IMAGE_TAG=${GARAGE_IMAGE_TAG:-"$GARAGE_IMAGE_TAG_DEFAULT"}
}

save_state() {
  cat >"$STATE_FILE" <<EOF
S3_DOMAIN="$S3_DOMAIN"
EMAIL="$EMAIL"
BUCKET_NAME="$BUCKET_NAME"
KEY_NAME="$KEY_NAME"
REGION="$REGION"
GARAGE_IMAGE_TAG="$GARAGE_IMAGE_TAG"
BASE_DIR="$BASE_DIR"
CFG_FILE="$CFG_FILE"
SERVICE_NAME="$SERVICE_NAME"
COMPOSE_FILE="$COMPOSE_FILE"
NGINX_SITE="$NGINX_SITE"
EOF
  chmod 600 "$STATE_FILE"
  info "Đã lưu tham số: $STATE_FILE"
}

pause() { read -rp $'\nNhấn Enter để tiếp tục... '; }

# ====== THIẾT LẬP HỆ THỐNG ======
apt_install() {
  info "Cài đặt gói cần thiết (Docker, Compose plugin, NGINX, Certbot, jq)..."
  export DEBIAN_FRONTEND=noninteractive

  local has_docker_repo=0
  if grep -Rqs "download.docker.com" /etc/apt/sources.list* 2>/dev/null; then
    has_docker_repo=1
  fi

  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release nginx certbot python3-certbot-nginx jq zip unzip awscli

  if command -v docker >/dev/null 2>&1; then
    info "Docker đã sẵn có → bỏ qua bước cài Docker."
  else
    if [[ $has_docker_repo -eq 1 ]]; then
      apt-get remove -y containerd || true
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
      apt-get remove -y containerd.io || true
      apt-get install -y docker.io docker-compose-plugin
    fi
  fi

  systemctl enable --now docker || true
}

setup_dirs() { info "Tạo thư mục $BASE_DIR ..."; mkdir -p "$BASE_DIR/meta" "$BASE_DIR/data"; }

write_config() {
  info "Ghi cấu hình Garage: $CFG_FILE"
  local RPC_SECRET ADMIN_TOKEN METRICS_TOKEN
  if [[ -f "$CFG_FILE" ]]; then
    cp -a "$CFG_FILE" "${CFG_FILE}.bak.$(date +%s)" || true
    RPC_SECRET=$(awk -F'"' '/^rpc_secret/{print $2}' "$CFG_FILE" 2>/dev/null || true)
    ADMIN_TOKEN=$(awk -F'"' '/^admin_token/{print $2}' "$CFG_FILE" 2>/dev/null || true)
    METRICS_TOKEN=$(awk -F'"' '/^metrics_token/{print $2}' "$CFG_FILE" 2>/dev/null || true)
  fi
  [[ -n "${RPC_SECRET:-}" ]] || RPC_SECRET=$(openssl rand -hex 32)
  [[ -n "${ADMIN_TOKEN:-}" ]] || ADMIN_TOKEN=$(openssl rand -base64 32)
  [[ -n "${METRICS_TOKEN:-}" ]] || METRICS_TOKEN=$(openssl rand -base64 32)

  cat >"$CFG_FILE" <<TOML
metadata_dir = "/var/lib/garage/meta"
data_dir     = "/var/lib/garage/data"

replication_factor = 1

rpc_bind_addr   = "0.0.0.0:3901"
rpc_public_addr = "127.0.0.1:3901"
rpc_secret      = "$RPC_SECRET"

[s3_api]
s3_region    = "$REGION"
api_bind_addr = "0.0.0.0:3900"

[admin]
api_bind_addr = "127.0.0.1:3903"
admin_token   = "$ADMIN_TOKEN"
metrics_token = "$METRICS_TOKEN"
TOML
}

write_compose() {
  info "Ghi docker-compose.yml: $COMPOSE_FILE"
  mkdir -p "$BASE_DIR"
  cat >"$COMPOSE_FILE" <<YML
services:
  $SERVICE_NAME:
    image: $GARAGE_IMAGE_TAG
    container_name: $SERVICE_NAME
    restart: unless-stopped
    network_mode: host
    environment:
      - RUST_LOG=garage=info
    volumes:
      - $CFG_FILE:/etc/garage.toml:ro
      - $BASE_DIR/meta:/var/lib/garage/meta
      - $BASE_DIR/data:/var/lib/garage/data
    command: ["/garage", "-c", "/etc/garage.toml", "server"]
YML
}

start_stack() { info "Khởi động Garage qua Docker Compose..."; docker compose -f "$COMPOSE_FILE" up -d --force-recreate; sleep 3; }
stop_stack()  { if docker compose -f "$COMPOSE_FILE" ps >/dev/null 2>&1; then info "Dừng Garage..."; docker compose -f "$COMPOSE_FILE" down || true; fi }

letsencrypt() {
  info "Yêu cầu chứng thư Let's Encrypt cho $S3_DOMAIN"
  certbot --nginx -d "$S3_DOMAIN" -m "$EMAIL" --agree-tos --non-interactive --redirect || true
  optimize_nginx_s3_site
}

ufw_rules() {
  if command_exists ufw && ufw status | grep -qi active; then
    info "Mở tường lửa UFW: 80/tcp, 443/tcp"; ufw allow 80/tcp || true; ufw allow 443/tcp || true
  fi
}

# ====== GARAGE CLI ======
GCLI() { docker compose -f "$COMPOSE_FILE" exec -T $SERVICE_NAME /garage -c /etc/garage.toml "$@"; }

wait_ready() {
  info "Chờ Garage sẵn sàng..."
  for _ in {1..60}; do GCLI status >/dev/null 2>&1 && return 0; sleep 1; done
  warn "Garage chưa phản hồi 'status', vẫn tiếp tục."; return 0
}

init_cluster_single() {
  wait_ready; info "Thiết lập layout 1 node..."
  local NODE_ID CUR NEW
  NODE_ID=$(GCLI status 2>/dev/null | awk '/^[0-9a-f]{16}/ {print $1; exit}')
  [[ -z "${NODE_ID:-}" ]] && NODE_ID=$(docker logs --since 15m "$SERVICE_NAME" 2>/dev/null | awk 'match($0,/Node ID of this node: ([0-9a-f]+)/,m){print m[1]; exit}')
  [[ -z "${NODE_ID:-}" ]] && { err "Không đọc được NODE_ID"; exit 1; }
  GCLI layout assign -z dc1 -c 1T "$NODE_ID" || true
  CUR=$(GCLI layout show | awk -F': ' '/Current layout version/{print $2; exit}')
  NEW=$(( ${CUR:-0} + 1 ))
  GCLI layout apply --version "$NEW" || true
}

create_bucket() { wait_ready; if GCLI bucket info "$BUCKET_NAME" >/dev/null 2>&1; then warn "Bucket '$BUCKET_NAME' đã tồn tại — bỏ qua."; else info "Tạo bucket: $BUCKET_NAME"; GCLI bucket create "$BUCKET_NAME"; fi }

create_key() {
  wait_ready; info "Tạo key: $KEY_NAME"
  local OUT KEY_ID SECRET_KEY CREDS
  OUT=$(GCLI key create "$KEY_NAME" || true)
  echo "$OUT" | sed 's/^/  /'
  KEY_ID=$(echo "$OUT" | awk -F': ' '/Key ID:/ {print $2; exit}')
  SECRET_KEY=$(echo "$OUT" | awk -F': ' '/Secret key:/ {print $2; exit}')
  if [[ -n "${KEY_ID:-}" && -n "${SECRET_KEY:-}" ]]; then
    CREDS="/root/garage-credentials.txt"
    cat > "$CREDS" <<CREDS
S3_ENDPOINT=https://$S3_DOMAIN
S3_REGION=$REGION
AWS_ACCESS_KEY_ID=$KEY_ID
AWS_SECRET_ACCESS_KEY=$SECRET_KEY
BUCKET=$BUCKET_NAME
CREDS
    chmod 600 "$CREDS"; info "Đã lưu thông tin truy cập: $CREDS"
  else
    warn "Không parse được Key ID/Secret; hãy tạo lại bằng: docker compose -f $COMPOSE_FILE exec -T $SERVICE_NAME /garage key create $KEY_NAME"
  fi
}

allow_key_bucket() { wait_ready; info "Cấp toàn quyền key '$KEY_NAME' cho bucket '$BUCKET_NAME'"; GCLI bucket allow --read --write --owner "$BUCKET_NAME" --key "$KEY_NAME"; }

show_status() { echo; info "Docker compose ps:"; docker compose -f "$COMPOSE_FILE" ps || true; echo; info "garage status:"; GCLI status || true; }

apply_and_restart() { write_config; write_compose; start_stack; optimize_nginx_s3_site; show_status; }
edit_config() { ${EDITOR:-nano} "$CFG_FILE"; }

# ====== QUY TRÌNH TRIỂN KHAI ======
full_install() {
  need_root; save_state; setup_dirs; apt_install; write_config; write_compose; ufw_rules; start_stack; optimize_nginx_s3_site; letsencrypt; optimize_nginx_s3_site; init_cluster_single; create_bucket; create_key; allow_key_bucket
}

final_summary() {
  cat <<END
$(color "\nHoàn tất!" 32)
S3 endpoint:   https://$S3_DOMAIN
Region:        $REGION
Bucket:        $BUCKET_NAME
Key name:      $KEY_NAME
Creds file:    /root/garage-credentials.txt

Thử với AWS CLI (path-style):
  source <(grep -E 'AWS_|S3_' /root/garage-credentials.txt | sed 's/^/export /')
  aws --endpoint-url https://$S3_DOMAIN s3 ls s3://$BUCKET_NAME/
END
}

# ====== GỠ CÀI ĐẶT ======
uninstall_all() {
  load_state; echo; warn "Gỡ cài đặt Garage + NGINX site. Bạn có thể chọn xoá dữ liệu và chứng thư."
  read -rp "Bạn có muốn XOÁ toàn bộ dữ liệu Garage tại $BASE_DIR/meta & $BASE_DIR/data? (y/N) " DEL_DATA
  read -rp "Bạn có muốn XOÁ chứng thư Let's Encrypt cho $S3_DOMAIN? (y/N) " DEL_CERT
  stop_stack
  rm -f "$COMPOSE_FILE"
  rm -f "$NGINX_SITE" /etc/nginx/sites-enabled/garage_s3
  nginx -t && systemctl reload nginx || true
  if [[ "${DEL_DATA,,}" == "y" ]]; then rm -rf "$BASE_DIR"; info "Đã xoá dữ liệu trong $BASE_DIR"; fi
  if [[ "${DEL_CERT,,}" == "y" ]]; then certbot delete --cert-name "$S3_DOMAIN" || true; fi
  info "Giữ lại cấu hình $CFG_FILE và trạng thái $STATE_FILE (bạn có thể xoá thủ công nếu muốn)."
  info "Gỡ cài đặt xong."
}

# ====== THIẾT LẬP THAM SỐ ======
configure_params() {
  load_state; echo; echo "Thiết lập tham số (Enter để giữ mặc định)"
  read -rp "S3 domain         [$S3_DOMAIN]: " x; S3_DOMAIN=${x:-$S3_DOMAIN}
  read -rp "Email Let'sEncrypt [$EMAIL]: " x; EMAIL=${x:-$EMAIL}
  read -rp "Bucket mặc định    [$BUCKET_NAME]: " x; BUCKET_NAME=${x:-$BUCKET_NAME}
  read -rp "Key name mặc định  [$KEY_NAME]: " x; KEY_NAME=${x:-$KEY_NAME}
  read -rp "Region             [$REGION]: " x; REGION=${x:-$REGION}
  read -rp "Thư mục lưu trữ BASE_DIR [$BASE_DIR]: " x; BASE_DIR=${x:-$BASE_DIR}
  COMPOSE_FILE="$BASE_DIR/docker-compose.yml"; save_state; setup_dirs
}

# ====== MENU BUCKET/KEY ======
bucket_exists() { GCLI bucket info "$1" >/dev/null 2>&1; }
create_bucket_interactive() { load_state; wait_ready; read -rp "Tên bucket mới [$BUCKET_NAME]: " b; b=${b:-$BUCKET_NAME}; if bucket_exists "$b"; then warn "Bucket '$b' đã tồn tại."; else info "Tạo bucket: $b"; GCLI bucket create "$b" || true; fi }
create_key_interactive() { load_state; wait_ready; read -rp "Tên key mới [$KEY_NAME]: " k; k=${k:-$KEY_NAME}; info "Tạo key: $k"; local OUT KEY_ID SECRET_KEY CREDS; OUT=$(GCLI key create "$k" || true); echo "$OUT" | sed 's/^/  /'; KEY_ID=$(echo "$OUT" | awk -F': ' '/Key ID:/ {print $2; exit}'); SECRET_KEY=$(echo "$OUT" | awk -F': ' '/Secret key:/ {print $2; exit}'); if [[ -n "${KEY_ID:-}" && -n "${SECRET_KEY:-}" ]]; then CREDS="/root/garage-credentials.txt"; cat > "$CREDS" <<CREDS
S3_ENDPOINT=https://$S3_DOMAIN
S3_REGION=$REGION
AWS_ACCESS_KEY_ID=$KEY_ID
AWS_SECRET_ACCESS_KEY=$SECRET_KEY
BUCKET=$BUCKET_NAME
CREDS
chmod 600 "$CREDS"; info "Đã lưu thông tin truy cập: $CREDS"; else warn "Không parse được Key ID/Secret; có thể key đã tồn tại. Hãy dùng tên khác."; fi }
allow_key_bucket_interactive() { load_state; wait_ready; read -rp "Bucket cần cấp quyền [$BUCKET_NAME]: " b; b=${b:-$BUCKET_NAME}; read -rp "Key cần cấp quyền   [$KEY_NAME]: " k; k=${k:-$KEY_NAME}; info "Cấp quyền key '$k' ↔ bucket '$b'"; GCLI bucket allow --read --write --owner "$b" --key "$k"; }
list_buckets() { load_state; wait_ready; info "Danh sách bucket:"; GCLI bucket list || true; }
menu_bucket_key() {
  PS3=$'Chọn tác vụ: '
  select opt in "Tạo bucket (nhập tên)" "Tạo key (nhập tên)" "Cấp quyền (nhập bucket & key)" "Liệt kê bucket" "Quay lại"; do
    case $REPLY in
      1) create_bucket_interactive; pause;; 2) create_key_interactive; pause;; 3) allow_key_bucket_interactive; pause;; 4) list_buckets; pause;; 5) break;; * ) echo "Chọn không hợp lệ";;
    esac
  done
}

# ====== NGINX GLOBAL (cache) ======
nginx_global_tune() {
  mkdir -p /var/cache/nginx/garage_public
  local CONF="/etc/nginx/conf.d/garage_global.conf"
  rm -f "$CONF" 2>/dev/null || true
  cat > "$CONF" <<'CONF'
# Cache store for public gateway
proxy_cache_path /var/cache/nginx/garage_public levels=1:2 keys_zone=gp_cache:100m max_size=20g inactive=7d use_temp_path=off;

# General proxy buffers (không bật gzip để tránh trùng với cấu hình hệ thống)
proxy_buffering on;
proxy_buffers 64 64k;
proxy_buffer_size 16k;
proxy_busy_buffers_size 256k;
CONF
  nginx -t && systemctl reload nginx || true
}

# ====== PUBLIC GATEWAY (public.<base>) ======
public_gateway_enable() {
  load_state; nginx_global_tune
  local BASE=${S3_DOMAIN#*.}; local PUB_DOMAIN_SUGGEST="public.$BASE"
  read -rp "Nhập public domain cho link public [$PUB_DOMAIN_SUGGEST]: " PUB_DOMAIN; PUB_DOMAIN=${PUB_DOMAIN:-$PUB_DOMAIN_SUGGEST}

  # enable/replace [s3_web]
  if grep -q '^\[s3_web\]' "$CFG_FILE"; then
    awk 'BEGIN{skip=0} /^\[s3_web\]/{print "# [s3_web] (replaced)"; skip=1; next} /^\[/{if(skip==1){skip=0}} skip==0{print}' "$CFG_FILE" > "$CFG_FILE.tmp" && mv "$CFG_FILE.tmp" "$CFG_FILE"
  fi
  cat >> "$CFG_FILE" <<EOF
[s3_web]
bind_addr  = "127.0.0.1:3902"
root_domain = ".${PUB_DOMAIN}"
index      = "index.html"
EOF
  docker compose -f "$COMPOSE_FILE" restart || start_stack

  local ALLOW_MAP="/etc/nginx/garage_public_allow.map.conf"
  [[ -f "$ALLOW_MAP" ]] || echo "# ~^/bucket/path$ 1;" > "$ALLOW_MAP"

  local SITE="/etc/nginx/sites-available/garage_public"; local CERT_DIR="/etc/letsencrypt/live/$PUB_DOMAIN"; local HAVE_CERT=0
  [[ -f "$CERT_DIR/fullchain.pem" && -f "$CERT_DIR/privkey.pem" ]] && HAVE_CERT=1

  # HTTP server (giữ http để ACME hoạt động, redirect nếu đã có cert)
  cat > "$SITE" <<'NGINX'
# allow-list cho file/bucket public
map $request_uri $public_ok {
  default 0;
  include /etc/nginx/garage_public_allow.map.conf;
}

upstream garage_web { server 127.0.0.1:3902; keepalive 64; }
map $request_method $skip_cache { default 1; GET 0; HEAD 0; }

server {
  listen 80; listen [::]:80;
  server_name PUBLIC_DOMAIN;

  proxy_cache gp_cache;
  proxy_cache_methods GET HEAD;
  proxy_cache_key "$scheme$host$uri$is_args$args";
  proxy_cache_lock on;
  proxy_cache_min_uses 1;
  proxy_cache_valid 200 206 10m;
  proxy_cache_valid 301 302 1h;
  proxy_cache_use_stale error timeout invalid_header updating http_500 http_502 http_503 http_504;
  proxy_cache_background_update on;
  proxy_cache_revalidate on;
  add_header X-Cache $upstream_cache_status always;

  location ~ ^/([^/]+)/?(.*)$ {
    if ($public_ok = 0) { return 403; }
    set $bucket $1;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $bucket.PUBLIC_DOMAIN;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_no_cache $skip_cache;
    proxy_cache_bypass $skip_cache;
    # Bỏ prefix bucket rồi forward, KHÔNG dùng proxy_pass có URI (tránh 404)
    rewrite ^/[^/]+/?(.*)$ /$1 break;
    proxy_pass http://127.0.0.1:3902;
  }
}
NGINX

  if (( HAVE_CERT == 1 )); then
    cat >> "$SITE" <<'NGINX'
server {
  listen 443 ssl http2; listen [::]:443 ssl http2;
  server_name PUBLIC_DOMAIN;

  ssl_certificate     CERT_FULLCHAIN;
  ssl_certificate_key CERT_PRIVKEY;

  proxy_cache gp_cache;
  proxy_cache_methods GET HEAD;
  proxy_cache_key "$scheme$host$uri$is_args$args";
  proxy_cache_lock on;
  proxy_cache_min_uses 1;
  proxy_cache_valid 200 206 10m;
  proxy_cache_valid 301 302 1h;
  proxy_cache_use_stale error timeout invalid_header updating http_500 http_502 http_503 http_504;
  proxy_cache_background_update on;
  proxy_cache_revalidate on;
  add_header X-Cache $upstream_cache_status always;

  location ~ ^/([^/]+)/?(.*)$ {
    if ($public_ok = 0) { return 403; }
    set $bucket $1;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $bucket.PUBLIC_DOMAIN;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_no_cache $skip_cache;
    proxy_cache_bypass $skip_cache;
    rewrite ^/[^/]+/?(.*)$ /$1 break;
    proxy_pass http://127.0.0.1:3902;
  }
}
NGINX
    sed -i "s|CERT_FULLCHAIN|$CERT_DIR/fullchain.pem|; s|CERT_PRIVKEY|$CERT_DIR/privkey.pem|" "$SITE"
  fi
  sed -i "s/PUBLIC_DOMAIN/${PUB_DOMAIN}/g" "$SITE"
  ln -sf "$SITE" /etc/nginx/sites-enabled/garage_public
  nginx -t && systemctl reload nginx

  if (( HAVE_CERT == 1 )); then
    info "Public gateway sẵn sàng: https://${PUB_DOMAIN} (VD: https://${PUB_DOMAIN}/<bucket>/<path>)"
  else
    warn "Chưa có chứng thư cho ${PUB_DOMAIN}. Dùng menu: 'Cấp chứng thư public domain', sau đó chạy lại mục (1)."
    info "Tạm thời truy cập HTTP: http://${PUB_DOMAIN}/<bucket>/<path>"
  fi
}

public_issue_cert() {
  load_state
  local BASE=${S3_DOMAIN#*.}; local PUB_DOMAIN_SUGGEST="public.$BASE"
  read -rp "Cấp chứng thư cho public domain nào [$PUB_DOMAIN_SUGGEST]: " PUB_DOMAIN; PUB_DOMAIN=${PUB_DOMAIN:-$PUB_DOMAIN_SUGGEST}
  certbot --nginx -d "$PUB_DOMAIN" -m "$EMAIL" --agree-tos --non-interactive --redirect || true
  public_gateway_enable
}

public_bucket_allow() {
  load_state; wait_ready
  read -rp "Bucket cần public [$BUCKET_NAME]: " b; b=${b:-$BUCKET_NAME}
  info "Cho phép website cho bucket: $b"; GCLI bucket website --allow "$b" || true
  # Thêm wildcard vào allow-list của Nginx
  local ALLOW_MAP="/etc/nginx/garage_public_allow.map.conf"
  [[ -f "$ALLOW_MAP" ]] || echo "# ~^/bucket/path$ 1;" > "$ALLOW_MAP"
  grep -qE "^~\^/${b}/\.\*\$ 1;" "$ALLOW_MAP" || echo "~^/${b}/.*$ 1;" >> "$ALLOW_MAP"
  nginx -t && systemctl reload nginx || true
  local BASE=${S3_DOMAIN#*.}; local PUB_DOMAIN="public.$BASE"; echo "URL mẫu: https://$PUB_DOMAIN/$b/<path>"
}

public_bucket_disallow() {
  load_state; wait_ready
  read -rp "Bucket cần thu hồi public [$BUCKET_NAME]: " b; b=${b:-$BUCKET_NAME}
  info "Tắt website cho bucket: $b"; GCLI bucket website --disable "$b" || true
}

public_gateway_disable() {
  load_state; info "Gỡ public gateway (bỏ [s3_web], xoá nginx site, tuỳ chọn xoá cert)"
  if grep -q '^\[s3_web\]' "$CFG_FILE"; then
    awk 'BEGIN{skip=0} /^\[s3_web\]/{skip=1; next} /^\[/{if(skip==1){skip=0}} skip==0{print}' "$CFG_FILE" > "$CFG_FILE.tmp" && mv "$CFG_FILE.tmp" "$CFG_FILE"
  fi
  docker compose -f "$COMPOSE_FILE" restart || true
  rm -f /etc/nginx/sites-enabled/garage_public /etc/nginx/sites-available/garage_public /etc/nginx/conf.d/garage_global.conf
  nginx -t && systemctl reload nginx || true
  read -rp "Xoá chứng thư liên quan đến public domain? (y/N) " del
  if [[ ${del,,} == y ]]; then
    certbot certificates 2>/dev/null | awk '/Certificate Name:/{name=$3} /Domains:/{print name":"$0}' | while IFS= read -r line; do name=${line%%:*}; info "Xoá cert: $name"; certbot delete --cert-name "$name" --non-interactive || true; done
  fi
  info "Đã gỡ public gateway."
}

public_allow_file() {
  load_state; local ALLOW_MAP="/etc/nginx/garage_public_allow.map.conf"
  read -rp "Bucket: " b; read -rp "Object path (ví dụ docker/introduction-to-docker-light.pdf): " o
  wait_ready; GCLI bucket website --allow "$b" >/dev/null 2>&1 || true
  # Escape regex đúng cách (thêm backslash trước metachar)
  local esc; esc=$(printf '%s' "$o" | sed -e 's/[][()^.$*+?{}|\/-]/\\&/g')
  [[ -f "$ALLOW_MAP" ]] || echo "# ~^/bucket/path$ 1;" > "$ALLOW_MAP"
  local pat="~^/"$b"/"$esc"$ 1;"
  grep -qF "$pat" "$ALLOW_MAP" || echo "$pat" >> "$ALLOW_MAP"
  nginx -t && systemctl reload nginx
  info "Đã bật public cho: /$b/$o"
}

public_revoke_file() {
  local ALLOW_MAP="/etc/nginx/garage_public_allow.map.conf"
  read -rp "Bucket: " b; read -rp "Object path: " o
  local esc; esc=$(printf '%s' "$o" | sed -e 's/[][()^.$*+?{}|\/-]/\\&/g')
  local pat="~^/"$b"/"$esc"$ 1;"
  if [[ -f "$ALLOW_MAP" ]]; then
    grep -vF "$pat" "$ALLOW_MAP" > "$ALLOW_MAP.tmp" && mv "$ALLOW_MAP.tmp" "$ALLOW_MAP"
    nginx -t && systemctl reload nginx; info "Đã thu hồi public cho: /$b/$o"
  else
    warn "Chưa có allowlist file: $ALLOW_MAP"
  fi
}

public_list_allowed() { local ALLOW_MAP="/etc/nginx/garage_public_allow.map.conf"; [[ -f "$ALLOW_MAP" ]] && nl -ba "$ALLOW_MAP" || warn "Chưa có allowlist."; }

menu_public_gateway() {
  PS3=$'Chọn tác vụ: '
  select opt in \
    "Bật public gateway (s3_web nội bộ + nginx public.<base>)" \
    "Cho phép public cho bucket" \
    "Thu hồi public cho bucket" \
    "Cấp chứng thư public domain" \
    "Bật public CHO MỘT FILE" \
    "Thu hồi public CHO MỘT FILE" \
    "Liệt kê các file public" \
    "Gỡ public gateway" \
    "Quay lại"; do
    case $REPLY in
      1) public_gateway_enable; pause;;
      2) public_bucket_allow;  pause;;
      3) public_bucket_disallow; pause;;
      4) public_issue_cert;   pause;;
      5) public_allow_file;   pause;;
      6) public_revoke_file;  pause;;
      7) public_list_allowed; pause;;
      8) public_gateway_disable; pause;;
      9) break;;
      *) echo "Chọn không hợp lệ";;
    esac
  done
}

# ====== S3 API NGINX (s3.<domain>) ======
optimize_nginx_s3_site() {
  load_state
  local SITE="$NGINX_SITE"; local CERT_DIR="/etc/letsencrypt/live/$S3_DOMAIN"; local HAVE_CERT=0
  [[ -f "$CERT_DIR/fullchain.pem" && -f "$CERT_DIR/privkey.pem" ]] && HAVE_CERT=1
  mkdir -p /var/www/html

  cat > "$SITE" <<'NGINX'
upstream garage_s3 { server 127.0.0.1:3900; keepalive 32; }
server {
  listen 80; listen [::]:80; server_name S3_DOMAIN;
  location ^~ /.well-known/acme-challenge/ { root /var/www/html; }
  return 301 https://$host$request_uri;
}
NGINX

  if (( HAVE_CERT == 1 )); then
    cat >> "$SITE" <<'NGINX'
server {
  listen 443 ssl http2; listen [::]:443 ssl http2; server_name S3_DOMAIN;
  ssl_certificate     CERT_FULLCHAIN;
  ssl_certificate_key CERT_PRIVKEY;
  client_max_body_size 0; proxy_request_buffering off;
  location / {
    proxy_http_version 1.1; proxy_set_header Connection ""; proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_no_cache 1; proxy_cache_bypass 1; proxy_pass http://garage_s3;
  }
}
NGINX
    sed -i "s|CERT_FULLCHAIN|$CERT_DIR/fullchain.pem|; s|CERT_PRIVKEY|$CERT_DIR/privkey.pem|" "$SITE"
  fi
  sed -i "s/S3_DOMAIN/$S3_DOMAIN/g" "$SITE"
  ln -sf "$SITE" /etc/nginx/sites-enabled/garage_s3
  nginx -t && systemctl reload nginx || true
}

# ====== CÔNG CỤ S3 ======
ensure_aws_env() {
  load_state
  if [[ -f /root/garage-credentials.txt ]]; then sed -i 's/\r$//' /root/garage-credentials.txt 2>/dev/null || true; set -a; . /root/garage-credentials.txt; set +a; fi
  : "${AWS_ACCESS_KEY_ID:=}"; : "${AWS_SECRET_ACCESS_KEY:=}"; : "${S3_REGION:=$REGION}"; : "${S3_ENDPOINT:=https://$S3_DOMAIN}"
  if [[ -z "$AWS_ACCESS_KEY_ID" || -z "$AWS_SECRET_ACCESS_KEY" ]]; then read -rp "AWS_ACCESS_KEY_ID: " AWS_ACCESS_KEY_ID; read -rp "AWS_SECRET_ACCESS_KEY: " AWS_SECRET_ACCESS_KEY; fi
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION="$S3_REGION"
}

s3_presign_interactive() { load_state; ensure_aws_env; read -rp "Bucket [$BUCKET_NAME]: " b; b=${b:-$BUCKET_NAME}; read -rp "Đường dẫn object (vd path/file.txt): " o; read -rp "Hết hạn (phút) [60]: " m; m=${m:-60}; local secs=$((m*60)); aws --endpoint-url "$S3_ENDPOINT" s3 presign "s3://$b/$o" --expires-in "$secs" | sed 's/^/URL: /'; }
s3_upload_interactive()  { load_state; ensure_aws_env; read -rp "File local cần upload: " p; read -rp "Bucket [$BUCKET_NAME]: " b; b=${b:-$BUCKET_NAME}; read -rp "Object key (tên đích): " o; aws --endpoint-url "$S3_ENDPOINT" s3 cp "$p" "s3://$b/$o"; }
s3_download_interactive(){ load_state; ensure_aws_env; read -rp "Bucket [$BUCKET_NAME]: " b; b=${b:-$BUCKET_NAME}; read -rp "Object key (tên nguồn): " o; read -rp "Đích lưu local [./]: " d; d=${d:-./}; aws --endpoint-url "$S3_ENDPOINT" s3 cp "s3://$b/$o" "$d"; }
s3_list_bucket_interactive(){ load_state; ensure_aws_env; read -rp "Bucket cần liệt kê [$BUCKET_NAME]: " b; b=${b:-$BUCKET_NAME}; aws --endpoint-url "$S3_ENDPOINT" s3 ls "s3://$b/" --human-readable --summarize; }

menu_s3_tools() {
  PS3=$'Chọn tác vụ: '
  select opt in "Tạo pre-signed URL (download)" "Upload file lên S3" "Tải file từ S3" "Liệt kê nội dung bucket" "Quay lại"; do
    case $REPLY in
      1) s3_presign_interactive; pause;; 2) s3_upload_interactive; pause;; 3) s3_download_interactive; pause;; 4) s3_list_bucket_interactive; pause;; 5) break;; * ) echo "Chọn không hợp lệ";;
    esac
  done
}

# ====== CHẨN ĐOÁN ======
diag_status() { GCLI status || true; echo; GCLI layout show || true; }
diag_logs()   { docker logs --tail 200 "$SERVICE_NAME" 2>/dev/null || true; }
diag_ports()  { command -v ss >/dev/null 2>&1 && ss -ltnp | egrep ':(3900|3901|3902|80|443)\b' || netstat -ltnp 2>/dev/null | egrep ':(3900|3901|3902|80|443)\b' || true; }
diag_nginx_test() { nginx -t || true; }

menu_diag() {
  PS3=$'Chọn tác vụ: '
  select opt in "Garage status + layout show" "Xem 200 dòng log gần nhất" "Kiểm tra cổng lắng nghe" "Kiểm tra cấu hình Nginx" "Quay lại"; do
    case $REPLY in
      1) diag_status; pause;; 2) diag_logs; pause;; 3) diag_ports; pause;; 4) diag_nginx_test; pause;; 5) break;; * ) echo "Chọn không hợp lệ";;
    esac
  done
}

# ====== BACKUP & RESTORE ======
backup_all() {
  need_root; load_state; ts=$(date +%Y%m%d-%H%M%S); default_file="/root/garage-backup-$ts.tar.zst"
  echo; read -rp "Đường dẫn file backup [.tar.zst] [$default_file]: " bf; BACKUP_FILE=${bf:-$default_file}
  was_up=0; docker compose -f "$COMPOSE_FILE" ps 2>/dev/null | grep -q Up && was_up=1
  info "Dừng Garage để backup nhất quán..."; stop_stack || true
  declare -a paths; for p in "$BASE_DIR/meta" "$BASE_DIR/data" "$COMPOSE_FILE" "$CFG_FILE" "/etc/garage-installer.env" "/root/garage-credentials.txt" "$NGINX_SITE" "/etc/letsencrypt"; do [[ -e "$p" ]] && paths+=("$p"); done
  if [[ "$BACKUP_FILE" == *.zip ]]; then command -v zip >/dev/null 2>&1 || apt-get install -y zip; info "Đang nén backup (ZIP) → $BACKUP_FILE ..."; zip -r "$BACKUP_FILE" "${paths[@]}"; else info "Đang nén backup (tar.zst) → $BACKUP_FILE ..."; tar --zstd -cf "$BACKUP_FILE" "${paths[@]}"; fi
  info "Hoàn tất backup (${#paths[@]} mục)."; [[ $was_up -eq 1 ]] && { info "Khởi động lại Garage sau backup..."; start_stack; }
  echo; info "File backup: $BACKUP_FILE"
}

restore_all() {
  need_root; load_state; echo; read -rp "Nhập đường dẫn file backup (.tar.zst/.zip): " BACKUP_FILE; [[ -f "$BACKUP_FILE" ]] || { err "Không tìm thấy $BACKUP_FILE"; pause; return 1; }
  warn "Khôi phục sẽ ghi đè cấu hình/dữ liệu hiện có (sẽ tạo bản sao dự phòng)."; read -rp "Tiếp tục khôi phục? (y/N) " ans; [[ ${ans,,} == y ]] || { info "Huỷ khôi phục."; return 0; }
  ts=$(date +%Y%m%d-%H%M%S); PRE_FILE="/root/garage-pre-restore-$ts.tar.zst"; info "Dừng Garage..."; stop_stack || true
  declare -a cur; for p in "$BASE_DIR/meta" "$BASE_DIR/data" "$COMPOSE_FILE" "$CFG_FILE" "/etc/garage-installer.env" "$NGINX_SITE" "/etc/letsencrypt"; do [[ -e "$p" ]] && cur+=("$p"); done
  if [[ ${#cur[@]} -gt 0 ]]; then info "Sao lưu trạng thái hiện tại → $PRE_FILE"; tar --zstd -cf "$PRE_FILE" "${cur[@]}"; fi
  info "Giải nén backup vào / ..."; mkdir -p "$BASE_DIR"; if [[ "$BACKUP_FILE" == *.zip ]]; then command -v unzip >/dev/null 2>&1 || apt-get install -y unzip; unzip -o "$BACKUP_FILE" -d /; else tar --zstd -xf "$BACKUP_FILE" -C /; fi
  if [[ -f "$NGINX_SITE" ]]; then ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/garage_s3; nginx -t && systemctl reload nginx || true; fi
  if [[ -f "$COMPOSE_FILE" ]]; then info "Khởi động Garage từ compose..."; docker compose -f "$COMPOSE_FILE" up -d; else warn "Không thấy $COMPOSE_FILE – hãy chạy mục 'Cài đặt & triển khai' để tạo lại compose, sau đó copy dữ liệu đã khôi phục."; fi
  show_status; info "Khôi phục xong. Bản sao dự phòng trước khôi phục: $PRE_FILE"
}

# ====== MENU CHÍNH ======
main_menu() {
  need_root; load_state
  while true; do
    clear
    echo "Garage Menu Installer — Ubuntu 22.04 — $SCRIPT_VERSION"
    echo "========================================================="
    echo "S3 domain : $S3_DOMAIN"
    echo "Email     : $EMAIL"
    echo "Bucket    : $BUCKET_NAME"
    echo "Key name  : $KEY_NAME"
    echo "Region    : $REGION"
    echo "Image     : $GARAGE_IMAGE_TAG"
    echo "CFG file  : $CFG_FILE"
    echo "Storage   : $BASE_DIR"
    echo
    echo "1) Cài đặt & triển khai đầy đủ"
    echo "2) Thiết lập tham số (domain/email/bucket/key/region/BASE_DIR)"
    echo "3) Chỉnh sửa cấu hình Garage (mở $CFG_FILE)"
    echo "4) Áp dụng cấu hình & khởi động lại Garage"
    echo "5) Bucket / Key / Quyền (tiện ích)"
    echo "6) Xem trạng thái"
    echo "7) Backup hệ thống → .tar.zst/.zip"
    echo "8) Khôi phục từ file backup .tar.zst/.zip"
    echo "9) Public gateway (public.<base> path → s3_web)"
    echo "10) Công cụ S3 (presign, upload/download, ls)"
    echo "11) Chẩn đoán (status/layout/logs/ports/nginx)"
    echo "12) Gỡ cài đặt"
    echo "13) Thoát"
    echo
    read -rp "Chọn [1-13]: " choice
    case "$choice" in
      1) full_install; pause;;
      2) configure_params; pause;;
      3) edit_config; pause;;
      4) apply_and_restart; pause;;
      5) menu_bucket_key;;
      6) show_status; pause;;
      7) backup_all; pause;;
      8) restore_all; pause;;
      9) menu_public_gateway;;
      10) menu_s3_tools;;
      11) menu_diag;;
      12) uninstall_all; pause;;
      13) exit 0;;
      *) echo "Chọn không hợp lệ"; sleep 1;;
    esac
  done
}

# ====== CHẠY MENU ======
main_menu
