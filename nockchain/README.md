# Tập lệnh Cài đặt Nockchain

Tập lệnh Bash tự động cài đặt node Nockchain trên Linux VPS hoặc WSL, chạy dưới dạng dịch vụ `nockchaind`.

## Yêu cầu
- Hệ điều hành: Ubuntu (hoặc WSL trên Windows)
- Phần cứng: 16GB RAM, 6 lõi CPU, 50-200GB SSD
- Mạng: Cổng 3005, 3006 mở
- Quyền: Root hoặc `sudo`

## Cài đặt

Chạy lệnh sau để tải và cài đặt:
```bash
curl -O https://raw.githubusercontent.com/laodauhgc/bash-scripts/main/nockchain/install_nockchain.sh && chmod +x install_nockchain.sh && ./install_nockchain.sh
```

### Tùy chọn
- Thêm `--node-type follower` để chạy node follower.
- Thêm `--mining-pubkey <khóa>` để cấu hình khóa khai thác.
- Ví dụ: `./install_nockchain.sh --node-type follower --mining-pubkey 0x1234567890abcdef`

## Kiểm tra
- Trạng thái: `sudo systemctl status nockchaind`
- Log: `journalctl -u nockchaind -f`
- Ví: Kiểm tra `~/nockchain/wallet_output.txt` (sao lưu an toàn)

## Lưu ý
- Nếu gặp lỗi, kiểm tra log hoặc liên hệ [Telegram](https://t.me/nockchainproject) hoặc [GitHub](https://github.com/zorp-corp/nockchain).
- Cập nhật node: `sudo systemctl stop nockchaind && cd ~/nockchain && git pull origin main && make build-hoon-all && make build && sudo systemctl start nockchaind`
