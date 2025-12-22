#!/usr/bin/env bash
set -euo pipefail

# n8n manager + Cloudflare Tunnel
N8N_HOST_DEFAULT="n8n.rawcode.io"
TUNNEL_NAME_DEFAULT="n8n-tunnel"
INSTALL_DIR_DEFAULT="/opt/n8n"
TIMEZONE_DEFAULT="Asia/Ho_Chi_Minh"
DB_NAME_DEFAULT="n8n"
DB_USER_DEFAULT="n8n"
N8N_IMAGE_DEFAULT="docker.n8n.io/n8nio/n8n"
DATA_DIR_DEFAULT="/root/.n8n"
CLOUDFLARED_CONFIG="/etc/cloudflared/n8n-tunnel.yml"
SYSTEMD_SERVICE="/etc/systemd/system/cloudflared-n8n.service"

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "❌ Vui lòng chạy script với quyền root (sudo)." >&2
    exit 1
  fi
}

pause() {
  read -rp "Nhấn Enter để tiếp tục..."
}

install_deps() {
  echo "▶ Cập nhật hệ thống & cài gói phụ thuộc..."
  apt-get update -y
  apt-get install -y curl ca-certificates gnupg lsb-release wget jq >/dev/null 2>&1 || apt-get install -y curl ca-certificates gnupg lsb-release wget jq
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "❌ Docker chưa được cài. Vui lòng cài Docker trước rồi chạy lại."
    exit 1
  fi
}

ensure_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then
    return
  fi
  echo "▶ Cài đặt cloudflared..."
  local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
  curl -fsSL "$url" -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared
}

prompt_with_default() {
  local prompt="$1"
  local default="$2"
  local var
  read -rp "$prompt [$default]: " var
  if [[ -z "$var" ]]; then
    var="$default"
  fi
  printf '%s\n' "$var"
}

prompt_password_twice() {
  local pass1 pass2
  while true; do
    >&2 echo "ℹ️ Lưu ý: khi nhập mật khẩu, terminal sẽ KHÔNG hiện ký tự."
    >&2 echo
    read -srp "Mật khẩu database PostgreSQL: " pass1; echo
    read -srp "Nhập lại mật khẩu database PostgreSQL: " pass2; echo
    if [[ -z "$pass1" ]]; then
      >&2 echo "❌ Mật khẩu không được để trống."
      continue
    fi
    if [[ "$pass1" != "$pass2" ]]; then
      >&2 echo "❌ Mật khẩu nhập lại không khớp, thử lại."
      continue
    fi
    break
  done
  printf '%s\n' "$pass1"
}

ensure_tunnel() {
  local TUNNEL_NAME="$1"
  echo "▶ Đảm bảo tunnel '$TUNNEL_NAME' tồn tại..."
  local TUNNEL_ID
  TUNNEL_ID=$(cloudflared tunnel list 2>/dev/null | awk -v name="$TUNNEL_NAME" '$2==name{print $1}' | head -n1 || true)

  if [[ -n "${TUNNEL_ID:-}" ]]; then
    echo "ℹ️ Tunnel '$TUNNEL_NAME' đã tồn tại, dùng lại."
  else
    echo "▶ Tạo tunnel mới '$TUNNEL_NAME'..."
    local CREATE_OUTPUT
    CREATE_OUTPUT=$(cloudflared tunnel create "$TUNNEL_NAME" 2>&1 || true)
    echo "$CREATE_OUTPUT"
    TUNNEL_ID=$(printf '%s\n' "$CREATE_OUTPUT" | awk '/Created tunnel/{print $NF}' | tail -n1 || true)
    if [[ -z "${TUNNEL_ID:-}" ]]; then
      TUNNEL_ID=$(cloudflared tunnel list 2>/dev/null | awk -v name="$TUNNEL_NAME" '$2==name{print $1}' | head -n1 || true)
    fi
    if [[ -z "${TUNNEL_ID:-}" ]]; then
      echo "❌ Không lấy được Tunnel ID cho '$TUNNEL_NAME'. Dừng." >&2
      exit 1
    fi
  fi

  local CREDENTIALS_FILE="/root/.cloudflared/${TUNNEL_ID}.json"
  if [[ ! -f "$CREDENTIALS_FILE" ]]; then
    CREDENTIALS_FILE=$(ls /root/.cloudflared/"${TUNNEL_ID}"*.json 2>/dev/null | head -n1 || true)
  fi

  if [[ ! -f "$CREDENTIALS_FILE" ]]; then
    echo "❌ Không tìm thấy credentials file cho tunnel ID $TUNNEL_ID trong /root/.cloudflared." >&2
    exit 1
  fi

  echo "   → Tunnel ID:   $TUNNEL_ID"
  echo "   → Credentials: $CREDENTIALS_FILE"

  N8N_TUNNEL_ID="$TUNNEL_ID"
  N8N_TUNNEL_CRED="$CREDENTIALS_FILE"
}

write_cloudflared_config() {
  local tunnel_id="$1"
  local cred_file="$2"
  local hostname="$3"

  mkdir -p /etc/cloudflared
  cat > "$CLOUDFLARED_CONFIG" <<EOF
tunnel: $tunnel_id
credentials-file: $cred_file

ingress:
  - hostname: $hostname
    service: http://127.0.0.1:5678
  - service: http_status:404
EOF
  echo "▶ Ghi file config tunnel: $CLOUDFLARED_CONFIG"
}

enable_cloudflared_service() {
  echo "▶ Ghi systemd service: $SYSTEMD_SERVICE"
  cat > "$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Cloudflare Tunnel - n8n-tunnel (n8n)
After=network-online.target
Wants=network-online.target

[Service]
TimeoutStartSec=0
Type=simple
Restart=always
ExecStart=/usr/local/bin/cloudflared --no-autoupdate --config $CLOUDFLARED_CONFIG tunnel run

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable cloudflared-n8n.service >/dev/null 2>&1 || true
  systemctl restart cloudflared-n8n.service

  echo "✅ Cloudflare Tunnel đã chạy. Kiểm tra nhanh:"
  systemctl status cloudflared-n8n.service --no-pager -l | sed -n '1,15p'
}

install_or_update_n8n() {
  echo
  echo "=== CÀI ĐẶT / CẬP NHẬT n8n + PostgreSQL + Cloudflare Tunnel ==="

  local N8N_HOST TUNNEL_NAME INSTALL_DIR TIMEZONE DB_NAME DB_USER DB_PASS N8N_IMAGE DATA_DIR

  N8N_HOST=$(prompt_with_default "Hostname cho n8n" "$N8N_HOST_DEFAULT")
  TUNNEL_NAME=$(prompt_with_default "Tên tunnel" "$TUNNEL_NAME_DEFAULT")
  INSTALL_DIR=$(prompt_with_default "Thư mục cài n8n" "$INSTALL_DIR_DEFAULT")
  TIMEZONE=$(prompt_with_default "Timezone" "$TIMEZONE_DEFAULT")
  DB_NAME=$(prompt_with_default "Tên database PostgreSQL" "$DB_NAME_DEFAULT")
  DB_USER=$(prompt_with_default "User database PostgreSQL" "$DB_USER_DEFAULT")

  DB_PASS=$(prompt_password_twice)

  N8N_IMAGE=$(prompt_with_default "Image n8n" "$N8N_IMAGE_DEFAULT")
  DATA_DIR="$DATA_DIR_DEFAULT"

  echo
  echo "📌 Tóm tắt:"
  echo "   - Hostname:       $N8N_HOST"
  echo "   - Tunnel name:    $TUNNEL_NAME"
  echo "   - Install dir:    $INSTALL_DIR"
  echo "   - Timezone:       $TIMEZONE"
  echo "   - DB:             $DB_NAME"
  echo "   - DB user:        $DB_USER"
  echo "   - n8n image:      $N8N_IMAGE"
  echo "   - Service name:   cloudflared-n8n.service"
  echo "   - Data dir:       $DATA_DIR (mount vào /home/node/.n8n)"
  echo "   * Nếu đã cài trước đó, KHÔNG nên đổi DB password nếu chưa xoá volume DB."
  echo

  read -rp "Tiếp tục cài đặt? [y/N]: " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo "Huỷ cài đặt."
    return
  fi

  install_deps
  ensure_docker
  ensure_cloudflared

  echo
  echo "▶ Ghi file docker-compose.yml trong $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
  mkdir -p "$DATA_DIR"
  chown 1000:1000 "$DATA_DIR" || true

  cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
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
      - N8N_HOST=$N8N_HOST
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=https://$N8N_HOST/
      - TZ=$TIMEZONE
      - GENERIC_TIMEZONE=$TIMEZONE
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
      - TZ=$TIMEZONE
    volumes:
      - n8n_postgres_data:/var/lib/postgresql/data

volumes:
  n8n_postgres_data:
    name: n8n_postgres_data
EOF

  echo "▶ Triển khai stack n8n + PostgreSQL (dùng Postgres 16, data mount $DATA_DIR)..."
  (
    cd "$INSTALL_DIR"
    docker compose pull n8n n8n-postgres || true
    docker compose up -d
  )

  echo "✅ n8n đã khởi động (local): http://127.0.0.1:5678"
  echo "   (Đợi vài giây cho container n8n & postgres ổn định...)"
  sleep 5

  if command -v curl >/dev/null 2>&1; then
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5678 || echo "000")
    echo "▶ Thử curl từ local tới n8n: HTTP code: $code"
  fi

  echo
  echo "ℹ️ Đã có cert Cloudflare tại /root/.cloudflared/cert.pem, bỏ qua bước 'cloudflared tunnel login' (nếu chưa có, hãy chạy 'cloudflared tunnel login' thủ công trước)."

  ensure_tunnel "$TUNNEL_NAME"

  echo "▶ Tạo / cập nhật DNS record cho $N8N_HOST..."
  if cloudflared tunnel route dns "$TUNNEL_NAME" "$N8N_HOST"; then
    echo "   → Đã tạo/cập nhật CNAME cho $N8N_HOST."
  else
    echo "⚠ Không tạo được DNS cho $N8N_HOST (có thể record đã tồn tại). Hãy kiểm tra lại trong Cloudflare."
  fi

  write_cloudflared_config "$N8N_TUNNEL_ID" "$N8N_TUNNEL_CRED" "$N8N_HOST"
  enable_cloudflared_service

  echo
  echo "🎉 HOÀN TẤT CÀI n8n + TUNNEL!"
  echo "   - n8n qua Cloudflare:  https://$N8N_HOST"
  echo "   - Local:               http://127.0.0.1:5678"
  echo
  echo "Lần đầu vào UI n8n, bạn sẽ tạo user owner."
}

status_n8n() {
  echo
  echo "=== TRẠNG THÁI n8n + TUNNEL ==="
  echo
  echo "▶ Docker containers (liên quan n8n):"
  if docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -i 'n8n' | column -t; then
    :
  else
    echo "Không tìm thấy container n8n."
  fi

  echo
  echo "▶ Systemd service: cloudflared-n8n.service"
  if systemctl list-unit-files | grep -q '^cloudflared-n8n\.service'; then
    systemctl status cloudflared-n8n.service --no-pager -l | sed -n '1,20p'
  else
    echo "Không có (hoặc service đang failed) cloudflared-n8n.service"
  fi

  echo
  echo "▶ Danh sách tunnel có chữ 'n8n':"
  cloudflared tunnel list 2>/dev/null | grep -i 'n8n' || echo "Không thấy tunnel nào chứa 'n8n'."

  echo
  echo "▶ Thử curl từ local tới n8n:"
  if command -v curl >/dev/null 2>&1; then
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5678 || echo "000")
    echo "HTTP code: $code"
  else
    echo "curl chưa cài, bỏ qua."
  fi
}

uninstall_n8n() {
  echo
  echo "=== GỠ n8n + Cloudflare Tunnel (local) ==="
  read -rp "Bạn chắc chắn muốn gỡ n8n (container + service tunnel local)? [y/N]: " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo "Huỷ gỡ."
    return
  fi

  local INSTALL_DIR DATA_DIR
  INSTALL_DIR="$INSTALL_DIR_DEFAULT"
  DATA_DIR="$DATA_DIR_DEFAULT"

  echo "▶ Dừng & xoá container n8n / n8n-postgres (nếu có)..."
  if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    (
      cd "$INSTALL_DIR"
      docker compose down || true
    )
  else
    docker rm -f n8n n8n-postgres 2>/dev/null || true
  fi

  echo "▶ Dừng & xoá systemd service cloudflared-n8n..."
  if systemctl list-unit-files | grep -q '^cloudflared-n8n\.service'; then
    systemctl stop cloudflared-n8n.service 2>/dev/null || true
    systemctl disable cloudflared-n8n.service 2>/dev/null || true
    rm -f "$SYSTEMD_SERVICE"
    systemctl daemon-reload
  fi

  if [[ -d "$DATA_DIR" ]]; then
    read -rp "Bạn có muốn XOÁ thư mục data '$DATA_DIR' (mất toàn bộ workflows, credentials, settings)? [y/N]: " ans
    if [[ "${ans,,}" == "y" ]]; then
      rm -rf "$DATA_DIR"
      echo "   → Đã xoá thư mục $DATA_DIR."
    fi
  fi

  local CANDIDATE_VOLUMES
  CANDIDATE_VOLUMES=$(docker volume ls --format '{{.Name}}' | grep -E '(^n8n_postgres_data$|^n8n_n8n_postgres_data$)' || true)
  if [[ -n "${CANDIDATE_VOLUMES:-}" ]]; then
    echo "Các Docker volume Postgres liên quan đến n8n được tìm thấy:"
    echo "$CANDIDATE_VOLUMES" | sed 's/^/   - /'
    read -rp "Bạn có muốn XOÁ các volume này (XOÁ TOÀN BỘ DB n8n)? [y/N]: " ans
    if [[ "${ans,,}" == "y" ]]; then
      echo "$CANDIDATE_VOLUMES" | xargs -r docker volume rm || true
    fi
  fi

  if [[ -d "$INSTALL_DIR" ]]; then
    read -rp "Bạn có muốn XOÁ thư mục cài đặt '$INSTALL_DIR' (docker-compose.yml, env...)? [y/N]: " ans
    if [[ "${ans,,}" == "y" ]]; then
      rm -rf "$INSTALL_DIR"
      echo "   → Đã xoá thư mục $INSTALL_DIR."
    fi
  fi

  if [[ -f "$CLOUDFLARED_CONFIG" ]]; then
    echo
    echo "▶ Thông tin tunnel từ file cấu hình $CLOUDFLARED_CONFIG:"
    local TUNNEL_ID TUNNEL_NAME
    TUNNEL_ID=$(grep -E '^tunnel:' "$CLOUDFLARED_CONFIG" | awk '{print $2}' | head -n1 || true)
    if [[ -n "${TUNNEL_ID:-}" ]]; then
      TUNNEL_NAME=$(cloudflared tunnel list 2>/dev/null | awk -v id="$TUNNEL_ID" '$1==id{print $2}' | head -n1 || true)
      echo "   - Tunnel ID:   $TUNNEL_ID"
      [[ -n "$TUNNEL_NAME" ]] && echo "   - Tunnel name: $TUNNEL_NAME"

      read -rp "Bạn có muốn XOÁ Cloudflare Tunnel '${TUNNEL_NAME:-$TUNNEL_ID}' khỏi account Cloudflare (cloudflared tunnel delete)? [y/N]: " ans
      if [[ "${ans,,}" == "y" ]]; then
        cloudflared tunnel delete "${TUNNEL_NAME:-$TUNNEL_ID}" || echo "⚠ Xoá tunnel thất bại, hãy kiểm tra lại thủ công."
      fi
    fi

    read -rp "Bạn có muốn XOÁ file cấu hình local '$CLOUDFLARED_CONFIG'? [y/N]: " ans
    if [[ "${ans,,}" == "y" ]]; then
      rm -f "$CLOUDFLARED_CONFIG"
      echo "   → Đã xoá file cấu hình tunnel local."
    fi
  fi

  echo
  echo "⚠ Về Cloudflare DNS:"
  echo "   - Script KHÔNG tự xoá CNAME DNS trên Cloudflare."
  echo "   - Sau khi xoá tunnel (nếu có), hãy vào Cloudflare Dashboard để xoá record CNAME tương ứng (ví dụ: $N8N_HOST_DEFAULT) nếu không dùng nữa."
  echo
  echo "✅ Đã gỡ n8n (container) + service cloudflared-n8n trên máy chủ (tuỳ chọn xoá data như bạn đã chọn)."
}

update_n8n_only() {
  echo
  echo "=== UPDATE n8n (pull image mới nhất, giữ nguyên data) ==="

  local INSTALL_DIR
  INSTALL_DIR="$INSTALL_DIR_DEFAULT"

  ensure_docker

  if [[ ! -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    echo "❌ Không tìm thấy $INSTALL_DIR/docker-compose.yml."
    echo "   Có vẻ n8n chưa được cài bằng script này."
    return
  fi

  echo "▶ Pull image mới nhất cho n8n & postgres..."
  (
    cd "$INSTALL_DIR"
    docker compose pull n8n n8n-postgres || true
  )

  echo "▶ Khởi động lại stack n8n (giữ nguyên data /root/.n8n & volume Postgres)..."
  (
    cd "$INSTALL_DIR"
    docker compose up -d
  )

  echo "✅ ĐÃ UPDATE n8n."
  docker ps --filter "name=n8n" --format '   - {{.Names}}: {{.Image}} ({{.Status}})'
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
    read -rp "Chọn chức năng (0-4): " choice
    case "$choice" in
      1) install_or_update_n8n ;;
      2) status_n8n ;;
      3) uninstall_n8n ;;
      4) update_n8n_only ;;
      0) echo "Bye!"; exit 0 ;;
      *) echo "Lựa chọn không hợp lệ."; ;;
    esac
    echo
  done
}

ensure_root
main_menu
