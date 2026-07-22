#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"
API_BASE_URL="${API_BASE_URL:-https://api.aegis.mvp.local}"
API_BASE_URL="${API_BASE_URL%/}"
if [[ "$API_BASE_URL" == */api ]]; then
  API_BASE_URL="${API_BASE_URL%/api}"
fi
ARTIFACT_BUCKET="${ARTIFACT_BUCKET:-aegis-telemetry}"
SCAN_TARGET_REF="${SCAN_TARGET_REF:-}"
EXPECTED_FLAG="${EXPECTED_FLAG:-aegis-flag-1234}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-10}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-900}"
CURL_INSECURE="${CURL_INSECURE:-true}"

curl_flags=(-sS)
if [[ "$CURL_INSECURE" == "true" ]]; then
  curl_flags+=(-k)
fi

json_field() {
  local field="$1"
  python3 -c 'import json,sys; data=json.load(sys.stdin); print(data.get(sys.argv[1], ""))' "$field"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "$1 is required" >&2
    exit 1
  fi
}

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  fi

  : "${AEGIS_SEED_USER_EMAIL:?AEGIS_SEED_USER_EMAIL must be set in .env or the environment}"
  : "${AEGIS_SEED_USER_PASSWORD:?AEGIS_SEED_USER_PASSWORD must be set in .env or the environment}"
}

api_request() {
  curl "${curl_flags[@]}" "$@"
}

login() {
  local response token
  response="$(api_request -X POST "$API_BASE_URL/api/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$AEGIS_SEED_USER_EMAIL\",\"password\":\"$AEGIS_SEED_USER_PASSWORD\"}")"
  token="$(printf '%s' "$response" | json_field access_token)"
  if [[ -z "$token" ]]; then
    echo "Login failed: $response" >&2
    exit 1
  fi
  printf '%s\n' "$token"
}

write_topology_artifact() {
  local artifact_file="$1"
  python3 - "$artifact_file" <<'PY'
import json
import sys

app = r'''
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse
import json
import sqlite3

DB = sqlite3.connect(":memory:", check_same_thread=False)
DB.executescript("""
CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT, password TEXT, seed_flag TEXT);
INSERT INTO users VALUES (1, 'demo@aegis.local', 'public-demo-data', '');
INSERT INTO users VALUES (2, 'admin@aegis.local', 'super-secret', 'aegis-flag-1234');
""")

class Handler(BaseHTTPRequestHandler):
    def _json(self, status, body):
        data = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            self._json(200, {"status": "ok"})
            return
        if parsed.path == "/":
            self._json(200, {"service": "Aegis-Target", "hint": "/search?q=' OR '1'='1"})
            return
        if parsed.path != "/search":
            self._json(404, {"error": "not found"})
            return

        q = parse_qs(parsed.query).get("q", ["1"])[0]
        query = "SELECT email, password, seed_flag FROM users WHERE email = '" + q + "'"
        try:
            rows = DB.execute(query).fetchall()
            self._json(200, {
                "query": query,
                "results": [{"email": r[0], "password": r[1], "seed_flag": r[2]} for r in rows],
            })
        except Exception as exc:
            self._json(500, {"error": str(exc), "query": query})

HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
'''.strip()

payload = {
    "target_image": "topology:aegis-target-sqli",
    "preferred_endpoint_workload": "aegis-target",
    "topology": {
        "workloads": [
            {
                "name": "aegis-target",
                "image": "python:3.12-alpine",
                "command": ["python", "/app/app.py"],
                "ports": [{"name": "http", "container_port": 8080, "port": 8080}],
                "config_files": [{"path": "/app/app.py", "content": app}],
            }
        ]
    },
}

with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(payload, fh, separators=(",", ":"))
PY
}

upload_topology_artifact() {
  local token="$1"
  local upload_response upload_url object_name artifact_file

  upload_response="$(api_request -H "Authorization: Bearer $token" "$API_BASE_URL/api/storage/upload-url?prefix=local-devops-loop")"
  upload_url="$(printf '%s' "$upload_response" | json_field url)"
  object_name="$(printf '%s' "$upload_response" | json_field object_name)"
  if [[ -z "$upload_url" || -z "$object_name" ]]; then
    echo "Failed to get upload URL: $upload_response" >&2
    exit 1
  fi

  artifact_file="$(mktemp)"
  write_topology_artifact "$artifact_file"
  api_request -X PUT "$upload_url" -H "Content-Type: application/json" --data-binary "@$artifact_file" >/dev/null
  rm -f "$artifact_file"

  printf 'minio://%s/%s\n' "$ARTIFACT_BUCKET" "$object_name"
}

create_scan() {
  local token="$1"
  local target_ref="$2"
  local response scan_id
  response="$(api_request -X POST "$API_BASE_URL/api/scans" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "{\"target_image\":\"$target_ref\",\"webapp_count\":1}")"
  scan_id="$(printf '%s' "$response" | json_field scan_id)"
  if [[ -z "$scan_id" ]]; then
    echo "Scan creation failed: $response" >&2
    exit 1
  fi
  printf '%s\n' "$scan_id"
}

wait_for_scan() {
  local token="$1"
  local scan_id="$2"
  local deadline=$((SECONDS + TIMEOUT_SECONDS))
  local response status

  while (( SECONDS < deadline )); do
    response="$(api_request -H "Authorization: Bearer $token" "$API_BASE_URL/api/scans/$scan_id")"
    status="$(printf '%s' "$response" | json_field status)"
    echo "Scan $scan_id status: ${status:-unknown}"

    case "$status" in
      COMPLETED|completed|SUCCESS|success|DONE|done)
        return 0
        ;;
      FAILED|failed|ERROR|error|CANCELLED|cancelled)
        echo "Scan failed: $response" >&2
        exit 1
        ;;
    esac

    sleep "$POLL_INTERVAL_SECONDS"
  done

  echo "Timed out waiting for scan $scan_id after ${TIMEOUT_SECONDS}s" >&2
  exit 1
}

assert_flag() {
  local token="$1"
  local scan_id="$2"
  local vulnerabilities evidence_ids evidence response

  vulnerabilities="$(api_request -H "Authorization: Bearer $token" "$API_BASE_URL/api/scans/$scan_id/vulnerabilities")"
  if grep -q "$EXPECTED_FLAG" <<<"$vulnerabilities"; then
    echo "Found $EXPECTED_FLAG in scan vulnerabilities."
    return 0
  fi

  evidence_ids="$(printf '%s' "$vulnerabilities" | python3 -c 'import json,sys; data=json.load(sys.stdin); items=data.get("vulnerabilities", data) if isinstance(data, dict) else data; print("\n".join(str(v.get("id", "")) for v in items if isinstance(v, dict) and v.get("id")))')"
  while IFS= read -r evidence_id; do
    [[ -z "$evidence_id" ]] && continue
    response="$(api_request -H "Authorization: Bearer $token" "$API_BASE_URL/api/vulnerabilities/$evidence_id/evidences")"
    if grep -q "$EXPECTED_FLAG" <<<"$response"; then
      echo "Found $EXPECTED_FLAG in evidence for vulnerability $evidence_id."
      return 0
    fi
  done <<<"$evidence_ids"

  evidence="$(api_request -H "Authorization: Bearer $token" "$API_BASE_URL/api/scans/$scan_id/report" || true)"
  if grep -q "$EXPECTED_FLAG" <<<"$evidence"; then
    echo "Found $EXPECTED_FLAG in scan report."
    return 0
  fi

  echo "Did not find $EXPECTED_FLAG in vulnerabilities, evidences, or report for scan $scan_id" >&2
  echo "$vulnerabilities" >&2
  exit 1
}

main() {
  require_command curl
  require_command python3
  load_env

  echo "Logging into $API_BASE_URL..."
  local token target_ref scan_id
  token="$(login)"
  target_ref="$SCAN_TARGET_REF"
  if [[ -z "$target_ref" ]]; then
    echo "Uploading local Aegis-Target topology artifact..."
    target_ref="$(upload_topology_artifact "$token")"
  fi
  echo "Creating scan for $target_ref..."
  scan_id="$(create_scan "$token" "$target_ref")"
  echo "Created scan $scan_id."

  wait_for_scan "$token" "$scan_id"
  assert_flag "$token" "$scan_id"
  echo "Local DevOps loop succeeded: $EXPECTED_FLAG extracted."
}

main "$@"
