#!/usr/bin/env bash
# Static/configuration smoke test; never starts or changes a Docker container.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
SOURCE_DIR="$REPO_ROOT/deploy/host/fastapi-dls"
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

cp -a "$SOURCE_DIR/." "$TMP_DIR/"
(
    cd "$TMP_DIR"
    ./dlsctl.sh configure 192.0.2.25 54443 54443 >/dev/null
)

[[ $(stat -c '%a' "$TMP_DIR/.env") == 600 ]] || fail '.env mode is not 0600'
openssl x509 -in "$TMP_DIR/state/cert/webserver.crt" -noout \
    -checkip 192.0.2.25 2>/dev/null | grep -Fq 'does match certificate' \
    || fail 'generated certificate has no matching IP SAN'

docker compose --env-file "$TMP_DIR/.env" -f "$TMP_DIR/compose.yaml" \
    config >"$TMP_DIR/rendered.yaml"
grep -Fq 'DLS_URL: 192.0.2.25' "$TMP_DIR/rendered.yaml" \
    || fail 'rendered Compose does not contain DLS_URL'
grep -Fq 'DLS_PORT: "54443"' "$TMP_DIR/rendered.yaml" \
    || fail 'rendered Compose does not contain the public port'
grep -Fq 'published: "54443"' "$TMP_DIR/rendered.yaml" && \
    grep -Fq 'target: 443' "$TMP_DIR/rendered.yaml" \
    || fail 'rendered Compose does not publish the requested host port'
if grep -Eq '(^|[[:space:]])DEBUG:' "$TMP_DIR/rendered.yaml"; then
    fail 'Compose must omit DEBUG for fastapi-dls 2.0.3'
fi

(
    cd "$TMP_DIR"
    ./dlsctl.sh configure dls-new.example.test 443 54443 >/dev/null
)
openssl x509 -in "$TMP_DIR/state/cert/webserver.crt" -noout \
    -checkhost dls-new.example.test 2>/dev/null | grep -Fq 'does match certificate' \
    || fail 'address change did not regenerate a matching DNS SAN'

if (cd "$TMP_DIR" && ./dlsctl.sh configure 'https://bad.example' >/dev/null 2>&1); then
    fail 'configure accepted a URL instead of an address'
fi

echo 'PASS: fastapi-dls Compose configuration contract'
