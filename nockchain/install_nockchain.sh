#!/bin/bash

# ========= Màu sắc =========
RESET='\033[0m'
BOLD='\033[1m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'

# ========= Đường dẫn =========
NCK_DIR="$HOME/nockchain"
BACKUP_DIR="$HOME/nockchain_backup"
REPO_URL="https://github.com/zorp-corp/nockchain.git"
ENV_FILE="$NCK_DIR/.env"

# ========= Kiểm tra lệnh =========
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# ========= Ghi log =========
log() {
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# ========= Tiêu đề =========
show_header() {
  clear
  echo -e "${BOLD}${BLUE}Nockchain Installation Script${RESET}"
  echo -e "${BLUE}GitHub: github.com/laodauhgc${RESET}"
  echo -e "${BLUE}-----------------------------------------------${RESET}"
  echo ""
}

# ========= Cài phụ thuộc =========
install_dependencies() {
  show_header
  log "${BLUE}Cài đặt phụ thuộc...${RESET}"
  sudo apt-get update && sudo apt-get upgrade -y
  sudo apt install -y curl git make clang llvm-dev libclang-dev
  if [ $? -eq 0 ]; then
    log "${GREEN}Phụ thuộc đã được cài đặt.${RESET}"
  else
    log "${RED}Lỗi: Không thể cài phụ thuộc. Kiểm tra mạng hoặc quyền!${RESET}"
    [ "$MENU_MODE" = true ] && pause_and_return || exit 1
  fi
  [ "$MENU_MODE" = true ] && pause_and_return
}

# ========= Cài Rust =========
install_rust() {
  show_header
  if command_exists rustc; then
    log "${YELLOW}Rust đã được cài đặt, bỏ qua.${RESET}"
    [ "$MENU_MODE" = true ] && pause_and_return
    return
  fi
  log "${BLUE}Cài đặt Rust...${RESET}"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  if [ $? -eq 0 ]; then
    . "$HOME/.cargo/env"
    export PATH="$HOME/.cargo/bin:$PATH"
    rustup default stable
    if command_exists rustc; then
      log "${GREEN}Rust đã được cài đặt.${RESET}"
    else
      log "${RED}Lỗi: Rust không được cài đúng. Kiểm tra môi trường!${RESET}"
      [ "$MENU_MODE" = true ] && pause_and_return || exit 1
    fi
  else
    log "${RED}Lỗi: Không thể cài Rust. Kiểm tra mạng!${RESET}"
    [ "$MENU_MODE" = true ] && pause_and_return || exit 1
  fi
  [ "$MENU_MODE" = true ] && pause_and_return
}

# ========= Thiết lập kho =========
setup_repository() {
  show_header
  log "${BLUE}Thiết lập kho Nockchain...${RESET}"
  if ! git ls-remote --heads "$REPO_URL" "master" | grep -q "master"; then
    log "${RED}Lỗi: Nhánh master không tồn tại trong $REPO_URL.${RESET}"
    [ "$MENU_MODE" = true ] && pause_and_return || exit 1
    return
  fi
  if [ -d "$NCK_DIR" ]; then
    log "${YELLOW}Thư mục $NCK_DIR đã tồn tại. Có muốn xóa và clone lại? (y/n)${RESET}"
    if [ "$MENU_MODE" = true ]; then
      read -r confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -rf "$NCK_DIR" "$HOME/.nockapp"
        git clone --branch master "$REPO_URL" "$NCK_DIR"
      else
        cd "$NCK_DIR" && git fetch origin && git checkout master && git pull origin master
      fi
    else
      rm -rf "$NCK_DIR" "$HOME/.nockapp"
      git clone --branch master "$REPO_URL" "$NCK_DIR"
    fi
  else
    git clone --branch master "$REPO_URL" "$NCK_DIR"
  fi
  if [ $? -ne 0 ]; then
    log "${RED}Lỗi: Không thể clone hoặc cập nhật kho.${RESET}"
    [ "$MENU_MODE" = true ] && pause_and_return || exit 1
    return
  fi
  cd "$NCK_DIR"
  if [ -f ".env" ]; then
    cp .env .env.bak
    log "${GREEN}Đã sao lưu .env thành .env.bak.${RESET}"
  fi
  if [ -f ".env_example" ]; then
    cp .env_example .env
    log "${GREEN}Đã tạo .env từ .env_example.${RESET}"
  else
    log "${RED}Lỗi: Không tìm thấy .env_example.${RESET}"
    [ "$MENU_MODE" = true ] && pause_and_return || exit 1
  fi
  log "${GREEN}Kho đã được thiết lập.${RESET}"
  [ "$MENU_MODE" = true ] && pause_and_return
}

# ========= Biên dịch dự án =========
build_project() {
  show_header
  if [ ! -d "$NCK_DIR" ]; then
    log "${RED}Lỗi: Thư mục $NCK_DIR không tồn tại. Chạy tùy chọn 3 trước!${RESET}"
    [ "$MENU_MODE" = true ] && pause_and_return || exit 1
    return
  fi
  cd "$NCK_DIR"
  log "${BLUE}Kiểm tra binary...${RESET}"
  if [ -f "target/release/nockchain-wallet" ] && [ -f "target/release/nockchain" ]; then
    log "${YELLOW}nockchain-wallet và nockchain đã có. Bỏ qua build để tiết kiệm thời gian.${RESET}"
  else
    log "${BLUE}Biên dịch Nockchain (có thể mất vài phút)...${RESET}"
    make install-hoonc > hoonc.log 2>&1
    if [ $? -ne 0 ]; then
      log "${YELLOW}Cảnh báo: make install-hoonc thất bại. Kiểm tra hoonc.log.${RESET}"
    fi
    make build > build.log 2>&1
    if [ $? -ne 0 ]; then
      log "${RED}Lỗi: make build thất bại. Kiểm tra build.log!${RESET}"
      [ "$MENU_MODE" = true ] && pause_and_return || exit 1
      return
    fi
    make install-nockchain-wallet
    if [ $? -ne 0 ]; then
      log "${RED}Lỗi: Không thể cài nockchain-wallet.${RESET}"
      [ "$MENU_MODE" = true ] && pause_and_return || exit 1
      return
    fi
    make install-nockchain
    if [ $? -ne 0 ]; then
      log "${RED}Lỗi: Không thể cài nockchain.${RESET}"
      [ "$MENU_MODE" = true ] && pause_and_return || exit 1
      return
    fi
    log "${BLUE}Kiểm tra binary sau build...${RESET}"
    ls -l target/release
    if [ ! -f "target/release/nockchain-wallet" ] || [ ! -f "target/release/nockchain" ]; then
      log "${RED}Lỗi: Không tìm thấy binary nockchain-wallet hoặc nockchain.${RESET}"
      [ "$MENU_MODE" = true ] && pause_and_return || exit 1
      return
    fi
    log "${GREEN}Biên dịch hoàn tất.${RESET}"
  fi
  [ "$MENU_MODE" = true ] && pause_and_return
}

# ========= Tạo ví =========
generate_wallet() {
  show_header
  if [ ! -d "$NCK_DIR" ] || [ ! -f "$NCK_DIR/target/release/nockchain-wallet" ]; then
    log "${RED}Lỗi: Thư mục $NCK_DIR hoặc nockchain-wallet không tồn tại. Chạy tùy chọn 3 và 4 trước!${RESET}"
    [ "$MENU_MODE" = true ] && pause_and_return || exit 1
    return
  fi
  cd "$NCK_DIR"
  log "${BLUE}Kiểm tra ví...${RESET}"
  if [ -f "wallet_output.txt" ]; then
    log "${YELLOW}Ví đã tồn tại tại wallet_output.txt. Bỏ qua để giữ ví cũ.${RESET}"
    log "${BLUE}Chi tiết ví:${RESET}"
    cat wallet_output.txt
    log "${YELLOW}Đảm bảo MINING_PUBKEY khớp với khóa công khai trong ví!${RESET}"
  else
    log "${BLUE}Tạo ví mới...${RESET}"
    export PATH="$PATH:$NCK_DIR/target/release"
    if ! command_exists nockchain-wallet; then
      log "${RED}Lỗi: Không tìm thấy lệnh nockchain-wallet. Kiểm tra build!${RESET}"
      [ "$MENU_MODE" = true ] && pause_and_return || exit 1
      return
    fi
    nockchain-wallet keygen > wallet_output.txt 2>&1
    if [ $? -ne 0 ]; then
      log "${RED}Lỗi: Không thể tạo ví. Kiểm tra wallet_output.txt!${RESET}"
      [ "$MENU_MODE" = true ] && pause_and_return || exit 1
      return
    fi
    log "${GREEN}Ví mới đã được tạo. Chi tiết lưu tại wallet_output.txt:${RESET}"
    cat wallet_output.txt
  fi
  log "${GREEN}Sao lưu ví...${RESET}"
  mkdir -p "$BACKUP_DIR"
  nockchain-wallet export-keys > keys.export 2>&1
  if [ $? -eq 0 ]; then
    cp wallet_output.txt keys.export "$BACKUP_DIR/"
    chmod 600 "$BACKUP_DIR/wallet_output.txt" "$BACKUP_DIR/keys.export"
    log "${GREEN}Đã sao lưu ví vào $BACKUP_DIR/wallet_output.txt và $BACKUP_DIR/keys.export.${RESET}"
  else
    log "${YELLOW}Cảnh báo: Không thể xuất khóa. Kiểm tra keys.export!${RESET}"
  fi
  log "${YELLOW}Quan trọng: Lưu $BACKUP_DIR/* an toàn, vì chứa khóa riêng!${RESET}"
  [ "$MENU_MODE" = true ] && pause_and_return
}

# ========= Cấu hình khóa khai thác =========
configure_mining_key() {
  show_header
  if [ ! -d "$NCK_DIR" ] || [ ! -f "$ENV_FILE" ]; then
    log "${RED}Lỗi: Thư mục $NCK_DIR hoặc .env không tồn tại. Chạy tùy chọn 3 trước!${RESET}"
    [ "$MENU_MODE" = true ] && pause_and_return || exit 1
    return
  fi
  cd "$NCK_DIR"
  log "${BLUE}Cấu hình khóa khai thác...${RESET}"
  if [ -f "wallet_output.txt" ]; then
    PUBLIC_KEY=$(grep -i "public key" wallet_output.txt | awk '{print $NF}' | tail -1)
    if [ -n "$PUBLIC_KEY" ]; then
      log "${YELLOW}Khóa công khai từ ví: $PUBLIC_KEY${RESET}"
      log "${YELLOW}Có muốn dùng khóa này cho MINING_PUBKEY? (y/n)${RESET}"
      if [ "$MENU_MODE" = true ]; then
        read -r use_wallet_key
        if [[ "$use_wallet_key" =~ ^[Yy]$ ]]; then
          MINING_PUBKEY="$PUBLIC_KEY"
        else
          log "${YELLOW}Nhập MINING_PUBKEY:${RESET}"
          read -r MINING_PUBKEY
        fi
      else
        MINING_PUBKEY="$PUBLIC_KEY"
      fi
    else
      log "${YELLOW}Không tìm thấy khóa công khai trong ví. Nhập MINING_PUBKEY:${RESET}"
      if [ "$MENU_MODE" = true ]; then
        read -r MINING_PUBKEY
      else
        log "${RED}Lỗi: Không có MINING_PUBKEY tự động trong chế độ không tương tác!${RESET}"
        exit 1
      fi
    fi
  else
    log "${YELLOW}Nhập MINING_PUBKEY:${RESET}"
    if [ "$MENU_MODE" = true ]; then
      read -r MINING_PUBKEY
    else
      log "${RED}Lỗi: Không có ví hoặc MINING_PUBKEY trong chế độ không tương tác!${RESET}"
      exit 1
    fi
  fi
  if [ -z "$MINING_PUBKEY" ]; then
    log "${RED}Lỗi: Không nhập MINING_PUBKEY!${RESET}"
    [ "$MENU_MODE" = true ] && pause_and_return || exit 1
    return
  fi
  if grep -q "^MINING_PUBKEY=" "$ENV_FILE"; then
    sed -i "s|^MINING_PUBKEY=.*|MINING_PUBKEY=$MINING_PUBKEY|" "$ENV_FILE"
  else
    echo "MINING_PUBKEY=$MINING_PUBKEY" >> "$ENV_FILE"
  fi
  if [ $? -eq 0 ] && grep -q "^MINING_PUBKEY=$MINING_PUBKEY$" "$ENV_FILE"; then
    log "${GREEN}Đã cấu hình MINING_PUBKEY: $MINING_PUBKEY${RESET}"
  else
    log "${RED}Lỗi: Không thể cập nhật .env!${RESET}"
    [ "$MENU_MODE" = true ] && pause_and_return || exit 1
  fi
  [ "$MENU_MODE" = true ] && pause_and_return
}

# ========= Chạy node miner =========
start_miner_node() {
  show_header
  if [ ! -d "$NCK_DIR" ] || [ ! -f "$NCK_DIR/target/release/nockchain" ]; then
    log "${RED}Lỗi: Thư mục $NCK_DIR hoặc nockchain không tồn tại. Chạy tùy chọn 3 và 4 trước!${RESET}"
    [ "$MENU_MODE" = true ] && pause_and_return || exit 1
    return
  fi
  cd "$NCK_DIR"
  if [ ! -f ".env" ] || ! grep -q "^MINING_PUBKEY=" .env; then
    log "${RED}Lỗi: Thiếu .env hoặc MINING_PUBKEY. Chạy tùy chọn 6 trước!${RESET}"
    [ "$MENU_MODE" = true ] && pause_and_return || exit 1
    return
  fi
  log "${BLUE}Kiểm tra .data.nockchain...${RESET}"
  if [ -f ".data.nockchain" ]; then
    log "${YELLOW}.data.nockchain tồn tại. Sao lưu và xóa để chạy mainnet...${RESET}"
    mv .data.nockchain "$BACKUP_DIR/data.nockchain.bak-$(date +%F-%H%M%S)"
  fi
  log "${BLUE}Kiểm tra cổng 3005, 3006...${RESET}"
  PORTS=(3005 3006)
  for PORT in "${PORTS[@]}"; do
    if lsof -i :$PORT >/dev/null 2>&1; then
      log "${YELLOW}Cổng $PORT đang bị chiếm. Có muốn giết tiến trình? (y/n)${RESET}"
      if [ "$MENU_MODE" = true ]; then
        read -r confirm_kill
        if [[ "$confirm_kill" =~ ^[Yy]$ ]]; then
          sudo fuser -k $PORT/tcp
          sudo fuser -k $PORT/udp
        else
          log "${RED}Lỗi: Cổng $PORT bị chiếm, không thể chạy node!${RESET}"
          [ "$MENU_MODE" = true ] && pause_and_return || exit 1
          return
        fi
      else
        sudo fuser -k $PORT/tcp
        sudo fuser -k $PORT/udp
      fi
    fi
  done
  log "${BLUE}Mở cổng 3005, 3006 (TCP/UDP)...${RESET}"
  sudo ufw allow 22/tcp && sudo ufw allow 3005:3006/tcp && sudo ufw allow 3005:3006/udp && sudo ufw --force enable
  if [ $? -ne 0 ]; then
    log "${YELLOW}Cảnh báo: Không thể mở cổng. Kiểm tra firewall!${RESET}"
  fi
  log "${BLUE}Tạo dịch vụ Systemd cho node miner...${RESET}"
  cat << EOF | sudo tee /etc/systemd/system/nockchaind.service
[Unit]
Description=Nockchain Miner Service
After=network.target

[Service]
User=root
WorkingDirectory=$NCK_DIR
ExecStart=/usr/bin/make run-nockchain
Restart=always
RestartSec=10
Environment="PATH=/root/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$NCK_DIR/target/release"
SyslogIdentifier=nockchaind
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  sudo chmod 644 /etc/systemd/system/nockchaind.service
  sudo systemctl daemon-reload
  sudo systemctl enable nockchaind
  sudo systemctl start nockchaind
  if [ $? -eq 0 ]; then
    log "${GREEN}Node miner đã khởi động qua Systemd.${RESET}"
    sudo systemctl status nockchaind --no-pager
  else
    log "${RED}Lỗi: Không thể khởi động node!${RESET}"
    [ "$MENU_MODE" = true ] && pause_and_return || exit 1
  fi
  log "${YELLOW}Xem log: journalctl -u nockchaind -f${RESET}"
  [ "$MENU_MODE" = true ] && pause_and_return
}

# ========= Sao lưu khóa =========
backup_keys() {
  show_header
  if [ ! -d "$NCK_DIR" ] || [ ! -f "$NCK_DIR/target/release/nockchain-wallet" ]; then
    log "${RED}Lỗi: Thư mục $NCK_DIR hoặc nockchain-wallet không tồn tại. Chạy tùy chọn 3 và 4 trước!${RESET}"
    pause_and_return
    return
  fi
  cd "$NCK_DIR"
  log "${BLUE}Sao lưu khóa ví...${RESET}"
  mkdir -p "$BACKUP_DIR"
  export PATH="$PATH:$NCK_DIR/target/release"
  nockchain-wallet export-keys > keys.export 2>&1
  if [ $? -eq 0 ]; then
    cp wallet_output.txt keys.export "$BACKUP_DIR/"
    chmod 600 "$BACKUP_DIR/wallet_output.txt" "$BACKUP_DIR/keys.export"
    log "${GREEN}Đã sao lưu vào $BACKUP_DIR/wallet_output.txt và $BACKUP_DIR/keys.export.${RESET}"
  else
    log "${RED}Lỗi: Không thể xuất khóa. Kiểm tra keys.export!${RESET}"
  fi
  log "${YELLOW}Quan trọng: Lưu $BACKUP_DIR/* an toàn!${RESET}"
  pause_and_return
}

# ========= Xem log =========
view_logs() {
  show_header
  log "${BLUE}Xem log node miner:${RESET}"
  journalctl -u nockchaind -f
  pause_and_return
}

# ========= Gỡ cài đặt =========
uninstall_nockchain() {
  show_header
  log "${BLUE}Gỡ cài đặt Nockchain...${RESET}"
  sudo systemctl stop nockchaind 2>/dev/null
  sudo systemctl disable nockchaind 2>/dev/null
  sudo rm /etc/systemd/system/nockchaind.service 2>/dev/null
  sudo systemctl daemon-reload 2>/dev/null
  sudo systemctl reset-failed 2>/dev/null
  rm -rf "$NCK_DIR" "$HOME/.nockapp"
  log "${GREEN}Đã gỡ cài đặt Nockchain. Sao lưu ví vẫn ở $BACKUP_DIR.${RESET}"
  pause_and_return
}

# ========= Chờ nhấn phím =========
pause_and_return() {
  echo ""
  read -n1 -r -p "${YELLOW}Nhấn phím bất kỳ để quay lại menu...${RESET}" key
  main_menu
}

# ========= Menu chính =========
main_menu() {
  show_header
  echo -e "${BOLD}${BLUE}Chọn thao tác:${RESET}"
  echo "  1) Cài đặt phụ thuộc"
  echo "  2) Cài đặt Rust"
  echo "  3) Thiết lập kho Nockchain"
  echo "  4) Biên dịch dự án"
  echo "  5) Tạo hoặc kiểm tra ví"
  echo "  6) Cấu hình khóa khai thác"
  echo "  7) Chạy node miner"
  echo "  8) Sao lưu khóa ví"
  echo "  9) Xem log node"
  echo "  10) Gỡ cài đặt Nockchain"
  echo "  0) Thoát"
  echo ""
  read -p "Nhập số: " choice
  case "$choice" in
    1) install_dependencies ;;
    2) install_rust ;;
    3) setup_repository ;;
    4) build_project ;;
    5) generate_wallet ;;
    6) configure_mining_key ;;
    7) start_miner_node ;;
    8) backup_keys ;;
    9) view_logs ;;
    10) uninstall_nockchain ;;
    0) log "${GREEN}Đã thoát.${RESET}"; exit 0 ;;
    *) log "${RED}Lựa chọn không hợp lệ!${RESET}"; pause_and_return ;;
  esac
}

# ========= Chạy tự động tất cả bước =========
auto_install() {
  show_header
  log "${BLUE}Bắt đầu cài đặt tự động Nockchain...${RESET}"
  install_dependencies
  install_rust
  setup_repository
  build_project
  generate_wallet
  configure_mining_key
  start_miner_node
  log "${GREEN}Cài đặt tự động hoàn tất!${RESET}"
}

# ========= Xử lý tham số dòng lệnh =========
MENU_MODE=false
while getopts "m" opt; do
  case $opt in
    m) MENU_MODE=true ;;
    *) echo "Usage: $0 [-m]"; exit 1 ;;
  esac
done

# ========= Khởi động =========
if [ "$MENU_MODE" = true ]; then
  main_menu
else
  auto_install
fi