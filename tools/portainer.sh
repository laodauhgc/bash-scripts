#!/bin/bash

# Các biến
PORTAINER_NAME="portainer"
PORTAINER_IMAGE="portainer/portainer-ce:latest"
PORTAINER_DATA_VOLUME="portainer_data"

# Thay đổi các cổng mặc định
PORTAINER_HTTP_PORT="9001"  # Thay đổi từ 9000
PORTAINER_TCP_PORT="8001"  # Thay đổi từ 8000
PORTAINER_HTTPS_PORT="9444" # Thêm cổng HTTPS và thay đổi từ 9443

# Hàm kiểm tra xem Docker đã được cài đặt chưa
check_docker() {
  if ! command -v docker &> /dev/null
  then
    echo "Docker chưa được cài đặt."
    echo "Vui lòng cài đặt Docker trước khi chạy script này."
    exit 1
  fi
}

# Hàm cài đặt Portainer
install_portainer() {
  echo "Bắt đầu cài đặt Portainer..."

  # Tạo volume nếu chưa tồn tại
  if ! docker volume inspect "$PORTAINER_DATA_VOLUME" &> /dev/null; then
    echo "Tạo volume '$PORTAINER_DATA_VOLUME'..."
    docker volume create "$PORTAINER_DATA_VOLUME"
  else
    echo "Volume '$PORTAINER_DATA_VOLUME' đã tồn tại."
  fi

  # Chạy container Portainer
  echo "Chạy container Portainer..."
  docker run -d \
    -p "$PORTAINER_HTTP_PORT:9000" \
    -p "$PORTAINER_TCP_PORT:8000" \
    -p "$PORTAINER_HTTPS_PORT:9443" \
    --name="$PORTAINER_NAME" \
    --restart=always \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$PORTAINER_DATA_VOLUME:/data" \
    "$PORTAINER_IMAGE"

  # Lấy địa chỉ IP public
  VM_IP=$(curl -s checkip.dyndns.org | sed 's/.*Address: \([0-9\.]*\).*/\1/')

  echo "Portainer đã được cài đặt thành công!"
  echo "Truy cập Portainer tại http://$VM_IP:$PORTAINER_HTTP_PORT"
}

# Hàm gỡ cài đặt Portainer
uninstall_portainer() {
  echo "Bắt đầu gỡ cài đặt Portainer..."

  # Dừng container Portainer
  if docker ps -q -f name="$PORTAINER_NAME" &> /dev/null; then
    echo "Dừng container Portainer..."
    docker stop "$PORTAINER_NAME"
  fi

  # Xóa container Portainer
  if docker ps -aq -f name="$PORTAINER_NAME" &> /dev/null; then
    echo "Xóa container Portainer..."
    docker rm "$PORTAINER_NAME"
  fi

  # Xóa volume Portainer (tùy chọn)
  read -r -p "Bạn có muốn xóa volume '$PORTAINER_DATA_VOLUME' không? (y/n) " response
  if [[ "$response" =~ ^([yY][eE][sS]|[yY]) ]]
  then
    if docker volume inspect "$PORTAINER_DATA_VOLUME" &> /dev/null; then
      echo "Xóa volume '$PORTAINER_DATA_VOLUME'..."
      docker volume rm "$PORTAINER_DATA_VOLUME"
    fi
  else
    echo "Không xóa volume '$PORTAINER_DATA_VOLUME'."
  fi

  echo "Portainer đã được gỡ cài đặt."
}

# Kiểm tra Docker
check_docker

# Xử lý tham số dòng lệnh
if [ "$1" == "rm" ]; then
  uninstall_portainer
else
  install_portainer
fi

exit 0
