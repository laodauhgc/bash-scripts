#!/usr/bin/env bash
set -euo pipefail

########################################
# Titan Guardian Updater for titand
# Script version: 1.2.0
########################################

SCRIPT_VERSION="1.2.0"

########################################
# CẤU HÌNH
########################################
TITAN_REPO_API="https://api.github.com/repos/Titannet-dao/titan-node/releases/latest"
TITAN_BINARY="titan-l1-guardian"
SYSTEM_DIR="/usr/local/bin"

# Tên service mặc định, có thể override bằng env TITAN_SERVICE_NAME hoặc --service
SERVICE_NAME_DEFAULT="titand"
SERVICE_NAME="${TITAN_SERVICE_NAME:-$SERVICE_NAME_DEFAULT}"
########################################

# Màu sắc cho output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

MODE="update"        # mặc định: update
DO_REBOOT=0          # mặc định: không reboot
EXPLICIT_VERSION=""  # nếu truyền --version thì dùng cái này

usage() {
  cat <<EOF
Titan Guardian Updater (script version: ${SCRIPT_VERSION})

Usage: $0 [mode] [options]

Modes:
  check               Chỉ kiểm tra: version mới nhất trên GitHub & version đang cài
  update              Cập nhật lên bản mới nhất (mặc định nếu không ghi gì)

Options:
  --version X         Cập nhật / kiểm tra với version cụ thể (vd: v0.1.23)
  --service NAME      Tên systemd service (mặc định: ${SERVICE_NAME_DEFAULT})
                      Ví dụ: --service titan-node
  --reboot            Sau khi update xong sẽ reboot máy
  -h, --help          Hiển thị trợ giúp

Env:
  TITAN_SERVICE_NAME  Override tên service mặc định (ví dụ: TITAN_SERVICE_NAME=titan-node)

Ví dụ:
  $0 check
  $0 update
  $0 update --service titan-node
  $0 update --reboot
  $0 update --version v0.1.23 --service titan-node
EOF
}

# Hàm báo lỗi
check_error() {
  local msg="$1"
  if [ $? -ne 0 ]; then
    echo -e "${RED}Error: ${msg}${NC}"
    exit 1
  fi
}

# Chắc chắn có curl
if ! command -v curl >/dev/null 2>&1; then
  echo -e "${RED}curl is required but not installed. Please install curl first.${NC}"
  exit 1
fi

# Hàm lấy nội dung URL
fetch_url() {
  local url="$1"
  curl -fsSL "$url"
}

# Hàm download file
download_file() {
  local url="$1"
  local dest="$2"
  curl -fL "$url" -o "$dest"
}

########################################
# PARSE THAM SỐ
########################################

# Mode có thể truyền đầu tiên: check / update
if [[ $# -ge 1 ]]; then
  case "$1" in
    check|--check|-c)
      MODE="check"
      shift
      ;;
    update|--update|-u)
      MODE="update"
      shift
      ;;
  esac
fi

# Các option khác
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reboot)
      DO_REBOOT=1
      shift
      ;;
    --version|-v)
      shift
      if [[ $# -eq 0 ]]; then
        echo -e "${RED}--version cần 1 giá trị, ví dụ: --version v0.1.23${NC}"
        exit 1
      fi
      EXPLICIT_VERSION="$1"
      shift
      ;;
    --service)
      shift
      if [[ $# -eq 0 ]]; then
        echo -e "${RED}--service cần 1 giá trị, ví dụ: --service titan-node${NC}"
        exit 1
      fi
      SERVICE_NAME="$1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo -e "${RED}Unknown argument: $1${NC}"
      usage
      exit 1
      ;;
  esac
done

########################################
# CHECK QUYỀN ROOT (chỉ với update)
########################################
if [[ "$MODE" = "update" ]] && [[ "$EUID" -ne 0 ]]; then
  echo -e "${RED}Vui lòng chạy với sudo hoặc dưới quyền root khi update.${NC}"
  exit 1
fi

########################################
# LẤY VERSION MỚI NHẤT / VERSION CHỈ ĐỊNH
########################################
echo -e "${YELLOW}Detecting Titan Guardian version...${NC}"
echo "Script version: ${SCRIPT_VERSION}"
echo "Using systemd service name: ${SERVICE_NAME}"

if [[ -n "$EXPLICIT_VERSION" ]]; then
  TITAN_VERSION="$EXPLICIT_VERSION"
  echo -e "Using explicit version: ${GREEN}${TITAN_VERSION}${NC}"
else
  JSON="$(fetch_url "$TITAN_REPO_API")"
  check_error "Failed to query GitHub API: $TITAN_REPO_API"

  if command -v jq >/dev/null 2>&1; then
    TITAN_VERSION="$(echo "$JSON" | jq -r '.tag_name')"
  else
    TITAN_VERSION="$(echo "$JSON" | grep '"tag_name"' | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')"
  fi

  if [[ -z "$TITAN_VERSION" || "$TITAN_VERSION" = "null" ]]; then
    echo -e "${RED}Could not determine latest version from GitHub API${NC}"
    exit 1
  fi
fi

TITAN_URL="https://github.com/Titannet-dao/titan-node/releases/download/${TITAN_VERSION}/${TITAN_BINARY}"

echo -e "Target version: ${GREEN}${TITAN_VERSION}${NC}"
echo "Download URL:   $TITAN_URL"
echo

########################################
# KIỂM TRA VERSION ĐANG CÀI
########################################
CURRENT_BIN_PATH="$(command -v "$TITAN_BINARY" 2>/dev/null || true)"
UP_TO_DATE=0

if [[ -n "$CURRENT_BIN_PATH" ]]; then
  echo "Current binary path: $CURRENT_BIN_PATH"
  CURRENT_VERSION_OUTPUT="$("$TITAN_BINARY" -v 2>&1 || true)"
  echo "Current version output: $CURRENT_VERSION_OUTPUT"

  # Lấy core version X.Y.Z từ output, ví dụ: 0.1.23 từ "titan-candidate version 0.1.23+git.a62ef10"
  CURRENT_BASE_VERSION="$(echo "$CURRENT_VERSION_OUTPUT" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"

  # Bỏ chữ 'v' ở phía trước tag GitHub, ví dụ: v0.1.23 -> 0.1.23
  LATEST_BASE_VERSION="${TITAN_VERSION#v}"

  if [[ -n "$CURRENT_BASE_VERSION" && "$CURRENT_BASE_VERSION" = "$LATEST_BASE_VERSION" ]]; then
    echo -e "${GREEN}Hiện tại đang chạy đúng version ${CURRENT_BASE_VERSION} (tag ${TITAN_VERSION}).${NC}"
    UP_TO_DATE=1
  elif [[ "$CURRENT_VERSION_OUTPUT" == *"$TITAN_VERSION"* ]]; then
    # fallback: nếu output chứa nguyên chuỗi tag
    echo -e "${GREEN}Hiện tại có vẻ đã là bản ${TITAN_VERSION} rồi.${NC}"
    UP_TO_DATE=1
  else
    echo -e "${YELLOW}Version đang cài có vẻ khác với tag ${TITAN_VERSION}.${NC}"
    UP_TO_DATE=0
  fi
else
  echo -e "${YELLOW}$TITAN_BINARY chưa được cài (command not found).${NC}"
  UP_TO_DATE=0
fi

########################################
# CHẾ ĐỘ CHỈ KIỂM TRA
########################################
if [[ "$MODE" = "check" ]]; then
  echo
  echo -e "${YELLOW}Check-only mode: không stop service, không download, không update, không reboot.${NC}"
  exit 0
fi

# Nếu đang update mà đã đúng version rồi thì thôi
if [[ "$MODE" = "update" && "$UP_TO_DATE" -eq 1 ]]; then
  echo
  echo -e "${GREEN}Đã chạy đúng version mục tiêu (${TITAN_VERSION}), không cần update thêm.${NC}"
  exit 0
fi

########################################
# TỪ ĐÂY TRỞ XUỐNG LÀ UPDATE THẬT
########################################
echo
echo "Starting the update process for Titan Guardian version ${TITAN_VERSION}..."

# Step 0: Stop the service
echo "Stopping the ${SERVICE_NAME} service..."
systemctl stop "$SERVICE_NAME"
check_error "Failed to stop the ${SERVICE_NAME} service"
echo -e "${GREEN}The ${SERVICE_NAME} service has been stopped${NC}"

# Step 1: Backup & remove old binary
echo "Handling old version of $TITAN_BINARY..."
if [[ -n "$CURRENT_BIN_PATH" && -f "$CURRENT_BIN_PATH" ]]; then
  TS="$(date +%Y%m%d-%H%M%S)"
  BACKUP_PATH="${CURRENT_BIN_PATH}.bak-${TS}"
  echo "Backing up old binary to: $BACKUP_PATH"
  cp "$CURRENT_BIN_PATH" "$BACKUP_PATH"
  check_error "Failed to backup old binary"

  echo "Removing old binary at: $CURRENT_BIN_PATH"
  rm -f "$CURRENT_BIN_PATH"
  check_error "Failed to remove old binary"
  echo -e "${GREEN}Old version backed up & removed successfully${NC}"
else
  echo "No old binary found, skipping removal"
fi

# Step 2: Download new version to temp file
TMP_FILE="$(mktemp "/tmp/${TITAN_BINARY}.XXXXXX")"
echo "Downloading new version to temporary file: $TMP_FILE"
download_file "$TITAN_URL" "$TMP_FILE"
check_error "Failed to download the new version"
echo -e "${GREEN}New version downloaded successfully${NC}"

# Step 3: Move & set permissions
DEST_PATH="${SYSTEM_DIR}/${TITAN_BINARY}"
echo "Moving $TITAN_BINARY to $DEST_PATH and setting permissions..."
mv "$TMP_FILE" "$DEST_PATH"
check_error "Failed to move $TITAN_BINARY to $SYSTEM_DIR"

chmod 0755 "$DEST_PATH"
check_error "Failed to set permissions for $TITAN_BINARY"
echo -e "${GREEN}Moved and set permissions successfully${NC}"

# Step 4: Start the service
echo "Starting the ${SERVICE_NAME} service..."
systemctl start "$SERVICE_NAME"
check_error "Failed to start the ${SERVICE_NAME} service"
echo -e "${GREEN}The ${SERVICE_NAME} service has been started${NC}"

# Step 5: Check version
echo "Checking the version of $TITAN_BINARY..."
"$TITAN_BINARY" -v
check_error "Failed to check the version"
echo -e "${GREEN}Update to version ${TITAN_VERSION} completed successfully!${NC}"

# Step 6: Optional reboot
if [[ "$DO_REBOOT" -eq 1 ]]; then
  echo "Reboot flag enabled. Rebooting in 5 seconds..."
  sleep 5
  reboot
else
  echo -e "${YELLOW}Không reboot tự động. Nếu cần, hãy reboot thủ công (hoặc dùng --reboot lần sau).${NC}"
fi

exit 0
