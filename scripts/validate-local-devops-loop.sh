#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_file() {
  local path="$1"
  if [[ ! -f "$ROOT_DIR/$path" ]]; then
    echo "Missing required file: $path" >&2
    exit 1
  fi
}

require_grep() {
  local pattern="$1"
  local path="$2"
  if ! grep -qE "$pattern" "$ROOT_DIR/$path"; then
    echo "Missing pattern '$pattern' in $path" >&2
    exit 1
  fi
}

require_file Makefile
require_file scripts/setup-dns.sh
require_file scripts/e2e-local-loop.sh
require_file kubernetes/local-target/kustomization.yaml
require_file kubernetes/local-target/deployment.yaml
require_file kubernetes/local-target/service.yaml
require_file kubernetes/local-target/configmap.yaml

require_grep '^setup-dns:' Makefile
require_grep '^deploy-local-target:' Makefile
require_grep '^e2e-local-loop:' Makefile

require_grep 'app\.aegis\.mvp\.local' scripts/setup-dns.sh
require_grep 'api\.aegis\.mvp\.local' scripts/setup-dns.sh
require_grep '/etc/hosts' scripts/setup-dns.sh
require_grep 'ingress-nginx' scripts/setup-dns.sh

require_grep 'aegis-flag-1234' kubernetes/local-target/configmap.yaml
require_grep 'aegis-target' kubernetes/local-target/deployment.yaml
require_grep 'aegis-target' kubernetes/local-target/service.yaml

require_grep 'aegis-flag-1234' scripts/e2e-local-loop.sh
require_grep '/api/auth/login' scripts/e2e-local-loop.sh
require_grep '/api/storage/upload-url' scripts/e2e-local-loop.sh
require_grep '/api/scans' scripts/e2e-local-loop.sh
require_grep 'minio://' scripts/e2e-local-loop.sh
require_grep 'AEGIS_SEED_USER_EMAIL' scripts/e2e-local-loop.sh
require_grep 'AEGIS_SEED_USER_PASSWORD' scripts/e2e-local-loop.sh
