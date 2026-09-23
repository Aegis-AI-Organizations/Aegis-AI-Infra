#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_file() {
  local path="$1"
  if [[ ! -f "$ROOT_DIR/$path" ]]; then
    echo "Missing required file: $path" >&2
    exit 1
  fi
}

require_grep() {
  local pattern="$1"
  local path="$2"
  if ! grep -qE "$pattern" "$ROOT_DIR/$path"; then
    echo "Missing pattern '$pattern' in $path" >&2
    exit 1
  fi
}

require_file Makefile
require_file scripts/setup-dns.sh
require_file scripts/e2e-local-loop.sh
require_file scripts/e2e-local-loop-port-forward.sh
require_file scripts/temporal-list-graph-pentest-workflows.sh
require_file scripts/temporal-cleanup-stale-graph-pentest-workflows.sh
require_file kubernetes/local-target/kustomization.yaml
require_file kubernetes/local-target/deployment.yaml
require_file kubernetes/local-target/service.yaml
require_file kubernetes/local-target/configmap.yaml
require_file kubernetes/envs/mvp/api-gateway/values.yaml
require_file kubernetes/envs/mvp/brain/values.yaml
require_file kubernetes/envs/mvp/crewai-worker/values.yaml
require_file kubernetes/envs/mvp/pentest-worker/values.yaml
require_file kubernetes/envs/mvp/infrastructure/db-init/manifests/seed.sql
require_file kubernetes/envs/mvp/infrastructure/db-init/manifests/init.sql

require_grep '^setup-dns:' Makefile
require_grep '^deploy-local-target:' Makefile
require_grep '^e2e-local-loop:' Makefile
require_grep '^e2e-local-loop-port-forward:' Makefile
require_grep '^temporal-list-graph-pentest-workflows:' Makefile
require_grep '^temporal-cleanup-stale-graph-pentest-workflows:' Makefile

require_grep 'app\.aegis\.mvp\.local' scripts/setup-dns.sh
require_grep 'api\.aegis\.mvp\.local' scripts/setup-dns.sh
require_grep '/etc/hosts' scripts/setup-dns.sh
require_grep 'ingress-nginx' scripts/setup-dns.sh

require_grep 'aegis-flag-1234' kubernetes/local-target/configmap.yaml
require_grep 'aegis-target' kubernetes/local-target/deployment.yaml
require_grep 'aegis-target' kubernetes/local-target/service.yaml

require_grep 'aegis-flag-1234' scripts/e2e-local-loop.sh
require_grep '/api/auth/login' scripts/e2e-local-loop.sh
require_grep '/api/storage/upload-url' scripts/e2e-local-loop.sh
require_grep '/api/scans' scripts/e2e-local-loop.sh
require_grep 'minio://' scripts/e2e-local-loop.sh
require_grep '"databaseSchemas"' scripts/e2e-local-loop.sh
require_grep '"externalMocks"' scripts/e2e-local-loop.sh
require_grep 'AEGIS_SEED_USER_EMAIL' scripts/e2e-local-loop.sh
require_grep 'AEGIS_SEED_USER_PASSWORD' scripts/e2e-local-loop.sh
require_grep 'port-forward' scripts/e2e-local-loop-port-forward.sh
require_grep 'API_BASE_URL="http://127\.0\.0\.1' scripts/e2e-local-loop-port-forward.sh
require_grep 'WorkflowId STARTS_WITH "graph-pentest-workflow-"' scripts/temporal-list-graph-pentest-workflows.sh
require_grep 'CONFIRM=terminate-stale-graph-pentest' scripts/temporal-cleanup-stale-graph-pentest-workflows.sh

require_grep 'ghcr\.io/aegis-ai-organizations/aegis-ai-api-gateway' kubernetes/envs/mvp/api-gateway/values.yaml
require_grep 'crewai-fields-local' kubernetes/envs/mvp/api-gateway/values.yaml
require_grep 'pullPolicy: IfNotPresent' kubernetes/envs/mvp/api-gateway/values.yaml
require_grep 'crewai-primary-local' kubernetes/envs/mvp/brain/values.yaml
require_grep 'pullPolicy: IfNotPresent' kubernetes/envs/mvp/brain/values.yaml
require_grep 'tool-runner-local' kubernetes/envs/mvp/crewai-worker/values.yaml
require_grep 'pullPolicy: IfNotPresent' kubernetes/envs/mvp/crewai-worker/values.yaml
require_grep 'tool-runner-local' kubernetes/envs/mvp/pentest-worker/values.yaml
require_grep 'pullPolicy: IfNotPresent' kubernetes/envs/mvp/pentest-worker/values.yaml
require_grep 'token_balance' kubernetes/envs/mvp/infrastructure/db-init/manifests/seed.sql
require_grep 'GREATEST\(companies\.token_balance' kubernetes/envs/mvp/infrastructure/db-init/manifests/seed.sql
require_grep 'ADD COLUMN IF NOT EXISTS debug_bundle' kubernetes/envs/mvp/infrastructure/db-init/manifests/init.sql
require_grep 'ADD COLUMN IF NOT EXISTS crew_report_json' kubernetes/envs/mvp/infrastructure/db-init/manifests/init.sql
require_grep 'ADD COLUMN IF NOT EXISTS crew_report_markdown' kubernetes/envs/mvp/infrastructure/db-init/manifests/init.sql
