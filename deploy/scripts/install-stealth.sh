#!/usr/bin/env bash
# install-stealth.sh —— 已退役的深层/自签 host 安装入口。
#
# 历史版本会上传伪 CA、patched viogpudo 与 EfiGuard，然后打开已删除的深层
# 重启 QEMU。该流程会改变物理 PCI 主 ID，并向 guest 安装系统级组件，已经与当前
# “物理 1AF4:1050 + stock VioGpuDod + 固定摘要用户态 NVAPI”契约冲突。
#
# 本文件故意 fail-fast，而不是静默转调或继续兼容旧参数。统一离线 EXE 需要在
# Windows 本地完成 UAC、驱动重启闭环与显示模式验收；从 host SSH 偷跑会掩盖这些
# 交互边界。保留文件名只为给旧自动化提供明确迁移诊断。
set -euo pipefail

cat >&2 <<'EOF'
ERROR: deploy/scripts/install-stealth.sh 已退役，未对 host 或 guest 做任何修改。

当前浅层流程：
  1. bash deploy/guest-stealth/package.sh
  2. 只把 deploy/guest-stealth/dist/respawn-stealth.exe 拷入 Windows
  3. 在 Windows 本地运行该 EXE；clone 首登使用 --firstlogon

禁止继续使用伪 CA、EfiGuard、patched driver、GPU_SELFSIGNED 深层开关或旧 NVAPI 转发器。
详见 deploy/guest-stealth/README.md。
EOF
exit 64
