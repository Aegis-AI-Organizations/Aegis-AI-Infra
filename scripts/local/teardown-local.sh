#!/bin/bash
set -e

echo "🗑️ Deleting ArgoCD application..."
kubectl delete -f ../kubernetes/bootstrap/root-app.yaml || true

echo "🧹 Deleting Temporal helm release..."
helm uninstall temporal -n aegis-system || true

echo "🧹 Cleaning up Aegis namespaces (this will stop all your deployed pods)..."
kubectl delete namespace aegis-system || true
kubectl delete namespace aegis-war-room || true

echo "✅ All Aegis pods and resources have been successfully stopped and removed."
