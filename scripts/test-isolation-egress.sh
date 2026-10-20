#!/usr/bin/env bash
# Aegis AI — Isolation test: egress blocking from War Room sandbox
#
# Verifies that the deployer's default-deny-egress NetworkPolicy correctly
# blocks all egress from sandbox pods except DNS to kube-system:53.
#
# A positive control (DNS resolution) is run before the blocking tests.
# A blocking result is only counted as PASS when the positive control confirms
# the probe pod is healthy and allowed egress works. If the positive control
# fails, blocking tests are SKIP — a timeout is not proof of isolation when
# the probe pod itself may not have started.
#
# Tests:
#   0. [CTRL+] Positive control: DNS to kube-system:53 works
#   1. Internet (IP direct) blocked
#   2. Internet (hostname) blocked
#   3. Kubernetes API server blocked
#   4. kube-system non-DNS port blocked
#   5. aegis-system services blocked (skipped if aegis-system absent)
#   6. DNS to kube-system allowed (explicit pass/fail)
#
# Usage: scripts/test-isolation-egress.sh
# Env overrides:
#   PROBE_IMAGE           Container image for probes   (default: busybox:1.36.0)
#   PROBE_TIMEOUT         Seconds per probe            (default: 8)
#   AEGIS_ALLOWED_CONTEXT kubectl context that must be active (default: unset → warn only)
#   REPORT_FILE           Path for the log report      (default: /tmp/...)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TEST_NS="aegis-war-room-test-egress"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_FILE="${REPORT_FILE:-/tmp/aegis-isolation-egress-${TIMESTAMP}.log}"
PROBE_IMAGE="${PROBE_IMAGE:-busybox:1.36.0}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-8}"
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
# Scan ID substituted into the external-api-mock pod selector (mirrors aegis-scan label in deployer).
SANDBOX_SCAN_ID="${SANDBOX_SCAN_ID:-test-isolation}"

# P4: set to "true" after the positive control (DNS) passes.
POSITIVE_CONTROL_OK=false

exec > >(tee -a "$REPORT_FILE") 2>&1

# ── helpers ────────────────────────────────────────────────────────────────────

section() { printf '\n== %s ==\n' "$1"; }

pass() {
  printf '[PASS] %s\n' "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  printf '[FAIL] %s\n' "$1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

skip() {
  printf '[SKIP] %s\n' "$1"
  SKIP_COUNT=$((SKIP_COUNT + 1))
}

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

cleanup() {
  section "Cleanup"
  kubectl delete namespace "$TEST_NS" --ignore-not-found --wait=false 2>/dev/null || true
  printf 'Namespace %s deletion requested\n' "$TEST_NS"
}

# Run a one-shot probe pod in TEST_NS.
# Returns 0 if the probe command exits 0, non-zero otherwise.
probe() {
  local label="$1"
  local cmd="$2"
  local pod_name
  pod_name="aegis-probe-$(printf '%s' "$label" | tr -dc 'a-z0-9' | cut -c1-12)-$$"
  kubectl run "$pod_name" \
    -n "$TEST_NS" \
    --rm \
    --restart=Never \
    --image="$PROBE_IMAGE" \
    --timeout=120s \
    -- sh -c "$cmd" \
    >/dev/null 2>&1
}

# P4: assert_blocked gates on the positive control.
# If the positive control failed, the probe pod may not start at all, making a
# non-zero exit indistinguishable from a genuine network block.
assert_blocked() {
  local label="$1"
  local cmd="$2"
  if [[ "$POSITIVE_CONTROL_OK" != "true" ]]; then
    skip "$label — positive control (DNS) failed: blocking result inconclusive"
    return
  fi
  if probe "$label" "$cmd"; then
    fail "$label — connection succeeded (expected blocked)"
  else
    pass "$label — egress blocked"
  fi
}

# assert_allowed: pass when the probe command exits 0.
assert_allowed() {
  local label="$1"
  local cmd="$2"
  if probe "$label" "$cmd"; then
    pass "$label — traffic allowed"
  else
    fail "$label — connection failed (expected allowed)"
  fi
}

# ── main ───────────────────────────────────────────────────────────────────────

require_command kubectl
check_allowed_context
trap 'on_error $LINENO' ERR

section "Aegis Isolation Test: Egress Blocking"
printf 'Kubernetes context : %s\n' "$(kubectl config current-context 2>/dev/null || echo unknown)"
printf 'Test namespace     : %s\n' "$TEST_NS"
printf 'Probe image        : %s\n' "$PROBE_IMAGE"
printf 'Probe timeout      : %ss\n' "$PROBE_TIMEOUT"
printf 'Report             : %s\n' "$REPORT_FILE"

trap cleanup EXIT

section "Setup"
kubectl delete namespace "$TEST_NS" --ignore-not-found >/dev/null 2>&1 || true
for _i in $(seq 1 15); do
  kubectl get namespace "$TEST_NS" >/dev/null 2>&1 || break
  sleep 2
done
kubectl create namespace "$TEST_NS"
printf 'Namespace %s created\n' "$TEST_NS"

# Apply the same egress NetworkPolicy the deployer creates at sandbox bootstrap.
# Mirrors createSandboxNetworkPolicy in kubernetes_resources.go (two egress rules):
#   rule 1 — DNS to kube-system (UDP+TCP 53)
#   rule 2 — HTTP/HTTPS/DNS to external-api-mock pods (inert in test: no such pods exist)
kubectl apply -n "$TEST_NS" -f - <<POLICY
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  labels:
    app.kubernetes.io/managed-by: aegis-test
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:
        - podSelector:
            matchLabels:
              app: external-api-mock
              app.kubernetes.io/name: external-api-mock
              app.kubernetes.io/managed-by: aegis-worker-deployer
              aegis-scan: "$SANDBOX_SCAN_ID"
      ports:
        - protocol: TCP
          port: 80
        - protocol: TCP
          port: 443
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
POLICY
printf 'NetworkPolicy default-deny-egress applied\n'

# P4: Positive control — must pass before blocking tests count.
# Proves the probe pod can start and DNS egress is functional. If this fails,
# a timeout on a blocking test is not proof of isolation.
section "Positive control — DNS (prerequisite for blocking tests)"
if probe "positive-ctrl-dns" "nslookup kubernetes.default.svc.cluster.local >/dev/null"; then
  pass "Positive control: probe pod healthy, DNS to kube-system:53 works"
  POSITIVE_CONTROL_OK=true
else
  fail "Positive control: DNS failed — probe pod may not start or kube-system:53 unreachable"
  printf 'NOTE: All blocking tests (1-5) will be SKIP until this is resolved.\n'
fi

section "Egress Tests"

# 1. Direct IP — no DNS needed, TCP connection to public internet
assert_blocked \
  "Internet IP direct (1.1.1.1:80)" \
  "wget -q --tries=1 --timeout=$PROBE_TIMEOUT http://1.1.1.1 -O /dev/null"

# 2. Hostname — requires DNS then TCP to public internet
assert_blocked \
  "Internet hostname (example.com:80)" \
  "wget -q --tries=1 --timeout=$PROBE_TIMEOUT http://example.com -O /dev/null"

# 3. Kubernetes API server in default namespace — always present, port 443
assert_blocked \
  "Kubernetes API server (kubernetes.default:443)" \
  "wget -q --tries=1 --timeout=$PROBE_TIMEOUT --no-check-certificate https://kubernetes.default.svc.cluster.local:443 -O /dev/null"

# 4. kube-system on a non-DNS port (10250 kubelet metrics)
assert_blocked \
  "kube-system non-DNS port (:10250)" \
  "wget -q --tries=1 --timeout=$PROBE_TIMEOUT http://kube-dns.kube-system.svc.cluster.local:10250 -O /dev/null"

# 5. aegis-system internal services — conditional on aegis-system being deployed
if kubectl get namespace aegis-system >/dev/null 2>&1; then
  assert_blocked \
    "aegis-system Temporal frontend (port 7233)" \
    "wget -q --tries=1 --timeout=$PROBE_TIMEOUT http://aegis-temporal-mvp-frontend.aegis-system.svc.cluster.local:7233 -O /dev/null"
else
  skip "aegis-system not deployed — cross-namespace egress test skipped"
fi

# 6. DNS to kube-system:53 must be allowed (explicit test, also serves as positive control)
assert_allowed \
  "DNS resolution via kube-system:53" \
  "nslookup kubernetes.default.svc.cluster.local >/dev/null"

section "Summary"
TOTAL=$((PASS_COUNT + FAIL_COUNT))
printf 'PASS  : %d\n' "$PASS_COUNT"
printf 'FAIL  : %d\n' "$FAIL_COUNT"
printf 'SKIP  : %d\n' "$SKIP_COUNT"
printf 'TOTAL : %d / %d\n' "$PASS_COUNT" "$TOTAL"
printf 'Report: %s\n' "$REPORT_FILE"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  printf '\nResult: FAIL\n'
  exit 1
fi
printf '\nResult: PASS\n'
