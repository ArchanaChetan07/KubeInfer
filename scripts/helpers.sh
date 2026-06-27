#!/bin/bash
# scripts/helpers.sh
# Day-two operations toolkit.
# Source this file or call functions individually.
#
# Usage: bash scripts/helpers.sh <command> [args]
# Run without args to see all commands.

set -euo pipefail

NAMESPACE="llm-inference"
RELEASE="vllm-stack"
HELM_CHART="helm/vllm-stack"

log()  { echo -e "\n\033[1;36m==> $1\033[0m"; }
ok()   { echo -e "\033[1;32m✓ $1\033[0m"; }
warn() { echo -e "\033[1;33m⚠ $1\033[0m"; }
err()  { echo -e "\033[1;31m✗ $1\033[0m"; exit 1; }

# ---------------------------------------------------------------------------
# STATUS: show overall platform health
# ---------------------------------------------------------------------------
status() {
  log "Platform status"
  echo ""
  echo "── Pods ─────────────────────────────────────────────────────────"
  kubectl get pods -n "$NAMESPACE" -o wide
  echo ""
  echo "── Services (external IPs) ──────────────────────────────────────"
  kubectl get svc -n "$NAMESPACE"
  echo ""
  echo "── HPA ──────────────────────────────────────────────────────────"
  kubectl get hpa -n "$NAMESPACE"
  echo ""
  echo "── PDB ──────────────────────────────────────────────────────────"
  kubectl get pdb -n "$NAMESPACE"
  echo ""
  echo "── GPU resources ────────────────────────────────────────────────"
  kubectl get nodes -o custom-columns=\
'NAME:.metadata.name,GPU_ALLOCATABLE:.status.allocatable.nvidia\.com/gpu,GPU_CAPACITY:.status.capacity.nvidia\.com/gpu'
}

# ---------------------------------------------------------------------------
# LOGS: tail engine pod logs
# ---------------------------------------------------------------------------
logs() {
  local pod="${1:-}"
  if [ -n "$pod" ]; then
    kubectl logs "$pod" -n "$NAMESPACE" -f --tail=100
  else
    kubectl logs -l app.kubernetes.io/component=engine -n "$NAMESPACE" -f --tail=50
  fi
}

# ---------------------------------------------------------------------------
# SHELL: exec into an engine pod for debugging
# ---------------------------------------------------------------------------
shell() {
  local pod
  pod=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=engine \
    --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
  echo "Connecting to $pod..."
  kubectl exec -it "$pod" -n "$NAMESPACE" -- /bin/bash
}

# ---------------------------------------------------------------------------
# SECRET: create/update HuggingFace token
# ---------------------------------------------------------------------------
hf_token() {
  local token="${1:-}"
  if [ -z "$token" ]; then
    read -rsp "Enter HuggingFace token: " token
    echo ""
  fi
  kubectl create secret generic hf-secret \
    --from-literal=token="$token" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
  ok "HuggingFace secret created/updated"
}

# ---------------------------------------------------------------------------
# DEPLOY: deploy a specific environment
# ---------------------------------------------------------------------------
deploy() {
  local env="${1:-dev}"
  local extra_args="${2:-}"
  log "Deploying to $env..."

  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
  helm repo update
  helm dependency build "$HELM_CHART/"

  helm upgrade --install "$RELEASE" "$HELM_CHART" \
    -f "environments/${env}/values.yaml" \
    --namespace "$NAMESPACE" \
    --create-namespace \
    --atomic \
    --timeout 20m \
    $extra_args

  ok "Deploy to $env complete"
  bash scripts/smoke-test.sh "$env"
}

# ---------------------------------------------------------------------------
# ROLLBACK: roll back to the previous Helm release
# ---------------------------------------------------------------------------
rollback() {
  warn "Rolling back $RELEASE in $NAMESPACE..."
  helm rollback "$RELEASE" --namespace "$NAMESPACE" --wait
  ok "Rollback complete"
}

# ---------------------------------------------------------------------------
# SCALE: manually scale engine replicas (bypasses HPA temporarily)
# ---------------------------------------------------------------------------
scale() {
  local replicas="${1:-}"
  if [ -z "$replicas" ]; then
    err "Usage: $0 scale <replicas>"
  fi
  warn "Scaling to $replicas replicas. HPA will resume control once metric is below threshold."
  kubectl scale deployment/${RELEASE}-engine -n "$NAMESPACE" --replicas="$replicas"
  ok "Scaled to $replicas replicas"
}

# ---------------------------------------------------------------------------
# METRICS: show key vLLM metrics from Prometheus
# ---------------------------------------------------------------------------
metrics() {
  local ip
  ip=$(kubectl get svc -n monitoring prometheus-kube-prometheus-prometheus \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "localhost")

  if [ "$ip" = "localhost" ]; then
    kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n monitoring &>/dev/null &
    PF_PID=$!
    sleep 2
  fi

  echo "── vLLM Metrics ──────────────────────────────────────────"
  for metric in \
    "vllm:num_requests_running" \
    "vllm:num_requests_waiting" \
    "vllm:gpu_cache_usage_perc" \
    "vllm:num_preemption_total"; do
    local val
    val=$(curl -s "http://localhost:9090/api/v1/query?query=${metric}" \
      | python3 -c "import sys,json; d=json.load(sys.stdin); r=d.get('data',{}).get('result',[]); print(r[0]['value'][1] if r else 'N/A')" 2>/dev/null || echo "N/A")
    printf "  %-40s %s\n" "$metric" "$val"
  done

  kill "$PF_PID" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# GPU STATUS: node-level GPU visibility
# ---------------------------------------------------------------------------
gpu_status() {
  log "GPU status across all nodes"
  kubectl get nodes -o custom-columns=\
'NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu,VERSION:.status.nodeInfo.kubeletVersion'
  echo ""
  log "GPU pods currently scheduled"
  kubectl get pods -A -o wide \
    --field-selector=status.phase=Running \
    | grep -E "nvidia|vllm|gpu" || echo "(none)"
}

# ---------------------------------------------------------------------------
# SMOKE: run smoke tests against an environment
# ---------------------------------------------------------------------------
smoke() {
  bash scripts/smoke-test.sh "${1:-dev}"
}

# ---------------------------------------------------------------------------
# Router
# ---------------------------------------------------------------------------
print_usage() {
  echo "LLM Inference Platform — Day-2 Operations Toolkit"
  echo ""
  echo "Usage: bash scripts/helpers.sh <command> [args]"
  echo ""
  echo "Commands:"
  echo "  status              Show full platform health overview"
  echo "  logs [pod]          Tail engine pod logs"
  echo "  shell               Exec into a running engine pod"
  echo "  hf_token [token]    Create/update HuggingFace API token secret"
  echo "  deploy <env>        Deploy to dev|staging|prod"
  echo "  rollback            Roll back to previous Helm release"
  echo "  scale <n>           Manually scale engine to N replicas"
  echo "  metrics             Print key vLLM metrics from Prometheus"
  echo "  gpu_status          Show GPU availability across nodes"
  echo "  smoke [env]         Run post-deploy smoke tests"
}

case "${1:-help}" in
  status)     status ;;
  logs)       logs "${2:-}" ;;
  shell)      shell ;;
  hf_token)   hf_token "${2:-}" ;;
  deploy)     deploy "${2:-dev}" "${3:-}" ;;
  rollback)   rollback ;;
  scale)      scale "${2:-}" ;;
  metrics)    metrics ;;
  gpu_status) gpu_status ;;
  smoke)      smoke "${2:-dev}" ;;
  *)          print_usage ;;
esac
