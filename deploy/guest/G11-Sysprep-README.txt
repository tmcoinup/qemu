VMate G-11 模板封装工具
========================

1. 先在模板 Windows 中安装并验收原版生产签名 GRID 538.33 驱动及所需软件，
   并保留一个日常使用的有密码本地管理员账户。
2. 打开“Windows 安全中心 → 病毒和威胁防护 → 管理设置”，手工关闭“篡改防护”。
   Seal 会只读检查这个状态；它不会修改 Defender 注册表、ACL 或绕过安全中心。
3. 不要运行 VgpuPortable.exe，也不要运行 Standalone-GuestLite 目录里的
   G11GuestLite.exe；前者会在每台克隆第一次启动时自动运行一次，Guest Lite 则由
   Finalize-Clone.ps1 自动应用。模板阶段提前运行会污染克隆的首次运行/回滚基线。
   如果本次用的是“首次初始化在系统 NVAPI 前失败”的实验克隆，Seal 会按保存的
   基线自动回滚 Guest Lite/性能状态并清理旧错误；不要手工删除 state.json。
4. 已经完成系统 NVAPI 初始化的克隆不能直接变成母盘；该投影绑定 VM UUID/profile，
   Seal 会拒绝。应改用尚未进入该阶段的实验克隆，或先通过原投影包完整卸载、重启
   并验证后再封装。
5. 把完整工具包放在 C:\G11SysprepKit；不要放进 C:\ProgramData\VMate\G11 或其
   子目录。右键“以管理员身份运行” Seal-G11-Template.cmd。
6. 确认后依次执行：只读模板门禁 → 按原基线回滚并清理克隆状态 → 把 Payload 中的
   Finalize、Retry 和 Guest Lite 归集到 C:\ProgramData\VMate\G11 →
   Sysprep /generalize /oobe /shutdown。任一步失败都不会启动 Sysprep。
7. 关机后不要再启动模板；回宿主运行 build-g11-private-base.sh。

package-g11-sysprep-kit.sh 一次编译并生成这个完整的公开、无凭据目录，其中已经归集：

- Seal-G11-Template.cmd 和 g11-sysprep-clone.xml；
- Assert-G11-Template-Ready.ps1（只读检查篡改防护和 VM 绑定投影）；
- Reset-G11-Template-State.ps1 与 Template-Reset（按保存基线安全回滚实验状态）；
- Collect-Sysprep-Diagnostics.ps1（Sysprep 失败时只读收集原因）；
- Payload\Finalize-Clone.ps1、Payload\Retry-Clone-Initialization.cmd；
- Payload\GuestLite 下经 clone-manifest.json 固定校验的自动首启载荷；
- Standalone-GuestLite\G11GuestLite.exe（仅供其他已有 Windows 手工使用）。

这个公开目录仍不含授权 VgpuPortable.exe 或 token。模板执行 Seal 后，还必须由宿主
运行 build-g11-private-base.sh（或私有 installer），给关机镜像注入授权 EXE，并再次
校验/刷新公开首启载荷。完成这两步后，每台克隆首次登录会自动运行，无需双击
Guest Lite，也不需要手工复制 Finalize 或 Retry。

应答文件会隐藏 OOBE 页面，但不会跳过 generalize。每台克隆仍会生成独立的
Windows SID、MachineGuid 和计算机名。不会启用 testsigning/nointegritychecks，
不会修改 BCD，也不会安装测试签名或自签名内核驱动。
无人值守只临时使用本机控制台空密码 Administrator；成功前会清除自动登录并禁用
该内置账户，不会把空密码管理员留给最终用户。
每 VM 系统 NVAPI 包由 VMate 克隆时自动生成并以只读光盘临时挂载；模板里不要
预放或手工运行 package-system-nvapi-projection.sh 的旧产物。

应答文件把 US 键盘设为第一输入、Microsoft Pinyin 设为第二输入。US 键盘是 Windows
10 自带组件，所以该输入需求可完全离线封装，不需要 en-US 显示语言 CAB；系统界面仍
保持 zh-CN。Guest Lite 2.6 会再次核验这个顺序、关闭通知、把默认播放端点静音，
开启游戏模式/关闭 Game DVR、设置高性能电源/NVIDIA 最高性能/DNF High，并保存
schema 6 回滚基线；超过 24 小时的固定 Temp 文件会安全清理且不能回滚。

如果 Sysprep 校验失败，Seal 会自动在工具包根目录生成并打开
Sysprep-Diagnostics.txt。错误 0x800F0975 表示 Windows Update/组件维护仍在使用
Reserved Storage：安装全部 Windows 更新、正常重启，重复到没有更新或重启待处理，
再重新运行 Seal。不要通过修改 ReserveManager/Sysprep 注册表状态来强行绕过。
