#!/usr/bin/env bash
# seal-base.sh —— 把指定 instance 的 disk.qcow2 转成只读基础镜像，供后续克隆。
#
# 用法：
#   deploy/scripts/seal-base.sh <SRC_INSTANCE> <BASE_NAME>
#
# 例：
#   deploy/scripts/seal-base.sh 2 win10-ltsc-shallow
#       -> /home/ubuntu/images/vms/_base/win10-ltsc-shallow.qcow2
#
# 推荐流程：装好 1 个 VM（autounattend + shallow-stealth），关机后用本脚本固化为
# base，再用 clone-from-base.sh 克隆给后续 instance。新 instance 只存增量。
#
# 注意：
#   - 源 VM 必须先关机（lsof 检查）
#   - sysprep / 清掉 SID 等是 Windows 侧的事，本脚本不做 — 如果不 sysprep，
#     克隆出的 VM 会复用 SID/MachineGUID。仅做单机用途时可以忽略。
#   - **默认会先清理源 disk 的腾讯/WeGame 设备身份**（qimei / 登录态 / SDK 缓存 +
#     注册表 Tencent 键，见 host-clean-tencent.sh），避免所有 clone 共享同一个
#     qimei 被 ACE 判同机/多开。这一步会改源 disk（清空其 WeGame 登录态 —— base
#     本该如此）。需要保留源 disk 原样请加 --no-clean。
#   - convert 后另存一份到 _base/，源 disk 仅被上面的清理改动、不被 convert 改。
#     可选随后 rm 源 disk 腾空间，再用 clone-from-base.sh 重建该 instance 即可。

set -euo pipefail

CLEAN=1
POS=()
for a in "$@"; do
    case "$a" in
        --no-clean) CLEAN=0 ;;
        --*) echo "ERROR: 未知 flag '$a'" >&2; exit 2 ;;
        *) POS+=("$a") ;;
    esac
done
SRC_INSTANCE="${POS[0]:-}"
BASE_NAME="${POS[1]:-}"

if [[ -z "$SRC_INSTANCE" || -z "$BASE_NAME" ]]; then
    echo "usage: $0 <SRC_INSTANCE> <BASE_NAME> [--no-clean]" >&2
    exit 2
fi
if ! [[ "$SRC_INSTANCE" =~ ^[0-9]+$ ]]; then
    echo "ERROR: SRC_INSTANCE 必须是正整数" >&2
    exit 2
fi
if [[ ! "$BASE_NAME" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "ERROR: BASE_NAME 只能用字母/数字/下划线/短横线" >&2
    exit 2
fi

VM_DIR="/home/ubuntu/images/vms/${SRC_INSTANCE}"
SRC_DISK="$VM_DIR/disk.qcow2"
BASE_DIR="/home/ubuntu/images/vms/_base"
BASE_FILE="$BASE_DIR/${BASE_NAME}.qcow2"

if [[ ! -f "$SRC_DISK" ]]; then
    echo "ERROR: $SRC_DISK 不存在" >&2
    exit 1
fi
if [[ -f "$BASE_FILE" ]]; then
    echo "ERROR: $BASE_FILE 已存在 —— 拒绝覆盖" >&2
    exit 1
fi

# 检查 VM 是否在跑——**两道防线**：QMP socket + 进程名。
# 2026-05 修：start-vm.sh -name 改成 "win10-${N}"（去 ryzen3 标签），旧 pgrep
# 模式永远 false → seal 在 VM 还跑时执行 → base 含 dirty NTFS → 所有 clone
# 启动看见 "Preparing Automatic Repair"。
if [[ -S "/tmp/qemu-stealth-${SRC_INSTANCE}.qmp" ]] \
   || pgrep -f "qemu-system-x86.*win10-${SRC_INSTANCE}," >/dev/null \
   || pgrep -f "qemu-system-x86.*win10-ryzen3-${SRC_INSTANCE}," >/dev/null; then
    echo "ERROR: instance $SRC_INSTANCE 还在运行" >&2
    echo "  先优雅关机：deploy/scripts/stop-vm.sh $SRC_INSTANCE" >&2
    echo "  或 guest 内 shutdown /s /t 0 + 等 QMP socket 消失：" >&2
    echo "      until [[ ! -S /tmp/qemu-stealth-${SRC_INSTANCE}.qmp ]]; do sleep 1; done" >&2
    exit 1
fi
# 额外保险：检查 qcow2 是否被任何进程持有
if lsof "$SRC_DISK" 2>/dev/null | grep -q .; then
    echo "ERROR: $SRC_DISK 被进程持有；seal 会做出不一致 base" >&2
    lsof "$SRC_DISK" 2>&1 | sed 's/^/    /' >&2
    exit 1
fi

mkdir -p "$BASE_DIR"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
QEMU_IMG="$REPO_ROOT/build/qemu-img"
[[ -x "$QEMU_IMG" ]] || QEMU_IMG=qemu-img

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ----------------------------------------------------------------------
# NVMe 容量护栏（封 base 时 fail-fast，而不是等克隆才 WARN）
#
# clone-from-base.sh 要求克隆出的 profile.NVME_SIZE_BYTES **字节级精确等于** base
# 虚拟容量（base 的 NTFS 只覆盖 base 容量，clone 盘大了尾段没分区 / 小了越界）。
# 它靠"重抽 profile 最多 100 次直到匹配"实现——但前提是 NVME_POOL 里**确实存在**
# 一个该容量的型号。若不存在，100 次全落空，fallback 成 size 矛盾的 profile
# → guest 进 "Preparing Automatic Repair" + 反作弊看到"型号容量≠裸盘容量"。
# 与其等到克隆时才 WARN，不如现在就拦下：base 一旦封死，后面每次克隆都中招。
# ----------------------------------------------------------------------
source "$SCRIPT_DIR/stealth-lib.sh"   # 取 NVME_POOL（库顶部纯定义，无副作用）
BASE_BYTES=$("$QEMU_IMG" info --output=json "$SRC_DISK" \
    | python3 -c 'import sys, json; print(json.load(sys.stdin)["virtual-size"])')
echo ">> base 虚拟容量: $BASE_BYTES bytes ($(numfmt --to=iec --suffix=B "$BASE_BYTES"))"

_nvme_match=()
for _e in "${NVME_POOL[@]}"; do
    IFS='|' read -r _m _fw _sz <<<"$_e"
    [[ "$_sz" == "$BASE_BYTES" ]] && _nvme_match+=("$_m")
done
if (( ${#_nvme_match[@]} == 0 )); then
    echo "ERROR: NVME_POOL 里没有容量 == ${BASE_BYTES} bytes 的型号" >&2
    echo "  → clone-from-base.sh 配不出匹配 profile，会做出 size 矛盾的 base，拒绝继续。" >&2
    echo "  池里现有容量：" >&2
    for _e in "${NVME_POOL[@]}"; do
        IFS='|' read -r _m _fw _sz <<<"$_e"
        printf '    %-34s %s bytes (%s)\n' "$_m" "$_sz" "$(numfmt --to=iec --suffix=B "$_sz")" >&2
    done
    echo "  修法：往 deploy/scripts/stealth-lib.sh 的 NVME_POOL 加一条容量 == base 的型号，" >&2
    echo "       或把 base 重建成池里已有的容量后重封。" >&2
    exit 1
fi
echo ">> NVMe 容量护栏 ✓ 池里 ${#_nvme_match[@]} 个型号匹配该容量: ${_nvme_match[*]}"

# 先清腾讯/WeGame 设备身份，再 convert —— 这样 base 天生干净且仍然压缩紧凑。
# 失败就 abort：宁可不出 base，也不出一个所有 clone 共享同一 qimei 的"漏指纹" base。
if (( CLEAN )); then
    echo ">> 清理源 disk 的腾讯/WeGame 设备身份（qimei / 登录态 / SDK 缓存 + 注册表）..."
    if ! sudo "$SCRIPT_DIR/host-clean-tencent.sh" "$SRC_INSTANCE" --disk "$SRC_DISK" 2>&1 | sed 's/^/    /'; then
        echo "ERROR: 腾讯身份清理失败 —— 拒绝产出可能泄露 qimei 的 base" >&2
        echo "  排查 host-clean-tencent.sh 后重跑；确认无需清理时加 --no-clean" >&2
        exit 1
    fi
else
    echo ">> --no-clean：跳过腾讯身份清理（源 disk 原样固化为 base）"
fi

echo ">> 源 disk: $SRC_DISK ($(numfmt --to=iec --suffix=B "$(stat -c%s "$SRC_DISK")"))"
echo ">> 目标 base: $BASE_FILE"
echo ">> qemu-img convert (compress=on，把稀疏 qcow2 重写为更紧凑的形式)..."
"$QEMU_IMG" convert -p -O qcow2 -c "$SRC_DISK" "$BASE_FILE"

# 设为只读防止误改
chmod 0444 "$BASE_FILE"

echo ""
echo "=== Done ==="
echo "  base 镜像: $BASE_FILE"
echo "  size:     $(numfmt --to=iec --suffix=B "$(stat -c%s "$BASE_FILE")")"
echo ""
echo "下一步 — 用 clone-from-base.sh 创建新 instance:"
echo "  deploy/scripts/clone-from-base.sh $BASE_NAME <NEW_INSTANCE>"
