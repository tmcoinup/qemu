# G-11 SDL 键盘：宿主拼音状态不再影响 Guest

本页只适用于 **G-11/vGPU 分支的 SDL 窗口**。V-11 是独立分支，不要直接混用
二进制或提交。这个修复只改宿主 QEMU 的 SDL 输入路径和启动环境；不会修改
Windows BCD，不会开启 `testsigning` / `nointegritychecks`，也不安装任何 Guest
内核驱动。

## 发生了什么

SDL2 桌面端初始化后默认开启“文本输入”。如果宿主当前是 IBus/Fcitx 拼音，宿主
IME 可以先消费字母键，QEMU 就收不到完整的 `KEYDOWN/KEYUP`，表现为 SDL 窗口
已经聚焦、鼠标也能用，但 Windows Guest 里无法正常打字。

虚拟机图形窗口不应该接收宿主已经合成好的文字，而应该把物理键位 scancode
原样交给 Guest。现在有两层保护：

1. QEMU SDL 初始化后立即关闭 SDL 文本输入，只走 scancode/qcode。
2. `start-vm.sh` 默认只为当前 QEMU 子进程隔离 XIM、IBus 和 Fcitx，兼容
   Wayland/XWayland 的 SDL 2.30 路径；不会切换或关闭桌面其他程序的输入法。

Guest 要输入中文，请在 Windows 内切换并使用 Windows 自己的微软拼音。宿主当前
是英文、拼音还是 Fcitx，不再决定 Guest 是否能收到键盘。

## 一键构建与验证

在仓库根目录照抄：

```bash
cd /home/ubuntu/projects/qemu
./deploy/host/build-qemu.sh
./deploy/tests/run-g11.sh --filter sdl
```

第一条会增量重编 `build/qemu-system-x86_64`；第二条是封装后的 SDL 回归入口，
包括宿主 IME 静态门禁和 `test-sdl2-event` 编译单测。已有 VM 进程不会热更新；
必须先让 Guest 正常完整关机，再用新二进制重新启动。

## 启动

把 `9` 换成实际 VM 编号：

```bash
./deploy/scripts/start-vm.sh 9 --sdl
```

不需要手工切换宿主输入法，也不需要额外环境变量。启动日志应出现：

```text
[start-vm] SDL 宿主输入法已隔离：host 拼音/Fcitx 状态不会吞 guest 按键
```

安装或救援路径显式使用 SDL 时也走同一封装。例如：

```bash
INSTALL_GFX_BACKEND=sdl ./deploy/scripts/start-vm.sh 9 --install /绝对路径/windows.iso
./deploy/scripts/start-vm.sh 9 --rescue-sdl
```

## 傻瓜式验收

1. 在宿主先切到“中文（拼音）”，不要切回英文。
2. 启动 SDL VM，在 Guest 打开记事本。
3. 依次按 `a b c 1 2 3 Backspace Enter`；每个按下和松开都应在 Guest 正常生效，
   不应弹出宿主候选框。
4. 在 Windows Guest 内切到微软拼音并输入中文；候选框应属于 Guest。
5. `Alt+Tab` 离开再回到 SDL 窗口，重复第 3 步，不能出现首键丢失或按键卡住。

若只想确认本次问题，至少完成前 3 步。宿主 GNOME 的 `Super`、`Alt+Tab` 等全局
快捷键是另一条路径，由现有 `--tame-gnome`/默认保护处理，不等同于输入法隔离。

## 诊断开关

默认值是 `QEMU_SDL_DISABLE_IBUS=1`。只有排查 SDL/桌面兼容性时，才可临时关闭
启动器的第二层隔离：

```bash
QEMU_SDL_DISABLE_IBUS=0 ./deploy/scripts/start-vm.sh 9 --sdl
```

这只用于 A/B 诊断；QEMU 本身仍坚持 raw scancode。若关闭后问题复现，恢复默认
命令重新启动即可。不要通过 Guest 驱动、BCD 或测试签名绕过这个宿主输入问题。

QEMU 自带的 SDL 文本控制台也改为物理键/qcode 路径，适合命令和快捷键；不再接收
宿主 IME 合成的 Unicode 文本。日常 Windows 中文输入不受此限制，因为它发生在
Guest 内。
