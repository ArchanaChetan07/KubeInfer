# On-Call Runbook

This document covers the most common production incidents and how to resolve them.
Keep this open during on-call shifts. All commands assume `kubectl` is configured
for the target cluster and `NAMESPACE=llm-inference`.

---

## Engine Down
**Alert:** `VLLMEngineDown`
**Symptoms:** Users get 502/503. No engine pods are ready.

```bash
# 1. Check pod status
kubectl get pods -n llm-inference -l app.kubernetes.io/component=engine

# 2. Check events (scheduling failures, image pull errors, etc.)
kubectl describe pod <pod-name> -n llm-inference

# 3. Check logs from the last failed pod
kubectl logs <pod-name> -n llm-inference --previous

# 4. Common causes:
#    - OOMKilled: GPU ran out of memory → reduce gpuMemoryUtilization or maxModelLen
#    - ImagePullBackOff: image tag not found or auth issue
#    - Pending: no GPU node available (check node capacity)
#    - CrashLoopBackOff: model loading failed (see crash loop section)

# 5. If a quick restart fixes it:
kubectl rollout restart deployment/vllm-stack-engine -n llm-inference
```

---

## Crash Loop
**Alert:** `VLLMEngineRestartLoop`
**Symptoms:** Engine pod restarts repeatedly. STATUS shows CrashLoopBackOff.

```bash
# Get logs from the CURRENT and PREVIOUS run
kubectl logs <pod-name> -n llm-inference
kubectl logs <pod-name> -n llm-inference --previous

# Common causes:
# "CUDA out of memory" → Lower gpuMemoryUtilization in values.yaml
# "Cannot open model"  → HF token missing or model name wrong
# "killed"             → OOM (OS-level, not CUDA) → increase memory limits
# "Connection refused" → Health probe firing too early → increase startupProbe.failureThreshold

# Check OOM kills
kubectl describe pod <pod-name> -n llm-inference | grep -A5 "Last State"
# Look for: Reason: OOMKilled

# Emergency: scale down to 0 while you fix the issue
kubectl scale deployment/vllm-stack-engine -n llm-inference --replicas=0
# Fix values.yaml, then redeploy
helm upgrade vllm-stack helm/vllm-stack -f environments/prod/values.yaml -n llm-inference
```

---

## High Latency
**Alert:** `VLLMHighTimeToFirstToken`
**Symptoms:** TTFT > 10s. Users complain responses are slow to start.

```bash
# Check queue depth (primary indicator)
kubectl exec -n llm-inference \
  $(kubectl get pods -n llm-inference -l app.kubernetes.io/component=engine -o name | head -1) \
  -- curl -s localhost:8000/metrics \
  | grep "vllm:num_requests_waiting"

# High queue + low KV cache → not enough GPU compute → scale up
kubectl scale deployment/vllm-stack-engine -n llm-inference --replicas=<N>

# High KV cache usage (>90%) → preemption happening → see "KV Cache Full" below

# Check if HPA is stuck
kubectl describe hpa vllm-stack-engine -n llm-inference
# Look for: "unable to compute desired replicas" or "conditions" errors
```

---

## KV Cache Near Full
**Alert:** `VLLMKVCacheNearFull`
**Symptoms:** Cache > 90%. Users see increased latency. Preemption counter rising.

This means vLLM is evicting active requests to fit new ones. Evicted requests get
recomputed from scratch — paying the full prefill cost again.

```bash
# Check cache utilization per pod
kubectl exec -n llm-inference \
  $(kubectl get pods -n llm-inference -l app.kubernetes.io/component=engine -o name | head -1) \
  -- curl -s localhost:8000/metrics \
  | grep -E "gpu_cache|num_preemption"

# Mitigations (pick one):
# 1. Reduce max-num-seqs (limits concurrent requests per engine)
helm upgrade vllm-stack helm/vllm-stack \
  -f environments/prod/values.yaml \
  -n llm-inference \
  --set engine.extraArgs[0]="--max-num-seqs=64"

# 2. Reduce max-model-len (shorter sequences = smaller KV cache per request)
# Edit prod values.yaml: model.maxModelLen: 4096

# 3. Add more GPU replicas
kubectl scale deployment/vllm-stack-engine -n llm-inference --replicas=<N+1>
```

---

## HPA Stuck / Not Scaling
**Alert:** `HPAAtMaxReplicas` or `HPAScalingFailed`

```bash
# Check HPA conditions
kubectl describe hpa vllm-stack-engine -n llm-inference

# Check if Prometheus Adapter is running
kubectl get pods -n monitoring | grep prometheus-adapter

# Check if the custom metric is visible
kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1 \
  | python3 -m json.tool | grep vllm

# If metric is missing: Prometheus may not be scraping the engine
# Check ServiceMonitor is installed:
kubectl get servicemonitor -n monitoring | grep vllm

# If at maxReplicas and queue is growing: need more capacity
# Increase maxReplicas in values.yaml and redeploy
helm upgrade vllm-stack helm/vllm-stack \
  -f environments/prod/values.yaml \
  --set hpa.maxReplicas=16 \
  -n llm-inference
```

---

## Rollback
Use when a new deploy breaks production.

```bash
# See Helm history
helm history vllm-stack -n llm-inference

# Roll back to previous release
helm rollback vllm-stack -n llm-inference --wait

# Or to a specific revision
helm rollback vllm-stack 3 -n llm-inference --wait

# Verify rollback
bash scripts/smoke-test.sh prod
```

Or via the CLI helper:
```bash
bash scripts/helpers.sh rollback
```

---

## GPU Node Not Available
**Symptoms:** Engine pods stuck in `Pending`. `kubectl describe pod` shows:
"0/N nodes are available: N Insufficient nvidia.com/gpu"

```bash
# Check GPU capacity on all nodes
kubectl get nodes -o custom-columns=\
'NAME:.metadata.name,GPU_CAP:.status.capacity.nvidia\.com/gpu,GPU_ALLOC:.status.allocatable.nvidia\.com/gpu'

# Check what's using the GPUs
kubectl get pods -A -o json \
  | python3 -c "
import sys, json
pods = json.load(sys.stdin)['items']
for p in pods:
  for c in p['spec'].get('containers', []):
    gpus = c.get('resources', {}).get('limits', {}).get('nvidia.com/gpu')
    if gpus:
      print(f\"{p['metadata']['namespace']}/{p['metadata']['name']}: {gpus} GPU(s)\")
"

# If GPU Operator pods are not ready:
kubectl get pods -n gpu-operator
kubectl describe pod <failing-gpu-operator-pod> -n gpu-operator
```

---

## Model Re-download (PVC lost)
If the model cache PVC was deleted, the engine will re-download the model at startup.
This can take 10–60+ minutes for large models.

```bash
# Watch the download progress in logs
kubectl logs -l app.kubernetes.io/component=engine -n llm-inference -f \
  | grep -E "Downloading|Progress|tokenizer"

# The pod will not become Ready until the model is loaded (startupProbe covers this).
# Do NOT restart the pod during download — it will start over.
```

---

## Useful one-liners

```bash
# All vLLM metrics
kubectl exec -n llm-inference \
  $(kubectl get pods -n llm-inference -l app.kubernetes.io/component=engine -o name | head -1) \
  -- curl -s localhost:8000/metrics | grep -v "^#"

# Watch pods in real time
watch kubectl get pods -n llm-inference

# Check which nodes have free GPUs
kubectl describe nodes | grep -A5 "Allocated resources" | grep "nvidia.com/gpu"

# Force immediate HPA evaluation (useful for testing)
kubectl annotate hpa vllm-stack-engine autoscaling.alpha.kubernetes.io/reload-time="$(date)" -n llm-inference
```
