#!/bin/bash

# Kiểm tra xem user có phải là root hay không
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run with root privileges."
   exit 1
fi

# Hàm kiểm tra xem lệnh có thành công không
check_command() {
  if [[ $? -ne 0 ]]; then
    echo "Command '$1' failed."
    exit 1
  fi
}

# Lấy key từ tham số hoặc yêu cầu nhập
while [[ $# -gt 0 ]]; do
  case "$1" in
    --key=*)
      KEY="${1#--key=}"
      shift
      ;;
    *)
      echo "Invalid parameter: $1"
      echo "Usage: ./install-agent.sh --key=<key>"
      exit 1
      ;;
  esac
done

if [ -z "$KEY" ]; then
  echo "No key provided. Please provide a key using --key=<your_key>"
  exit 1
fi

# Kiểm tra xem Snap đã được cài đặt chưa
echo "Checking Snap..."
if snap --version &> /dev/null; then
  echo "Snap is already installed."
else
  echo "Snap is not installed, proceeding with installation..."
  if command -v apt &> /dev/null; then
    echo "System is Debian/Ubuntu."
    apt update
    check_command "apt update"
    apt install -y snapd
    check_command "apt install -y snapd"
  elif command -v dnf &> /dev/null; then
    echo "System is Fedora."
    dnf install -y snapd
    check_command "dnf install -y snapd"
  elif command -v yum &> /dev/null; then
    echo "System is CentOS/RHEL."
    yum install -y snapd
    check_command "yum install -y snapd"
  else
    echo "System is not supported. Cannot install Snap automatically."
    exit 1
  fi
  systemctl enable --now snapd.socket
  check_command "systemctl enable --now snapd.socket"
  echo "Snap has been successfully installed."
fi

# Cài đặt Multipass
echo "Installing Multipass..."
snap install multipass
check_command "snap install multipass"
echo "Multipass has been installed."

# Kiểm tra Multipass
echo "Checking Multipass..."
multipass --version
check_command "multipass --version"
echo "Multipass is ready."

# Tải và giải nén Titan Agent
echo "Downloading and extracting Titan Agent..."
wget https://pcdn.titannet.io/test4/bin/agent-linux.zip
check_command "wget https://pcdn.titannet.io/test4/bin/agent-linux.zip"
mkdir -p /root/titanagent
check_command "mkdir -p /root/titanagent"

# Kiểm tra và cài đặt unzip
if ! command -v unzip &> /dev/null; then
    if command -v apt &> /dev/null; then
        apt update
        check_command "apt update"
        apt install -y unzip
        check_command "apt install -y unzip"
    elif command -v dnf &> /dev/null; then
        dnf install -y unzip
        check_command "dnf install -y unzip"
    elif command -v yum &> /dev/null; then
        yum install -y unzip
        check_command "yum install -y unzip"
    else
        echo "System does not support automatic unzip installation, please install manually."
        exit 1
    fi
fi

unzip agent-linux.zip -d /usr/local
check_command "unzip agent-linux.zip -d /usr/local"

# Make the agent executable and move to /usr/local/bin
sudo chmod +x /usr/local/agent
check_command "chmod +x /usr/local/agent"
sudo cp /usr/local/agent /usr/local/bin/
check_command "cp /usr/local/agent /usr/local/bin/"

echo "Titan Agent has been downloaded and extracted."

# Lấy tên người dùng hiện tại
USER=$(whoami)

# Tạo file service systemd
echo "Creating systemd service file..."
cat <<EOF | sudo tee /etc/systemd/system/titanagent.service
[Unit]
Description=Titan Agent
After=network.target

[Service]
WorkingDirectory=/root/titanagent
ExecStart=/usr/local/bin/agent --working-dir=/root/titanagent --server-url=https://test4-api.titannet.io --key="$KEY"
Restart=on-failure
User=$USER
Group=$USER

[Install]
WantedBy=multi-user.target
EOF
check_command "Creating systemd service file"

# Kích hoạt service
echo "Enabling systemd service..."
sudo systemctl enable titanagent
check_command "sudo systemctl enable titanagent"

# Khởi động service
echo "Starting systemd service..."
sudo systemctl start titanagent
check_command "sudo systemctl start titanagent"

# Kiểm tra trạng thái service
echo "Checking systemd service status..."
sudo systemctl status titanagent
check_command "sudo systemctl status titanagent"
echo "Titan Agent has been installed and started as a systemd service."

echo "Installation and running of Titan Agent is completed."
