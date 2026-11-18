#!/usr/bin/env bash
# make dev-deploy [PROFILE=dev-core|dev-full] — plain kubectl apply -k, no
# ArgoCD required. Idempotent: re-running just re-applies the same manifests.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/kube-context-guard.sh
source "$ROOT_DIR/scripts/lib/kube-context-guard.sh"

PROFILE="${PROFILE:-dev-core}"
ENV_DIR="$ROOT_DIR/kubernetes/envs/dev/$PROFILE"

if [[ ! -d "$ENV_DIR" ]]; then
  echo "ERROR: unknown PROFILE '$PROFILE' (expected dev-core or dev-full)." >&2
  exit 1
fi

require_dev_context

ENV_FILE="${AEGIS_ENV_FILE:-$ROOT_DIR/.env}"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Copy .env.example to .env first (dev-only placeholder values are fine)." >&2
  exit 1
fi

echo "Applying kubernetes/envs/dev/$PROFILE (profile: $PROFILE)..."
kubectl apply -k "$ENV_DIR"

echo "Waiting for namespace aegis-dev..."
kubectl wait --for=jsonpath='{.status.phase}'=Active namespace/aegis-dev --timeout=60s

echo "Pushing $ENV_FILE into Secret 'aegis-env' (namespace aegis-dev)..."
grep -v -E '^(ENV|password)=' "$ENV_FILE" > /tmp/aegis-dev-env-tmp.txt || true
echo "ENV=dev" >> /tmp/aegis-dev-env-tmp.txt
kubectl create secret generic aegis-env \
  --from-env-file="/tmp/aegis-dev-env-tmp.txt" \
  --namespace aegis-dev \
  --dry-run=client -o yaml | kubectl apply -f -
rm -f /tmp/aegis-dev-env-tmp.txt

echo "Waiting for core deployments to roll out..."
kubectl rollout status statefulset/aegis-postgres-dev-postgresql -n aegis-dev --timeout=180s || true
for dep in api-gateway-dev brain-dev dashboard-dev; do
  kubectl rollout status deployment/"$dep" -n aegis-dev --timeout=180s || true
done

echo ""
echo "✅ dev-core deployed. Try:"
echo "   curl http://api.aegis-dev.127.0.0.1.nip.io/health"
echo "   open http://app.aegis-dev.127.0.0.1.nip.io"
