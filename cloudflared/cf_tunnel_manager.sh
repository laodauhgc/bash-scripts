#!/usr/bin/env bash
set -euo pipefail

# ==========================
# Cloudflare Tunnel Manager
# ==========================
# Menu:
#   1) Tạo / cập nhật tunnel cho 1 app
#   2) Liệt kê tunnel (cloudflared tunnel list)
#   3) Liệt kê service cloudflared-*.service
#   4) Xem config 1 tunnel
#   5) Xoá service + config (và optionally xoá tunnel trên Cloudflare)
#   0) Thoát
#
# Mỗi app nên theo convention:
#   - Tunnel name:   <app>-tunnel  (vd: portainer-tunnel)
#   - Config file:   /etc/cloudflared/<tunnel-name>.yml
#   - Service name:  cloudflared-<app>.service
#
# ==========================

require_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "❌ Vui lòng chạy script với quyền root (sudo)."
    exit 1
  fi
}

ensure_cloudflared() {
  if ! command -v cloudflared &>/dev/null; then
    echo "⚠ Không tìm thấy cloudflared, tiến hành cài đặt..."
    apt update -y
    cd /tmp
    curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb
    dpkg -i cloudflared.deb || apt -f install -y
  fi
}

ensure_cert() {
  local cert="/root/.cloudflared/cert.pem"
  if [ ! -f "$cert" ]; then
    echo "🔑 Chưa có cert Cloudflare, cần login để cấp quyền cho tunnel."
    echo "   - Lệnh sau sẽ in ra một URL."
    echo "   - Bạn copy URL đó, mở trong trình duyệt, đăng nhập Cloudflare."
    echo "   - Chọn zone chứa domain tương ứng."
    echo "   - Sau khi màn hình báo thành công, quay lại terminal."
    echo
    read -rp "Nhấn Enter để chạy 'cloudflared tunnel login'..." _
    cloudflared tunnel login
  else
    echo "ℹ️ Đã có cert Cloudflare tại ${cert}, bỏ qua bước 'cloudflared tunnel login'."
  fi
}

create_or_update_tunnel() {
  echo "=== TẠO / CẬP NHẬT TUNNEL CHO 1 APP ==="

  read -rp "Tên app (vd: portainer, harbor, grafana...): " APP_NAME
  if [ -z "$APP_NAME" ]; then
    echo "❌ Tên app không được trống."
    return
  fi

  read -rp "Hostname public (vd: portainer.rawcode.io): " HOSTNAME
  if [ -z "$HOSTNAME" ]; then
    echo "❌ Hostname không được trống."
    return
  fi

  local DEFAULT_TUNNEL_NAME="${APP_NAME}-tunnel"
  read -rp "Tên tunnel [${DEFAULT_TUNNEL_NAME}]: " TUNNEL_NAME
  TUNNEL_NAME=${TUNNEL_NAME:-$DEFAULT_TUNNEL_NAME}

  read -rp "Local service URL (vd: https://localhost:9443 hoặc http://localhost:3000): " SERVICE_URL
  if [ -z "$SERVICE_URL" ]; then
    echo "❌ Service URL không được trống."
    return
  fi

  echo
  echo "📌 Thông tin:"
  echo "   - App:          ${APP_NAME}"
  echo "   - Hostname:     ${HOSTNAME}"
  echo "   - Tunnel name:  ${TUNNEL_NAME}"
  echo "   - Service URL:  ${SERVICE_URL}"
  echo
  read -rp "Xác nhận tạo/cập nhật? [y/N]: " CONFIRM
  CONFIRM=${CONFIRM:-n}
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "⏹ Bỏ qua."
    return
  fi

  ensure_cloudflared
  ensure_cert

  echo
  echo "▶ Tạo hoặc dùng lại tunnel '${TUNNEL_NAME}'..."
  if cloudflared tunnel list 2>/dev/null | grep -w "$TUNNEL_NAME" >/dev/null; then
    echo "ℹ️ Tunnel đã tồn tại, dùng lại."
  else
    cloudflared tunnel create "$TUNNEL_NAME"
  fi

  echo "▶ Lấy Tunnel ID & credentials..."
  local TUNNEL_ID
  TUNNEL_ID=$(cloudflared tunnel list 2>/dev/null | awk -v t="$TUNNEL_NAME" '$0 ~ t {print $1; exit}')
  if [ -z "$TUNNEL_ID" ]; then
    echo "❌ Không lấy được Tunnel ID cho '${TUNNEL_NAME}'."
    return
  fi

  local CLOUDFLARED_DIR="/root/.cloudflared"
  local CRED_FILE="${CLOUDFLARED_DIR}/${TUNNEL_ID}.json"

  if [ ! -f "$CRED_FILE" ]; then
    echo "❌ Không tìm thấy credentials file: $CRED_FILE"
    echo "   Hãy chạy 'ls -l ${CLOUDFLARED_DIR}' để kiểm tra và sửa tay."
    return
  fi

  echo "   → Dùng credentials file: $CRED_FILE"

  echo "▶ Tạo / cập nhật DNS record trên Cloudflare cho ${HOSTNAME}..."
  local DNS_OUTPUT=""
  if ! DNS_OUTPUT=$(cloudflared tunnel route dns --overwrite-dns "$TUNNEL_ID" "$HOSTNAME" 2>&1); then
    echo "$DNS_OUTPUT"
    if echo "$DNS_OUTPUT" | grep -qi "already exists"; then
      echo "⚠️ DNS record cho ${HOSTNAME} đã tồn tại."
      echo "   Hãy đảm bảo trong Cloudflare Dashboard:"
      echo "   - Type: CNAME"
      echo "   - Name: ${HOSTNAME}"
      echo "   - Target: ${TUNNEL_ID}.cfargotunnel.com"
      echo "   Script vẫn tiếp tục vì tunnel & service đã chạy."
    else
      echo "❌ Lỗi tạo DNS record (không phải do record đã tồn tại). Dừng thao tác."
      return
    fi
  else
    echo "$DNS_OUTPUT"
  fi

  echo "▶ Tạo config & service local..."
  mkdir -p /etc/cloudflared
  local CF_CONFIG_FILE="/etc/cloudflared/${TUNNEL_NAME}.yml"
  local SERVICE_NAME="cloudflared-${APP_NAME}.service"
  local CF_SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"

  cat >"$CF_CONFIG_FILE" <<EOF
tunnel: ${TUNNEL_NAME}
credentials-file: ${CRED_FILE}

ingress:
  - hostname: ${HOSTNAME}
    service: ${SERVICE_URL}
  - service: http_status:404
EOF

  echo "   → Đã ghi config: $CF_CONFIG_FILE"

  local CF_BIN
  CF_BIN="$(command -v cloudflared)"

  # Nếu service cũ tồn tại, dừng trước
  if systemctl list-unit-files | grep -q "^${SERVICE_NAME}"; then
    systemctl disable --now "${SERVICE_NAME}" 2>/dev/null || true
  fi

  cat >"$CF_SERVICE_FILE" <<EOF
[Unit]
Description=Cloudflare Tunnel - ${TUNNEL_NAME} (${APP_NAME})
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

  echo "   → Đã ghi service file: $CF_SERVICE_FILE"

  echo "🔄 Reload systemd & bật service ${SERVICE_NAME}..."
  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}"

  echo "✅ Đã tạo/cập nhật tunnel & service cho app '${APP_NAME}'."
  systemctl status "${SERVICE_NAME}" --no-pager || true
  echo
}

list_tunnels() {
  ensure_cloudflared
  echo "=== DANH SÁCH TUNNEL (cloudflared tunnel list) ==="
  cloudflared tunnel list || echo "⚠ Không lấy được danh sách tunnel."
  echo
}

list_services() {
  echo "=== DANH SÁCH SERVICE cloudflared-*.service ==="
  echo
  systemctl list-unit-files | grep "cloudflared-" || echo "Không có service cloudflared-* nào."
  echo
  echo "--- Trạng thái đang chạy ---"
  systemctl list-units --type=service | grep "cloudflared-" || echo "Không có service cloudflared-* đang chạy."
  echo
}

show_config() {
  read -rp "Nhập tên tunnel (vd: harbor-tunnel, portainer-tunnel): " TUNNEL_NAME
  if [ -z "$TUNNEL_NAME" ]; then
    echo "❌ Tên tunnel không được trống."
    return
  fi

  local CF_CONFIG_FILE="/etc/cloudflared/${TUNNEL_NAME}.yml"
  if [ ! -f "$CF_CONFIG_FILE" ]; then
    echo "❌ Không tìm thấy file config: $CF_CONFIG_FILE"
    return
  fi

  echo "=== NỘI DUNG ${CF_CONFIG_FILE} ==="
  cat "$CF_CONFIG_FILE"
  echo
}

delete_local_and_optional_remote() {
  echo "=== XOÁ SERVICE + CONFIG (và tùy chọn xoá tunnel trên Cloudflare) ==="

  read -rp "Tên app (vd: portainer, harbor, grafana...): " APP_NAME
  if [ -z "$APP_NAME" ]; then
    echo "❌ Tên app không được trống."
    return
  fi

  local SERVICE_NAME="cloudflared-${APP_NAME}.service"
  echo "   → Service tương ứng: ${SERVICE_NAME}"

  if systemctl list-unit-files | grep -q "^${SERVICE_NAME}"; then
    echo "▶ Dừng & disable service ${SERVICE_NAME}..."
    systemctl disable --now "${SERVICE_NAME}" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}"
    systemctl daemon-reload
    echo "   ✅ Đã xoá service local."
  else
    echo "ℹ️ Không tìm thấy service ${SERVICE_NAME}."
  fi

  read -rp "Tên tunnel tương ứng (vd: ${APP_NAME}-tunnel): " TUNNEL_NAME
  if [ -z "$TUNNEL_NAME" ]; then
    echo "ℹ️ Bỏ qua xoá config & tunnel vì không có tên tunnel."
    return
  fi

  local CF_CONFIG_FILE="/etc/cloudflared/${TUNNEL_NAME}.yml"
  if [ -f "$CF_CONFIG_FILE" ]; then
    read -rp "Xoá file config local ${CF_CONFIG_FILE}? [y/N]: " DEL_CFG
    DEL_CFG=${DEL_CFG:-n}
    if [[ "$DEL_CFG" =~ ^[Yy]$ ]]; then
      rm -f "$CF_CONFIG_FILE"
      echo "   ✅ Đã xoá file config local."
    else
      echo "   ℹ️ Giữ nguyên file config local."
    fi
  else
    echo "ℹ️ Không tìm thấy file config local: ${CF_CONFIG_FILE}"
  fi

  ensure_cloudflared

  read -rp "Bạn có muốn XOÁ tunnel '${TUNNEL_NAME}' khỏi Cloudflare account không? [y/N]: " DEL_REMOTE
  DEL_REMOTE=${DEL_REMOTE:-n}
  if [[ "$DEL_REMOTE" =~ ^[Yy]$ ]]; then
    echo "⚠ CẢNH BÁO: Hành động này sẽ xoá tunnel trên Cloudflare."
    read -rp "Gõ CHAPNHAN để xác nhận: " CONFIRM_WORD
    if [ "$CONFIRM_WORD" = "CHAPNHAN" ]; then
      cloudflared tunnel delete "$TUNNEL_NAME" || echo "⚠ Không xoá được tunnel (có thể đã bị xoá trước đó)."
      echo "✅ Đã gửi lệnh xoá tunnel '${TUNNEL_NAME}' trên Cloudflare."
    else
      echo "❌ Không khớp CHAPNHAN, huỷ xoá tunnel từ Cloudflare."
    fi
  else
    echo "ℹ️ Không xoá tunnel trên Cloudflare (chỉ xoá local)."
  fi

  echo
}

show_menu() {
  echo "=============================="
  echo " CLOUDFLARE TUNNEL MANAGER"
  echo "=============================="
  echo "1) Tạo / cập nhật tunnel cho 1 app"
  echo "2) Liệt kê tunnel"
  echo "3) Liệt kê service cloudflared-*"
  echo "4) Xem config 1 tunnel"
  echo "5) Xoá service + config (và tùy chọn xoá tunnel)"
  echo "0) Thoát"
  echo "=============================="
}

main() {
  require_root

  while true; do
    show_menu
    read -rp "Chọn chức năng (0-5): " choice
    echo
    case "$choice" in
      1) create_or_update_tunnel ;;
      2) list_tunnels ;;
      3) list_services ;;
      4) show_config ;;
      5) delete_local_and_optional_remote ;;
      0)
        echo "👋 Thoát."
        exit 0
        ;;
      *)
        echo "❌ Lựa chọn không hợp lệ."
        ;;
    esac
  done
}

main "$@"
