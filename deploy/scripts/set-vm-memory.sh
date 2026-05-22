#!/bin/bash
# ---------------------------------------------------------------------------
# set-vm-memory.sh —— 切换某台隐身 VM 的内存配置（4GB 单通道 <-> 8GB 双通道）
#
# 只改 profile 里的 MEM_TOTAL_MB 一个字段，**不碰任何其它硬件身份**
# （CPU / 主板 / GPU / NVMe / 各类序列号全不动），也**不改启动命令**：照常
#     ./start-vm.sh <N> [--proxy ...]
# start-vm.sh 会自动读 profile.MEM_TOTAL_MB 决定内存拓扑。改完**重启 VM** 生效
# （内存量是开机确定的硬件拓扑，不做热插拔——热插拔事件本身是 VM 特征）。
#
# 用法:
#   ./set-vm-memory.sh <N> 8G        # 8192 MiB = 2×4GB 双通道（两卡槽占满）← 4G×2
#   ./set-vm-memory.sh <N> 4G        # 4096 MiB = 1×4GB 单通道（占 1 空 1）
#   ./set-vm-memory.sh <N> 4Gx2      # 同 8G（4GB 两条；'4G*2' 需加引号防 shell 展开 *）
#   ./set-vm-memory.sh <N> 8192      # 直接给 MiB
#   ./set-vm-memory.sh <N>           # 只看当前配置，不改（= --show）
#
# size 友好写法（大小写随意）:
#   2G | 2048                       -> 2048  （1×2GB 单通道）
#   4G | 4096 | 1x4G | single       -> 4096  （1×4GB 单通道，2 卡槽占 1 空 1）
#   8G | 8192 | 4Gx2 | 2x4G | dual  -> 8192  （2×4GB 双通道，两卡槽占满）
#   <纯数字>[m]                      -> 该 MiB 值
#
# 为什么主推 ≤8192: 画像是"2 卡槽 AM4 入门主板 + 2G/4G DDR4 颗粒池"。8192 时
# SMBIOS 出两条各自唯一序列号的 4GB DIMM（DIMM_A2 / DIMM_B2，CHANNEL A/B）。
# >8192 会让 SMBIOS DIMM 数 (ram/4GiB) 超过 2 卡槽，与主板物理槽位矛盾 → 警告。
# ---------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=stealth-lib.sh
source "$HERE/stealth-lib.sh"

_die(){ echo "ERROR: $*" >&2; exit 1; }
_usage(){ sed -n '2,/^# --*$/p' "$0" | sed -e 's/^# *//' -e 's/^#$//' >&2; exit "${1:-2}"; }

[[ $# -ge 1 ]] || _usage
case "${1:-}" in -h|--help) _usage 0 ;; esac

INSTANCE="$1"; shift || true
[[ "$INSTANCE" =~ ^[0-9]+$ ]] || _die "instance 必须是正整数（实际 '$INSTANCE'）"
VM_DIR="/home/ubuntu/images/vms/${INSTANCE}"
PROFILE="$VM_DIR/profile"
[[ -f "$PROFILE" ]] || _die "profile 不存在: $PROFILE （先 ./start-vm.sh $INSTANCE 生成硬件身份）"

SIZE_ARG="${1:-}"

# size 写法 -> MiB（× 和 * 统一成 x；纯数字/带 m 后缀直接取值）
_parse_size(){
    local s
    s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d ' ' | tr '×*' 'xx')"
    case "$s" in
        --show|show|"")        echo "" ;;
        2g|1x2g|2gx1)          echo 2048 ;;
        4g|1x4g|4gx1|single)   echo 4096 ;;
        8g|4gx2|2x4g|dual)     echo 8192 ;;
        *) if [[ "$s" =~ ^([0-9]+)m?$ ]]; then echo "${BASH_REMATCH[1]}"; else echo "__BAD__"; fi ;;
    esac
}

# 载入 profile（拿 MEM_MFR / part / SN 等，用于打印拓扑）
set +u; stealth_load_profile "$PROFILE"; set -u
CUR="${MEM_TOTAL_MB:-}"; [[ -z "$CUR" ]] && CUR=4096   # 老 profile 无字段 = 历史默认 4GB

# 打印某内存总量对应的 DIMM 拓扑（与 start-vm.sh / stealth_print_profile 口径一致）
_topo(){
    local mib="$1" nd pd part sn2
    if (( mib <= 4096 )); then nd=1; pd=$mib; else nd=2; pd=$(( mib / 2 )); fi
    if (( pd >= 4096 )); then part="$MEM_PART_4G"; else part="$MEM_PART_2G"; fi
    if (( nd == 1 )); then
        echo "     ${mib} MiB = 1× $(( pd / 1024 )).$(( (pd % 1024) * 10 / 1024 )) GiB   单通道, 2 卡槽占 1 空 1"
        echo "     厂商=${MEM_MFR}  part=${part}  SN=${MEM_SERIAL}"
    else
        sn2=$(printf '%s' "${MEM_SERIAL}-dimm2" | sha256sum | head -c 8 | tr '[:lower:]' '[:upper:]')
        echo "     ${mib} MiB = 2× $(( pd / 1024 )).$(( (pd % 1024) * 10 / 1024 )) GiB   双通道, 2 卡槽全占"
        echo "     厂商=${MEM_MFR}  part=${part}"
        echo "     SN: ${MEM_SERIAL} (DIMM_A2) / ${sn2} (DIMM_B2)  ← 两条各自唯一"
    fi
}

echo ">> VM ${INSTANCE} profile: $PROFILE"
echo ">> 当前内存配置:"
_topo "$CUR"

NEW="$(_parse_size "$SIZE_ARG")"
if [[ -z "$NEW" ]]; then
    echo ">>"
    echo ">> （只读模式；给个 size 才会改，例如：$(basename "$0") ${INSTANCE} 8G）"
    exit 0
fi
[[ "$NEW" == "__BAD__" ]] && _die "无法识别的内存写法: '$SIZE_ARG'（试 4G / 8G / 4Gx2 / 8192）"
[[ "$NEW" =~ ^[0-9]+$ ]] || _die "解析出的内存值非法: '$NEW'"
(( NEW >= 512 )) || _die "内存太小: ${NEW} MiB（至少 512）"

# 画像自洽性校验（2 卡槽板 + 2G/4G 颗粒池）
if (( NEW > 8192 )); then
    echo ">> WARN: ${NEW} MiB 会让 SMBIOS DIMM 数 (ram/4GiB) 超过 2，"
    echo ">>       与'2 卡槽 AM4 入门主板'画像矛盾。强烈建议 ≤ 8192。"
    read -r -p ">> 仍要继续？[y/N] " _a; [[ "${_a:-}" == [yY] ]] || { echo ">> 已取消。"; exit 1; }
elif (( NEW != 2048 && NEW != 4096 && NEW != 8192 )); then
    echo ">> WARN: ${NEW} MiB 不是 2G/4G/8G 整配置，SMBIOS 末条 DIMM 容量会是余数，"
    echo ">>       裸金属画像略不自然。建议用 4096 或 8192。"
fi

if [[ "$NEW" == "$CUR" ]]; then
    echo ">>"
    echo ">> 已经是 ${NEW} MiB，无需改动。"
    exit 0
fi

# VM 在运行 -> 提示重启才生效（不热插拔）
if pgrep -f "name win10-${INSTANCE}," >/dev/null 2>&1 || pgrep -f "qemu-stealth-${INSTANCE}\." >/dev/null 2>&1; then
    echo ">>"
    echo ">> 注意: VM ${INSTANCE} 似乎正在运行。改动写进 profile 后需要重启才生效:"
    echo ">>       ./stop-vm.sh ${INSTANCE} && ./start-vm.sh ${INSTANCE} [--proxy ...]"
fi

# 备份 + 原子写（字段存在则原位替换，不存在则插在 MEM_SERIAL 之后）
BAK="${PROFILE}.bak.$(date +%s)"
cp -p "$PROFILE" "$BAK"
TMP="${PROFILE}.tmp.$$"
if grep -q '^MEM_TOTAL_MB=' "$PROFILE"; then
    sed "s|^MEM_TOTAL_MB=.*|MEM_TOTAL_MB=${NEW}|" "$PROFILE" > "$TMP"
elif grep -q '^MEM_SERIAL=' "$PROFILE"; then
    sed "/^MEM_SERIAL=/a MEM_TOTAL_MB=${NEW}" "$PROFILE" > "$TMP"
else
    cp "$PROFILE" "$TMP"
    echo "MEM_TOTAL_MB=${NEW}" >> "$TMP"
fi
mv -f "$TMP" "$PROFILE"

echo ">>"
echo ">> 已写入 MEM_TOTAL_MB=${NEW} MiB （备份: $BAK）"
echo ">> 改后内存配置:"
_topo "$NEW"
echo ">>"
echo ">> 生效（启动命令不变）:  ./start-vm.sh ${INSTANCE} [--proxy ...]"
