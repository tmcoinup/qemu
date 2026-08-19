#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
DEPLOY_ROOT=$(cd "$TEST_DIR/../.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

# shellcheck source=../../lib/dgame-endpoints.sh
source "$DEPLOY_ROOT/lib/dgame-endpoints.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

alias_path=$(dgame_endpoint_path 8 fb "$TEST_ROOT")
target="$TEST_ROOT/vms/8/run/dgame-fb-shm.sock"
mkdir -p "$(dirname "$target")"
dgame_endpoint_alias_install "$alias_path" "$target"
[[ -L "$alias_path" && "$(readlink -- "$alias_path")" == "$target" ]] ||
    fail "canonical V-11 alias was not installed"

# Idempotent install is allowed, but neither a foreign symlink nor a real
# DGame broker socket may be replaced.
dgame_endpoint_alias_install "$alias_path" "$target"
foreign="$TEST_ROOT/qemu-stealth-9.fb"
ln -s "$TEST_ROOT/foreign.sock" "$foreign"
! dgame_endpoint_alias_install "$foreign" "$target" >/dev/null 2>&1 ||
    fail "foreign alias was replaced"

dgame_endpoint_alias_remove "$foreign" "$target" >/dev/null 2>&1
[[ -L "$foreign" ]] || fail "foreign alias was removed"
dgame_endpoint_alias_remove "$alias_path" "$target"
[[ ! -e "$alias_path" && ! -L "$alias_path" ]] ||
    fail "owned alias was not removed"

qmp_path=$(dgame_endpoint_path 16 qmp "$TEST_ROOT")
preview_path=$(dgame_preview_socket_path "$TEST_ROOT/vms/16/run")
[[ "$qmp_path" == "$TEST_ROOT/qemu-stealth-16.qmp" ]] ||
    fail "QMP path contract differs"
[[ "$preview_path" == "$TEST_ROOT/vms/16/run/dgame-fb-shm.sock" ]] ||
    fail "preview socket contract differs"
! dgame_endpoint_path 0 fb "$TEST_ROOT" >/dev/null 2>&1 ||
    fail "VM ID zero was accepted"
! dgame_endpoint_path 8 unknown "$TEST_ROOT" >/dev/null 2>&1 ||
    fail "unknown endpoint suffix was accepted"

echo "PASS: DGame V-11/G-11 endpoint compatibility"
