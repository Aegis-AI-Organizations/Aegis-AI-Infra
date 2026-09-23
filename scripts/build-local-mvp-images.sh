#!/usr/bin/env bash
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOSITORY_DIR="${REPOSITORY_DIR:-$(cd "$INFRA_DIR/.." && pwd)}"
DOCKER_HOST="${DOCKER_HOST:-unix:///Users/enzogaggiotti/.orbstack/run/docker.sock}"

build_image() {
  local repo_dir="$1"
  local image="$2"

  if [[ ! -d "$REPOSITORY_DIR/$repo_dir" ]]; then
    echo "Missing repository: $REPOSITORY_DIR/$repo_dir" >&2
    exit 1
  fi

  echo "Building $image from $repo_dir"
  DOCKER_HOST="$DOCKER_HOST" docker build -t "$image" "$REPOSITORY_DIR/$repo_dir"
}

build_image "Aegis-AI-Api-Gateway" "ghcr.io/aegis-ai-organizations/aegis-ai-api-gateway:crewai-fields-local"
build_image "Aegis-AI-Brain" "ghcr.io/aegis-ai-organizations/aegis-ai-brain:crewai-primary-local"
build_image "Aegis-AI-Agent-Crew" "ghcr.io/aegis-ai-organizations/aegis-ai-agent-crew:tool-runner-local"
build_image "Aegis-AI-Worker-Pentest" "ghcr.io/aegis-ai-organizations/aegis-ai-worker-pentest:tool-runner-local"

echo "Local MVP images built successfully."
