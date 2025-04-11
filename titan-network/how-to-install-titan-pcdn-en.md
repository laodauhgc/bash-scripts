# 🚀 How to Deploy **Titan PCDN** - **Galileo Testnet** 🧪

**Description:** Community solution from **Titan Network**, based on official documentation, with simple deployment, easy management, and overcomes **NAT** configurations.

**Official Documentation:** [https://titannet.gitbook.io/titan-network-en/galileo-testnet/participation-guide](https://titannet.gitbook.io/titan-network-en/galileo-testnet/participation-guide) 📚

**🌍 Deployable Regions:**

*   **North America:** Mexico, Canada 🇲🇽🇨🇦
*   **South America:** Argentina, Peru, Colombia, Chile, Ecuador 🇦🇷🇵🇪🇨🇴🇨🇱🇪🇨
*   **Middle East & Africa:** Pakistan, Saudi Arabia, Iraq, Türkiye, Egypt, Algeria, South Africa 🇵🇰🇸🇦🇮🇶🇹🇷🇪🇬🇩🇿🇿🇦
*   **Asia:** Vietnam, Indonesia, India 🇻🇳🇮🇩🇮🇳

**⚙️ Device Requirements:**

*   **System OS:** Linux - Ubuntu 22.04 🐧
*   **CPU:** 2-4 vcpu 💻
*   **RAM:** 4-8 Gb RAM 💾
*   **SSD:** 50-250Gb 💽
*   **Bandwidth:** 20-100Mbps 📶
*   **Network/IP:** Public IP - No NAT 🌐

## 🔑 How to get **ACCESS TOKEN** for using **Bash Shell**

**Step 1:** 📝

*   Register TNT 4 ref here: [https://test4.titannet.io/Invitelogin?code=RjJJwA](https://test4.titannet.io/Invitelogin?code=RjJJwA)
*   Or enter the invite code on the TNT4 Dashboard: `RjJJwA`

**Step 2:** ✉️

*   Send your **KEY** and **Titan Network** wallet address (**Kelpr Wallet**) to Telegram: [@LaoDauTg](https://t.me/LaoDauTg) to receive the `[ACCESS_TOKEN]`

**Step 3:** ⚙️

*   Follow the installation guide below.

## 🛠️ How to Install **Titan PCDN**

1.  **Update & Upgrade APT** 🔄

    ```bash
    apt update && apt upgrade
    ```

2.  **Enable Cgroups v1** - Will restart the VM ⚠️

    ```bash
    curl -fsSL https://raw.githubusercontent.com/vinatechpro/titan-install/refs/heads/main/agent/enable-cgroups-v1.sh | bash
    ```

3.  **Install titan-pcdn** (replace `[ACCESS_TOKEN]` with your own) ⬇️

    ```bash
    wget -O titan-pcdn.sh https://raw.githubusercontent.com/laodauhgc/bash-scripts/refs/heads/main/titan-network/titan-pcdn.sh && chmod +x titan-pcdn.sh && sudo ./titan-pcdn.sh [ACCESS_TOKEN]
    ```

## ⚙️ How to Manage **titan-pcdn**

*   **View logs:** 🪵

    ```bash
    cd ~/titan-pcdn && docker compose logs -f
    ```

*   **Remove node - Uninstall:** 🗑️

    ```bash
    cd ~/titan-pcdn && docker compose down && cd .. && rm -rf titan-pcdn && docker rmi laodauhgc/titan-pcdn
    ```

**📌 Notes:**

*   **ACCESS TOKEN** is mandatory. There is no limit to the number of nodes installed.
*   **ACCESS TOKEN** is linked to your **KEY** and cannot be substituted for another **KEY**. If you want to register another **KEY**, please return to **Step 1**.
