#!/usr/bin/env bash
# make dev-destroy — idempotent: fine to run on a cluster that's already gone.
set -euo pipefail

CLUSTER_NAME="aegis-dev"

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  kind delete cluster --name "$CLUSTER_NAME"
  echo "✅ kind cluster '$CLUSTER_NAME' deleted."
else
  echo "kind cluster '$CLUSTER_NAME' does not exist, nothing to do."
fi
