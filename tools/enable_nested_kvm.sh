#!/usr/bin/env bash

# Script tự động bật nested virtualization trên Linux
# Hỗ trợ KVM (Intel: vmx, AMD: svm)
# Chạy với quyền root

# Thoát ngay khi có lỗi, lỗi pipeline, không dùng biến chưa khai báo (tùy chọn)
set -eo pipefail
# set -u # Bỏ comment nếu muốn kiểm tra biến chưa khai báo chặt chẽ hơn

# --- Biến và Hằng số ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT_NAME=$(basename "$0")
LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')] [${SCRIPT_NAME}]"

# --- Hàm phụ trợ ---

# Hàm ghi log
log() {
    echo -e "${LOG_PREFIX} $1"
}

# Hàm báo lỗi và thoát
error_exit() {
    log "${RED}Lỗi: $1${NC}" >&2
    exit 1
}

# Kiểm tra quyền root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "Script này cần chạy với quyền root. Vui lòng dùng sudo."
    fi
    log "${GREEN}Đang chạy với quyền root.${NC}"
}

# Kiểm tra các lệnh cần thiết
check_dependencies() {
    log "${YELLOW}Kiểm tra các lệnh cần thiết...${NC}"
    local missing_cmds=()
    for cmd in grep modprobe cat head uname; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_cmds+=("$cmd")
        fi
    done
    if [[ ${#missing_cmds[@]} -gt 0 ]]; then
        error_exit "Các lệnh sau không tìm thấy: ${missing_cmds[*]}. Vui lòng cài đặt chúng."
    fi
    log "${GREEN}Các lệnh cần thiết đã có.${NC}"
}

# --- Hàm chính ---

# Hàm kiểm tra CPU và ảo hóa
check_cpu_virt() {
    log "${YELLOW}Kiểm tra hỗ trợ ảo hóa CPU...${NC}"
    if grep -qE 'vmx|svm' /proc/cpuinfo; then
        CPU_FLAGS=$(grep -m 1 -oE 'vmx|svm' /proc/cpuinfo)
        if [[ "$CPU_FLAGS" == "vmx" ]]; then
            log "${GREEN}CPU Intel được phát hiện (hỗ trợ vmx).${NC}"
            MODULE="kvm_intel"
        elif [[ "$CPU_FLAGS" == "svm" ]]; then
            log "${GREEN}CPU AMD được phát hiện (hỗ trợ svm).${NC}"
            MODULE="kvm_amd"
        else
             # Trường hợp này gần như không xảy ra nếu grep thành công
             error_exit "Không thể xác định loại CPU từ cờ ảo hóa."
        fi
        # Xuất biến MODULE ra phạm vi ngoài hàm
        export MODULE
    else
        error_exit "CPU không hỗ trợ ảo hóa phần cứng (vmx/svm không được tìm thấy trong /proc/cpuinfo). Đảm bảo ảo hóa đã được bật trong BIOS/UEFI."
    fi
}

# Hàm kiểm tra trạng thái nested virtualization hiện tại
# Trả về 0 nếu đã bật, 1 nếu chưa bật
check_nested_status() {
    local module_name="$1"
    local param_file="/sys/module/${module_name}/parameters/nested"

    log "${YELLOW}Kiểm tra trạng thái nested cho ${module_name}...${NC}"
    if [[ ! -f "$param_file" ]]; then
        # Module có thể chưa được tải, hoặc kernel quá cũ không có file này
        log "${YELLOW}Không tìm thấy file ${param_file}. Có thể module ${module_name} chưa được tải hoặc nested không được hỗ trợ theo cách này.${NC}"
        return 1 # Giả định là chưa bật
    fi

    local nested_status
    nested_status=$(cat "$param_file")
    if [[ "$nested_status" == "Y" || "$nested_status" == "1" ]]; then
        log "${GREEN}Nested virtualization đã được bật (runtime) cho ${module_name} (Giá trị: $nested_status).${NC}"
        return 0
    else
        log "${YELLOW}Nested virtualization chưa được bật (runtime) cho ${module_name} (Giá trị: $nested_status).${NC}"
        return 1
    fi
}

# Hàm bật nested virtualization
enable_nested_virt() {
    local module_name="$1"
    local conf_dir="/etc/modprobe.d"
    local conf_file="${conf_dir}/${module_name}_nested.conf" # Đặt tên file rõ ràng hơn

    log "${YELLOW}Đang cấu hình để bật nested virtualization cho ${module_name}...${NC}"

    # 1. Cố gắng gỡ module hiện tại để áp dụng cấu hình mới ngay lập tức
    # Lưu ý: Bước này có thể thất bại nếu module đang được sử dụng (ví dụ: có VM đang chạy)
    log "${YELLOW}Đang thử gỡ module ${module_name} để tải lại với cấu hình mới...${NC}"
    if modprobe -r "$module_name"; then
        log "${GREEN}Module ${module_name} đã được gỡ bỏ thành công.${NC}"
    else
        log "${YELLOW}Không thể gỡ module ${module_name}. Có thể module đang được sử dụng. Thay đổi cấu hình sẽ có hiệu lực sau khi khởi động lại hệ thống.${NC}"
        # Không thoát script ở đây, vì cấu hình vẫn sẽ được lưu cho lần khởi động sau
    fi

    # 2. Tạo file cấu hình để bật nested vĩnh viễn
    log "${YELLOW}Tạo/Cập nhật file cấu hình ${conf_file}...${NC}"
    # Đảm bảo thư mục tồn tại
    mkdir -p "$conf_dir" || error_exit "Không thể tạo thư mục ${conf_dir}."
    # Ghi cấu hình
    echo "options ${module_name} nested=1" > "$conf_file" || error_exit "Không thể ghi vào file ${conf_file}."
    log "${GREEN}Đã ghi cấu hình 'options ${module_name} nested=1' vào ${conf_file}.${NC}"

    # 3. Tải lại module với cấu hình mới
    log "${YELLOW}Đang tải lại module ${module_name}...${NC}"
    if ! modprobe "$module_name"; then
        error_exit "Không thể tải module ${module_name} sau khi cấu hình nested. Kiểm tra log hệ thống (dmesg, journalctl) để biết chi tiết."
    fi
    log "${GREEN}Module ${module_name} đã được tải lại.${NC}"

    # 4. Kiểm tra lại trạng thái runtime
    if check_nested_status "$module_name"; then
        log "${GREEN}Xác nhận thành công: Nested virtualization hiện đã được bật cho ${module_name}.${NC}"
    else
        # Nếu việc gỡ module ở bước 1 thành công mà vẫn không bật được ở đây, có thể có vấn đề khác
        log "${YELLOW}Không thể xác nhận nested virtualization được bật ngay lập tức. Có thể cần khởi động lại hệ thống.${NC}"
        # Không nên coi đây là lỗi nghiêm trọng vì cấu hình đã được lưu
    fi
}

# Hàm cài đặt các gói ảo hóa cần thiết
install_virt_packages() {
    log "${YELLOW}Kiểm tra và cài đặt các gói ảo hóa cần thiết...${NC}"
    local pkg_manager=""
    local install_cmd=""
    local update_cmd=""
    local packages=()

    # Xác định bản phân phối và trình quản lý gói
    if command -v apt &>/dev/null; then
        pkg_manager="apt"
        update_cmd="apt update -y"
        # Thêm cpu-checker để có kvm-ok
        packages=(qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virtinst cpu-checker)
        install_cmd="apt install -y ${packages[*]}"
    elif command -v dnf &>/dev/null; then
        pkg_manager="dnf"
        update_cmd="dnf check-update" # dnf thường không cần update riêng biệt trước install
        # Kiểm tra gói tương đương cpu-checker trên Fedora/RHEL
        packages=(qemu-kvm libvirt-daemon libvirt-client libvirt-daemon-kvm virt-install bridge-utils) # Tên gói có thể thay đổi chút ít
        install_cmd="dnf install -y ${packages[*]}"
    elif command -v yum &>/dev/null; then
        pkg_manager="yum"
        update_cmd="yum check-update"
        packages=(qemu-kvm libvirt-daemon libvirt-client libvirt-daemon-kvm virt-install bridge-utils)
        install_cmd="yum install -y ${packages[*]}"
    else
        error_exit "Không tìm thấy trình quản lý gói hỗ trợ (apt, dnf, yum)."
    fi

    log "Sử dụng trình quản lý gói: ${pkg_manager}"
    log "Các gói sẽ được cài đặt (nếu chưa có): ${packages[*]}"

    # Cập nhật và Cài đặt (Hiển thị output)
    log "Chạy lệnh cập nhật (${update_cmd})..."
    if ! $update_cmd; then
        log "${YELLOW}Lệnh cập nhật có thể đã báo lỗi/cảnh báo, nhưng vẫn tiếp tục cài đặt.${NC}"
    fi

    log "Chạy lệnh cài đặt (${install_cmd})..."
    if ! $install_cmd; then
        error_exit "Không thể cài đặt các gói cần thiết. Vui lòng kiểm tra output ở trên để biết lỗi chi tiết."
    fi

    log "${GREEN}Các gói ảo hóa cần thiết đã được kiểm tra/cài đặt.${NC}"

    # Đảm bảo dịch vụ libvirtd được bật và khởi động
    log "${YELLOW}Đảm bảo dịch vụ libvirtd đang chạy và được kích hoạt...${NC}"
    if systemctl is-active --quiet libvirtd; then
        log "${GREEN}Dịch vụ libvirtd đang chạy.${NC}"
    else
        log "${YELLOW}Đang khởi động dịch vụ libvirtd...${NC}"
        systemctl start libvirtd || log "${YELLOW}Không thể khởi động libvirtd ngay lập tức. Có thể cần kiểm tra cấu hình.${NC}"
    fi
    if systemctl is-enabled --quiet libvirtd; then
        log "${GREEN}Dịch vụ libvirtd đã được kích hoạt để khởi động cùng hệ thống.${NC}"
    else
        log "${YELLOW}Đang kích hoạt dịch vụ libvirtd để khởi động cùng hệ thống...${NC}"
        systemctl enable libvirtd || log "${YELLOW}Không thể kích hoạt libvirtd.${NC}"
    fi
}

# Hàm kiểm tra KVM hoạt động (sử dụng kvm-ok nếu có)
check_kvm() {
    log "${YELLOW}Kiểm tra KVM hoạt động...${NC}"
    if command -v kvm-ok &>/dev/null; then
        log "Đang chạy kvm-ok..."
        if kvm-ok; then
            log "${GREEN}kvm-ok xác nhận: KVM acceleration có thể được sử dụng.${NC}"
        else
            # kvm-ok thường cung cấp thông tin hữu ích khi thất bại
            error_exit "kvm-ok báo cáo KVM không thể sử dụng được. Đảm bảo ảo hóa được bật trong BIOS/UEFI và module KVM (${MODULE}) đã được tải đúng cách."
        fi
    else
        log "${YELLOW}Lệnh 'kvm-ok' không tìm thấy. Bỏ qua bước kiểm tra này. (Bạn có thể cài đặt 'cpu-checker' trên Debian/Ubuntu hoặc tìm gói tương đương).${NC}"
        # Kiểm tra sự tồn tại của thiết bị KVM như một phương án thay thế cơ bản
        if [[ -e /dev/kvm ]]; then
             log "${GREEN}Tìm thấy thiết bị /dev/kvm. KVM có vẻ đã được kích hoạt.${NC}"
        else
             log "${YELLOW}Không tìm thấy thiết bị /dev/kvm. Có thể KVM chưa hoạt động đúng.${NC}"
        fi
    fi
}

# --- Hàm chính điều khiển luồng ---
main() {
    log "${YELLOW}=== Bắt đầu Script Cấu hình Nested Virtualization ===${NC}"

    check_root
    check_dependencies
    check_cpu_virt # Xác định và export biến $MODULE

    # Kiểm tra trạng thái ban đầu
    # Sử dụng || true để không bị dừng bởi set -e nếu check_nested_status trả về 1 (chưa bật)
    if check_nested_status "$MODULE" || true; then
        # Nếu hàm trả về 0 (đã bật), không cần làm gì thêm với module
        if [[ $? -eq 0 ]]; then
             log "${GREEN}Nested virtualization đã được cấu hình và bật.${NC}"
        else
             # Nếu hàm trả về 1 (chưa bật), tiến hành bật
             install_virt_packages # Cài trước khi cố gắng load module
             enable_nested_virt "$MODULE"
        fi
    fi

    # Kiểm tra KVM tổng thể sau khi đã cố gắng bật nested
    check_kvm

    log "${GREEN}=== Hoàn tất Script Cấu hình Nested Virtualization ===${NC}"
    log "${YELLOW}QUAN TRỌNG: Mặc dù script đã cố gắng áp dụng thay đổi ngay lập tức, bạn nên KHỞI ĐỘNG LẠI HỆ THỐNG để đảm bảo tất cả thay đổi về module kernel có hiệu lực hoàn toàn và ổn định.${NC}"
    log "${YELLOW}Sau khi khởi động lại, bạn có thể kiểm tra lại bằng lệnh:${NC}"
    log "${YELLOW}cat /sys/module/${MODULE}/parameters/nested (Kết quả mong đợi: Y hoặc 1)${NC}"
}

# --- Chạy script ---
main
