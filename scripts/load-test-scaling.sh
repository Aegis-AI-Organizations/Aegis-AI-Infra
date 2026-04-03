#!/bin/bash
set -e

# Load .env
ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    echo "❌ .env file not found."
    exit 1
fi

GATEWAY_URL="http://localhost:3000/api"
EMAIL="${AEGIS_SEED_USER_EMAIL}"
PASSWORD="${AEGIS_SEED_USER_PASSWORD}"

echo "🔐 Logging in to Aegis API Gateway..."
LOGIN_RESP=$(curl -s -X POST "$GATEWAY_URL/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\", \"password\":\"$PASSWORD\"}")

TOKEN=$(echo $LOGIN_RESP | grep -oE '"access_token":"[^"]+"' | cut -d'"' -f4)

if [ -z "$TOKEN" ]; then
    echo "❌ Failed to get access token. Response: $LOGIN_RESP"
    exit 1
fi

echo "🚀 Simulating 50 scan requests to trigger KEDA scaling..."
for i in {1..50}; do
    curl -s -X POST "$GATEWAY_URL/scans" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"target_image": "nginx:latest"}' > /dev/null &

    if [ $((i % 10)) -eq 0 ]; then
        echo "📤 Sent $i requests..."
    fi
done

echo "✅ All 50 requests sent. Waiting for KEDA to scale up pods..."
echo "📊 Monitor with: kubectl get pods -n aegis-system -l app=pentest-worker-mvp -w"

# Optional: wait and check
sleep 5
COUNT=$(kubectl get pods -n aegis-system -l app=pentest-worker-mvp --no-headers | wc -l)
echo "📈 Current worker pod count: $COUNT"
