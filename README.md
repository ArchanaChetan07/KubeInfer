<div align="center">

# KubeInfer

**Production-grade LLM inference platform on Kubernetes**

[![Kubernetes](https://img.shields.io/badge/Kubernetes-326CE5?style=flat-square&logo=kubernetes&logoColor=white)](https://kubernetes.io)
[![Helm](https://img.shields.io/badge/Helm-0F1689?style=flat-square&logo=helm&logoColor=white)](https://helm.sh)
[![vLLM](https://img.shields.io/badge/vLLM-Inference%20Engine-FF6B35?style=flat-square)](https://github.com/vllm-project/vllm)
[![NVIDIA](https://img.shields.io/badge/NVIDIA-GPU%20Operator-76B900?style=flat-square&logo=nvidia&logoColor=white)](https://github.com/NVIDIA/gpu-operator)
[![Prometheus](https://img.shields.io/badge/Prometheus-E6522C?style=flat-square&logo=prometheus&logoColor=white)](https://prometheus.io)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow?style=flat-square)](LICENSE)

*Stop serving LLMs from a notebook. This is what production looks like.*

</div>

---

## What is KubeInfer?

KubeInfer is a production-ready Helm chart and GitOps scaffold for deploying vLLM inference on Kubernetes with NVIDIA GPUs. It bridges the gap between "model works on my machine" and "model serves 1000 requests/min reliably."

**Built for:** MLOps engineers, platform teams, and AI startups that need LLM inference running reliably — not just running.

---

## Architecture

```
Internet / Internal Clients
        │  HTTPS (TLS — cert-manager + Let's Encrypt)
        ▼
┌─────────────────────────────────┐
│      nginx Ingress Controller   │  Rate limit: 500 req/min
│      Proxy timeout: 300s        │
└───────────────┬─────────────────┘
                │
┌───────────────▼─────────────────┐
│       Request Router            │  Session-affinity routing
│       HPA: CPU-based 1–10x      │  → KV cache reuse
└──────┬────────┬────────┬────────┘
       │        │        │
  ┌────▼──┐ ┌──▼───┐ ┌──▼───┐
  │Engine │ │Engine│ │Engine│   vLLM + PagedAttention
  │  GPU  │ │  GPU │ │  GPU │   Continuous batching
  └────┬──┘ └──┬───┘ └──┬───┘
       └────────┴────────┘
              │
    ┌─────────▼──────────┐
    │  Shared PVC (RWX)  │   Model weights cache
    │  50–200 GB         │   No re-download on scale-out
    └────────────────────┘

HPA signal: vllm:num_requests_waiting  (queue depth, not CPU)
Scale up:   > 5 waiting → +2 pods/60s
Scale down: 10 min stabilization → -1 pod/5 min
```

---

## Key design decisions

**Queue-depth HPA, not CPU HPA**
LLM inference is GPU-bound. CPU sits at 5% while the GPU queue fills up. Scaling on CPU tells you nothing. We expose `vllm:num_requests_waiting` via Prometheus Adapter as a custom K8s metric and scale on that instead.

**Asymmetric scale behavior**
Scale up fast (2 pods/60s) — GPU pods take 2–5 min to become ready, so react before users notice. Scale down slow (1 pod/5 min, 10 min stabilization) — avoid churning expensive GPU nodes on transient dips.

**ReadWriteMany PVC for model cache**
All engine replicas mount the same PVC. HPA scale-out means new pods load the model from local storage (~30s) rather than re-downloading from HuggingFace (~10–30 min for large models).

**minReplicas: 2 in production**
One replica = one point of failure. A pod restart during node maintenance is a 5-minute outage. Two replicas + PodDisruptionBudget means rolling updates never drop below 1 live engine.

---

## Stack

| Layer | Component | Purpose |
|---|---|---|
| Inference | vLLM | PagedAttention · continuous batching · OpenAI-compatible API |
| GPU | NVIDIA GPU Operator + DCGM | Driver mgmt · device plugin · GPU metrics |
| Orchestration | Kubernetes + Helm | Scheduling · rolling deploys · multi-env values |
| Routing | lmstack-router | Session-affinity load balancing across engines |
| Load Balancer | MetalLB | Bare-metal LoadBalancer IP assignment |
| TLS | cert-manager | Automatic Let's Encrypt certificate rotation |
| Autoscaling | HPA + Prometheus Adapter | Scale on queue depth custom metric |
| Observability | Prometheus + Grafana | 10-panel dashboard · DCGM + vLLM metrics |
| Alerting | Alertmanager | 12 production rules covering TTFT, KV cache, HPA |
| Security | RBAC + NetworkPolicy + PSS | Zero-trust network · least-privilege service accounts |
| CI/CD | GitHub Actions | lint → unittest → kubeconform → trivy → staged deploy |
| UI | Open WebUI | Self-hosted chat interface over vLLM API |

---

## Project structure

```
KubeInfer/
├── helm/vllm-stack/
│   ├── Chart.yaml
│   ├── values.yaml                  # Documented defaults
│   └── templates/
│       ├── namespace.yaml           # Pod Security Standards label
│       ├── rbac.yaml                # Separate SAs for engine + router
│       ├── networkpolicy.yaml       # Default-deny + surgical allows
│       ├── pvc.yaml                 # Model cache + WebUI (resource-policy: keep)
│       ├── deployment.yaml          # Engine + Router + WebUI
│       ├── service.yaml             # Headless engine + LB router + Ingress
│       ├── hpa.yaml                 # Queue-depth HPA + PDB
│       └── servicemonitor.yaml      # Prometheus scrape + Adapter ConfigMap
├── environments/
│   ├── dev/values.yaml              # Single GPU, no HPA, relaxed security
│   ├── staging/values.yaml          # 2 replicas, TLS, full monitoring
│   └── prod/values.yaml             # HA, minReplicas:2, pinned image digest
├── monitoring/
│   ├── alerts/vllm-alerts.yaml      # 12 PrometheusRule alerts
│   └── dashboards/vllm-dashboard.json
├── scripts/
│   ├── bootstrap.sh                 # One-command cluster setup
│   ├── smoke-test.sh                # 8 automated post-deploy checks
│   └── helpers.sh                   # status / logs / rollback / scale
├── tests/helm-unit-tests/           # helm-unittest plugin tests
└── docs/
    ├── architecture.md
    ├── runbook.md                   # Engine down, crash loop, HPA stuck...
    └── scaling-guide.md             # Model/GPU matrix, canary rollout
```

---

## Quick start

```bash
# 1. Bootstrap cluster dependencies
bash scripts/bootstrap.sh

# 2. Set your HuggingFace token
kubectl create secret generic hf-secret \
  --from-literal=token=hf_YOUR_TOKEN \
  -n llm-inference

# 3. Deploy (dev)
helm upgrade --install vllm-stack helm/vllm-stack \
  -f environments/dev/values.yaml \
  --namespace llm-inference \
  --create-namespace --wait

# 4. Smoke test
bash scripts/smoke-test.sh dev

# 5. Hit the API
curl http://<EXTERNAL-IP>:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"meta-llama/Llama-3.2-1B-Instruct","messages":[{"role":"user","content":"Hello!"}],"max_tokens":128}'
```

---

## Model sizing guide

| Model | VRAM needed | GPUs | `tensorParallelSize` | PVC size |
|---|---|---|---|---|
| Phi-3-mini (3.8B) | 8 GB | 1× A10G | 1 | 10 Gi |
| Llama-3.1-8B | 16 GB | 1× A100 80GB | 1 | 25 Gi |
| Llama-3.1-70B (FP8) | 80 GB | 1× H100 or 4× A100 | 1 or 4 | 150 Gi |
| Mixtral-8x7B | 90 GB | 2× A100 80GB | 2 | 100 Gi |

---

## Observability

**Grafana dashboard covers:**
- Queue depth (`vllm:num_requests_waiting`) — the HPA signal
- Time to first token P50/P95/P99
- End-to-end latency P50/P95/P99
- Token throughput (prompt + generation tokens/sec)
- KV cache utilization % (alert at 90%)
- Preemption rate
- GPU utilization, memory, temperature (DCGM)
- HPA replica count vs min/max

**Alert rules (12 total):**
`VLLMEngineDown` · `VLLMEngineRestartLoop` · `VLLMHighTimeToFirstToken` · `VLLMHighE2ELatency` · `VLLMQueueDepthHigh` · `VLLMKVCacheNearFull` · `VLLMPreemptionsIncreasing` · `GPUMemoryHigh` · `GPUTemperatureHigh` · `GPUUtilizationLow` · `HPAAtMaxReplicas` · `HPAScalingFailed`

---

## Security

| Layer | Control |
|---|---|
| Namespace | Pod Security Standards: baseline |
| Identity | Dedicated ServiceAccounts (engine + router) — no default SA token |
| Permissions | Least-privilege RBAC — engine reads own Secret only |
| Network | NetworkPolicy: deny-all + surgical allows (router→engine, Prometheus→engine) |
| Images | Trivy scan in CI · pin to digest in prod |
| TLS | cert-manager + Let's Encrypt (staging/prod) |
| Secrets | K8s Secret · ExternalSecrets-ready for AWS Secrets Manager / Vault |

---

## CI/CD pipeline

```
PR opened
  └── helm lint (dev + staging + prod values)
  └── helm unittest (GPU allocation, HPA metric, RBAC, PDB)
  └── kubeconform (K8s 1.29 schema validation)
  └── trivy image scan (HIGH/CRITICAL CVEs fail the build)
  └── gitleaks (secret scanning)

Merge to main
  └── auto-deploy → staging (helm upgrade --atomic --timeout 15m)
  └── smoke-test.sh staging (8 checks: health, models, inference, metrics, PDB)
  └── Slack notification

Manual trigger (prod)
  └── GitHub Environment approval gate (required reviewers)
  └── deploy → prod (helm upgrade --atomic --timeout 20m)
  └── smoke-test.sh prod
  └── git tag deploy-prod-<timestamp>
```

---

## Docs

- [Architecture deep-dive](docs/architecture.md)
- [Scaling guide](docs/scaling-guide.md) — model/GPU matrix, HPA tuning, canary rollout, cost optimization
- [On-call runbook](docs/runbook.md) — engine down, crash loop, high latency, KV cache full, HPA stuck, rollback

---

## Author

**Archana Suresh Patil** — Platform & MLOps Engineer  
MS Data Science · University of San Diego · GPA 3.9  
📍 Sunnyvale, CA · Open to full-time · No sponsorship needed  
📬 apatil@sandiego.edu · [LinkedIn](https://linkedin.com/in/archana-suresh-patil-792213245) · [GitHub](https://github.com/ArchanaChetan07)
