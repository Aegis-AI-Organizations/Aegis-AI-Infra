#!/usr/bin/env bash
# make dev-build — builds service images from sibling repos and loads them
# into the kind cluster. Always tags "dev-local", never "latest".
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOSITORY_DIR="${REPOSITORY_DIR:-$(cd "$ROOT_DIR/.." && pwd)}"
CLUSTER_NAME="aegis-dev"
TAG="dev-local"

build_and_load() {
  local repo_dir="$1" image_name="$2"
  local image="${image_name}:${TAG}"

  if [[ ! -d "$REPOSITORY_DIR/$repo_dir" ]]; then
    echo "Skipping $image: missing repository $REPOSITORY_DIR/$repo_dir" >&2
    return 0
  fi

  echo "Building $image from $repo_dir"
  docker build -t "$image" "$REPOSITORY_DIR/$repo_dir"
  echo "Loading $image into kind cluster '$CLUSTER_NAME'"
  kind load docker-image "$image" --name "$CLUSTER_NAME"
}

build_and_load "Aegis-AI-Api-Gateway" "ghcr.io/aegis-ai-organizations/aegis-ai-api-gateway"
build_and_load "Aegis-AI-Brain" "ghcr.io/aegis-ai-organizations/aegis-ai-brain"
build_and_load "Aegis-AI-Dashboard" "ghcr.io/aegis-ai-organizations/aegis-ai-dashboard"

if [[ "${PROFILE:-dev-core}" == "dev-full" ]]; then
  build_and_load "Aegis-AI-Landing" "ghcr.io/aegis-ai-organizations/aegis-ai-landing"
  build_and_load "Aegis-AI-Agent-Crew" "ghcr.io/aegis-ai-organizations/aegis-ai-agent-crew"
  build_and_load "Aegis-AI-Worker-Pentest" "ghcr.io/aegis-ai-organizations/aegis-ai-worker-pentest"
  build_and_load "Aegis-AI-Worker-Ingest" "ghcr.io/aegis-ai-organizations/aegis-ai-worker-ingest"
  build_and_load "Aegis-AI-Worker-Deployer" "ghcr.io/aegis-ai-organizations/aegis-ai-worker-deployer"
fi

echo "✅ Dev images built and loaded (tag: $TAG)."
