#!/bin/bash
set -e

# Configuration
ENV="${1:-mvp}"
CERT_DIR="./certificates/brain/$ENV"
mkdir -p "$CERT_DIR"
NAMESPACE="aegis-system"
BRAIN_SVC="brain-$ENV"
FULL_HOST="$BRAIN_SVC.$NAMESPACE.svc.cluster.local"

echo "🧠 Generating Brain mTLS Certificates for Aegis [$ENV]..."

# 1. Generate CA (if not exists)
if [ ! -f "$CERT_DIR/ca.key" ]; then
    openssl genrsa -out "$CERT_DIR/ca.key" 4096
    openssl req -x509 -new -nodes -key "$CERT_DIR/ca.key" -sha256 -days 3650 -out "$CERT_DIR/ca.crt" -subj "/CN=AegisBrainCA"
fi

# 2. Generate Server Certificate for Brain
openssl genrsa -out "$CERT_DIR/server.key" 2048
openssl req -new -key "$CERT_DIR/server.key" -out "$CERT_DIR/server.csr" -subj "/CN=$FULL_HOST"
cat <<EOT > "$CERT_DIR/server.ext"
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = $BRAIN_SVC
DNS.2 = $BRAIN_SVC.$NAMESPACE
DNS.3 = $FULL_HOST
DNS.4 = localhost
EOT
openssl x509 -req -in "$CERT_DIR/server.csr" -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial -out "$CERT_DIR/server.crt" -days 825 -sha256 -extfile "$CERT_DIR/server.ext"

# 3. Generate Client Certificate for API Gateway
openssl genrsa -out "$CERT_DIR/client.key" 2048
openssl req -new -key "$CERT_DIR/client.key" -out "$CERT_DIR/client.csr" -subj "/CN=aegis-api-gateway-client"
openssl x509 -req -in "$CERT_DIR/client.csr" -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial -out "$CERT_DIR/client.crt" -days 825 -sha256

echo "✅ Certificates generated in $CERT_DIR"

# 4. Create Kubernetes Secrets
echo "🔒 Creating Kubernetes Secrets for Brain mTLS..."
kubectl create namespace "$NAMESPACE" || true

# Secret for Brain (Server)
kubectl create secret generic brain-server-tls \
    --namespace "$NAMESPACE" \
    --from-file=ca.crt="$CERT_DIR/ca.crt" \
    --from-file=tls.crt="$CERT_DIR/server.crt" \
    --from-file=tls.key="$CERT_DIR/server.key" \
    --dry-run=client -o yaml | kubectl apply -f -

# Secret for API Gateway (Client)
kubectl create secret generic brain-client-tls \
    --namespace "$NAMESPACE" \
    --from-file=ca.crt="$CERT_DIR/ca.crt" \
    --from-file=tls.crt="$CERT_DIR/client.crt" \
    --from-file=tls.key="$CERT_DIR/client.key" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "🚀 Brain mTLS Secrets deployed."
