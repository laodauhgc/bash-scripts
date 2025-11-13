## Nockpool - CPU

Nockpool Install
```
curl -sSL https://raw.githubusercontent.com/laodauhgc/bash-scripts/refs/heads/main/nockchain/nockpool.sh | sudo bash -s -- ACCOUNT_TOKEN
```
Nockpool Status
```
systemctl status nockpool.service
```
Nockpool Logs
```
journalctl -u nockpool.service -f
```
Nockpool Stop
```
systemctl stop nockpool.service
```
Nockpool Remove
```
sudo systemctl disable --now nockpool.service && sudo rm -rf /opt/nockpool /etc/systemd/system/nockpool.service && sudo systemctl daemon-reload
```
## Nockpool - GPU
```
curl -sSL https://raw.githubusercontent.com/laodauhgc/bash-scripts/refs/heads/main/nockchain/nockpool_docker.sh | sudo bash -s -- ACCOUNT_TOKEN
```
