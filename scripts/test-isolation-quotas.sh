#!/usr/bin/env bash
# Aegis AI — Isolation test: ResourceQuota and LimitRange enforcement
#
# Tests:
#   1. Deployer-created sandbox has a ResourceQuota   — SKIP if no real sandbox found
#   2. Deployer-created sandbox has a LimitRange      — SKIP if no real sandbox found
#   3. [PROOF] ResourceQuota enforced — pod within limits starts
#   4. [PROOF] LimitRange enforced — pod exceeding CPU max rejected
#              P6: distinguishes LimitRange rejection from RBAC forbidden
#
# Tests 1-2 inspect a namespace created by the real deployer.
# Set SANDBOX_NS to a specific namespace, or leave unset to auto-discover
# the most recent aegis-war-room-* namespace labelled managed-by=aegis-worker-deployer.
# Both tests are SKIP when no such namespace exists on the cluster.
#
# Usage: scripts/test-isolation-quotas.sh
# Env overrides:
#   SANDBOX_NS            Deployer-created namespace to inspect (default: auto-discover)
#   PROBE_IMAGE           Container image for test pods         (default: busybox:1.36.0)
#   AEGIS_ALLOWED_CONTEXT kubectl context guard                 (default: unset → warn only)
#   REPORT_FILE           Path for the log report               (default: /tmp/...)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TEST_NS="aegis-war-room-test-quota"
# Set SANDBOX_NS to a deployer-created namespace to test, or leave empty for auto-discovery.
SANDBOX_NS="${SANDBOX_NS:-}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_FILE="${REPORT_FILE:-/tmp/aegis-isolation-quotas-${TIMESTAMP}.log}"
PROBE_IMAGE="${PROBE_IMAGE:-busybox:1.36.0}"
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
GAP_COUNT=0

exec > >(tee -a "$REPORT_FILE") 2>&1

# ── helpers ────────────────────────────────────────────────────────────────────

section() { printf '\n== %s ==\n' "$1"; }
pass()    { printf '[PASS] %s\n' "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail()    { printf '[FAIL] %s\n' "$1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
gap()     { printf '[GAP]  %s\n' "$1"; GAP_COUNT=$((GAP_COUNT + 1)); }
skip()    { printf '[SKIP] %s\n' "$1"; SKIP_COUNT=$((SKIP_COUNT + 1)); }

require_command() {
  command -v "$1" >/dev/null 2>&1 || { printf 'Missing required command: %s\n' "$1" >&2; exit 127; }
}

on_error() {
  printf '\n[ERROR] Script aborted at line %s. Partial results: PASS=%d FAIL=%d GAP=%d. Report: %s\n' \
    "${1:-?}" "$PASS_COUNT" "$FAIL_COUNT" "$GAP_COUNT" "$REPORT_FILE" >&2
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

cleanup() {
  section "Cleanup"
  kubectl delete namespace "$TEST_NS" --ignore-not-found --wait=false 2>/dev/null || true
  printf 'Namespace %s deletion requested\n' "$TEST_NS"
}

delete_pod_if_exists() {
  kubectl delete pod "$1" -n "${2:-$TEST_NS}" --ignore-not-found --grace-period=0 2>/dev/null || true
}

# ── main ───────────────────────────────────────────────────────────────────────

require_command kubectl
check_allowed_context
trap 'on_error $LINENO' ERR

section "Aegis Isolation Test: ResourceQuota and LimitRange"
printf 'Kubernetes context : %s\n' "$(kubectl config current-context 2>/dev/null || echo unknown)"
printf 'Test namespace     : %s\n' "$TEST_NS"
printf 'Report             : %s\n' "$REPORT_FILE"
trap cleanup EXIT

# Auto-discover a deployer-created sandbox if SANDBOX_NS is not set.
if [[ -z "$SANDBOX_NS" ]]; then
  SANDBOX_NS="$(kubectl get namespaces \
    -l 'app.kubernetes.io/managed-by=aegis-worker-deployer' \
    --no-headers \
    -o custom-columns=':metadata.name' 2>/dev/null \
    | grep '^aegis-war-room-' | head -1 | tr -d ' ')" || true
fi
if [[ -n "$SANDBOX_NS" ]]; then
  printf 'Sandbox under test : %s\n' "$SANDBOX_NS"
else
  printf 'Sandbox under test : (none found — tests 1-2 will be SKIP)\n'
fi

section "Setup"
kubectl delete namespace "$TEST_NS" --ignore-not-found >/dev/null 2>&1 || true
for _i in $(seq 1 10); do
  kubectl get namespace "$TEST_NS" >/dev/null 2>&1 || break
  sleep 2
done
kubectl create namespace "$TEST_NS"
printf 'Namespace %s created\n' "$TEST_NS"

# ── Test 1: Deployer-created sandbox has ResourceQuota ───────────────────────
section "Test 1 — Deployer-created sandbox has ResourceQuota"
if [[ -z "$SANDBOX_NS" ]]; then
  skip "Test 1 — no deployer-created sandbox found (set SANDBOX_NS=aegis-war-room-<scan> to override)"
else
  quota_count="$(kubectl get resourcequota -n "$SANDBOX_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$quota_count" -gt 0 ]]; then
    pass "ResourceQuota exists in $SANDBOX_NS ($quota_count found)"
  else
    fail "No ResourceQuota in $SANDBOX_NS — deployer fix not deployed or RBAC missing"
  fi
fi

# ── Test 2: Deployer-created sandbox has LimitRange ──────────────────────────
section "Test 2 — Deployer-created sandbox has LimitRange"
if [[ -z "$SANDBOX_NS" ]]; then
  skip "Test 2 — no deployer-created sandbox found"
else
  limitrange_count="$(kubectl get limitrange -n "$SANDBOX_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$limitrange_count" -gt 0 ]]; then
    pass "LimitRange exists in $SANDBOX_NS ($limitrange_count found)"
  else
    fail "No LimitRange in $SANDBOX_NS — deployer fix not deployed or RBAC missing"
  fi
fi

# ── Tests 3-4: ResourceQuota enforcement proof ────────────────────────────────
section "Setup — Apply ResourceQuota and LimitRange to $TEST_NS"

kubectl apply -n "$TEST_NS" -f - <<'QUOTA'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: aegis-sandbox-quota
  labels:
    app.kubernetes.io/managed-by: aegis-test
spec:
  hard:
    requests.cpu: "500m"
    requests.memory: "512Mi"
    limits.cpu: "1"
    limits.memory: "1Gi"
    pods: "10"
QUOTA

kubectl apply -n "$TEST_NS" -f - <<'LIMITRANGE'
apiVersion: v1
kind: LimitRange
metadata:
  name: aegis-sandbox-limits
  labels:
    app.kubernetes.io/managed-by: aegis-test
spec:
  limits:
    - type: Container
      default:
        cpu: "200m"
        memory: "256Mi"
      defaultRequest:
        cpu: "100m"
        memory: "128Mi"
      max:
        cpu: "500m"
        memory: "512Mi"
LIMITRANGE
printf 'ResourceQuota and LimitRange applied to %s\n' "$TEST_NS"

# ── Test 3: pod within quota starts successfully ──────────────────────────────
section "Test 3 — [PROOF] Pod within ResourceQuota starts"
delete_pod_if_exists "aegis-test-within-quota"
kubectl apply -n "$TEST_NS" -f - <<WITHIN
apiVersion: v1
kind: Pod
metadata:
  name: aegis-test-within-quota
  labels:
    app.kubernetes.io/managed-by: aegis-test
spec:
  restartPolicy: Never
  containers:
    - name: probe
      image: $PROBE_IMAGE
      imagePullPolicy: IfNotPresent
      command: [sh, -c, "echo OK"]
      resources:
        requests:
          cpu: "100m"
          memory: "64Mi"
        limits:
          cpu: "200m"
          memory: "128Mi"
WITHIN

for _i in $(seq 1 20); do
  phase="$(kubectl get pod aegis-test-within-quota -n "$TEST_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
  [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
  sleep 3
done
phase="$(kubectl get pod aegis-test-within-quota -n "$TEST_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")"
if [[ "$phase" == "Succeeded" ]]; then
  pass "Pod within quota started and completed (phase: Succeeded)"
else
  fail "Pod within quota did not complete (phase: $phase)"
fi

# ── Test 4: pod exceeding CPU limit is rejected ───────────────────────────────
# P6: capture output separately and distinguish LimitRange rejection from RBAC
# forbidden. A LimitRange rejection contains the max value in the message;
# an RBAC denial contains "is forbidden: User" — both matter but for different reasons.
section "Test 4 — [PROOF] Pod exceeding CPU max rejected by LimitRange"
delete_pod_if_exists "aegis-test-exceed-quota"

exceed_spec="$(cat <<EXCEED
apiVersion: v1
kind: Pod
metadata:
  name: aegis-test-exceed-quota
  labels:
    app.kubernetes.io/managed-by: aegis-test
spec:
  restartPolicy: Never
  containers:
    - name: probe
      image: $PROBE_IMAGE
      imagePullPolicy: IfNotPresent
      command: [sh, -c, "echo OK"]
      resources:
        requests:
          cpu: "800m"
          memory: "64Mi"
        limits:
          cpu: "2"
          memory: "128Mi"
EXCEED
)"

err_output="$(printf '%s' "$exceed_spec" | kubectl apply -n "$TEST_NS" -f - 2>&1 || true)"

if printf '%s' "$err_output" | grep -qiE 'maximum cpu|exceeded|must be less than or equal'; then
  pass "LimitRange rejected pod exceeding CPU limit (enforcement works)"
elif printf '%s' "$err_output" | grep -qiE 'is forbidden: User|cannot create resource "pods"'; then
  fail "Pod creation forbidden by RBAC, not LimitRange — check RBAC permissions for test user"
elif kubectl get pod aegis-test-exceed-quota -n "$TEST_NS" >/dev/null 2>&1; then
  fail "Pod exceeding CPU limit was accepted (LimitRange max is 500m CPU — pod requested 2 cores)"
  kubectl delete pod aegis-test-exceed-quota -n "$TEST_NS" --grace-period=0 2>/dev/null || true
else
  fail "Unexpected apply result — no clear accept/reject signal. Output: ${err_output:-<empty>}"
fi

section "Summary"
TOTAL=$((PASS_COUNT + FAIL_COUNT + GAP_COUNT))
printf 'PASS  : %d\n' "$PASS_COUNT"
printf 'FAIL  : %d\n' "$FAIL_COUNT"
printf 'GAP   : %d  (deployer must be updated — see details above)\n' "$GAP_COUNT"
printf 'SKIP  : %d\n' "$SKIP_COUNT"
printf 'TOTAL : %d / %d\n' "$PASS_COUNT" "$TOTAL"
printf 'Report: %s\n' "$REPORT_FILE"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  printf '\nResult: FAIL\n'
  exit 1
fi
if [[ "$GAP_COUNT" -gt 0 ]]; then
  printf '\nResult: PASS WITH GAPS (%d gap(s) — deployer update required)\n' "$GAP_COUNT"
  exit 3
fi
printf '\nResult: PASS\n'
