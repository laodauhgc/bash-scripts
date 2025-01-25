# Auto Instal Titan L2 Edge on Linux - `edge.sh`

## How to Use

Run this command:

```bash
curl -s https://raw.githubusercontent.com/laodauhgc/bash-scripts/refs/heads/main/titan-network/edge.sh | sudo bash -s -- your_hash_value number_of_nodes
```
## Example:
```bash
curl -s https://raw.githubusercontent.com/laodauhgc/bash-scripts/refs/heads/main/titan-network/edge.sh | sudo bash -s -- 36284E4F-5CBE-4D95-994B-90E53D90CA2C 3
```

## Important

*   **Hash:** Required.
*   **Nodes:** 1-5 (default 5), If you don't fill in `number_of_nodes`, it defaults to `5`.
*   **Root:** Requires `sudo`.
