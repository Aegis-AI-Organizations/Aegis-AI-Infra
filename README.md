# ☁️ Aegis AI — Infrastructure (Aegis-AI-Infra)

**Project ID:** AEGIS-CORE-2026

> IaC (Infrastructure as Code) repository centralizing the entire Kubernetes topology of the **Aegis AI** platform. All resources are declarative and managed by **ArgoCD** via the **App of Apps** pattern.

---

## 📑 Table of Contents

- [Global Architecture](#️-global-architecture)
- [Tech Stack](#️-tech-stack)
- [Repository Structure](#-repository-structure)
- [Quick Start (Local)](#-quick-start-local)
- [Available Environments](#-available-environments)
- [Deployed Services](#-deployed-services)
- [Generic Helm Chart](#-generic-helm-chart-aegis-service)
- [Security & DevSecOps](#-security--devsecops)
- [Utility Scripts](#-utility-scripts)
- [CI / Pre-commit](#-ci--pre-commit)
- [Contributing](#-contributing)

---

## 🏗️ Global Architecture

The Aegis infrastructure is built on an **Event-Driven Microservices** pattern on Kubernetes 1.28+. Continuous deployment is fully driven by **ArgoCD** (GitOps): any change merged to `HEAD` is automatically synchronized into the cluster.

```
GitHub (this repo)
       │  (GitOps — automatic sync)
       ▼
    ArgoCD  ──── root-app-<env>.yaml  (App of Apps)
       │
       ├─── aegis-api-gateway-<env>    → namespace: aegis-system
       ├─── aegis-brain-<env>          → namespace: aegis-system
       ├─── aegis-dashboard-<env>      → namespace: aegis-system
       ├─── aegis-pentest-worker-<env> → namespace: aegis-system
       ├─── aegis-postgres-<env>       → namespace: aegis-system
       ├─── aegis-db-init-<env>        → namespace: aegis-system
       └─── aegis-temporal-<env>       → namespace: aegis-system
```

---

## 🛠️ Tech Stack

| Component | Technology | Version |
|---|---|---|
| Orchestration | Kubernetes | 1.28+ |
| GitOps | ArgoCD | stable |
| CNI | Cilium | — |
| Ingress | Nginx Ingress Controller | — |
| Workflow Engine | Temporal | 0.x (Helm) |
| Database | PostgreSQL | 16 (Bitnami 18.5.1) |
| Packaging | Helm v3 | — |
| IaC Templates | Kustomize | — |
| Secrets | Infisical / KV | — |
| Sandbox Runtime | gVisor (`runsc`) | `sandbox-*` namespaces only |

---

## 📁 Repository Structure

```
Aegis-AI-Infra/
├── .github/
│   ├── CODEOWNERS                    # File ownership
│   └── workflows/
│       ├── build-and-test.yml        # CI build & tests
│       ├── ci-orchestrator.yml       # CI orchestrator
│       └── linting.yml               # YAML linting / pre-commit
│
├── docs/
│   ├── getting-started.md            # ← Local setup guide
│   ├── architecture.md               # Global infrastructure architecture
│   ├── kubernetes.md                 # Kubernetes architecture & patterns
│   ├── cilium-network.md             # Cilium network policies
│   └── gvisor-sandbox.md             # gVisor sandbox runtime
│
├── kubernetes/
│   ├── bootstrap/
│   │   └── root-app-pre-alpha.yaml   # ArgoCD App of Apps (pre-alpha env)
│   │
│   ├── charts/
│   │   └── aegis-service/            # Generic Helm chart (all microservices)
│   │       ├── Chart.yaml
│   │       ├── values.yaml           # Default values
│   │       └── templates/
│   │           ├── deployment.yaml
│   │           ├── service.yaml
│   │           └── ingress.yaml
│   │
│   └── envs/
│       └── pre-alpha/                # Pre-alpha environment
│           ├── kustomization.yaml    # List of deployed applications
│           ├── api-gateway/
│           │   ├── application.yaml  # ArgoCD Application
│           │   └── values.yaml       # Helm overrides for this env
│           ├── brain/
│           ├── dashboard/
│           ├── pentest-worker/
│           └── infrastructure/
│               ├── db-init/          # PostgreSQL schema init job
│               ├── postgres/         # PostgreSQL (Bitnami)
│               └── temporal/         # Temporal Workflow Engine
│
└── scripts/
    ├── setup-env.sh                  # Bootstraps a full environment
    ├── stop-env.sh                   # Stops env (scale down to 0)
    └── teardown-env.sh               # Fully destroys env (deletes namespaces)
```

---

## 🚀 Quick Start (Local)

> 📖 **Full guide:** [`docs/getting-started.md`](docs/getting-started.md)

### Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) **with Kubernetes enabled** (or [kind](https://kind.sigs.k8s.io/) / [minikube](https://minikube.sigs.k8s.io/))
- [`kubectl`](https://kubernetes.io/docs/tasks/tools/) ≥ 1.28
- [`helm`](https://helm.sh/docs/intro/install/) ≥ 3.x
- Access to the [`ghcr.io/aegis-ai-organizations`](https://ghcr.io) registry (GitHub token)

### Launch the `pre-alpha` environment

```bash
# 1. Clone the repo
git clone https://github.com/Aegis-AI-Organizations/Aegis-AI-Infra.git
cd Aegis-AI-Infra

# 2. Make sure kubectl points to the right cluster
kubectl config current-context

# 3. Run the full setup
./scripts/setup-env.sh pre-alpha

# 4. Access the ArgoCD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443
# → https://localhost:8080  (user: admin, password: see below)
```

Retrieve the ArgoCD admin password:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

---

## 🌍 Available Environments

| Environment | Branch | K8s Namespace | Status |
|---|---|---|---|
| `pre-alpha` | `HEAD` | `aegis-system` | ✅ Active |

---

## 📦 Deployed Services

| Service | Image | Port | Ingress |
|---|---|---|---|
| `api-gateway` | `ghcr.io/.../aegis-ai-api-gateway:latest` | 8080 | `api.aegis.pre-alpha.local` |
| `brain` | `ghcr.io/.../aegis-ai-brain:latest` | 8080 | — |
| `dashboard` | `ghcr.io/.../aegis-ai-dashboard:latest` | 8080 | — |
| `pentest-worker` | `ghcr.io/.../aegis-ai-worker-pentest:latest` | 8080 | — |
| `db-init` | `postgres:16` (Kubernetes Job) | — | — |
| `postgresql` | Bitnami PostgreSQL 16 | 5432 | — |
| `temporal` | Temporal Helm Chart | 7233 | — |

---

## 🎯 Generic Helm Chart (`aegis-service`)

All Aegis microservices use the shared chart at `kubernetes/charts/aegis-service`. Per-environment values are defined in `kubernetes/envs/<env>/<service>/values.yaml`.

Key parameters:

| Parameter | Description | Default |
|---|---|---|
| `replicaCount` | Number of replicas | `1` |
| `image.repository` | Docker image | `nginx` |
| `image.tag` | Image tag | `latest` |
| `image.pullPolicy` | Pull policy | `IfNotPresent` |
| `service.port` | K8s Service port | `80` |
| `service.targetPort` | Container port | `8080` |
| `env` | Environment variables | `[]` |
| `ingress.enabled` | Enable ingress | `false` |
| `probes.enabled` | Enable liveness/readiness | `false` |
| `securityContext` | Pod security context | see `values.yaml` |

---

## 🔐 Security & DevSecOps

- **Network:** Deny-all by default. Strict segmentation by namespace (`aegis-gateway`, `aegis-core`, `aegis-data`, `sandbox-*`). No standard namespace has direct internet access.
- **Runtime:** Digital Twins in `sandbox-*` use exclusively **gVisor (`runsc`)**. The standard `runc` runtime is forbidden in those namespaces.
- **Secrets:** Injected via **Infisical/KV**. Committed files are automatically audited to prevent plaintext secrets.
- **mTLS:** Nginx Ingress enforces mTLS (client certificate authentication) + WAF.

> ⚠️ **Never commit secrets to this repository.** Pre-commit hooks and CI automatically block commits containing sensitive values.

---

## 🔧 Utility Scripts

### `./scripts/setup-env.sh <env>`
Bootstraps a complete environment from scratch:
1. Creates `argocd` and `aegis-system` namespaces
2. Installs **Nginx Ingress Controller**
3. Installs **ArgoCD**
4. Applies the App of Apps (`root-app-<env>.yaml`)

```bash
./scripts/setup-env.sh pre-alpha
```

### `./scripts/stop-env.sh <env>`
Stops the environment **without destroying it** (scales to 0 replicas). Pauses ArgoCD auto-sync. Ideal for freeing local resources.

```bash
./scripts/stop-env.sh pre-alpha
# To restart: ./scripts/setup-env.sh pre-alpha
```

### `./scripts/teardown-env.sh <env>`
**Completely destroys** the environment: deletes the App of Apps and the `aegis-system` namespace.

```bash
./scripts/teardown-env.sh pre-alpha
```

---

## 🔄 CI / Pre-commit

### GitHub Actions

| Workflow | Trigger | Description |
|---|---|---|
| `linting.yml` | `push` / `PR` | YAML lint + pre-commit hooks |
| `build-and-test.yml` | `push` / `PR` | Build & tests |
| `ci-orchestrator.yml` | `push` / `PR` | Global CI orchestrator |

### Pre-commit (local)

```bash
# Install pre-commit
pip install pre-commit
pre-commit install --hook-type commit-msg

# Run manually on all files
pre-commit run --all-files
```

**Commit convention:**
```
[TYPE] Message in English
```
Valid types: `ADD`, `FIX`, `UPDATE`, `REMOVE`, `DOC`, `REFACTOR`, `TEST`, `CI`, `CONFIG`, `MERGE`, `WORK`, `WIP`

---

## 🤝 Contributing

1. Create a branch from `main`
2. Follow the commit convention (`[TYPE] Message`)
3. Open a Pull Request — CODEOWNERS will be notified automatically
4. CI must be green before any merge

---

*Aegis AI — Infrastructure Team — 2026*
