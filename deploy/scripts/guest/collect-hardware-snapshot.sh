#!/usr/bin/env bash
# 在 Linux 客体内采集硬件枚举快照。所有探针只读、并发执行；单项缺工具会记录
# skipped/exit code，不会让其它证据丢失。建议在客体内以 root 运行以读取 DMI/内核日志。
set -euo pipefail

OUTPUT_DIR="${1:-vmate-hardware-$(date +%Y%m%d-%H%M%S)}"
MAX_JOBS="${MAX_JOBS:-4}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-60}"

if ! [[ "$MAX_JOBS" =~ ^[1-9][0-9]*$ && "$PROBE_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: MAX_JOBS/PROBE_TIMEOUT 必须为正整数" >&2
    exit 2
fi
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

# 普通用户不应触发交互式 sudo 卡住自动验收；只有免密 sudo 可用时才提升只读探针。
ROOT_PREFIX=()
if (( EUID != 0 )) && sudo -n true >/dev/null 2>&1; then
    ROOT_PREFIX=(sudo -n)
fi

wait_for_slot() {
    while (( $(jobs -pr | wc -l) >= MAX_JOBS )); do
        wait -n || true
    done
}

run_probe() {
    local name="$1"
    shift
    wait_for_slot
    (
        local status=0
        {
            printf 'probe=%s\n' "$name"
            printf 'timestamp=%s\n' "$(date -Iseconds)"
            printf 'command='
            printf '%q ' "$@"
            printf '\n\n'
            timeout --signal=TERM "$PROBE_TIMEOUT" "$@" || status=$?
        } >"$OUTPUT_DIR/$name.txt" 2>&1
        printf '%s\n' "$status" >"$OUTPUT_DIR/$name.status"
    ) &
}

run_optional_probe() {
    local name="$1" binary="$2"
    shift 2
    if command -v "$binary" >/dev/null 2>&1; then
        run_probe "$name" "$binary" "$@"
    else
        printf 'skipped: command not found: %s\n' "$binary" >"$OUTPUT_DIR/$name.txt"
        printf '127\n' >"$OUTPUT_DIR/$name.status"
    fi
}

# 基础系统与 CPU/DMI：用于核对 CPU SKU、核心线程、BIOS、主板、机箱和 DIMM。
run_probe uname uname -a
run_probe os-release sh -c 'cat /etc/os-release; printf "\ncmdline="; cat /proc/cmdline'
run_optional_probe lscpu lscpu --json
if command -v dmidecode >/dev/null 2>&1; then
    run_probe dmidecode "${ROOT_PREFIX[@]}" dmidecode --type 0,1,2,3,4,9,16,17,19,32
else
    printf 'skipped: command not found: dmidecode\n' >"$OUTPUT_DIR/dmidecode.txt"
    printf '127\n' >"$OUTPUT_DIR/dmidecode.status"
fi

# PCI/USB/存储/TPM：主 ID、subsystem、link speed/width 与固件是跨源一致性重点。
run_optional_probe lspci-verbose lspci -nnvv
run_optional_probe lspci-tree lspci -tv
run_optional_probe lsusb lsusb -v
run_optional_probe nvme-list nvme list -v
if command -v nvme >/dev/null 2>&1 && [[ -e /dev/nvme0 ]]; then
    run_probe nvme-id-ctrl "${ROOT_PREFIX[@]}" nvme id-ctrl -H /dev/nvme0
fi
run_optional_probe tpm-properties tpm2_getcap properties-fixed

# 驱动和错误日志只截取本次启动，便于识别设备初始化、TDR、I/O 与 ACPI warning。
run_optional_probe kernel-modules lsmod
if command -v dmesg >/dev/null 2>&1; then
    run_probe dmesg-warning "${ROOT_PREFIX[@]}" dmesg --level=emerg,alert,crit,err,warn
fi
if command -v journalctl >/dev/null 2>&1; then
    run_probe journal-warning "${ROOT_PREFIX[@]}" journalctl -b -p warning --no-pager
fi

# EDID 可能有多个 connector，单独在一个只读子任务中依次导出二进制和解码文本。
wait_for_slot
(
    status=0
    found=0
    for edid in /sys/class/drm/*/edid; do
        [[ -s "$edid" ]] || continue
        found=1
        connector="$(basename "$(dirname "$edid")")"
        cp -- "$edid" "$OUTPUT_DIR/edid-$connector.bin" || status=$?
        if command -v edid-decode >/dev/null 2>&1; then
            edid-decode "$edid" >"$OUTPUT_DIR/edid-$connector.txt" 2>&1 || status=$?
        fi
    done
    (( found )) || printf 'no non-empty DRM EDID found\n' >"$OUTPUT_DIR/edid-none.txt"
    printf '%s\n' "$status" >"$OUTPUT_DIR/edid.status"
) &

wait

# 汇总保留每个探针状态。缺少可选工具记为 warning，真正命令失败记为 failed，
# 让报告既适用于最小发行版，也不会把权限/驱动问题误报成全通过。
failed=0
warnings=0
{
    printf 'generated_at=%s\n' "$(date -Iseconds)"
    printf 'kernel=%s\n' "$(uname -r)"
    for status_file in "$OUTPUT_DIR"/*.status; do
        name="$(basename "$status_file" .status)"
        code="$(tr -d '[:space:]' <"$status_file")"
        printf '%s=%s\n' "$name" "$code"
        if [[ "$code" == 127 ]]; then
            warnings=$((warnings + 1))
        elif [[ "$code" != 0 ]]; then
            failed=$((failed + 1))
        fi
    done
    printf 'failed=%d\nwarning_or_missing=%d\n' "$failed" "$warnings"
} >"$OUTPUT_DIR/SUMMARY.txt"

echo "Linux hardware snapshot: $OUTPUT_DIR"
echo "probes failed=$failed, warning/missing=$warnings"
exit "$(( failed > 0 ? 1 : 0 ))"
