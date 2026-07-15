# install-stealth-guest.ps1 —— 已退役的深层自签 guest 安装入口。
#
# 历史实现会写根证书、替换 bootmgfw、安装 EfiGuard/patched driver，并投放依赖真实
# NVIDIA 运行时的旧转发器。当前浅层模式只允许统一 EXE 发布固定摘要的独立用户态
# shim；保留本文件仅用于阻止旧深层命令继续执行。
$ErrorActionPreference = 'Stop'

throw @'
install-stealth-guest.ps1 已退役，未修改系统。
请改用 deploy/guest-stealth/dist/respawn-stealth.exe；它只接受物理 1AF4:1050、
使用 Microsoft WHCP stock VioGpuDod，并发布固定摘要的双架构用户态 NVAPI。
'@
