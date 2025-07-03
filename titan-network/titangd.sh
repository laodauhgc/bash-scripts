#!/bin/bash

# Check and create /titan/storage directory
if [ ! -d "/titan/storage" ]; then
    mkdir -p /titan/storage
    chmod -R 777 /titan/storage
    echo "/titan/storage directory has been created and granted 777 permissions."
else
    echo "/titan/storage directory already exists."
fi

# Install K3s
echo "Starting K3s installation..."
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik" sh -s -
echo "K3s has been installed."

# Configure kubeconfig
echo "Configuring kubeconfig..."
mkdir -p ~/.kube
sudo cat /etc/rancher/k3s/k3s.yaml | tee ~/.kube/config >/dev/null
echo "kubeconfig has been configured."

# Verify K3s installation
echo "Verifying K3s installation..."
kubectl get nodes

# Install Helm
echo "Starting Helm installation..."
wget https://get.helm.sh/helm-v3.11.0-linux-amd64.tar.gz
tar -zxvf helm-v3.11.0-linux-amd64.tar.gz
install linux-amd64/helm /usr/local/bin/helm
echo "Helm has been installed."

# Install Ingress Nginx
echo "Installing Ingress Nginx..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx --create-namespace
echo "Ingress Nginx has been installed."

# Configure StorageClass
echo "Configuring StorageClass..."
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
cat <<EOF > storageclass.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
parameters:
  path: "/titan/storage"
EOF

kubectl apply -f storageclass.yaml
kubectl patch configmap local-path-config -n kube-system --type=json -p='[{"op": "replace", "path": "/data/config.json", "value":"{\n  \"nodePathMap\":[\n  {\n    \"node\":\"DEFAULT_PATH_FOR_NON_LISTED_NODES\",\n    \"paths\":[\"/titan/storage\"]\n  }\n  ]\n}"}]'
echo "StorageClass has been configured."

# Download and install titan-L1 guardian
echo "Downloading titan-L1 guardian..."
wget https://github.com/Titannet-dao/titan-node/releases/download/v0.1.22/titan-l1-guardian
mv titan-l1-guardian /usr/local/bin/
chmod 0755 /usr/local/bin/titan-l1-guardian
echo "titan-L1 guardian has been installed."

# Create systemd file for titan L1 node
echo "Creating systemd file for titan L1 node..."
cat <<EOF > /etc/systemd/system/titand.service
[Unit]
Description=Titan L1 Guardian Node
After=network.target
StartLimitIntervalSec=0

[Service]
User=root
Environment="QUIC_GO_DISABLE_ECN=true"
Environment="TITAN_METADATAPATH=/titan/storage"
Environment="TITAN_ASSETSPATHS=/titan/storage"
ExecStart=titan-l1-guardian daemon start
Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF

echo "Reloading systemd daemon..."
systemctl daemon-reload

# Enable systemd service
echo "Enabling titand.service..."
systemctl enable titand.service
echo "titan L1 service has been enabled."

echo "Environment setup completed!"

echo "***"
echo "You need to copy the backed up .titancandidate directory to /root before starting L1"
echo "After copying, just run the command: systemctl start titand.service"
echo "DONE."
