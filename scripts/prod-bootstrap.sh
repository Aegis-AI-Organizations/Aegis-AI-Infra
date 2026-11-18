#!/usr/bin/env bash
# Production bootstrap — GitOps only. This script does exactly one thing:
# apply the root Application so ArgoCD takes over from there. It never runs
# `kubectl apply` against application workloads directly, and it is not
# invoked by any `make dev-*` target.
#
# Usage (on leCube5080, by an operator, never from a developer workstation):
#   PROD_KUBE_CONTEXT=<exact-context-name> scripts/prod-bootstrap.sh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/kube-context-guard.sh
source "$ROOT_DIR/scripts/lib/kube-context-guard.sh"

require_prod_context

read -r -p "This applies kubernetes/bootstrap/root-app-prod.yaml to PRODUCTION. Type 'yes' to continue: " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  echo "Aborted."
  exit 1
fi

kubectl apply -f "$ROOT_DIR/kubernetes/bootstrap/root-app-prod.yaml"
echo "Applied. ArgoCD now owns the sync from kubernetes/envs/prod — no further manual steps."
