# Kubernetes — Aegis AI Infra

This document describes the Kubernetes architecture used in the Aegis AI project, the deployment patterns, and the manifest structure.

---

## 🏗️ Overview

The Aegis infrastructure is built on **Kubernetes 1.28+** and the **GitOps** pattern via **ArgoCD**. All resources are declarative and versioned in this repository. No manual modifications (`kubectl apply` ad hoc) should be applied outside of the GitOps process.

---

## 📦 App of Apps Pattern

The entry point is a bootstrap **App of Apps** file:

```
kubernetes/bootstrap/root-app-<env>.yaml
```

This ArgoCD `Application` resource points to `kubernetes/envs/<env>/kustomization.yaml`, which in turn lists all ArgoCD applications for that environment.

```
root-app-pre-alpha.yaml
       │
       └──► kustomization.yaml (pre-alpha)
               ├── api-gateway/application.yaml
               ├── brain/application.yaml
               ├── dashboard/application.yaml
               ├── pentest-worker/application.yaml
               ├── infrastructure/postgres/application.yaml
               └── infrastructure/temporal/application.yaml
```

---

## 🌊 Sync Waves (Deployment Order)

ArgoCD deploys resources in the order defined by the `argocd.argoproj.io/sync-wave` annotation:

| Wave | Services |
|---|---|
| `1` | `postgresql`, `temporal` (infrastructure layer) |
| `2` | `api-gateway`, `brain`, `dashboard`, `pentest-worker` (application layer) |

This guarantees that databases and the workflow engine are available **before** the microservices start.

---

## 🎯 Generic Helm Chart (`aegis-service`)

All microservices share a generic Helm chart located at:

```
kubernetes/charts/aegis-service/
├── Chart.yaml          # Chart metadata (version 0.1.0)
├── values.yaml         # Default values
└── templates/
    ├── deployment.yaml # Kubernetes Deployment
    ├── service.yaml    # ClusterIP Service
    └── ingress.yaml    # Ingress (optional)
```

### Per-Environment Value Overrides

Each service in each environment has its own `values.yaml` file under `kubernetes/envs/<env>/<service>/values.yaml`. This file overrides the chart's default values.

**Example — `brain/values.yaml` (pre-alpha):**
```yaml
nameOverride: "brain-pre-alpha"
replicaCount: 1
image:
  repository: ghcr.io/aegis-ai-organizations/aegis-ai-brain
  tag: "latest"
  pullPolicy: Always
service:
  port: 8080
  targetPort: 8080
env:
  - name: DB_HOST
    value: "aegis-postgres-pre-alpha.aegis-system.svc.cluster.local:5432"
  - name: TEMPORAL_HOST
    value: "temporal.aegis-system.svc.cluster.local:7233"
resources:
  limits:
    cpu: 300m
    memory: 512Mi
```

---

## 🔗 Namespaces

| Namespace | Contents |
|---|---|
| `argocd` | ArgoCD (GitOps controller) |
| `aegis-system` | All Aegis services (microservices + infra) |
| `ingress-nginx` | Nginx Ingress Controller |
| `sandbox-*` | Isolated sandbox namespaces (gVisor required) |

---

## 🌐 Ingress

The Nginx Ingress Controller is used to expose HTTP services. In pre-alpha, only the **api-gateway** has an Ingress enabled on `api.aegis.pre-alpha.local`.

To access it locally, add this entry to `/etc/hosts`:
```
127.0.0.1   api.aegis.pre-alpha.local
```

---

## 🔍 Useful Commands

```bash
# Status of all ArgoCD applications
kubectl get applications -n argocd

# Status of all pods in aegis-system
kubectl get pods -n aegis-system

# Stream logs for a pod
kubectl logs -n aegis-system <pod-name> -f

# Describe a resource (useful for debugging)
kubectl describe pod -n aegis-system <pod-name>

# View recent events
kubectl get events -n aegis-system --sort-by='.lastTimestamp'

# Port-forward to a service
kubectl port-forward svc/<service-name> -n aegis-system <local-port>:<remote-port>
```

---

## 📖 Further Reading

- [Getting Started — Run locally](getting-started.md)
- [Global Architecture](architecture.md)
- [Cilium Network Policies](cilium-network.md)
- [gVisor Sandbox Runtime](gvisor-sandbox.md)
- [Official ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [Official Helm Documentation](https://helm.sh/docs/)
