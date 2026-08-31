# G-11 vGPU 宿主快速配置

本文用于已经安装 VMate/QEMU 的宿主。空白 V100 新主机请优先按照
[`G11-V100-VGPU18.4-FRESH-INSTALL.md`](G11-V100-VGPU18.4-FRESH-INSTALL.md)
操作；本文只列日常切档、创建和验收命令。

## 当前受支持组合

| 物理 GPU | host / guest | 宿主策略 | 当前定位 |
| --- | --- | --- | --- |
| Tesla V100 | vGPU 18.4：`570.172.07` / `573.48` | mixed，发布 1Q 与 2Q；RM identity required | 新主机生产主路径，已实测单 1Q、单 2Q、1Q+2Q |
| Tesla V100 | vGPU 16.4：`535.161.05` / `538.33` | equal 1024，仅 1Q | 既有全 1Q 环境兼容 |
| RTX 2080 | R535：`535.161.05` / `538.33` | equal 1024 或 equal 2048 | 旧显卡稳定分支 |
| Tesla V100 | vGPU 19.5：`580.159.01` / `582.53` | name-only，RM identity off | 历史问题定位；不作为统一版本 |

不要把 R570 的 2Q 结果外推到 R535 或 R580，也不要混装其它小版本。任何切档前都必须
先关闭该物理 GPU 上的全部 VM，并确认 `/sys/bus/mdev/devices` 为空。

本项目不启用 Windows `testsigning`/`nointegritychecks`，不修改 BCD，也不安装测试签名
或自签名内核驱动。凭据只在运行时安全输入，不写入仓库或配置文件。

## 1. 只读识别宿主

```bash
lspci -Dnn | grep -Ei 'NVIDIA|VGA|3D|Display'
uname -r
cat /sys/module/nvidia/version
find /sys/bus/mdev/devices -mindepth 1 -maxdepth 1 -type l -print
./deploy/host/probe-vgpu-host.sh
```

V100/R570 还应确认官方 mixed mode：

```bash
sudo /usr/local/libexec/qemu-vgpu-mixed-mode status 0000:81:00.0
```

将示例 BDF 换成实际 V100。结果必须同时显示 capability `Supported`、mode `Enabled`。

## 2. 配置 V100/R570 1Q+2Q 混合池

```bash
./deploy/configure-g11-vgpu-host.sh \
  --preset v100-sxm2-16gb \
  --gpu 0000:81:00.0 \
  --fb-mode mixed \
  --force

sudo ./deploy/host/install-vgpu-mixed-mode.sh 0000:81:00.0
```

如果 V100 是 PCIe、32GB、V100S 或 FHHL，按 `--help` 选择对应 preset，不能仅凭名称
猜容量。配置成功后复检两档映射：

```bash
./deploy/host/probe-vgpu-host.sh --fb-mb 1024
./deploy/host/probe-vgpu-host.sh --fb-mb 2048
```

R570 的受管配置应包含：

```text
VGPU_HOST_FB_MODE=mixed
VGPU_RESOURCE_PROFILE_1024=V100X-1Q
VGPU_RESOURCE_PROFILE_2048=V100X-2Q
VGPU_RM_FB_IDENTITY_MODE=required
```

这里的 `V100X` 只是 SXM2 16GB 示例；其它 V100 型号使用各自前缀。

## 3. 配置旧 RTX 2080/R535 固定档

整卡只能同时使用一个显存档。配置 1GB：

```bash
./deploy/configure-g11-vgpu-host.sh \
  --preset rtx2080-16gb \
  --gpu 0000:04:00.0 \
  --fb-mode equal \
  --tier 1024 \
  --force
```

配置 2GB 时只把 `--tier` 改为 `2048`。脚本发现运行中的 mdev 或固定档冲突会拒绝
继续；不要手工删除仍被 QEMU 占用的 mdev。

## 4. 创建 VM

V100/R570 mixed 池无需先切整卡档位，可以直接按 VM 请求 1GB 或 2GB：

```bash
./deploy/scripts/clone-from-base.sh win10-base 1 \
  --gpu-vram 1024 \
  --platform i7-4820k-p9x79-elpida-8g \
  --ssd-profile samsung-970-pro-512gb \
  --start

./deploy/scripts/clone-from-base.sh win10-base 2 \
  --gpu-vram 2048 \
  --platform i7-4820k-p9x79-elpida-8g \
  --ssd-profile samsung-970-pro-512gb \
  --start
```

也可以创建单台指定身份：

```bash
./deploy/scripts/vmctl.sh create 8 --gpu-profile gtx750_asus_1gb
./deploy/scripts/vmctl.sh create 9 --gpu-profile gtx750ti_msi_2gb
```

若仍提示“空池固定 2048MB”，说明正在读取旧 equal 配置；先确认配置文件来源，再用
本节第 2 步生成 mixed 策略。不要用环境变量绕过实时驱动/mode/容量门禁。

## 5. 快速验收

每种新硬件或重装宿主至少完成：单开 1Q、单开 2Q、同时开 1Q+2Q。检查：

- Device Manager：`Status=OK`、`ConfigManagerErrorCode=0`；
- 1Q 为 GTX 750 / 1024 MiB，2Q 为 GTX 750 Ti / 2048 MiB；
- Guest driver 为正式签名 `573.48`，不使用任何签名绕过；
- Guest System 日志没有 Display 4101/TDR；
- 宿主日志没有 NVIDIA XID、PTE 或 display-copy timeout；
- 正常关机后 QEMU 退出，mdev 被回收。

2026-08-31 的物理 V100/R570 验收中，单 2Q 和 1Q+2Q 混合均实际执行 RAM_TYPE
`15 -> 8`；两台 Guest 均 Code 0、TDR=0，宿主错误计数为 0，并完成正常关机回收。

## 6. VMate 修复中心

VMate 启动时只做授权检查。宿主依赖、6.8 默认内核、R570 驱动、Hook、mixed mode、
mdev 和性能项由“修复中心 → 自动修复”统一处理。命令行等价入口：

```bash
sudo /opt/vmate/repair-env.sh g11 \
  --target-bdf 0000:81:00.0 \
  --model v100 \
  --target-uid "$(id -u)"
```

修复器不会自动重启。页面要求重启时手动重启，再执行一次自动修复完成收口。已有 VM
或 mdev 时它会拒绝重启 manager/切换分支，这是保护，不应绕过。
