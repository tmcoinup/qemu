VMate G-11 模板封装工具
========================

1. 先在模板 Windows 中安装并验收原版生产签名 GRID 538.33 驱动及所需软件，
   并保留一个日常使用的有密码本地管理员账户。
2. 不要运行 VgpuPortable.exe；它会在每台克隆第一次启动时自动运行一次，随后
   安装该 VM 专属的 x86/x64 系统 NVAPI，内部重启验证并最终关机。
3. 右键“以管理员身份运行” Seal-G11-Template.cmd。
4. 确认后会执行 Sysprep /generalize /oobe /shutdown。
5. 关机后不要再启动模板；回宿主运行 build-g11-private-base.sh。

应答文件会隐藏 OOBE 页面，但不会跳过 generalize。每台克隆仍会生成独立的
Windows SID、MachineGuid 和计算机名。不会启用 testsigning/nointegritychecks，
不会修改 BCD，也不会安装测试签名或自签名内核驱动。
无人值守只临时使用本机控制台空密码 Administrator；成功前会清除自动登录并禁用
该内置账户，不会把空密码管理员留给最终用户。
每 VM 系统 NVAPI 包由 VMate 克隆时自动生成并以只读光盘临时挂载；模板里不要
预放或手工运行 package-system-nvapi-projection.sh 的旧产物。
