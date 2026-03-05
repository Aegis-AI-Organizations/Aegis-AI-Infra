#!/bin/bash
set -e

# Load .env if present (dev local override)
ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"
if [ -f "$ENV_FILE" ]; then
  echo "📦 Loading environment variables from .env..."
  set -o allexport
  # shellcheck source=../.env
  source "$ENV_FILE"
  set +o allexport
fi

ENV=$1
if [[ -z "$ENV" ]]; then
  echo "Usage: ./setup-env.sh <environment>"
  echo "Example: ./setup-env.sh pre-alpha"
  exit 1
fi

echo "🎡 Initializing Aegis infrastructure for environment [$ENV]..."

# Pre-check: Wait for namespaces to be fully deleted ONLY if they are in 'Terminating' state
while kubectl get namespace ingress-nginx argocd aegis-system 2>&1 | grep -q "Terminating"; do
    echo "⚠️  Namespaces are currently in 'Terminating' state, waiting for cleanup..."
    sleep 3
done

kubectl create namespace ingress-nginx || true
kubectl create namespace argocd || true
kubectl create namespace aegis-system || true

# Inject the local .env securely into the Kubernetes cluster
if [ -f "$ENV_FILE" ]; then
  echo "🔒 Pushing local .env into Kubernetes Secret 'aegis-env'..."
  # Use dry-run to apply or overwrite the secret idempotently
  kubectl create secret generic aegis-env \
    --from-env-file="$ENV_FILE" \
    --namespace aegis-system \
    --dry-run=client -o yaml | kubectl apply -f -
fi

echo "📥 Installing Ingress Nginx..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml

echo "📥 Installing ArgoCD..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side || true

echo "⏳ Waiting for ArgoCD components to be ready..."
kubectl rollout status deployment/argocd-server -n argocd --timeout=300s
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=300s
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s

if [ ! -f "../../kubernetes/bootstrap/root-app-$ENV.yaml" ] && [ ! -f "kubernetes/bootstrap/root-app-$ENV.yaml" ]; then
    echo "❌ Missing root-app-$ENV.yaml"
    exit 1
fi

echo "🔗 Deploying [$ENV] App of Apps..."
# Try from scripts/ folder or root folder
if [ -f "kubernetes/bootstrap/root-app-$ENV.yaml" ]; then
    kubectl apply -f kubernetes/bootstrap/root-app-$ENV.yaml
else
    kubectl apply -f ../kubernetes/bootstrap/root-app-$ENV.yaml
fi

# Authenticate to GHCR if token is set
if [[ -n "$GHCR_TOKEN" && -n "$GHCR_USERNAME" ]]; then
  echo "🔐 Authenticating to GHCR..."
  echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin
fi
# Auto-initialize Temporal Namespace in the background
echo "🕒 Starting Temporal namespace auto-initialization job..."
(
  # Wait up to 5 minutes for Temporal AdminTools to be available and run the setup
  kubectl rollout status deployment/aegis-temporal-$ENV-admintools -n aegis-system --timeout=300s >/dev/null 2>&1 || true
  sleep 5 # Extra buffer for the internal services to fully boot

  # Check if namespace already exists, otherwise create it
  if ! kubectl exec -n aegis-system deployment/aegis-temporal-$ENV-admintools -- temporal operator namespace describe -n default >/dev/null 2>&1; then
    echo "⚙️ Creating 'default' Temporal namespace..."
    kubectl exec -n aegis-system deployment/aegis-temporal-$ENV-admintools -- temporal operator namespace create -n default --retention 24h --description "Default namespace for Aegis" || true
  fi
) &

echo "🚀 Everything is ready! ArgoCD is now managing your '$ENV' environment."
echo "You can view ArgoCD by port-forwarding: kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo ""
echo "💡 Tip: run 'source .env' to load DB and service variables in your terminal."
