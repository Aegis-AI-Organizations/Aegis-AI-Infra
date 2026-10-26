#!/usr/bin/env bash
# Aegis AI — Isolation test: gVisor (runsc) runtime enforcement
#
# Verifies that:
#   1. RuntimeClass "gvisor" exists in the cluster
#   2. SANDBOX_RUNTIME_CLASS is set in deployer-worker values.yaml
#   3. A pod created with runtimeClassName: gvisor is scheduled and runs
#   4. The pod spec confirms runtimeClassName was honoured by the scheduler
#   5. Pod kernel version differs from host kernel, confirming gVisor sandbox
#      is active (not just runtimeClassName set in spec)
#
# If gVisor is not installed on cluster nodes, test 3 will FAIL with the
# scheduler event as evidence.
#
# P5: test 5 compares pod uname -r vs host uname -r. gVisor reports a fake
# kernel (typically "4.4.0") distinct from the real host kernel (e.g. "6.1.x").
# /proc/version is also captured as a second signal when available.
#
# Usage: scripts/test-isolation-gvisor.sh
# Env overrides:
#   PROBE_IMAGE           Container image for the test pod  (default: busybox:1.36.0)
#   AEGIS_ALLOWED_CONTEXT kubectl context guard             (default: unset → warn only)
#   REPORT_FILE           Path for the log report           (default: /tmp/...)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TEST_NS="aegis-war-room-test-gvisor"
TEST_POD="aegis-test-gvisor-pod"
DEPLOYER_VALUES="$ROOT_DIR/kubernetes/envs/mvp/deployer-worker/values.yaml"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_FILE="${REPORT_FILE:-/tmp/aegis-isolation-gvisor-${TIMESTAMP}.log}"
PROBE_IMAGE="${PROBE_IMAGE:-busybox:1.36.0}"
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
ENV_FAIL_COUNT=0
POD_RAN=false

exec > >(tee -a "$REPORT_FILE") 2>&1

# ── helpers ────────────────────────────────────────────────────────────────────

section() { printf '\n== %s ==\n' "$1"; }
pass()    { printf '[PASS] %s\n' "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail()    { printf '[FAIL] %s\n' "$1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
skip()    { printf '[SKIP] %s\n' "$1"; SKIP_COUNT=$((SKIP_COUNT + 1)); }
env_fail() { printf '[ENV-FAIL] %s\n' "$1"; ENV_FAIL_COUNT=$((ENV_FAIL_COUNT + 1)); }

require_command() {
  command -v "$1" >/dev/null 2>&1 || { printf 'Missing required command: %s\n' "$1" >&2; exit 127; }
}

on_error() {
  printf '\n[ERROR] Script aborted at line %s. Partial results: PASS=%d FAIL=%d. Report: %s\n' \
    "${1:-?}" "$PASS_COUNT" "$FAIL_COUNT" "$REPORT_FILE" >&2
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

is_env_failure() {
  local ns="$1" pod="$2"
  if kubectl get events -n "$ns" \
      --field-selector "involvedObject.name=$pod" \
      2>/dev/null \
      | grep -qiE 'RuntimeHandler|runsc'; then
    return 0
  fi
  if kubectl get pod "$pod" -n "$ns" \
      -o jsonpath='{.status.message}' 2>/dev/null \
      | grep -qiE 'RuntimeHandler|runsc'; then
    return 0
  fi
  return 1
}

cleanup() {
  section "Cleanup"
  kubectl delete pod "$TEST_POD" -n "$TEST_NS" --ignore-not-found --grace-period=0 2>/dev/null || true
  kubectl delete namespace "$TEST_NS" --ignore-not-found --wait=false 2>/dev/null || true
  printf 'Namespace %s deletion requested\n' "$TEST_NS"
}

# Wait for a pod to reach a terminal phase (Succeeded or Failed), with timeout.
wait_pod_terminal() {
  local ns="$1"
  local pod="$2"
  local timeout_s="${3:-120}"
  local elapsed=0
  while [[ $elapsed -lt $timeout_s ]]; do
    local phase
    phase="$(kubectl get pod "$pod" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
    case "$phase" in
      Succeeded|Failed) return 0 ;;
    esac
    sleep 3
    elapsed=$((elapsed + 3))
  done
  return 1
}

# ── main ───────────────────────────────────────────────────────────────────────

require_command kubectl
check_allowed_context
trap 'on_error $LINENO' ERR

section "Aegis Isolation Test: gVisor Runtime Class"
printf 'Kubernetes context : %s\n' "$(kubectl config current-context 2>/dev/null || echo unknown)"
printf 'Test namespace     : %s\n' "$TEST_NS"
printf 'Probe image        : %s\n' "$PROBE_IMAGE"
printf 'Deployer values    : %s\n' "$DEPLOYER_VALUES"
printf 'Report             : %s\n' "$REPORT_FILE"

trap cleanup EXIT

# ── Test 1: RuntimeClass exists in cluster ─────────────────────────────────────
section "Test 1 — RuntimeClass gvisor in cluster"
if kubectl get runtimeclass gvisor >/dev/null 2>&1; then
  handler="$(kubectl get runtimeclass gvisor -o jsonpath='{.handler}' 2>/dev/null || echo "")"
  pass "RuntimeClass 'gvisor' exists (handler: ${handler:-unknown})"
else
  fail "RuntimeClass 'gvisor' not found — run: kubectl apply -f kubernetes/envs/mvp/infrastructure/gvisor-runtimeclass/manifests/runtimeclass.yaml"
fi

# ── Test 2: deployer-worker values.yaml sets SANDBOX_RUNTIME_CLASS ────────────
section "Test 2 — SANDBOX_RUNTIME_CLASS set in deployer-worker values.yaml"
if [[ ! -f "$DEPLOYER_VALUES" ]]; then
  skip "deployer-worker values.yaml not found at $DEPLOYER_VALUES"
elif grep -qE '^[[:space:]]*-?[[:space:]]*name:[[:space:]]*SANDBOX_RUNTIME_CLASS' "$DEPLOYER_VALUES"; then
  value="$(grep -A1 'SANDBOX_RUNTIME_CLASS' "$DEPLOYER_VALUES" | grep 'value:' | awk '{print $2}' | tr -d '"' || echo "")"
  pass "SANDBOX_RUNTIME_CLASS set in deployer-worker values.yaml (value: ${value:-?})"
else
  fail "SANDBOX_RUNTIME_CLASS missing from deployer-worker/values.yaml — deployer will silently skip gVisor"
fi

# ── Test 3: pod with runtimeClassName: gvisor schedules and runs ──────────────
section "Test 3 — Pod scheduling and execution with runtimeClassName: gvisor"

kubectl delete namespace "$TEST_NS" --ignore-not-found >/dev/null 2>&1 || true
for _i in $(seq 1 15); do
  kubectl get namespace "$TEST_NS" >/dev/null 2>&1 || break
  sleep 2
done
kubectl create namespace "$TEST_NS"
printf 'Namespace %s created\n' "$TEST_NS"

# P5: collect uname -r AND /proc/version for two independent kernel identity signals.
kubectl apply -n "$TEST_NS" -f - <<MANIFEST
apiVersion: v1
kind: Pod
metadata:
  name: $TEST_POD
  labels:
    app.kubernetes.io/managed-by: aegis-test
spec:
  runtimeClassName: gvisor
  restartPolicy: Never
  containers:
    - name: probe
      image: $PROBE_IMAGE
      imagePullPolicy: IfNotPresent
      command: [sh, -c, "uname -r && echo AEGIS_GVISOR_OK && cat /proc/version 2>/dev/null || true"]
MANIFEST
printf 'Pod %s created with runtimeClassName: gvisor\n' "$TEST_POD"
printf 'Waiting for pod to reach terminal phase (max 120s)...\n'

if wait_pod_terminal "$TEST_NS" "$TEST_POD" 120; then
  phase="$(kubectl get pod "$TEST_POD" -n "$TEST_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
  if [[ "$phase" == "Succeeded" ]]; then
    pass "Pod scheduled and ran successfully under runtimeClassName: gvisor"
    POD_RAN=true
  else
    reason="$(kubectl get pod "$TEST_POD" -n "$TEST_NS" \
      -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null || echo "")"
    printf '\nScheduler events for this pod:\n'
    kubectl get events -n "$TEST_NS" \
      --field-selector "involvedObject.name=$TEST_POD" \
      --sort-by=.lastTimestamp 2>/dev/null || true
    if is_env_failure "$TEST_NS" "$TEST_POD"; then
      env_fail "RuntimeHandler 'runsc' not supported on this node — install gVisor (runsc) on cluster nodes"
    else
      fail "Pod reached phase=$phase (reason: ${reason:-unknown}) — check gVisor installation"
    fi
  fi
else
  phase="$(kubectl get pod "$TEST_POD" -n "$TEST_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")"
  printf '\nScheduler events for this pod:\n'
  kubectl get events -n "$TEST_NS" \
    --field-selector "involvedObject.name=$TEST_POD" \
    --sort-by=.lastTimestamp 2>/dev/null || true
  if is_env_failure "$TEST_NS" "$TEST_POD"; then
    env_fail "RuntimeHandler 'runsc' not supported on this node — install gVisor (runsc) on cluster nodes"
  else
    fail "Pod timed out waiting for terminal phase (current: $phase) — gVisor scheduler may be unavailable"
  fi
fi

# ── Test 4: runtimeClassName confirmed in pod spec ─────────────────────────────
section "Test 4 — runtimeClassName honoured in pod spec"
runtime_class="$(kubectl get pod "$TEST_POD" -n "$TEST_NS" \
  -o jsonpath='{.spec.runtimeClassName}' 2>/dev/null || echo "")"
if [[ "$runtime_class" == "gvisor" ]]; then
  pass "Pod spec carries runtimeClassName=gvisor"
else
  fail "Pod spec runtimeClassName='${runtime_class:-<empty>}' (expected gvisor)"
fi

# ── Test 5: kernel identity — gVisor sandbox actually active ──────────────────
# P5: compare pod uname -r with host uname -r. gVisor's fake kernel is typically
# "4.4.0"; the host kernel is usually 5.x or 6.x. Matching means gVisor is not
# sandboxing (handler misconfigured or pod ran on host kernel).
# /proc/version provides a second signal: gVisor reports a distinct version string.
section "Test 5 — gVisor kernel identity (pod kernel ≠ host kernel)"
if [[ "$POD_RAN" != "true" ]]; then
  skip "Test 5 requires pod to have run under gVisor — test 3 did not produce a Succeeded pod"
else
  logs="$(kubectl logs "$TEST_POD" -n "$TEST_NS" 2>/dev/null || echo "")"

  if ! printf '%s' "$logs" | grep -q 'AEGIS_GVISOR_OK'; then
    fail "Expected 'AEGIS_GVISOR_OK' in pod logs — pod may not have completed (logs: ${logs:-<empty>})"
  else
    host_kernel="$(uname -r)"
    pod_kernel="$(printf '%s' "$logs" | head -1)"
    proc_version="$(printf '%s' "$logs" | grep -v 'AEGIS_GVISOR_OK' | tail -1 || echo "")"

    printf '[INFO] Host kernel     : %s\n' "$host_kernel"
    printf '[INFO] Pod  kernel     : %s\n' "${pod_kernel:-<empty>}"
    if [[ -n "$proc_version" ]] && [[ "$proc_version" != "$pod_kernel" ]]; then
      printf '[INFO] /proc/version   : %s\n' "$proc_version"
    fi

    if [[ -z "$pod_kernel" ]]; then
      fail "Could not parse pod kernel version from logs"
    elif [[ "$pod_kernel" == "$host_kernel" ]]; then
      fail "Pod kernel ($pod_kernel) matches host kernel — gVisor sandbox not active (handler may be misconfigured)"
    else
      pass "Pod kernel ($pod_kernel) differs from host ($host_kernel) — gVisor sandbox is active"
      # Second signal: gVisor /proc/version contains "gvisor" or a known stub string.
      if [[ -n "$proc_version" ]]; then
        if printf '%s' "$proc_version" | grep -qiE 'gvisor|runsc|stub'; then
          pass "/proc/version confirms gVisor runtime (second signal)"
        else
          printf '[INFO] /proc/version does not contain gvisor/runsc marker — kernel diff alone is the evidence\n'
        fi
      fi
    fi
  fi
fi

section "Summary"
TOTAL=$((PASS_COUNT + FAIL_COUNT + ENV_FAIL_COUNT))
printf 'PASS     : %d\n' "$PASS_COUNT"
printf 'FAIL     : %d\n' "$FAIL_COUNT"
printf 'ENV-FAIL : %d  (environment issue — not a test logic failure)\n' "$ENV_FAIL_COUNT"
printf 'SKIP     : %d\n' "$SKIP_COUNT"
printf 'TOTAL    : %d / %d\n' "$PASS_COUNT" "$TOTAL"
printf 'Report: %s\n' "$REPORT_FILE"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  printf '\nResult: FAIL\n'
  exit 1
fi
if [[ "$ENV_FAIL_COUNT" -gt 0 ]]; then
  printf '\nResult: ENV-FAIL (gVisor not installed on cluster nodes — install runsc to enable sandbox)\n'
  exit 3
fi
printf '\nResult: PASS\n'
