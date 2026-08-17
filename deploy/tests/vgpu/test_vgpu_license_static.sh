#!/usr/bin/env bash
# Static safety contract for the host wrapper and guest activation script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HOST_SCRIPT="$REPO_ROOT/deploy/install-vgpu-license.sh"
GUEST_SCRIPT="$REPO_ROOT/deploy/guest/install-vgpu-license.ps1"
RTC_SCRIPT="$REPO_ROOT/deploy/guest/fix-rtc-utc.ps1"
DOC="$REPO_ROOT/deploy/docs/VGPU-LICENSING.md"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

bash -n "$HOST_SCRIPT" || fail "host wrapper is not valid Bash"
[[ -s "$GUEST_SCRIPT" ]] || fail "guest activation script is missing"
[[ -s "$RTC_SCRIPT" ]] || fail "guest RTC diagnostic script is missing"
[[ -s "$DOC" ]] || fail "licensing runbook is missing"

if grep -Eq 'GUEST_PASS=\$\{GUEST_PASS:-[^}]+' "$HOST_SCRIPT"; then
    fail "host wrapper contains a default guest password"
fi
if grep -Fq '123456' "$HOST_SCRIPT" "$GUEST_SCRIPT" "$DOC"; then
    fail "licensing files contain a hard-coded lab password"
fi
if grep -Fq 'http://192.168.' "$HOST_SCRIPT" "$GUEST_SCRIPT"; then
    fail "licensing scripts contain a fixed private-network URL"
fi

grep -Fq -- '--license-url' "$HOST_SCRIPT" \
    || fail "host wrapper has no configurable license URL"
grep -Fq -- '--token-file' "$HOST_SCRIPT" \
    || fail "host wrapper has no local token-file mode"
grep -Fq 'client.copy(source_value, remote_token)' "$HOST_SCRIPT" \
    || fail "host wrapper does not transfer a local token over WinRM"
grep -Fq 'SOURCE_MODE=file' "$HOST_SCRIPT" \
    || fail "host wrapper does not distinguish local token transfer"
grep -Fq -- '--password-stdin' "$HOST_SCRIPT" \
    || fail "host wrapper has no non-command-line password input"
grep -Fq "3<<<\"\$GUEST_PASS\"" "$HOST_SCRIPT" \
    || fail "host wrapper does not pass the password through a private file descriptor"
grep -Fq "if had_errors or errors:" "$HOST_SCRIPT" \
    || fail "WinRM errors are not fail-closed"

grep -Fq "\$ErrorActionPreference = 'Stop'" "$GUEST_SCRIPT" \
    || fail "guest errors are not terminating"
grep -Fq "ParameterSetName = 'File'" "$GUEST_SCRIPT" \
    || fail "guest script has no mutually exclusive local token mode"
grep -Fq '$ExpectedTokenSha256' "$GUEST_SCRIPT" \
    || fail "guest script does not verify a transferred token hash"
grep -Fq 'Copy-Item -LiteralPath $sourceTokenPath' "$GUEST_SCRIPT" \
    || fail "guest script does not consume the transferred token file"
grep -Fq 'no HTTP download was used' "$GUEST_SCRIPT" \
    || fail "guest script does not identify the HTTP-free token path"
grep -Fq '[IO.File]::Replace' "$GUEST_SCRIPT" \
    || fail "token replacement is not atomic"
grep -Fq 'rollback' "$GUEST_SCRIPT" \
    || fail "guest script has no rollback path"
grep -Fq 'MinimumTokenBytes' "$GUEST_SCRIPT" \
    || fail "guest script does not validate token size"
grep -Fq 'License Status\s*:\s*Licensed(?:\s+\([^\r\n]*\))?' "$GUEST_SCRIPT" \
    || fail "guest script does not strictly verify Licensed state"
grep -Fq 'env -u GUEST_PASS python3' "$HOST_SCRIPT" \
    || fail "host wrapper leaks an exported guest password into the WinRM helper environment"
grep -Fq 'ConfigManagerErrorCode' "$GUEST_SCRIPT" \
    || fail "guest script does not verify Device Manager health"
grep -Fq 'NVDisplay.ContainerLocalSystem' "$GUEST_SCRIPT" \
    || fail "guest script does not manage the NVIDIA licensing service"
grep -Fq 'Wait-LicenseServiceStatus' "$GUEST_SCRIPT" \
    || fail "guest script does not bound NVIDIA service state transitions"
grep -Fq "[ValidateSet('start', 'stop')]" "$GUEST_SCRIPT" \
    || fail "guest script does not use explicit bounded service controls"
grep -Fq "System32\\sc.exe" "$GUEST_SCRIPT" \
    || fail "guest script does not use the Windows service controller"
if grep -Fq 'Restart-Service -Name $serviceName' "$GUEST_SCRIPT"; then
    fail "guest script still uses the potentially unbounded Restart-Service path"
fi
grep -Fq 'Assert-LocalRtcContract' "$GUEST_SCRIPT" \
    || fail "guest script does not enforce the host-owned local RTC contract"
grep -Fq 'RealTimeIsUniversal must be absent or DWORD 0' "$GUEST_SCRIPT" \
    || fail "guest script does not reject the obsolete UTC RTC registry contract"
grep -Fq -- '-rtc base=localtime,clock=host,driftfix=slew' "$GUEST_SCRIPT" \
    || fail "guest script does not identify the required host RTC arguments"
grep -Fq 'TZ=Asia/Shanghai' "$GUEST_SCRIPT" \
    || fail "guest script does not identify the required host timezone"
grep -Fq 'China Standard Time' "$GUEST_SCRIPT" \
    || fail "guest script does not enforce the project timezone"
if grep -Eq 'New-ItemProperty|Set-ItemProperty|Remove-ItemProperty|Set-TimeZone|Set-Date|/resync|/config' "$GUEST_SCRIPT"; then
    fail "guest license installer contains a registry, timezone, clock, or time-service mutator"
fi
grep -Fq -- '--dump-header' "$GUEST_SCRIPT" \
    || fail "guest script does not compare its clock with the token server"
grep -Fq -- '--proto-redir' "$GUEST_SCRIPT" \
    || fail "guest script does not constrain redirect protocols"
grep -Fq 'Clock windback has been detected' "$GUEST_SCRIPT" \
    || fail "guest script has no actionable clock-windback diagnosis"
grep -Fq 'FileShare]::None' "$GUEST_SCRIPT" \
    || fail "guest script does not serialize token-directory transactions"
grep -Fq -- "-Filter '.client_configuration_token*.rollback'" "$GUEST_SCRIPT" \
    || fail "guest script does not preserve an interrupted transaction rollback"
grep -Fq -- "-Filter '*.tok'" "$GUEST_SCRIPT" \
    || fail "guest script does not reject multiple client tokens"
grep -Fq 'ServerAddress' "$GUEST_SCRIPT" \
    || fail "guest script does not reject legacy license-server settings"

grep -Fq 'deprecated and performs read-only diagnostics' "$RTC_SCRIPT" \
    || fail "legacy RTC script is not clearly marked as a read-only diagnostic"
grep -Fq "'China Standard Time'" "$RTC_SCRIPT" \
    || fail "RTC diagnostic does not verify the Windows timezone"
grep -Fq 'RealTimeIsUniversal must be absent or DWORD 0' "$RTC_SCRIPT" \
    || fail "RTC diagnostic does not verify the local RTC registry contract"
grep -Fq 'TZ=Asia/Shanghai' "$RTC_SCRIPT" \
    || fail "RTC diagnostic does not show the required host timezone"
grep -Fq -- '-rtc base=localtime,clock=host,driftfix=slew' "$RTC_SCRIPT" \
    || fail "RTC diagnostic does not show the required QEMU arguments"
grep -Fq 'fully shut down Windows' "$RTC_SCRIPT" \
    || fail "RTC diagnostic does not require a new QEMU cold boot after manual correction"
if grep -Eq 'New-ItemProperty|Set-ItemProperty|Remove-ItemProperty|Set-TimeZone|Set-Date|/resync|/config' "$RTC_SCRIPT"; then
    fail "RTC diagnostic contains a registry, timezone, clock, or time-service mutator"
fi
if grep -Eq '&[[:space:]]+\$tzutil[[:space:]]+/s([[:space:]]|$)' "$RTC_SCRIPT"; then
    fail "RTC diagnostic attempts to set the Windows timezone"
fi

echo "PASS: vGPU license install safety contract"
