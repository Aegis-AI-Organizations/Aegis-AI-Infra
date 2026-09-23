# MVP Demo Checklist

## Before Demo

- Run `make build-local-mvp-images` if any MVP service code changed locally.
- Verify ArgoCD: `kubectl -n argocd get application aegis-api-gateway-mvp aegis-brain-mvp aegis-crewai-worker-mvp aegis-pentest-worker-mvp aegis-db-init-mvp -o wide`.
- Verify pods: `kubectl -n aegis-system get pods -o wide`.
- Verify no MVP-critical image pulls are broken: `kubectl -n aegis-system get pods -o wide | grep -E 'ImagePullBackOff|ErrImagePull' || true`.
- Verify stale workflows: `make temporal-list-graph-pentest-workflows`.
- If stale `Running` graph workflows exist, run `CONFIRM=terminate-stale-graph-pentest make temporal-cleanup-stale-graph-pentest-workflows`.

## Local E2E Commands

- DNS path: `make setup-dns && make e2e-local-loop`.
- DNS-free fallback: `make e2e-local-loop-port-forward`.
- Use the port-forward path when `api.aegis.mvp.local` does not resolve or routes to the wrong ingress address.
- Validate local operations without launching a scan: `bash scripts/validate-local-devops-loop.sh`.
- Validate predictable local image tags: `bash scripts/validate-predictable-deployments.sh`.
- Rebuild all local MVP images after service code changes: `make build-local-mvp-images`.

## Demo Path

- Start API fallback path with `make e2e-local-loop-port-forward` for a deterministic CLI demo.
- Confirm login succeeds through the seeded account.
- Confirm target topology upload succeeds and a scan ID is created.
- Confirm scan progresses to `COMPLETED`.
- Confirm vulnerabilities include `aegis-flag-1234`.
- Confirm Brain logs show `CrewAI pentest analysis status=COMPLETED`.
- Confirm report generation logs include `Stored PDF report`.

## Expected Evidence

- Final scan status: `COMPLETED`.
- At least one `CRITICAL` SQL Injection vulnerability.
- Loot proof: `aegis-flag-1234`.
- CrewAI report persisted, with deterministic fallback if Ollama is unavailable.
- PDF report stored in MinIO.
- Sandbox cleanup requested after report generation.

## Redeploy Reproducibility Check

- Restart Brain and CrewAI: `kubectl -n aegis-system rollout restart deploy/brain-mvp deploy/crewai-worker-mvp`.
- Wait for Brain: `kubectl -n aegis-system rollout status deploy/brain-mvp --timeout=180s`.
- Wait for CrewAI: `kubectl -n aegis-system rollout status deploy/crewai-worker-mvp --timeout=180s`.
- Run e2e: `make e2e-local-loop-port-forward`.
- Confirm Brain logs include `CrewAI pentest analysis status=COMPLETED` and `Stored PDF report`.

## Temporal Operations

- List workflows: `make temporal-list-graph-pentest-workflows`.
- Cleanup is guarded and must stay explicit: `CONFIRM=terminate-stale-graph-pentest make temporal-cleanup-stale-graph-pentest-workflows`.
- Do not automate stale workflow termination until the team validates that terminating old `Running` `graph-pentest-workflow-*` executions is expected behavior.

## Known Local Notes

- DNS path remains `make e2e-local-loop`; port-forward path is the fallback when `api.aegis.mvp.local` is unavailable.
- Temporal admintools currently talks to the local MVP frontend in plaintext on port `7233`; helper scripts unset stale `TEMPORAL_CLI_TLS_*` variables for CLI operations.
- Ollama is optional for local MVP demo; when unreachable, CrewAI uses the Worker Pentest report as deterministic evidence.
