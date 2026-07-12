#!/usr/bin/env bash
# Sign a PE file (e.g. viogpudo.sys) with a signingTime attribute set to
# a date before the 2015-07-29 Windows DSE grandfather deadline, using the
# pre-2015 cert chain produced by gen-backdated-ca.sh.
#
# This is the osslsigncode equivalent of the HookSignTool trick: no RFC3161
# countersignature is attached, so Windows falls back to the self-reported
# signingTime attribute when evaluating the grandfather rule.
#
# Usage:  sign-backdated.sh <in.sys> <out.sys>
# Env:
#   PFX_PASSWORD  PFX password (default: stealth)
#   SIGN_TIME     unix timestamp for signingTime attribute
#                 default: 1420070400 (2015-01-01 00:00 UTC) -- well before
#                 the 2015-07-29 deadline, well after the cert NotBefore
#   DESC          description embedded in signature
#   CERTS_DIR     dir containing backdated-signer.pfx and backdated-ca.crt
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <in.sys> <out.sys>" >&2
    exit 1
fi

IN="$1"
OUT="$2"
SIGN_TIME="${SIGN_TIME:-1420070400}"   # 2015-01-01 00:00:00 UTC
PFX_PASSWORD="${PFX_PASSWORD:-stealth}"
DESC="${DESC:-NVIDIA Display Driver}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CERTS_DIR="${CERTS_DIR:-$SCRIPT_DIR/../certs}"

PFX="$CERTS_DIR/backdated-signer.pfx"
CA_CRT="$CERTS_DIR/backdated-ca.crt"

if [[ ! -f "$PFX" || ! -f "$CA_CRT" ]]; then
    echo "ERROR: cert bundle missing in $CERTS_DIR, run gen-backdated-ca.sh first" >&2
    exit 1
fi

if [[ ! -f "$IN" ]]; then
    echo "ERROR: input file not found: $IN" >&2
    exit 1
fi

echo "[sign] input      : $IN ($(stat -c '%s' "$IN") bytes)"
echo "[sign] signingTime: $(date -u -d @$SIGN_TIME '+%Y-%m-%d %H:%M:%S UTC') ($SIGN_TIME)"
echo "[sign] cert chain : $CA_CRT -> signer"

# osslsigncode 2.8 refuses to overwrite an existing output file
if [[ -e "$OUT" ]]; then rm -f "$OUT"; fi

# -h sha256:    Authenticode recommends SHA-256 for driver signatures since 2016
# -ac <ca.crt>: additional cert embedded in the signature block (the CA)
#               so the guest can verify the chain without needing the CA in
#               Root at signtool-time (guest still needs it at load-time)
# -n <desc>:    description string (visible in sigcheck)
# -time <unix>: CRUCIAL — sets signingTime authenticated attribute to this
#               unix timestamp. Without a -t/-ts server, this is what Windows
#               reads for grandfather-rule evaluation.
# -pkcs12 + -pass: PFX + password
TSA_CERT="$CERTS_DIR/backdated-tsa.crt"
TSA_KEY="$CERTS_DIR/backdated-tsa.key"
TSA_ARGS=()
if [[ -f "$TSA_CERT" && -f "$TSA_KEY" ]]; then
    # Use built-in RFC3161 TSA so Windows sees a trusted countersignature
    # at SIGN_TIME (grandfather rule needs this, not just self-reported
    # signingTime). The TSA cert is issued by the same backdated CA we
    # install into LocalMachine\Root, so the timestamp chain validates.
    TSA_ARGS=(-TSA-certs "$TSA_CERT" -TSA-key "$TSA_KEY" -TSA-time "$SIGN_TIME")
    echo "[sign] TSA countersig: $TSA_CERT @ $(date -u -d @$SIGN_TIME '+%Y-%m-%d %H:%M:%S UTC')"
else
    echo "[sign] (no TSA cert — signature will have self-reported signingTime only)"
fi

# faketime forces wall-clock during osslsigncode's internal TSA flow. Without
# this, osslsigncode's -TSA-time is respected for the tstTokenInfo field but
# the embedded PKCS#7 countersignature's signingTime still reads real time.
FAKE_DATE="$(date -u -d @$SIGN_TIME '+%Y-%m-%d %H:%M:%S')"
faketime "$FAKE_DATE" osslsigncode sign \
    -pkcs12 "$PFX" \
    -pass "$PFX_PASSWORD" \
    -ac "$CA_CRT" \
    -h sha256 \
    -n "$DESC" \
    -time "$SIGN_TIME" \
    "${TSA_ARGS[@]}" \
    -in "$IN" \
    -out "$OUT"

echo
echo "[sign] verifying..."
osslsigncode verify -in "$OUT" 2>&1 | grep -E 'Current PE checksum|Calculated PE|Signature|Number|Message digest|Signing time' || true

echo
echo "[sign] done -> $OUT"
