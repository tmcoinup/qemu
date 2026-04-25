#!/usr/bin/env bash
# Generate a self-signed CA + code-signing cert chain with pre-2015-07-29
# validity so drivers signed with a backdated signing time pass Win10/11
# grandfather DSE check on Secure-Boot-off systems.
#
# Output (in $OUT_DIR):
#   backdated-ca.key / .crt     : root CA (NotBefore=2014-01-01)
#   backdated-signer.key / .crt : leaf code-signing cert (NotBefore=2014-06-01)
#   backdated-signer.pfx        : PFX bundle for signtool / osslsigncode
#   backdated-ca.der            : root CA in DER (to import into guest Root store)
#   backdated-signer.der        : leaf in DER (to import into TrustedPublisher)
#
# The certs themselves have pre-2015 NotBefore. The signing time is set
# per-invocation by sign-backdated.sh via osslsigncode -time.
set -euo pipefail

OUT_DIR="${OUT_DIR:-$(dirname "$0")/../certs}"
CA_SUBJ="${CA_SUBJ:-/CN=NVIDIA Code Signing Root/O=NVIDIA Corporation/C=US}"
SIGNER_SUBJ="${SIGNER_SUBJ:-/CN=NVIDIA Driver Signer/O=NVIDIA Corporation/C=US}"
PFX_PASSWORD="${PFX_PASSWORD:-stealth}"

# Pre-2015-07-29 dates (driver grandfather deadline).
# openssl ca/x509 uses `-days` relative to NotBefore we set via faketime.
CA_NOTBEFORE="2014-01-01 00:00:00"
CA_DAYS=5844   # ~16 years; NotAfter ≈ 2029-12-30
SIGNER_NOTBEFORE="2014-06-01 00:00:00"
SIGNER_DAYS=5300  # NotAfter ≈ 2028-11-21 (within CA validity)

mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

# Check for faketime; it's the cleanest way to make openssl emit arbitrary NotBefore.
if ! command -v faketime >/dev/null 2>&1; then
    echo "ERROR: install faketime:  sudo apt install faketime" >&2
    exit 1
fi

# --- Root CA ---------------------------------------------------------
echo "[gen-ca] generating root CA key + self-signed cert"
openssl genrsa -out backdated-ca.key 2048 2>/dev/null

cat >ca-ext.cnf <<'EOF'
basicConstraints = critical, CA:TRUE, pathlen:1
keyUsage         = critical, digitalSignature, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF

faketime "$CA_NOTBEFORE" openssl req -x509 -new -nodes \
    -key backdated-ca.key \
    -days $CA_DAYS \
    -subj "$CA_SUBJ" \
    -sha256 \
    -extensions v3_ca -config <(cat <<CFG
[req]
distinguished_name = dn
x509_extensions    = v3_ca
prompt = no
[dn]
CN = ignored
[v3_ca]
basicConstraints = critical, CA:TRUE, pathlen:1
keyUsage         = critical, digitalSignature, keyCertSign, cRLSign
subjectKeyIdentifier = hash
CFG
) -out backdated-ca.crt

openssl x509 -in backdated-ca.crt -outform DER -out backdated-ca.der

# --- Leaf code-signing cert -----------------------------------------
echo "[gen-ca] generating leaf code-signing key + CSR"
openssl genrsa -out backdated-signer.key 2048 2>/dev/null

faketime "$SIGNER_NOTBEFORE" openssl req -new \
    -key backdated-signer.key \
    -subj "$SIGNER_SUBJ" \
    -out backdated-signer.csr

cat >signer-ext.cnf <<'EOF'
basicConstraints       = critical, CA:FALSE
keyUsage               = critical, digitalSignature
extendedKeyUsage       = critical, codeSigning
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer
EOF

faketime "$SIGNER_NOTBEFORE" openssl x509 -req \
    -in backdated-signer.csr \
    -CA backdated-ca.crt -CAkey backdated-ca.key -CAcreateserial \
    -days $SIGNER_DAYS -sha256 \
    -extfile signer-ext.cnf \
    -out backdated-signer.crt

openssl x509 -in backdated-signer.crt -outform DER -out backdated-signer.der

# --- PFX bundle for signtool -----------------------------------------
openssl pkcs12 -export \
    -out backdated-signer.pfx \
    -inkey backdated-signer.key \
    -in backdated-signer.crt \
    -certfile backdated-ca.crt \
    -name "NVIDIA Driver Signer" \
    -passout "pass:$PFX_PASSWORD"

rm -f ca-ext.cnf signer-ext.cnf backdated-signer.csr backdated-ca.srl

echo
echo "[gen-ca] done. generated in $OUT_DIR:"
ls -la "$OUT_DIR"
echo
echo "[gen-ca] verify CA NotBefore:"
openssl x509 -in backdated-ca.crt -noout -dates -subject
echo
echo "[gen-ca] verify signer NotBefore:"
openssl x509 -in backdated-signer.crt -noout -dates -subject -issuer
