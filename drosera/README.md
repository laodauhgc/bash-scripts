# drosera.sh v0.1.0

> 🛠️ Automated installer for Drosera Operator on a VPS

## Quick Start

Chỉ với **một dòng lệnh** (download + thực thi + cài đặt):

```bash
curl -sSL https://raw.githubusercontent.com/laodauhgc/bash-scripts/refs/heads/main/drosera/install.sh -o /root/drosera.sh && chmod +x /root/drosera.sh && sudo /root/drosera.sh --pk YOUR_PRIVATE_KEY
```

> 💧 **Lưu ý**: Bạn cần có ETH Testnet trên mạng Hoodi để thanh toán phí giao dịch. Vui lòng xin từ faucet: [https://hoodi-faucet.pk910.de/](https://hoodi-faucet.pk910.de/)

## Verify

```bash
sudo systemctl status drosera-operator.service
sudo journalctl -u drosera-operator.service -f
```

## Optional Flags

```bash
--rpc <RPC_URL>           Primary RPC endpoint (default: https://1rpc.io/hoodi)
--backup-rpc <BACKUP_URL> Backup RPC endpoint (default: https://ethereum-hoodi-rpc.publicnode.com)
--contract <ADDRESS>      Drosera contract (default: 0x91cB447BaFc6e0EA0F4Fe056F5a9b1F14bb06e5D)
--chain-id <ID>           Chain ID (default: 56048)
--p2p-port <PORT>         P2P port (default: 31313)
--rpc-port <PORT>         RPC/HTTP port (default: 31314)
--db-dir <DIRECTORY>      Data directory (default: /var/lib/drosera-data)
--help                    Show help message
```

---

🚀 **DONE!**

