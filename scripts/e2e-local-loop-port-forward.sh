#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-aegis-system}"
SERVICE="${SERVICE:-api-gateway-mvp}"
LOCAL_PORT="${LOCAL_PORT:-18080}"
REMOTE_PORT="${REMOTE_PORT:-8080}"

log_file="$(mktemp)"
pf_pid=""

cleanup() {
  if [[ -n "$pf_pid" ]]; then
    kill "$pf_pid" >/dev/null 2>&1 || true
  fi
  rm -f "$log_file"
}
trap cleanup EXIT

kubectl -n "$NAMESPACE" port-forward "svc/$SERVICE" "$LOCAL_PORT:$REMOTE_PORT" >"$log_file" 2>&1 &
pf_pid=$!

for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$LOCAL_PORT/health" >/dev/null 2>&1 || curl -fsS "http://127.0.0.1:$LOCAL_PORT/api/health" >/dev/null 2>&1; then
    API_BASE_URL="http://127.0.0.1:$LOCAL_PORT" bash "$ROOT_DIR/scripts/e2e-local-loop.sh"
    exit 0
  fi

  if ! kill -0 "$pf_pid" >/dev/null 2>&1; then
    echo "port-forward exited before the API became reachable:" >&2
    cat "$log_file" >&2
    exit 1
  fi

  sleep 1
done

echo "Timed out waiting for port-forwarded API on 127.0.0.1:$LOCAL_PORT" >&2
cat "$log_file" >&2
exit 1
