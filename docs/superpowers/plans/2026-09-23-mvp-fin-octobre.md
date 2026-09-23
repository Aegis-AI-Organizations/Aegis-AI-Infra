# MVP Fin Octobre Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stabiliser un MVP Aegis AI reproductible d'ici fin octobre, capable de lancer un scan, déployer une sandbox, exécuter un pentest, produire des vulnérabilités et générer un rapport.

**Architecture:** Le MVP reste GitOps via ArgoCD sur l'environnement Kubernetes `mvp`. Les chemins critiques sont API Gateway -> Brain -> Temporal -> Deployer/CrewAI/Worker Pentest -> MinIO/rapport. Les validations locales passent soit par DNS local (`make setup-dns`), soit par port-forward (`make e2e-local-loop-port-forward`) pour éviter de bloquer sur `/etc/hosts`.

**Tech Stack:** Kubernetes OrbStack, ArgoCD, Temporal, KEDA, PostgreSQL, MinIO, Neo4j, Python workers, Go API Gateway, React Dashboard.

**Spec:** This plan is operational and based on the current MVP stabilization work in `Aegis-AI-Infra`.

## Global Constraints

- Pentest traffic must target only the sandbox endpoint produced by Worker-Deployer.
- Do not target source infrastructure services such as Neo4j, PostgreSQL, Temporal, MinIO, or control-plane APIs.
- Local MVP images must use locally available tags with `pullPolicy: IfNotPresent` unless a published GHCR tag is intentionally promoted.
- `make e2e-local-loop` must remain the DNS-based path; `make e2e-local-loop-port-forward` is the no-hosts-file fallback.
- Temporal workflow cleanup must require explicit confirmation before termination.

---

### Task 1: Stabilize Local MVP GitOps Images

**Files:**
- Modify: `kubernetes/envs/mvp/api-gateway/values.yaml`
- Modify: `kubernetes/envs/mvp/brain/values.yaml`
- Modify: `kubernetes/envs/mvp/crewai-worker/values.yaml`
- Modify: `kubernetes/envs/mvp/pentest-worker/values.yaml`
- Modify: `scripts/validate-local-devops-loop.sh`
- Modify: `scripts/validate-predictable-deployments.sh`

**Interfaces:**
- Consumes: local images in OrbStack Docker.
- Produces: ArgoCD-synced deployments using `crewai-fields-local`, `crewai-primary-local`, and `tool-runner-local` tags.

- [ ] **Step 1: Run failing validation before changing values**

Run: `bash scripts/validate-local-devops-loop.sh`
Expected: FAIL if any MVP component uses a remote-only tag or `pullPolicy: Always`.

- [ ] **Step 2: Update values to local MVP tags**

Set API Gateway to `ghcr.io/aegis-ai-organizations/aegis-ai-api-gateway:crewai-fields-local`.
Set Brain to `ghcr.io/aegis-ai-organizations/aegis-ai-brain:crewai-primary-local`.
Set CrewAI to `ghcr.io/aegis-ai-organizations/aegis-ai-agent-crew:tool-runner-local`.
Set Worker Pentest to `ghcr.io/aegis-ai-organizations/aegis-ai-worker-pentest:tool-runner-local`.

- [ ] **Step 3: Verify validators pass**

Run: `bash scripts/validate-local-devops-loop.sh && bash scripts/validate-predictable-deployments.sh`
Expected: both commands exit 0.

- [ ] **Step 4: Push to main so ArgoCD syncs the same source**

Run: `git push origin HEAD:main`
Expected: ArgoCD Applications sync to the pushed revision.

### Task 2: Make E2E Validation Reproducible Without DNS Setup

**Files:**
- Create: `scripts/e2e-local-loop-port-forward.sh`
- Modify: `Makefile`
- Modify: `scripts/validate-local-devops-loop.sh`

**Interfaces:**
- Consumes: `scripts/e2e-local-loop.sh`.
- Produces: `make e2e-local-loop-port-forward`.

- [ ] **Step 1: Validate script presence and Make target**

Run: `bash scripts/validate-local-devops-loop.sh`
Expected: PASS only when the wrapper script and Make target are present.

- [ ] **Step 2: Run e2e through port-forward**

Run: `make e2e-local-loop-port-forward`
Expected: scan reaches `COMPLETED` and reports `aegis-flag-1234` in vulnerabilities or evidence.

### Task 3: Add Safe Temporal Workflow Operations

**Files:**
- Create: `scripts/temporal-list-graph-pentest-workflows.sh`
- Create: `scripts/temporal-cleanup-stale-graph-pentest-workflows.sh`
- Modify: `Makefile`
- Modify: `scripts/validate-local-devops-loop.sh`

**Interfaces:**
- Consumes: Temporal admin tools deployment `aegis-temporal-mvp-admintools`.
- Produces: read-only workflow listing and guarded termination command.

- [ ] **Step 1: List graph pentest workflows**

Run: `make temporal-list-graph-pentest-workflows`
Expected: table of `graph-pentest-workflow-*` executions or an empty list.

- [ ] **Step 2: Confirm cleanup guard refuses unsafe runs**

Run: `bash scripts/temporal-cleanup-stale-graph-pentest-workflows.sh`
Expected: FAIL with an instruction requiring `CONFIRM=terminate-stale-graph-pentest`.

- [ ] **Step 3: Terminate only stale running workflows when explicitly confirmed**

Run: `CONFIRM=terminate-stale-graph-pentest make temporal-cleanup-stale-graph-pentest-workflows`
Expected: only running `graph-pentest-workflow-*` executions are terminated.

### Task 4: Weekly MVP Operating Rhythm

**Files:**
- Modify: `docs/superpowers/plans/2026-09-23-mvp-fin-octobre.md`

**Interfaces:**
- Consumes: current MVP status and e2e evidence.
- Produces: weekly execution focus.

- [ ] **Week of Sep 23: Environment stability**

Keep ArgoCD synced, remove `ImagePullBackOff`, prove e2e with port-forward, and document Temporal cleanup.

- [ ] **Week of Sep 30: Product path hardening**

Validate Dashboard/API scan creation, report download, user-facing error states, and repeatable sandbox cleanup.

- [ ] **Week of Oct 7: Fresh cluster reproducibility**

Run teardown/setup from scratch and verify e2e without relying on old pods or manual patches.

- [ ] **Week of Oct 14: Demo readiness**

Prepare a deterministic demo script: login, create scan, monitor progress, inspect vulnerabilities, download report.

- [ ] **Week of Oct 21: Buffer and polish**

Fix remaining flakes, update documentation, freeze MVP scope, and avoid risky feature expansion.

### Task 5: Final Verification

**Files:**
- No file changes.

**Interfaces:**
- Consumes: tasks 1-4.
- Produces: MVP readiness evidence.

- [ ] **Step 1: Verify cluster health**

Run: `kubectl -n aegis-system get pods -o wide`
Expected: core pods are `Running` or completed jobs are `Completed`; no active `ImagePullBackOff` for MVP-critical deployments.

- [ ] **Step 2: Verify ArgoCD source**

Run: `kubectl -n argocd get application aegis-api-gateway-mvp aegis-brain-mvp aegis-crewai-worker-mvp aegis-pentest-worker-mvp -o wide`
Expected: applications are `Synced` and `Healthy` on the intended commit.

- [ ] **Step 3: Verify e2e**

Run: `make e2e-local-loop-port-forward`
Expected: `Local DevOps loop succeeded: aegis-flag-1234 extracted.`

## Self-Review

- Spec coverage: image stability, e2e fallback, Temporal cleanup, weekly MVP milestones, and final verification are covered.
- Placeholder scan: no placeholder tasks remain.
- Type consistency: shell script names and Make targets match the tasks above.
