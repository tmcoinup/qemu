#!/usr/bin/env bash
# Standard run-g11.sh entry point for the Python NV_Modes policy regression.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1
exec python3 "$script_dir/test_nvidia_modes.py"
