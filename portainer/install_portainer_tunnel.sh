#!/usr/bin/env bash
set -euo pipefail

### ============================
###  CONFIG & INPUT
### ============================

if [ "$EUID" -ne 0 ]; then
  echo "❌ Vui lòng chạy script với quyền root (sudo su hoặc sudo ./install_portainer_tunnel.sh)"
  exit 1
fi

echo "=== CÀI ĐẶT PORTAINER + CLOUDFLARE TUNNEL (Ubuntu) ==="

read -rp "Nhập hostname cho Portainer (vd: portainer.rawcode.io): " PORTAINER_HOST
if [ -z "$PORTAINER_HOST" ]; then
  echo "❌ Hostname không được để trống."
  exit 1
fi

read -rp "Tên Cloudflare Tunnel [portainer-tunnel]: " TUNNEL_NAME
TUNNEL_NAME=${TUNNEL_NAME:-portainer-tunnel}

# Config mặc định Portainer
PORTAINER_CONTAINER_NAME="portainer"
PORTAINER_IMAGE="portainer/portainer-ce:latest"
PORTAINER_DATA_VOLUME="portainer_data"
PORTAINER_HTTP_PORT=9000
PORTAINER_HTTPS_PORT=9443
PORTAINER_BIND_ADDR="127.0.0.1"   # chỉ listen local cho an toàn

echo
echo "📌 Tóm tắt cấu hình:"
echo "   - Portainer host:     $PORTAINER_HOST"
echo "   - Tunnel name:        $TUNNEL_NAME"
echo "   - Container name:     $PORTAINER_CONTAINER_NAME"
echo "   - Bind address:       $PORTAINER_BIND_ADDR"
echo "   - HTTP port:          $PORTAINER_HTTP_PORT"
echo "   - HTTPS port:         $PORTAINER_HTTPS_PORT"
echo
read -rp "Xác nhận tiếp tục? [y/N]: " CONFIRM
CONFIRM=${CONFIRM:-n}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "⏹ Hủy cài đặt."
  exit 0
fi

### ============================
###  STEP 1: CÀI GÓI CẦN THIẾT
### ============================

echo "▶ Cập nhật hệ thống & cài gói phụ thuộc..."
apt update -y
apt install -y curl ca-certificates gnupg lsb-release

# Docker: cài nếu chưa có
if ! command -v docker &>/dev/null; then
  echo "⚠ Không tìm thấy docker, tiến hành cài đặt Docker CE..."
  install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  fi
  apt update -y
  apt install -y docker-ce docker-ce-cli containerd.io
fi

systemctl enable docker
systemctl start docker

### ============================
###  STEP 2: CÀI PORTAINER
### ============================

echo "▶ Cài đặt Portainer CE..."

# Nếu container đã tồn tại thì stop + remove
if docker ps -a --format '{{.Names}}' | grep -wq "$PORTAINER_CONTAINER_NAME"; then
  echo "⚠ Container '$PORTAINER_CONTAINER_NAME' đã tồn tại. Đang dừng và xóa..."
  docker stop "$PORTAINER_CONTAINER_NAME" >/dev/null 2>&1 || true
  docker rm "$PORTAINER_CONTAINER_NAME" >/dev/null 2>&1 || true
fi

# Tạo volume nếu chưa có
if ! docker volume inspect "$PORTAINER_DATA_VOLUME" &>/dev/null; then
  echo "📦 Tạo volume dữ liệu: $PORTAINER_DATA_VOLUME"
  docker volume create "$PORTAINER_DATA_VOLUME" >/dev/null
fi

echo "🐳 Chạy container Portainer (HTTP 9000, HTTPS 9443, bind $PORTAINER_BIND_ADDR)..."

docker run -d \
  -p "${PORTAINER_BIND_ADDR}:${PORTAINER_HTTP_PORT}:9000" \
  -p "${PORTAINER_BIND_ADDR}:${PORTAINER_HTTPS_PORT}:9443" \
  --name="$PORTAINER_CONTAINER_NAME" \
  --restart=always \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "${PORTAINER_DATA_VOLUME}:/data" \
  "$PORTAINER_IMAGE"

echo "✅ Portainer đã được cài."
echo "   Local HTTP : http://${PORTAINER_BIND_ADDR}:${PORTAINER_HTTP_PORT}"
echo "   Local HTTPS: https://${PORTAINER_BIND_ADDR}:${PORTAINER_HTTPS_PORT}"
echo "   (Lần đầu HTTPS sẽ cảnh báo self-signed cert là bình thường.)"

### ============================
###  STEP 3: CÀI CLOUDFLARE TUNNEL
###  (config: /etc/cloudflared/${TUNNEL_NAME}.yml,
###   service: cloudflared-portainer.service)
### ============================

echo
echo "▶ Cài đặt cloudflared (Cloudflare Tunnel)..."

if ! command -v cloudflared &>/dev/null; then
  cd /tmp
  curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb
  dpkg -i cloudflared.deb || apt -f install -y
fi

CLOUDFLARE_CERT="/root/.cloudflared/cert.pem"

echo
if [ ! -f "$CLOUDFLARE_CERT" ]; then
  echo "🔑 Chưa có cert Cloudflare, cần login để cấp quyền cho tunnel."
  echo "   - Lệnh sau sẽ in ra một URL."
  echo "   - Bạn copy URL đó, mở trong trình duyệt, đăng nhập Cloudflare."
  echo "   - Chọn zone chứa domain: ${PORTAINER_HOST}"
  echo "   - Sau khi màn hình báo thành công, quay lại terminal."
  echo
  read -rp "Nhấn Enter để chạy 'cloudflared tunnel login'..." _
  cloudflared tunnel login
else
  echo "ℹ️ Đã có cert Cloudflare tại ${CLOUDFLARE_CERT}, bỏ qua bước 'cloudflared tunnel login'."
fi

echo "✅ Chuẩn bị xong chứng chỉ Cloudflare."

# Nếu tunnel đã tồn tại, không cần tạo lại
if cloudflared tunnel list 2>/dev/null | grep -w "$TUNNEL_NAME" >/dev/null; then
  echo "ℹ️ Tunnel '${TUNNEL_NAME}' đã tồn tại, dùng lại tunnel này."
else
  echo "▶ Tạo Tunnel mới: ${TUNNEL_NAME}..."
  cloudflared tunnel create "$TUNNEL_NAME"
fi

echo "▶ Lấy Tunnel ID & credentials file tương ứng..."
TUNNEL_ID=$(cloudflared tunnel list 2>/dev/null | awk -v t="$TUNNEL_NAME" '$0 ~ t {print $1; exit}')
if [ -z "$TUNNEL_ID" ]; then
  echo "❌ Không lấy được Tunnel ID cho '${TUNNEL_NAME}'."
  exit 1
fi

CLOUDFLARED_DIR="/root/.cloudflared"
CRED_FILE="${CLOUDFLARED_DIR}/${TUNNEL_ID}.json"

if [ ! -f "$CRED_FILE" ]; then
  echo "❌ Không tìm thấy credentials file: $CRED_FILE"
  echo "   Hãy chạy 'ls -l ${CLOUDFLARED_DIR}' để kiểm tra và sửa tay."
  exit 1
fi

echo "   Dùng credentials file: $CRED_FILE"

echo "▶ Tạo / cập nhật DNS record trên Cloudflare cho ${PORTAINER_HOST}..."
# Dùng --overwrite-dns để ép trỏ về đúng tunnel, và bắt lỗi "already exists" cho idempotent
DNS_OUTPUT=""
if ! DNS_OUTPUT=$(cloudflared tunnel route dns --overwrite-dns "$TUNNEL_ID" "$PORTAINER_HOST" 2>&1); then
  echo "$DNS_OUTPUT"
  if echo "$DNS_OUTPUT" | grep -qi "already exists"; then
    echo "⚠️ DNS record cho ${PORTAINER_HOST} đã tồn tại."
    echo "   Hãy đảm bảo trong Cloudflare Dashboard:"
    echo "   - Type: CNAME"
    echo "   - Name: ${PORTAINER_HOST}"
    echo "   - Target: ${TUNNEL_ID}.cfargotunnel.com"
    echo "   Script vẫn tiếp tục vì tunnel & service đã chạy."
  else
    echo "❌ Lỗi tạo DNS record (không phải do record đã tồn tại). Dừng script."
    exit 1
  fi
else
  echo "$DNS_OUTPUT"
fi

echo "▶ Tạo file cấu hình tunnel riêng cho Portainer..."

mkdir -p /etc/cloudflared
CF_CONFIG_FILE="/etc/cloudflared/${TUNNEL_NAME}.yml"                # vd: /etc/cloudflared/portainer-tunnel.yml
CF_SERVICE_FILE="/etc/systemd/system/cloudflared-portainer.service" # tên service cố định

cat >"$CF_CONFIG_FILE" <<EOF
tunnel: ${TUNNEL_NAME}
credentials-file: ${CRED_FILE}

ingress:
  - hostname: ${PORTAINER_HOST}
    service: https://localhost:${PORTAINER_HTTPS_PORT}
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF

echo "   → Đã tạo config: $CF_CONFIG_FILE"

echo "▶ Tạo (hoặc ghi đè) systemd service: cloudflared-portainer.service"

CF_BIN="$(command -v cloudflared)"

# Nếu service cũ tồn tại, dừng trước cho sạch
if systemctl list-unit-files | grep -q "^cloudflared-portainer.service"; then
  systemctl disable --now cloudflared-portainer.service 2>/dev/null || true
fi

cat >"$CF_SERVICE_FILE" <<EOF
[Unit]
Description=Cloudflare Tunnel - ${TUNNEL_NAME} (Portainer)
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=${CF_BIN} --no-autoupdate --config ${CF_CONFIG_FILE} tunnel run
Restart=always
RestartSec=5
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

echo "   → Đã tạo service file: $CF_SERVICE_FILE"

echo "🔄 Reload systemd & bật service cloudflared-portainer..."
systemctl daemon-reload
systemctl enable --now cloudflared-portainer.service

echo "✅ Cloudflare Tunnel đã chạy. Kiểm tra trạng thái:"
systemctl status cloudflared-portainer.service --no-pager || true

echo
echo "🎉 HOÀN TẤT PORTAINER + TUNNEL!"
echo "   - Portainer qua Cloudflare: https://${PORTAINER_HOST}"
echo "   - Lần đầu truy cập sẽ phải tạo tài khoản admin trong UI Portainer."
echo
echo "Nếu UI chưa vào được, hãy chờ 1–2 phút cho Tunnel & DNS cập nhật."
