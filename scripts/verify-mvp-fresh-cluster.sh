#!/usr/bin/env bash
set -euo pipefail

ENVIRONMENT="${ENVIRONMENT:-mvp}"
CONFIRM="${CONFIRM:-}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-1200}"
NAMESPACE="${NAMESPACE:-aegis-system}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "$1 is required" >&2
    exit 1
  fi
}

require_confirmation() {
  if [[ "$CONFIRM" != "fresh-mvp-cluster" ]]; then
    cat >&2 <<'EOF'
Refusing to rebuild the MVP cluster without explicit confirmation.

This command is destructive for the local MVP environment. It runs:
- scripts/teardown-env.sh mvp
- scripts/setup-env.sh mvp
- make verify-mvp-pipeline

Run with:
  CONFIRM=fresh-mvp-cluster TIMEOUT_SECONDS=1200 make verify-mvp-fresh-cluster
EOF
    exit 1
  fi
}

assert_namespace_not_terminating() {
  local phase
  phase="$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "$phase" == "Terminating" ]]; then
    cat >&2 <<EOF
Namespace $NAMESPACE is stuck in Terminating after teardown.

Inspect it before continuing:
  kubectl get namespace $NAMESPACE -o yaml

If this is a local-only MVP rebuild and you accept finalizing the namespace, run explicitly:
  kubectl get namespace $NAMESPACE -o json | jq '.spec.finalizers=[]' | kubectl replace --raw /api/v1/namespaces/$NAMESPACE/finalize -f -
EOF
    exit 1
  fi
}

main() {
  require_command kubectl
  require_command make
  require_confirmation

  echo "Tearing down $ENVIRONMENT environment..."
  ./scripts/teardown-env.sh "$ENVIRONMENT"
  assert_namespace_not_terminating

  echo "Setting up $ENVIRONMENT environment..."
  ./scripts/setup-env.sh "$ENVIRONMENT"

  TIMEOUT_SECONDS="$TIMEOUT_SECONDS" make verify-mvp-pipeline
  echo "Fresh MVP cluster verification completed."
}

main "$@"
