#!/usr/bin/env bash
# make dev-logs SERVICE=api-gateway-dev
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/kube-context-guard.sh
source "$ROOT_DIR/scripts/lib/kube-context-guard.sh"

SERVICE="${SERVICE:-api-gateway-dev}"
require_dev_context

echo "Streaming logs for deployment/$SERVICE (Ctrl+C to stop)..."
kubectl logs -n aegis-dev "deploy/$SERVICE" -f --tail=200
