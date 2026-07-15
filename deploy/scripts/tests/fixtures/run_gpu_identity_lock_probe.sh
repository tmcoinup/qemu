#!/usr/bin/env bash
# 在两个独立 PowerShell 进程中竞争 GPU 身份共享写锁。该辅助用例与
# durable transaction 状态机的内存 RegistryKey fixture 解耦，主测试因此可以
# 保持在 500 个非注释代码行以内，并由 quick runner 间接且必然地执行。
# shellcheck disable=SC2016
# 单引号块是交给 PowerShell 子进程解析的源码，其中 `$env:` 绝不能由 Bash 展开。
set -euo pipefail

transaction_script="${1:-}"
[[ -f "$transaction_script" ]] || {
    echo "FAIL: 缺少 GPU identity transaction helper: $transaction_script" >&2
    exit 1
}
command -v pwsh >/dev/null 2>&1 || {
    echo "FAIL: 缺少 pwsh" >&2
    exit 1
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

run_lock_probe() {
    local output="$1"
    local hold_ms="$2"
    TRANSACTION_SCRIPT="$transaction_script" LOCK_OUTPUT="$output" \
        LOCK_HOLD_MS="$hold_ms" pwsh -NoLogo -NoProfile -NonInteractive -Command '
            . $env:TRANSACTION_SCRIPT
            Invoke-WithIdentityWriterLock {
                [IO.File]::WriteAllText($env:LOCK_OUTPUT,
                    [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString() + "`n")
                Start-Sleep -Milliseconds ([int]$env:LOCK_HOLD_MS)
                [IO.File]::AppendAllText($env:LOCK_OUTPUT,
                    [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString() + "`n")
            }
        '
}

run_lock_probe "$tmp_dir/first" 600 &
first_pid=$!
sleep 0.1
run_lock_probe "$tmp_dir/second" 0 &
second_pid=$!
wait "$first_pid" "$second_pid"

first_release="$(sed -n '2p' "$tmp_dir/first")"
second_acquire="$(sed -n '1p' "$tmp_dir/second")"
[[ -n "$first_release" && -n "$second_acquire" && \
    "$second_acquire" -ge "$first_release" ]] || {
    echo "FAIL: 跨进程 identity mutex 出现临界区交错" >&2
    exit 1
}
