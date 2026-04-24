#!/usr/bin/env bash
#
# restore.sh — 从 baseline 快照恢复 vm1 的 qcow2。
#
# 常见触发场景:
#   - guest 挂在 bootmgr spinner 死循环（driver 重装 + Fast Startup 交互坏了）
#   - 一次调试改崩了 Windows 注册表，想回滚
#   - 只是想做完改动后回到干净态再试别的
#
# 前置: ./down.sh 保证 VM 已经关掉（否则覆盖盘会坏数据）。
#
set -euo pipefail

QCOW_LIVE=/home/ubuntu/images/vms/win10-vm1.qcow2
QCOW_OK=/home/ubuntu/images/vms/win10-ok.qcow2

if pgrep -f 'qemu-system-x86_64.*vm1\b' >/dev/null; then
    echo "[restore] vm1 QEMU 还在跑，先 ./down.sh --force"
    exit 1
fi

if [[ ! -f "$QCOW_OK" ]]; then
    echo "[restore] baseline $QCOW_OK 不存在 — 现在没救援镜像可用"
    exit 1
fi

echo "[restore] backing up current broken qcow2 to .broken-<ts>"
mv "$QCOW_LIVE" "${QCOW_LIVE}.broken-$(date +%s)"
echo "[restore] cp --reflink=auto $QCOW_OK -> $QCOW_LIVE"
cp --reflink=auto "$QCOW_OK" "$QCOW_LIVE"
ls -la "$QCOW_LIVE" "${QCOW_LIVE}.broken-"*
echo "[restore] done. ./up.sh --rdp 启动。"
