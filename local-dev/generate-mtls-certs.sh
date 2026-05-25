#!/bin/sh
set -eu

cert_dir="${1:-$(dirname "$0")/certs}"
mkdir -p "$cert_dir"
umask 077

openssl genrsa -out "$cert_dir/ca.key" 4096
openssl req -x509 -new -sha256 -days 3650 \
  -key "$cert_dir/ca.key" \
  -out "$cert_dir/ca.pem" \
  -subj "/CN=Aegis Local Internal CA"

openssl req -new -newkey rsa:2048 -nodes \
  -keyout "$cert_dir/brain.key" \
  -out "$cert_dir/brain.csr" \
  -subj "/CN=brain"
cat > "$cert_dir/brain.ext" <<'EOF'
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:brain,DNS:localhost,IP:127.0.0.1
EOF
openssl x509 -req -sha256 -days 365 \
  -in "$cert_dir/brain.csr" \
  -CA "$cert_dir/ca.pem" \
  -CAkey "$cert_dir/ca.key" \
  -CAcreateserial \
  -out "$cert_dir/brain.pem" \
  -extfile "$cert_dir/brain.ext"

openssl req -new -newkey rsa:2048 -nodes \
  -keyout "$cert_dir/gateway.key" \
  -out "$cert_dir/gateway.csr" \
  -subj "/CN=gateway"
cat > "$cert_dir/gateway.ext" <<'EOF'
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth
EOF
openssl x509 -req -sha256 -days 365 \
  -in "$cert_dir/gateway.csr" \
  -CA "$cert_dir/ca.pem" \
  -CAkey "$cert_dir/ca.key" \
  -CAcreateserial \
  -out "$cert_dir/gateway.pem" \
  -extfile "$cert_dir/gateway.ext"

rm -f "$cert_dir/brain.csr" "$cert_dir/brain.ext" \
  "$cert_dir/gateway.csr" "$cert_dir/gateway.ext" "$cert_dir/ca.srl"
chmod 600 "$cert_dir"/*.key
chmod 644 "$cert_dir"/*.pem
openssl verify -CAfile "$cert_dir/ca.pem" "$cert_dir/brain.pem" "$cert_dir/gateway.pem"
