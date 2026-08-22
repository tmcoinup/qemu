#!/usr/bin/env bash
# Focused G-11 SDL validation suite: source contracts, launcher fixtures and
# the compiled input/pointer regressions that materially affect interaction.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
build_dir="${BUILD_DIR:-$repo_root/build}"
wrapper="$repo_root/deploy/scripts/g11-sdl-performance.sh"
build_targets=1
static_only=0
passed=0
failed=0
skipped=0
incomplete=0
declare -a failed_names=()

usage() {
    cat <<'EOF'
用法：deploy/tests/run-g11-sdl.sh [选项]

  --no-build     不运行 ninja；仍执行已有的编译单测
  --static-only  只执行 shell/source/启动器 fixture，不要求 build 目录
  -h, --help     显示帮助

可用 BUILD_DIR=/绝对路径 指定 QEMU build 目录。
EOF
}

while (($#)); do
    case "$1" in
        --no-build)
            build_targets=0
            shift
            ;;
        --static-only)
            build_targets=0
            static_only=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "[g11-sdl-test] 未知参数：$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

run_case() {
    local name=$1
    shift
    printf '\n==> %s\n' "$name"
    if "$@"; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        failed_names+=("$name")
    fi
}

skip_case() {
    local name=$1 reason=$2
    printf '\n==> %s\nSKIP: %s\n' "$name" "$reason"
    skipped=$((skipped + 1))
}

cd "$repo_root"

run_case "shell syntax: SDL wrapper/suite" \
    bash -n deploy/scripts/g11-sdl-performance.sh deploy/tests/run-g11-sdl.sh

declare -a shell_tests=()
while IFS= read -r test_path; do
    shell_tests+=("$test_path")
done < <(find deploy/tests/qemu -maxdepth 1 -type f \
    -name 'test_sdl_*.sh' -print | sort)
shell_tests+=(
    deploy/tests/qemu/test_g11_mutter_kms_thread.sh
    deploy/tests/qemu/test_vfio_region_frame_dedup_static.sh
    deploy/tests/qemu/test_vfio_dmabuf_fallback_static.sh
    deploy/tests/vgpu/test_vgpu_console_interval_static.sh
    deploy/tests/vgpu/test_usb_hid_low_latency.sh
    deploy/tests/vgpu/test_root_start_vm_native_display.sh
)

for test_path in "${shell_tests[@]}"; do
    if [[ -f "$test_path" ]]; then
        run_case "$test_path" bash "$test_path"
    else
        run_case "$test_path" bash -c \
            'echo "缺少预期测试：$1" >&2; exit 1' _ "$test_path"
    fi
done

unit_names=(test-input-paused-release)
while IFS= read -r unit_source; do
    unit_names+=("$(basename "$unit_source" .c)")
done < <(find tests/unit -maxdepth 1 -type f -name 'test-sdl2-*.c' -print | sort)
unit_names+=(test-usb-hid-numlock)
qtest_names=(usb-hid-keyboard-queue-test usb-hid-numlock-test)

if ((static_only)); then
    for unit_name in "${unit_names[@]}" "${qtest_names[@]}"; do
        skip_case "$unit_name" "--static-only 已明确跳过编译单测"
    done
else
    if [[ ! -f "$build_dir/build.ninja" ]]; then
        echo "[g11-sdl-test] 未配置 build 目录：$build_dir" >&2
        echo "[g11-sdl-test] shell/source 测试已继续；编译单测未执行。" >&2
        echo "[g11-sdl-test] 请先运行 ./deploy/host/build-qemu.sh，再重跑本命令。" >&2
        incomplete=1
    elif ((build_targets)); then
        if ! command -v ninja >/dev/null 2>&1; then
            echo "[g11-sdl-test] 找不到 ninja，无法增量构建；将尝试已有二进制。" >&2
            incomplete=1
        else
            declare -a ninja_targets=(qemu-system-x86_64)
            for unit_name in "${unit_names[@]}"; do
                ninja_targets+=("tests/unit/$unit_name")
            done
            for qtest_name in "${qtest_names[@]}"; do
                ninja_targets+=("tests/qtest/$qtest_name")
            done
            run_case "ninja: SDL/input test targets" \
                ninja -C "$build_dir" "${ninja_targets[@]}"
        fi
    fi

    qemu_bin="$build_dir/qemu-system-x86_64"
    if [[ -x "$qemu_bin" ]]; then
        run_case "g11-sdl-performance audit" \
            env QEMU_BIN="$qemu_bin" "$wrapper" audit
    else
        skip_case "g11-sdl-performance audit" \
            "qemu-system-x86_64 不存在；先运行 ./deploy/host/build-qemu.sh"
        incomplete=1
    fi

    for unit_name in "${unit_names[@]}"; do
        unit_bin="$build_dir/tests/unit/$unit_name"
        if [[ -x "$unit_bin" ]]; then
            run_case "${unit_bin#$repo_root/}" "$unit_bin" --tap
        else
            skip_case "${unit_bin#$repo_root/}" \
                "二进制不存在；先运行 ./deploy/host/build-qemu.sh"
            incomplete=1
        fi
    done

    for qtest_name in "${qtest_names[@]}"; do
        qtest_bin="$build_dir/tests/qtest/$qtest_name"
        if [[ -x "$qtest_bin" && -x "$qemu_bin" ]]; then
            printf '\n==> %s\n' "${qtest_bin#$repo_root/}"
            if timeout --foreground 60s env QTEST_QEMU_BINARY="$qemu_bin" \
                    "$qtest_bin" --tap; then
                passed=$((passed + 1))
            else
                failed=$((failed + 1))
                failed_names+=("${qtest_bin#$repo_root/}")
            fi
        else
            skip_case "${qtest_bin#$repo_root/}" \
                "qtest 或 qemu-system-x86_64 不存在；先运行 ./deploy/host/build-qemu.sh"
            incomplete=1
        fi
    done
fi

printf '\nG-11 SDL 验证：%d 通过，%d 失败，%d 跳过\n' \
    "$passed" "$failed" "$skipped"
if ((failed)); then
    printf 'FAILED: %s\n' "${failed_names[@]}" >&2
    exit 1
fi
if ((incomplete)); then
    echo "INCOMPLETE: 静态检查通过，但缺少部分 build/编译单测；按上方提示构建后重跑。" >&2
    exit 2
fi
echo "PASS: G-11 SDL source、启动封装与编译输入回归均通过"
