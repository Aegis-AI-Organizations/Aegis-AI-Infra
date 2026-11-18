#!/usr/bin/env bash
# make dev-status
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/kube-context-guard.sh
source "$ROOT_DIR/scripts/lib/kube-context-guard.sh"

require_dev_context

echo ""
echo "--- Pods (aegis-dev) ---"
kubectl get pods -n aegis-dev -o wide
echo ""
echo "--- Services (aegis-dev) ---"
kubectl get svc -n aegis-dev
echo ""
echo "--- Ingress (aegis-dev) ---"
kubectl get ingress -n aegis-dev
echo ""
echo "--- ArgoCD Applications (if installed) ---"
kubectl get applications -n argocd 2>/dev/null | grep -i dev || echo "(none — ArgoCD not installed in this cluster, or no -dev apps synced)"
