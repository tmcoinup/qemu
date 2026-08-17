#!/usr/bin/env bash
# Stable entry point for local and CI validation of the G-11 deployment layer.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
build_dir="${BUILD_DIR:-$repo_root/build}"
run_unit=1
build_targets=1
filter=""
unit_names=(
    test-input-paused-release
    test-sdl2-event
    test-sdl2-pointer
    test-usb-hid-numlock
    test-fb-shm-stream-pace
    test-fb-shm-stream-gpu
    test-fb-shm-stream-control
    test-fb-shm-stream-ffmpeg
)
qtest_names=(
    usb-hid-keyboard-queue-test
)

usage() {
    cat <<'EOF'
usage: deploy/tests/run-g11.sh [options]

  --filter TEXT   run deployment tests whose path contains TEXT
  --no-build      do not rebuild the QEMU/streamer test targets
  --no-unit       skip compiled G-11 unit tests
  -h, --help      show this help

BUILD_DIR may point at a configured QEMU build directory.
EOF
}

while (($#)); do
    case "$1" in
        --filter)
            [[ $# -ge 2 ]] || {
                echo "run-g11: --filter requires text" >&2
                exit 2
            }
            filter=$2
            shift 2
            ;;
        --no-build)
            build_targets=0
            shift
            ;;
        --no-unit)
            run_unit=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "run-g11: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

cd "$repo_root"

if ((build_targets)); then
    if [[ ! -f "$build_dir/build.ninja" ]]; then
        echo "run-g11: build directory is not configured: $build_dir" >&2
        exit 1
    fi
    unit_targets=()
    for unit_name in "${unit_names[@]}"; do
        unit_targets+=("tests/unit/$unit_name")
    done
    qtest_targets=()
    for qtest_name in "${qtest_names[@]}"; do
        qtest_targets+=("tests/qtest/$qtest_name")
    done
    if ! ninja -C "$build_dir" qemu-system-x86_64 qemu-fb-shm-stream \
            "${unit_targets[@]}" "${qtest_targets[@]}"; then
        echo "run-g11: build failed" >&2
        exit 1
    fi
fi

mapfile -d '' tests < <(
    find deploy/tests/vgpu deploy/tests/qemu -type f -name 'test_*.sh' \
        -print0 | sort -z
)

passed=0
failed=0
selected=0
failed_tests=()
for test_path in "${tests[@]}"; do
    if [[ -n "$filter" && "$test_path" != *"$filter"* ]]; then
        continue
    fi
    selected=$((selected + 1))
    printf '\n==> %s\n' "$test_path"
    if bash "$test_path"; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        failed_tests+=("$test_path")
    fi
done

if ((selected == 0)); then
    echo "run-g11: no deployment test matched" >&2
    exit 2
fi

if ((run_unit)); then
    for unit_name in "${unit_names[@]}"; do
        unit_bin="$build_dir/tests/unit/$unit_name"
        printf '\n==> %s\n' "${unit_bin#$repo_root/}"
        if [[ -x "$unit_bin" ]] && "$unit_bin" --tap; then
            passed=$((passed + 1))
        else
            failed=$((failed + 1))
            failed_tests+=("${unit_bin#$repo_root/}")
        fi
    done
    for qtest_name in "${qtest_names[@]}"; do
        qtest_bin="$build_dir/tests/qtest/$qtest_name"
        printf '\n==> %s\n' "${qtest_bin#$repo_root/}"
        if [[ -x "$qtest_bin" ]] && \
                QTEST_QEMU_BINARY="$build_dir/qemu-system-x86_64" \
                "$qtest_bin" --tap; then
            passed=$((passed + 1))
        else
            failed=$((failed + 1))
            failed_tests+=("${qtest_bin#$repo_root/}")
        fi
    done
fi

printf '\nG-11 validation: %d passed, %d failed\n' "$passed" "$failed"
if ((failed)); then
    printf 'FAILED: %s\n' "${failed_tests[@]}" >&2
    exit 1
fi
