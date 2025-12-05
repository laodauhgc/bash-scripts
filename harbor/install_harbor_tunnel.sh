#!/usr/bin/env bash
set -euo pipefail

### ============================
###  CONFIG & INPUT
### ============================

if [ "$EUID" -ne 0 ]; then
  echo "❌ Vui lòng chạy script với quyền root (sudo su hoặc sudo ./script.sh)"
  exit 1
fi

echo "=== CÀI ĐẶT HARBOR + CLOUDFLARE TUNNEL (Ubuntu) ==="

read -rp "Nhập hostname cho Harbor (vd: harbor.rawcode.io): " HARBOR_HOST
if [ -z "$HARBOR_HOST" ]; then
  echo "❌ Hostname không được để trống."
  exit 1
fi

while true; do
  read -srp "Nhập mật khẩu admin Harbor: " HARBOR_ADMIN_PWD
  echo
  read -srp "Nhập lại mật khẩu admin Harbor: " HARBOR_ADMIN_PWD_CONFIRM
  echo
  if [ "$HARBOR_ADMIN_PWD" = "$HARBOR_ADMIN_PWD_CONFIRM" ] && [ -n "$HARBOR_ADMIN_PWD" ]; then
    break
  else
    echo "❌ Mật khẩu không trùng hoặc rỗng, hãy nhập lại."
  fi
done

read -rp "Nhập version Harbor [v2.11.0]: " HARBOR_VERSION
HARBOR_VERSION=${HARBOR_VERSION:-v2.11.0}

read -rp "Tên Cloudflare Tunnel [harbor-tunnel]: " TUNNEL_NAME
TUNNEL_NAME=${TUNNEL_NAME:-harbor-tunnel}

read -rp "Thư mục cài Harbor [/opt/harbor]: " INSTALL_DIR
INSTALL_DIR=${INSTALL_DIR:-/opt/harbor}

echo
echo "📌 Tóm tắt cấu hình:"
echo "   - Harbor host:        $HARBOR_HOST"
echo "   - Harbor version:     $HARBOR_VERSION"
echo "   - Tunnel name:        $TUNNEL_NAME"
echo "   - Install directory:  $INSTALL_DIR"
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
apt install -y curl jq ca-certificates gnupg lsb-release

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

# docker compose (plugin hoặc binary)
if ! docker compose version &>/dev/null; then
  if ! command -v docker-compose &>/dev/null; then
    echo "▶ Cài docker-compose..."
    apt install -y docker-compose
  fi
fi

systemctl enable docker
systemctl start docker

### ============================
###  STEP 2: CÀI HARBOR
### ============================

echo "▶ Tải và cài Harbor (${HARBOR_VERSION})..."

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

HARBOR_TGZ="harbor-online-installer-${HARBOR_VERSION}.tgz"
if [ ! -f "$HARBOR_TGZ" ]; then
  echo "▶ Tải $HARBOR_TGZ từ GitHub..."
  wget "https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}/${HARBOR_TGZ}"
fi

# Giải nén vào INSTALL_DIR (strip thư mục gốc)
tar xzf "$HARBOR_TGZ" --strip-components=1

if [ ! -f harbor.yml.tmpl ]; then
  echo "❌ Không tìm thấy harbor.yml.tmpl trong $INSTALL_DIR"
  exit 1
fi

echo "▶ Tạo file cấu hình harbor.yml..."

# Chỉ tạo mới nếu chưa có, để lần sau có thể giữ config
if [ ! -f harbor.yml ]; then
  cp harbor.yml.tmpl harbor.yml
fi

# Sửa hostname
sed -i "s/^hostname:.*/hostname: ${HARBOR_HOST}/" harbor.yml

# Sửa mật khẩu admin
if grep -q "^harbor_admin_password:" harbor.yml; then
  sed -i "s/^harbor_admin_password:.*/harbor_admin_password: ${HARBOR_ADMIN_PWD}/" harbor.yml
else
  echo "harbor_admin_password: ${HARBOR_ADMIN_PWD}" >> harbor.yml
fi

# Cấu hình HTTP port 80 (Harbor listen nội bộ, Cloudflare Tunnel sẽ terminate HTTPS)
if grep -q "^http:" harbor.yml; then
  # Đảm bảo http port là 80
  awk '
  /^http:/ { print; getline; if ($1 == "port:") { print "  port: 80"; next } }
  { print }
  ' harbor.yml > harbor.yml.tmp && mv harbor.yml.tmp harbor.yml
else
  cat <<EOF >> harbor.yml

http:
  port: 80
  relativeurls: false
EOF
fi

# Vô hiệu hóa https block (comment các dòng chính)
sed -i 's/^https:/# https_disabled:/g' harbor.yml
sed -i 's/^  port: 443/#  port: 443/g' harbor.yml
sed -i 's/^  certificate:/#  certificate:/g' harbor.yml
sed -i 's/^  private_key:/#  private_key:/g' harbor.yml

echo "▶ Cài đặt Harbor (chạy ./install.sh)..."
./install.sh

echo "✅ Harbor đã được cài. Kiểm tra container..."
docker ps | grep harbor || echo "⚠ Không thấy container harbor trong docker ps, hãy kiểm tra log trong $INSTALL_DIR."

### ============================
###  STEP 3: CÀI CLOUDFLARE TUNNEL
### ============================

echo
echo "▶ Cài đặt cloudflared (Cloudflare Tunnel)..."

if ! command -v cloudflared &>/dev/null; then
  cd /tmp
  curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb
  dpkg -i cloudflared.deb || apt -f install -y
fi

echo
echo "🔑 Bước tiếp theo: ĐĂNG NHẬP CLOUDFLARE ĐỂ CẤP QUYỀN CHO TUNNEL."
echo "   - Lệnh sau sẽ in ra một URL."
echo "   - Bạn copy URL đó, mở trong trình duyệt, đăng nhập Cloudflare."
echo "   - Chọn zone chứa domain: ${HARBOR_HOST}"
echo "   - Sau khi màn hình báo thành công, quay lại terminal."
echo
read -rp "Nhấn Enter để chạy 'cloudflared tunnel login'..." _

cloudflared tunnel login

echo "✅ Đăng nhập Cloudflare xong. Tạo Tunnel: ${TUNNEL_NAME}..."

cloudflared tunnel create "$TUNNEL_NAME"

echo "▶ Tìm file credentials mới tạo trong /root/.cloudflared..."
CLOUDFLARED_DIR="/root/.cloudflared"
if [ ! -d "$CLOUDFLARED_DIR" ]; then
  echo "❌ Không tìm thấy thư mục $CLOUDFLARED_DIR"
  exit 1
fi

# Lấy file JSON mới nhất (thường chính là credentials của tunnel vừa tạo)
CRED_FILE=$(ls -t ${CLOUDFLARED_DIR}/*.json 2>/dev/null | head -n1 || true)

if [ -z "$CRED_FILE" ]; then
  echo "❌ Không tìm thấy file credentials .json trong $CLOUDFLARED_DIR"
  echo "   Hãy chạy 'ls -l /root/.cloudflared' để kiểm tra và sửa tay trong /etc/cloudflared/config.yml."
  exit 1
fi

echo "   Dùng credentials file: $CRED_FILE"

echo "▶ Tạo DNS record trên Cloudflare cho ${HARBOR_HOST}..."
cloudflared tunnel route dns "$TUNNEL_NAME" "$HARBOR_HOST"

echo "▶ Tạo file cấu hình /etc/cloudflared/config.yml..."

mkdir -p /etc/cloudflared

cat >/etc/cloudflared/config.yml <<EOF
tunnel: ${TUNNEL_NAME}
credentials-file: ${CRED_FILE}

ingress:
  - hostname: ${HARBOR_HOST}
    service: http://localhost:80
  - service: http_status:404
EOF

echo "▶ Cài cloudflared như service systemd..."
cloudflared service install

systemctl enable cloudflared
systemctl restart cloudflared

echo "✅ Cloudflare Tunnel đã chạy. Kiểm tra:"
systemctl status cloudflared --no-pager || true

### ============================
###  STEP 4: (TÙY CHỌN) ĐÓNG PORT 80/443 TỪ BÊN NGOÀI
### ============================

echo
read -rp "Bạn có muốn bật UFW firewall và chặn truy cập trực tiếp 80/443 từ ngoài không? [y/N]: " UFW_CONFIRM
UFW_CONFIRM=${UFW_CONFIRM:-n}

if [[ "$UFW_CONFIRM" =~ ^[Yy]$ ]]; then
  echo "▶ Cấu hình UFW..."
  apt install -y ufw
  ufw allow OpenSSH
  ufw deny 80/tcp
  ufw deny 443/tcp
  ufw --force enable
  ufw status verbose
  echo "✅ Đã bật UFW, chỉ cho phép SSH, chặn 80/443 từ internet."
else
  echo "⚠ Bỏ qua cấu hình UFW. Port 80/443 vẫn có thể truy cập trực tiếp bằng IP server."
fi

echo
echo "🎉 HOÀN TẤT!"
echo "   - Harbor UI:       https://${HARBOR_HOST}"
echo "   - User mặc định:   admin"
echo "   - Mật khẩu admin:  (theo bạn đã nhập)"
echo
echo "Nếu UI chưa vào được, hãy chờ 1–2 phút cho Tunnel & DNS cập nhật."
