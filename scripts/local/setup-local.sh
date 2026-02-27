#!/bin/bash
set -e

echo "🎡 Initializing Aegis infrastructure..."

kubectl create namespace argocd || true
kubectl create namespace aegis-system || true
kubectl create namespace aegis-war-room || true
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side

echo "⏳ Waiting for ArgoCD..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

kubectl apply -f ../kubernetes/bootstrap/root-app.yaml

echo "🚀 Everything is ready! ArgoCD is now deploying your prototype."

echo "Installing Temporal..."
helm repo add temporal https://charts.temporal.io
helm repo update

helm install temporal temporal/temporal \
  --namespace aegis-system \
  --set server.replicaCount=1 \
  --set cassandra.enabled=false \
  --set postgresql.enabled=true

echo "Temporal is now installed!"
