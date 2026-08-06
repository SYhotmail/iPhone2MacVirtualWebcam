#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESOURCES_DIR="$ROOT_DIR/Transport/Sources/Transport/Resources"

CERT_BASENAME="${CERT_BASENAME:-cam2mac-local-server}"
CERT_COMMON_NAME="${CERT_COMMON_NAME:-Cam2Mac Local Server}"
CERT_ORGANIZATION="${CERT_ORGANIZATION:-Cam2Mac}"
CERT_PASSWORD="${CERT_PASSWORD:-cam2mac-local-cert}"
CERT_VALID_DAYS="${CERT_VALID_DAYS:-3650}"

CERT_PATH="$RESOURCES_DIR/${CERT_BASENAME}.cer"
P12_PATH="$RESOURCES_DIR/${CERT_BASENAME}.p12"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cam2mac-cert.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

OPENSSL_CONFIG="$WORK_DIR/openssl.cnf"
KEY_PATH="$WORK_DIR/server.key"
PEM_CERT_PATH="$WORK_DIR/server.pem"

cat > "$OPENSSL_CONFIG" <<EOF
[ req ]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_req

[ dn ]
CN = ${CERT_COMMON_NAME}
O = ${CERT_ORGANIZATION}

[ v3_req ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = camera-lan-stream.local
DNS.2 = localhost
IP.1 = 127.0.0.1
EOF

echo "Generating private key and self-signed server certificate..."
openssl req \
  -x509 \
  -nodes \
  -days "$CERT_VALID_DAYS" \
  -newkey rsa:2048 \
  -keyout "$KEY_PATH" \
  -out "$PEM_CERT_PATH" \
  -config "$OPENSSL_CONFIG"

echo "Exporting PKCS#12 identity..."
openssl pkcs12 \
  -export \
  -out "$P12_PATH" \
  -inkey "$KEY_PATH" \
  -in "$PEM_CERT_PATH" \
  -passout "pass:$CERT_PASSWORD"

echo "Writing DER certificate resource..."
openssl x509 \
  -in "$PEM_CERT_PATH" \
  -inform PEM \
  -out "$CERT_PATH" \
  -outform DER

FINGERPRINT="$(openssl x509 -in "$PEM_CERT_PATH" -inform PEM -noout -fingerprint -sha256 | sed 's/^.*=//' | tr '[:upper:]' '[:lower:]' | tr -d ':')"
NOT_AFTER="$(openssl x509 -in "$PEM_CERT_PATH" -inform PEM -noout -enddate | sed 's/^notAfter=//')"

cat <<EOF

Updated transport TLS resources:

- $CERT_PATH
- $P12_PATH

Certificate SHA-256:
$FINGERPRINT

Certificate expiration:
$NOT_AFTER

Next steps:

1. Rebuild the iPhone app.
2. Rebuild the Mac app.
3. Reinstall both so they embed the same Transport resources.
EOF
