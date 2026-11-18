#!/usr/bin/env bash
# Shared context guard for dev/prod scripts (sourced, not executed).
#
# Rules this file enforces:
#  - dev scripts refuse to run against anything that isn't the kind-aegis-dev
#    context.
#  - prod scripts refuse to run unless PROD_KUBE_CONTEXT is explicitly set by
#    the operator AND matches the current kubectl context exactly. Nothing in
#    here guesses what "production" is.
set -euo pipefail

DEV_KUBE_CONTEXT="${DEV_KUBE_CONTEXT:-kind-aegis-dev}"

current_kube_context() {
  kubectl config current-context 2>/dev/null || echo ""
}

require_dev_context() {
  local ctx
  ctx="$(current_kube_context)"
  if [[ "$ctx" != "$DEV_KUBE_CONTEXT" ]]; then
    echo "ERROR: current kubectl context is \"${ctx:-<none>}\", expected \"$DEV_KUBE_CONTEXT\"." >&2
    echo "       Run 'make dev-create' first, or 'kubectl config use-context $DEV_KUBE_CONTEXT'." >&2
    echo "       Refusing to run a dev command against a non-dev context." >&2
    exit 2
  fi
  echo "kubectl context : $ctx"
  echo "target namespace: ${AEGIS_DEV_NAMESPACE:-aegis-dev}"
}

# Never guesses production. The operator must export PROD_KUBE_CONTEXT
# themselves, and it must match the current context exactly.
require_prod_context() {
  local ctx
  ctx="$(current_kube_context)"
  if [[ -z "${PROD_KUBE_CONTEXT:-}" ]]; then
    echo "ERROR: PROD_KUBE_CONTEXT is not set." >&2
    echo "       This command touches the production cluster and requires an explicit," >&2
    echo "       operator-provided PROD_KUBE_CONTEXT. It is never inferred automatically." >&2
    exit 2
  fi
  if [[ "$ctx" != "$PROD_KUBE_CONTEXT" ]]; then
    echo "ERROR: current kubectl context is \"${ctx:-<none>}\", but PROD_KUBE_CONTEXT=\"$PROD_KUBE_CONTEXT\"." >&2
    echo "       Refusing to run — contexts must match exactly." >&2
    exit 2
  fi
  echo "kubectl context : $ctx (matches PROD_KUBE_CONTEXT)"
  echo "target namespace: aegis-system"
  echo "WARNING: this command targets PRODUCTION on leCube5080." >&2
}
