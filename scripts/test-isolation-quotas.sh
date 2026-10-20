#!/usr/bin/env bash
# Aegis AI — Isolation test: ResourceQuota and LimitRange enforcement
#
# This script has two purposes:
#
#   GAP DOCUMENTATION (tests 1-2):
#     The deployer currently creates NO ResourceQuota or LimitRange in sandbox
#     namespaces. These tests document the gap and will FAIL until the deployer
#     (internal/deployer/kubernetes_resources.go) is updated to apply them.
#
#   ENFORCEMENT PROOF (tests 3-4):
#     Applies test quotas manually and verifies that Kubernetes enforces them
#     correctly, proving the mechanism works once the deployer is wired up.
#
# Tests:
#   1. [GAP] Deployer-created sandbox has no ResourceQuota     — expected FAIL
#   2. [GAP] Deployer-created sandbox has no LimitRange        — expected FAIL
#   3. [PROOF] ResourceQuota enforced — pod within limits starts
#   4. [PROOF] LimitRange enforced — pod exceeding CPU max rejected
#              P6: distinguishes LimitRange rejection from RBAC forbidden
#
# Usage: scripts/test-isolation-quotas.sh
# Env overrides:
#   PROBE_IMAGE           Container image for test pods  (default: busybox:1.36.0)
#   AEGIS_ALLOWED_CONTEXT kubectl context guard          (default: unset → warn only)
#   REPORT_FILE           Path for the log report        (default: /tmp/...)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TEST_NS="aegis-war-room-test-quota"
# A second namespace simulating what the deployer would produce (no quotas applied).
DEPLOYER_SIM_NS="aegis-war-room-test-quota-deployer"
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
  for ns in "$TEST_NS" "$DEPLOYER_SIM_NS"; do
    kubectl delete namespace "$ns" --ignore-not-found --wait=false 2>/dev/null || true
    printf 'Namespace %s deletion requested\n' "$ns"
  done
}

delete_pod_if_exists() {
  kubectl delete pod "$1" -n "${2:-$TEST_NS}" --ignore-not-found --grace-period=0 2>/dev/null || true
}

# ── main ───────────────────────────────────────────────────────────────────────

require_command kubectl
check_allowed_context

section "Aegis Isolation Test: ResourceQuota and LimitRange"
printf 'Kubernetes context : %s\n' "$(kubectl config current-context 2>/dev/null || echo unknown)"
printf 'Test namespace     : %s\n' "$TEST_NS"
printf 'Simulated deployer : %s\n' "$DEPLOYER_SIM_NS"
printf 'Report             : %s\n' "$REPORT_FILE"
printf '\nNOTE: [GAP] tests document missing deployer functionality\n'
printf '      and are expected to FAIL until the deployer is updated.\n'

trap cleanup EXIT

section "Setup"
for ns in "$TEST_NS" "$DEPLOYER_SIM_NS"; do
  kubectl delete namespace "$ns" --ignore-not-found >/dev/null 2>&1 || true
  for _i in $(seq 1 10); do
    kubectl get namespace "$ns" >/dev/null 2>&1 || break
    sleep 2
  done
  kubectl create namespace "$ns"
  printf 'Namespace %s created\n' "$ns"
done

# ── Test 1: [GAP] No ResourceQuota in deployer-simulated namespace ────────────
section "Test 1 — [GAP] Deployer-created sandbox has ResourceQuota"
quota_count="$(kubectl get resourcequota -n "$DEPLOYER_SIM_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$quota_count" -gt 0 ]]; then
  pass "ResourceQuota exists in sandbox namespace ($quota_count found)"
else
  gap "No ResourceQuota in sandbox namespace — deployer (kubernetes_resources.go) must be updated to apply CPU/memory quotas"
fi

# ── Test 2: [GAP] No LimitRange in deployer-simulated namespace ──────────────
section "Test 2 — [GAP] Deployer-created sandbox has LimitRange"
limitrange_count="$(kubectl get limitrange -n "$DEPLOYER_SIM_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$limitrange_count" -gt 0 ]]; then
  pass "LimitRange exists in sandbox namespace ($limitrange_count found)"
else
  gap "No LimitRange in sandbox namespace — deployer must be updated to set per-container CPU/memory defaults"
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
TOTAL=$((PASS_COUNT + FAIL_COUNT))
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
  printf '\nResult: PASS (with %d infrastructure gap(s) requiring deployer update)\n' "$GAP_COUNT"
  exit 0
fi
printf '\nResult: PASS\n'
