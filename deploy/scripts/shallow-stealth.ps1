# shallow-stealth.ps1 —— 已退役的 HTTP 流式安装入口。
#
# 旧脚本会从 host 下载松散驱动/脚本，并只写 x64 nvapi64.dll，既缺 GPU-Z 2.70
# PE32 主程序所需的 SysWOW64\nvapi.dll，也没有当前摘要与双架构事务保护。继续使用
# 会造成混版，因此这里只做明确拒绝。
$ErrorActionPreference = 'Stop'

throw @'
shallow-stealth.ps1 已退役，未修改系统。
请在 host 运行 deploy/guest-stealth/package.sh，只把 dist/respawn-stealth.exe
拷入 Windows 后本地运行。当前流程只发布固定摘要双架构用户态 DLL，不使用自签驱动。
'@
