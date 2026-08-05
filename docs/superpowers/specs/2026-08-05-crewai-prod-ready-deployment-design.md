# CrewAI Prod-Ready Deployment Design

## Goal

Make the CrewAI worker deployment production-ready from an infrastructure and release perspective, without changing Brain scan orchestration in this iteration.

The target state is a fresh Kubernetes cluster that can pull the CrewAI image from GHCR without relying on a local Orbstack image cache, deploy the worker through ArgoCD, connect it to Temporal, and expose enough CI/security checks to catch common image and deployment regressions before release.

## Scope

This design covers two repositories:

- `Aegis-AI-Agent-Crew`: container image, release workflow, CI checks, runtime image hardening, and deployment documentation.
- `Aegis-AI-Infra`: Helm chart capabilities, MVP values, ArgoCD deployment, KEDA, network policy, and operator runbook.

This design intentionally does not change Brain/API behavior. Brain-to-CrewAI workflow integration, result mapping, and scan feature flags belong in a later spec.

## Non-Goals

- Do not add destructive CrewAI capabilities.
- Do not add Kubernetes API permissions to the CrewAI pod.
- Do not deploy Ollama in-cluster for the MVP MacBook target.
- Do not replace the existing Pentest worker path in Brain.
- Do not introduce a secret-managed GHCR pull path, because the selected strategy is a public GHCR package.

## Decisions

### GHCR Visibility

The CrewAI image package should be publicly pullable from GHCR.

Rationale: the current cluster has no registry secret pattern, other local services rely on images already present in Orbstack, and a production-like deployment should not depend on node-local image cache. Public GHCR keeps the Kubernetes deployment simple while still allowing immutable tag pinning.

### Image Tags

Kubernetes must continue pinning a concrete release tag such as `v2.0.8`. The deployment must not use `latest`.

The release workflow may continue publishing `latest` for humans, but manifests and validation scripts must reject `latest` in Kubernetes values.

### Runtime Model Endpoint

For MVP, CrewAI continues to use external Ollama on macOS through `http://host.docker.internal:11434`.

Production-ready here means configurable, validated, and documented. It does not mean HA Ollama in Kubernetes.

## Architecture

CrewAI remains a Temporal activity worker:

1. ArgoCD deploys `crewai-worker-mvp` from the generic `aegis-service` chart.
2. KEDA keeps at least one worker replica available and can scale on `CREWAI_TASK_QUEUE` backlog.
3. The worker connects to `aegis-temporal-mvp-frontend` on port `7233`.
4. The worker calls external Ollama on `host.docker.internal:11434` for planner, guider, and executor models.
5. Cilium egress policy allows only DNS, Temporal, and external Ollama.

The worker does not expose user traffic. Any readiness strategy must reflect worker startup, not HTTP request serving.

## Agent-Crew Changes

### Dockerfile Hardening

The image should retain:

- `python:3.12-slim` base.
- non-root `aegis` runtime user.
- `CREWAI_MODE=worker` default.
- explicit writable `HOME=/home/aegis`.
- ownership of `/app` and `/home/aegis` by `aegis`.

The image should add or verify:

- a `.dockerignore` that excludes git metadata, caches, graph output, local env files, and test artifacts not needed at runtime.
- no secrets or local model data copied into the image.
- a deterministic container smoke test in CI that imports `src.worker` or starts a harmless mode without requiring Temporal.

### CI and Release

CI should validate the Docker path before release:

- `uv run python -m compileall src`.
- `PYTHONPATH=. uv run pytest -q`.
- `docker build` for the runtime image.
- a smoke command against the built image that proves the Python environment can import the worker modules as the non-root user.
- a vulnerability scan using a pragmatic scanner such as Trivy.
- SBOM generation if supported by the selected GitHub Action without introducing fragile credentials.

The release workflow should:

- keep publishing immutable `v2.0.<run_number>` tags.
- keep publishing `latest` only as a convenience tag.
- document the manual GHCR package visibility setting required to make the package public.

### Observability

The worker already logs Temporal host, namespace, and task queue on startup. Keep those logs, but avoid logging secrets or payload bodies.

If additional health output is added, it must be safe for production logs.

## Infra Changes

### Helm Chart Capabilities

The generic `aegis-service` chart should support the following opt-in fields:

- `imagePullSecrets`, even though CrewAI should not require it with public GHCR. This keeps the chart usable for private images.
- `command` and `args`, for future worker smoke/debug entrypoints.
- `podSecurityContext`, to complement container `securityContext`.
- richer labels and annotations on pod templates.
- non-HTTP probe flexibility or a documented choice to keep probes disabled for non-HTTP workers.

The existing TriggerAuthentication template should either be wired into ScaledObject via `authenticationRef` when enabled, or documented as unsupported for current Temporal scaler use.

### CrewAI MVP Values

The CrewAI values should keep:

- image tag pinned to the selected release.
- `imagePullPolicy: IfNotPresent` for local efficiency.
- `CREWAI_MODE=worker`.
- `CREWAI_TASK_QUEUE=CREWAI_TASK_QUEUE`.
- Temporal host and namespace from existing cluster config.
- external Ollama model variables.
- KEDA min replica count of `1` for MVP reliability.
- network policy egress to Temporal and external Ollama only.

The values should add or clarify:

- explicit `podSecurityContext` where compatible with the image.
- optional `imagePullSecrets: []` to document that none are required for public GHCR.
- comments or docs explaining that a fresh cluster should pull from GHCR, while local Orbstack cache is only a fallback.

### Deployment Validation

Infra validation should continue rejecting `latest` in Kubernetes manifests.

Additional checks should validate that CrewAI renders:

- a pinned GHCR image tag.
- KEDA `ScaledObject` for `CREWAI_TASK_QUEUE`.
- Temporal egress.
- Ollama FQDN egress.
- no ServiceAccount token mount unless explicitly required.

## Error Handling and Rollback

Operators should be able to distinguish four failure classes:

- GHCR pull failure: pod events show `ImagePullBackOff` or `unauthorized`.
- Image runtime failure: pod logs show Python/container startup errors.
- Temporal failure: worker logs fail before `Agent Crew worker started` or KEDA scaler cannot connect.
- Ollama failure: activity logs fail model endpoint checks when work is executed.

Rollback should use the previous pinned image tag in `kubernetes/envs/mvp/crewai-worker/values.yaml`, then rely on ArgoCD sync.

## Testing Strategy

### Agent-Crew

- Unit tests for Dockerfile invariants, including writable non-root home.
- Existing activity contract and worker tests stay in place.
- CI runs full tests with `uv`.
- CI builds the Docker image.
- CI runs a non-network container smoke test.
- CI scans the built image.

### Infra

- `helm template crewai-worker-mvp kubernetes/charts/aegis-service -f kubernetes/envs/mvp/crewai-worker/values.yaml`.
- `kubectl kustomize kubernetes/envs/mvp`.
- `bash scripts/validate-predictable-deployments.sh`.
- Existing pre-commit hooks.
- Optional targeted tests for rendered `imagePullSecrets`, `authenticationRef`, and CrewAI values if the repo already has a test harness.

### Runtime Verification

After deployment:

- `kubectl get deployment crewai-worker-mvp -n aegis-system -o wide` shows `1/1` ready.
- `kubectl logs -n aegis-system deployment/crewai-worker-mvp` includes `Agent Crew worker started`.
- `kubectl describe pod` shows the image was pulled or found locally and no restart loop.
- An Ollama probe pod can reach `http://host.docker.internal:11434/api/tags`.

## Security Notes

- Public GHCR means the image must not contain secrets, private data, or local model weights.
- The worker remains non-root and should not mount the Kubernetes ServiceAccount token.
- Network egress remains allowlisted.
- The worker does not need RBAC for this iteration.
- Scanner findings should fail CI only for high or critical vulnerabilities where the scanner supports severity filtering with acceptable noise.

## Acceptance Criteria

- A fresh cluster can pull `ghcr.io/aegis-ai-organizations/aegis-ai-agent-crew:<pinned-tag>` without local image cache.
- CrewAI deployment reaches `1/1 Ready` through ArgoCD.
- Worker logs show successful Temporal startup.
- CI catches Dockerfile regressions that would break non-root startup.
- CI builds and smoke-tests the container image.
- CI generates image vulnerability feedback before release.
- Infra render checks verify pinned image, KEDA queue, Temporal egress, Ollama egress, and disabled token mount.
- Operator docs explain deploy, verify, troubleshoot, and rollback.

## Follow-Up Spec

The next spec should cover Brain-to-CrewAI integration:

- add `CREWAI_TASK_QUEUE` config in Brain.
- add a feature flag choosing Pentest worker or CrewAI.
- call `run_crew_pentest` during the existing attacking phase.
- map CrewAI results into vulnerabilities/report artifacts.
- add end-to-end scan verification.
