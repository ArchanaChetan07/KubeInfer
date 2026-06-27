# Scaling Guide

## Model selection by GPU

| Model | Size | GPUs needed | Recommended GPU | tensor-parallel-size |
|-------|------|-------------|-----------------|----------------------|
| Phi-3-mini | ~2 GB | 1× any | A10G / L40S | 1 |
| Llama-3.2-1B | ~3 GB | 1× any | A10G / L40S | 1 |
| Llama-3.1-8B | ~16 GB | 1× A100/H100 | A100 80GB | 1 |
| Llama-3.1-70B (FP8) | ~80 GB | 1× H100 or 4× A100 | H100 80GB | 1 or 4 |
| Llama-3.1-405B (FP8) | ~400 GB | 4× H100 or 8× A100 | 4× H100 | 4 or 8 |
| Mixtral-8x7B | ~90 GB | 2× A100 | 2× A100 80GB | 2 |

## PVC storage by model

```
model.maxModelLen × 2 bytes × num_heads × head_dim = KV cache per sequence
Total PVC = model weights + KV cache reserve

Quick reference:
  7B  FP16 → 14 GB  → request 25 Gi
  8B  BF16 → 16 GB  → request 25 Gi
  70B FP8  → 70 GB  → request 150 Gi
  405B FP8 → 400 GB → request 800 Gi
```

## HPA tuning

The default queue depth threshold of 5 is a good starting point.
Tune it based on your latency SLO:

- **Latency-sensitive (< 2s TTFT):** set threshold to 2–3
- **Throughput-optimized (batch workloads):** set threshold to 10–20
- **Cost-optimized:** raise threshold, accept higher latency at peak

```yaml
# environments/prod/values.yaml
hpa:
  queueDepthThreshold: "3"   # More responsive, more expensive
```

## Multi-GPU (tensor parallelism)

For models that don't fit on a single GPU, use tensor parallelism:

```yaml
# environments/prod/values.yaml
engine:
  gpuCount: 4               # Allocate 4 GPUs per pod
  tensorParallelSize: 4     # Split the model across 4 GPUs
  nodeSelector:
    accelerator: nvidia
    nvidia.com/gpu.count: "8"   # Only schedule on 8-GPU nodes

  # Shared memory for CUDA IPC between GPUs
  # The dshm volume in the Deployment template handles this automatically.
```

## Canary rollout (prod model upgrades)

When upgrading the model or vLLM version in production:

```bash
# 1. Deploy the new version to staging first
bash scripts/helpers.sh deploy staging

# 2. Run smoke tests on staging
bash scripts/smoke-test.sh staging

# 3. Deploy to prod with --wait (atomic rollout — rolls back on failure)
helm upgrade vllm-stack helm/vllm-stack \
  -f environments/prod/values.yaml \
  --set engine.image.tag=v0.7.0 \
  -n llm-inference \
  --atomic \
  --timeout 20m

# 4. Monitor latency and error rate for 15 minutes
# Check Grafana dashboard or:
kubectl logs -l app.kubernetes.io/component=engine -n llm-inference -f | grep ERROR

# 5. If anything looks wrong, roll back immediately
bash scripts/helpers.sh rollback
```

## Cost optimization

**Use spot/preemptible nodes for dev and staging:**
```yaml
# environments/dev/values.yaml
engine:
  tolerations:
    - key: "cloud.google.com/gke-spot"   # GKE
      operator: Exists
      effect: NoSchedule
    # AWS:
    # - key: "eks.amazonaws.com/capacityType"
    #   value: "SPOT"
    #   effect: NoSchedule
```

**Scale to zero in dev (use KEDA instead of native HPA):**
```yaml
# With KEDA, you can scale to 0 replicas when there's no traffic.
# Cold start penalty: ~2–5 min for a 7B model with cached weights.
# Install KEDA: helm install keda kedacore/keda -n keda --create-namespace
```

**Rightsize before production:**
Run a load test with [locust](https://locust.io/) or [k6](https://k6.io/), then
check Grafana for:
- GPU utilization at peak (target 70–85%)
- KV cache utilization at peak (target < 80%)
- P95 TTFT vs your SLO

Adjust `gpuMemoryUtilization`, `maxModelLen`, and HPA thresholds to match.
