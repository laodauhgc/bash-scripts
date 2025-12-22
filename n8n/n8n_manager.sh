#!/usr/bin/env bash
# n8n manager + Cloudflare Tunnel
# - Cài / cập nhật n8n + PostgreSQL 16 + Cloudflare Tunnel
# - Kiểm tra trạng thái
# - Gỡ n8n (container, service tunnel) + tuỳ chọn xoá data (volume + ~/.n8n)

set -o pipefail

ensure_root() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "Script cần chạy với quyền root. Hãy dùng sudo."
    exit 1
  fi
}

pause() {
  read -rp "Nhấn Enter để tiếp tục..."
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local answer
  read -rp "$prompt [y/N]: " answer
  answer="${answer:-$default}"
  if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
    return 0
  fi
  return 1
}

install_deps() {
  echo "▶ Cập nhật hệ thống & cài gói phụ thuộc..."
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y curl ca-certificates gnupg lsb-release wget jq >/dev/null 2>&1 || true
}

ensure_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then
    return
  fi
  echo "▶ Cài đặt cloudflared..."
  local tmpdeb="/tmp/cloudflared.deb"
  curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o "$tmpdeb"
  dpkg -i "$tmpdeb" >/dev/null 2>&1 || apt-get install -f -y >/dev/null 2>&1
  rm -f "$tmpdeb"
}

write_docker_compose() {
  local install_dir="$1"
  local n8n_host="$2"
  local db_name="$3"
  local db_user="$4"
  local db_pass="$5"
  local timezone="$6"
  local data_dir="$7"

  mkdir -p "$install_dir"
  mkdir -p "$data_dir"

  cat > "${install_dir}/docker-compose.yml" <<EOF
services:
  postgres:
    image: postgres:16
    container_name: n8n-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${db_name}
      POSTGRES_USER: ${db_user}
      POSTGRES_PASSWORD: ${db_pass}
    volumes:
      - n8n_postgres_data:/var/lib/postgresql/data
    networks:
      - n8n_net

  n8n:
    image: docker.n8n.io/n8nio/n8n
    container_name: n8n
    restart: unless-stopped
    depends_on:
      - postgres
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_DATABASE=${db_name}
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_USER=${db_user}
      - DB_POSTGRESDB_PASSWORD=${db_pass}
      - NODE_ENV=production
      - N8N_HOST=${n8n_host}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=https://${n8n_host}/
      - N8N_EDITOR_BASE_URL=https://${n8n_host}/
      - GENERIC_TIMEZONE=${timezone}
    ports:
      - "127.0.0.1:5678:5678"
    volumes:
      - ${data_dir}:/home/node/.n8n
    networks:
      - n8n_net

networks:
  n8n_net:

volumes:
  n8n_postgres_data:
EOF
}

deploy_stack() {
  local install_dir="$1"
  echo "▶ Triển khai stack n8n + PostgreSQL (dùng Postgres 16, data mount ~/.n8n)..."
  (cd "$install_dir" && docker compose up -d)
  echo "✅ n8n đã khởi động (local): http://127.0.0.1:5678"
  echo "   (Đợi vài giây cho container n8n & postgres ổn định...)"
  sleep 5
}

ensure_tunnel() {
  local tunnel_name="$1"
  local hostname="$2"
  local config_file="$3"

  ensure_cloudflared

  mkdir -p /etc/cloudflared
  mkdir -p /root/.cloudflared

  echo "▶ Đảm bảo tunnel '${tunnel_name}' tồn tại..."

  local tunnel_id
  tunnel_id="$(cloudflared tunnel list --output json 2>/dev/null | jq -r '.[] | select(.name=="'"${tunnel_name}"'") | .id' | head -n1)"

  if [[ -z "$tunnel_id" || "$tunnel_id" == "null" ]]; then
    echo "▶ Tạo tunnel mới '${tunnel_name}'..."
    cloudflared tunnel create "${tunnel_name}"
    tunnel_id="$(cloudflared tunnel list --output json 2>/dev/null | jq -r '.[] | select(.name=="'"${tunnel_name}"'") | .id' | head -n1)"
  else
    echo "ℹ️ Tunnel '${tunnel_name}' đã tồn tại, dùng lại."
  fi

  if [[ -z "$tunnel_id" || "$tunnel_id" == "null" ]]; then
    echo "❌ Không lấy được Tunnel ID cho '${tunnel_name}'. Hãy kiểm tra cloudflared."
    return 1
  fi

  local cred_file="/root/.cloudflared/${tunnel_id}.json"
  if [[ ! -f "$cred_file" ]]; then
    cred_file="$(ls /root/.cloudflared/${tunnel_id}*.json 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z "$cred_file" || ! -f "$cred_file" ]]; then
    echo "❌ Không tìm thấy credentials file cho tunnel ID ${tunnel_id} trong /root/.cloudflared."
    return 1
  fi

  echo "   → Tunnel ID:   ${tunnel_id}"
  echo "   → Credentials: ${cred_file}"

  echo "▶ Tạo / cập nhật DNS record cho ${hostname}..."
  if cloudflared tunnel route dns "${tunnel_name}" "${hostname}"; then
    echo "   → Đã tạo/cập nhật CNAME cho ${hostname}."
  else
    echo "⚠ Không tạo được DNS cho ${hostname} (có thể record đã tồn tại). Hãy kiểm tra lại trong Cloudflare."
  fi

  echo "▶ Ghi file config tunnel: ${config_file}"
  cat > "${config_file}" <<EOF
tunnel: ${tunnel_id}
credentials-file: ${cred_file}

ingress:
  - hostname: ${hostname}
    service: http://127.0.0.1:5678
  - service: http_status:404
EOF

  echo "▶ Ghi systemd service: /etc/systemd/system/cloudflared-n8n.service"
  cat > /etc/systemd/system/cloudflared-n8n.service <<EOF
[Unit]
Description=Cloudflare Tunnel - ${tunnel_name} (n8n)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared --no-autoupdate --config ${config_file} tunnel run
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now cloudflared-n8n.service

  echo "✅ Cloudflare Tunnel đã chạy. Kiểm tra nhanh:"
  systemctl --no-pager --lines=5 status cloudflared-n8n.service || true
}

install_n8n() {
  local default_host="n8n.rawcode.io"
  local default_tunnel="n8n-tunnel"
  local default_install_dir="/opt/n8n"
  local default_tz="Asia/Ho_Chi_Minh"
  local default_db_name="n8n"
  local default_db_user="n8n"
  local default_data_dir="/root/.n8n"

  echo
  echo "=== CÀI ĐẶT / CẬP NHẬT n8n + PostgreSQL + Cloudflare Tunnel ==="

  read -rp "Hostname cho n8n [${default_host}]: " n8n_host
  n8n_host="${n8n_host:-$default_host}"

  read -rp "Tên tunnel [${default_tunnel}]: " tunnel_name
  tunnel_name="${tunnel_name:-$default_tunnel}"

  read -rp "Thư mục cài n8n [${default_install_dir}]: " install_dir
  install_dir="${install_dir:-$default_install_dir}"

  read -rp "Timezone [${default_tz}]: " timezone
  timezone="${timezone:-$default_tz}"

  read -rp "Tên database PostgreSQL [${default_db_name}]: " db_name
  db_name="${db_name:-$default_db_name}"

  read -rp "User database PostgreSQL [${default_db_user}]: " db_user
  db_user="${db_user:-$default_db_user}"

  echo "ℹ️ Lưu ý: khi nhập mật khẩu DB, terminal sẽ KHÔNG hiện ký tự."
  local db_pass db_pass2
  while true; do
    read -srp "Mật khẩu database PostgreSQL: " db_pass
    echo
    read -srp "Nhập lại mật khẩu database PostgreSQL: " db_pass2
    echo
    if [[ -z "$db_pass" ]]; then
      echo "❌ Mật khẩu không được để trống."
      continue
    fi
    if [[ "$db_pass" != "$db_pass2" ]]; then
      echo "❌ Mật khẩu nhập lại không khớp, hãy thử lại."
      continue
    fi
    break
  done

  read -rp "Image n8n [docker.n8n.io/n8nio/n8n]: " n8n_image
  n8n_image="${n8n_image:-docker.n8n.io/n8nio/n8n}"

  local data_dir="$default_data_dir"

  echo
  echo "📌 Tóm tắt:"
  echo "   - Hostname:       ${n8n_host}"
  echo "   - Tunnel name:    ${tunnel_name}"
  echo "   - Install dir:    ${install_dir}"
  echo "   - Timezone:       ${timezone}"
  echo "   - DB:             ${db_name}"
  echo "   - DB user:        ${db_user}"
  echo "   - n8n image:      ${n8n_image}"
  echo "   - Service name:   cloudflared-n8n.service"
  echo "   - Data dir:       ${data_dir} (mount vào /home/node/.n8n)"
  echo "   * Nếu đã cài trước đó với Postgres 15, muốn chuyển sang 16 thì NÊN xoá volume 'n8n_postgres_data' trước."
  echo

  if ! ask_yes_no "Tiếp tục cài đặt?"; then
    echo "Huỷ cài đặt."
    return
  fi

  install_deps

  write_docker_compose "$install_dir" "$n8n_host" "$db_name" "$db_user" "$db_pass" "$timezone" "$data_dir"

  if [[ "$n8n_image" != "docker.n8n.io/n8nio/n8n" ]]; then
    sed -i "s|image: docker.n8n.io/n8nio/n8n|image: ${n8n_image//\//\\/}|" "${install_dir}/docker-compose.yml"
  fi

  deploy_stack "$install_dir"

  ensure_tunnel "$tunnel_name" "$n8n_host" "/etc/cloudflared/n8n-tunnel.yml"

  echo
  echo "🎉 HOÀN TẤT CÀI n8n + TUNNEL!"
  echo "   - n8n qua Cloudflare:  https://${n8n_host}"
  echo "   - Local:               http://127.0.0.1:5678"
  echo
  echo "Lần đầu vào UI n8n, bạn sẽ tạo user owner."
}

status_n8n() {
  echo
  echo "=== TRẠNG THÁI n8n + TUNNEL ==="
  echo
  echo "▶ Docker containers (liên quan n8n):"
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | awk 'NR==1 || $1 ~ /^n8n/'

  echo
  echo "▶ Systemd service: cloudflared-n8n.service"
  systemctl --no-pager --lines=5 status cloudflared-n8n.service 2>/dev/null || echo "Không có (hoặc service đang failed) cloudflared-n8n.service"

  echo
  echo "▶ Danh sách tunnel có chữ 'n8n':"
  cloudflared tunnel list 2>/dev/null | (grep -E 'NAME|n8n' || echo "Không tìm thấy tunnel liên quan n8n (theo tên).")

  echo
  echo "▶ Thử curl từ local tới n8n:"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5678 || echo "000")
  echo "HTTP code: ${code}"
}

uninstall_n8n() {
  local install_dir="/opt/n8n"
  local data_dir="/root/.n8n"
  local volume_name="n8n_postgres_data"
  local tunnel_cfg="/etc/cloudflared/n8n-tunnel.yml"

  echo
  echo "=== GỠ n8n + Cloudflare Tunnel (local) ==="
  if ! ask_yes_no "Bạn chắc chắn muốn gỡ n8n (container + service tunnel local)?"; then
    echo "Huỷ thao tác gỡ."
    return
  fi

  echo "▶ Dừng & xoá container n8n / n8n-postgres (nếu có)..."
  docker rm -f n8n n8n-postgres >/dev/null 2>&1 || true

  echo "▶ Dừng & xoá systemd service cloudflared-n8n..."
  systemctl stop cloudflared-n8n.service >/dev/null 2>&1 || true
  systemctl disable cloudflared-n8n.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/cloudflared-n8n.service
  systemctl daemon-reload >/dev/null 2>&1 || true

  if docker volume inspect "${volume_name}" >/dev/null 2>&1; then
    echo
    if ask_yes_no "Bạn có muốn XOÁ Docker volume '${volume_name}' (mất toàn bộ dữ liệu DB n8n)?"; then
      docker volume rm "${volume_name}" && echo "   → Đã xoá volume ${volume_name}."
    else
      echo "↪ Giữ lại volume ${volume_name}."
    fi
  fi

  if [[ -d "$data_dir" ]]; then
    echo
    if ask_yes_no "Bạn có muốn XOÁ thư mục data '${data_dir}' (mất toàn bộ workflows, credentials, settings)?"; then
      rm -rf "$data_dir"
      echo "   → Đã xoá thư mục ${data_dir}."
    else
      echo "↪ Giữ lại thư mục ${data_dir}."
    fi
  fi

  if [[ -d "$install_dir" ]]; then
    echo
    if ask_yes_no "Bạn có muốn XOÁ thư mục cài đặt '${install_dir}' (docker-compose.yml, env...)?"; then
      rm -rf "$install_dir"
      echo "   → Đã xoá thư mục ${install_dir}."
    else
      echo "↪ Giữ lại thư mục cài đặt ${install_dir}."
    fi
  fi

  if [[ -f "$tunnel_cfg" ]]; then
    echo
    echo "▶ Thông tin tunnel từ file cấu hình ${tunnel_cfg}:"
    local tunnel_id tunnel_name
    tunnel_id="$(awk '/^tunnel:/{print $2}' "$tunnel_cfg" | head -n1)"

    if command -v cloudflared >/dev/null 2>&1; then
      tunnel_name="$(cloudflared tunnel list --output json 2>/dev/null | jq -r '.[] | select(.id=="'"${tunnel_id}"'") | .name' | head -n1)"
    fi
    if [[ -z "$tunnel_name" || "$tunnel_name" == "null" ]]; then
      tunnel_name="(không xác định, dùng ID: ${tunnel_id})"
    fi

    echo "   - Tunnel ID:   ${tunnel_id}"
    echo "   - Tunnel name: ${tunnel_name}"

    if command -v cloudflared >/dev/null 2>&1; then
      echo
      if ask_yes_no "Bạn có muốn XOÁ Cloudflare Tunnel '${tunnel_name}' khỏi account Cloudflare (cloudflared tunnel delete)?"; then
        cloudflared tunnel delete "${tunnel_name}" || echo "⚠ Lỗi khi xoá tunnel, hãy kiểm tra lại thủ công."
      else
        echo "↪ Giữ nguyên tunnel trên Cloudflare."
      fi
    else
      echo "⚠ Không tìm thấy lệnh cloudflared, không thể xoá tunnel tự động."
    fi

    echo
    if ask_yes_no "Bạn có muốn XOÁ file cấu hình local '${tunnel_cfg}'?"; then
      rm -f "$tunnel_cfg"
      echo "   → Đã xoá file cấu hình tunnel local."
    else
      echo "↪ Giữ lại file cấu hình tunnel local."
    fi
  fi

  echo
  echo "⚠ Về Cloudflare DNS:"
  echo "   - Script KHÔNG tự xoá CNAME DNS trên Cloudflare."
  echo "   - Sau khi xoá tunnel (nếu có), hãy vào Cloudflare Dashboard để xoá record CNAME tương ứng (ví dụ: n8n.rawcode.io) nếu không dùng nữa."
  echo
  echo "✅ Đã gỡ n8n (container) + service cloudflared-n8n trên máy chủ (tuỳ chọn xoá data như bạn đã chọn)."
}

main_menu() {
  while true; do
    echo "=============================="
    echo " n8n MANAGER + CLOUDFLARE TUNNEL"
    echo "=============================="
    echo "1) Cài / cập nhật n8n + tunnel"
    echo "2) Kiểm tra trạng thái n8n + tunnel"
    echo "3) Gỡ n8n + service + (tuỳ chọn) xoá data"
    echo "0) Thoát"
    echo "=============================="
    read -rp "Chọn chức năng (0-3): " choice
    case "$choice" in
      1) install_n8n ;;
      2) status_n8n ;;
      3) uninstall_n8n ;;
      0) echo "Bye!"; exit 0 ;;
      *) echo "Lựa chọn không hợp lệ."; pause ;;
    esac
    echo
  done
}

ensure_root
main_menu
