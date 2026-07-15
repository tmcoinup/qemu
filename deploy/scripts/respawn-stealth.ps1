# respawn-stealth.ps1 —— 已退役的 clone HTTP/RunOnce 入口。
#
# clone 现在固定从 D:\工具\respawn-stealth.exe 运行经过整包校验的 payload。旧 HTTP
# 入口无法保证 apply/helper/DLL 同版，也会让提权脚本受网络和用户可写目录影响。
$ErrorActionPreference = 'Stop'

throw @'
respawn-stealth.ps1 已退役，未修改系统。
请更新 D:\工具\respawn-stealth.exe；clone 首次登录使用 --firstlogon。
不要恢复 HTTP RunOnce 或松散脚本下载链。
'@
