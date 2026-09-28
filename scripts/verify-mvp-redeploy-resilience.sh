#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-aegis-system}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-240s}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-1200}"

deployments=(
  brain-mvp
  crewai-worker-mvp
  pentest-worker-mvp
  deployer-worker-mvp
)

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "$1 is required" >&2
    exit 1
  fi
}

restart_deployments() {
  local deployment
  for deployment in "${deployments[@]}"; do
    echo "Restarting deployment/$deployment..."
    kubectl -n "$NAMESPACE" rollout restart "deploy/$deployment"
  done
}

wait_for_rollouts() {
  local deployment
  for deployment in "${deployments[@]}"; do
    echo "Waiting for deployment/$deployment rollout..."
    kubectl -n "$NAMESPACE" rollout status "deploy/$deployment" --timeout="$ROLLOUT_TIMEOUT"
  done
}

main() {
  require_command kubectl
  require_command make

  restart_deployments
  wait_for_rollouts
  TIMEOUT_SECONDS="$TIMEOUT_SECONDS" make verify-mvp-pipeline
  echo "MVP redeploy resilience verified."
}

main "$@"
