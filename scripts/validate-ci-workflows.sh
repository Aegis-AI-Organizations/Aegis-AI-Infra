#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/build-and-test.yml"

require_grep() {
  local pattern="$1"
  local path="$2"
  if ! grep -qE "$pattern" "$path"; then
    echo "Missing pattern '$pattern' in ${path#$ROOT_DIR/}" >&2
    exit 1
  fi
}

if grep -qE '^    timeout-minutes:' "$WORKFLOW"; then
  echo "Build/test workflow must not use job-level timeouts because they can expire while queued" >&2
  exit 1
fi

require_grep "version: 'v3\.15\.4'" "$WORKFLOW"
require_grep "version: 'v1\.30\.8'" "$WORKFLOW"
require_grep 'bash scripts/validate-ci-workflows\.sh' "$WORKFLOW"
