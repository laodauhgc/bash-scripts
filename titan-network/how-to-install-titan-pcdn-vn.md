# 🚀 Hướng Dẫn Triển Khai **Titan PCDN** - **Galileo Testnet** 🧪

**Mô tả:** Giải pháp từ cộng đồng **Titan Network**, dựa trên tài liệu chính thức, triển khai đơn giản, quản lý dễ dàng và vượt qua cấu hình **NAT**.

**Tài liệu chính thức:** [https://titannet.gitbook.io/titan-network-en/galileo-testnet/participation-guide](https://titannet.gitbook.io/titan-network-en/galileo-testnet/participation-guide) 📚

**🌍 Khu vực có thể triển khai:**

*   **North America:** Mexico, Canada 🇲🇽🇨🇦
*   **South America:** Argentina, Peru, Colombia, Chile, Ecuador 🇦🇷🇵🇪🇨🇴🇨🇱🇪🇨
*   **Middle East & Africa:** Pakistan, Saudi Arabia, Iraq, Türkiye, Egypt, Algeria, South Africa 🇵🇰🇸🇦🇮🇶🇹🇷🇪🇬🇩🇿🇿🇦
*   **Asia:** Vietnam, Indonesia, India 🇻🇳🇮🇩🇮🇳

**⚙️ Yêu cầu về thiết bị:**

*   **System OS:** Linux - Ubuntu 22.04 🐧
*   **CPU:** 2-4 vcpu 💻
*   **RAM:** 4-8 Gb RAM 💾
*   **SSD:** 50-250Gb 💽
*   **Bandwidth:** 20-100Mbps 📶
*   **Network/IP:** Public IP - No NAT 🌐

## 🔑 Hướng dẫn lấy **ACCESS TOKEN** để sử dụng **Bash Shell**

**Bước 1:** 📝

*   Đăng ký ref TNT 4 tại đây: [https://test4.titannet.io/Invitelogin?code=RjJJwA](https://test4.titannet.io/Invitelogin?code=RjJJwA)
*   Hoặc nhập mã mời tại trang Dashboard TNT4: `RjJJwA`

**Bước 2:** ✉️

*   Gửi **KEY** và địa chỉ ví **Titan Network** (**Kelpr Wallet**) đến Telegram: [@LaoDauTg](https://t.me/LaoDauTg) để nhận `[ACCESS_TOKEN]`

**Bước 3:** ⚙️

*   Cài đặt theo hướng dẫn bên dưới.

## 🛠️ Hướng dẫn cài đặt **Titan PCDN**

1.  **Update & Upgrade APT** 🔄

    ```bash
    apt update && apt upgrade
    ```

2.  **Bật Cgroups v1** - Sẽ khởi động lại VM ⚠️

    ```bash
    curl -fsSL https://raw.githubusercontent.com/vinatechpro/titan-install/refs/heads/main/agent/enable-cgroups-v1.sh | bash
    ```

3.  **Cài đặt titan-pcdn** (thay thế `[ACCESS_TOKEN]` của bạn trong câu lệnh) ⬇️

    ```bash
    wget -O titan-pcdn.sh https://raw.githubusercontent.com/laodauhgc/bash-scripts/refs/heads/main/titan-network/titan-pcdn.sh && chmod +x titan-pcdn.sh && sudo ./titan-pcdn.sh [ACCESS_TOKEN]
    ```

## ⚙️ Hướng dẫn quản lý **titan-pcdn**

*   **Xem logs:** 🪵

    ```bash
    cd ~/titan-pcdn && docker compose logs -f
    ```

*   **Xóa node - gỡ cài đặt:** 🗑️

    ```bash
    cd ~/titan-pcdn && docker compose down && cd .. && rm -rf titan-pcdn && docker rmi laodauhgc/titan-pcdn
    ```

**📌 Ghi chú:**

*   **ACCESS TOKEN** là bắt buộc. Không giới hạn số nodes cài đặt.
*   **ACCESS TOKEN** sẽ liên kết đến **KEY** của bạn, không thể thay thế cho **KEY** khác. Nếu muốn đăng ký **KEY** khác, vui lòng quay lại **Bước 1**.
