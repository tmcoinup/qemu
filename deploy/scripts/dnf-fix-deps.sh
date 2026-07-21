#!/usr/bin/env bash
# dnf-fix-deps.sh —— host 侧一键：构建独立 dnf-fix-deps.exe 并推到指定 VM 执行
#
# 用途：
#   修复 DNF.exe 启动错误 0xc000007b（缺 VC++ / DirectX 运行库）
#
# 前置条件：
#   - VM 已经跑起来，OpenSSH 服务已起 (vm-bootstrap.ps1 跑过)
#   - Administrator/123456，host 上装了 sshpass
#   - VM 网络通微软下载站（DirectX 使用 June 2010 完整包）
#
# 用法：
#   deploy/scripts/dnf-fix-deps.sh <INSTANCE> [<guest-ip>] [--dry-run]
#
# 示例：
#   deploy/scripts/dnf-fix-deps.sh 1
#   deploy/scripts/dnf-fix-deps.sh 2 192.168.30.144
#   deploy/scripts/dnf-fix-deps.sh 1 --dry-run     # 只打印检测结果
#
# 退出码：
#   0 = 全部成功
#   1 = guest 侧安装器失败（看 C:\ProgramData\VMateDnfDeps\install.log）
#   2 = 参数错误 / 找不到 VM

set -euo pipefail

# ---- 参数解析 ------------------------------------------------------
DRY_RUN=""
POS_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --dry-run|-n) DRY_RUN="--dry-run" ;;
        -h|--help)
            sed -n '2,/^set -euo pipefail$/p' "$0" | sed -e 's/^# \{0,1\}//' -e '/^set -/d' >&2
            exit 0
            ;;
        *) POS_ARGS+=("$arg") ;;
    esac
done

INSTANCE="${POS_ARGS[0]:-}"
GUEST_IP="${POS_ARGS[1]:-}"
if ! [[ "$INSTANCE" =~ ^[1-9][0-9]*$ ]]; then
    echo "usage: $0 <INSTANCE> [<guest-ip>] [--dry-run]" >&2
    exit 2
fi

cd "$(dirname "$0")/../.."   # → qemu 仓库根

QMP="/tmp/qemu-stealth-${INSTANCE}.qmp"
PASS='123456'
PACKAGE_SCRIPT="deploy/guest-dnf-deps/package.sh"
EXE_LOCAL="deploy/guest-dnf-deps/dist/dnf-fix-deps.exe"

if [[ ! -x "$PACKAGE_SCRIPT" ]]; then
    echo "ERROR: 找不到可执行打包入口 $PACKAGE_SCRIPT" >&2
    exit 2
fi
echo ">> 构建当前源码对应的独立 EXE"
"$PACKAGE_SCRIPT"
[[ -s "$EXE_LOCAL" ]] || {
    echo "ERROR: 未生成 $EXE_LOCAL" >&2
    exit 2
}

# ---- 发现 guest IP（复用 install-stealth.sh 的算法）---------------
if [[ -z "$GUEST_IP" ]]; then
    if [[ ! -S "$QMP" ]]; then
        echo "ERROR: $QMP 不存在 —— VM${INSTANCE} 没在跑？" >&2
        echo "提示：先跑 deploy/scripts/start-vm.sh ${INSTANCE}" >&2
        exit 2
    fi
    # 通过 QMP socket 路径定位本实例的 QEMU 进程，再从命令行抓 MAC
    # （比按 name 匹配稳：name 模板可能随版本变，但 QMP socket 名字是约定死的）
    MAC=$(pgrep -af "qemu-stealth-${INSTANCE}\.qmp" 2>/dev/null \
            | head -1 | grep -oE 'mac=[a-f0-9:]+' | head -1 | cut -d= -f2)
    if [[ -z "$MAC" ]]; then
        echo "ERROR: 找不到 instance $INSTANCE 的 MAC，请显式传入 guest-ip" >&2
        exit 2
    fi
    # ARP scan 把 192.168.30/24 全网刷一遍触发邻居发现
    for i in $(seq 30 220); do ping -c 1 -W 1 -n "192.168.30.$i" >/dev/null 2>&1 & done
    wait 2>/dev/null
    sleep 1
    GUEST_IP=$(ip neigh 2>/dev/null | grep "$MAC" | grep -oE '192\.168\.[0-9]+\.[0-9]+' | head -1)
    if [[ -z "$GUEST_IP" ]]; then
        echo "ERROR: ARP 扫描没找到 MAC=$MAC 的 guest，请显式传 IP" >&2
        exit 2
    fi
fi
echo ">> guest IP = $GUEST_IP (instance $INSTANCE)"

GUEST="Administrator@$GUEST_IP"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no -o ConnectTimeout=10)

# ---- 预检：ssh 通不通 ---------------------------------------------
echo ">> [1/4] 测试 SSH"
if ! sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "$GUEST" 'echo UP' 2>/dev/null | grep -q UP; then
    cat >&2 <<EOF
ERROR: SSH 到 $GUEST_IP 失败 —— OpenSSH 没起。

→ 方案 A（推荐，长期）：在 guest 里跑 bootstrap，启用 OpenSSH：
    1. 用 SDL 窗口/RDP 进 VM
    2. PowerShell 管理员：
       irm http://<host-ip>:8765/vm-bootstrap.ps1 | iex

→ 方案 B（一次性）：把下面这个独立 EXE 复制到 guest 后双击：
       $EXE_LOCAL
EOF
    exit 2
fi

# ---- 推送独立 EXE -------------------------------------------------
# 相对 scp 目标落在 Administrator 私有 profile，避免经用户可预创建的公共目录执行。
echo ">> [2/4] 推送独立 EXE 到 Administrator profile"
sshpass -p "$PASS" scp "${SSH_OPTS[@]}" "$EXE_LOCAL" \
    "$GUEST":'dnf-fix-deps.exe' >/dev/null

# ---- 在 guest 执行 ------------------------------------------------
echo ">> [3/4] 执行独立 dnf-fix-deps.exe ${DRY_RUN:+(DryRun)}"
set +e
sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "$GUEST" \
    ".\\dnf-fix-deps.exe --no-confirm $DRY_RUN"
PS_RC=$?
set -e

# ---- 收尾 ----------------------------------------------------------
echo ""
echo ">> [4/4] guest 脚本退出码 = $PS_RC"
if [[ $PS_RC -ne 0 && $PS_RC -ne 194 ]]; then
    echo ">> 失败 —— 拉取 install.log 看详情："
    # shellcheck disable=SC2016
    # $env:ProgramData 必须由 guest PowerShell 展开，不能由 host Bash 展开。
    sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "$GUEST" \
        'powershell -NoProfile -Command "Get-Content $env:ProgramData\VMateDnfDeps\install.log -Tail 50"' 2>/dev/null || true
    exit 1
fi

echo ""
if [[ $PS_RC -eq 194 ]]; then
    echo "=== dnf-fix-deps 安装成功，但 Windows 需要重启（远端退出码 3010）。"
    exit 0
fi
echo "=== dnf-fix-deps 完成。下一步："
echo "   1. 在 VM 里重启 WeGame / DNF"
echo "   2. 若仍 0xc000007b，看 C:\\ProgramData\\VMateDnfDeps\\install.log"
echo "==="
