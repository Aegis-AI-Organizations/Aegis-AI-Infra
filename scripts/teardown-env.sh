#!/bin/bash
set -e

ENV=$1
if [[ -z "$ENV" ]]; then
  echo "Usage: ./teardown-env.sh <environment>"
  echo "Example: ./teardown-env.sh pre-alpha"
  exit 1
fi

echo "🗑️ Deleting ArgoCD Root Application [$ENV]..."
if [ -f "kubernetes/bootstrap/root-app-$ENV.yaml" ]; then
    kubectl delete -f kubernetes/bootstrap/root-app-$ENV.yaml || true
else
    kubectl delete -f ../kubernetes/bootstrap/root-app-$ENV.yaml || true
fi

echo "🧹 Cleaning up Aegis namespaces (this will aggressively stop all your deployed pods)..."
kubectl delete namespace aegis-system --ignore-not-found || true

echo "✅ All Aegis pods and resources have been successfully stopped and removed."
