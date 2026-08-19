#!/usr/bin/env bash
# Exercise the reversible GNOME animation wrapper without touching live settings.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
guard="$repo_root/deploy/host/gnome-animation-guard.py"
launcher="$repo_root/deploy/scripts/start-vm.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -x "$guard" ]] || fail "GNOME animation guard is missing or not executable"
grep -Fq 'QEMU_SDL_GNOME_ANIMATIONS="${QEMU_SDL_GNOME_ANIMATIONS:-off}"' \
    "$launcher" || fail "G-11 SDL launcher does not default to the guarded mode"
grep -Fq 'gnome-animation-guard.py' "$launcher" \
    || fail "G-11 SDL launcher does not wrap QEMU with the animation guard"

tmp_dir="$(mktemp -d /tmp/g11-animation-guard-test.XXXXXX)"
trap 'rm -rf -- "$tmp_dir"' EXIT
fake_gsettings="$tmp_dir/gsettings"
value_file="$tmp_dir/value"

cat >"$fake_gsettings" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    get)
        cat "$QEMU_FAKE_GSETTINGS_VALUE"
        ;;
    writable)
        echo true
        ;;
    set)
        [[ "${4:-}" == true || "${4:-}" == false ]] || exit 2
        printf '%s\n' "$4" >"$QEMU_FAKE_GSETTINGS_VALUE"
        ;;
    *)
        exit 2
        ;;
esac
EOF
chmod +x "$fake_gsettings"

export QEMU_GNOME_ANIMATION_STATE_DIR="$tmp_dir"
export QEMU_GNOME_ANIMATION_GSETTINGS="$fake_gsettings"
export QEMU_FAKE_GSETTINGS_VALUE="$value_file"

# The child sees animations disabled; the exact original value returns after it.
echo true >"$value_file"
python3 "$guard" run -- bash -c \
    '[[ "$(<"$QEMU_FAKE_GSETTINGS_VALUE")" == false ]]' \
    || fail "guarded command did not observe animations disabled"
[[ "$(<"$value_file")" == true ]] \
    || fail "original true setting was not restored"

echo false >"$value_file"
python3 "$guard" run -- true \
    || fail "guard could not preserve an already-disabled setting"
[[ "$(<"$value_file")" == false ]] \
    || fail "original false setting was not restored exactly"

# Releasing one of two concurrent VMs must not re-enable animations underneath
# the remaining VM.  The last owner restores the baseline.
echo true >"$value_file"
ready_file="$tmp_dir/first-ready"
release_file="$tmp_dir/release-first"
python3 "$guard" run -- bash -c '
    [[ "$(<"$QEMU_FAKE_GSETTINGS_VALUE")" == false ]]
    : >"$1"
    while [[ ! -e "$2" ]]; do sleep 0.02; done
' _ "$ready_file" "$release_file" &
first_guard=$!
for _ in $(seq 1 100); do
    [[ -e "$ready_file" ]] && break
    sleep 0.02
done
[[ -e "$ready_file" ]] || fail "first concurrent guard did not start"

python3 "$guard" run -- true || fail "second concurrent guard failed"
[[ "$(<"$value_file")" == false ]] \
    || fail "second VM exit re-enabled animations while the first was live"
: >"$release_file"
wait "$first_guard" || fail "first concurrent guard failed"
[[ "$(<"$value_file")" == true ]] \
    || fail "last VM exit did not restore the baseline"

# A killed wrapper leaves the pre-change value in its journal.  Recovery must
# prune the dead owner and restore that value without guessing or resetting it.
crash_ready="$tmp_dir/crash-ready"
echo true >"$value_file"
python3 "$guard" run -- bash -c ': >"$1"; sleep 0.2' _ "$crash_ready" &
crash_guard=$!
for _ in $(seq 1 100); do
    [[ -e "$crash_ready" ]] && break
    sleep 0.02
done
[[ -e "$crash_ready" ]] || fail "crash-recovery guard did not start"
kill -KILL "$crash_guard"
wait "$crash_guard" 2>/dev/null || true
[[ "$(<"$value_file")" == false ]] \
    || fail "crash fixture did not leave the guarded setting active"
python3 "$guard" recover || fail "idempotent recovery failed"
[[ "$(<"$value_file")" == true ]] \
    || fail "stale-owner recovery did not restore the baseline"
python3 "$guard" recover || fail "idempotent recovery failed"

echo "OK: SDL GNOME animation guard checks passed"
