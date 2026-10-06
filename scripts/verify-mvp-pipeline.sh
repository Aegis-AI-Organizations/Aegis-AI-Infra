#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-aegis-system}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
LOG_SINCE="${MVP_PIPELINE_LOG_SINCE:-30m}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-1200}"
ARGOCD_HEALTH_TIMEOUT="${ARGOCD_HEALTH_TIMEOUT:-180}"
EXPECTED_FLAG="${EXPECTED_FLAG:-aegis-flag-1234}"

critical_apps=(
  aegis-api-gateway-mvp
  aegis-brain-mvp
  aegis-crewai-worker-mvp
  aegis-pentest-worker-mvp
  aegis-db-init-mvp
)

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "$1 is required" >&2
    exit 1
  fi
}

assert_argocd_healthy() {
  local app sync health deadline
  deadline=$((SECONDS + ARGOCD_HEALTH_TIMEOUT))

  while true; do
    for app in "${critical_apps[@]}"; do
      sync="$(kubectl -n "$ARGOCD_NAMESPACE" get application "$app" -o jsonpath='{.status.sync.status}')"
      health="$(kubectl -n "$ARGOCD_NAMESPACE" get application "$app" -o jsonpath='{.status.health.status}')"
      if [[ "$sync" != "Synced" || "$health" != "Healthy" ]]; then
        break
      fi
    done

    if [[ "$sync" == "Synced" && "$health" == "Healthy" ]]; then
      echo "ArgoCD critical applications are Synced/Healthy."
      return
    fi

    if (( SECONDS >= deadline )); then
      echo "ArgoCD application $app is $sync/$health, expected Synced/Healthy" >&2
      exit 1
    fi

    sleep 5
  done
}

assert_no_image_pull_errors() {
  local bad_pods
  bad_pods="$(kubectl -n "$NAMESPACE" get pods -o wide | grep -E 'ImagePullBackOff|ErrImagePull' || true)"
  if [[ -n "$bad_pods" ]]; then
    echo "Found image pull failures:" >&2
    printf '%s\n' "$bad_pods" >&2
    exit 1
  fi
  echo "No ImagePullBackOff|ErrImagePull pods found."
}

run_e2e() {
  echo "Running MVP e2e through e2e-local-loop-port-forward..."
  TIMEOUT_SECONDS="$TIMEOUT_SECONDS" EXPECTED_FLAG="$EXPECTED_FLAG" make e2e-local-loop-port-forward
}

collect_logs() {
  local selector="$1"
  kubectl -n "$NAMESPACE" logs -l "$selector" --since="$LOG_SINCE" --all-containers --tail=-1 2>/dev/null || true
}

assert_log_contains() {
  local name="$1"
  local selector="$2"
  local pattern="$3"
  local logs
  logs="$(collect_logs "$selector")"
  if ! grep -qF "$pattern" <<<"$logs"; then
    echo "Missing '$pattern' in recent $name logs selected by $selector" >&2
    exit 1
  fi
  echo "Found '$pattern' in $name logs."
}

assert_cleanup_evidence() {
  local logs
  logs="$(collect_logs 'app.kubernetes.io/name=deployer-worker')$(collect_logs 'app=deployer-worker-mvp')"
  if grep -qiE 'cleanup|delete.*sandbox|sandbox.*delete|Sandbox cleanup' <<<"$logs"; then
    echo "Found sandbox cleanup evidence in deployer logs."
  else
    echo "Missing sandbox cleanup evidence in recent deployer logs." >&2
    exit 1
  fi
}

assert_temporal_not_stuck() {
  local workflows
  workflows="$(make temporal-list-graph-pentest-workflows)"
  if grep -Eq 'Running|WORKFLOW_EXECUTION_STATUS_RUNNING' <<<"$workflows"; then
    echo "Found graph pentest workflow still Running after MVP e2e:" >&2
    printf '%s\n' "$workflows" >&2
    exit 1
  fi
  echo "No graph pentest workflow remains Running."
}

main() {
  require_command kubectl
  require_command make

  assert_argocd_healthy
  assert_no_image_pull_errors
  run_e2e
  assert_log_contains "Brain" 'app=brain-mvp' 'CrewAI pentest analysis status=COMPLETED'
  assert_log_contains "Brain" 'app=brain-mvp' 'Stored PDF report'
  assert_cleanup_evidence
  assert_temporal_not_stuck
  echo "MVP pipeline reliability verified with $EXPECTED_FLAG."
}

main "$@"
