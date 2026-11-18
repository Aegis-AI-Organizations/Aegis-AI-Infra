#!/usr/bin/env bash
# make dev-create — idempotent: safe to re-run if the cluster already exists.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/kube-context-guard.sh
source "$ROOT_DIR/scripts/lib/kube-context-guard.sh"

CLUSTER_NAME="aegis-dev"
KIND_CONFIG="$ROOT_DIR/kubernetes/envs/dev/kind-aegis-dev.yaml"

command -v kind >/dev/null 2>&1 || { echo "ERROR: kind is required (https://kind.sigs.k8s.io/)." >&2; exit 127; }
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl is required." >&2; exit 127; }

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "kind cluster '$CLUSTER_NAME' already exists, reusing it."
else
  echo "Creating kind cluster '$CLUSTER_NAME'..."
  kind create cluster --config "$KIND_CONFIG"
fi

kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null
require_dev_context

echo "Installing ingress-nginx (kind provider manifest)..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s

echo ""
echo "✅ aegis-dev cluster is up. Context: kind-$CLUSTER_NAME"
echo "   Next: make dev-build && make dev-deploy"
