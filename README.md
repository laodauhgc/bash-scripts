# Bash Script Auto Install

**System Info**
```
bash <(curl -s https://raw.githubusercontent.com/laodauhgc/bash-scripts/refs/heads/main/cfg.sh)
```
**Titan Edge Install**
```
curl -s https://raw.githubusercontent.com/laodauhgc/bash-scripts/refs/heads/main/titan-network/edge.sh | sudo bash -s -- your_hash_value number_of_nodes
```
**Titan Agent Install**
```
curl -O https://raw.githubusercontent.com/laodauhgc/bash-scripts/refs/heads/main/titan-network/agent.sh && chmod u+x agent.sh && ./agent.sh --key=your_key_here --ver=vi
```
