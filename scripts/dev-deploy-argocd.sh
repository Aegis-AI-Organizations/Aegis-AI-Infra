#!/usr/bin/env bash
# make dev-deploy-argocd — optional: installs ArgoCD (if missing, same as
# make dev-deploy) and applies root-app-dev.yaml so ArgoCD pulls the
# manifests from the git remote/HEAD instead of from kubectl apply -k's
# local render. Use this specifically to test the GitOps path end to end
# (requires your branch to be pushed); `make dev-deploy` is the faster
# default and works on uncommitted local changes.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/kube-context-guard.sh
source "$ROOT_DIR/scripts/lib/kube-context-guard.sh"

require_dev_context

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side
kubectl rollout status deployment/argocd-server -n argocd --timeout=300s

echo "Applying kubernetes/bootstrap/root-app-dev.yaml..."
kubectl apply -f "$ROOT_DIR/kubernetes/bootstrap/root-app-dev.yaml"

echo ""
echo "✅ ArgoCD installed and root-app-dev applied."
echo "   kubectl port-forward svc/argocd-server -n argocd 8080:443"
