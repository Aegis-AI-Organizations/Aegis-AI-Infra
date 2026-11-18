#!/usr/bin/env bash
# make validate — static validation only, never touches a live cluster.
#  - yamllint on every tracked YAML file (if yamllint is available)
#  - `kubectl kustomize` on every environment (proves all referenced paths
#    exist and every kustomization/Application manifest is well-formed)
#  - dev/prod naming-isolation checks required by the dev/prod split
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

FAILED=0

echo "== YAML lint =="
if command -v yamllint >/dev/null 2>&1; then
  if ! yamllint -d relaxed kubernetes; then
    FAILED=1
  fi
else
  echo "yamllint not installed, skipping (install with: pip install yamllint)"
fi

echo ""
echo "== kubectl kustomize: every environment builds =="
for env in envs/mvp envs/prod envs/dev/dev-core envs/dev/dev-full; do
  echo "-- kubernetes/$env --"
  if ! kubectl kustomize "kubernetes/$env" > /tmp/aegis-render-"$(basename "$env")".yaml; then
    echo "FAILED: kubernetes/$env" >&2
    FAILED=1
  fi
done

echo ""
echo "== dev must never reference aegis-system, prod domains, or Cloudflare =="
if grep -rEn "aegis-system|aegis-ai\.fr|cloudflare|cloudflared" kubernetes/envs/dev; then
  echo "FAILED: dev environment references production namespace/domains/Cloudflare" >&2
  FAILED=1
else
  echo "OK"
fi

echo ""
echo "== dev and prod ArgoCD Application names must be disjoint =="
dev_names="$(grep -rhoE 'name: aegis-[a-z0-9-]+-dev' kubernetes/envs/dev kubernetes/bootstrap/root-app-dev.yaml | sort -u)"
prod_names="$(grep -rhoE 'name: aegis-[a-z0-9-]+(-mvp)?' kubernetes/envs/prod kubernetes/envs/mvp kubernetes/bootstrap/root-app-prod.yaml kubernetes/bootstrap/root-app-mvp.yaml | sort -u)"
overlap="$(comm -12 <(echo "$dev_names") <(echo "$prod_names") || true)"
if [[ -n "$overlap" ]]; then
  echo "FAILED: Application names shared between dev and prod:" >&2
  echo "$overlap" >&2
  FAILED=1
else
  echo "OK"
fi

echo ""
echo "== prod must not contain plaintext secrets =="
if grep -rniE "password:\s*['\"a-z0-9]|PASSWORD:\s*['\"a-z0-9]" kubernetes/envs/prod kubernetes/envs/mvp --include="*.yaml" | grep -vE "secretKeyRef|existingSecret|SecretKey|key:|name: aegis-env|neo4j_password"; then
  echo "FAILED: possible plaintext secret found in prod/mvp manifests" >&2
  FAILED=1
else
  echo "OK"
fi

echo ""
if [[ "$FAILED" -ne 0 ]]; then
  echo "❌ Validation failed."
  exit 1
fi
echo "✅ All validations passed."
