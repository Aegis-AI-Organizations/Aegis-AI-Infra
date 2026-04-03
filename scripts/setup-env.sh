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

    required_env_vars=(
        POSTGRES_DB
        POSTGRES_USER
        POSTGRES_PASSWORD
        AEGIS_SEED_USER_EMAIL
        AEGIS_SEED_USER_PASSWORD
        TEMPORAL_NAMESPACE
        JWT_SECRET
        ALLOWED_ORIGINS
    )

    missing_vars=()
    for var_name in "${required_env_vars[@]}"; do
        if [[ -z "${!var_name}" ]]; then
            missing_vars+=("$var_name")
        fi
    done

    if [ ${#missing_vars[@]} -gt 0 ]; then
        echo "❌ Missing required variables in .env: ${missing_vars[*]}"
        exit 1
    fi
fi

ENV=$1
if [[ -z "$ENV" ]]; then
  echo "Usage: ./setup-env.sh <environment>"
  echo "Example: ./setup-env.sh pre-alpha"
  exit 1
fi

echo "🎡 Initializing Aegis infrastructure for environment [$ENV]..."

# Pre-check: avoid infinite wait when namespaces are stuck in Terminating.
NAMESPACES_TO_CHECK=(ingress-nginx argocd aegis-system keda)

cleanup_stale_keda_apiservices() {
    kubectl delete apiservice v1beta1.external.metrics.k8s.io --ignore-not-found >/dev/null 2>&1 || true
    kubectl delete apiservice v1alpha1.keda.sh --ignore-not-found >/dev/null 2>&1 || true
    kubectl delete apiservice v1alpha1.eventing.keda.sh --ignore-not-found >/dev/null 2>&1 || true
}

is_any_namespace_terminating() {
    for ns in "${NAMESPACES_TO_CHECK[@]}"; do
        phase=$(kubectl get namespace "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [[ "$phase" == "Terminating" ]]; then
            return 0
        fi
    done
    return 1
}

wait_timeout=120
elapsed=0
while is_any_namespace_terminating; do
    echo "⚠️  Namespaces are currently in 'Terminating' state, waiting for cleanup..."
    if [ $elapsed -ge 15 ]; then
        # Common local-cluster issue: stale KEDA APIService blocks namespace discovery/finalization.
        cleanup_stale_keda_apiservices
    fi
    if [ $elapsed -ge $wait_timeout ]; then
        echo "⚠️  Timeout reached. Attempting to clear namespace finalizers..."
        for ns in "${NAMESPACES_TO_CHECK[@]}"; do
            phase=$(kubectl get namespace "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)
            if [[ "$phase" == "Terminating" ]]; then
                kubectl patch namespace "$ns" --type=merge -p '{"spec":{"finalizers":[]}}' >/dev/null 2>&1 || true
            fi
        done
        sleep 5
        if is_any_namespace_terminating; then
            echo "❌ Some namespaces are still stuck in 'Terminating'."
            echo "   Run './scripts/teardown-env.sh $ENV' again and retry setup."
            exit 1
        fi
        break
    fi
    sleep 3
    elapsed=$((elapsed + 3))
done

kubectl create namespace ingress-nginx || true
kubectl create namespace argocd || true
kubectl create namespace aegis-system || true

# Inject the local .env securely into the Kubernetes cluster
if [ -f "$ENV_FILE" ]; then
  echo "🔒 Pushing local .env into Kubernetes Secret 'aegis-env'..."
  # Use dry-run to apply or overwrite the secret idempotently
  cat "$ENV_FILE" > /tmp/aegis-env-tmp.txt
  echo "" >> /tmp/aegis-env-tmp.txt
  echo "password=${POSTGRES_PASSWORD}" >> /tmp/aegis-env-tmp.txt
  kubectl create secret generic aegis-env \
    --from-env-file="/tmp/aegis-env-tmp.txt" \
    --namespace aegis-system \
    --dry-run=client -o yaml | kubectl apply -f -
  rm -f /tmp/aegis-env-tmp.txt
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
# Auto-initialize Temporal Namespace (synchronous to ensure services don't crash)
echo "🕒 Initializing Temporal namespace..."
# Wait up to 5 minutes for Temporal AdminTools to be created by ArgoCD
timeout=300
elapsed=0
until kubectl get deployment/aegis-temporal-$ENV-admintools -n aegis-system >/dev/null 2>&1 || [ $elapsed -ge $timeout ]; do
    echo "⏳ Waiting for Temporal AdminTools deployment to be created..."
    sleep 5
    elapsed=$((elapsed + 5))
done

if [ $elapsed -ge $timeout ]; then
    echo "❌ Timeout waiting for Temporal AdminTools to be created."
    exit 1
fi

kubectl rollout status deployment/aegis-temporal-$ENV-admintools -n aegis-system --timeout=300s
sleep 5 # Extra buffer for internal services

# Wait for Temporal Cluster to be SERVING
echo "⏳ Waiting for Temporal Cluster to be healthy..."
timeout=300
elapsed=0
while ! kubectl exec -n aegis-system deployment/aegis-temporal-$ENV-admintools -- temporal operator cluster health --address aegis-temporal-$ENV-frontend:7233 2>/dev/null | grep -q "SERVING"; do
    if [ $elapsed -ge $timeout ]; then
        echo "❌ Timeout waiting for Temporal Cluster to become healthy."
        exit 1
    fi
    sleep 5
    elapsed=$((elapsed + 5))
done

# Check if namespace already exists, otherwise create it
echo "⚙️ Ensuring '${TEMPORAL_NAMESPACE}' Temporal namespace exists..."
timeout=120
elapsed=0
while ! kubectl exec -n aegis-system deployment/aegis-temporal-$ENV-admintools -- temporal operator namespace describe --address aegis-temporal-$ENV-frontend:7233 -n ${TEMPORAL_NAMESPACE} >/dev/null 2>&1; do
    if [ $elapsed -ge $timeout ]; then
        echo "❌ Timeout creating Temporal namespace."
        exit 1
    fi
    echo "⚙️ Creating '${TEMPORAL_NAMESPACE}' Temporal namespace..."
    kubectl exec -n aegis-system deployment/aegis-temporal-$ENV-admintools -- temporal operator namespace create --address aegis-temporal-$ENV-frontend:7233 -n ${TEMPORAL_NAMESPACE} --retention 24h --description "Default namespace for Aegis" >/dev/null 2>&1 || true
    sleep 5
    elapsed=$((elapsed + 5))
done

echo "⏳ Waiting for Aegis services to be ready..."
kubectl rollout status deployment/api-gateway-$ENV -n aegis-system --timeout=300s
kubectl rollout status deployment/brain-$ENV -n aegis-system --timeout=300s

echo "🚀 Everything is ready! ArgoCD is now managing your '$ENV' environment."
echo "You can view ArgoCD by port-forwarding: kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo ""
echo "💡 Tip: run 'source .env' to load DB and service variables in your terminal."
