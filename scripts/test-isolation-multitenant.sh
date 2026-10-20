#!/usr/bin/env bash
# Aegis AI — Isolation test: cross-tenant network isolation
#
# Verifies that two co-resident War Room sandbox namespaces cannot reach each
# other over the cluster network. Each sandbox gets a target pod (httpd) and a
# Service; then each side tries to connect to the other's service. Both must be
# blocked.
#
# Tests:
#   1. NS_A → NS_B blocked (egress from A to B's ClusterIP)
#   2. NS_B → NS_A blocked (egress from B to A's ClusterIP)
#   3. NS_A → NS_B service blocked (by DNS cross-namespace name)
#   4. NS_B → NS_A service blocked (by DNS cross-namespace name)
#
# Each blocking test is gated on a positive control (DNS from the source
# namespace). A blocking result is only counted as PASS when the positive
# control proves the probe pod is healthy and the allowed egress works.
# If the positive control fails the blocking test is SKIP, not PASS.
#
# Both sandboxes use the same deployer-style NetworkPolicy (default-deny-egress
# + DNS-only exception).
#
# Usage: scripts/test-isolation-multitenant.sh
# Env overrides:
#   PROBE_IMAGE           Container image for test pods  (default: busybox:1.36.0)
#   PROBE_TIMEOUT         Seconds per connection probe   (default: 8)
#   AEGIS_ALLOWED_CONTEXT kubectl context that must be active (default: unset → warn only)
#   REPORT_FILE           Path for the log report        (default: /tmp/...)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

NS_A="aegis-war-room-test-tenant-a"
NS_B="aegis-war-room-test-tenant-b"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_FILE="${REPORT_FILE:-/tmp/aegis-isolation-multitenant-${TIMESTAMP}.log}"
PROBE_IMAGE="${PROBE_IMAGE:-busybox:1.36.0}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-8}"
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# Positive control flags: set to "true" after DNS check succeeds per namespace.
DNS_OK_A=false
DNS_OK_B=false
# Target readiness flags: set to "true" when target pod is Running.
POD_A_READY=false
POD_B_READY=false

exec > >(tee -a "$REPORT_FILE") 2>&1

# ── helpers ────────────────────────────────────────────────────────────────────

section() { printf '\n== %s ==\n' "$1"; }
pass()    { printf '[PASS] %s\n' "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail()    { printf '[FAIL] %s\n' "$1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
skip()    { printf '[SKIP] %s\n' "$1"; SKIP_COUNT=$((SKIP_COUNT + 1)); }

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
  for ns in "$NS_A" "$NS_B"; do
    kubectl delete namespace "$ns" --ignore-not-found --wait=false 2>/dev/null || true
    printf 'Namespace %s deletion requested\n' "$ns"
  done
}

# Apply the deployer's default-deny-egress NetworkPolicy to a namespace.
apply_sandbox_netpolicy() {
  local ns="$1"
  kubectl apply -n "$ns" -f - <<'POLICY'
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
POLICY
}

# Create a target pod (busybox httpd) and a Service in the given namespace.
# P3: uses httpd -f instead of nc -e (nc -e not available in standard busybox builds).
create_target() {
  local ns="$1"
  local name="aegis-target-$ns"

  kubectl apply -n "$ns" -f - <<MANIFEST
apiVersion: v1
kind: Pod
metadata:
  name: $name
  labels:
    app: aegis-target
    app.kubernetes.io/managed-by: aegis-test
spec:
  restartPolicy: Never
  containers:
    - name: srv
      image: $PROBE_IMAGE
      imagePullPolicy: IfNotPresent
      command: [sh, -c, "httpd -f -p 8080 -h /tmp"]
MANIFEST

  kubectl apply -n "$ns" -f - <<SVC
apiVersion: v1
kind: Service
metadata:
  name: aegis-target
  labels:
    app.kubernetes.io/managed-by: aegis-test
spec:
  selector:
    app: aegis-target
  ports:
    - port: 8080
      targetPort: 8080
  type: ClusterIP
SVC
  printf 'Target pod+service created in %s\n' "$ns"
}

# Wait until a pod is Running (up to timeout_s seconds). Returns 0 if Running.
wait_pod_running() {
  local ns="$1"
  local pod="$2"
  local timeout_s="${3:-60}"
  local elapsed=0
  while [[ $elapsed -lt $timeout_s ]]; do
    local phase
    phase="$(kubectl get pod "$pod" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
    [[ "$phase" == "Running" ]] && return 0
    sleep 3
    elapsed=$((elapsed + 3))
  done
  return 1
}

# P4: positive control — verify DNS works from a namespace (probe pod can start
# and the allowed egress to kube-system:53 is functional).
# Returns 0 if DNS works, non-0 otherwise.
probe_dns() {
  local ns="$1"
  local pod_name="aegis-probe-dns-$$"
  kubectl run "$pod_name" \
    -n "$ns" \
    --rm \
    --restart=Never \
    --image="$PROBE_IMAGE" \
    --timeout=60s \
    -- sh -c "nslookup kubernetes.default.svc.cluster.local >/dev/null" \
    >/dev/null 2>&1
}

# Run a transient probe from src_ns trying to reach target (host:port).
# Returns 0 if connection succeeded, non-zero if blocked/timed-out.
probe_cross() {
  local src_ns="$1"
  local target_host="$2"
  local target_port="${3:-8080}"
  local pod_name="aegis-probe-cross-$$"

  kubectl run "$pod_name" \
    -n "$src_ns" \
    --rm \
    --restart=Never \
    --image="$PROBE_IMAGE" \
    --timeout=120s \
    -- sh -c "nc -z -w${PROBE_TIMEOUT} ${target_host} ${target_port}" \
    >/dev/null 2>&1
}

# Assert a cross-namespace connection is blocked, gated on positive control.
# $1=label $2=src_ns $3=target_host $4=target_port $5=dns_ok_var $6=target_ready_var
assert_cross_blocked() {
  local label="$1"
  local src_ns="$2"
  local target_host="$3"
  local target_port="${4:-8080}"
  local dns_ok="$5"       # "true" or "false"
  local target_ready="$6" # "true" or "false"

  if [[ "$dns_ok" != "true" ]]; then
    skip "$label — positive control (DNS from $src_ns) failed: blocking result inconclusive"
    return
  fi
  if [[ "$target_ready" != "true" ]]; then
    skip "$label — target pod not Running: blocking result inconclusive"
    return
  fi
  if probe_cross "$src_ns" "$target_host" "$target_port"; then
    fail "$label — connection succeeded (cross-tenant egress must be blocked)"
  else
    pass "$label — egress blocked"
  fi
}

# ── main ───────────────────────────────────────────────────────────────────────

require_command kubectl
check_allowed_context
trap 'on_error $LINENO' ERR

section "Aegis Isolation Test: Cross-Tenant Network Isolation"
printf 'Kubernetes context : %s\n' "$(kubectl config current-context 2>/dev/null || echo unknown)"
printf 'Tenant A namespace : %s\n' "$NS_A"
printf 'Tenant B namespace : %s\n' "$NS_B"
printf 'Probe image        : %s\n' "$PROBE_IMAGE"
printf 'Probe timeout      : %ss\n' "$PROBE_TIMEOUT"
printf 'Report             : %s\n' "$REPORT_FILE"

trap cleanup EXIT

section "Setup — Create namespaces and apply NetworkPolicies"
for ns in "$NS_A" "$NS_B"; do
  kubectl delete namespace "$ns" --ignore-not-found >/dev/null 2>&1 || true
  for _i in $(seq 1 15); do
    kubectl get namespace "$ns" >/dev/null 2>&1 || break
    sleep 2
  done
  kubectl create namespace "$ns"
  apply_sandbox_netpolicy "$ns"
  printf 'Namespace %s created with default-deny-egress\n' "$ns"
done

section "Setup — Deploy target pods and services"
create_target "$NS_A"
create_target "$NS_B"

# P3/P7: wait for pods; set ready flags; SKIP tests if pod did not reach Running.
printf 'Waiting for target pods to reach Running (max 60s)...\n'
for ns in "$NS_A" "$NS_B"; do
  target="aegis-target-$ns"
  if wait_pod_running "$ns" "$target" 60; then
    printf 'Pod %s/%s is Running\n' "$ns" "$target"
    [[ "$ns" == "$NS_A" ]] && POD_A_READY=true || POD_B_READY=true
  else
    phase="$(kubectl get pod "$target" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo unknown)"
    # P7: SKIP instead of WARNING — a non-Running target makes blocking tests inconclusive.
    skip "Target pod $ns/$target not Running (phase: $phase) — tests targeting this pod will be SKIP"
  fi
done

# Resolve ClusterIPs for the direct-IP tests (tests 1-2).
IP_A="$(kubectl get svc aegis-target -n "$NS_A" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")"
IP_B="$(kubectl get svc aegis-target -n "$NS_B" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")"
printf 'Service ClusterIP A: %s\n' "${IP_A:-<unavailable>}"
printf 'Service ClusterIP B: %s\n' "${IP_B:-<unavailable>}"

# P4: Positive controls — verify probe pod can start and DNS works from each namespace.
section "Positive Controls — DNS reachability from each namespace"
if probe_dns "$NS_A"; then
  pass "Positive control: DNS works from NS_A (probe pod healthy, kube-system:53 reachable)"
  DNS_OK_A=true
else
  fail "Positive control: DNS failed from NS_A — tests probing FROM NS_A will be SKIP"
fi

if probe_dns "$NS_B"; then
  pass "Positive control: DNS works from NS_B (probe pod healthy, kube-system:53 reachable)"
  DNS_OK_B=true
else
  fail "Positive control: DNS failed from NS_B — tests probing FROM NS_B will be SKIP"
fi

section "Cross-Tenant Tests"

# ── Test 1: NS_A → NS_B pod IP blocked ────────────────────────────────────────
section "Test 1 — NS_A cannot reach NS_B by ClusterIP"
if [[ -z "$IP_B" ]]; then
  skip "NS_B Service ClusterIP unavailable — skipping direct-IP test"
else
  assert_cross_blocked \
    "NS_A → NS_B ClusterIP ($IP_B:8080)" \
    "$NS_A" "$IP_B" 8080 "$DNS_OK_A" "$POD_B_READY"
fi

# ── Test 2: NS_B → NS_A pod IP blocked ────────────────────────────────────────
section "Test 2 — NS_B cannot reach NS_A by ClusterIP"
if [[ -z "$IP_A" ]]; then
  skip "NS_A Service ClusterIP unavailable — skipping direct-IP test"
else
  assert_cross_blocked \
    "NS_B → NS_A ClusterIP ($IP_A:8080)" \
    "$NS_B" "$IP_A" 8080 "$DNS_OK_B" "$POD_A_READY"
fi

# ── Test 3: NS_A → NS_B DNS name blocked ──────────────────────────────────────
# DNS resolves (kube-system:53 is allowed) but the TCP connection must be blocked.
section "Test 3 — NS_A cannot reach NS_B by DNS name"
DNS_B="aegis-target.${NS_B}.svc.cluster.local"
assert_cross_blocked \
  "NS_A → NS_B DNS ($DNS_B:8080)" \
  "$NS_A" "$DNS_B" 8080 "$DNS_OK_A" "$POD_B_READY"

# ── Test 4: NS_B → NS_A DNS name blocked ──────────────────────────────────────
section "Test 4 — NS_B cannot reach NS_A by DNS name"
DNS_A="aegis-target.${NS_A}.svc.cluster.local"
assert_cross_blocked \
  "NS_B → NS_A DNS ($DNS_A:8080)" \
  "$NS_B" "$DNS_A" 8080 "$DNS_OK_B" "$POD_A_READY"

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
