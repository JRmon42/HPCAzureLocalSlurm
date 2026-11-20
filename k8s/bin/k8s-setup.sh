#!/usr/bin/env bash
# Configures an Azure Local VM as the POC Kubernetes cluster that stands in for AKS on Azure Local:
#   k3s + Kueue + simulated GPUs (nvidia.com/gpu advertised on the node) + OCR queue + night window,
# and writes the kubeconfigs consumed by the Slurm gateway.
# Production: AKS on Azure Local + NVIDIA GPU Operator replace k3s and the simulated GPUs (docs/09).
#
# Env: BUNDLE_DIR, CONTROLLER_IP, K8S_IP, SIM_GPUS (default 8), GPU_MODEL, KUEUE_VERSION
set -euo pipefail
BUNDLE_DIR="${BUNDLE_DIR:-/tmp/k8s-bundle}"
CONTROLLER_IP="${CONTROLLER_IP:?}"
K8S_IP="${K8S_IP:?}"
SIM_GPUS="${SIM_GPUS:-8}"
GPU_MODEL="${GPU_MODEL:-rtx6000}"
KUEUE_VERSION="${KUEUE_VERSION:-}"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Long-lived VM: keep the static IP written at first boot (see controller-setup.sh)
echo "==> Freezing the network configuration"
echo 'network: {config: disabled}' >/etc/cloud/cloud.cfg.d/99-azlocal-keep-network.cfg

echo "==> /shared (NFS from the Slurm controller)"
apt-get install -y -q nfs-common >/dev/null 2>&1 || true
mkdir -p /shared
grep -q " /shared " /etc/fstab || echo "$CONTROLLER_IP:/shared /shared nfs defaults,_netdev,nofail 0 0" >>/etc/fstab
mountpoint -q /shared || mount /shared
mkdir -p /var/lib/models

echo "==> k3s"
if ! command -v k3s >/dev/null; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --disable traefik --disable servicelb --write-kubeconfig-mode 644 --tls-san $K8S_IP --node-label gpu.azlocal/model=$GPU_MODEL" sh -
fi
for _ in $(seq 1 60); do kubectl get nodes 2>/dev/null | grep -q ' Ready' && break; sleep 5; done
kubectl get nodes

echo "==> Simulated GPUs: $SIM_GPUS x nvidia.com/gpu on $(hostname -s)"
kubectl patch node "$(hostname -s)" --subresource=status --type=merge \
  -p "{\"status\":{\"capacity\":{\"nvidia.com/gpu\":\"$SIM_GPUS\"},\"allocatable\":{\"nvidia.com/gpu\":\"$SIM_GPUS\"}}}" >/dev/null

echo "==> Kueue"
if [[ -z "$KUEUE_VERSION" ]]; then
  KUEUE_VERSION="$(curl -fsSL https://api.github.com/repos/kubernetes-sigs/kueue/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+')"
fi
echo "Kueue $KUEUE_VERSION"
kubectl apply --server-side -f "https://github.com/kubernetes-sigs/kueue/releases/download/$KUEUE_VERSION/manifests.yaml" >/dev/null
kubectl -n kueue-system wait deploy/kueue-controller-manager --for=condition=available --timeout=300s
kubectl wait --for=condition=Established crd/clusterqueues.kueue.x-k8s.io crd/localqueues.kueue.x-k8s.io crd/resourceflavors.kueue.x-k8s.io --timeout=120s
# The webhook needs a moment before the first Kueue object is accepted
for _ in $(seq 1 30); do
  kubectl apply -f "$BUNDLE_DIR/kueue-ocr.yaml" >/dev/null 2>&1 && break
  sleep 10
done
kubectl apply -f "$BUNDLE_DIR/kueue-ocr.yaml"
kubectl apply -f "$BUNDLE_DIR/ocr-window.yaml"

echo "==> Shared OCR folders and the pod script"
mkdir -p /shared/ocr/bin /shared/ocr/in /shared/ocr/out /shared/k8s
install -m 0755 "$BUNDLE_DIR/qwen-ocr.sh" /shared/ocr/bin/qwen-ocr.sh

echo "==> Kubeconfigs for the Slurm gateway"
CA_B64="$(base64 -w0 /var/lib/rancher/k3s/server/tls/server-ca.crt)"
for _ in $(seq 1 30); do
  TOKEN="$(kubectl -n ocr get secret slurm-gateway-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
  [[ -n "$TOKEN" ]] && break; sleep 2
done
[[ -n "$TOKEN" ]] || { echo "service account token not issued"; exit 1; }
cat >/shared/k8s/hpcuser.kubeconfig <<EOF
apiVersion: v1
kind: Config
clusters:
- name: azlocal-k8s
  cluster: {server: "https://$K8S_IP:6443", certificate-authority-data: $CA_B64}
users:
- name: slurm-gateway
  user: {token: $TOKEN}
contexts:
- name: ocr
  context: {cluster: azlocal-k8s, user: slurm-gateway, namespace: ocr}
current-context: ocr
EOF
chown hpcuser:hpcuser /shared/k8s/hpcuser.kubeconfig && chmod 0600 /shared/k8s/hpcuser.kubeconfig
# Cluster-admin kubeconfig for the operator (root only)
sed "s|https://127.0.0.1:6443|https://$K8S_IP:6443|" /etc/rancher/k3s/k3s.yaml >/shared/k8s/admin.kubeconfig
chown root:root /shared/k8s/admin.kubeconfig && chmod 0600 /shared/k8s/admin.kubeconfig

echo "==> Pre-pulling the llama.cpp image"
k3s ctr images pull ghcr.io/ggml-org/llama.cpp:full >/dev/null 2>&1 || echo "(pre-pull skipped)"
k3s ctr images pull registry.k8s.io/kubectl:v1.31.0 >/dev/null 2>&1 || true

kubectl get clusterqueue,localqueue -A
kubectl get node "$(hostname -s)" -o jsonpath='{.status.allocatable}'; echo
echo "K8S-SETUP-DONE"
