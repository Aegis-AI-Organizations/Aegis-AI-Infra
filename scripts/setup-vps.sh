#!/bin/bash
set -e

echo "🔧 Installing ArgoCD..."
kubectl create namespace argocd || true
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "⏳ Waiting for ArgoCD server..."
kubectl wait --for=condition=available --timeout=60s deployment/argocd-server -n argocd

echo "🚀 Branching the GitOps (Root App)..."
kubectl apply -f ../kubernetes/bootstrap/root-app.yaml

echo "✅ Automatic deployment is enabled."
