# G-11 vGPU 宿主策略快速教程

本页只负责生成/切换宿主 framebuffer 策略。V100 全 1Q 的驱动、Hook、依赖和
Windows 安装使用
[`G11-V100-R535-VGPU16.4-FRESH-INSTALL.md`](G11-V100-R535-VGPU16.4-FRESH-INSTALL.md)；
R580 mixed 实验使用
[`G11-V100-VGPU19.5-FRESH-INSTALL.md`](G11-V100-VGPU19.5-FRESH-INSTALL.md)。

## 先区分两条分支

| 物理卡 | host/guest | framebuffer 策略 |
|---|---|---|
| RTX 2080/2080 Ti | R535 / GRID 538.33 | `equal`；整卡统一 1GB 或 2GB |
| Tesla V100，推荐 | vGPU 16.4 `535.161.05` / `538.33` | `equal + 1024`；整卡只用 1Q |
| Tesla V100，可选 | vGPU 19.5 `580.159.01` / `582.53` | `mixed` capability；生产 RM tuple 保持原生 |

V100 不再使用旧 vGPU 19.0 部署入口。R535 与 R580 共享生命周期代码，但驱动资产、
Hook ABI、Guest Driver 和宿主修复合同独立；VMate 不做在线跨分支升级。

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

## 3A. V100/vGPU 16.4：推荐全 1Q

已测 SXM2 16GB：

```bash
./deploy/configure-g11-vgpu-host.sh \
  --preset v100-sxm2-16gb \
  --fb-mode equal --tier 1024 \
  --gpu 0000:81:00.0 --force
```

生成的关键合同为：

```text
VGPU_HOST_FB_MODE=equal
VGPU_HOST_FB_TIER_MB=1024
VGPU_RESOURCE_PROFILE=V100X-1Q
VGPU_RESOURCE_FB_MB=1024
VGPU_RM_FB_IDENTITY_MODE=required
```

R535/16.4 不运行 mixed-mode helper，也不创建 2Q。实机已经确认 RAM_TYPE、位宽 Hook、
Windows Code 0/WHCP、1024MiB 和约 9 分钟无 XID/TDR/PTE/display-copy timeout。

## 3B. V100/vGPU 19.5：可选 1Q/2Q capability

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

R580 业务只用 1Q 时，也可以保持上述 mixed 策略并在每次创建时指定 1024：

```bash
./deploy/scripts/vmctl.sh create 8 --gpu-vram 1024
```

如果希望策略层也禁止 2Q，则在全部 VM/mdev 停止后生成 equal 1Q；不过当前全 1Q
生产更推荐前一节已完成 Guest 验收的 R535/16.4：

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

V100/R535 1Q 只需 probe 实际 1Q profile：

```bash
deploy/host/probe-vgpu-host.sh \
  --config deploy/host/vgpu-host.conf --profile V100X-1Q
```

V100/R580 mixed 才分别 probe：

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

V100 2Q（只属于已通过实时 capability/mode 门禁的 R580 分支）：

```bash
./deploy/scripts/vmctl.sh create 2 --gpu-vram 2048
```

从母盘克隆：

```bash
./deploy/scripts/clone-from-base.sh win10-base 1 --gpu-vram 1024 --start
```

若宿主策略为 equal 2048，申请 1024 会明确拒绝；V100/R535 equal 1024 申请 2Q
同样会拒绝。若 V100/R580 mixed 的 live mode 关闭，1Q/2Q 混搭会在写 sysfs 前拒绝。

## 6. V100 身份字段说明

- mdev profile 决定 1Q/1024MB 或 2Q/2048MB 配额，名称/FHD 可按 G-11 profile
  投影；
- R535/V100 全 1Q 使用 `VGPU_RM_FB_IDENTITY_MODE=required`。实机日志确认
  `RAM_TYPE 15 -> 8`、位宽 `4096 -> 128`，538.33 Code 0/WHCP，约 9 分钟没有
  PTE/TDR/XID 43/display-copy timeout；显存厂家因 Manager 未查询仍是未证明字段；
- R580/V100 生产默认 `VGPU_RM_FB_IDENTITY_MODE=off`，RAM_TYPE、显存厂家和位宽
  保留 NVIDIA 原生值；`V100X-1Q` + 582.53 的 name-only 运行 4 分钟无
  PTE/TDR/XID/unload，但该轮未读取 Device Manager；
- R535 的 2Q，以及 R580 name-only 的 2Q/1Q+2Q 都必须另做正式 Guest 验收。

R580 完整消费卡 RM tuple 在 1Q 上会重复触发故障；R535 的成功不能无条件外推给
R580。两条分支都不能通过测试签名驱动、关闭完整性校验或修改 BCD 绕过稳定性门禁。

## 7. 切换失败时

1. `vmctl.sh status ID` 检查仍运行的 VM；
2. 检查 `/sys/bus/mdev/devices`；
3. 只有 V100/R580 才运行 mixed helper 的 `status`；R535 应确认 equal/1024；
4. 确认 host config 指向实际文件且不是符号链接；
5. 所有实例停止后，才可用同一 preset/BDF 加 `--force` 原子替换。

脚本不会替你强杀 VM、删除未知 mdev、卸载驱动或保存密码。
