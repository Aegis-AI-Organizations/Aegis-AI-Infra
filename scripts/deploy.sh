#!/bin/bash
# Usage: ./deploy.sh [local|vps|cloud]

ENV=$1
if [[ -z "$ENV" ]]; then
  echo "Usage: ./deploy.sh [local|vps|cloud]"
  exit 1
fi

echo "🚀 Deploying Aegis stack in environment: $ENV"

if [ ! -f "kubernetes/bootstrap/root-app-$ENV.yaml" ]; then
    echo "❌ Missing root-app-$ENV.yaml"
    exit 1
fi

kubectl apply -f kubernetes/bootstrap/root-app-$ENV.yaml

echo "📡 ArgoCD is now synchronizing the services from the envs/$ENV folder."
