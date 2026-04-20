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
kubectl create namespace keda || true

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

# Generate mTLS Certificates for Temporal and Brain
if [ -f "scripts/generate-temporal-certs.sh" ]; then
    ./scripts/generate-temporal-certs.sh "$ENV"
    ./scripts/generate-brain-certs.sh "$ENV"
elif [ -f "generate-temporal-certs.sh" ]; then
    ./generate-temporal-certs.sh "$ENV"
    ./generate-brain-certs.sh "$ENV"
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

echo "🔄 Resuming ArgoCD management and scaling up core services..."
# Wait for ArgoCD to discover the sub-applications after the root app is deployed
echo "⏳ Waiting for ArgoCD to discover core applications (Postgres, Temporal)..."
timeout=120
elapsed=0
until (kubectl get application aegis-postgres-$ENV -n argocd >/dev/null 2>&1 && kubectl get application aegis-temporal-$ENV -n argocd >/dev/null 2>&1) || [ $elapsed -ge $timeout ]; do
    sleep 5
    elapsed=$((elapsed + 5))
done

# Resume auto-sync for all apps in this environment (in case it was stopped by stop-env.sh)
for app in $(kubectl get applications -n argocd -o name | grep "$ENV"); do
  kubectl patch "$app" -n argocd --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' \
    >/dev/null 2>&1 && echo "   ✓ Resumed $app sync" || true
done

# Force sync core components to overcome initial discovery lag
echo "🔄 Forcing immediate sync of core infrastructure..."
kubectl patch application aegis-postgres-$ENV -n argocd --type=merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"normal"}}}' >/dev/null 2>&1 || true
kubectl patch application aegis-temporal-$ENV -n argocd --type=merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"normal"}}}' >/dev/null 2>&1 || true

# Explicit scale up of core DB if it was at 0
PG_STATEFULSET="aegis-postgres-$ENV-postgresql"
PG_HOST="aegis-postgres-$ENV-postgresql.aegis-system.svc.cluster.local"
if kubectl get statefulset "$PG_STATEFULSET" -n aegis-system >/dev/null 2>&1; then
    replicas=$(kubectl get statefulset "$PG_STATEFULSET" -n aegis-system -o jsonpath='{.spec.replicas}')
    if [[ "$replicas" -eq 0 ]]; then
        echo "📈 Scaling up PostgreSQL from 0..."
        kubectl scale statefulset "$PG_STATEFULSET" --replicas=1 -n aegis-system
    fi
fi

# Wait for PG to be ready
echo "🐘 Waiting for PostgreSQL to be healthy..."
PG_POD_LBL="app.kubernetes.io/name=postgresql,app.kubernetes.io/instance=aegis-postgres-$ENV"
# 1. Wait for pod existence first to avoid "no matching resources found" crashing kubectl wait
timeout=300
elapsed=0
until kubectl get pods -l "$PG_POD_LBL" -n aegis-system -o name 2>/dev/null | grep -q "pod/" || [ $elapsed -ge $timeout ]; do
    echo "⏳ Waiting for PostgreSQL pods to be created..."
    sleep 5
    elapsed=$((elapsed + 5))
done

if [ $elapsed -ge $timeout ]; then
    echo "❌ Timeout waiting for PostgreSQL pods to be created."
    exit 1
fi

# 2. Now wait for readiness
kubectl wait --for=condition=ready pod -l "$PG_POD_LBL" -n aegis-system --timeout=300s

# Check if databases exist (local clusters can lose data on restart)
echo "🔍 Checking database integrity..."
HAS_CLIENT_DB=$(kubectl exec -n aegis-system statefulset/$PG_STATEFULSET -- sh -c "PGPASSWORD=$POSTGRES_PASSWORD psql -U aegis_admin -lqt" | cut -d \| -f 1 | grep -qw "aegis_db" && echo "yes" || echo "no")
HAS_TEMPORAL_DB=$(kubectl exec -n aegis-system statefulset/$PG_STATEFULSET -- sh -c "PGPASSWORD=$POSTGRES_PASSWORD psql -U aegis_admin -lqt" | cut -d \| -f 1 | grep -qw "aegis_persistence" && echo "yes" || echo "no")

if [ "$HAS_CLIENT_DB" = "no" ]; then
    echo "⚠️  Application database missing. Forcing database initialization..."
    kubectl delete job aegis-db-init-$ENV -n aegis-system --ignore-not-found
fi

if [ "$HAS_TEMPORAL_DB" = "no" ]; then
    echo "⚠️  Temporal database missing. Forcing schema initialization..."
    kubectl delete job -n aegis-system -l "app.kubernetes.io/instance=aegis-temporal-$ENV,app.kubernetes.io/component=database" --ignore-not-found
fi

# Kick ArgoCD root app and wait for Jobs to complete
kubectl patch application aegis-prototype-$ENV -n argocd --type=merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"normal"}}}' >/dev/null 2>&1 || true

echo "🕒 Initializing Temporal databases and schema manually..."
# 1. Wait for AdminTools (which natively waits for Postgres)
timeout=300
elapsed=0
until kubectl get deployment aegis-temporal-$ENV-admintools -n aegis-system >/dev/null 2>&1 || [ $elapsed -ge $timeout ]; do
    echo "   ...waiting for admintools deployment to be created by ArgoCD..."
    sleep 5
    elapsed=$((elapsed + 5))
done
kubectl rollout status deployment/aegis-temporal-$ENV-admintools -n aegis-system --timeout=300s

# 2. Run schema initialization from the stable admintools container
ADM_POD=$(kubectl get pod -l app.kubernetes.io/instance=aegis-temporal-$ENV,app.kubernetes.io/component=admintools -n aegis-system -o name | head -n 1)

echo "   -> Creating databases..."
# Ignore errors if they already exist (idempotent)
kubectl exec -n aegis-system "$ADM_POD" -- temporal-sql-tool --plugin postgres12 --port 5432 --endpoint aegis-postgres-mvp-postgresql.aegis-system.svc.cluster.local create-database -db aegis_persistence || true
kubectl exec -n aegis-system "$ADM_POD" -- temporal-sql-tool --plugin postgres12 --port 5432 --endpoint aegis-postgres-mvp-postgresql.aegis-system.svc.cluster.local create-database -db aegis_visibility || true

echo "   -> Setting up schema..."
kubectl exec -n aegis-system "$ADM_POD" -- temporal-sql-tool --plugin postgres12 --port 5432 --endpoint aegis-postgres-mvp-postgresql.aegis-system.svc.cluster.local --db aegis_persistence setup-schema -v 0.0 || true
kubectl exec -n aegis-system "$ADM_POD" -- temporal-sql-tool --plugin postgres12 --port 5432 --endpoint aegis-postgres-mvp-postgresql.aegis-system.svc.cluster.local --db aegis_visibility setup-schema -v 0.0 || true

echo "   -> Updating schema to latest..."
kubectl exec -n aegis-system "$ADM_POD" -- temporal-sql-tool --plugin postgres12 --port 5432 --endpoint aegis-postgres-mvp-postgresql.aegis-system.svc.cluster.local --db aegis_persistence update-schema -d /etc/temporal/schema/postgresql/v12/temporal/versioned || true
kubectl exec -n aegis-system "$ADM_POD" -- temporal-sql-tool --plugin postgres12 --port 5432 --endpoint aegis-postgres-mvp-postgresql.aegis-system.svc.cluster.local --db aegis_visibility update-schema -d /etc/temporal/schema/postgresql/v12/visibility/versioned || true

echo "⏳ Cleaning up and waiting for Aegis AI application job..."
# Force job recreation if it already exists to ensure seeding runs on new postgres instance
kubectl delete job aegis-db-init-$ENV -n aegis-system --ignore-not-found >/dev/null 2>&1 || true
# Non-blocking wait loop with progress feedback
timeout=300
elapsed=0
until kubectl get job/aegis-db-init-$ENV -n aegis-system -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null | grep -q "True" || [ $elapsed -ge $timeout ]; do
    echo "   ...waiting for database seeding to complete ($elapsed/$timeout s)..."
    sleep 10
    elapsed=$((elapsed + 10))
done

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

echo "🚀 Finalizing core Aegis services..."
until kubectl get deployment api-gateway-$ENV -n aegis-system >/dev/null 2>&1; do sleep 2; done
kubectl rollout status deployment/api-gateway-$ENV -n aegis-system --timeout=300s
until kubectl get deployment brain-$ENV -n aegis-system >/dev/null 2>&1; do sleep 2; done
kubectl rollout status deployment/brain-$ENV -n aegis-system --timeout=300s

echo "🚀 Everything is ready! ArgoCD is now managing your '$ENV' environment."
echo "You can view ArgoCD by port-forwarding: kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo ""
echo "💡 Tip: run 'source .env' to load DB and service variables in your terminal."
