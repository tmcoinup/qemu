# G-11 SDL 空闲不黑屏傻瓜教程

本功能只调整 **Linux 宿主机** 的 SDL 屏保/显示器休眠许可。它不修改 Windows
电源计划，不改 BCD，不开启 `testsigning`/`nointegritychecks`，也不安装任何
测试签名或自签名内核驱动。改动只在 G-11 分支；不要把它当作 V-11 的发布物。

## 已封装的默认行为

使用标准入口启动 SDL，不需要额外参数：

```bash
cd /home/ubuntu/projects/qemu
./deploy/scripts/start-vm.sh 9 --sdl
```

把 `9` 换成实际 VM 编号。启动日志必须出现：

```text
[start-vm] SDL 宿主防息屏已启用：窗口空闲不会触发宿主屏保/显示器休眠
```

此后只要该 QEMU SDL 进程仍在运行，SDL 会阻止宿主屏保/DPMS 因空闲把物理显示器
变黑。QEMU 正常退出时会恢复宿主自动息屏资格，不会永久修改 GNOME/KDE 设置。

## 第一次使用：一键构建与检查

在宿主机终端整段复制：

```bash
cd /home/ubuntu/projects/qemu
./deploy/host/build-qemu.sh
bash deploy/tests/qemu/test_sdl_no_sleep_static.sh
```

看到下面成功信息后，关闭旧 QEMU 进程，再从标准入口重新启动 VM：

```text
OK: SDL host-display no-sleep static checks passed
```

只重建但继续观察已经运行的旧 QEMU 进程不会生效。

## 傻瓜式实机验收

1. 用上面的 `start-vm.sh` 启动 VM，并确认日志显示“SDL 宿主防息屏已启用”。
2. 保持 SDL 窗口可见，不碰键盘和鼠标，等待超过宿主原来的自动息屏时间。
3. 物理显示器应持续点亮，SDL 中最后一帧应保持可见。
4. 正常关闭 VM，再按宿主原来的自动息屏时间等待；宿主应重新可以自动息屏。

“整台宿主显示器变黑”属于本功能处理范围。如果宿主桌面和其他窗口仍然可见，
只有 Windows 画面在 SDL 客户区内变黑，则通常是 Guest 自己关闭显示输出或 GPU
scanout 异常，不要用本开关掩盖；先在 Guest 内按键唤醒，再检查 Windows 电源计划
和 QEMU/GPU 日志。

## 确实需要宿主自动息屏时

例如笔记本使用电池时，可只对本次启动恢复上游 QEMU 行为：

```bash
cd /home/ubuntu/projects/qemu
QEMU_SDL_ALLOW_HOST_DISPLAY_SLEEP=1 \
  ./deploy/scripts/start-vm.sh 9 --sdl
```

日志会明确显示：

```text
[start-vm] SDL 允许宿主自动息屏（显式兼容模式）
```

要重新启用默认防息屏，去掉该环境变量即可；不需要运行 `gsettings`、`xset`、
`systemd-inhibit` 或任何 root 命令。宿主凭据不会被读取或写入仓库。

## 仍然黑屏时

先确认运行的是本次构建的二进制：

```bash
readlink -f build/qemu-system-x86_64
pgrep -af qemu-system-x86_64
```

然后记录以下信息再排查：宿主桌面环境、`XDG_SESSION_TYPE`、是否整台显示器都黑、
黑屏前等待时间、启动日志中的防息屏状态，以及 Guest 按键后能否恢复。不要通过
修改 BCD、开启测试签名或安装自签名驱动来解决宿主 SDL 息屏问题。
