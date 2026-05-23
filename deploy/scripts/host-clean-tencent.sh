#!/usr/bin/env bash
# host-clean-tencent.sh — 离线清空 Win10 guest 里的腾讯/WeGame 身份缓存，
# 让一份镜像可以当"多 DNF" base 克隆：每台 clone 首启按自己的随机硬件重新
# 生成设备指纹，而不是共享 base 里那一份。
#
# 为什么必须清（跨 clone 关联向量）：
#   - %AppData%\Roaming\Tencent\qimei\   = 腾讯跨 App **设备唯一 ID**（QIMEI）。
#     base 不清 → 所有 clone 上报同一个 qimei → ACE/WeGame 直接判同机/多开。
#   - CTLogin / TXSSO / WGLogin / TCLSCore / libsdk = 登录态 / SSO token / SDK
#     设备缓存；rail / WeGame(Local) / ConnectedDevicesPlatform 同理。
#   - D3DSCache = 绑 GPU 的 shader 缓存，GPU 每台 clone 随机，留着既不匹配也是
#     "多机同缓存"的尾巴。
#   注册表里还有一份镜像（HKCU\Software\Tencent + HKLM\SOFTWARE\[WOW6432Node\]
#   Tencent），不删的话 qimei 会从注册表恢复而不是按新硬件重算 —— 一起删。
#
# **不碰**的东西（避免破坏功能 / 反作弊语义）：
#   - AntiCheatExpert(ACE)：ACE 每次启动按硬件 live 生成指纹，删它的程序/状态会
#     要求重下、且可能破坏 ACE 完整性（见 feedback_no_driver_mod_ace）。
#   - AppData\...\Microsoft：shell/字体/.NET 等 per-user 必需状态，整删会坏配置。
#
# 纯离线：qemu-nbd 直接读写 qcow2，不连 guest、不联网。要 root 仅因 nbd/mount NTFS。
# 离线改 hive **不 truncate .LOG1/.LOG2**（truncate 会让 winload reject hive →
# 0xc0000001 reboot loop，见 host-inject-runonce.sh 的废弃教训）；只做 header
# pre-fixup 让 hivex 能打开，删键后 hivex commit 自己同步 seq/checksum。
#
# Prereqs (apt 一行装齐)：
#   sudo apt install -y qemu-utils ntfs-3g python3-hivex
#
# 用法：
#   sudo deploy/scripts/host-clean-tencent.sh <INSTANCE> [--dry-run] [--no-registry]
#   sudo deploy/scripts/host-clean-tencent.sh <INSTANCE> --disk /path/to/disk.qcow2
#
# 环境/flag：
#   --disk <path> | DISK=<path>   指定 qcow2（默认 vms/<N>/disk.qcow2，回退旧布局）
#   --dry-run                     只打印将删的东西，不动盘
#   --no-registry                 只删文件缓存，不动注册表 hive
#   NBD=/dev/nbdN                 默认 /dev/nbd0
#   MOUNT=<path>                  默认 /mnt/win10-inst<N>
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must be run as root. Try: sudo $0 $*" >&2
    exit 1
fi

INSTANCE="${1:-}"
shift || true
if [[ -z "$INSTANCE" || ! "$INSTANCE" =~ ^[0-9]+$ ]]; then
    echo "usage: $0 <INSTANCE> [--dry-run] [--no-registry] [--disk <path>]" >&2
    exit 2
fi

DRY=0
DO_REG=1
CLI_DISK=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)     DRY=1 ;;
        --no-registry) DO_REG=0 ;;
        --disk)        CLI_DISK="${2:-}"; shift ;;
        --disk=*)      CLI_DISK="${1#*=}" ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
    shift
done

VM_DIR="/home/ubuntu/images/vms/${INSTANCE}"
if [[ -n "$CLI_DISK" ]]; then
    DISK="$CLI_DISK"
elif [[ -n "${DISK:-}" ]]; then
    DISK="$DISK"
elif [[ -f "${VM_DIR}/disk.qcow2" ]]; then
    DISK="${VM_DIR}/disk.qcow2"
else
    DISK="/home/ubuntu/images/win10-inst${INSTANCE}.qcow2"
fi
: "${NBD:=/dev/nbd0}"
: "${MOUNT:=/mnt/win10-inst${INSTANCE}}"

log() { printf '[clean-tencent] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

MISSING=()
command -v qemu-nbd >/dev/null || MISSING+=("qemu-utils")
command -v ntfsfix  >/dev/null || MISSING+=("ntfs-3g")
python3 -c 'import hivex' 2>/dev/null || MISSING+=("python3-hivex")
if (( ${#MISSING[@]} > 0 )); then
    log "缺以下 apt 包：${MISSING[*]}"
    log "一行装齐： sudo apt install -y ${MISSING[*]}"
    exit 1
fi

[[ -f "$DISK" ]] || die "disk not found: $DISK"
log "disk: $DISK"
(( DRY )) && log "*** DRY-RUN：只打印不删 ***"

# ----------------------------------------------------------------------
# 挂载（套路同 host-fix-gpu-devpkey.sh：nbd + ntfsfix + ntfs-3g rw）
# ----------------------------------------------------------------------
modprobe nbd max_part=16 2>/dev/null || true
cleanup() {
    local rc=$?
    umount "$MOUNT" 2>/dev/null || true
    qemu-nbd --disconnect "$NBD" 2>/dev/null || true
    exit $rc
}
trap cleanup EXIT

log "attaching $DISK to $NBD"
qemu-nbd --connect="$NBD" --format=qcow2 "$DISK"
sleep 1

SYSPART=""
for p in "${NBD}p3" "${NBD}p4" "${NBD}p2" "${NBD}p1"; do
    [[ -b "$p" ]] || continue
    if blkid -o value -s TYPE "$p" 2>/dev/null | grep -q '^ntfs$'; then
        SYSPART="$p"; break
    fi
done
[[ -n "$SYSPART" ]] || die "no NTFS partition found under $NBD"
log "system partition: $SYSPART"

mkdir -p "$MOUNT"
ntfsfix --clear-dirty "$SYSPART" >/dev/null
MOUNT_ERR=$(mktemp)
if ! mount -t ntfs-3g -o rw,remove_hiberfile "$SYSPART" "$MOUNT" 2> "$MOUNT_ERR"; then
    cat "$MOUNT_ERR" >&2
    if grep -q "hibernated" "$MOUNT_ERR"; then
        cat >&2 <<'EOF'

[clean-tencent] ⚠ Windows 处于 Fast Startup（混合关机）状态，hiberfil.sys 阻止 RW 挂载。
[clean-tencent] 永久修复（只需一次）：guest 内管理员 PowerShell 跑：
[clean-tencent]   powercfg -h off
[clean-tencent]   shutdown /s /t 0
[clean-tencent] 再 host 重跑本脚本。
EOF
    fi
    rm -f "$MOUNT_ERR"
    exit 1
fi
rm -f "$MOUNT_ERR"

# ----------------------------------------------------------------------
# 1) 文件缓存删除
# ----------------------------------------------------------------------
DELETED=0
rm_target() {
    local t="$1" kind="${2:-dir}"
    if [[ ! -e "$t" ]]; then
        return 0
    fi
    local sz
    sz=$(du -sh "$t" 2>/dev/null | cut -f1 || echo "?")
    log "  删 [$sz] ${t#$MOUNT}"
    if (( ! DRY )); then
        rm -rf -- "$t"
    fi
    DELETED=$((DELETED+1))
}

log "=== 文件缓存 ==="
shopt -s nullglob
PROFILE_DIRS=()
for d in "$MOUNT"/Users/*/; do
    [[ -d "$d" ]] || continue
    case "$(basename "$d")" in
        "All Users"|"Default User"|"Public") continue ;;
    esac
    PROFILE_DIRS+=("$d")
done

for prof in "${PROFILE_DIRS[@]}"; do
    log "profile: ${prof#$MOUNT}"
    rm_target "${prof}AppData/Roaming/Tencent"
    rm_target "${prof}AppData/Local/WeGame"
    rm_target "${prof}AppData/Local/rail"
    rm_target "${prof}AppData/Local/RailCrashReport"
    rm_target "${prof}AppData/Local/ConnectedDevicesPlatform"
    rm_target "${prof}AppData/Local/D3DSCache"
    # Temp：整个 Temp 删掉，Windows 首启自动重建（顺手清掉 WeGame 安装残留临时文件）
    rm_target "${prof}AppData/Local/Temp"
done

# 机器级
rm_target "$MOUNT/ProgramData/Tencent"
rm_target "$MOUNT/ProgramData/WeGame"

log "文件删除项：$DELETED"

# ----------------------------------------------------------------------
# 2) 注册表 Tencent 键删除（best-effort，不阻塞文件清理结果）
# ----------------------------------------------------------------------
if (( DO_REG )); then
    log "=== 注册表 Tencent 键 ==="

    # hive header pre-fixup：同步 seq + 拉齐 end_of_last_page + 重算 checksum，
    # 让 libhivex 能打开 cold-shutdown 的 hive（逻辑同 host-fix-gpu-devpkey.sh）。
    pre_fixup() {
        python3 - "$1" <<'PY' || true
import struct, sys
path = sys.argv[1]
HBIN_BASE = 0x1000
try:
    with open(path, 'r+b') as f:
        data = bytearray(f.read())
except OSError as e:
    sys.exit(0)
if data[:4] != b'regf':
    sys.exit(0)
pri = struct.unpack_from('<I', data, 4)[0]
sec = struct.unpack_from('<I', data, 8)[0]
eolp = struct.unpack_from('<I', data, 0x28)[0]
if pri != sec:
    newseq = max(pri, sec)
    struct.pack_into('<I', data, 4, newseq)
    struct.pack_into('<I', data, 8, newseq)
off = HBIN_BASE; last_end = HBIN_BASE
while off < len(data):
    if bytes(data[off:off+4]) != b'hbin':
        break
    hbin_size = struct.unpack_from('<I', data, off + 8)[0]
    if hbin_size == 0 or off + hbin_size > len(data):
        break
    last_end = off + hbin_size; off += hbin_size
actual = last_end - HBIN_BASE
if eolp > actual:
    struct.pack_into('<I', data, 0x28, actual)
csum = 0
for i in range(0, 0x1fc, 4):
    csum ^= struct.unpack_from('<I', data, i)[0]
struct.pack_into('<I', data, 0x1fc, csum)
with open(path, 'wb') as f:
    f.write(data)
PY
    }

    # 删指定 hive 下的若干键路径（'\' 分隔）。DRY=1 只报告。
    del_keys() {
        local hive="$1"; shift
        [[ -f "$hive" ]] || { log "  (跳过，hive 不存在: ${hive#$MOUNT})"; return 0; }
        (( DRY == 0 )) && pre_fixup "$hive"
        DRY="$DRY" HIVE="$hive" KEYS="$*" python3 - <<'PY' || log "  WARN: hivex 处理失败（文件已删，注册表残留不致命，guest 首启会重建）: ${HIVE#$MOUNT}"
import hivex, os, sys
hive = os.environ['HIVE']
dry  = os.environ.get('DRY') == '1'
keys = os.environ['KEYS'].split('|')
h = hivex.Hivex(hive, write=not dry)
root = h.root()
removed = 0
for keypath in keys:
    parts = [p for p in keypath.split('\\') if p]
    node = root
    ok = True
    for p in parts[:-1]:
        nxt = h.node_get_child(node, p)
        if nxt is None:
            ok = False; break
        node = nxt
    if not ok:
        continue
    child = h.node_get_child(node, parts[-1])
    if child is None:
        continue
    print(f'  {"[dry] " if dry else ""}删键: {keypath}')
    if not dry:
        h.node_delete_child(child)
        removed += 1
if removed and not dry:
    h.commit(None)
PY
    }

    # HKLM\SOFTWARE：Tencent + 32 位重定向 WOW6432Node\Tencent
    del_keys "$MOUNT/Windows/System32/config/SOFTWARE" \
        'Tencent|WOW6432Node\Tencent'

    # HKCU：每个用户 profile 的 NTUSER.DAT → Software\Tencent
    for prof in "${PROFILE_DIRS[@]}"; do
        [[ -f "${prof}NTUSER.DAT" ]] || continue
        log "  NTUSER: ${prof#$MOUNT}"
        del_keys "${prof}NTUSER.DAT" 'Software\Tencent'
    done
else
    log "=== 注册表：--no-registry，跳过 ==="
fi

log "done. base 现在不含腾讯设备身份；每台 clone 首启按自己硬件重建 qimei。"
