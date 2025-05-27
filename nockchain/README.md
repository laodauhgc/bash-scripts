# Hướng Dẫn Cài Đặt Nockchain

Script này tự động hóa việc cài đặt, chạy và xóa các node worker Nockchain trên Ubuntu. Cấu hình tường lửa, biên dịch Nockchain, quản lý ví khóa và chạy worker ở chế độ nền.

## Yêu Cầu

- Hệ điều hành Ubuntu
- CPU: 8 lõi trở lên
- RAM: 16GB trở lên
- Quyền root
- Kết nối internet

## Cài Đặt

1. **Tải Script**

   Tải và cấp quyền thực thi script:
   ```bash
   curl -O https://raw.githubusercontent.com/laodauhgc/bash-scripts/main/nockchain/install_nockchain.sh && chmod +x install_nockchain.sh
   ```

## Sử Dụng

### Chạy Worker

- **Mặc định (số worker = số lõi CPU)**:
  ```bash
  sudo ./install_nockchain.sh
  ```

- **Chỉ định số worker** (ví dụ: 8):
  ```bash
  sudo ./install_nockchain.sh -c 8
  ```
  Hoặc trực tiếp:
   ```bash
   curl -O https://raw.githubusercontent.com/laodauhgc/bash-scripts/main/nockchain/install_nockchain.sh && chmod +x install_nockchain.sh -c 8
   ```

  Lệnh này tạo 8 worker (`nockchain-worker-01` đến `nockchain-worker-08`), mở cổng tường lửa (`22/tcp`, `3005:3006/tcp`, `3005:3006/udp`, `30000/udp`, `30301-30308/tcp+udp`), và chạy worker ở chế độ nền.
  Nếu bạn sử dụng các dịch vụ Cloud, thuê VPS chỉ nên chạy 75-80% số CPU.

### Xóa Worker

- **Xóa tất cả worker** (giữ `/root/nockchain_backup`):
  ```bash
  sudo ./install_nockchain.sh -rm
  ```

  Lệnh này dừng tiến trình Nockchain, xóa thư mục worker và xóa cổng P2P (`30301-30308`) khỏi tường lửa.

## Giám Sát

- **Kiểm tra log**:
  ```bash
  tail -f /root/nockchain-worker-01/worker-01.log
  ```
  Tìm dòng `[%mining-on ...]` hoặc `block ... added to validated blocks at <height>`.

- **Kiểm tra tiến trình**:
  ```bash
  ps aux | grep nockchain
  ```

- **Kiểm tra tường lửa**:
  ```bash
  ufw status
  ```

## Quản Lý Ví

- Khóa ví được lưu tại `/root/nockchain_backup` (`keys.export`, `wallet_output.txt`).
- Nếu `keys.export` tồn tại, script sẽ nhập ví; nếu không, tạo ví mới.
- Xem khóa công khai:
  ```bash
  cat /root/nockchain_backup/wallet_output.txt
  ```

## Lưu Ý

- **Thời gian biên dịch**: Lần đầu cài đặt có thể mất hơn 30 phút để biên dịch Nockchain.
- **NAT**: Cần cấu hình chuyển tiếp cổng `30301-<số_worker>` nếu dùng NAT.
- **Quyền root**: Chạy với `sudo` để cài đặt và quản lý tường lửa.
- **Thông tin thêm**: Xem [Nockchain GitHub](https://github.com/zorp-corp/nockchain).
