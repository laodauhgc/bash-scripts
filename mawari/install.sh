#!/usr/bin/env bash
set -Eeuo pipefail

#####################################
# Mawari Guardian Node - Installer  #
# Default: English output           #
# Options: vi, ru, zh               #
#####################################

# --- Defaults / params ---
CONTAINER_NAME="mawari-node"
CACHE_DIR="${HOME}/mawari"
IMAGE_DEFAULT="us-east4-docker.pkg.dev/mawarinetwork-dev/mwr-net-d-car-uses4-public-docker-registry-e62e/mawari-node:latest"
IMAGE="$IMAGE_DEFAULT"
TIMEOUT=300  # seconds
LANG_CODE="${LANG_CODE:-en}" # default language

# Ensure UTF-8 for non-ASCII output (best-effort)
export LC_ALL="${LC_ALL:-C.UTF-8}"
export LANG="${LANG:-C.UTF-8}"

print_usage() {
  cat <<EOF
Usage:
  $0 [-a|--address 0xOWNER] [-n|--name mawari-node] [-d|--dir ~/mawari] [-i|--image IMAGE] [-t|--timeout 300] [-L|--lang en|vi|ru|zh]

Options:
  -a, --address   OWNER_ADDRESS (0x...)
  -n, --name      Container name (default: mawari-node)
  -d, --dir       Data directory (default: ~/mawari)
  -i, --image     Docker image (default: ${IMAGE_DEFAULT})
  -t, --timeout   Seconds to wait for burner address (default: 300)
  -L, --lang      Output language: en (default), vi, ru, zh
  -h, --help      Show this help
EOF
}

# --- Tiny i18n helper ---
t() {
  local key="$1"
  case "${LANG_CODE}" in
    vi)
      case "$key" in
        docker_not_found) echo "❌ Không tìm thấy 'docker'. Vui lòng cài Docker trước." ;;
        docker_cant_run)  echo "❌ Docker không thể chạy (cần quyền). Hãy thêm user vào nhóm docker hoặc dùng sudo." ;;
        prompt_owner)     echo -n "Nhập địa chỉ ví OWNER_ADDRESS (0x...): " ;;
        invalid_owner)    echo "❌ Địa chỉ ví không hợp lệ." ;;
        summary_owner)    echo "✅ OWNER_ADDRESS" ;;
        summary_name)     echo "⚙️  Container" ;;
        summary_dir)      echo "📁 Dữ liệu" ;;
        summary_image)    echo "🐳 Image" ;;
        summary_timeout)  echo "⏳ Timeout dò ví burner (giây)" ;;
        pulling_image)    echo "⬇️  Đang kéo image (always)..." ;;
        starting)         echo "🚀 Khởi tạo container..." ;;
        scanning_logs)    echo "🔍 Đang dò log để lấy địa chỉ ví Burner Wallet..." ;;
        timeout_burner)   echo "⚠️ Hết thời gian chờ, chưa thấy địa chỉ ví burner trong log." ;;
        view_logs_hint)   echo "👉 Xem log: docker logs -f" ;;
        replacing)        echo "♻️ Container đã tồn tại. Đang thay thế..." ;;
        success)          echo "✅ Khởi tạo thành công!" ;;
        burner_wallet)    echo "🔥 BURNER_WALLET" ;;
        saved)            echo "💾 Đã lưu tệp:" ;;
        next_steps)       echo "👉 Tiếp theo:\n   1) Gửi 1 MAWARI test token vào ví burner.\n   2) Vào https://app.testnet.mawari.net/ và Delegate License cho ví burner.\n   3) Chờ trạng thái 'Running'." ;;
        admin)            echo "🔧 Lệnh quản trị:" ;;
        logs_cmd)         echo "   - Xem log:" ;;
        status_cmd)       echo "   - Trạng thái:" ;;
        stop_cmd)         echo "   - Dừng:" ;;
        start_cmd)        echo "   - Start:" ;;
        lang_label)       echo "🗣️  Ngôn ngữ" ;;
        *) echo "$key" ;;
      esac
      ;;
    ru)
      case "$key" in
        docker_not_found) echo "❌ 'docker' не найден. Пожалуйста, установите Docker." ;;
        docker_cant_run)  echo "❌ Docker не может запуститься (нужны привилегии). Добавьте пользователя в группу docker или используйте sudo." ;;
        prompt_owner)     echo -n "Введите OWNER_ADDRESS (0x...): " ;;
        invalid_owner)    echo "❌ Неверный адрес кошелька." ;;
        summary_owner)    echo "✅ OWNER_ADDRESS" ;;
        summary_name)     echo "⚙️  Контейнер" ;;
        summary_dir)      echo "📁 Каталог данных" ;;
        summary_image)    echo "🐳 Образ" ;;
        summary_timeout)  echo "⏳ Таймаут поиска burner (сек)" ;;
        pulling_image)    echo "⬇️  Загрузка образа (always)..." ;;
        starting)         echo "🚀 Запуск контейнера..." ;;
        scanning_logs)    echo "🔍 Поиск адреса burner-кошелька в логах..." ;;
        timeout_burner)   echo "⚠️ Время ожидания истекло, адрес burner не найден в логах." ;;
        view_logs_hint)   echo "👉 Смотрите логи: docker logs -f" ;;
        replacing)        echo "♻️ Контейнер уже существует. Пересоздание..." ;;
        success)          echo "✅ Инициализация успешно завершена!" ;;
        burner_wallet)    echo "🔥 BURNER_WALLET" ;;
        saved)            echo "💾 Сохранено:" ;;
        next_steps)       echo "👉 Дальше:\n   1) Отправьте 1 тестовый токен MAWARI на burner-кошелёк.\n   2) Откройте https://app.testnet.mawari.net/ и делегируйте лицензию burner-кошельку.\n   3) Дождитесь статуса 'Running'." ;;
        admin)            echo "🔧 Команды администрирования:" ;;
        logs_cmd)         echo "   - Логи:" ;;
        status_cmd)       echo "   - Статус:" ;;
        stop_cmd)         echo "   - Остановить:" ;;
        start_cmd)        echo "   - Запустить:" ;;
        lang_label)       echo "🗣️  Язык" ;;
        *) echo "$key" ;;
      esac
      ;;
    zh)
      case "$key" in
        docker_not_found) echo "❌ 未找到 'docker'，请先安装 Docker。" ;;
        docker_cant_run)  echo "❌ Docker 无法运行（需要权限）。请将用户加入 docker 组或使用 sudo。" ;;
        prompt_owner)     echo -n "请输入 OWNER_ADDRESS（0x...）：";;
        invalid_owner)    echo "❌ 钱包地址无效。" ;;
        summary_owner)    echo "✅ OWNER_ADDRESS" ;;
        summary_name)     echo "⚙️  容器" ;;
        summary_dir)      echo "📁 数据目录" ;;
        summary_image)    echo "🐳 镜像" ;;
        summary_timeout)  echo "⏳ 等待 burner 地址超时（秒）" ;;
        pulling_image)    echo "⬇️  拉取镜像（always）..." ;;
        starting)         echo "🚀 正在启动容器..." ;;
        scanning_logs)    echo "🔍 正在从日志中提取 Burner 钱包地址..." ;;
        timeout_burner)   echo "⚠️ 超时，日志中未发现 Burner 地址。" ;;
        view_logs_hint)   echo "👉 查看日志：docker logs -f" ;;
        replacing)        echo "♻️ 检测到已存在的容器，正在替换..." ;;
        success)          echo "✅ 初始化成功！" ;;
        burner_wallet)    echo "🔥 BURNER_WALLET" ;;
        saved)            echo "💾 已保存：" ;;
        next_steps)       echo "👉 接下来：\n   1) 向上面的 Burner 地址发送 1 个 MAWARI 测试代币。\n   2) 打开 https://app.testnet.mawari.net/ 将 License 委托给该地址。\n   3) 等待状态变为“Running”。" ;;
        admin)            echo "🔧 管理命令：" ;;
        logs_cmd)         echo "   - 查看日志：" ;;
        status_cmd)       echo "   - 状态：" ;;
        stop_cmd)         echo "   - 停止：" ;;
        start_cmd)        echo "   - 启动：" ;;
        lang_label)       echo "🗣️  语言" ;;
        *) echo "$key" ;;
      esac
      ;;
    *) # en
      case "$key" in
        docker_not_found) echo "❌ 'docker' not found. Please install Docker first." ;;
        docker_cant_run)  echo "❌ Docker cannot run (permissions needed). Add your user to the docker group or use sudo." ;;
        prompt_owner)     echo -n "Enter OWNER_ADDRESS (0x...): " ;;
        invalid_owner)    echo "❌ Invalid wallet address." ;;
        summary_owner)    echo "✅ OWNER_ADDRESS" ;;
        summary_name)     echo "⚙️  Container" ;;
        summary_dir)      echo "📁 Data dir" ;;
        summary_image)    echo "🐳 Image" ;;
        summary_timeout)  echo "⏳ Burner scan timeout (sec)" ;;
        pulling_image)    echo "⬇️  Pulling image (always)..." ;;
        starting)         echo "🚀 Starting container..." ;;
        scanning_logs)    echo "🔍 Scanning logs for Burner Wallet address..." ;;
        timeout_burner)   echo "⚠️ Timeout reached; burner address not found in logs." ;;
        view_logs_hint)   echo "👉 View logs: docker logs -f" ;;
        replacing)        echo "♻️ Container already exists. Replacing..." ;;
        success)          echo "✅ Initialization successful!" ;;
        burner_wallet)    echo "🔥 BURNER_WALLET" ;;
        saved)            echo "💾 Saved files:" ;;
        next_steps)       echo "👉 Next steps:\n   1) Send 1 MAWARI test token to the burner wallet.\n   2) Open https://app.testnet.mawari.net/ and Delegate the License to the burner.\n   3) Wait for status 'Running'." ;;
        admin)            echo "🔧 Admin commands:" ;;
        logs_cmd)         echo "   - Logs:" ;;
        status_cmd)       echo "   - Status:" ;;
        stop_cmd)         echo "   - Stop:" ;;
        start_cmd)        echo "   - Start:" ;;
        lang_label)       echo "🗣️  Language" ;;
        *) echo "$key" ;;
      esac
      ;;
  esac
}

OWNER_ADDRESS="${OWNER_ADDRESS:-}"

# --- Parse args ---
while [[ "${#}" -gt 0 ]]; do
  case "${1}" in
    -a|--address) OWNER_ADDRESS="${2:-}"; shift 2 ;;
    -n|--name) CONTAINER_NAME="${2:-}"; shift 2 ;;
    -d|--dir) CACHE_DIR="${2:-}"; shift 2 ;;
    -i|--image) IMAGE="${2:-}"; shift 2 ;;
    -t|--timeout) TIMEOUT="${2:-}"; shift 2 ;;
    -L|--lang) LANG_CODE="${2:-en}"; shift 2 ;;
    -h|--help) print_usage; exit 0 ;;
    *) echo "Invalid option: ${1}"; print_usage; exit 1 ;;
  esac
done

# normalize language
case "${LANG_CODE,,}" in
  en|vi|ru|zh|zh-cn|zh_simplified) [[ "${LANG_CODE}" == zh* ]] && LANG_CODE="zh" || true ;;
  *) LANG_CODE="en" ;;
esac

# --- Check Docker ---
DOCKER_BIN="docker"
if ! command -v docker >/dev/null 2>&1; then
  t docker_not_found >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    DOCKER_BIN="sudo docker"
  else
    t docker_cant_run >&2
    exit 1
  fi
fi

# --- Read OWNER_ADDRESS if not passed ---
if [[ -z "${OWNER_ADDRESS}" ]]; then
  t prompt_owner
  read -r OWNER_ADDRESS
fi
# --- Validate wallet ---
if [[ ! "${OWNER_ADDRESS}" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
  t invalid_owner >&2
  exit 1
fi

echo "$(t lang_label): ${LANG_CODE}"
echo "$(t summary_owner): ${OWNER_ADDRESS}"
echo "$(t summary_name): ${CONTAINER_NAME}"
echo "$(t summary_dir): ${CACHE_DIR}"
echo "$(t summary_image): ${IMAGE}"
echo "$(t summary_timeout): ${TIMEOUT}"

# --- Prepare data dir ---
mkdir -p "${CACHE_DIR}"

# --- Replace existing container if any (data persists on host dir) ---
EXISTING_ID="$(${DOCKER_BIN} ps -a --filter "name=^/${CONTAINER_NAME}$" -q || true)"
if [[ -n "${EXISTING_ID}" ]]; then
  t replacing
  ${DOCKER_BIN} rm -f "${CONTAINER_NAME}" >/dev/null
fi

# --- Pull & run container (official, persistent) ---
t pulling_image
${DOCKER_BIN} pull "${IMAGE}" >/dev/null

t starting
${DOCKER_BIN} run -d \
  --name "${CONTAINER_NAME}" \
  --restart unless-stopped \
  --pull always \
  -v "${CACHE_DIR}:/app/cache" \
  -e "OWNERS_ALLOWLIST=${OWNER_ADDRESS}" \
  "${IMAGE}" >/dev/null

# --- Extract burner wallet from logs ---
t scanning_logs
BURNER_ADDR=""
START_TS="$(date +%s)"

try_extract_burner() {
  ${DOCKER_BIN} logs --since 0s --tail 500 "${CONTAINER_NAME}" 2>&1 \
  | grep -i "Using burner wallet" \
  | grep -Eo '0x[0-9a-fA-F]{40}' \
  | head -n1 || true
}

BURNER_ADDR="$(try_extract_burner || true)"

while [[ -z "${BURNER_ADDR}" ]]; do
  NOW="$(date +%s)"
  ELAPSED=$(( NOW - START_TS ))
  if (( ELAPSED > TIMEOUT )); then
    t timeout_burner
    echo "$(t view_logs_hint) ${CONTAINER_NAME}"
    exit 2
  fi
  sleep 2
  BURNER_ADDR="$(try_extract_burner || true)"
done

# --- Save & print results ---
TS_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "${BURNER_ADDR}" > "${CACHE_DIR}/burner_wallet.txt"

cat > "${CACHE_DIR}/burner_wallet.json" <<JSON
{
  "burner_address": "${BURNER_ADDR}",
  "owner_address": "${OWNER_ADDRESS}",
  "container_name": "${CONTAINER_NAME}",
  "image": "${IMAGE}",
  "cache_dir": "${CACHE_DIR}",
  "locale": "${LANG_CODE}",
  "created_at_utc": "${TS_ISO}"
}
JSON

cat > "${CACHE_DIR}/.env" <<ENV
OWNER_ADDRESS=${OWNER_ADDRESS}
BURNER_WALLET=${BURNER_ADDR}
CONTAINER_NAME=${CONTAINER_NAME}
LANG_CODE=${LANG_CODE}
ENV

echo
t success
echo "$(t burner_wallet)=${BURNER_ADDR}"
echo "$(t saved)"
echo "   - ${CACHE_DIR}/burner_wallet.json"
echo "   - ${CACHE_DIR}/burner_wallet.txt"
echo "   - ${CACHE_DIR}/.env"
echo
printf "%b\n" "$(t next_steps)"
echo
t admin
echo "$(t logs_cmd)    ${DOCKER_BIN} logs -f ${CONTAINER_NAME}"
echo "$(t status_cmd)  ${DOCKER_BIN} ps"
echo "$(t stop_cmd)    ${DOCKER_BIN} stop ${CONTAINER_NAME}"
echo "$(t start_cmd)   ${DOCKER_BIN} start ${CONTAINER_NAME}"
