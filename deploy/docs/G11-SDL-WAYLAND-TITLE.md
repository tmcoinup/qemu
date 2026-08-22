# G-11 SDL/Wayland 标题 GDK 日志风暴修复

## 现象与结论

典型日志：

```text
qemu-system-x86_64: Gdk: gdk_monitor_get_scale_factor: assertion 'GDK_IS_MONITOR (monitor)' failed
```

这不是 Windows、vGPU、EDID 或物理显示器故障。G-11 的 SDL 标题原本每秒更新一次
`Content/Present`；GNOME Wayland 下 SDL 2 会通过 `libdecor-gtk` 绘制窗口标题栏，
每次改标题都会重建 GTK offscreen header。GTK 3 在销毁旧 header 时可能查询已经脱离
display 的 monitor，一次标题更新会输出几十条相同断言。

修复后有两层保护：

1. 相同标题不再重复调用 `SDL_SetWindowTitle()`；
2. `QEMU_SDL_TITLE_FPS=auto` 在实际 SDL driver 为 Wayland 时默认保持静态标题。
   若宿主装有 Cairo libdecor，启动器只为当前 QEMU 进程选择 Cairo 插件并自动恢复实时
   `Content/Present` 标题。X11 仍默认实时显示。

这条修复只涉及宿主 userspace 窗口装饰和 QEMU 标题更新。它不改 BCD，不开启
`testsigning`/`nointegritychecks`，不安装或替换任何内核驱动，也不写入宿主凭据。

## VM3 傻瓜修复

当前已经运行的 QEMU 仍是旧进程，不能热替换；让 Windows 从“开始 → 电源 → 关机”
完整关机后再做下面步骤。不要为清日志强杀 QEMU，也不要动 guest driver。

```bash
cd /home/ubuntu/projects/qemu

# 推荐：安装纯 userspace Cairo 标题装饰，保留实时 Content/Present 标题。
# sudo 只在 apt 安装时正常询问，不保存密码。
./deploy/host/install-g11-sdl-wayland-decor.sh

# 增量构建，不清 build/。
./deploy/host/build-qemu.sh

# 按 VM3 当前 ultra + native Wayland 档位重新启动。
./deploy/scripts/g11-sdl-performance.sh start 3 --ultra-responsive --native-wayland
```

如果暂时不安装 Cairo，直接跳过第一条也安全：新 QEMU 会自动使用静态 `win10-3`
标题，日志风暴同样停止，只是标题不再实时显示 FPS。

## 验收

另开终端执行：

```bash
cd /home/ubuntu/projects/qemu
./deploy/scripts/g11-sdl-performance.sh verify 3

# 新一轮启动日志不应继续增长这种断言。
rg -n "gdk_monitor_get_scale_factor.*GDK_IS_MONITOR" \
  /home/ubuntu/images/vms/3/log/qemu.log | tail
```

启动器应打印以下二者之一：

- 已安装 Cairo：`SDL Wayland 标题装饰：Cairo（实时 Content/Present...）`；
- 未安装 Cairo：`使用静态标题，避免 libdecor-gtk/GDK 日志风暴`。

`qemu.log` 是追加文件，`rg` 仍可能显示本次修复前的旧行。判断标准是重启后的行数不再
持续增加；不需要删除或清空历史日志。

## 显式回退与诊断

始终使用静态标题：

```bash
QEMU_SDL_TITLE_FPS=0 \
  ./deploy/scripts/g11-sdl-performance.sh start 3 --ultra-responsive --native-wayland
```

仅在 Cairo 已通过 `install-g11-sdl-wayland-decor.sh --check` 验收时，才需要显式强制
实时标题：

```bash
./deploy/host/install-g11-sdl-wayland-decor.sh --check
QEMU_SDL_TITLE_FPS=1 \
  ./deploy/scripts/g11-sdl-performance.sh start 3 --ultra-responsive --native-wayland
```

普通生产启动保留 `auto` 即可，不要把 `LIBDECOR_PLUGIN_DIR` 或 VM3 路径写进
`vm.conf`。
