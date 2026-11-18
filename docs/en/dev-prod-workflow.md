# Dev / Prod Environments — Aegis AI Infra

> ⚠️ **Never modify, commit, or push this repository from leCube5080. Every
> change must be authored and validated on a developer workstation, then
> deployed to production by ArgoCD.**

---

## 1. Architecture

```
kubernetes/
├── bootstrap/
│   ├── root-app-mvp.yaml   # Root ArgoCD Application currently live on leCube5080
│   ├── root-app-prod.yaml  # Same Application (identical name), path -> envs/prod
│   └── root-app-dev.yaml   # Optional root app for exercising ArgoCD locally
├── envs/
│   ├── mvp/   # Currently-deployed state. Kept temporarily (see §8).
│   ├── prod/  # Kustomize overlay of envs/mvp: same names, 2 corrections.
│   └── dev/
│       ├── dev-core/  # Default profile: Postgres, Redis, api-gateway, brain, dashboard
│       └── dev-full/  # dev-core + Temporal, MinIO, Neo4j, ClickHouse, KEDA, workers
├── charts/aegis-service/  # Generic Helm chart, reused by mvp/prod/dev
└── local-target/          # Deterministic SQLi target for e2e tests (unchanged)
```

`envs/prod/kustomization.yaml` does not duplicate `envs/mvp`: it lists it as
its base (`resources: [../mvp]`) and applies two JSON6902 patches
(cert-manager, PostgreSQL). Every ArgoCD Application name, Helm release
name, and PVC name stays identical between `mvp` and `prod` — that is what
makes the cutover non-destructive (details in
`kubernetes/envs/prod/README.md`).

`envs/dev` does not reuse `envs/mvp`: prod's mTLS/Temporal/Cloudflare
complexity has no place on a developer laptop, so dev is a deliberately
simpler configuration, written independently.

## 2. Role of Git, ArgoCD, and leCube5080

- **Git** is the only source of truth. Every infrastructure change goes
  through a branch, review, and a merge to `main`.
- **ArgoCD**, installed on leCube5080, continuously watches the `main`
  branch and syncs the production cluster to the state declared under
  `kubernetes/envs/prod`.
- **leCube5080** never runs `git commit` or `git push`. It only receives
  changes through ArgoCD.

## 3. Developer workflow

```bash
git checkout -b feat/my-feature

make dev-create                 # creates the "aegis-dev" kind cluster
make dev-build                  # builds local images, tagged "dev-local"
make dev-deploy                 # kubectl apply -k kubernetes/envs/dev/dev-core

make dev-status                 # checks pod/ingress state
make dev-logs SERVICE=brain-dev # follows a service's logs

# ... development iterations ...

make validate                   # yamllint + kubectl kustomize on every env
make render-dev                 # local, read-only render of the dev manifest

make dev-destroy                # tears down the kind cluster when done
```

For the full stack (Temporal, MinIO, Neo4j, ClickHouse, workers):
`make dev-build PROFILE=dev-full && make dev-deploy PROFILE=dev-full`.

Once local testing passes: open a Pull Request against `main` following the
repo's Git workflow (see `.github/workflows/linting.yml` for the
`[TYPE] Message` commit format).

## 4. Production workflow

- **No development happens on leCube5080.** No pushes from leCube5080.
- ArgoCD watches `main` and automatically syncs `kubernetes/envs/prod`
  (`prune: true`, `selfHeal: true`).
- **Initial bootstrap** (already done today via `root-app-mvp.yaml`):
  `kubectl apply -f kubernetes/bootstrap/root-app-mvp.yaml` on leCube5080's
  ArgoCD cluster.
- **Cutover to `envs/prod`**: see the detailed procedure and guardrails in
  `kubernetes/envs/prod/README.md`. In short — only one root Application at
  a time; never apply `root-app-mvp.yaml` and `root-app-prod.yaml`
  simultaneously.
- **Rollback**: `git revert` the offending commit on `main`. ArgoCD
  automatically resyncs the previous state (`selfHeal: true`). No manual
  `kubectl` command is needed on leCube5080 for a standard rollback.
- Any script under `scripts/prod-*.sh` is limited to validation, rendering,
  and explicit GitOps bootstrap — never a direct deployment of application
  workloads. See `scripts/lib/kube-context-guard.sh`: these scripts refuse to
  run unless `PROD_KUBE_CONTEXT` is explicitly set and matches the current
  `kubectl` context exactly.

## 5. Secrets management

- No real secret is ever committed. `.env.example` (repo root) and
  `kubernetes/envs/dev/secret.example.yaml` document the expected shape with
  placeholder values.
- In both prod and dev, services read the same Kubernetes Secret `aegis-env`
  (same keys). `make dev-deploy` builds this Secret from the developer's
  local `.env` (never committed) and applies it in the `aegis-dev` namespace.
- In prod, `aegis-env` is injected manually by an operator on leCube5080
  (outside of Git).

## 6. Local prerequisites

- `kind` (cluster `aegis-dev`, node image pinned in
  `kubernetes/envs/dev/kind-aegis-dev.yaml`)
- `kubectl` ≥ 1.28, `docker`
- Optional (`make dev-deploy-argocd`): no extra tooling — the script installs
  ArgoCD inside the kind cluster itself.

## 7. dev-core / dev-full / prod differences

| | dev-core | dev-full | prod |
|---|---|---|---|
| Namespace | `aegis-dev` | `aegis-dev` | `aegis-system` |
| Replicas | 1 | 1 | per service |
| mTLS / cert-manager | disabled | disabled | enabled (`v1.21.3`) |
| Temporal/MinIO/Neo4j/ClickHouse | absent | present (reduced tags/replicas) | present |
| Cloudflare Tunnel | absent | absent | present |
| gVisor | absent (RuntimeClass unavailable on kind) | absent | present where required |
| GPU | never required (Ollama runs on the host, CPU or GPU) | same | same |
| Images | local build, `dev-local` tag, `pullPolicy: Never` | same | explicit immutable tags |
| PVCs | small (≤1Gi) | small (≤1Gi) | existing production sizes |

## 8. Progressive migration from `envs/mvp`

1. **Today**: `envs/mvp` is the live state on leCube5080, driven by
   `root-app-mvp.yaml`. Nothing changes yet.
2. **This change** adds `envs/prod` (an overlay of `envs/mvp`) and `envs/dev`,
   without touching `envs/mvp` or `root-app-mvp.yaml`.
3. **Validation**: `make validate` must pass; the diff between
   `kubectl kustomize kubernetes/envs/mvp` and
   `kubectl kustomize kubernetes/envs/prod` must be limited to the two
   corrections (cert-manager, PostgreSQL).
4. **Cutover** (operator, on leCube5080, after merge): follow
   `kubernetes/envs/prod/README.md`. It's an in-place edit of the same
   ArgoCD Application (`aegis-prototype-mvp`) — never two root apps active
   at once.
5. **Retiring `envs/mvp`**: only once `envs/prod` has been confirmed stable
   through at least one full deploy cycle. At that point `root-app-mvp.yaml`
   can be removed and `envs/mvp` retired in a dedicated PR.

## See also

- [Kubernetes — manifests and App of Apps](kubernetes.md)
- [`kubernetes/envs/prod/README.md`](../../kubernetes/envs/prod/README.md) — detailed cutover procedure
- [Global Architecture](architecture.md)
