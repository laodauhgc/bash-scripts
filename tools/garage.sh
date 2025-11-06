#!/usr/bin/env bash
# Force UTF-8 để tránh lỗi hiển thị ký tự trên một số VPS
export LC_ALL=C.UTF-8 LANG=C.UTF-8
# Garage Menu Installer for Ubuntu 22.04 — dùng menu tương tác
SCRIPT_VERSION="v1.2.1-2025-11-06"
# Cách chạy: sudo bash garage_menu.sh

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
BUCKET_DEFAULT="demo"
KEY_NAME_DEFAULT="demo-key"

# ====== HÀM TIỆN ÍCH ======
color() { echo -e "[1;${2}m$1[0m"; }
info()  { color "[INFO] $1" 34; }
warn()  { color "[WARN] $1" 33; }
err()   { color "[ERR ] $1" 31; }

need_root() {
  if [[ $(id -u) -ne 0 ]]; then err "Hãy chạy với quyền root (sudo)."; exit 1; fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

load_state() {
  # Nạp tham số từ file trạng thái nếu có; nếu không gán mặc định
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi
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

pause() { read -rp $'
Nhấn Enter để tiếp tục... '; }

# ====== THIẾT LẬP HỆ THỐNG ======
apt_install() {
  info "Cài đặt gói cần thiết (Docker, Compose plugin, NGINX, Certbot, jq)..."
  export DEBIAN_FRONTEND=noninteractive

  # Phát hiện repo Docker chính thức → dùng bộ docker-ce; nếu không → dùng gói Ubuntu (docker.io)
  local has_docker_repo=0
  if grep -Rqs "download.docker.com" /etc/apt/sources.list* 2>/dev/null; then
    has_docker_repo=1
  fi

  apt-get update -y

  # Gói chung
  apt-get install -y ca-certificates curl gnupg lsb-release nginx certbot python3-certbot-nginx jq zip unzip

  if command -v docker >/dev/null 2>&1; then
    info "Docker đã sẵn có → bỏ qua bước cài Docker."
  else
    if [[ $has_docker_repo -eq 1 ]]; then
      # Chuyển sang bộ Docker CE (tránh xung đột: gỡ containerd của Ubuntu nếu có)
      apt-get remove -y containerd || true
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
      # Dùng gói Ubuntu (docker.io) và đảm bảo không còn containerd.io
      apt-get remove -y containerd.io || true
      apt-get install -y docker.io docker-compose-plugin
    fi
  fi

  systemctl enable --now docker || true
}

setup_dirs() {
  info "Tạo thư mục $BASE_DIR ..."
  mkdir -p "$BASE_DIR/meta" "$BASE_DIR/data"
}

write_config() {
  info "Ghi cấu hình Garage: $CFG_FILE"
  local RPC_SECRET ADMIN_TOKEN METRICS_TOKEN

  if [[ -f "$CFG_FILE" ]]; then
    cp -a "$CFG_FILE" "${CFG_FILE}.bak.$(date +%s)" || true
    # Giữ nguyên token/secret cũ để tránh lỗi handshake khi container đang chạy
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

start_stack() {
  info "Khởi động Garage qua Docker Compose..."
  # Luôn tái tạo để nạp cấu hình mới (tránh lệch rpc_secret)
  docker compose -f "$COMPOSE_FILE" up -d --force-recreate
  sleep 3
}

stop_stack() {
  if docker compose -f "$COMPOSE_FILE" ps >/dev/null 2>&1; then
    info "Dừng Garage..."; docker compose -f "$COMPOSE_FILE" down || true
  fi
}

nginx_basic() {
  info "Tạo site NGINX cho $S3_DOMAIN (HTTP proxy → 3900)"
  cat > "$NGINX_SITE" <<NGINX
server {
  listen 80;
  listen [::]:80;
  server_name $S3_DOMAIN;
  client_max_body_size 0;
  proxy_request_buffering off;
  location / {
    proxy_pass http://127.0.0.1:3900;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_http_version 1.1;
  }
}
NGINX
  ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/garage_s3
  nginx -t
  systemctl reload nginx
}

letsencrypt() {
  info "Yêu cầu chứng thư Let's Encrypt cho $S3_DOMAIN"
  certbot --nginx -d "$S3_DOMAIN" -m "$EMAIL" --agree-tos --non-interactive --redirect
}

ufw_rules() {
  if command_exists ufw && ufw status | grep -qi active; then
    info "Mở tường lửa UFW: 80/tcp, 443/tcp"
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true
  fi
}

# ====== GARAGE CLI (trong container) ======
GCLI() { docker compose -f "$COMPOSE_FILE" exec -T $SERVICE_NAME /garage -c /etc/garage.toml "$@"; }

wait_ready() {
  info "Chờ Garage sẵn sàng..."
  # thử lâu hơn và khoan báo lỗi sớm
  for i in {1..60}; do
    if GCLI status >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  warn "Garage có thể chưa sẵn sàng nhưng sẽ tiếp tục bước kế (assign layout)."
  return 0
}; do
    if GCLI status >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  err "Garage chưa sẵn sàng."; return 1
}

init_cluster_single() {
  wait_ready
  info "Thiết lập layout 1 node..."
  local NODE_ID CUR NEW
  NODE_ID=$(GCLI status 2>/dev/null | awk '/^[0-9a-f]{16}/{print $1; exit}')
  if [[ -z "${NODE_ID:-}" ]]; then
    NODE_ID=$(docker logs --since 15m "$SERVICE_NAME" 2>/dev/null | awk 'match($0,/Node ID of this node: ([0-9a-f]+)/,m){print m[1]; exit}')
  fi
  if [[ -z "${NODE_ID:-}" ]]; then err "Không đọc được NODE_ID"; exit 1; fi
  GCLI layout assign -z dc1 -c 1T "$NODE_ID" || true
  CUR=$(GCLI layout show | awk -F': ' '/Current layout version/{print $2; exit}')
  NEW=$(( ${CUR:-0} + 1 ))
  GCLI layout apply --version "$NEW" || true
}

create_bucket() {
  wait_ready
  info "Tạo bucket: $BUCKET_NAME"
  GCLI bucket create "$BUCKET_NAME" || true
}

create_key() {
  wait_ready
  info "Tạo key: $KEY_NAME"
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
    chmod 600 "$CREDS"
    info "Đã lưu thông tin truy cập: $CREDS"
  else
    warn "Không parse được Key ID/Secret; hãy tạo lại bằng: docker compose -f $COMPOSE_FILE exec -T $SERVICE_NAME /garage key create $KEY_NAME"
  fi
}

allow_key_bucket() {
  wait_ready
  info "Cấp toàn quyền key '$KEY_NAME' cho bucket '$BUCKET_NAME'"
  GCLI bucket allow --read --write --owner "$BUCKET_NAME" --key "$KEY_NAME"
}

show_status() {
  echo
  info "Docker compose ps:"; docker compose -f "$COMPOSE_FILE" ps || true
  echo
  info "garage status:"; GCLI status || true
}

apply_and_restart() {
  info "Reload cấu hình (restart container)"
  docker compose -f "$COMPOSE_FILE" restart || true
  show_status
}

edit_config() {
  ${EDITOR:-nano} "$CFG_FILE"
}

# ====== QUY TRÌNH TRIỂN KHAI TỰ ĐỘNG ======
full_install() {
  need_root; load_state; save_state
  apt_install
  setup_dirs
  write_config
  write_compose
  ufw_rules
  start_stack
  nginx_basic
  letsencrypt
  init_cluster_single
  create_bucket
  create_key
  allow_key_bucket
  final_summary
}

final_summary() {
  cat <<END
$(color "
Hoàn tất!" 32)
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
  load_state
  echo
  warn "Gỡ cài đặt Garage + NGINX site. Bạn có thể chọn xoá dữ liệu và chứng thư."
  read -rp "Bạn có muốn XOÁ toàn bộ dữ liệu Garage tại $BASE_DIR/meta & $BASE_DIR/data? (y/N) " DEL_DATA
  read -rp "Bạn có muốn XOÁ chứng thư Let's Encrypt cho $S3_DOMAIN? (y/N) " DEL_CERT

  stop_stack

  # Xoá compose & container (đã down ở trên)
  rm -f "$COMPOSE_FILE"

  # Gỡ site NGINX
  rm -f "$NGINX_SITE" /etc/nginx/sites-enabled/garage_s3
  nginx -t && systemctl reload nginx || true

  # Xoá dữ liệu nếu chọn
  if [[ "${DEL_DATA,,}" == "y" ]]; then
    rm -rf "$BASE_DIR"
    info "Đã xoá dữ liệu trong $BASE_DIR"
  fi

  # Xoá cert nếu chọn
  if [[ "${DEL_CERT,,}" == "y" ]]; then
    certbot delete --cert-name "$S3_DOMAIN" || true
  fi

  info "Giữ lại cấu hình $CFG_FILE và trạng thái $STATE_FILE (bạn có thể xoá thủ công nếu muốn)."
  info "Gỡ cài đặt xong."
}

# ====== THIẾT LẬP THAM SỐ TƯƠNG TÁC ======
configure_params() {
  load_state
  echo
  echo "Thiết lập tham số (Enter để giữ mặc định)"
  read -rp "S3 domain         [$S3_DOMAIN]: " x; S3_DOMAIN=${x:-$S3_DOMAIN}
  read -rp "Email Let'sEncrypt [$EMAIL]: " x; EMAIL=${x:-$EMAIL}
  read -rp "Bucket mặc định    [$BUCKET_NAME]: " x; BUCKET_NAME=${x:-$BUCKET_NAME}
  read -rp "Key name mặc định  [$KEY_NAME]: " x; KEY_NAME=${x:-$KEY_NAME}
  read -rp "Region             [$REGION]: " x; REGION=${x:-$REGION}
  read -rp "Thư mục lưu trữ BASE_DIR [$BASE_DIR]: " x; BASE_DIR=${x:-$BASE_DIR}
  COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
  save_state
  setup_dirs
}

# ====== MENU CON ======
menu_bucket_key() {
  PS3=$'Chọn tác vụ: '
  select opt in \
    "Tạo bucket" \
    "Tạo key" \
    "Cấp quyền key ↔ bucket" \
    "Quay lại"; do
    case $REPLY in
      1) load_state; create_bucket; pause ;;
      2) load_state; create_key; pause ;;
      3) load_state; allow_key_bucket; pause ;;
      4) break ;;
      *) echo "Chọn không hợp lệ" ;;
    esac
  done
}

# ====== BACKUP & RESTORE ======
backup_all() {
  need_root; load_state
  ts=$(date +%Y%m%d-%H%M%S)
  default_file="/root/garage-backup-$ts.tar.zst"
  echo
  read -rp "Đường dẫn file backup [.tar.zst] [$default_file]: " bf
  BACKUP_FILE=${bf:-$default_file}

  was_up=0
  if docker compose -f "$COMPOSE_FILE" ps 2>/dev/null | grep -q Up; then was_up=1; fi
  info "Dừng Garage để backup nhất quán..."
  stop_stack || true

  # Gom danh sách đường dẫn thực sự tồn tại
  declare -a paths
  for p in \
    "$BASE_DIR/meta" \
    "$BASE_DIR/data" \
    "$COMPOSE_FILE" \
    "$CFG_FILE" \
    "/etc/garage-installer.env" \
    "/root/garage-credentials.txt" \
    "$NGINX_SITE" \
    "/etc/letsencrypt"; do
    [[ -e "$p" ]] && paths+=("$p")
  done

  if [[ "$BACKUP_FILE" == *.zip ]]; then
    command -v zip >/dev/null 2>&1 || apt-get install -y zip
    info "Đang nén backup (ZIP) → $BACKUP_FILE ..."
    zip -r "$BACKUP_FILE" "${paths[@]}"
  else
    info "Đang nén backup (tar.zst) → $BACKUP_FILE ..."
    tar --zstd -cf "$BACKUP_FILE" "${paths[@]}"
  fi
  info "Hoàn tất backup (${#paths[@]} mục)."

  if [[ $was_up -eq 1 ]]; then
    info "Khởi động lại Garage sau backup..."; start_stack
  fi
  echo
  info "File backup: $BACKUP_FILE"
}

restore_all() {
  need_root; load_state
  echo
  read -rp "Nhập đường dẫn file backup (.tar.zst): " BACKUP_FILE
  [[ -f "$BACKUP_FILE" ]] || { err "Không tìm thấy $BACKUP_FILE"; pause; return 1; }
  warn "Khôi phục sẽ ghi đè cấu hình/dữ liệu hiện có (sẽ tạo bản sao dự phòng)."
  read -rp "Tiếp tục khôi phục? (y/N) " ans
  [[ ${ans,,} == y ]] || { info "Huỷ khôi phục."; return 0; }

  ts=$(date +%Y%m%d-%H%M%S)
  PRE_FILE="/root/garage-pre-restore-$ts.tar.zst"

  info "Dừng Garage..."; stop_stack || true

  # Lưu ảnh hiện tại nếu tồn tại
  declare -a cur
  for p in "$BASE_DIR/meta" "$BASE_DIR/data" "$COMPOSE_FILE" "$CFG_FILE" \
           "/etc/garage-installer.env" "$NGINX_SITE" "/etc/letsencrypt"; do
    [[ -e "$p" ]] && cur+=("$p")
  done
  if [[ ${#cur[@]} -gt 0 ]]; then
    info "Sao lưu trạng thái hiện tại → $PRE_FILE"
    tar --zstd -cf "$PRE_FILE" "${cur[@]}"
  fi

  info "Giải nén backup vào / ..."
  mkdir -p "$BASE_DIR"
  if [[ "$BACKUP_FILE" == *.zip ]]; then
    command -v unzip >/dev/null 2>&1 || apt-get install -y unzip
    unzip -o "$BACKUP_FILE" -d /
  else
    tar --zstd -xf "$BACKUP_FILE" -C /
  fi

  # Đảm bảo site NGINX được bật
  if [[ -f "$NGINX_SITE" ]]; then
    ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/garage_s3
    nginx -t && systemctl reload nginx || true
  fi

  # Khởi động Garage
  if [[ -f "$COMPOSE_FILE" ]]; then
    info "Khởi động Garage từ compose..."
    docker compose -f "$COMPOSE_FILE" up -d
  else
    warn "Không thấy $COMPOSE_FILE – hãy chạy mục 'Cài đặt & triển khai' để tạo lại compose, sau đó copy dữ liệu đã khôi phục."
  fi

  show_status
  info "Khôi phục xong. Bản sao dự phòng trước khôi phục: $PRE_FILE"
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
    echo "9) Gỡ cài đặt"
    echo "10) Thoát"
    echo
    read -rp "Chọn [1-10]: " choice
    case "$choice" in
      1) full_install; pause ;;
      2) configure_params; pause ;;
      3) edit_config; pause ;;
      4) apply_and_restart; pause ;;
      5) menu_bucket_key ;;
      6) show_status; pause ;;
      7) backup_all; pause ;;
      8) restore_all; pause ;;
      9) uninstall_all; pause ;;
      10) exit 0 ;;
      *) echo "Chọn không hợp lệ"; sleep 1 ;;
    esac
  done
}

# ====== CHẠY MENU ======
main_menu
