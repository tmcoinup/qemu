# G-11：SDL 隐藏后 DGame GPU 预览不定格

本页用于 G-11 NVIDIA vGPU 的 `fb-shm` DGame 预览。症状通常是 DGame 卡片仍显示
目标 FPS，但 SDL 窗口隐藏后游戏画面停在同一张纹理。FPS 数字不是新帧证明：消费端
可以每秒重复绘制 60 次同一份 GPU backing。

这套修复让协商了 `GPU_SYNC` 的 Linux consumer 接收 fb-shm 自己的 ROI texture，
而不是长期采样 VFIO/SDL 的原始 scanout。QEMU 每次只交付一帧：先复制 ROI、附带
acquire sync-file，再等待 consumer 完成自己的私有纹理复制并发送
`GPU_FRAME_DONE`。DONE 前 QEMU 不会覆写该 backing；超时或断线会丢弃 consumer
并退役 backing，不会把仍可能被外部导入的存储重新使用。旧 consumer 没有
`GPU_SYNC` 时仍走 legacy 路径。

本功能不会开启 testsigning 或 nointegritychecks，不修改 Windows BCD，不安装测试
签名/自签名内核驱动，也不需要把宿主凭据写入仓库。

## 最短、安全步骤

在仓库根目录执行源码预检：

```bash
cd /home/ubuntu/projects/qemu
./deploy/scripts/check-fb-shm-gpu-sync.sh source
```

看到下面两行才继续：

```text
[fb-shm-sync] READ_ONLY=source,binary,proc,unix-socket-metadata
[fb-shm-sync] RESULT=ready
```

然后按仓库正式构建入口增量编译：

```bash
./deploy/host/build-qemu.sh
./deploy/scripts/check-fb-shm-gpu-sync.sh binary
```

`binary` 只执行 QEMU 的 object help 并读取二进制字符串，不启动 VM。若报告
`可能尚未重编`，不要拿旧进程继续验收；先完成构建。

已经运行的 QEMU 不会被新二进制热替换。请在 Windows 内正常选择“关机”，确认旧
QEMU 进程退出，再使用原来的正式命令启动。下面以 VM9 为例，编号必须换成真实值：

```bash
./deploy/scripts/start-vm.sh 9
./deploy/scripts/check-fb-shm-gpu-sync.sh runtime 9
```

`runtime` 只读取 `/proc`、运行中映像和 preview Unix socket 的文件类型。它不会连接
QMP，不会连接 fb-shm 控制 socket，也不会启动、停止、暂停或重启 VM。成功输出应含：

```text
OK: vm9 PID=...
OK: preview endpoint=...（只检查文件类型，未连接）
OK: 运行中映像包含 GPU_SYNC/fence/lease 合同
[fb-shm-sync] RESULT=ready
```

如果需要一次完成源码、构建和运行态只读检查：

```bash
./deploy/scripts/check-fb-shm-gpu-sync.sh all 9
```

## 动态验收：必须看像素变化

只读 wrapper 不能证明 GPU 像素正在变化。请把 Guest 停在具有持续动画的位置，例如
游戏角色待机、技能特效或连续播放的视频，并保持 DGame 预览可见。

先在 SDL 可见时观察 15 秒，确认画面内容持续变化。然后由操作员显式切到仅推流：

```bash
./deploy/scripts/ctl-vm.sh 9 stream-only
```

这个命令会改变当前 VM 的显示状态，因此不属于只读 wrapper。它应先恢复 fb-shm，
确认成功后再隐藏 SDL。接下来连续观察 DGame 预览至少 30 秒，并核对：

1. 角色、特效或视频内容继续前进，而不只是 FPS 文本保持在 60；
2. 没有周期性跳回旧画面或上下颠倒；
3. 使用非零 ROI 时，裁剪位置与 SDL 可见时相同；
4. 关闭或遮挡 DGame 预览后，QEMU 不崩溃，consumer 可以正常重连。

建议在隐藏 SDL 前后各保存两张相隔 2 秒的 DGame 截图。每组截图的动画像素必须不同；
只比较红色 FPS 数字没有意义。

验收完成后恢复本地窗口：

```bash
./deploy/scripts/ctl-vm.sh 9 window-only
```

## 这条同步链实际保证什么

Linux `GPU_SYNC` 通知必须携带两个有序 fd：

```text
SCM_RIGHTS { dma-buf, acquire_sync_file }
```

consumer 先等待 acquire sync-file，再把共享 ROI 复制进自己的本地 texture，等待该
复制完成，最后才发送匹配 frame sequence 的 `GPU_FRAME_DONE`。QEMU 在匹配 DONE
之前不写 `gl_sync_fb`。SHM/PBO 读回使用另外的 `gl_blit_fb`，因此普通 SHM consumer
和 SDL 窗口不会被这个单帧 lease 反压。

如果服务端不认识新协商位，它可能仍发送旧式单 fd 的不安全帧。新 client 必须拒绝
“没有 `SYNC_FILE` 标记或 fd 数量不是 2”的通知，不能把它当作同步成功。这样才能
避免旧 server 在 consumer 仍采样时覆写同一个原始 scanout。

CPU `DisplaySurface` 场景也不依赖 SDL 的 `surface->texture`：fb-shm 从 CPU surface
数据上传 ROI 到自己的 upload texture，再翻转到 `gl_sync_fb`。GL scanout 场景按
backing height 正确反射 `y0_top` 坐标，并把 wire layout 归一化为：

```text
x=0, y=0
width=backing_width=ROI width
height=backing_height=ROI height
source_width/source_height=完整可见 Guest 尺寸
Y0_TOP=0
```

## 常见失败及处理

### `binary` 报告缺少 GPU_SYNC 合同

当前 `build/qemu-system-x86_64` 仍是旧版本，或构建失败。重新运行正式构建入口：

```bash
./deploy/host/build-qemu.sh
./deploy/scripts/check-fb-shm-gpu-sync.sh binary
```

不要尝试热替换运行中 QEMU。让 Windows 完整关机后再用新二进制启动。

### `runtime` 报告 `(deleted)` 或旧合同

源码/二进制已经更新，但 VM 仍运行旧 inode。保存 Guest 工作后从 Windows 正常关机，
确认进程退出，再正常启动。wrapper 不会代替你停止或重启 VM。

### 日志出现 `requires EGL_ANDROID_native_fence_sync`

当前 EGL provider 不能创建 acquire fence。QEMU 会拒绝向同步 client 发送不安全的
单 fd GPU 帧；strict client 应由 watchdog 重连或明确降级到 SHM。不要通过忽略
`SYNC_FILE`、提前发送 DONE 或复用原始 VFIO dma-buf 来“消除”这条错误。

### 日志出现 `lease expired; dropping stalled consumer`

consumer 在 3 秒内没有完成本地 GPU copy/DONE。QEMU 会关闭该 consumer 并退役旧
private backing，避免继续覆写。检查 DGame 的 fence wait、私有 texture copy 和
DONE 队列；不要延长到无限等待，也不要在未完成 copy 时提前 DONE。

### SDL 隐藏后仍只有 FPS、像素不变

依次核对：

```bash
./deploy/scripts/check-fb-shm-gpu-sync.sh source
./deploy/scripts/check-fb-shm-gpu-sync.sh binary
./deploy/scripts/check-fb-shm-gpu-sync.sh runtime 9
```

三项都通过后，再查看 QEMU 是否记录 native-fence 或 lease 错误，以及 DGame 是否拒绝
了错误 fd 数量。不要用 Present/FPS 代替两张不同时间点的像素证据。

## 回滚与安全边界

出现问题时先恢复 SDL：

```bash
./deploy/scripts/ctl-vm.sh 9 window-only
```

如需换回上一版 QEMU，先让 Windows 完整关机，再由现有发布/构建流程选择已知可用的
二进制；不要覆盖正在运行的映像。这里没有任何步骤要求修改 Guest BCD、关闭代码
完整性、安装测试签名驱动或重建 NVIDIA vGPU。wrapper 也不会执行这些操作。
