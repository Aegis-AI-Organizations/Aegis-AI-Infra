#!/usr/bin/env bash
# make render-dev / make render-prod — pure `kubectl kustomize`, no cluster
# access, no side effects. Used by both the Makefile and validate-envs.sh.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ENV="${1:?Usage: render-env.sh <dev/dev-core|dev/dev-full|prod|mvp>}"
ENV_DIR="$ROOT_DIR/kubernetes/envs/$ENV"

if [[ ! -d "$ENV_DIR" ]]; then
  echo "ERROR: no such environment path: kubernetes/envs/$ENV" >&2
  exit 1
fi

kubectl kustomize "$ENV_DIR"
