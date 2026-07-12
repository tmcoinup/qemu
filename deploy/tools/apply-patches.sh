#!/bin/bash
# apply-patches.sh - apply all deploy/patches/*.patch on top of a clean
# QEMU 9.2.0 tree, then configure+build.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

cd "$REPO_ROOT"

# Apply individually so a partial failure is localized.
# Idempotent: if a patch is already applied (reverse-check passes), skip it.
for p in "$HERE"/../patches/000*-*.patch; do
    name="$(basename "$p")"
    if git apply --check --reverse "$p" 2>/dev/null; then
        echo ">> skip    $name  (already applied)"
        continue
    fi
    if ! git apply --check "$p" 2>/dev/null; then
        echo "FAIL: $name neither applies forward nor reverses cleanly."
        echo "      Tree is in an inconsistent state. Reset with:"
        echo "        git checkout v9.2.0 -- <the files listed in the patch>"
        exit 1
    fi
    echo ">> apply   $name"
    git apply "$p"
done

# Hand off to the dedicated build script so all configure/ninja logic lives
# in one place (deploy/tools/build.sh). Pass through any extra args.
exec "$HERE/build.sh" "$@"
