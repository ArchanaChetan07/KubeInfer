#!/bin/bash
# scripts/bootstrap.sh
# One-command cluster bootstrap.
# Installs all dependencies that the Helm chart assumes exist:
#   MicroK8s, cert-manager, NVIDIA GPU Operator, MetalLB,
#   Prometheus Operator (kube-prometheus-stack), nginx-ingress.
#
# Run once per cluster, then use `helm upgrade --install` for app deploys.
# Safe to re-run: all installs are idempotent.
#
# Usage: bash scripts/bootstrap.sh [--skip-microk8s] [--skip-gpu-operator]

set -euo pipefail

SKIP_MICROK8S=false
SKIP_GPU_OPERATOR=false

for arg in "$@"; do
  case "$arg" in
    --skip-microk8s)    SKIP_MICROK8S=true ;;
    --skip-gpu-operator) SKIP_GPU_OPERATOR=true ;;
  esac
done

log() { echo -e "\n\033[1;36m==> $1\033[0m"; }
ok()  { echo -e "\033[1;32m✓ $1\033[0m"; }
err() { echo -e "\033[1;31m✗ $1\033[0m"; exit 1; }

# ---------------------------------------------------------------------------
log "[1/8] MicroK8s"
# ---------------------------------------------------------------------------
if [ "$SKIP_MICROK8S" = "false" ]; then
  sudo apt-get update -q
  sudo apt-get install -y snapd
  sudo snap install microk8s --classic

  sudo usermod -a -G microk8s "$USER"
  mkdir -p ~/.kube && chmod 0700 ~/.kube

  grep -qxF "alias kubectl='microk8s kubectl'" ~/.bashrc \
    || echo "alias kubectl='microk8s kubectl'" >> ~/.bashrc

  grep -qxF "export KUBECONFIG=/var/snap/microk8s/current/credentials/client.config" ~/.bashrc \
    || echo "export KUBECONFIG=/var/snap/microk8s/current/credentials/client.config" >> ~/.bashrc

  export KUBECONFIG=/var/snap/microk8s/current/credentials/client.config
  sudo microk8s status --wait-ready
  microk8s kubectl label node \
    "$(microk8s kubectl get nodes --no-headers | awk '{print $1}')" \
    node-role.kubernetes.io/control-plane='' \
    accelerator=nvidia \
    --overwrite 2>/dev/null || true
  ok "MicroK8s ready"
else
  ok "Skipping MicroK8s (--skip-microk8s)"
fi

# From here, use kubectl (alias or real)
K="kubectl"

# ---------------------------------------------------------------------------
log "[2/8] Helm"
# ---------------------------------------------------------------------------
if ! command -v helm &>/dev/null; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
ok "Helm $(helm version --short)"

# ---------------------------------------------------------------------------
log "[3/8] Helm repos"
# ---------------------------------------------------------------------------
helm repo add jetstack        https://charts.jetstack.io          --force-update
helm repo add nvidia          https://helm.ngc.nvidia.com/nvidia   --force-update
helm repo add metallb         https://metallb.github.io/metallb    --force-update
helm repo add ingress-nginx   https://kubernetes.github.io/ingress-nginx --force-update
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo update
ok "Helm repos updated"

# ---------------------------------------------------------------------------
log "[4/8] cert-manager (TLS certificate automation)"
# ---------------------------------------------------------------------------
if ! $K get namespace cert-manager &>/dev/null; then
  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --version v1.15.1 \
    --set crds.enabled=true \
    --wait
  ok "cert-manager installed"
else
  ok "cert-manager already installed"
fi

# ---------------------------------------------------------------------------
log "[5/8] NVIDIA GPU Operator"
# ---------------------------------------------------------------------------
if [ "$SKIP_GPU_OPERATOR" = "false" ]; then
  if ! $K get namespace gpu-operator &>/dev/null; then
    helm install gpu-operator nvidia/gpu-operator \
      --namespace gpu-operator \
      --create-namespace \
      --set driver.enabled=false \
      --set toolkit.enabled=true \
      --set devicePlugin.enabled=true \
      --set dcgmExporter.enabled=true \
      --set nodeStatusExporter.enabled=true \
      --set validator.enabled=true \
      --wait --timeout 5m
    ok "NVIDIA GPU Operator installed"
  else
    ok "GPU Operator already installed"
  fi
else
  ok "Skipping GPU Operator (--skip-gpu-operator)"
fi

# ---------------------------------------------------------------------------
log "[6/8] MetalLB (bare-metal LoadBalancer)"
# ---------------------------------------------------------------------------
if ! $K get namespace metallb-system &>/dev/null; then
  helm install metallb metallb/metallb \
    --namespace metallb-system \
    --create-namespace \
    --wait
  ok "MetalLB installed"
else
  ok "MetalLB already installed"
fi

# ---------------------------------------------------------------------------
log "[7/8] nginx ingress controller"
# ---------------------------------------------------------------------------
if ! $K get namespace ingress-nginx &>/dev/null; then
  helm install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --create-namespace \
    --set controller.service.type=LoadBalancer \
    --wait
  ok "nginx ingress installed"
else
  ok "nginx ingress already installed"
fi

# ---------------------------------------------------------------------------
log "[8/8] kube-prometheus-stack (Prometheus Operator + Grafana)"
# ---------------------------------------------------------------------------
if ! $K get namespace monitoring &>/dev/null; then
  helm install prometheus prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --create-namespace \
    --set grafana.adminPassword=changeme-in-prod \
    --set grafana.service.type=LoadBalancer \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --set prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false \
    --wait --timeout 10m
  ok "kube-prometheus-stack installed"
else
  ok "Prometheus stack already installed"
fi

# ---------------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅  Bootstrap complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Verify GPU is visible to Kubernetes:"
echo "  kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.capacity.'nvidia\.com/gpu'"
echo ""
echo "Next steps:"
echo "  1. kubectl create secret generic hf-secret --from-literal=token=hf_YOUR_TOKEN -n llm-inference"
echo "  2. Edit environments/dev/values.yaml — set metallb.ipRange to a free subnet range"
echo "  3. helm upgrade --install vllm-stack helm/vllm-stack -f environments/dev/values.yaml -n llm-inference --create-namespace"
echo "  4. bash scripts/smoke-test.sh dev"
