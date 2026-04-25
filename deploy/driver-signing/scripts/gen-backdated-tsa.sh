#!/usr/bin/env bash
# Generate a TSA (timestamp authority) cert under the same backdated root CA.
# osslsigncode can use this as a built-in TSA to emit a self-countersigned
# RFC3161 timestamp at any unix time — including pre-2015-07-29 for the
# Windows DSE grandfather rule.
set -euo pipefail

OUT_DIR="${OUT_DIR:-$(dirname "$0")/../certs}"
TSA_SUBJ="${TSA_SUBJ:-/CN=NVIDIA Timestamping CA 2014/O=NVIDIA Corporation/C=US}"
TSA_NOTBEFORE="2014-03-01 00:00:00"
TSA_DAYS=5400
mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

if [[ ! -f backdated-ca.key ]]; then
    echo "ERROR: missing backdated-ca.key; run gen-backdated-ca.sh first" >&2
    exit 1
fi

echo "[gen-tsa] generating TSA leaf cert under our backdated CA"
openssl genrsa -out backdated-tsa.key 2048 2>/dev/null

faketime "$TSA_NOTBEFORE" openssl req -new \
    -key backdated-tsa.key \
    -subj "$TSA_SUBJ" \
    -out backdated-tsa.csr

cat >tsa-ext.cnf <<'EOF'
basicConstraints       = critical, CA:FALSE
keyUsage               = critical, digitalSignature, nonRepudiation
extendedKeyUsage       = critical, timeStamping
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer
EOF

faketime "$TSA_NOTBEFORE" openssl x509 -req \
    -in backdated-tsa.csr \
    -CA backdated-ca.crt -CAkey backdated-ca.key -CAcreateserial \
    -days $TSA_DAYS -sha256 \
    -extfile tsa-ext.cnf \
    -out backdated-tsa.crt

rm -f backdated-tsa.csr tsa-ext.cnf backdated-ca.srl

echo "[gen-tsa] done."
openssl x509 -in backdated-tsa.crt -noout -dates -subject -ext extendedKeyUsage
