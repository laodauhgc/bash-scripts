# Nockchain Installation Script

Tập lệnh Bash tự động cài đặt node Nockchain miner trên Ubuntu, sử dụng Systemd để chạy liên tục.

## Yêu cầu
- **Hệ điều hành**: Ubuntu
- **Phần cứng**: 16GB RAM, 8 lõi CPU, 50-200GB SSD
- **Mạng**: Cổng 3005, 3006 (TCP/UDP) mở
- **Quyền**: Root hoặc `sudo`

## Cài đặt
Chạy lệnh sau để tải và cài đặt:
```bash
curl -O https://raw.githubusercontent.com/laodauhgc/bash-scripts/main/nockchain/install_nockchain.sh && chmod +x install_nockchain.sh && ./install_nockchain.sh
```

### Tùy chọn
- `-m`: Chạy ở chế độ menu để chọn từng bước.
- Ví dụ: `./install_nockchain.sh -m`

## Kiểm tra
- **Trạng thái dịch vụ**:
  ```bash
  sudo systemctl status nockchaind
  ```
- **Log**:
  ```bash
  journalctl -u nockchaind -f
  ```
- **Ví**:
  ```bash
  cat ~/nockchain/wallet_output.txt
  ```
- **Sao lưu**:
  ```bash
  ls -l ~/nockchain_backup
  ```
  - Lưu `~/nockchain_backup/wallet_output.txt` và `keys.export` an toàn.

## Lưu ý
- **Cổng**: Đảm bảo cổng 3005, 3006 (TCP/UDP) mở:
  ```bash
  sudo ufw status
  ```
- **Hỗ trợ**: [Telegram](https://t.me/nockchainproject), [GitHub](https://github.com/zorp-corp/nockchain)
- **Sao lưu ví**: Giữ `~/nockchain_backup/*` an toàn, chứa khóa riêng.
