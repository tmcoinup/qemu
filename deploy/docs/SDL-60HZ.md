# SDL 固定 60Hz 傻瓜教程

`start-vm.sh` 的 SDL 窗口现在默认按固定 60Hz 执行 Present。无需增加参数：

```bash
cd /home/ubuntu/projects/qemu
./deploy/start-vm.sh 3
```

启动日志出现下面一行即表示默认模式生效：

```text
[start-vm] SDL Present 模式：固定 60Hz（默认）
```

窗口可见且未最小化时，标题中的 `SDL Present` 应稳定在约 60 FPS。最小化或隐藏
窗口时仍会降频，避免无意义占用宿主资源。

旧的动态模式没有删除。后续优化或对比时，只给本次启动加环境变量：

```bash
QEMU_SDL_PRESENT_MODE=dynamic ./deploy/start-vm.sh 3
```

动态模式只在画面发生变化时 Present，因此静止桌面的标题可能显示 `0.0 FPS`，这是
正常行为。下次直接运行 `./deploy/start-vm.sh 3` 会自动恢复默认固定 60Hz。

该切换只影响宿主 SDL 窗口的 Present 节拍，不改 Windows BCD，不开启
`testsigning`/`nointegritychecks`，也不安装测试签名或自签名内核驱动。
