# 🚀 Инструкция по развертыванию **Titan PCDN** - **Galileo Testnet** 🧪

**Описание:** Решение от сообщества **Titan Network**, основанное на официальной документации, с простой установкой, легким управлением и обходом конфигураций **NAT**.

**Официальная документация:** [https://titannet.gitbook.io/titan-network-en/galileo-testnet/participation-guide](https://titannet.gitbook.io/titan-network-en/galileo-testnet/participation-guide) 📚

**🌍 Регионы для развертывания:**

*   **Северная Америка:** Мексика, Канада 🇲🇽🇨🇦
*   **Южная Америка:** Аргентина, Перу, Колумбия, Чили, Эквадор 🇦🇷🇵🇪🇨🇴🇨🇱🇪🇨
*   **Ближний Восток и Африка:** Пакистан, Саудовская Аравия, Ирак, Турция, Египет, Алжир, Южная Африка 🇵🇰🇸🇦🇮🇶🇹🇷🇪🇬🇩🇿🇿🇦
*   **Азия:** Вьетнам, Индонезия, Индия 🇻🇳🇮🇩🇮🇳

**⚙️ Требования к оборудованию:**

*   **Операционная система:** Linux - Ubuntu 22.04 🐧
*   **CPU:** 2-4 vcpu 💻
*   **RAM:** 4-8 Gb RAM 💾
*   **SSD:** 50-250Gb 💽
*   **Пропускная способность:** 20-100Mbps 📶
*   **Сеть/IP:** Public IP - No NAT 🌐

## 🔑 Как получить **ACCESS TOKEN** для использования **Bash Shell**

**Шаг 1:** 📝

*   Зарегистрируйте реферальную ссылку TNT 4 здесь: [https://test4.titannet.io/Invitelogin?code=RjJJwA](https://test4.titannet.io/Invitelogin?code=RjJJwA)
*   Или введите код приглашения на панели управления TNT4: `RjJJwA`

**Шаг 2:** ✉️

*   Отправьте свой **KEY** и адрес кошелька **Titan Network** (**Kelpr Wallet**) в Telegram: [@LaoDauTg](https://t.me/LaoDauTg), чтобы получить `[ACCESS_TOKEN]`

**Шаг 3:** ⚙️

*   Следуйте инструкциям по установке ниже.

## 🛠️ Как установить **Titan PCDN**

1.  **Обновить и обновить APT** 🔄

    ```bash
    apt update && apt upgrade
    ```

2.  **Включить Cgroups v1** - Перезагрузит VM ⚠️

    ```bash
    curl -fsSL https://raw.githubusercontent.com/vinatechpro/titan-install/refs/heads/main/agent/enable-cgroups-v1.sh | bash
    ```

3.  **Установите titan-pcdn** (замените `[ACCESS_TOKEN]` на свой собственный) ⬇️

    ```bash
    wget -O titan-pcdn.sh https://raw.githubusercontent.com/laodauhgc/bash-scripts/refs/heads/main/titan-network/titan-pcdn.sh && chmod +x titan-pcdn.sh && sudo ./titan-pcdn.sh [ACCESS_TOKEN]
    ```

## ⚙️ Как управлять **titan-pcdn**

*   **Просмотр журналов:** 🪵

    ```bash
    cd ~/titan-pcdn && docker compose logs -f
    ```

*   **Удалить ноду - Удаление:** 🗑️

    ```bash
    cd ~/titan-pcdn && docker compose down && cd .. && rm -rf titan-pcdn && docker rmi laodauhgc/titan-pcdn
    ```

**📌 Примечания:**

*   **ACCESS TOKEN** является обязательным. Количество устанавливаемых узлов не ограничено.
*   **ACCESS TOKEN** привязан к вашему **KEY** и не может быть заменен другим **KEY**. Если вы хотите зарегистрировать другой **KEY**, пожалуйста, вернитесь к **Шагу 1**.
