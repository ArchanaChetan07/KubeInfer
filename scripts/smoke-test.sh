#!/bin/bash
# scripts/smoke-test.sh
# Post-deploy smoke tests. Run after every Helm deploy.
# Exits non-zero if any test fails (CI will catch this).
#
# Usage:
#   bash scripts/smoke-test.sh dev
#   bash scripts/smoke-test.sh staging
#   bash scripts/smoke-test.sh prod

set -euo pipefail

ENV="${1:-dev}"
NAMESPACE="llm-inference"
TIMEOUT=300   # seconds to wait for pods to be ready

log()  { echo -e "\n\033[1;36m==> $1\033[0m"; }
pass() { echo -e "  \033[1;32m[PASS]\033[0m $1"; }
fail() { echo -e "  \033[1;31m[FAIL]\033[0m $1"; FAILURES=$((FAILURES+1)); }

FAILURES=0

# ---------------------------------------------------------------------------
log "1. Waiting for engine pods to be ready..."
# ---------------------------------------------------------------------------
if kubectl rollout status deployment/vllm-stack-engine \
    -n "$NAMESPACE" \
    --timeout="${TIMEOUT}s" 2>/dev/null; then
  pass "Engine deployment is ready"
else
  fail "Engine deployment did not become ready within ${TIMEOUT}s"
fi

# ---------------------------------------------------------------------------
log "2. Verifying pod health (no crash loops)..."
# ---------------------------------------------------------------------------
RESTART_COUNT=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=engine \
  -o jsonpath='{.items[*].status.containerStatuses[*].restartCount}' \
  | tr ' ' '\n' | awk '{s+=$1} END {print s+0}')

if [ "$RESTART_COUNT" -lt 3 ]; then
  pass "Engine pods have < 3 restarts total (current: $RESTART_COUNT)"
else
  fail "Engine pods have $RESTART_COUNT total restarts — check for crash loops"
fi

# ---------------------------------------------------------------------------
log "3. Getting external IP for API test..."
# ---------------------------------------------------------------------------
# Determine base URL based on environment
if [ "$ENV" = "dev" ]; then
  EXTERNAL_IP=$(kubectl get svc vllm-stack-engine \
    -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  API_URL="http://${EXTERNAL_IP}:8000"
else
  EXTERNAL_IP=$(kubectl get svc vllm-stack-router \
    -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  API_URL="http://${EXTERNAL_IP}:8000"
fi

if [ -z "$EXTERNAL_IP" ]; then
  fail "Could not determine external IP — LoadBalancer may still be provisioning"
  echo "  Try: kubectl get svc -n $NAMESPACE"
  FAILURES=$((FAILURES+1))
  # Fall through to kubectl port-forward as fallback
  kubectl port-forward svc/vllm-stack-engine 8000:8000 -n "$NAMESPACE" &>/dev/null &
  PF_PID=$!
  sleep 3
  API_URL="http://localhost:8000"
fi

# ---------------------------------------------------------------------------
log "4. Health check endpoint..."
# ---------------------------------------------------------------------------
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "${API_URL}/health" || echo "000")
if [ "$HTTP_STATUS" = "200" ]; then
  pass "/health → HTTP 200"
else
  fail "/health → HTTP ${HTTP_STATUS} (expected 200)"
fi

# ---------------------------------------------------------------------------
log "5. Models endpoint (OpenAI-compatible)..."
# ---------------------------------------------------------------------------
MODELS_RESPONSE=$(curl -s --connect-timeout 10 "${API_URL}/v1/models" || echo "{}")
MODEL_COUNT=$(echo "$MODELS_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data',[])))" 2>/dev/null || echo "0")

if [ "$MODEL_COUNT" -gt 0 ]; then
  MODEL_NAME=$(echo "$MODELS_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'])" 2>/dev/null || echo "unknown")
  pass "/v1/models → $MODEL_COUNT model(s) available (first: $MODEL_NAME)"
else
  fail "/v1/models → no models returned"
fi

# ---------------------------------------------------------------------------
log "6. Chat completion (end-to-end inference test)..."
# ---------------------------------------------------------------------------
if [ "$MODEL_COUNT" -gt 0 ]; then
  COMPLETION=$(curl -s --connect-timeout 30 --max-time 60 \
    "${API_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"${MODEL_NAME}\",
      \"messages\": [{\"role\": \"user\", \"content\": \"Reply with exactly: SMOKE_TEST_OK\"}],
      \"max_tokens\": 20,
      \"temperature\": 0
    }" || echo "{}")

  CONTENT=$(echo "$COMPLETION" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('choices',[{}])[0].get('message',{}).get('content','MISSING'))" \
    2>/dev/null || echo "ERROR")

  if echo "$CONTENT" | grep -qi "smoke_test_ok"; then
    pass "Chat completion → got expected response"
  else
    fail "Chat completion → unexpected response: '$CONTENT'"
  fi
else
  fail "Skipping inference test (no models available)"
fi

# ---------------------------------------------------------------------------
log "7. Metrics endpoint (Prometheus scrape target)..."
# ---------------------------------------------------------------------------
METRICS_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "${API_URL}/metrics" || echo "000")
if [ "$METRICS_STATUS" = "200" ]; then
  pass "/metrics → HTTP 200"
else
  fail "/metrics → HTTP ${METRICS_STATUS} (Prometheus scraping will fail)"
fi

# ---------------------------------------------------------------------------
log "8. PodDisruptionBudget check..."
# ---------------------------------------------------------------------------
PDB_EXISTS=$(kubectl get pdb -n "$NAMESPACE" 2>/dev/null | grep -c "vllm" || echo "0")
if [ "$ENV" != "dev" ] && [ "$PDB_EXISTS" -gt 0 ]; then
  pass "PodDisruptionBudget exists in $NAMESPACE"
elif [ "$ENV" = "dev" ]; then
  pass "PDB check skipped (dev environment)"
else
  fail "No PodDisruptionBudget found in $NAMESPACE — production needs one"
fi

# ---------------------------------------------------------------------------
# Kill port-forward if we started one
kill "$PF_PID" 2>/dev/null || true

# ---------------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$FAILURES" -eq 0 ]; then
  echo -e "✅  All smoke tests passed for \033[1m$ENV\033[0m"
else
  echo -e "❌  \033[1;31m$FAILURES test(s) failed\033[0m for $ENV"
  echo "   Review the output above and check kubectl describe for details."
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit $FAILURES
