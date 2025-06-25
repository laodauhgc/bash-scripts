# Hướng dẫn cài đặt Nexus CLI - Docker

## Yêu cầu tối thiểu
- **Hệ điều hành**: Ubuntu 22.04 LTS trở lên
- **CPU**: 4 core
- **RAM**: 8GB
- **Ổ cứng**: 20GB trống
- **Internet**: Ổn định
- **Quyền root**: Yêu cầu
- **Ví Nexus**: Lấy từ [app.nexus.xyz/nodes](https://app.nexus.xyz/nodes)

## Cách sử dụng
1. **Chuẩn bị ví Nexus**:
   - Đăng nhập [app.nexus.xyz/nodes](https://app.nexus.xyz/nodes), lấy địa chỉ ví (ví dụ: `0x238a3a4ff431De579885D4xxx`).

2. **Chạy lệnh cài đặt**:
   ```bash
   wget -O install.sh https://raw.githubusercontent.com/laodauhgc/bash-scripts/refs/heads/main/nexus/install.sh && chmod +x install.sh && ./install.sh 0x238a3a4ff431De579885D4xxx
   ```
   - Thay `0x238a3a4ff431De579885D4xxx` bằng ví của bạn.
   - Lệnh tải script, cấp quyền thực thi, cài Docker, tạo swap (1x-2x RAM), đăng ký node với ví, và chạy node.

3. **Kiểm tra**:
   - Xem log:
     ```bash
     docker logs -f nexus-node
     ```
   - Kiểm tra container:
     ```bash
     docker ps
     ```
   - Log lưu tại `/root/nexus_logs/nexus.log`.

4. **Dừng node** (nếu cần):
   ```bash
   docker stop nexus-node && docker rm nexus-node
   ```
