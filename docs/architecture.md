# Architecture

## System diagram

```
Internet / Internal Clients
          │
          ▼  HTTPS (TLS terminated by nginx ingress + cert-manager)
┌─────────────────────────────────────────────────────────────────┐
│                     nginx Ingress Controller                    │
│              Rate limiting: 500 req/min per IP                  │
│              Proxy timeout: 300s (long requests)                │
└───────────────────────────┬─────────────────────────────────────┘
                            │  HTTP :8000
┌───────────────────────────▼─────────────────────────────────────┐
│              vLLM Request Router (Deployment)                   │
│   Strategy: session (same session → same backend = KV reuse)    │
│   Discovers engine pods via K8s headless service (DNS)          │
│   HPA: CPU-based, 1–10 replicas                                 │
└─────────┬──────────────────┬──────────────────┬─────────────────┘
          │                  │                  │
    ┌─────▼──────┐   ┌───────▼──────┐   ┌──────▼──────┐
    │ vLLM Engine│   │ vLLM Engine  │   │ vLLM Engine │
    │  Pod 0     │   │  Pod 1       │   │  Pod N      │
    │            │   │              │   │             │
    │  CUDA GPU  │   │  CUDA GPU    │   │  CUDA GPU   │
    │ PagedAttn  │   │ PagedAttn    │   │ PagedAttn   │
    │ :8000/v1   │   │ :8000/v1     │   │ :8000/v1    │
    └────────────┘   └──────────────┘   └─────────────┘
          │                  │
          └──── shared PVC (model weights cache) ──────┘
                   ReadWriteMany (NFS/EFS/CephFS)
                   50–200 GB depending on model

HPA signal: vllm:num_requests_waiting (via Prometheus Adapter)
Scale up:   queue > 5 per replica, 2 pods/60s
Scale down: 10 min stabilization, 1 pod/5 min
Min/max:    2–12 replicas (prod)
```

## Component responsibilities

### nginx Ingress
- TLS termination (cert-manager issues Let's Encrypt certs)
- Rate limiting (protects against abuse)
- Proxy timeouts (LLM responses can take 60+ seconds)

### Request Router
- Accepts all external API traffic (OpenAI-compatible)
- Routes by session ID (same user → same backend → KV cache hit)
- Independently scalable (CPU-bound, unlike the engines)

### vLLM Engine
- Runs the LLM model with NVIDIA CUDA acceleration
- PagedAttention: OS-style virtual memory for GPU KV cache
- Continuous batching: GPU always working, no idle time between requests
- Exposes `/v1/chat/completions`, `/v1/completions`, `/v1/models`, `/metrics`

### Shared PVC (model cache)
- ReadWriteMany so all engine replicas mount the same volume
- First engine startup downloads the model (~minutes to ~hours)
- Subsequent startups and new replicas from HPA scale-out load in seconds

### HPA (Horizontal Pod Autoscaler)
- Scales engine replicas based on `vllm:num_requests_waiting`
- This is the inference queue depth — how many requests are waiting for a GPU batch slot
- More meaningful than CPU (engines are GPU-bound, not CPU-bound)
- Prometheus Adapter bridges Prometheus metrics → K8s custom metrics API

## Networking

All pods run in the `llm-inference` namespace with NetworkPolicy:

```
External → nginx ingress → router (allowed)
Router   → engine :8000  (allowed)
Engine   → HuggingFace Hub :443 (egress, for model download)
Engine   → kube-dns :53 (egress, for DNS)
Prometheus → engine :8000/metrics (allowed from monitoring ns)
Everything else: DENIED
```

## Security model

| Layer | Control |
|-------|---------|
| Namespace | Pod Security Standards: baseline |
| Workload | Dedicated ServiceAccounts (engine + router), no default SA token |
| RBAC | Engine: read-only ConfigMaps + own Secret. Router: list/watch pods/endpoints |
| Network | NetworkPolicy: deny-all + explicit allows |
| Secrets | HF token in K8s Secret; use ExternalSecrets + AWS Secrets Manager in prod |
| Images | Trivy scan in CI, pin to digest in prod (not `latest`) |
| TLS | cert-manager + Let's Encrypt (staging cert for pre-prod, prod cert for prod) |

## Observability

Three pillars:

**Metrics** (Prometheus + Grafana)
- vLLM: queue depth, token throughput, TTFT, e2e latency, KV cache %, preemptions
- NVIDIA DCGM: GPU util %, memory used/free, temperature, power draw
- Kubernetes: pod readiness, HPA replica count, PDB violations

**Logs** (stdout → your log aggregator)
- All pods log to stdout — pipe to Loki/Datadog/CloudWatch via your preferred agent
- Set `model.disableLogRequests: false` temporarily to debug request-level issues

**Alerts** (Alertmanager PrometheusRules)
- Critical: engine down, crash loop, HPA blocked, OOM imminent
- Warning: high TTFT, queue saturation, KV cache > 90%, GPU temp > 85°C

## Scaling strategy

```
Single replica (dev/test)
  └─ 1 engine, 1 GPU, no HA

Multi-replica (staging/prod)
  └─ 2+ engines on different nodes
  └─ PDB: minAvailable 1–2
  └─ HPA: 2–12 replicas based on queue depth
  └─ PVC: ReadWriteMany for instant scale-out

Multi-GPU per replica (large models)
  └─ Set gpuCount: 4, tensorParallelSize: 4 for 70B+
  └─ Requires 4×A100 or 4×H100 per pod
  └─ GPU topology awareness via nodeSelector + tolerations
```
