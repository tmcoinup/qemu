G-11 Guest 启动/运行优化（native SDL/GTK）
================================================

适用：start-vm.sh 默认、--sdl、--gtk、--vgpu-sdl、--vgpu-gtk。
不适用：--legacy-shmem / --rdp。旧 relay 模式仍需要 NvDisplayContainer；
如果以后要改回旧模式，请先运行 04-Rollback.cmd。

日常只记一个文件：VgpuPortable.exe

1. 双击 VgpuPortable.exe，UAC 点“是”。
2. 等待窗口同时完成显卡身份/授权和推荐性能优化。
3. 看到最终 INSTALL PASS 后，从 Windows 开始菜单选择“关机”。不要睡眠或休眠。
4. 宿主正常冷启动 VM。

下面四个 cmd 是维护入口，日常不需要运行：

- 01-Audit.cmd：只生成诊断报告，不改设置；
- 02-Apply-Recommended.cmd：仅用于仍持有旧版 VgpuPortable.exe 的 VM；
- 03-Verify.cmd：支持人员要求复验时才运行；
- 04-Rollback.cmd：效果不满意或要恢复 legacy-shmem/RDP 时运行。

新版 VgpuPortable.exe 首次执行后，会把维护工具自动保存到：
C:\ProgramData\G11GuestPerformance\tools

推荐优化会做什么：

- 禁用（不删除）仓库旧 RDP/ivshmem 路径的抓屏 relay 服务与开机/登录任务；
- 停止旧 NvStreamSvc/AudioSvcHost 抓屏进程；
- 保留正式 GRID 驱动、license 和官方 NVDisplay.ContainerLocalSystem；
- 取消 Explorer 对开机启动软件的人为延迟；
- 使用 Windows 内置“高性能”电源计划（系统存在时）；
- 将该计划的显示器超时和系统空闲睡眠（交流/电池）设为“从不”，防止无人操作后 guest 自己黑屏；
- 关闭重复的 guest Game DVR 和部分桌面动画，DGame/QEMU host 画面不受影响；
- 生成开机事件、启动项和 3 秒 CPU 采样报告。

明确不会做什么：

- 不修改 BCD；
- 不开启 testsigning/nointegritychecks；
- 不安装、替换或签名任何内核驱动；
- 不关闭 Defender、Windows Update、SysMain、Windows Search 或分页文件；
- 不删除服务、计划任务或程序文件；
- 不保存任何宿主机凭据。

报告目录：C:\ProgramData\G11GuestPerformance\reports
回滚状态：C:\ProgramData\G11GuestPerformance\state.json
