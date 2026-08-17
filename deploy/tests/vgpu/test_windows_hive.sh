#!/usr/bin/env bash
# Standard run-g11.sh entry point for Windows primary-hive validation tests.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1
exec python3 "$script_dir/test_windows_hive.py"
