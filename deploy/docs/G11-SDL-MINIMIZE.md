# G-11 SDL 最小化/恢复修复傻瓜教程

本修复只落在 G-11 的 SDL 直显路径，不合并 V-11，不修改
Windows BCD，不开启 `testsigning`/`nointegritychecks`，也不安装任何
测试签名或自签名内核驱动。

## 修复了什么

- GNOME Shell 46 在窗口尺寸切换时会同时绘制“旧窗口 clone”和“新窗口
  actor”；VM 的整幅桌面因此会明显像两个画面。G-11 的 `start-vm.sh`
  现在默认通过可逆守护器关闭这段宿主动画，最后一个 SDL VM 退出后精确
  恢复启动前的设置。
- SDL/X11 的 `WM_CLASS` 固定为 `qemu`（仍允许管理员环境变量覆盖），让
  GNOME/Dock 正确分组窗口并使用正常的最小化目标，不再走左上角后备目标。
- `MAXIMIZED` 和 `RESTORED` 都会补一次完整重绘，避免新尺寸缓冲区保留旧帧。
- 宿主 SDL 窗口缩放只改显示画布，不再把窗口管理器的中间尺寸
  回写成 Guest 分辨率。
- 窗口最小化或通过 QMP 隐藏后，2D、GL 和 native-EGL 统一停止
  Present；native-EGL X11 子窗口不再被 resize/map/raise。
- 隐藏期间不再创建/整帧上传 GL surface texture，也不导入 DMA-BUF 或创建
  scanout FBO；只保留“最新画面待补”标记，恢复可见后一次性上传或 replay。
- 最小化前排队的 resize/redraw 会被丢弃，恢复时补一次完整重绘。
- Guest 若在最小化期间主动换显示模式，宿主窗口尺寸只在恢复后
  按最新画面一次性应用。

## 一键构建与验证

在宿主机终端整段复制：

```bash
cd /home/ubuntu/projects/qemu
./deploy/host/build-qemu.sh
./deploy/tests/run-g11.sh --filter sdl
```

`build-qemu.sh` 是封装好的增量构建入口。`run-g11.sh` 会自动发现
`test_sdl_minimize_static.sh` 和 `test_sdl_gnome_animation_guard.sh`，并运行
`test-sdl2-event` 可见性策略单测。动画守护器测试使用假的 `gsettings`，不会
改动当前桌面设置。

只想快速复查本修复时：

```bash
cd /home/ubuntu/projects/qemu
bash deploy/tests/qemu/test_sdl_minimize_static.sh
bash deploy/tests/qemu/test_sdl_gnome_animation_guard.sh
ninja -C build tests/unit/test-sdl2-event qemu-system-x86_64
build/tests/unit/test-sdl2-event --tap
```

## 封装如何保护宿主设置

不需要手工运行 `gsettings`。正常入口：

```bash
cd /home/ubuntu/projects/qemu
./deploy/scripts/start-vm.sh 9 --sdl
```

在 GNOME 下会出现：

```text
[start-vm] GNOME 窗口动画保护：已去掉 SDL 最小化/恢复/最大化双影；QEMU 退出自动恢复
```

守护器只改当前用户的 `org.gnome.desktop.interface enable-animations`，不需要
root；它记录原值、支持多个 SDL VM 同时运行，并在最后一个退出时恢复原值。
状态只放在 `$XDG_RUNTIME_DIR`，不写凭据、不写 VM 配置、不进仓库。
这是 GNOME 的当前用户全局开关，因此 SDL VM 运行期间，同一桌面的其他窗口也会
暂时没有过渡动画；VM 退出后立即恢复。若不接受这个取舍，使用下面的 `on` 回退。

若启动器曾被 `kill -9`，一键恢复：

```bash
cd /home/ubuntu/projects/qemu
python3 deploy/host/gnome-animation-guard.py recover
python3 deploy/host/gnome-animation-guard.py status
```

确实想保留 GNOME 原生动画，可只对本次启动回退；这会重新出现 Shell 自己的
旧窗口 clone，不代表 SDL 又改了 Guest 分辨率：

```bash
QEMU_SDL_GNOME_ANIMATIONS=on ./deploy/scripts/start-vm.sh 9 --sdl
```

## 傻瓜式实机验收

把 `9` 换成真实 VM 编号：

```bash
cd /home/ubuntu/projects/qemu
./deploy/scripts/start-vm.sh 9 --sdl
```

1. Windows 进入桌面后，在“设置 → 系统 → 显示”记下当前分辨率。
2. 点宿主 SDL 标题栏的最小化按钮，等待 5 秒。窗口应由桌面合成器
   直接收起，不应在左上角残留一个小 Guest 画面，也不应同时出现两个桌面。
3. 从 Dock/任务栏恢复窗口。画面应立即重画，不应长时黑屏，窗口不应
   以 `1×1` 或其他极小尺寸恢复，也不应出现旧帧和新帧双影。
4. 再查 Windows 分辨率：必须与第 1 步相同，桌面图标不应因宿主
   最小化而重排。
5. 重复“最小化 → 恢复” 10 次，再测一次最大化、手动拖动缩放和
   `Ctrl+Alt+0` 恢复 1:1 窗口。缩放后应保持等比画面/黑边，不改 Guest
   原生分辨率。

代码和启动封装只有在下一次启动 QEMU 时生效；不能只重建后继续观察已经运行的
旧进程。先正常关闭当前 VM，再按上面的 `start-vm.sh` 命令重新启动。

## 出问题时

先停止 VM，再临时用 GTK 对照：

```bash
./deploy/scripts/start-vm.sh 9 --gtk
```

若 GTK 正常而 SDL 仍异常，记录宿主的 `XDG_SESSION_TYPE`、SDL 启动日志、
最小化前后窗口尺寸、Guest 分辨率，以及下面两条输出：

```bash
python3 deploy/host/gnome-animation-guard.py status
gsettings get org.gnome.desktop.interface enable-animations
```

不要通过改 BCD、开测试签名
或安装自签名驱动来排查宿主窗口问题。
