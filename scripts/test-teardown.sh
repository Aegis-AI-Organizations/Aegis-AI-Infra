#!/usr/bin/env bash
# Aegis AI — Teardown test + emergency cleanup tool
#
# Dual purpose:
#   TEST MODE (default): verifies that War Room sandbox teardown works correctly
#   EMERGENCY MODE    : bulk-deletes all aegis-war-room-* namespaces that are
#                       currently stuck (e.g. Temporal workflow crashed without
#                       running _cleanup). Run with --emergency to activate.
#
# Tests (test mode):
#   1. Normal teardown   — create namespace → delete → verify gone within 60s
#   2. Idempotent delete — double-delete returns CLEANED, not an error
#   3. Stuck finalizer   — add a kubernetes finalizer → delete → namespace stuck
#                          in Terminating → force-patch finalizers=[] → verify
#                          gone (documents the hard-cleanup escape hatch)
#   4. Emergency dry-run — list aegis-war-room-* namespaces that would be deleted
#   5. Residual check    — no aegis-war-room-test-* namespaces remain after tests
#
# Usage:
#   scripts/test-teardown.sh                         # run tests
#   scripts/test-teardown.sh --emergency             # confirm then bulk-delete
#   scripts/test-teardown.sh --emergency --force     # bulk-delete without TTY prompt (CI)
#
# Env overrides:
#   REPORT_FILE          Path for the log report          (default: /tmp/...)
#   WAR_ROOM_PREFIX      Namespace prefix to scan         (default: aegis-war-room-)
#   AEGIS_ALLOWED_CONTEXT kubectl context guard           (default: unset → warn only)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_FILE="${REPORT_FILE:-/tmp/aegis-teardown-${TIMESTAMP}.log}"
WAR_ROOM_PREFIX="${WAR_ROOM_PREFIX:-aegis-war-room-}"

TEST_NS="aegis-war-room-test-teardown"
TEST_NS_FINALIZER="aegis-war-room-test-teardown-fin"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# Parse flags before exec redirect so TTY check remains valid.
EMERGENCY=false
FORCE=false
for arg in "$@"; do
  case "$arg" in
    --emergency) EMERGENCY=true ;;
    --force)     FORCE=true ;;
  esac
done

exec > >(tee -a "$REPORT_FILE") 2>&1

# ── helpers ────────────────────────────────────────────────────────────────────

section() { printf '\n== %s ==\n' "$1"; }
pass()    { printf '[PASS] %s\n' "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail()    { printf '[FAIL] %s\n' "$1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
skip()    { printf '[SKIP] %s\n' "$1"; SKIP_COUNT=$((SKIP_COUNT + 1)); }
info()    { printf '[INFO] %s\n' "$1"; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || { printf 'Missing required command: %s\n' "$1" >&2; exit 127; }
}

# P2: enforce context guard.
check_allowed_context() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo "")"
  if [[ -n "${AEGIS_ALLOWED_CONTEXT:-}" ]]; then
    if [[ "$ctx" != "$AEGIS_ALLOWED_CONTEXT" ]]; then
      printf 'ERROR: current context "%s" does not match AEGIS_ALLOWED_CONTEXT="%s"\n' \
        "$ctx" "$AEGIS_ALLOWED_CONTEXT" >&2
      printf '       Set AEGIS_ALLOWED_CONTEXT=%s to run on this cluster.\n' "$ctx" >&2
      exit 2
    fi
  else
    printf 'WARNING: AEGIS_ALLOWED_CONTEXT is not set — running on "%s" without context guard.\n' "$ctx"
    printf '         Export AEGIS_ALLOWED_CONTEXT="%s" to enforce safety.\n\n' "$ctx"
  fi
}

# Wait until a namespace is fully absent, up to timeout_s seconds.
wait_ns_gone() {
  local ns="$1"
  local timeout_s="${2:-60}"
  local elapsed=0
  while [[ $elapsed -lt $timeout_s ]]; do
    kubectl get namespace "$ns" >/dev/null 2>&1 || return 0
    sleep 3
    elapsed=$((elapsed + 3))
  done
  return 1
}

cleanup() {
  section "Cleanup"
  for ns in "$TEST_NS" "$TEST_NS_FINALIZER"; do
    # Force-remove finalizers before deletion in case test left namespace stuck.
    local phase
    phase="$(kubectl get namespace "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
    if [[ "$phase" == "Terminating" ]]; then
      kubectl patch namespace "$ns" \
        --type=merge \
        -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
    fi
    kubectl delete namespace "$ns" --ignore-not-found --wait=false 2>/dev/null || true
    printf 'Namespace %s deletion requested\n' "$ns"
  done
}

# ── emergency mode ─────────────────────────────────────────────────────────────

emergency_teardown() {
  section "EMERGENCY TEARDOWN — deleting all ${WAR_ROOM_PREFIX}* namespaces"
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo unknown)"
  printf 'Kubernetes context: %s\n' "$ctx"
  printf 'WARNING: this is destructive and irreversible.\n\n'

  mapfile -t orphans < <(
    kubectl get namespaces -o name 2>/dev/null \
      | grep "namespace/${WAR_ROOM_PREFIX}" \
      | sed 's|namespace/||'
  )

  if [[ ${#orphans[@]} -eq 0 ]]; then
    printf 'No %s* namespaces found. Nothing to do.\n' "$WAR_ROOM_PREFIX"
    exit 0
  fi

  printf 'Found %d namespace(s) to delete:\n' "${#orphans[@]}"
  for ns in "${orphans[@]}"; do
    local phase
    phase="$(kubectl get namespace "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo unknown)"
    printf '  - %s (phase: %s)\n' "$ns" "$phase"
  done
  printf '\n'

  # P1: require explicit confirmation unless --force is set.
  if ! $FORCE; then
    if [[ ! -t 0 ]]; then
      printf 'ERROR: no TTY detected. Rerun with --force to skip confirmation in non-interactive mode.\n' >&2
      exit 1
    fi
    printf 'Type "yes" to confirm deletion of %d namespace(s) on context "%s": ' \
      "${#orphans[@]}" "$ctx"
    read -r confirm
    if [[ "$confirm" != "yes" ]]; then
      printf 'Aborted.\n'
      exit 1
    fi
  fi

  for ns in "${orphans[@]}"; do
    local phase
    phase="$(kubectl get namespace "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
    if [[ "$phase" == "Terminating" ]]; then
      printf 'Patching finalizers on stuck namespace %s...\n' "$ns"
      kubectl patch namespace "$ns" \
        --type=merge \
        -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
    fi
    kubectl delete namespace "$ns" --ignore-not-found --wait=false
    printf 'Deletion requested: %s\n' "$ns"
  done

  printf '\nAll deletions requested. Waiting up to 90s for namespaces to disappear...\n'
  for ns in "${orphans[@]}"; do
    if wait_ns_gone "$ns" 90; then
      printf '[GONE] %s\n' "$ns"
    else
      printf '[STUCK] %s still present after 90s — check for remaining finalizers:\n' "$ns"
      kubectl get namespace "$ns" -o jsonpath='{.metadata.finalizers}' 2>/dev/null || true
      printf '\n'
    fi
  done

  printf '\nReport: %s\n' "$REPORT_FILE"
  exit 0
}

# ── main ───────────────────────────────────────────────────────────────────────

require_command kubectl
check_allowed_context

if $EMERGENCY; then
  emergency_teardown
fi

section "Aegis Teardown Test"
printf 'Kubernetes context : %s\n' "$(kubectl config current-context 2>/dev/null || echo unknown)"
printf 'Test namespace     : %s\n' "$TEST_NS"
printf 'Finalizer test ns  : %s\n' "$TEST_NS_FINALIZER"
printf 'War room prefix    : %s\n' "$WAR_ROOM_PREFIX"
printf 'Report             : %s\n' "$REPORT_FILE"

trap cleanup EXIT

# ── Test 1: Normal teardown ────────────────────────────────────────────────────
section "Test 1 — Normal teardown: create → delete → gone within 60s"

kubectl delete namespace "$TEST_NS" --ignore-not-found >/dev/null 2>&1 || true
for _i in $(seq 1 15); do
  kubectl get namespace "$TEST_NS" >/dev/null 2>&1 || break
  sleep 2
done
kubectl create namespace "$TEST_NS"
printf 'Namespace %s created\n' "$TEST_NS"

# Create a minimal deployment to simulate a real sandbox.
kubectl create deployment aegis-test-app \
  -n "$TEST_NS" \
  --image=busybox:1.36.0 \
  -- sh -c "sleep 3600" >/dev/null
printf 'Deployment created in %s\n' "$TEST_NS"

# Delete the namespace (mirrors DestroySandbox in activities.go).
kubectl delete namespace "$TEST_NS" --wait=false
printf 'Namespace %s deletion requested\n' "$TEST_NS"

if wait_ns_gone "$TEST_NS" 60; then
  pass "Namespace $TEST_NS fully terminated within 60s"
else
  fail "Namespace $TEST_NS still present after 60s — check for stuck finalizers"
  kubectl get namespace "$TEST_NS" \
    -o jsonpath='{.metadata.finalizers}' 2>/dev/null && printf '\n' || true
fi

# ── Test 2: Idempotent delete (double-delete) ──────────────────────────────────
section "Test 2 — Idempotent delete: deleting absent namespace returns success"

if kubectl delete namespace "$TEST_NS" --ignore-not-found 2>&1 | grep -qiE 'error|panic'; then
  fail "Deleting absent namespace $TEST_NS produced an error"
else
  pass "Deleting absent namespace $TEST_NS is idempotent (mirrors DestroySandbox CLEANED path)"
fi

# ── Test 3: Stuck-finalizer hard-cleanup escape hatch ─────────────────────────
section "Test 3 — Stuck finalizer: patch finalizers=[] to unblock termination"

kubectl delete namespace "$TEST_NS_FINALIZER" --ignore-not-found >/dev/null 2>&1 || true
for _i in $(seq 1 15); do
  kubectl get namespace "$TEST_NS_FINALIZER" >/dev/null 2>&1 || break
  sleep 2
done
kubectl create namespace "$TEST_NS_FINALIZER"
printf 'Namespace %s created\n' "$TEST_NS_FINALIZER"

# Add a custom finalizer so the namespace gets stuck in Terminating.
kubectl patch namespace "$TEST_NS_FINALIZER" \
  --type=merge \
  -p '{"metadata":{"finalizers":["aegis.io/test-finalizer"]}}'
printf 'Finalizer aegis.io/test-finalizer added to %s\n' "$TEST_NS_FINALIZER"

kubectl delete namespace "$TEST_NS_FINALIZER" --wait=false
printf 'Deletion requested — namespace should be stuck in Terminating\n'

sleep 5
phase="$(kubectl get namespace "$TEST_NS_FINALIZER" \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "gone")"

if [[ "$phase" == "Terminating" ]]; then
  info "Namespace is in Terminating phase as expected — applying finalizer patch"
  kubectl patch namespace "$TEST_NS_FINALIZER" \
    --type=merge \
    -p '{"metadata":{"finalizers":[]}}'
  printf 'Finalizers cleared\n'

  if wait_ns_gone "$TEST_NS_FINALIZER" 30; then
    pass "Namespace $TEST_NS_FINALIZER removed after finalizer patch (hard-cleanup path works)"
  else
    fail "Namespace $TEST_NS_FINALIZER still present after finalizer patch and 30s wait"
  fi
elif [[ "$phase" == "gone" ]]; then
  skip "Namespace was already gone before stuck-state could be verified (fast GC)"
else
  fail "Expected Terminating phase but got '$phase' — finalizer test inconclusive"
fi

# ── Test 4: Emergency dry-run — list what would be deleted ────────────────────
section "Test 4 — Emergency dry-run: list aegis-war-room-* namespaces"
mapfile -t candidates < <(
  kubectl get namespaces -o name 2>/dev/null \
    | grep "namespace/${WAR_ROOM_PREFIX}" \
    | sed 's|namespace/||' || true
)
if [[ ${#candidates[@]} -eq 0 ]]; then
  pass "No orphaned ${WAR_ROOM_PREFIX}* namespaces found (clean state)"
else
  printf '[INFO] %d orphaned namespace(s) would be deleted by --emergency:\n' "${#candidates[@]}"
  for ns in "${candidates[@]}"; do
    phase="$(kubectl get namespace "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo unknown)"
    printf '       - %s (phase: %s)\n' "$ns" "$phase"
  done
  fail "Found ${#candidates[@]} orphaned ${WAR_ROOM_PREFIX}* namespace(s) — run with --emergency to clean up"
fi

# ── Test 5: Residual check ─────────────────────────────────────────────────────
section "Test 5 — Residual check: no aegis-war-room-test-* namespaces remain"
mapfile -t residuals < <(
  kubectl get namespaces -o name 2>/dev/null \
    | grep "namespace/aegis-war-room-test-" \
    | sed 's|namespace/||' || true
)
if [[ ${#residuals[@]} -eq 0 ]]; then
  pass "No aegis-war-room-test-* namespaces remain"
else
  fail "${#residuals[@]} test namespace(s) still present after teardown:"
  for ns in "${residuals[@]}"; do
    printf '       - %s\n' "$ns"
  done
fi

section "Summary"
TOTAL=$((PASS_COUNT + FAIL_COUNT))
printf 'PASS  : %d\n' "$PASS_COUNT"
printf 'FAIL  : %d\n' "$FAIL_COUNT"
printf 'SKIP  : %d\n' "$SKIP_COUNT"
printf 'TOTAL : %d / %d\n' "$PASS_COUNT" "$TOTAL"
printf 'Report: %s\n' "$REPORT_FILE"
printf '\nTo clean up orphaned sandboxes: %s --emergency\n' "$(basename "$0")"
printf 'In CI (no TTY): %s --emergency --force\n' "$(basename "$0")"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  printf '\nResult: FAIL\n'
  exit 1
fi
printf '\nResult: PASS\n'
