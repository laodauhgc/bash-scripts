# Nockchain Installation Script

Tập lệnh Bash tự động cài đặt node Nockchain miner trên Ubuntu, sử dụng Systemd để chạy liên tục.

## Yêu cầu
- **Hệ điều hành**: Ubuntu
- **Phần cứng**: 16GB RAM, 8 lõi CPU, 50-200GB SSD
- **Mạng**: Cổng 3005, 3006 (TCP) mở
- **Quyền**: Root hoặc `sudo`

## Cài đặt
Chạy lệnh sau để tải và cài đặt:
```bash
curl -O https://raw.githubusercontent.com/laodauhgc/bash-scripts/main/nockchain/install_nockchain.sh && chmod +x install_nockchain.sh && ./install_nockchain.sh
```

### Tùy chọn
- `--mining-pubkey <khóa>`: Đặt khóa công khai khai thác (khớp với ví).
- Ví dụ: `./install_nockchain.sh --mining-pubkey 3UF4KcSJ...`

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
  cat ~/nockchain_backup/keys.export
  ```
  - Lưu `~/nockchain_backup/*` an toàn.

## Lưu ý
- **Cổng**: Đảm bảo cổng 3005, 3006 mở:
  ```bash
  sudo ufw status
  ```
- **Mainnet**: Chạy trong thư mục sạch (tập lệnh tự xóa `.data.nockchain` nếu có).
- **Hỗ trợ**: [Telegram](https://t.me/nockchainproject), [GitHub](https://github.com/zorp-corp/nockchain)
