#!/usr/bin/env bash
# Immutable host-side GPU-Z asset contract shared by the package builders.
#
# Callers must copy the selected source into a private work directory with
# gpuz_asset_snapshot before trusting its bytes.  Validation is intentionally
# performed on that private snapshot, so a mutable candidate path cannot cause
# the manifest and embedded PE resource to describe different generations.

readonly GPUZ_ASSET_BUNDLE_NAME='GPU-Z.exe'
readonly GPUZ_ASSET_SOURCE_RELATIVE='candidates/gpuz-2.70-audit/GPU-Z.2.70.0.exe'
readonly GPUZ_ASSET_BYTES=11642144
readonly GPUZ_ASSET_PRODUCT_VERSION='2.70.0'
readonly GPUZ_ASSET_SHA256='6CB0EF29682452DE81A9576808881685161411A1FAD00938BA04131159979C29'

gpuz_asset_default_source() {
    [[ -n "${IMAGE_ROOT:-}" ]] || {
        echo '[gpuz-assets] ERROR: IMAGE_ROOT is not initialized' >&2
        return 1
    }
    printf '%s/%s\n' "$IMAGE_ROOT" "$GPUZ_ASSET_SOURCE_RELATIVE"
}

gpuz_asset_resolve_source() {
    local source=${1:-} resolved

    [[ -n "$source" && "$source" == /* &&
       "$source" != *$'\n'* && "$source" != *$'\r'* ]] || {
        echo '[gpuz-assets] ERROR: GPU-Z source must be an absolute host path without newlines' >&2
        return 1
    }
    [[ -f "$source" && ! -L "$source" && -r "$source" ]] || {
        echo "[gpuz-assets] ERROR: GPU-Z source is not a readable regular non-symlink: $source" >&2
        return 1
    }
    resolved=$(realpath -e -- "$source") || {
        echo "[gpuz-assets] ERROR: GPU-Z source could not be resolved: $source" >&2
        return 1
    }
    [[ -f "$resolved" && ! -L "$resolved" && -r "$resolved" ]] || {
        echo "[gpuz-assets] ERROR: resolved GPU-Z source is unsafe: $resolved" >&2
        return 1
    }
    printf '%s\n' "$resolved"
}

gpuz_asset_snapshot() {
    local source=${1:-} destination=${2:-} snapshot_bytes snapshot_sha
    local source_fd

    [[ -n "$source" && -n "$destination" ]] || {
        echo '[gpuz-assets] ERROR: gpuz_asset_snapshot requires SOURCE and DESTINATION' >&2
        return 1
    }
    [[ ! -e "$destination" && ! -L "$destination" ]] || {
        echo "[gpuz-assets] ERROR: private GPU-Z snapshot already exists: $destination" >&2
        return 1
    }
    exec {source_fd}<"$source" || {
        echo "[gpuz-assets] ERROR: could not pin GPU-Z source: $source" >&2
        return 1
    }
    [[ -f "/proc/self/fd/$source_fd" ]] || {
        exec {source_fd}<&-
        echo "[gpuz-assets] ERROR: pinned GPU-Z source is not a regular file: $source" >&2
        return 1
    }
    if ! install -m 0600 -- "/proc/self/fd/$source_fd" "$destination"; then
        exec {source_fd}<&-
        echo '[gpuz-assets] ERROR: could not create the private GPU-Z snapshot' >&2
        return 1
    fi
    exec {source_fd}<&-

    if [[ ! -f "$destination" || -L "$destination" ]]; then
        rm -f -- "$destination"
        echo '[gpuz-assets] ERROR: private GPU-Z snapshot is unsafe' >&2
        return 1
    fi
    snapshot_bytes=$(stat -c %s -- "$destination")
    snapshot_sha=$(
        sha256sum -- "$destination" | awk '{print toupper($1)}'
    )
    if [[ "$snapshot_bytes" != "$GPUZ_ASSET_BYTES" ||
          "$snapshot_sha" != "$GPUZ_ASSET_SHA256" ]]; then
        rm -f -- "$destination"
        echo "[gpuz-assets] ERROR: private GPU-Z snapshot is not the locked ${GPUZ_ASSET_PRODUCT_VERSION} asset (${GPUZ_ASSET_BYTES} bytes / ${GPUZ_ASSET_SHA256})" >&2
        return 1
    fi
}
