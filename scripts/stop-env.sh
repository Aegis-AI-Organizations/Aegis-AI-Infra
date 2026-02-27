#!/bin/bash
# stop-env.sh - Gracefully stops a pre-alpha environment without destroying ArgoCD config.
# Unlike teardown-env.sh, this script scales down all deployments and
# statefulsets to 0 replicas (fast shutdown), without deleting namespaces or
# ArgoCD applications. Run setup-env.sh or scale back up to restart.
#
# Usage: ./scripts/stop-env.sh <environment>
# Example: ./scripts/stop-env.sh pre-alpha

set -euo pipefail

ENV=${1:-}
if [[ -z "$ENV" ]]; then
  echo "Usage: ./scripts/stop-env.sh <environment>"
  echo "Example: ./scripts/stop-env.sh pre-alpha"
  exit 1
fi

NAMESPACE="aegis-system"

echo "🛑 Stopping environment [$ENV] in namespace [$NAMESPACE]..."

# ------------------------------------------------------------------
# 1. Pause ArgoCD auto-sync so it doesn't fight our scale-down
# ------------------------------------------------------------------
echo "⏸️  Pausing ArgoCD auto-sync for all applications in [$ENV]..."
for app in $(kubectl get applications -n argocd -o name 2>/dev/null | grep "$ENV" || true); do
  kubectl patch "$app" -n argocd \
    --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":null}}}' \
    >/dev/null 2>&1 && echo "   ✓ Paused $app" || true
done

# ------------------------------------------------------------------
# 2. Kill any local port-forward processes
# ------------------------------------------------------------------
echo "🔌 Stopping local port-forwards..."
pkill -f "kubectl port-forward" 2>/dev/null || true

# ------------------------------------------------------------------
# 3. Scale down all Deployments to 0
# ------------------------------------------------------------------
echo "📉 Scaling down Deployments..."
kubectl get deployments -n "$NAMESPACE" -o name 2>/dev/null | \
  xargs -r -I{} kubectl scale {} --replicas=0 -n "$NAMESPACE" 2>/dev/null || true

# ------------------------------------------------------------------
# 4. Scale down all StatefulSets to 0
# ------------------------------------------------------------------
echo "📉 Scaling down StatefulSets..."
kubectl get statefulsets -n "$NAMESPACE" -o name 2>/dev/null | \
  xargs -r -I{} kubectl scale {} --replicas=0 -n "$NAMESPACE" 2>/dev/null || true

# ------------------------------------------------------------------
# 5. Wait for pods to terminate
# ------------------------------------------------------------------
echo "⏳ Waiting for pods to terminate..."
kubectl wait --for=delete pod --all -n "$NAMESPACE" --timeout=60s 2>/dev/null || true

echo ""
echo "✅ Environment [$ENV] stopped."
echo "   - ArgoCD config and applications are preserved."
echo "   - Auto-sync is paused (re-enable it via ArgoCD UI or setup-env.sh)."
echo ""
echo "▶️  To restart, run: ./scripts/setup-env.sh $ENV"
