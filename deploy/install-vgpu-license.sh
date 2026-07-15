#!/usr/bin/env bash
#
# Install a DLS client configuration token inside a Windows vGPU guest over
# WinRM, restart the NVIDIA licensing service, and fail unless the guest is
# both Licensed and healthy.
#
# Examples:
#   ./deploy/install-vgpu-license.sh 2 --license-url https://dls.example/-/client-token
#   ./deploy/install-vgpu-license.sh 2 --token-file /secure/client_configuration_token.tok
#   ./deploy/install-vgpu-license.sh 2 --insecure-tls  # local self-signed DLS only
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=lib/vm-storage.sh
source ./lib/vm-storage.sh
vm_storage_init

usage() {
    cat <<'EOF'
Usage: install-vgpu-license.sh [vm_id] [options]

Options:
  --ip ADDRESS             Guest IPv4 address (otherwise resolve VM_MAC on br0)
  --license-url URL        Full client-token URL; also VGPU_LICENSE_URL
  --token-file FILE        Copy an existing .tok over WinRM; guest makes no HTTP download
  --insecure-tls           Accept an untrusted/self-signed DLS certificate
  --allow-http             Allow a plain HTTP token URL (isolated network only)
  --guest-user USER        WinRM administrator (default: Administrator)
  --password-stdin         Read the WinRM password from one line on stdin
  --min-token-bytes N      Reject smaller downloads (default: 1024)
  --wait-seconds N         Wait for Licensed state (default: 45)
  -h, --help               Show this help

The password is never accepted as a command-line argument. If GUEST_PASS is
unset, an interactive terminal is prompted without echo. WinRM HTTP/NTLM must
already be enabled in the trusted guest network.

TLS certificate verification is enabled by default. Use --insecure-tls only
for the local lab server with a self-signed certificate.

--license-url and --token-file are mutually exclusive. A transferred token
still contains the DLS endpoint, so the guest must be able to reach that
endpoint after installation.
EOF
}

die() {
    echo "[license] ERROR: $*" >&2
    exit 1
}

VM_ID=${VM_ID:-1}
IP_OVERRIDE=""
GUEST_USER=${GUEST_USER:-Administrator}
LICENSE_URL=${VGPU_LICENSE_URL:-}
TOKEN_FILE=${VGPU_LICENSE_TOKEN_FILE:-}
INSECURE_TLS=${VGPU_LICENSE_INSECURE_TLS:-0}
ALLOW_HTTP=${VGPU_LICENSE_ALLOW_HTTP:-0}
MIN_TOKEN_BYTES=${VGPU_LICENSE_MIN_TOKEN_BYTES:-1024}
WAIT_SECONDS=${VGPU_LICENSE_WAIT_SECONDS:-45}
PASSWORD_STDIN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)
            [[ $# -ge 2 ]] || die "--ip requires a value"
            IP_OVERRIDE=$2
            shift 2
            ;;
        --license-url|--url)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            LICENSE_URL=$2
            shift 2
            ;;
        --token-file)
            [[ $# -ge 2 ]] || die "--token-file requires a value"
            TOKEN_FILE=$2
            shift 2
            ;;
        --insecure-tls)
            INSECURE_TLS=1
            shift
            ;;
        --allow-http)
            ALLOW_HTTP=1
            shift
            ;;
        --guest-user)
            [[ $# -ge 2 ]] || die "--guest-user requires a value"
            GUEST_USER=$2
            shift 2
            ;;
        --password-stdin)
            PASSWORD_STDIN=1
            shift
            ;;
        --min-token-bytes)
            [[ $# -ge 2 ]] || die "--min-token-bytes requires a value"
            MIN_TOKEN_BYTES=$2
            shift 2
            ;;
        --wait-seconds)
            [[ $# -ge 2 ]] || die "--wait-seconds requires a value"
            WAIT_SECONDS=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *.*.*.*)
            IP_OVERRIDE=$1
            shift
            ;;
        [0-9]*)
            VM_ID=$1
            shift
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

[[ "$VM_ID" =~ ^[0-9]+$ ]] || die "invalid VM id: $VM_ID"
[[ "$MIN_TOKEN_BYTES" =~ ^[0-9]+$ ]] || die "invalid --min-token-bytes: $MIN_TOKEN_BYTES"
[[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]] || die "invalid --wait-seconds: $WAIT_SECONDS"
(( MIN_TOKEN_BYTES >= 256 && MIN_TOKEN_BYTES <= 1048576 )) \
    || die "--min-token-bytes must be between 256 and 1048576"
(( WAIT_SECONDS >= 5 && WAIT_SECONDS <= 300 )) \
    || die "--wait-seconds must be between 5 and 300"

if [[ -z "$IP_OVERRIDE" ]]; then
    conf=$(vm_storage_config_path "$VM_ID")
    [[ -f "$conf" ]] || die "missing VM configuration: $conf"
    # shellcheck source=/dev/null
    source "$conf"
    [[ -n "${VM_MAC:-}" ]] || die "VM_MAC is missing from $conf"
    mac_lc=${VM_MAC,,}
    IP=$(ip -4 neigh show 2>/dev/null | awk -v m="$mac_lc" \
        '$3=="br0" && tolower($5)==m && $1 ~ /^[0-9]/ {print $1; exit}')
    [[ -n "$IP" ]] || die "no br0 neighbor entry for VM MAC $VM_MAC; pass --ip"
else
    IP=$IP_OVERRIDE
fi

case "$INSECURE_TLS" in 0|1) ;; *) die "VGPU_LICENSE_INSECURE_TLS must be 0 or 1" ;; esac
case "$ALLOW_HTTP" in 0|1) ;; *) die "VGPU_LICENSE_ALLOW_HTTP must be 0 or 1" ;; esac

[[ -z "$TOKEN_FILE" || -z "$LICENSE_URL" ]] \
    || die "--token-file and --license-url/VGPU_LICENSE_URL are mutually exclusive"

if [[ -n "$TOKEN_FILE" ]]; then
    [[ "$INSECURE_TLS" == 0 && "$ALLOW_HTTP" == 0 ]] \
        || die "--insecure-tls/--allow-http apply only to --license-url"
    command -v realpath >/dev/null 2>&1 || die "realpath is required for --token-file"
    command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required for --token-file"
    TOKEN_FILE=$(realpath -e -- "$TOKEN_FILE") \
        || die "token file does not exist: $TOKEN_FILE"
    [[ -f "$TOKEN_FILE" && -r "$TOKEN_FILE" ]] \
        || die "token file is not a readable regular file: $TOKEN_FILE"
    TOKEN_BYTES=$(stat -c %s -- "$TOKEN_FILE") \
        || die "cannot read token size: $TOKEN_FILE"
    (( TOKEN_BYTES >= MIN_TOKEN_BYTES && TOKEN_BYTES <= 1048576 )) \
        || die "token size is outside ${MIN_TOKEN_BYTES}..1048576 bytes: $TOKEN_BYTES"
    if LC_ALL=C head -c 256 -- "$TOKEN_FILE" | grep -Eiq '<[[:space:]]*(!doctype[[:space:]]+html|html)'; then
        die "token file looks like HTML: $TOKEN_FILE"
    fi
    TOKEN_SHA256=$(sha256sum -- "$TOKEN_FILE" | awk '{print toupper($1)}')
    SOURCE_MODE=file
    SOURCE_VALUE=$TOKEN_FILE
else
    if [[ -z "$LICENSE_URL" ]]; then
        HOST_IP=$(ip -4 -o addr show br0 2>/dev/null \
            | awk 'NR == 1 {sub(/\/.*/, "", $4); print $4}')
        if [[ -z "$HOST_IP" ]]; then
            HOST_IP=$(ip -4 route get "$IP" 2>/dev/null \
                | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')
        fi
        [[ -n "$HOST_IP" ]] \
            || die "cannot infer the DLS address; pass --license-url or --token-file"
        LICENSE_URL="https://${HOST_IP}/-/client-token"
    fi
    case "$LICENSE_URL" in
        https://*) ;;
        http://*)
            [[ "$ALLOW_HTTP" == 1 ]] \
                || die "plain HTTP is refused; pass --allow-http only on an isolated trusted network"
            ;;
        *) die "--license-url must be an absolute HTTP(S) URL" ;;
    esac
    TOKEN_SHA256=''
    SOURCE_MODE=url
    SOURCE_VALUE=$LICENSE_URL
fi

if (( PASSWORD_STDIN )); then
    IFS= read -r GUEST_PASS || die "could not read the guest password from stdin"
elif [[ -z "${GUEST_PASS:-}" ]]; then
    if [[ -t 0 ]]; then
        read -r -s -p "WinRM password for ${GUEST_USER}@${IP}: " GUEST_PASS
        echo
    else
        die "GUEST_PASS is unset; export it or use --password-stdin"
    fi
fi
[[ -n "$GUEST_PASS" ]] || die "guest password is empty"

command -v python3 >/dev/null 2>&1 || die "python3 is required"
python3 -c 'import pypsrp' >/dev/null 2>&1 \
    || die "Python package pypsrp is required for WinRM transport"

GUEST_SCRIPT="$SCRIPT_DIR/guest/install-vgpu-license.ps1"
[[ -s "$GUEST_SCRIPT" ]] || die "missing guest activation script: $GUEST_SCRIPT"

if [[ "$SOURCE_MODE" == file ]]; then
    echo "[license] guest=${GUEST_USER}@${IP} token_file=${SOURCE_VALUE} bytes=${TOKEN_BYTES} sha256=${TOKEN_SHA256}"
else
    echo "[license] guest=${GUEST_USER}@${IP} token_url=${SOURCE_VALUE}"
fi
if [[ "$SOURCE_MODE" == url && "$INSECURE_TLS" == 1 ]]; then
    echo "[license] WARNING: TLS certificate verification is disabled for this run" >&2
fi

env -u GUEST_PASS python3 - "$IP" "$GUEST_USER" "$SOURCE_MODE" "$SOURCE_VALUE" \
    "$TOKEN_SHA256" "$INSECURE_TLS" "$ALLOW_HTTP" "$MIN_TOKEN_BYTES" \
    "$WAIT_SECONDS" "$GUEST_SCRIPT" 3<<<"$GUEST_PASS" <<'PYEOF'
import pathlib
import sys
import uuid

from pypsrp.client import Client

(
    ip,
    user,
    source_mode,
    source_value,
    token_sha256,
    insecure_tls,
    allow_http,
    minimum_bytes,
    wait_seconds,
    script_path,
) = sys.argv[1:11]
password = None
with open(3, "r", encoding="utf-8") as password_stream:
    password = password_stream.read()
if password.endswith("\n"):
    password = password[:-1]


def ps_literal(value):
    return "'" + value.replace("'", "''") + "'"


guest_script = pathlib.Path(script_path).read_text(encoding="utf-8-sig")
remote_token = None

try:
    client = Client(ip, username=user, password=password, ssl=False, auth="ntlm")
    arguments = [
        "-MinimumTokenBytes", str(int(minimum_bytes)),
        "-WaitSeconds", str(int(wait_seconds)),
    ]
    if source_mode == "file":
        remote_token = (
            r"C:\Windows\Temp\qemu-vgpu-license-"
            + uuid.uuid4().hex
            + ".tok"
        )
        remote_token = client.copy(source_value, remote_token)
        arguments[0:0] = [
            "-TokenFile", ps_literal(remote_token),
            "-ExpectedTokenSha256", ps_literal(token_sha256),
        ]
    elif source_mode == "url":
        arguments[0:0] = ["-LicenseUrl", ps_literal(source_value)]
        if insecure_tls == "1":
            arguments.append("-InsecureTls")
        if allow_http == "1":
            arguments.append("-AllowHttp")
    else:
        raise ValueError(f"unsupported token source mode: {source_mode}")

    payload = "& {\n" + guest_script + "\n} " + " ".join(arguments)
    output, streams, had_errors = client.execute_ps(payload)
except Exception as exc:
    print(f"[license] WinRM execution failed: {exc}", file=sys.stderr)
    raise SystemExit(1)
finally:
    if remote_token is not None:
        try:
            client.execute_ps(
                "Remove-Item -LiteralPath "
                + ps_literal(remote_token)
                + " -Force -ErrorAction SilentlyContinue"
            )
        except Exception as cleanup_exc:
            print(
                f"[license] warning: could not remove guest temporary token: {cleanup_exc}",
                file=sys.stderr,
            )
    password = None

if output:
    print(output, end="" if output.endswith("\n") else "\n")
errors = list(streams.error or [])
for error in errors:
    print(f"[license] guest error: {error}", file=sys.stderr)
if had_errors or errors:
    raise SystemExit(1)
PYEOF

unset GUEST_PASS
echo "[license] PASS: guest reports service=Running, license=Licensed, GPU code=0"
