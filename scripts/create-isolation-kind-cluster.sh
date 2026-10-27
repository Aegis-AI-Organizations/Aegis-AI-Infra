#!/usr/bin/env bash
# Aegis AI — Local reference cluster for isolation proofs (kind + Cilium)
#
# OrbStack's built-in cluster does not route pod traffic through Cilium
# (see Infra#73), so egress/multitenant NetworkPolicy tests always pass
# vacuously there. This script builds a disposable kind cluster with real
# Cilium as the CNI, so test-isolation-egress.sh and
# test-isolation-multitenant.sh prove something.
#
# This does NOT cover gVisor: kind nodes are containers, and installing a
# real runsc containerd shim inside them needs host-level privileges this
# script doesn't attempt. gVisor needs real Linux nodes (cloud) — out of
# scope here, tracked separately in Infra#73.
#
# Usage:
#   scripts/create-isolation-kind-cluster.sh         # create + wait for Cilium
#   scripts/create-isolation-kind-cluster.sh --delete # tear down
set -euo pipefail

CLUSTER_NAME="aegis-isolation-test"
CILIUM_VERSION="1.15.5"
KIND_CONFIG="$(mktemp)"
trap 'rm -f "$KIND_CONFIG"' EXIT

if [[ "${1:-}" == "--delete" ]]; then
  kind delete cluster --name "$CLUSTER_NAME"
  exit 0
fi

cat > "$KIND_CONFIG" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
networking:
  disableDefaultCNI: true
  podSubnet: "10.244.0.0/16"
nodes:
  - role: control-plane
  - role: worker
EOF

kind create cluster --config "$KIND_CONFIG"

helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
helm repo update cilium

helm install cilium cilium/cilium --version "$CILIUM_VERSION" \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="${CLUSTER_NAME}-control-plane" \
  --set k8sServicePort=6443

echo "Waiting for Cilium to be ready..."
kubectl wait --for=condition=Ready pods -l k8s-app=cilium -n kube-system --timeout=180s

echo ""
echo "Cluster ready. Context: kind-${CLUSTER_NAME}"
echo "Run isolation tests with:"
echo "  AEGIS_ALLOWED_CONTEXT=kind-${CLUSTER_NAME} scripts/test-isolation-egress.sh"
echo "  AEGIS_ALLOWED_CONTEXT=kind-${CLUSTER_NAME} scripts/test-isolation-multitenant.sh"
echo ""
echo "Tear down with: $(basename "$0") --delete"
