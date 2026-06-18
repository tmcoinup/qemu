#!/usr/bin/env bash
# clone-from-base.sh —— 用 _base/ 里的某个基础镜像快速创建一个新 instance。
#
# 用法：
#   deploy/scripts/clone-from-base.sh <BASE_NAME> <NEW_INSTANCE>
#
# 例：
#   deploy/scripts/clone-from-base.sh win10-ltsc-shallow 4
#       -> /home/ubuntu/images/vms/4/disk.qcow2 (qcow2 backed by base)
#       -> /home/ubuntu/images/vms/4/profile (重新随机硬件身份)
#
# 工作机制：
#   - qcow2 backing-file: 新 disk 只存增量，base 共享只读
#   - profile 一定是新随机的（CPU/主板/GPU/MAC/UUID/NVMe SN 全部新），
#     这样多份克隆给反作弊看是各自独立的硬件
#   - OVMF NVRAM 也是从 /usr/share/OVMF/OVMF_VARS_4M.fd 重新拷贝
#
# 之后启动：
#   DISPLAY=:1 deploy/scripts/start-vm.sh <NEW_INSTANCE>

set -euo pipefail

# 必须 root：脚本最后两步 (host-fix-gpu-devpkey / host-inject-runonce) 要挂 NTFS。
# 没 root 跑完后用户得手动补跑这两步，容易漏；改成强制提示。
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: 必须以 root 运行（脚本末尾要挂 NTFS 写 hive）" >&2
    echo "" >&2
    echo "  sudo $0 $*" >&2
    echo "" >&2
    exit 1
fi

BASE_NAME="${1:-}"
NEW_INSTANCE="${2:-}"

if [[ -z "$BASE_NAME" || -z "$NEW_INSTANCE" ]]; then
    echo "usage: $0 <BASE_NAME> <NEW_INSTANCE>" >&2
    echo "" >&2
    echo "可用 base:" >&2
    ls /home/ubuntu/images/vms/_base/*.qcow2 2>/dev/null | sed 's|.*/||;s|\.qcow2$||;s|^|  - |' >&2
    exit 2
fi
if ! [[ "$NEW_INSTANCE" =~ ^[0-9]+$ ]]; then
    echo "ERROR: NEW_INSTANCE 必须是正整数" >&2
    exit 2
fi

BASE_FILE="/home/ubuntu/images/vms/_base/${BASE_NAME}.qcow2"
if [[ ! -f "$BASE_FILE" ]]; then
    echo "ERROR: $BASE_FILE 不存在" >&2
    exit 1
fi

VM_DIR="/home/ubuntu/images/vms/${NEW_INSTANCE}"
DISK="$VM_DIR/disk.qcow2"
PROFILE="$VM_DIR/profile"
OVMF_VARS="$VM_DIR/ovmf-vars.fd"

if [[ -e "$DISK" ]]; then
    echo "ERROR: instance $NEW_INSTANCE 的 disk.qcow2 已存在 —— 拒绝覆盖" >&2
    echo "  如要重建，先 rm -rf $VM_DIR" >&2
    exit 1
fi

mkdir -p "$VM_DIR"

# sudo 跑完文件默认 root:root，普通用户读不了 profile，
# 也写不了 OVMF NVRAM。
# 用 EXIT trap 兜底 chown：无论后面哪步失败 abort，
# 都保证退出前把 vms/<N>/ 归还执行 sudo 的原用户。
# 历史 bug：devpkey 失败后 set -e+pipefail 中途退出，
# 跳过末尾 chown，留下 root:root，
# start-vm.sh 报 "profile: Permission denied"。
ORIG_USER="${SUDO_USER:-ubuntu}"
ORIG_GROUP="$(id -gn "$ORIG_USER" 2>/dev/null || echo "$ORIG_USER")"
trap 'chown -R "${ORIG_USER}:${ORIG_GROUP}" "$VM_DIR" 2>/dev/null || true' EXIT

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
QEMU_IMG="$REPO_ROOT/build/qemu-img"
[[ -x "$QEMU_IMG" ]] || QEMU_IMG=qemu-img

# guest 启动后 FirstLogonCommands Order=10 会去 host 8765 拉 respawn-stealth.ps1
# (apply-gpu-spoof 自动按 PCI subsys 重对齐 GPU 注册表覆盖)。host 重启后这个
# server 容易忘开，连不上就静默 fail。这里检测如果 8765 没监听就在后台起一份。
if ! ss -tln 2>/dev/null | grep -q ':8765\b'; then
    HTTP_SERVE="$REPO_ROOT/deploy/scripts/serve-stealth-http.py"
    if [[ -f "$HTTP_SERVE" ]]; then
        ORIG_USER="${SUDO_USER:-ubuntu}"
        echo ">> 起 stealth HTTP server (8765) 让 guest FirstLogon 能拉 respawn-stealth.ps1"
        sudo -u "$ORIG_USER" nohup python3 "$HTTP_SERVE" 8765 \
            > /tmp/serve-http.log 2>&1 &
        disown 2>/dev/null || true
        sleep 1
    fi
fi

echo ">> base:        $BASE_FILE"
echo ">> 创建增量盘:  $DISK"
"$QEMU_IMG" create -f qcow2 -F qcow2 -b "$BASE_FILE" "$DISK" >/dev/null
ls -la "$DISK"

# 重新随机 stealth 身份（保证 multi-clone 之间硬件 fingerprint 不同）
echo ">> 重新随机 stealth profile..."
source "$(dirname "$0")/stealth-lib.sh"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
QEMU_IMG="$REPO_ROOT/build/qemu-img"
[[ -x "$QEMU_IMG" ]] || QEMU_IMG=qemu-img

# 先读 base 容量，让 pick_profile 重抽 NVMe 直到选定 model 的容量 = base 容量。
# 原因：base 的 NTFS 只覆盖 base 容量；clone 时 qcow2 resize 比 base 大，
# 多出的尾段没分区 → Win 启动看见 "Preparing Automatic Repair"（disk size
# vs partition layout 不一致）。
# 同样地 clone 容量 < base 也不行（NTFS 会指向越界扇区）。所以严格要 ==。
BASE_BYTES=$("$QEMU_IMG" info --output=json "$BASE_FILE" \
    | python3 -c 'import sys, json; print(json.load(sys.stdin)["virtual-size"])')
echo ">> base 容量: $BASE_BYTES bytes ($(numfmt --to=iec --suffix=B $BASE_BYTES))"

# 最多 100 次重抽——理论上 NVMe pool 里至少 1 条跟 base 容量匹配的 model
for _i in $(seq 1 100); do
    stealth_pick_profile
    if [[ "${NVME_SIZE_BYTES:-0}" == "$BASE_BYTES" ]]; then
        echo ">> profile NVMe = $NVME_MODEL (size $NVME_SIZE_BYTES) ✓ 匹配 base"
        break
    fi
done
if [[ "${NVME_SIZE_BYTES:-0}" != "$BASE_BYTES" ]]; then
    echo ">> WARN: NVMe pool 里找不到容量 = $BASE_BYTES bytes 的 model"
    echo "        NTFS 不一致，guest 可能进 Automatic Repair。建议检查 NVME_POOL 是否含该容量"
fi

stealth_save_profile "$PROFILE"
echo ">> profile -> $PROFILE"
stealth_print_profile 2>&1
# pick 已经 export 全部字段；下面 qcow2 resize 直接读 $NVME_SIZE_BYTES / $NVME_MODEL

# 从 stock OVMF 模板拷一份新 NVRAM
OVMF_TEMPLATE=/usr/share/OVMF/OVMF_VARS_4M.fd
if [[ -f "$OVMF_TEMPLATE" ]]; then
    cp "$OVMF_TEMPLATE" "$OVMF_VARS"
    echo ">> OVMF NVRAM -> $OVMF_VARS"
fi

# --- 1) qcow2 resize：profile NVMe 跟 base 容量已经在上面 pick 阶段强制对齐。
#        正常路径不应再 resize（== base）；保险起见还是判一下 ---
TARGET_BYTES="${NVME_SIZE_BYTES:-$BASE_BYTES}"
if (( TARGET_BYTES != BASE_BYTES )); then
    echo ">> WARN: profile NVMe (${TARGET_BYTES}) != base (${BASE_BYTES})"
    echo "        guest 启动可能 Automatic Repair（NTFS partition 跟 disk size 错位）"
    echo "        如启动报错，删 VM<N> 重 clone（pick 会再次尝试匹配 base 容量）"
fi
# 不 resize qcow2 —— 增量层容量 == base 容量，保持 NTFS 一致

# --- 2) DEVPKEY 修复：新 profile 的 GPU subsys 在 base 注册表里没覆盖；
#        offline 写 hive 让设备管理器立刻显示新 GPU 名 + Provider=NVIDIA/AMD
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEVPKEY_FIX="$SCRIPT_DIR/host-fix-gpu-devpkey.sh"
if [[ -x "$DEVPKEY_FIX" ]]; then
    echo ">> 重写 DEVPKEY DriverProvider / DeviceDesc（用新 profile.GPU_*）..."
    if [[ $EUID -eq 0 ]]; then
        # 非致命：失败也不能 abort 整个 clone。
        # 否则会跳过后面的 unattend 注入和 chown，
        # 留下 root:root 且没注入 OOBE unattend 的半成品 VM。
        # GPU DEVPKEY 即便没离线写入，首启脚本也会按新
        # PCI subsys 重对齐 GPU 注册表。
        if ! "$DEVPKEY_FIX" "$NEW_INSTANCE" 2>&1 | sed 's/^/    /'; then
            echo "   WARN: host-fix-gpu-devpkey.sh 失败"
            echo "         非致命，继续 clone。"
            echo "         GPU 名首启由 respawn-stealth.ps1"
            echo "         兜底重对齐。"
            echo "         若反复失败，多半是 base 处于"
            echo "         Fast Startup/hiberfile。"
            echo "         在 base 内 powercfg -h off 一次即可修复。"
        fi
    else
        echo ">> 需 sudo 权限挂 NTFS；执行： sudo $DEVPKEY_FIX $NEW_INSTANCE"
        echo "   或者先用 sudo 运行 clone-from-base.sh"
    fi
fi

# --- 3) NumLock 修复：sysprep generalize 会把 .DEFAULT hive 的
#        InitialKeyboardIndicators 重置成 0x80000000（启动主动写 LED=OFF）。
#        host-fix-numlock.sh 离线把它改回 0x80000002（LED=ON）。
NUMLOCK_FIX="$SCRIPT_DIR/host-fix-numlock.sh"
if [[ -x "$NUMLOCK_FIX" && $EUID -eq 0 ]]; then
    echo ">> 修 NumLock 默认状态（DEFAULT hive InitialKeyboardIndicators=ON）..."
    "$NUMLOCK_FIX" "$NEW_INSTANCE" 2>&1 | sed 's/^/    /' || \
        echo "   WARN: host-fix-numlock.sh 失败，可在 guest 内跑 vm-prep.ps1 兜底"
fi

# --- 4) Unattend 注入：sysprep'd base 首启会进 OOBE 区域设置等交互界面。
#        deploy/autounattend/autounattend.xml 含 SkipMachineOOBE/SkipUserOOBE
#        + AutoLogon Administrator/123456 + ms-gamingoverlay handler 等，
#        放进 %WINDIR%\Panther\Unattend\unattend.xml 让 OOBE 自动跑完直接
#        进 desktop，不用手点。
UNATTEND_INJ="$SCRIPT_DIR/host-inject-unattend.sh"
if [[ -x "$UNATTEND_INJ" && $EUID -eq 0 ]]; then
    echo ">> 注入 OOBE unattend.xml（首启自动以 Administrator 登录进 desktop）..."
    "$UNATTEND_INJ" "$NEW_INSTANCE" 2>&1 | sed 's/^/    /' || \
        echo "   WARN: host-inject-unattend.sh 失败，guest 首启会停在 OOBE"
fi

# --- 5) RunOnce 不再 inject —— SOFTWARE hive 离线写 + .LOG truncate 会被
#        Windows 启动 reject (0xc0000001)。respawn-stealth.ps1 已搬进
#        deploy/autounattend/autounattend.xml 的 FirstLogonCommands Order=10，
#        OOBE 走完 unattend 后第一次 logon 自动跑，不需要动注册表 hive。

# --- 6) 目录所有权由顶部的 EXIT trap 统一 chown 回 ORIG_USER。
#        无论成功还是中途失败，都只在 trap 中处理。
#        这里只打印结果说明，不再重复 chown。
echo ">> 目录所有权将 → ${ORIG_USER}:${ORIG_GROUP}"
echo "   (EXIT trap 兜底，start-vm.sh 可直接非 root 起)"

echo ""
echo "=== Done ==="
echo "  instance:  $NEW_INSTANCE"
echo "  disk:      $DISK (qcow2 backed by base $BASE_NAME)"
echo "  size:      $TARGET_BYTES bytes (Win 看到的容量)"
echo "  GPU 重对齐: respawn-stealth.ps1 经 autounattend FirstLogonCommands 拉起"
echo ""
echo "下一步 — 启动:"
echo "  deploy/scripts/start-vm.sh $NEW_INSTANCE"
echo ""
echo "克隆出的 VM 会复用 base 系统盘内容（Win + shallow stealth + DNF 等），"
echo "硬件身份新（CPU/主板/GPU/MAC/UUID/NVMe SN 全随机），且**首次开机**会自动："
echo "  1. 走 unattend.xml → 跳过 OOBE 区域/账户/EULA 等所有交互"
echo "     → AutoLogon Administrator/123456 直接进 desktop"
echo "  2. FirstLogonCommands → 启 RDP / 关 NLA / 注册 ms-gamingoverlay / 拉 respawn-stealth.ps1"
echo "  3. respawn-stealth.ps1 按新 PCI subsys 选 GPU 名 → 重启"
echo "  4. 重启后设备管理器显示 profile.GPU_NAME（不是 base 那个老型号）"
echo ""
echo "⚠️ 没有 sysprep —— Win SID/MachineGUID 与 base 同源；多机并发跑会有"
echo "   AD/Office 激活冲突。需要彻底新机器请先 sysprep base 再 seal-base.sh。"
