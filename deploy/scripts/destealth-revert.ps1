#Requires -Version 5.1

# destealth-revert.ps1 —— 已退役的历史深层驱动清理入口。
#
# 旧实现会强制卸载所有名为 viogpudo.inf 的驱动包、删除活动 viogpudo.sys 和
# VioGpuDod 服务。当前浅层模式本来就依赖 Microsoft-WHQL stock VioGpuDod；在健康
# 客机运行旧逻辑会把正确驱动一并破坏。深层自签/EfiGuard 路径已经移除，因此不再
# 提供能修改系统的自动回滚脚本。若确有历史深层客机需要迁移，应先离线备份，再按
# deploy/docs/DEBUG.md 的人工诊断结果逐项处理，最后运行最新统一 EXE。

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

throw @'
destealth-revert.ps1 已退役，未修改系统。
它不能用于当前 1AF4:1050 + stock VioGpuDod 浅层模式，否则旧版本会误删健康驱动。
请使用 deploy/guest-stealth/dist/respawn-stealth.exe；历史深层客机须先备份并人工清理。
'@
