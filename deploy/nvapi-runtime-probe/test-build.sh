#!/usr/bin/env bash
# 无需启动 Windows 客体即可检查双架构探针的 PE、依赖和诊断契约。
set -euo pipefail
export LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH=0

cd "$(dirname "$(readlink -f "$0")")"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

check_probe() {
    local executable="$1"
    local objdump="$2"
    local expected_format="$3"
    local expected_architecture="$4"
    local expected_dll="$5"
    local headers imports ascii_strings wide_strings

    [[ -s "$executable" ]] || fail "$executable 不存在或为空"
    headers="$("$objdump" -f "$executable")"
    grep -F "file format $expected_format" <<<"$headers" >/dev/null \
        || fail "$executable 机器架构不是 $expected_format"

    imports="$("$objdump" -p "$executable")"
    grep -F 'Subsystem' <<<"$imports" | grep -F 'Windows CUI' >/dev/null \
        || fail "$executable 不是无弹窗控制台程序"
    grep -F 'DLL Name: KERNEL32.dll' <<<"$imports" >/dev/null \
        || fail "$executable 未导入 Windows 动态加载 API"
    grep -F 'GetProcAddress' <<<"$imports" >/dev/null \
        || fail "$executable 未通过 GetProcAddress 获取 QueryInterface"
    grep -F 'LoadLibraryExW' <<<"$imports" >/dev/null \
        || fail "$executable 未从绝对系统路径动态加载 NVAPI"
    grep -F 'DLL Name: libwinpthread-1.dll' <<<"$imports" >/dev/null \
        && fail "$executable 不应依赖额外 MinGW pthread 运行库"
    python3 - "$executable" <<'PY' \
        || fail "$executable 链接时间戳不为 0"
import pathlib
import struct
import sys

data = pathlib.Path(sys.argv[1]).read_bytes()
pe_offset = struct.unpack_from("<I", data, 0x3C)[0]
if data[pe_offset:pe_offset + 4] != b"PE\0\0":
    raise SystemExit(1)
timestamp = struct.unpack_from("<I", data, pe_offset + 8)[0]
raise SystemExit(0 if timestamp == 0 else 1)
PY

    ascii_strings="$(strings -a "$executable")"
    wide_strings="$(strings -a -e l "$executable")"
    grep -Fx 'nvapi_QueryInterface' <<<"$ascii_strings" >/dev/null \
        || fail "$executable 缺少 NVAPI 唯一导出查找名"
    grep -Fx "probe.architecture=$expected_architecture" \
        <<<"$ascii_strings" >/dev/null \
        || fail "$executable 没有锁定目标位数日志"
    grep -Fx 'probe.version=2' <<<"$ascii_strings" >/dev/null \
        || fail "$executable 没有锁定包含显存接口验收的 probe.version=2"
    grep -Fx 'nvapi.initialize.status=%d' <<<"$ascii_strings" >/dev/null \
        || fail "$executable 未输出 Initialize 原始状态"
    grep -Fx 'nvapi.enumerate.status=%d' <<<"$ascii_strings" >/dev/null \
        || fail "$executable 未输出 EnumPhysicalGPUs 原始状态"
    grep -F '.pci.status=%d' <<<"$ascii_strings" >/dev/null \
        || fail "$executable 未输出 GetPCIIdentifiers 原始状态"
    grep -F '.name.status=%d' <<<"$ascii_strings" >/dev/null \
        || fail "$executable 未输出 GetFullName 原始状态"
    grep -F '.type.status=%d' <<<"$ascii_strings" >/dev/null \
        || fail "$executable 未输出 GetGPUType 原始状态"
    grep -F '.framebuffer.kib=%u' <<<"$ascii_strings" >/dev/null \
        || fail "$executable 未输出 legacy framebuffer KiB"
    grep -Fx 'query.memory_info.present=%u' <<<"$ascii_strings" >/dev/null \
        || fail "$executable 未要求 GetMemoryInfo QueryInterface"
    grep -Fx 'query.memory_info_ex.present=%u' <<<"$ascii_strings" >/dev/null \
        || fail "$executable 未要求 GetMemoryInfoEx QueryInterface"
    grep -F '.memory_info.status=%d' <<<"$ascii_strings" >/dev/null \
        || fail "$executable 未输出 GetMemoryInfo 原始状态"
    grep -F '.memory_info_ex.status=%d' <<<"$ascii_strings" >/dev/null \
        || fail "$executable 未输出 GetMemoryInfoEx 原始状态"
    grep -F '.memory_info.dedicated_kib=%u' <<<"$ascii_strings" >/dev/null \
        || fail "$executable 未输出 GetMemoryInfo KiB"
    grep -F '.memory_info_ex.dedicated_bytes=%llu' \
        <<<"$ascii_strings" >/dev/null \
        || fail "$executable 未输出 GetMemoryInfoEx bytes"
    grep -F 'nvapi.driver_version.status=%d' <<<"$ascii_strings" >/dev/null \
        || fail "$executable 未输出 DriverAndBranchVersion 原始状态"
    grep -F 'query.forbidden_display_topology.present=%u' \
        <<<"$ascii_strings" >/dev/null \
        || fail "$executable 未拒绝 GPU-Z 不完整 display 拓扑"
    [[ "$(LC_ALL=C grep -aob $'\x68\xb3\xf9\x07' "$executable" |
        wc -l)" -eq 1 ]] \
        || fail "$executable 未精确包含 GetMemoryInfo QueryInterface ID"
    [[ "$(LC_ALL=C grep -aob $'\x98\x94\x59\xc0' "$executable" |
        wc -l)" -eq 1 ]] \
        || fail "$executable 未精确包含 GetMemoryInfoEx QueryInterface ID"
    grep -F "$expected_dll" <<<"$wide_strings" >/dev/null \
        || fail "$executable 没有锁定对应系统 NVAPI 文件名"
}

for tool in i686-w64-mingw32-objdump x86_64-w64-mingw32-objdump \
        strings python3; do
    command -v "$tool" >/dev/null 2>&1 \
        || fail "缺少探针静态检查工具：$tool"
done

check_probe nvapi-runtime-probe-x86.exe i686-w64-mingw32-objdump \
    pei-i386 x86 nvapi.dll
check_probe nvapi-runtime-probe-x64.exe x86_64-w64-mingw32-objdump \
    pei-x86-64 x64 nvapi64.dll

echo "OK: NVAPI x86/x64 runtime probe PE and diagnostics passed"
