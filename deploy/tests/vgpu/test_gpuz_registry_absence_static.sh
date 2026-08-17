#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
guest="$root/deploy/guest/apply-gpuz-profile.ps1"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

backup_function=$(sed -n \
    '/^function New-GuestBackup {/,/^function Invoke-ProfilePatch {/p' \
    "$guest")
registry_probe=$(sed -n \
    '/^function Test-HklmRegistrySubKeyExists {/,/^function New-GuestBackup {/p' \
    "$guest")

[[ -n "$backup_function" && -n "$registry_probe" ]] ||
    fail 'could not locate the registry backup/probe functions'

if grep -Eq '&[[:space:]]+\$SystemReg[[:space:]]+query' \
        <<<"$backup_function"; then
    fail 'optional NVAPI backup still probes a missing key through reg.exe'
fi

for required in \
        '[Microsoft.Win32.RegistryKey]::OpenBaseKey(' \
        '[Microsoft.Win32.RegistryHive]::LocalMachine' \
        '[Microsoft.Win32.RegistryView]::Registry64' \
        '$baseKey.OpenSubKey($SubKey, $false)' \
        '$key.Dispose()' \
        '$baseKey.Dispose()'; do
    grep -Fq -- "$required" <<<"$registry_probe" ||
        fail "managed read-only registry probe is missing: $required"
done

for required in \
        "\$nvapiSubKey = 'SOFTWARE\NVIDIA Corporation\Global\NvAPI'" \
        'if (Test-HklmRegistrySubKeyExists $nvapiSubKey)' \
        '& $SystemReg export ("HKLM\{0}" -f $nvapiSubKey)' \
        "(Join-Path \$root 'nvapi-before.absent.txt')"; do
    grep -Fq -- "$required" <<<"$backup_function" ||
        fail "NVAPI backup absence contract is missing: $required"
done

echo 'PASS: a fresh Windows guest can record an absent NVAPI key without a native-command failure'
