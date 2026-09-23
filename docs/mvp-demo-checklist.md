# MVP Demo Checklist

## Before Demo

- Run `make build-local-mvp-images` if any MVP service code changed locally.
- Verify ArgoCD: `kubectl -n argocd get application aegis-api-gateway-mvp aegis-brain-mvp aegis-crewai-worker-mvp aegis-pentest-worker-mvp aegis-db-init-mvp -o wide`.
- Verify pods: `kubectl -n aegis-system get pods -o wide`.
- Verify stale workflows: `make temporal-list-graph-pentest-workflows`.
- If stale `Running` graph workflows exist, run `CONFIRM=terminate-stale-graph-pentest make temporal-cleanup-stale-graph-pentest-workflows`.

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

## Known Local Notes

- DNS path remains `make e2e-local-loop`; port-forward path is the fallback when `api.aegis.mvp.local` is unavailable.
- Temporal admintools currently talks to the local MVP frontend in plaintext on port `7233`; helper scripts unset stale `TEMPORAL_CLI_TLS_*` variables for CLI operations.
- Ollama is optional for local MVP demo; when unreachable, CrewAI uses the Worker Pentest report as deterministic evidence.
