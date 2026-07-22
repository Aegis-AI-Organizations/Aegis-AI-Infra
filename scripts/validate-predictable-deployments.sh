#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K8S_DIR="$ROOT_DIR/kubernetes"
API_VALUES="$K8S_DIR/envs/mvp/api-gateway/values.yaml"
NEO4J_SCHEMA_JOB="$K8S_DIR/envs/mvp/infrastructure/neo4j-schema/manifests/job.yaml"

if grep -RInE 'tag:[[:space:]]*["'"'']?latest["'"'']?[[:space:]]*$|image:[[:space:]]*[^#[:space:]]+:latest[[:space:]]*$' "$K8S_DIR"; then
  echo "latest image tags are forbidden in Kubernetes deployment manifests" >&2
  exit 1
fi

if ! grep -qE '^[[:space:]]*repository:[[:space:]]*"?aegis-api"?[[:space:]]*$' "$API_VALUES"; then
  echo "api-gateway image repository must render as aegis-api:a8931b6" >&2
  exit 1
fi

if ! grep -qE '^[[:space:]]*tag:[[:space:]]*"?a8931b6"?[[:space:]]*$' "$API_VALUES"; then
  echo "api-gateway image tag must render as aegis-api:a8931b6" >&2
  exit 1
fi

if ! grep -q 'argocd.argoproj.io/hook:[[:space:]]*PostSync' "$NEO4J_SCHEMA_JOB"; then
  echo "Neo4j schema Job must be annotated as an ArgoCD PostSync hook" >&2
  exit 1
fi

if ! grep -q 'argocd.argoproj.io/hook-delete-policy:[[:space:]]*HookSucceeded' "$NEO4J_SCHEMA_JOB"; then
  echo "Neo4j schema Job must delete succeeded hook runs" >&2
  exit 1
fi
