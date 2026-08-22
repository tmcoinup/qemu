# SDL 固定 60Hz 傻瓜教程

`start-vm.sh` 的 SDL 窗口现在默认按固定 60Hz 执行 Present。无需增加参数：

```bash
cd /home/ubuntu/projects/qemu
./deploy/scripts/start-vm.sh 3
```

启动日志出现下面一行即表示默认模式生效：

```text
[start-vm] SDL Present 模式：固定 60Hz（默认）
```

窗口可见且未最小化时，标题会同时显示两项：

- `Update`：QEMU 显示更新/损伤合并后送到 SDL 的更新速率；
- `Present`：SDL 向宿主窗口提交的速率，固定模式下应稳定在约 `60/s`。

静止桌面常见 `Content 0.0/s | Present 60.0/s (fixed)`，这是正常的；如果持续播放视频时
`Update` 突然长时间变成 0，而 `Present` 仍为 60，说明窗口只是在重复最后一帧，
不能把它误判为“画面正常”。最小化或隐藏窗口时仍会降频，避免无意义占用资源。
Update 是显示更新回调率，不是 GPU 内部唯一帧序号；只能结合动态画面判断。

需要只对本次启动调整目标帧率时，可选 30 到 240；生产默认仍是 60：

```bash
QEMU_SDL_TARGET_FPS=120 ./deploy/scripts/start-vm.sh 3 --sdl
```

这只是为高刷新率实机 A/B 提供入口，不保证 vGPU source 能产生 120 个不同画面。

旧的动态模式没有删除。后续优化或对比时，只给本次启动加环境变量：

```bash
QEMU_SDL_PRESENT_MODE=dynamic ./deploy/scripts/start-vm.sh 3
```

动态模式只在画面发生变化时 Present，因此静止桌面的 `Content` 和 `Present` 都可能
显示 `0.0/s (dynamic)`，这是正常行为。下次直接运行 `./deploy/scripts/start-vm.sh 3` 会自动
恢复默认固定 60Hz。

该切换只影响宿主 SDL 窗口的 Present 节拍，不改 Windows BCD，不开启
`testsigning`/`nointegritychecks`，也不安装测试签名或自签名内核驱动。
