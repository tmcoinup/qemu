# G-11 vGPU 宿主策略快速教程

本页只负责生成/切换宿主 framebuffer 策略。V100 的驱动、Hook、依赖、Windows 安装
和回退请直接使用
[`G11-V100-VGPU19.5-FRESH-INSTALL.md`](G11-V100-VGPU19.5-FRESH-INSTALL.md)。

## 先区分两条分支

| 物理卡 | host/guest | framebuffer 策略 |
|---|---|---|
| RTX 2080/2080 Ti | R535 / GRID 538.33 | `equal`；整卡统一 1GB 或 2GB |
| Tesla V100 | vGPU 19.5 `580.159.01` / `582.53` | 默认 `mixed`；1Q/2Q 可混搭 |

V100 不再支持旧 vGPU 19.0 部署入口。两条路径共享生命周期代码，但驱动资产和
宿主修复合同独立。

任何切档前都必须正常关闭目标 GPU 上全部 VM，并确认没有活动 mdev：

```bash
find /sys/bus/mdev/devices -mindepth 1 -maxdepth 1 -print
```

不允许 testsigning、nointegritychecks、自签 Windows 内核驱动或 BCD 修改；宿主和
guest 凭据不得写入配置/仓库。

## 1. 查真实 GPU BDF

```bash
lspci -Dnn | grep -i nvidia
nvidia-smi --query-gpu=name,pci.bus_id,memory.total --format=csv,noheader
```

以下用 `0000:81:00.0` 举例。新主机必须替换，不能照抄。

## 2. RTX 2080：整卡统一档

固定 2GB：

```bash
cd /home/ubuntu/projects/qemu
./deploy/configure-g11-vgpu-host.sh \
  --preset rtx2080-16gb \
  --tier 2048 \
  --gpu 0000:65:00.0
```

固定 1GB 时把 `--tier` 改为 `1024`。RTX 2080/R535 不接受 `--fb-mode mixed`；
这正是最初“1024MB 与宿主固定 2048MB 冲突”的原因。需切档时，停完该卡上全部
VM/mdev 后重跑并加 `--force`。

## 3. V100/vGPU 19.5：默认允许 1Q/2Q

已测 SXM2 16GB：

```bash
./deploy/configure-g11-vgpu-host.sh \
  --preset v100-sxm2-16gb \
  --gpu 0000:81:00.0
```

默认生成：

```text
VGPU_HOST_FB_MODE=mixed
VGPU_RESOURCE_PROFILE_1024=V100X-1Q
VGPU_RESOURCE_PROFILE_2048=V100X-2Q
VGPU_TOTAL_FB_MB=16384
VGPU_MDEV_IDENTITY_MODE=required
SPOOF_MODE=B
```

其它 V100 使用与实卡匹配的 preset：

```text
v100-pcie-16gb   v100-pcie-32gb
v100-sxm2-16gb   v100-sxm2-32gb
v100s-pcie-32gb  v100-fhhl-16gb
```

mixed 策略只有在精确 `580.159.01`、V100 capability=`Supported` 且 mode=`Enabled`
时才放行创建。先用受管 helper 复检：

```bash
sudo /usr/local/libexec/qemu-vgpu-mixed-mode status 0000:81:00.0
```

业务全部使用 1Q 时，保持上述 mixed 策略并在每次创建时指定 1024 即可：

```bash
./deploy/scripts/vmctl.sh create 8 --gpu-vram 1024
```

如果希望策略层也禁止 2Q，则在全部 VM/mdev 停止后生成 equal 1Q：

```bash
./deploy/configure-g11-vgpu-host.sh \
  --preset v100-sxm2-16gb \
  --fb-mode equal --tier 1024 \
  --gpu 0000:81:00.0 --force
```

## 4. 检查配置和 profile

默认文件是 gitignored 的 `deploy/host/vgpu-host.conf`：

```bash
bash -n deploy/host/vgpu-host.conf
sed -n '1,80p' deploy/host/vgpu-host.conf
```

V100 mixed 可分别 probe：

```bash
deploy/host/probe-vgpu-host.sh \
  --config deploy/host/vgpu-host.conf --profile V100X-1Q
deploy/host/probe-vgpu-host.sh \
  --config deploy/host/vgpu-host.conf --profile V100X-2Q
```

必须唯一匹配目标 parent BDF、`device_api=vfio-pci` 和 1024/2048MB。profile 不存在
或有歧义时不要猜 `nvidia-NNN`。

## 5. 创建与克隆

V100 1Q：

```bash
./deploy/scripts/vmctl.sh create 1 --gpu-vram 1024
```

V100 2Q：

```bash
./deploy/scripts/vmctl.sh create 2 --gpu-vram 2048
```

从母盘克隆：

```bash
./deploy/scripts/clone-from-base.sh win10-base 1 --gpu-vram 1024 --start
```

若宿主策略为 RTX/equal 2048，申请 1024 会明确拒绝；若 V100/mixed 的 live mode
关闭，1Q/2Q 混搭也会在写 sysfs 前拒绝。

## 6. V100 身份字段说明

- 1Q：RAM_TYPE、显存厂商和位宽均按 G-11 profile 投影；
- 2Q：显存厂商和位宽可投影，RAM_TYPE 由运行时 framebuffer guard 自动跳过；
- 1Q + 2Q 已在同卡、正式 582.53 guest driver 上完成 Code 0 和关机验证。

2Q 的 RAM_TYPE 跳过是稳定性保护，不应通过测试签名驱动或 BCD 绕过。

## 7. 切换失败时

1. `vmctl.sh status ID` 检查仍运行的 VM；
2. 检查 `/sys/bus/mdev/devices`；
3. V100 运行 mixed helper 的 `status`；
4. 确认 host config 指向实际文件且不是符号链接；
5. 所有实例停止后，才可用同一 preset/BDF 加 `--force` 原子替换。

脚本不会替你强杀 VM、删除未知 mdev、卸载驱动或保存密码。
