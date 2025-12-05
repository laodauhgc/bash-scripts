# 🚀 Harbor Registry + Cloudflare Tunnel — Auto Installer

Triển khai **Harbor (Docker Registry UI)** trên Ubuntu và **ẩn hoàn toàn IP máy chủ** qua **Cloudflare Tunnel** — bảo mật hơn, không cần mở cổng 80/443, vẫn push/pull Docker mượt mà.

---

## ✨ Tính năng

* Cài đặt **Harbor** tự động (Docker-based).
* **Không cần HTTPS trên server** — Cloudflare Tunnel xử lý SSL.
* **Ẩn toàn bộ IP máy chủ** khỏi internet.
* **Tự tạo DNS** trên Cloudflare:
  `harbor.example.com → <tunnel-id>.cfargotunnel.com`
* Cấu hình **cloudflared** chạy như **systemd service**.
* Tùy chọn bật **UFW** để chặn truy cập trực tiếp qua IP.
* Hỗ trợ **Ubuntu 22.04 / 24.04**.

---

## 📌 Yêu cầu

### 1) Máy chủ Ubuntu

* Ubuntu 22.04 hoặc 24.04
* Quyền `root` hoặc `sudo`
* Kết nối internet ổn định

### 2) Domain / subdomain

* Ví dụ: `harbor.example.com`
* Domain **được quản lý DNS bởi Cloudflare** (đã trỏ nameserver)

### 3) Tài khoản Cloudflare

* Đang đăng nhập trên trình duyệt
* Có quyền quản lý DNS cho domain

---

## 📥 Tải script

**Repo script:**
`https://github.com/laodauhgc/bash-scripts/blob/main/harbor/install_harbor_tunnel.sh`

**Raw (khuyên dùng với curl):**
`https://raw.githubusercontent.com/laodauhgc/bash-scripts/refs/heads/main/harbor/install_harbor_tunnel.sh`

Tải & cấp quyền chạy:

```bash
curl -O https://raw.githubusercontent.com/laodauhgc/bash-scripts/refs/heads/main/harbor/install_harbor_tunnel.sh
chmod +x install_harbor_tunnel.sh
```

---

## ▶️ Cài đặt

```bash
sudo ./install_harbor_tunnel.sh
```

Script sẽ hỏi các thông tin:

| Câu hỏi               | Ý nghĩa                | Mặc định             |
| --------------------- | ---------------------- | -------------------- |
| Hostname Harbor       | Domain truy cập Harbor | `harbor.example.com` |
| Mật khẩu admin Harbor | Dùng để đăng nhập UI   | —                    |
| Version Harbor        | Phiên bản Harbor       | `v2.11.0`            |
| Tunnel name           | Tên Cloudflare Tunnel  | `harbor-tunnel`      |
| Installation dir      | Thư mục cài đặt Harbor | `/opt/harbor`        |

---

## 🔐 Xác thực Cloudflare Tunnel

Script sẽ dừng tại lệnh:

```bash
cloudflared tunnel login
```

Thao tác:

1. Copy URL hiển thị → mở trong trình duyệt.
2. Chọn domain của bạn → xác nhận.

Cloudflare sẽ sinh file credential tại:

```
/root/.cloudflared/<UUID>.json
```

Sau đó script tự động:

* tạo tunnel
* cấu hình DNS
* ghi `/etc/cloudflared/config.yml`
* khởi động **cloudflared** (systemd)
* hoàn tất setup Harbor

---

## 🌐 Truy cập Harbor

Mở trình duyệt:

```
https://harbor.example.com
```

Đăng nhập:

```
username: admin
password: (mật khẩu bạn đã nhập)
```

---

## 🐳 Kiểm thử Docker Push/Pull

1. Tạo **project** trong UI Harbor (ví dụ: `demo`).
2. Login Docker:

```bash
docker login harbor.example.com
```

3. Push image:

```bash
docker pull alpine:latest
docker tag alpine:latest harbor.example.com/demo/alpine:latest
docker push harbor.example.com/demo/alpine:latest
```

Nếu thấy log `Pushed` → thành công 🎉

---

## 🔥 Bảo mật nâng cao (UFW)

Khi được hỏi, chọn **Yes** để bật firewall:

* **Allow:** SSH
* **Deny:** 80, 443 từ internet
* **Cloudflare Tunnel** vẫn hoạt động (chỉ cần outbound)

Lợi ích:

* ✔ **Ẩn IP hoàn toàn**
* ✔ Tránh bị scan/đánh thẳng vào IP máy chủ

---

## 📁 Cấu trúc sau cài đặt

```
/opt/harbor/
 ├── harbor.yml
 ├── docker-compose.yml
 ├── install.sh
 └── common/

~/.cloudflared/
 └── <UUID>.json

/etc/cloudflared/config.yml
```

---

## 🛠 Troubleshooting

### ❌ Không truy cập được domain?

* Chờ 1–2 phút để DNS Cloudflare cập nhật.
* Kiểm tra dịch vụ:

```bash
systemctl status cloudflared
docker ps
```

### ❌ Docker push báo `unauthorized`?

* Cấp quyền cho user:
  UI Harbor → **Projects** → `demo` → **Members** → **Add Member** → Role: **Developer**

### ❌ DNS cho Tunnel không tự tạo?

* Tạo lại thủ công:

```bash
cloudflared tunnel route dns <tunnel-name> harbor.example.com
```

---

## 🤝 Đóng góp

Mở issue hoặc tạo Pull Request tại repo:
`https://github.com/laodauhgc/bash-scripts`

---

## 📄 License

**MIT License**
