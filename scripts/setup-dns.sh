#!/usr/bin/env bash
set -euo pipefail

HOSTS_FILE="/etc/hosts"
HOSTNAMES=("app.aegis.mvp.local" "api.aegis.mvp.local")
INGRESS_NAMESPACE="${INGRESS_NAMESPACE:-ingress-nginx}"
INGRESS_SERVICE="${INGRESS_SERVICE:-ingress-nginx-controller}"

detect_ingress_address() {
  local address

  address="$(kubectl -n "$INGRESS_NAMESPACE" get svc "$INGRESS_SERVICE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  if [[ -n "$address" ]]; then
    printf '%s\n' "$address"
    return 0
  fi

  address="$(kubectl -n "$INGRESS_NAMESPACE" get svc "$INGRESS_SERVICE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  if [[ -n "$address" ]]; then
    printf '%s\n' "$address"
    return 0
  fi

  address="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
  if [[ -n "$address" ]]; then
    printf '%s\n' "$address"
    return 0
  fi

  return 1
}

update_hosts() {
  local address="$1"
  local tmp_file
  tmp_file="$(mktemp)"

  awk '!/app\.aegis\.mvp\.local|api\.aegis\.mvp\.local/' "$HOSTS_FILE" > "$tmp_file"
  printf '%s\t%s %s\n' "$address" "${HOSTNAMES[0]}" "${HOSTNAMES[1]}" >> "$tmp_file"

  if [[ -w "$HOSTS_FILE" ]]; then
    cp "$tmp_file" "$HOSTS_FILE"
  else
    sudo cp "$tmp_file" "$HOSTS_FILE"
  fi

  rm -f "$tmp_file"
}

main() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "kubectl is required to detect the local ingress address" >&2
    exit 1
  fi

  local ingress_address
  if ! ingress_address="$(detect_ingress_address)"; then
    echo "Unable to detect Kubernetes ingress address from $INGRESS_NAMESPACE/$INGRESS_SERVICE" >&2
    exit 1
  fi

  update_hosts "$ingress_address"
  echo "Mapped ${HOSTNAMES[*]} to $ingress_address in $HOSTS_FILE"
  echo "Local web access should now work without curl --resolve."
}

main "$@"
