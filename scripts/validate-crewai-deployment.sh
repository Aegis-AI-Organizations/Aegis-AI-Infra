#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RENDERED="$(mktemp)"
trap 'rm -f "${RENDERED}"' EXIT

helm template crewai-worker-mvp \
  "${ROOT_DIR}/kubernetes/charts/aegis-service" \
  -f "${ROOT_DIR}/kubernetes/envs/mvp/crewai-worker/values.yaml" \
  > "${RENDERED}"

require() {
  local pattern="$1"
  local description="$2"
  if ! grep -Fq "${pattern}" "${RENDERED}"; then
    echo "CrewAI deployment validation failed: missing ${description}" >&2
    echo "Pattern: ${pattern}" >&2
    exit 1
  fi
}

reject() {
  local pattern="$1"
  local description="$2"
  if grep -Fq "${pattern}" "${RENDERED}"; then
    echo "CrewAI deployment validation failed: forbidden ${description}" >&2
    echo "Pattern: ${pattern}" >&2
    exit 1
  fi
}

require "image: \"ghcr.io/aegis-ai-organizations/aegis-ai-agent-crew:v" "pinned CrewAI GHCR image"
reject "aegis-ai-agent-crew:latest" "latest CrewAI image tag"
require "automountServiceAccountToken: false" "disabled service account token mount"
require "runAsNonRoot: true" "non-root pod security context"
reject "runAsNonRoot: false" "root-capable container security context"
require "type: RuntimeDefault" "RuntimeDefault seccomp profile"
require "kind: ScaledObject" "KEDA ScaledObject"
require "taskQueue: CREWAI_TASK_QUEUE" "CrewAI Temporal task queue scaler"
require "serviceName: aegis-temporal-mvp-frontend" "Temporal egress service"
require "matchName: host.docker.internal" "external Ollama FQDN egress"
require "port: \"11434\"" "Ollama TCP egress port"
require "port: \"7233\"" "Temporal TCP egress port"

echo "CrewAI deployment validation passed"
