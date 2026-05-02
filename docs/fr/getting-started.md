# 🚀 Getting Started — Aegis AI Infra (Local Setup)

This guide walks you through running the full Aegis AI infrastructure locally on your machine, using **Docker Desktop** (or `kind`/`minikube`) as your Kubernetes cluster.

---

## 📋 Prerequisites

Make sure the following tools are installed before proceeding:

| Tool | Minimum Version | Installation |
|---|---|---|
| Docker Desktop | latest stable | [docker.com](https://www.docker.com/products/docker-desktop/) |
| Kubernetes (via Docker Desktop or kind) | 1.28+ | [kind.sigs.k8s.io](https://kind.sigs.k8s.io/) |
| `kubectl` | 1.28+ | [kubernetes.io/docs/tasks/tools](https://kubernetes.io/docs/tasks/tools/) |
| `helm` | 3.x | [helm.sh/docs/intro/install](https://helm.sh/docs/intro/install/) |
| `git` | — | [git-scm.com](https://git-scm.com/) |
| `pre-commit` *(optional, for contributing)* | — | `pip install pre-commit` |

---

## ⚙️ Environment Setup (`.env`)

All sensitive variables (DB passwords, tokens, etc.) are managed locally via a `.env` file that is **never committed** (listed in `.gitignore`).

```bash
# Copy the template
cp .env.example .env
```

Then open `.env` and fill in any missing values (e.g. your `GHCR_TOKEN`). The MVP defaults are already pre-filled for local use.

```bash
# Load variables in your current terminal session
source .env

# Quick check — should print "aegis_admin"
echo $POSTGRES_USER
```

> 💡 All scripts (`setup-env.sh`, `stop-env.sh`, `teardown-env.sh`) automatically source `.env` on startup — you don't need to source it manually before running them.

| Variable | Description | Default |
|---|---|---|
| `POSTGRES_HOST` | PostgreSQL host (after port-forward) | `localhost` |
| `POSTGRES_PORT` | PostgreSQL port | `5432` |
| `POSTGRES_DB` | Database name | `aegis_db` |
| `POSTGRES_USER` | DB username | `aegis_admin` |
| `POSTGRES_PASSWORD` | DB password | `password123` |
| `JWT_SECRET` | Secret key for JWT signing | `mvp-secret-key-12345` |
| `TEMPORAL_HOST` | Temporal host (after port-forward) | `localhost` |
| `TEMPORAL_PORT` | Temporal gRPC port | `7233` |
| `ARGOCD_SERVER` | ArgoCD server address | `localhost:8080` |
| `GHCR_USERNAME` | GitHub username for GHCR auth | *(your GitHub handle)* |
| `GHCR_TOKEN` | GitHub PAT (`read:packages` scope) | *(generate on GitHub)* |

---

## 🖥️ Option A — Docker Desktop (recommended for macOS/Windows)

1. Open **Docker Desktop**
2. Go to **Settings → Kubernetes**
3. Check **"Enable Kubernetes"**
4. Click **"Apply & Restart"**
5. Wait until the Kubernetes indicator (bottom left) turns **green**

Verify the active context is `docker-desktop`:

```bash
kubectl config current-context
# Expected: docker-desktop
```

---

## 🐳 Option B — kind (Kubernetes in Docker)

If you prefer an isolated cluster with `kind`:

```bash
# Install kind (macOS)
brew install kind

# Create a cluster named "aegis-local"
kind create cluster --name aegis-local

# Verify
kubectl config current-context
# Expected: kind-aegis-local
```

---

## ⚡ One-Command Setup

Once your cluster is ready, from the **repository root**:

```bash
./scripts/setup-env.sh mvp
```

This script will automatically:
1. Create the `argocd` and `aegis-system` namespaces
2. Install **Nginx Ingress Controller**
3. Install **ArgoCD** (latest stable version)
4. Wait for the ArgoCD server to be available
5. Deploy the **App of Apps** (`root-app-mvp.yaml`)

> ⏳ The first run may take **5 to 10 minutes** while ArgoCD pulls all images.

---

## 🎛️ Accessing the ArgoCD UI

Once setup is complete, open a tunnel to the ArgoCD UI:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Then open in your browser: **[https://localhost:8080](https://localhost:8080)**

> ⚠️ Your browser will show a self-signed certificate warning → click "Advanced → Proceed anyway".

**Credentials:**
- **Username:** `admin`
- **Password:** retrieved with the following command:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

---

## 🌐 Accessing Services (Ingress)

The **api-gateway** is exposed via an Ingress on the hostname `api.aegis.mvp.local`.

To resolve this hostname locally, add the following entry to your `/etc/hosts` file:

```bash
# Get the Ingress Controller IP
kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

Then edit `/etc/hosts` (requires `sudo`):

```
# Aegis AI - MVP local
127.0.0.1   api.aegis.mvp.local
```

The API Gateway is then accessible at: **http://api.aegis.mvp.local**

> 💡 On **Docker Desktop**, the LoadBalancer IP is typically `127.0.0.1`. On `kind`, use `kubectl port-forward` instead.

---

## 🗄️ Infrastructure Services

### PostgreSQL

PostgreSQL runs in the `aegis-system` namespace. To access it from your machine:

```bash
kubectl port-forward svc/aegis-postgres-mvp-postgresql -n aegis-system 5432:5432
```

**Credentials (MVP dev only):**
- Host: `localhost:5432`
- Database: `aegis_db`
- Username: `aegis_admin`
- Password: `password123`

> ⚠️ These credentials are for the local development environment only. Never use these values in production.

### Temporal UI

To access the Temporal web interface:

```bash
kubectl port-forward svc/aegis-temporal-mvp-web -n aegis-system 8081:8080
```

Then open: **[http://localhost:8081](http://localhost:8081)**

---

## 📊 Checking Service Status

```bash
# List all pods in aegis-system
kubectl get pods -n aegis-system

# List ArgoCD applications
kubectl get applications -n argocd

# View recent events (useful for debugging)
kubectl get events -n aegis-system --sort-by='.lastTimestamp'

# Stream logs for a specific service (e.g. brain)
kubectl logs -n aegis-system -l app=brain-mvp --tail=100 -f
```

---

## 🛑 Stopping the Environment

To **stop** the pods without destroying the ArgoCD config (ideal for freeing RAM):

```bash
./scripts/stop-env.sh mvp
```

To **restart** after a stop:

```bash
./scripts/setup-env.sh mvp
```

---

## 🗑️ Full Teardown

To **completely remove** everything (namespaces, pods, volumes, ArgoCD config):

```bash
./scripts/teardown-env.sh mvp
```

> ⚠️ This command is **irreversible**. All local PostgreSQL data will be lost (persistence is disabled in MVP).

---

## 🔧 Development & Contributing

### Install pre-commit hooks

```bash
pip install pre-commit
pre-commit install --hook-type commit-msg
pre-commit install
```

### Commit convention

All commits must follow this format:

```
[TYPE] Message in English
```

| Type | Usage |
|---|---|
| `ADD` | New feature or resource |
| `FIX` | Bug fix |
| `UPDATE` | Dependency or configuration update |
| `REMOVE` | Code or resource removal |
| `DOC` | Documentation only |
| `REFACTOR` | Refactoring without behavior change |
| `TEST` | Adding or modifying tests |
| `CI` | CI/CD pipeline changes |
| `CONFIG` | Configuration changes |
| `MERGE` | Branch merges |
| `WIP` | Work in progress (avoid on `main`) |

### Modifying a service's configuration

Helm overrides for each service live in:

```
kubernetes/envs/mvp/<service>/values.yaml
```

After a change is pushed, ArgoCD detects it automatically (auto-sync is enabled) and redeploys the affected service.

---

## 🐞 Common Troubleshooting

### Pods stuck in `ImagePullBackOff`

You are likely not authenticated to the GHCR registry. Verify:

```bash
docker pull ghcr.io/aegis-ai-organizations/aegis-ai-brain:latest
```

If it fails, re-authenticate:

```bash
echo "YOUR_TOKEN" | docker login ghcr.io -u YOUR_USERNAME --password-stdin
```

### ArgoCD is not auto-syncing

Auto-sync may have been paused (e.g. by a previous `stop-env.sh` run):

```bash
# Check sync status of all applications
kubectl get applications -n argocd -o wide
```

To force a re-sync from the ArgoCD UI or CLI:

```bash
# Install argocd CLI (macOS)
brew install argocd

# Login
argocd login localhost:8080 --username admin --password <PASSWORD> --insecure

# Force sync all Aegis apps
argocd app sync -l app.kubernetes.io/part-of=aegis
```

### A pod is in `CrashLoopBackOff`

```bash
# View logs of the crashing pod
kubectl logs -n aegis-system <pod-name> --previous

# Describe the pod to see events
kubectl describe pod -n aegis-system <pod-name>
```

### `setup-env.sh` fails on the ArgoCD wait step

If ArgoCD takes too long to start (slow machine or limited resources):

```bash
# Check ArgoCD pods
kubectl get pods -n argocd

# If pods are Pending, check available node resources
kubectl describe nodes
```

---

*Aegis AI — Infrastructure Team — 2026*
