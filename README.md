# LLM Inference Platform

Production-grade, Kubernetes-native LLM inference infrastructure built on vLLM and NVIDIA GPUs.
Designed for startups that need to move fast without sacrificing operational maturity.

## What this is

A self-contained Helm chart + GitOps scaffold that deploys:

- **vLLM inference engine** — OpenAI-compatible API, PagedAttention, continuous batching
- **Request router** — KV-cache-aware load balancing across inference replicas
- **Custom HPA** — scales on queue depth (`vllm:num_requests_waiting`), not CPU
- **Full observability** — Prometheus, Grafana dashboards, Alertmanager rules
- **Security baseline** — RBAC, NetworkPolicy, PodSecurityStandards, ExternalSecrets
- **Multi-environment GitOps** — dev / staging / prod via ArgoCD or Helm + values files
- **CI/CD pipeline** — GitHub Actions: lint → test → security scan → deploy

## Repository layout

```
llm-inference-platform/
├── helm/vllm-stack/            # Helm chart (the core deliverable)
│   ├── Chart.yaml
│   ├── values.yaml             # Defaults (overridden per environment)
│   └── templates/
│       ├── namespace.yaml
│       ├── serviceaccount.yaml
│       ├── rbac.yaml
│       ├── networkpolicy.yaml
│       ├── secret-store.yaml   # ExternalSecrets / SecretStore
│       ├── pvc.yaml
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── ingress.yaml
│       ├── hpa.yaml            # Custom metric HPA (queue depth)
│       ├── pdb.yaml            # PodDisruptionBudget
│       ├── prometheus-adapter-config.yaml
│       ├── servicemonitor.yaml
│       └── _helpers.tpl
├── environments/
│   ├── dev/values.yaml
│   ├── staging/values.yaml
│   └── prod/values.yaml
├── monitoring/
│   ├── dashboards/             # Grafana JSON dashboards
│   └── alerts/                 # Alertmanager PrometheusRule CRDs
├── security/
│   ├── pod-security-policy.yaml
│   └── trivy-scan.yaml
├── .github/workflows/
│   ├── ci.yaml                 # Lint, test, scan on PR
│   └── deploy.yaml             # Deploy on merge to main/release
├── scripts/
│   ├── bootstrap.sh            # One-command cluster bootstrap
│   ├── rollout.sh              # Canary / blue-green helpers
│   ├── smoke-test.sh           # Post-deploy validation
│   └── helpers.sh              # Day-two operations toolkit
├── tests/
│   └── helm-unit-tests/        # Helm unittest plugin tests
└── docs/
    ├── architecture.md
    ├── runbook.md
    └── scaling-guide.md
```

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| kubectl | 1.28+ | Cluster interaction |
| helm | 3.14+ | Chart deployment |
| helmfile | 0.162+ | Multi-environment orchestration |
| argocd CLI | 2.10+ | GitOps sync (optional) |
| trivy | latest | Container image scanning |
| helm-unittest | 0.5+ | Chart unit tests |

Node requirements:
- Ubuntu 22.04+ with NVIDIA drivers installed (`nvidia-smi` working)
- Minimum: 1× GPU node (A10G / L40S / A100 / H100)
- Recommended prod: 2+ GPU nodes across availability zones

## Quick start (dev)

```bash
# 1. Bootstrap cluster dependencies (cert-manager, GPU operator, MetalLB, etc.)
bash scripts/bootstrap.sh

# 2. Create secrets
kubectl create secret generic hf-secret \
  --from-literal=token=hf_YOUR_TOKEN \
  -n llm-inference

# 3. Deploy dev environment
helm upgrade --install vllm-stack helm/vllm-stack \
  -f environments/dev/values.yaml \
  --namespace llm-inference \
  --create-namespace \
  --wait

# 4. Run smoke tests
bash scripts/smoke-test.sh dev
```

## Deploying to production

```bash
helm upgrade --install vllm-stack helm/vllm-stack \
  -f environments/prod/values.yaml \
  --namespace llm-inference \
  --create-namespace \
  --atomic \
  --timeout 15m
```

Or push to `main` and let GitHub Actions handle it (see `.github/workflows/deploy.yaml`).

## Accessing the API

```bash
# Get the external IP
kubectl get svc vllm-router -n llm-inference

# List models
curl http://<EXTERNAL-IP>:8000/v1/models

# Chat completion (OpenAI-compatible)
curl http://<EXTERNAL-IP>:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta-llama/Llama-3.1-8B-Instruct",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 256
  }'
```

## Key design decisions

**Queue-depth HPA over CPU HPA** — LLM inference is GPU-bound. CPU utilization
is meaningless as a scaling signal. We scale on `vllm:num_requests_waiting`
via the Prometheus Adapter, triggering scale-up when the queue exceeds 5 waiting
requests and holding scale-down for 10 minutes to avoid expensive cold starts.

**Asymmetric scaling** — Scale up aggressively (2 replicas/60 s), scale down
slowly (1 replica/5 min). A vLLM pod takes 2–5 minutes to become ready. A fast
scale-down that reverses under load means users wait for model loads.

**minReplicas: 2 in production** — A single vLLM replica means a pod failure
equals an outage. Two replicas give PodDisruptionBudget room to drain safely
during node maintenance.

**PVC with ReadWriteMany** — Allows multiple replicas to mount the same model
cache, making scale-out fast (no re-download per new replica).

**Dedicated namespace with NetworkPolicy** — Inference pods can only receive
traffic from the router and monitoring. No east-west access to other namespaces.

## Docs

- [Architecture deep-dive](docs/architecture.md)
- [Scaling guide](docs/scaling-guide.md)
- [On-call runbook](docs/runbook.md)
