#!/usr/bin/env bash
# QEMU 文件 AIO 自动选择、显式 fail-closed 与 active-read probe 回归。
# shellcheck disable=SC2016,SC2030 # 静态字面匹配；QEMU 赋值刻意限制在策略子 shell。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SELECTOR="$REPO_ROOT/deploy/scripts/lib/sv-storage-aio.sh"
PROBE="$REPO_ROOT/deploy/scripts/lib/qemu-aio-probe.py"
STORAGE="$REPO_ROOT/deploy/scripts/lib/stealth-storage.sh"
REAL_QEMU="$REPO_ROOT/build/qemu-system-x86_64"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

cat >"$TMP_DIR/fake-probe.py" <<'PY'
import os
import pathlib
import sys

mode = sys.argv[2]
with pathlib.Path(os.environ["FAKE_PROBE_LOG"]).open("a", encoding="ascii") as log:
    log.write(mode + "\n")
available = set(filter(None, os.environ.get("FAKE_AIO_AVAILABLE", "").split(",")))
raise SystemExit(0 if mode in available else 1)
PY

run_selector() (
    export HERE="$REPO_ROOT/deploy/scripts"
    export QEMU=/bin/true
    export QEMU_AIO_PROBE="$TMP_DIR/fake-probe.py"
    export FAKE_PROBE_LOG="$1"
    export FAKE_AIO_AVAILABLE="$2"
    export QEMU_DISK_AIO="$3"
    export QEMU_CAP_CHECK="$4"
    # shellcheck source=../lib/sv-storage-aio.sh
    source "$SELECTOR"
    printf 'selected=%s\n' "$QEMU_DISK_AIO_SELECTED"
)

: >"$TMP_DIR/probe.log"
run_selector "$TMP_DIR/probe.log" io_uring,native auto 1 \
    >"$TMP_DIR/auto-uring.out"
grep -F 'selected=io_uring' "$TMP_DIR/auto-uring.out" >/dev/null ||
    fail "auto 没有优先选择可用的 io_uring"
[[ "$(<"$TMP_DIR/probe.log")" == io_uring ]] ||
    fail "io_uring 成功后仍探测了低优先级后端"

: >"$TMP_DIR/probe.log"
run_selector "$TMP_DIR/probe.log" native auto 1 >"$TMP_DIR/auto-native.out"
grep -F 'selected=native' "$TMP_DIR/auto-native.out" >/dev/null ||
    fail "auto 没有在 io_uring 不可用时选择 native"
[[ "$(<"$TMP_DIR/probe.log")" == $'io_uring\nnative' ]] ||
    fail "auto 的 io_uring→native 探测顺序错误"

: >"$TMP_DIR/probe.log"
run_selector "$TMP_DIR/probe.log" "" auto 1 >"$TMP_DIR/auto-threads.out"
grep -F 'selected=threads' "$TMP_DIR/auto-threads.out" >/dev/null ||
    fail "两个内核后端均不可用时没有回退 threads"

: >"$TMP_DIR/probe.log"
run_selector "$TMP_DIR/probe.log" io_uring auto 0 >"$TMP_DIR/cap-off.out"
grep -F 'selected=threads' "$TMP_DIR/cap-off.out" >/dev/null ||
    fail "QEMU_CAP_CHECK=0 fixture 没有保持 threads"
[[ ! -s "$TMP_DIR/probe.log" ]] ||
    fail "QEMU_CAP_CHECK=0 的 auto 模式仍启动了 active probe"

: >"$TMP_DIR/probe.log"
if run_selector "$TMP_DIR/probe.log" "" native 1 \
        >"$TMP_DIR/strict-native.out" 2>&1; then
    fail "显式 native 探测失败后发生了静默回退"
fi
grep -F '显式 QEMU_DISK_AIO=native 未通过' \
        "$TMP_DIR/strict-native.out" >/dev/null ||
    fail "显式 AIO 失败诊断不明确"

if [[ "${QEMU_AIO_SKIP_REAL_PROBE:-0}" != 1 ]]; then
    [[ -x "$REAL_QEMU" ]] || fail "缺少真实 QEMU，无法验证 active-read probe"
    ln -s "$REAL_QEMU" "$TMP_DIR/qemu, path with spaces"
    python3 "$PROBE" "$TMP_DIR/qemu, path with spaces" threads ||
        fail "active-read probe 不能处理带空格/逗号的 QEMU 路径"
else
    echo "SKIP: launcher job 不提供真实 QEMU，仅验证 selector 策略"
fi

cat >"$TMP_DIR/fallback-qemu" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' '{"return":{}}' '{"return":""}' '{"return":{}}'
echo 'Unable to use Linux AIO, falling back to thread pool' >&2
SH
chmod +x "$TMP_DIR/fallback-qemu"
if python3 "$PROBE" "$TMP_DIR/fallback-qemu" native --quiet; then
    fail "active-read probe 接受了 native 静默线程池回退"
fi

grep -F 'aio=${disk_aio},discard=unmap' "$STORAGE" >/dev/null ||
    fail "启动盘没有消费已验证的 AIO 后端"
if grep -F 'iothread=' "$STORAGE" >/dev/null; then
    fail "AIO 优化错误地给 emulated storage 增加了 IOThread"
fi

echo "PASS: storage AIO auto selection and active-read policy"
