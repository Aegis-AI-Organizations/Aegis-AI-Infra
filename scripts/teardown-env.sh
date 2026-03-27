#!/bin/bash
set -e

# Load .env if present
ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"
if [ -f "$ENV_FILE" ]; then
  set -o allexport; source "$ENV_FILE"; set +o allexport
fi

ENV=$1
if [[ -z "$ENV" ]]; then
  echo "Usage: ./teardown-env.sh <environment>"
  echo "Example: ./teardown-env.sh pre-alpha"
  exit 1
fi

echo "🗑️ Deleting ArgoCD Root Application [$ENV]..."
if [ -f "kubernetes/bootstrap/root-app-$ENV.yaml" ]; then
    kubectl delete -f "kubernetes/bootstrap/root-app-$ENV.yaml" || true
else
    kubectl delete -f "../kubernetes/bootstrap/root-app-$ENV.yaml" || true
fi

echo "🗑️ Deleting KEDA ArgoCD Application [$ENV] if present..."
kubectl -n argocd delete application "aegis-keda-$ENV" --ignore-not-found || true

echo "🧹 Removing ArgoCD Application finalizers (if any remain)..."
kubectl -n argocd get applications -o name 2>/dev/null | while read -r app; do
  kubectl -n argocd patch "$app" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
done

echo "🧹 Removing stale KEDA APIService registrations (if present)..."
kubectl delete apiservice v1beta1.external.metrics.k8s.io --ignore-not-found || true
kubectl delete apiservice v1alpha1.keda.sh --ignore-not-found || true
kubectl delete apiservice v1alpha1.eventing.keda.sh --ignore-not-found || true

echo "🧹 Cleaning up Aegis namespaces, KEDA, ArgoCD, and Ingress..."
kubectl delete namespace aegis-system --ignore-not-found || true
kubectl delete namespace keda --ignore-not-found || true
kubectl delete namespace argocd --ignore-not-found || true
kubectl delete namespace ingress-nginx --ignore-not-found || true

echo "⏳ Waiting for namespaces to be fully removed (this may take a minute)..."
while kubectl get namespace aegis-system keda argocd ingress-nginx >/dev/null 2>&1; do
  sleep 2
done

echo "✅ All Aegis pods and resources have been successfully stopped and removed."
