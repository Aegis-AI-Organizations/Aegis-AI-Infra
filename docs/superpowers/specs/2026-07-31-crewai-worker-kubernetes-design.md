# CrewAI Worker Kubernetes Deployment Design

## Goal

Deploy the `Aegis-AI-Agent-Crew` image as a non-destructive Temporal worker in the MVP Kubernetes environment.

This is Sprint 2 of the CrewAI integration path. Sprint 1 published the Docker image to GHCR. Sprint 2 must make the worker run in-cluster, connect to Temporal, reach the external Ollama MVP endpoint, and stay ready for Sprint 3 Brain integration.

## Recommended Approach

Use the existing `kubernetes/charts/aegis-service` Helm chart and add a new ArgoCD application under `kubernetes/envs/mvp/crewai-worker/`.

This matches the current MVP worker pattern used by `pentest-worker`, `ingest-worker`, and `deployer-worker`:

- ArgoCD owns deployment lifecycle.
- Helm values hold worker-specific runtime config.
- KEDA can scale from Temporal queue depth.
- Cilium network policy restricts egress.
- No bespoke chart is needed for this first worker deployment.

## Kubernetes Resources

Add these files:

- `kubernetes/envs/mvp/crewai-worker/application.yaml`
- `kubernetes/envs/mvp/crewai-worker/values.yaml`

Update this file:

- `kubernetes/envs/mvp/kustomization.yaml`

The ArgoCD application name should be `aegis-crewai-worker-mvp`, target namespace `aegis-system`, sync wave `3`, and source path `kubernetes/charts/aegis-service`.

The Helm release should use `nameOverride: "crewai-worker-mvp"`.

## Runtime Configuration

The worker container runs the published CrewAI image in worker mode:

- `CREWAI_MODE=worker`
- `TEMPORAL_HOST=aegis-temporal-mvp-frontend.aegis-system.svc.cluster.local:7233`
- `TEMPORAL_NAMESPACE` from `aegis-env/TEMPORAL_NAMESPACE`
- `CREWAI_TASK_QUEUE=CREWAI_TASK_QUEUE`
- `TEMPORAL_TLS_ENABLE=false`

CrewAI LLM role defaults should point to the external Ollama MVP endpoint running on the Mac host:

- `PLANNER_PROVIDER=ollama`
- `PLANNER_MODEL=llama3.1:8b`
- `PLANNER_API_BASE=http://host.docker.internal:11434`
- `GUIDER_PROVIDER=ollama`
- `GUIDER_MODEL=whiterabbitneo`
- `GUIDER_API_BASE=http://host.docker.internal:11434`
- `EXECUTOR_PROVIDER=ollama`
- `EXECUTOR_MODEL=deepseek-coder-v2`
- `EXECUTOR_API_BASE=http://host.docker.internal:11434`

If `host.docker.internal` is not reachable from pods, use the Mac LAN IP and update all three `*_API_BASE` values consistently.

Use the GHCR image published by Sprint 1:

- repository: `ghcr.io/aegis-ai-organizations/aegis-ai-agent-crew`
- tag: the confirmed release tag, or `latest` if the MVP should track the newest Crew image during active integration.

## Scaling

Enable KEDA with a Temporal trigger:

- `minReplicaCount: 1` for Sprint 2 so connection failures surface immediately.
- `maxReplicaCount: 5` initially to protect the external Mac-hosted Ollama process and laptop clusters.
- `taskQueue: CREWAI_TASK_QUEUE`
- `endpoint: aegis-temporal-mvp-frontend.aegis-system.svc.cluster.local:7233`
- `queueTypes: workflow,activity`
- `targetQueueSize: 1`
- `activationTargetQueueSize: 0`
- `useTLS: false`

Sprint 4 can revisit `maxReplicaCount` after the 50-scan robustness campaign measures Ollama and worker load.

## Security And Network Policy

CrewAI V1 is non-destructive and must not mutate the cluster.

Do not grant Kubernetes RBAC for this worker unless a later Sprint introduces a concrete need. The worker should not need a service account token for Kubernetes API writes.

Enable Cilium network policy with:

- DNS egress enabled.
- Egress to Temporal frontend on TCP `7233`.
- Egress to the external Ollama endpoint on TCP `11434`.

No ingress is required. The worker is driven by Temporal polling only.

## Resource Profile

Initial conservative requests and limits:

- requests: `cpu: 250m`, `memory: 512Mi`
- limits: `cpu: 1000m`, `memory: 2Gi`

CrewAI plus LLM orchestration can consume more memory than the Go/Rust workers. These values are intentionally higher than `pentest-worker` but still safe for the MVP cluster.

## Deployment Flow

1. Add the ArgoCD application and values.
2. Add the application to the MVP kustomization.
3. Render manifests locally with Helm or Kustomize where available.
4. Run repository validation scripts and pre-commit.
5. Push through PR and let ArgoCD sync.
6. Verify the pod is running in `aegis-system`.
7. Verify logs show Temporal connection and worker startup.
8. Verify Temporal sees a worker polling `CREWAI_TASK_QUEUE`.

## Verification

Local verification before PR:

- `helm template crewai-worker-mvp kubernetes/charts/aegis-service -f kubernetes/envs/mvp/crewai-worker/values.yaml`
- `kubectl kustomize kubernetes/envs/mvp`
- `git diff --check`
- `pre-commit run --all-files`
- `graphify update .`

Cluster verification after ArgoCD sync:

- `kubectl get application aegis-crewai-worker-mvp -n argocd`
- `kubectl get pods -n aegis-system -l app=crewai-worker-mvp`
- `kubectl logs -n aegis-system deploy/crewai-worker-mvp`
- confirm logs include connection to Temporal host and task queue `CREWAI_TASK_QUEUE`.
- confirm the worker does not report `OLLAMA_UNREACHABLE` when probing the configured external Ollama URL.
- if the worker reports `OLLAMA_UNREACHABLE`, verify `ollama serve` is running on the Mac host and probe `http://host.docker.internal:11434/api/tags` from an ephemeral pod before changing CrewAI code.

## Out Of Scope

Sprint 2 does not modify Brain workflows.

Sprint 2 does not enqueue `run_crew_pentest` activities from production scans.

Sprint 2 does not add Kubernetes write permissions to CrewAI.

Sprint 2 does not require Docker local builds, because image publication is already validated by GitHub Actions and GHCR.

Sprint 2 does not deploy Ollama into Kubernetes. Ollama remains external and host-managed for the MacBook MVP.

## Risks

The Infra repo currently has local uncommitted changes unrelated to this design. Implementation must preserve them and stage only CrewAI files.

The external Ollama endpoint must be reachable from pods before finalizing values. Start with `http://host.docker.internal:11434`; if pod-level probing fails, use the Mac LAN IP instead.

The CrewAI image tag must be confirmed before values are committed. `latest` is acceptable for fast MVP iteration only if the team accepts mutable image behavior.

## Self-Review

No placeholders remain. The design is scoped to Kubernetes deployment only and explicitly excludes Brain integration. The runtime env, network policy, scaling, and verification steps match the current MVP worker deployment pattern. Ollama is intentionally external for the MacBook MVP and covered by `2026-07-31-external-ollama-mvp-design.md`.
