#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
packager="$root/deploy/package-guest-performance.sh"
wrapper="$root/deploy/scripts/guest-performance.sh"
guest="$root/deploy/guest/guest-performance/Optimize-Guest.ps1"

fail() { echo "FAIL: $*" >&2; exit 1; }
for dependency in xorriso sha256sum mktemp rg; do
    command -v "$dependency" >/dev/null 2>&1 || fail "missing dependency: $dependency"
done

bash -n "$packager"
bash -n "$wrapper"

tmp=$(mktemp -d)
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT INT TERM
output="$tmp/output"
iso=$("$packager" --output-root "$output" --print-path)
[[ "$iso" == "$output"/G11GuestPerformance-*.iso && -s "$iso" && ! -L "$iso" ]] \
    || fail 'packager did not publish a safe content-addressed ISO'
[[ "$("$packager" --output-root "$output" --print-path)" == "$iso" ]] \
    || fail 'identical content was not reused'

listing=$(xorriso -indev "$iso" -find / -type f -exec echo 2>/dev/null)
for expected in Optimize-Guest.ps1 01-Audit.cmd 02-Apply-Recommended.cmd \
        03-Verify.cmd 04-Rollback.cmd README.txt SHA256SUMS.txt; do
    rg -Fq "/$expected" <<<"$listing" || fail "ISO omitted $expected"
done

extracted="$tmp/extracted"
mkdir -p "$extracted"
xorriso -osirrox on -indev "$iso" -extract / "$extracted" >/dev/null 2>&1
(
    cd "$extracted"
    sha256sum -c SHA256SUMS.txt >/dev/null
) || fail 'ISO payload checksum validation failed'

# cmd launchers are deliberately published with CRLF for cmd.exe.
for launcher in "$extracted"/*.cmd; do
    LC_ALL=C rg -q $'\r$' "$launcher" || fail "launcher is not CRLF: $launcher"
done

for required in \
        "StartupDelayInMSec" \
        "NvDisplayContainer" \
        "AudioDeviceGraphHost" \
        "HideRdpIdd" \
        "PurgeRdpGhosts" \
        "StealthMonitor-Refresh" \
        "NVDisplay.ContainerLocalSystem" \
        "VIDEOIDLE" \
        "STANDBYIDLE" \
        "PowerSettings" \
        "Could not apply registry target" \
        "rollback also failed" \
        "Invoke-RollbackInternal"; do
    rg -Fq "$required" "$guest" || fail "guest script omitted: $required"
done

rg -Fq 'if (-not (Test-Path -LiteralPath $Entry.Path -PathType Container))' \
    "$guest" || fail 'registry apply still recreates existing hardened keys'

if rg -n -i \
        'bcdedit\.exe|pnputil\.exe|Disable-PnpDevice|Unregister-ScheduledTask|sc\.exe[[:space:]]+delete|Set-MpPreference|nointegritychecks[[:space:]]+on|testsigning[[:space:]]+on' \
        "$guest"; then
    fail 'guest optimizer contains a prohibited destructive/signing operation'
fi
if rg -n 'Stop-Service.+NVDisplay\.ContainerLocalSystem|Set-Service.+NVDisplay\.ContainerLocalSystem' \
        "$guest"; then
    fail 'guest optimizer attempts to modify the official NVIDIA service'
fi

echo 'PASS: G-11 guest performance package'
