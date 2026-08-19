# G-11 SDL 鼠标修复与光标说明

这次修复只落在 G-11，不合并 V-11 整个提交，也不改变 Windows BCD、
`testsigning`、`nointegritychecks` 或 guest 内核驱动。
窗口最小化/恢复的独立构建与验收步骤见
[`G11-SDL-MINIMIZE.md`](G11-SDL-MINIMIZE.md)。
宿主处于拼音/Fcitx 时 Guest 键盘无输入，见
[`G11-SDL-HOST-IME.md`](G11-SDL-HOST-IME.md)。

## 一键构建与验证

在 QEMU 仓库根目录执行：

```bash
./deploy/host/build-qemu.sh
./deploy/tests/run-g11.sh --filter sdl
```

第一条命令用仓库自带的 Meson 环境增量构建 QEMU。第二条是封装后的 G-11
验证入口，会运行 SDL 静态回归和 `test-sdl2-pointer` 坐标单测。不要直接使用
Ubuntu 自带的 Meson 1.3；当前 QEMU 构建目录使用更新的仓库环境。

只想快速重跑本功能时：

```bash
bash deploy/tests/qemu/test_sdl_pointer_mapping_static.sh
build/tests/unit/test-sdl2-pointer --tap
```

## 启动

把 `9` 换成实际 VM 编号：

```bash
./deploy/scripts/start-vm.sh 9 --sdl
```

默认 `usb-tablet` 是绝对坐标设备。窗口模式下无需抓住鼠标；指针应能从任意
边自然离开窗口。只有纯相对鼠标或用户显式按下 `Ctrl+Alt+G` 时，SDL 才约束
宿主指针。

## 傻瓜式验收

1. 先按 `Ctrl+Alt+0`，让窗口恢复 guest 原生大小。
2. 在 Windows 桌面把鼠标缓慢移到四个边角，guest 指针应到达对应边角。
3. 把窗口放大到出现黑边，再重复四边测试。进入黑边时 guest 坐标只钳制到
   最近边缘，不应在画面内部提前卡住。
4. 从左、右、上、下任意一边移出窗口，再移入；不应再依赖“换一个方向出去”
   才恢复。
5. 缩小窗口并慢速移动鼠标，连续的小位移不应被整数缩放永久吃掉。

## 光标样式为什么仍可能是箭头

“鼠标位置”和“光标图片”是两条独立通道：

| 数据来源 | SDL 行为 |
|---|---|
| `usb-tablet` 绝对坐标 | 宿主位置映射到 guest；本次已修复 |
| QEMU 收到 guest cursor shape/热点/可见性 | SDL 自动使用真实 guest 光标 |
| NVIDIA R535 VFIO REGION | 只有主画面，没有 cursor shape；使用 Windows 箭头 fallback |
| 游戏把软件光标画进主画面 | 按 `Ctrl+Alt+C` 隐藏宿主箭头，即可看到游戏原始光标 |

因此，当前 native SDL 和 GTK 都只显示默认箭头，并不是两个前端恰好同时坏了，
而是 NVIDIA REGION 没有向 QEMU 提供 Windows 硬件光标平面。QEMU 无法仅从主
画面可靠猜出 I-beam、手型或游戏硬件光标，也不能可靠判断何时应自动隐藏箭头。

SDL 的 `Ctrl+Alt+C` 是安全的即时切换：窗口标题出现
`Cursor: framebuffer (host hidden)` 时，宿主 overlay 已隐藏；再按一次恢复。
它不修改 guest。

若要完全自动同步 Windows/游戏硬件光标，需要单独增加 guest 用户态 cursor
bridge，把形状、热点、可见性送回 QEMU。仓库旧的 ivshmem/DXGI relay 已有形状
协议，但 native vGPU 路径刻意不挂 ivshmem，也不运行该 relay，不能直接冒充为
已支持。后续实现应使用签名的生产传输驱动或纯用户态安全通道；不得为此开启
测试签名或安装自签名内核驱动。

## 常用热键

- `Ctrl+Alt+0`：恢复 1:1 窗口大小。
- `Ctrl+Alt+G`：显式抓取或释放相对鼠标。
- `Ctrl+Alt+C`：切换 framebuffer/game cursor 模式。
- `Ctrl+Alt+F`：切换全屏。
