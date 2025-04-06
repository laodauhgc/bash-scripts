#!/bin/bash
# --- Tùy chỉnh màu sắc ---
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# --- Cấu hình Cơ bản ---
# Tên mong muốn cho các project sẽ được tạo
DESIRED_PROJECT_NAMES=("project-edge-01" "project-edge-02")
# Số lượng project cần đảm bảo tồn tại (phải khớp với số lượng tên ở trên)
DESIRED_PROJECT_COUNT=${#DESIRED_PROJECT_NAMES[@]}

# Cấu hình VM (giữ nguyên từ yêu cầu trước)
TARGET_ZONE="us-east5-c"
VM_COUNT_PER_PROJECT=8
VM_MACHINE_TYPE="e2-small"
VM_IMAGE="projects/ubuntu-os-cloud/global/images/ubuntu-minimal-2204-jammy-v20250311"
VM_DISK_TYPE="pd-ssd"
VM_DISK_SIZE="56"
# Service Account sẽ được lấy tự động cho từng project
VM_SCOPES="https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/service.management.readonly,https://www.googleapis.com/auth/servicecontrol,https://www.googleapis.com/auth/trace.append"
STARTUP_SCRIPT_URL="https://raw.githubusercontent.com/laodauhgc/bash-scripts/refs/heads/main/titan-network/gcp/install-edge.sh"
# --- Kết thúc Cấu hình ---

# Mảng để lưu trữ ID thực tế của các project được quản lý
declare -a MANAGED_PROJECT_IDS=()

# === Các hàm tiện ích ===

# Function to generate a random string (for project ID)
# Project ID rules: 6-30 chars, lowercase letters, digits, hyphens, start with letter.
generate_project_id() {
  local prefix="edge-proj-"
  local random_part=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 12)
  echo "${prefix}${random_part}"
}

# === Các hàm xử lý GCP ===

# Lấy và kiểm tra hash value
get_hash_value() {
  hash_value="${1:-}"
  if [ -z "$hash_value" ]; then
    echo -e "${RED}Lỗi: Không có giá trị hash được cung cấp.${NC}"
    echo -e "${YELLOW}Cách dùng: ./script.sh <your_hash_value>${NC}"
    exit 1
  fi
  echo -e "${BLUE}Sử dụng hash value: $hash_value${NC}"
}

# Kiểm tra gcloud và xác thực
check_gcloud() {
  if ! command -v gcloud &> /dev/null; then
    echo -e "${RED}Lỗi: Không tìm thấy lệnh 'gcloud'. Vui lòng cài đặt Google Cloud SDK.${NC}"
    exit 1
  fi
  gcloud auth list --format="value(account)" > /dev/null 2>&1
  if [ $? -ne 0 ]; then
    echo -e "${RED}Lỗi: Chưa xác thực với gcloud. Chạy 'gcloud auth login' và 'gcloud config set account [YOUR_ACCOUNT]'.${NC}"
    exit 1
  fi
  echo -e "${GREEN}Đã xác thực gcloud.${NC}"
}

# Lấy thông tin Organization và Billing Account
get_gcp_info() {
  organization_id=$(gcloud organizations list --format="value(ID)" 2>/dev/null)
  if [ -n "$organization_id" ]; then
    echo -e "${BLUE}Phát hiện Organization ID: $organization_id ${NC}"
  else
    echo -e "${ORANGE}Không phát hiện Organization. Project sẽ được tạo không có thư mục mẹ là Organization.${NC}"
  fi

  billing_account_id=$(gcloud beta billing accounts list --format="value(name)" --filter='OPEN' | head -n 1)
  if [ -z "$billing_account_id" ]; then
    echo -e "${RED}Lỗi: Không tìm thấy tài khoản thanh toán (Billing Account) nào đang mở.${NC}"
    echo -e "${YELLOW}Đảm bảo bạn có quyền truy cập vào ít nhất một tài khoản thanh toán đang hoạt động.${NC}"
    exit 1
  fi
  echo -e "${BLUE}Sử dụng Billing Account ID: $billing_account_id ${NC}"
}

# Hàm đảm bảo các project mục tiêu tồn tại, được tạo nếu cần và lưu ID
ensure_target_projects() {
  echo -e "${ORANGE}--- Đảm bảo $DESIRED_PROJECT_COUNT project mục tiêu tồn tại ---${NC}"
  MANAGED_PROJECT_IDS=() # Reset mảng ID

  # Lấy danh sách project hiện có (chỉ lấy ID và tên) để kiểm tra
  echo -e "${BLUE}Đang lấy danh sách project hiện có...${NC}"
  # Sử dụng map để lưu trữ tên -> ID của project hiện có
  declare -A existing_projects
  while IFS=" " read -r proj_id proj_name; do
    # Chỉ lưu nếu tên project không rỗng
    if [[ -n "$proj_name" ]]; then
       existing_projects["$proj_name"]="$proj_id"
    fi
  done < <(gcloud projects list --format="value(projectId,name)")


  local project_created_count=0
  for desired_name in "${DESIRED_PROJECT_NAMES[@]}"; do
    local found_id=""
    # Kiểm tra xem project với tên mong muốn đã tồn tại chưa
    if [[ -v existing_projects["$desired_name"] ]]; then
        found_id="${existing_projects[$desired_name]}"
        echo -e "${GREEN}Project với tên '$desired_name' (ID: $found_id) đã tồn tại.${NC}"
        MANAGED_PROJECT_IDS+=("$found_id")
    else
        # Nếu chưa tồn tại, tạo project mới
        echo -e "${YELLOW}Project với tên '$desired_name' chưa tồn tại. Đang tạo...${NC}"
        local new_project_id=$(generate_project_id) # Tạo ID ngẫu nhiên, hợp lệ
        echo -e "${BLUE}Sử dụng Project ID được tạo: $new_project_id ${NC}"

        local create_cmd="gcloud projects create \"$new_project_id\" --name=\"$desired_name\""
        if [ -n "$organization_id" ]; then
            create_cmd+=" --organization=\"$organization_id\""
        fi

        # Thực hiện tạo project
        if ! eval "$create_cmd"; then
             echo -e "${RED}Lỗi: Không thể tạo project '$desired_name' (ID: $new_project_id). Kiểm tra lỗi ở trên, quyền hoặc tên/ID đã tồn tại.${NC}"
             # Có thể cần xử lý lỗi tốt hơn ở đây, ví dụ thử lại với ID khác hoặc thoát
             continue # Bỏ qua project này và tiếp tục với project tiếp theo
        fi
        echo -e "${GREEN}Đã tạo project '$desired_name' với ID: $new_project_id.${NC}"
        ((project_created_count++))
        sleep 10 # Chờ một chút để project được khởi tạo hoàn toàn

        # Liên kết tài khoản thanh toán
        echo -e "${YELLOW}Đang liên kết Billing Account '$billing_account_id' vào project '$new_project_id'...${NC}"
        if ! gcloud beta billing projects link "$new_project_id" --billing-account="$billing_account_id"; then
             echo -e "${RED}Cảnh báo: Không thể tự động liên kết billing cho project '$new_project_id'.${NC}"
             echo -e "${YELLOW}Vui lòng liên kết thủ công trong GCP Console. Script sẽ tiếp tục...${NC}"
             # Không thoát, nhưng cảnh báo người dùng
        else
             echo -e "${GREEN}Đã liên kết billing thành công cho project '$new_project_id'.${NC}"
             sleep 5 # Chờ cho việc liên kết billing ổn định
        fi
        MANAGED_PROJECT_IDS+=("$new_project_id")
    fi
  done

  if [ ${#MANAGED_PROJECT_IDS[@]} -ne $DESIRED_PROJECT_COUNT ]; then
      echo -e "${RED}Lỗi: Không thể đảm bảo đủ số lượng project mục tiêu (${#MANAGED_PROJECT_IDS[@]}/${DESIRED_PROJECT_COUNT}). Xem lại lỗi ở trên.${NC}"
      exit 1
  fi

  if [ "$project_created_count" -gt 0 ]; then
      echo -e "${ORANGE}Đã tạo $project_created_count project mới. Chờ thêm 30 giây để các dịch vụ được ổn định...${NC}"
      sleep 30
  fi

  echo -e "${GREEN}--- Hoàn tất đảm bảo project. Các Project ID sẽ được quản lý: ${MANAGED_PROJECT_IDS[*]} ---${NC}"
}

# Tạo firewall rule (Vẫn giữ nguyên quy tắc mở ALL - Cần xem xét lại về bảo mật)
create_firewall_rule() {
    local project_id=$1
    local rule_name="allow-all-ingress-insecure" # Tên rõ ràng hơn về sự không an toàn
    echo -e "${BLUE}Kiểm tra/Tạo firewall rule '$rule_name' trong project '$project_id'...${NC}"
    if ! gcloud compute --project="$project_id" firewall-rules describe "$rule_name" --format="value(name)" > /dev/null 2>&1; then
        echo -e "${YELLOW}Đang tạo firewall rule '$rule_name' (CHO PHÉP TẤT CẢ - KHÔNG AN TOÀN!) trong project '$project_id'...${NC}"
        gcloud compute --project="$project_id" firewall-rules create "$rule_name" \
            --direction=INGRESS \
            --priority=1000 \
            --network=default \
            --action=ALLOW \
            --rules=all \
            --source-ranges=0.0.0.0/0 \
            --description="CẢNH BÁO: Cho phép tất cả truy cập vào từ mọi nguồn. Chỉ dùng cho mục đích thử nghiệm." \
            --quiet # Thêm quiet để tránh hỏi xác nhận (nếu có)
        if [ $? -ne 0 ]; then
            echo -e "${RED}Lỗi khi tạo firewall rule trong project '$project_id'.${NC}"
        else
             echo -e "${GREEN}Đã tạo Firewall rule '$rule_name' trong project '$project_id'.${NC}"
        fi
    else
        echo -e "${BLUE}Firewall rule '$rule_name' đã tồn tại trong project '$project_id'.${NC}"
    fi
}

# Kích hoạt Compute API và tạo firewall rule cho các project được quản lý
enable_compute_and_firewall() {
    echo -e "${ORANGE}--- Kích hoạt Compute API & Cài đặt Firewall cho các project được quản lý ---${NC}"
    for project_id in "${MANAGED_PROJECT_IDS[@]}"; do
        echo -e "${BLUE}Đang xử lý project: $project_id${NC}"
        echo -e "${YELLOW}Kích hoạt compute.googleapis.com cho project '$project_id'...${NC}"
        # Kích hoạt API, nếu lỗi thì báo đỏ nhưng vẫn tiếp tục thử tạo firewall
        gcloud services enable compute.googleapis.com --project "$project_id" --async # Sử dụng --async để không phải chờ đợi lâu ở đây
        if [ $? -ne 0 ]; then
             echo -e "${RED}Có lỗi xảy ra khi yêu cầu kích hoạt Compute API cho project '$project_id'. Việc kích hoạt có thể vẫn đang diễn ra trong nền.${NC}"
        else
             echo -e "${BLUE}Đã gửi yêu cầu kích hoạt Compute API cho project '$project_id'.${NC}"
        fi
        # Chờ một chút trước khi tạo firewall rule
        sleep 5
        create_firewall_rule "$project_id"
    done
     echo -e "${ORANGE}Đã gửi yêu cầu kích hoạt API và tạo firewall. Cần chờ API kích hoạt hoàn tất ở bước sau.${NC}"
}

# Kiểm tra và chờ đợi Compute API được kích hoạt hoàn toàn
check_service_enablement() {
    local project_id="$1"
    local service_name="compute.googleapis.com"
    echo -e "${BLUE}Kiểm tra trạng thái Compute API trong project '$project_id'...${NC}"
    local attempt=0
    # Chờ tối đa 3 phút (36 * 5 giây)
    local max_attempts=36

    while [ $attempt -lt $max_attempts ]; do
        local service_status
        # Lấy trạng thái dựa trên tên cấu hình
        service_status=$(gcloud services list --enabled --project "$project_id" --filter="config.name:$service_name" --format="value(config.name)")

        if [[ "$service_status" == "$service_name" ]]; then
            echo -e "${GREEN}Compute API đã được kích hoạt trong project '$project_id'.${NC}"
            return 0 # Thành công
        else
            echo -e "${YELLOW}Compute API chưa sẵn sàng trong project '$project_id'. Đang chờ (lần $((attempt+1))/$max_attempts)...${NC}"
            sleep 5
            ((attempt++))
        fi
    done
    echo -e "${RED}Lỗi: Compute API không được kích hoạt trong project '$project_id' sau thời gian chờ.${NC}"
    return 1 # Thất bại
}

# Chạy kiểm tra và chờ đợi API kích hoạt cho tất cả project được quản lý
run_api_enablement_check() {
   echo -e "${ORANGE}--- Chờ đợi Compute API kích hoạt hoàn tất ---${NC}"
   local all_enabled=true
   for project_id in "${MANAGED_PROJECT_IDS[@]}"; do
     if ! check_service_enablement "$project_id"; then
        all_enabled=false
        # Có thể quyết định thoát ngay tại đây nếu một project lỗi
        # echo -e "${RED}Thoát do lỗi kích hoạt API.${NC}"; exit 1
     fi
   done
   if ! $all_enabled; then
       echo -e "${RED}Lỗi: Không thể kích hoạt Compute API cho một hoặc nhiều project. Xem lại lỗi ở trên.${NC}"
       exit 1
   fi
   echo -e "${GREEN}--- Compute API đã được kích hoạt trên tất cả project được quản lý ---${NC}"
}

# Hàm tạo máy ảo (VM)
create_vms() {
    echo -e "${ORANGE}--- Bắt đầu tạo máy ảo (VM) ---${NC}"
    for project_id in "${MANAGED_PROJECT_IDS[@]}"; do
        echo -e "${BLUE}=== Đang xử lý tạo VM cho project: $project_id ===${NC}"

        # 1. Lấy Project Number
        local project_number
        project_number=$(gcloud projects describe "$project_id" --format="value(projectNumber)")
        if [ -z "$project_number" ]; then
            echo -e "${RED}Lỗi: Không thể lấy Project Number cho project '$project_id'. Bỏ qua tạo VM cho project này.${NC}"
            continue # Chuyển sang project tiếp theo
        fi
        echo -e "${BLUE}Project Number của '$project_id' là: $project_number${NC}"

        # 2. Xác định Service Account mặc định của Compute Engine
        local service_account_email="${project_number}-compute@developer.gserviceaccount.com"
        echo -e "${BLUE}Sử dụng Service Account mặc định: $service_account_email${NC}"
        # Optional: Thêm kiểm tra xem SA này có thực sự tồn tại không (cần API được kích hoạt)
        # gcloud iam service-accounts describe "$service_account_email" --project="$project_id" > /dev/null 2>&1
        # if [ $? -ne 0 ]; then
        #     echo -e "${RED}Cảnh báo: Không thể xác minh Service Account '$service_account_email' trong project '$project_id'. Đảm bảo nó tồn tại.${NC}"
        # fi

        # 3. Tạo các VM trong project này
        local vm_created_count=0
        for (( i=1; i<=VM_COUNT_PER_PROJECT; i++ )); do
            local instance_name=$(printf "vm-edge-%02d" "$i") # Tên VM: vm-edge-01, vm-edge-02,...
            echo -e "${YELLOW}Đang tạo VM '$instance_name' trong project '$project_id' tại zone '$TARGET_ZONE'...${NC}"

            # Chuẩn bị startup script (thoát khỏi các ký tự đặc biệt nếu cần)
            local startup_script_content="#!/bin/bash
echo '>>> Downloading startup script...'
wget \"$STARTUP_SCRIPT_URL\" -T 20 -O install-edge.sh || curl -fsSL \"$STARTUP_SCRIPT_URL\" -o install-edge.sh
if [ -f install-edge.sh ]; then
  echo '>>> Executing startup script...'
  bash install-edge.sh \"$hash_value\"
  echo '>>> Startup script finished.'
else
  echo '>>> ERROR: Failed to download startup script from $STARTUP_SCRIPT_URL' >&2
fi"

            gcloud compute instances create "$instance_name" \
                --project="$project_id" \
                --zone="$TARGET_ZONE" \
                --machine-type="$VM_MACHINE_TYPE" \
                --network-interface="network-tier=PREMIUM,nic-type=GVNIC,stack-type=IPV4_ONLY,subnet=default" \
                --no-restart-on-failure \
                --maintenance-policy=MIGRATE \
                --provisioning-model=STANDARD \
                --service-account="$service_account_email" \
                --scopes="$VM_SCOPES" \
                --enable-display-device \
                --create-disk="auto-delete=yes,boot=yes,device-name=$instance_name,image=$VM_IMAGE,mode=rw,size=$VM_DISK_SIZE,type=$VM_DISK_TYPE" \
                --no-shielded-secure-boot \
                --shielded-vtpm \
                --shielded-integrity-monitoring \
                --labels="goog-ec-src=vm_add-gcloud,created-by=bash-script" \
                --metadata=startup-script="$startup_script_content" \
                --reservation-affinity=any \
                --quiet # Thêm quiet

            if [ $? -eq 0 ]; then
                echo -e "${GREEN}Đã tạo thành công VM '$instance_name' trong project '$project_id'.${NC}"
                ((vm_created_count++))
            else
                echo -e "${RED}Lỗi khi tạo VM '$instance_name' trong project '$project_id'. Kiểm tra lỗi chi tiết ở trên.${NC}"
                # Quyết định: dừng lại (exit 1) hay tiếp tục (continue)? Mặc định là tiếp tục.
            fi
            sleep 1 # Nghỉ ngắn giữa các lần tạo VM
        done
        echo -e "${BLUE}=== Hoàn tất tạo $vm_created_count/$VM_COUNT_PER_PROJECT VM cho project '$project_id' ===${NC}"
    done
    echo -e "${GREEN}--- Hoàn tất quá trình tạo VM ---${NC}"
}

# Liệt kê địa chỉ IP của các máy ảo đã tạo
list_server_ips() {
    echo -e "${ORANGE}--- Liệt kê địa chỉ IP của các VM đã tạo ---${NC}"
    local all_ips=()
    if [ ${#MANAGED_PROJECT_IDS[@]} -eq 0 ]; then
        echo -e "${YELLOW}Không có project nào được quản lý để lấy IP.${NC}"
        return
    fi

    for project_id in "${MANAGED_PROJECT_IDS[@]}"; do
        echo -e "${BLUE}Đang lấy IP từ project: $project_id ${NC}"
        local ips=()
        # Lọc chính xác hơn theo tên và zone
        ips=($(gcloud compute instances list \
                --project="$project_id" \
                --filter="name~'^vm-edge-' AND zone:( $TARGET_ZONE )" \
                --format="value(networkInterfaces[0].accessConfigs[0].natIP)" \
                2>/dev/null)) # Ẩn lỗi nếu không tìm thấy instance

        if [ ${#ips[@]} -gt 0 ]; then
            echo -e "${GREEN}Tìm thấy ${#ips[@]} IP(s) trong project '$project_id': ${ips[*]}${NC}"
            all_ips+=("${ips[@]}")
        else
            echo -e "${YELLOW}Không tìm thấy VM nào khớp hoặc không có IP ngoại bộ trong project '$project_id'.${NC}"
        fi
        sleep 1
    done

    echo -e "----------------------------------------------"
    echo -e "${YELLOW}Tổng hợp danh sách địa chỉ IP công cộng của các VM:${NC}"
    if [ ${#all_ips[@]} -gt 0 ]; then
        printf "%s\n" "${all_ips[@]}"
    else
        echo -e "${RED}Không tìm thấy địa chỉ IP nào.${NC}"
    fi
     echo -e "----------------------------------------------"
}

# === Hàm Chính ===
main() {
    echo -e "${YELLOW}===============================================================${NC}"
    echo -e "${YELLOW} Bắt đầu Script Tự Động Tạo VM Titan Network Edge trên GCP ${NC}"
    echo -e "${YELLOW}===============================================================${NC}"
    local start_time=$(date +%s)

    # 1. Kiểm tra và lấy thông tin đầu vào
    get_hash_value "$1"
    check_gcloud
    get_gcp_info

    # 2. Đảm bảo project tồn tại
    ensure_target_projects

    # 3. Kích hoạt API và tạo Firewall (bắt đầu chạy ngầm và tạo rule)
    enable_compute_and_firewall

    # 4. Chờ đợi API kích hoạt hoàn tất
    run_api_enablement_check

    # 5. Tạo máy ảo
    create_vms

    # 6. Liệt kê IPs
    list_server_ips

    # 7. Hoàn thành
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    echo -e "${GREEN}===============================================================${NC}"
    echo -e "${GREEN} Script đã hoàn thành thành công! ${NC}"
    echo -e "${GREEN} Tổng thời gian thực thi: $(date -u -d @${duration} +'%H giờ %M phút %S giây') ${NC}"
    echo -e "${GREEN}===============================================================${NC}"
}

# --- Thực thi Hàm Chính ---
main "$@" # Truyền tất cả các tham số dòng lệnh vào hàm main
