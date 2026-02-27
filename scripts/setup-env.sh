#!/bin/bash
set -e

ENV=$1
if [[ -z "$ENV" ]]; then
  echo "Usage: ./setup-env.sh <environment>"
  echo "Example: ./setup-env.sh pre-alpha"
  exit 1
fi

echo "🎡 Initializing Aegis infrastructure for environment [$ENV]..."

kubectl create namespace argocd || true
kubectl create namespace aegis-system || true

echo "📥 Installing Ingress Nginx..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml

echo "📥 Installing ArgoCD..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side || true

echo "⏳ Waiting for ArgoCD Server to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

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

echo "🚀 Everything is ready! ArgoCD is now managing your '$ENV' environment."
echo "You can view ArgoCD by port-forwarding: kubectl port-forward svc/argocd-server -n argocd 8080:443"
