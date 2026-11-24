#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == *"get application"* ]]; then
  if [[ "$*" == *".status.sync.status"* ]]; then
    printf 'Synced'
    exit 0
  fi
  if [[ "$*" == *".status.health.status"* ]]; then
    app=""
    for arg in "$@"; do
      [[ "$arg" == aegis-*-mvp ]] && app="$arg"
    done
    if [[ "$app" == "aegis-api-gateway-mvp" ]]; then
      count="$(cat "$FAKE_HEALTH_COUNT" 2>/dev/null || echo 0)"
      count=$((count + 1))
      printf '%s' "$count" > "$FAKE_HEALTH_COUNT"
      [[ "$count" -eq 1 ]] && printf 'Progressing' || printf 'Healthy'
    else
      printf 'Healthy'
    fi
    exit 0
  fi
fi

if [[ "$*" == *"get pods"* ]]; then
  printf 'NAME READY STATUS\n'
  exit 0
fi

if [[ "$*" == *"logs"* ]]; then
  printf '%s\n' \
    'CrewAI pentest analysis status=COMPLETED' \
    'Stored PDF report' \
    'Sandbox cleanup completed'
  exit 0
fi

printf 'Unexpected kubectl call: %s\n' "$*" >&2
exit 1
EOF

cat > "$TMP_DIR/make" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$TMP_DIR/kubectl" "$TMP_DIR/make"

export FAKE_HEALTH_COUNT="$TMP_DIR/health-count"
output="$(
  PATH="$TMP_DIR:$PATH" \
  TIMEOUT_SECONDS=5 \
  ARGOCD_POLL_INTERVAL_SECONDS=0 \
  bash "$ROOT_DIR/scripts/verify-demo-readiness.sh" 2>&1
)"

grep -qF 'Waiting for ArgoCD application aegis-api-gateway-mvp: Synced/Progressing' <<<"$output"
grep -qF 'ArgoCD critical applications are Synced/Healthy.' <<<"$output"
grep -qF 'Demo readiness verified.' <<<"$output"

echo "verify-demo-readiness ArgoCD wait test passed."
