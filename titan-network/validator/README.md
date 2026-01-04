# Titan Validator Recovery Script

This script automates the setup and restoration of a Titan Chain validator node on a new machine. It installs dependencies, restores configuration, unpacks data snapshot, and starts the node via systemd.

## Prerequisites

- **Operating System**: Ubuntu 22.04 LTS or later.
- **User Access**: Run as root (use `sudo su` if needed).
- **Hardware Specs**: At least 16 cores CPU, 16GB RAM, 2TB SSD storage, 100Mbps bandwidth.
- **Backup Preparation**:
  - On the old machine, backup all files and folders in `/root/.titan` except `/root/.titan/wasm` and `/root/.titan/data`.
  - Compress the `/root/.titan/data` folder into a zst file: `cd /root/.titan && tar -cf - data | zstd -T0 -o titan_snapshot.zst` OR Download here.
  - Create a folder `/root/titan_backup` on the new machine and upload:
    - All backed up files/folders (e.g., config, keyhash, *.address, *.info).
    - The `titan_snapshot.zst` file.
  - Structure example:
    ```
    /root/titan_backup/
    ├── config/  (contains config.toml, app.toml, genesis.json, etc.)
    ├── priv_validator_key.json  (if not in config)
    ├── other files (*.address, keyhash, etc.)
    └── titan_snapshot.zst
    ```
- **Internet Access**: For downloading Go, titand binary, and libwasmvm.
- **Important**: It is mandatory to completely stop the Validator before performing Recovery. The stop command is `systemctl stop titan && systemctl disable titan`.

## Installation and Execution

Combined into 1 command to run directly (be careful with security, only use if trust source):
```
wget https://raw.githubusercontent.com/laodauhgc/bash-scripts/refs/heads/main/titan-network/validator/titan-validator-recovery.sh && chmod +x titan-validator-recovery.sh && sudo ./titan-validator-recovery.sh
```
   - The script will prompt for:
     - Backup path (default: /root/titan_backup).
     - Moniker (default: my-monikey).
   - It checks for required files/folders in backup.
   - After running, it displays logs for 3 minutes, then status.
   - Check until `"catching_up": false` in status – synchronization complete.
   - If jailed, unjail with: `titand tx slashing unjail --from="your_wallet_name" --chain-id="titan-test-4" --gas=100000 --fees=50000uttnt`.

## Troubleshooting

- **Script Fails**: Check error messages. Ensure backup structure correct and files intact.
- **Node Not Syncing**: Check `journalctl -u titan -f` for errors.
- **Unjail Fail**: Ensure wallet has funds for fees.
