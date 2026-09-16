#!/usr/bin/env bash
set -euo pipefail
deploy="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec pwsh -NoLogo -NoProfile -NonInteractive -File \
    "$deploy/tests/guest/system_nvapi_gpu_update.tests.ps1" -DeployRoot "$deploy"
