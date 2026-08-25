#!/usr/bin/env bash
# 同口径比较 GPU-P 功能和虚拟化痕迹，防止只看单一阳性数。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GPUP="$REPO_ROOT/deploy/windows/gpup"
DETECT="$GPUP/Detect-VGpuP.ps1"
MODULE="$GPUP/VMate.GpuP.DetectionParity.ps1"
WRAPPER="$GPUP/Compare-VMateGpuPDetection.ps1"

fail() { echo "FAIL: $*" >&2; exit 1; }
require_text() {
    rg -F --quiet -- "$1" "$2" || fail "missing '$1' in $2"
}

for file in "$DETECT" "$MODULE" "$WRAPPER"; do
    [[ -f "$file" ]] || fail "missing $file"
    [[ "$(od -An -tx1 -N3 "$file" | tr -d ' \n')" == efbbbf ]] || \
        fail "$file lacks UTF-8 BOM"
    (( $(wc -l < "$file") <= 500 )) || fail "$file exceeds 500 lines"
done

require_text 'FunctionalGpuPSignalCount' "$DETECT"
require_text 'IntrinsicGpuPSignalCount' "$DETECT"
require_text 'HypervisorExposureSignalCount' "$DETECT"
require_text 'ArtifactExposureSignalCount' "$DETECT"
require_text '[string]$OutputPath' "$DETECT"
require_text '[IO.File]::WriteAllText' "$DETECT"
require_text 'function Compare-VMateGpuPDetection' "$MODULE"
require_text "@('GpuPDetector', 'Detector')" "$MODULE"
require_text 'FunctionalParity' "$MODULE"
require_text 'ConcealmentParity' "$MODULE"
require_text 'OverallParity' "$MODULE"
require_text 'function-at-least-reference-and-artifacts-no-more-than-reference' "$MODULE"
require_text 'exit 2' "$WRAPPER"

powershell_bin="$(command -v pwsh || command -v powershell || true)"
if [[ -n "$powershell_bin" ]]; then
    VMATE_PARITY_MODULE="$MODULE" \
        "$powershell_bin" -NoLogo -NoProfile -NonInteractive -Command '
        $ErrorActionPreference = "Stop"
        . $env:VMATE_PARITY_MODULE
        $reference = [pscustomobject]@{
            Verdict = "GPU-P"; GpuPSignalCount = 2
            Signals = @(
                [pscustomobject]@{ Layer="Display"; Hit=$true },
                [pscustomobject]@{ Layer="D3DKMT"; Hit=$true })
        }
        $candidate = [pscustomobject]@{
            Verdict = "GPU-P"; FunctionalGpuPSignalCount = 2
            IntrinsicGpuPSignalCount = 1
            HypervisorExposureSignalCount = 3
            DisplayExposureSignalCount = 1
            ArtifactExposureSignalCount = 4
        }
        $worse = Compare-VMateGpuPDetection $reference $candidate
        if (-not $worse.FunctionalParity -or $worse.ConcealmentParity -or
            $worse.OverallParity -or $worse.Delta.ArtifactExposureSignalCount -ne 3) {
            throw "functional/concealment split is invalid"
        }
        $candidate.ArtifactExposureSignalCount = 1
        $candidate.HypervisorExposureSignalCount = 0
        $equal = Compare-VMateGpuPDetection $reference $candidate
        if (-not $equal.OverallParity) { throw "equal-or-better candidate failed" }
    '
else
    echo 'SKIP: PowerShell not found; detection parity static contract passed'
fi

echo 'PASS: Windows GPU-P detection parity contract'
