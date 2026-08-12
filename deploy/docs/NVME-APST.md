# NVMe APST 主机配置

`deploy/scripts/host-nvme-apst.sh` 是一个可独立复制和运行的单文件脚本，不依赖本仓库的其他脚本或库。

它使用 NVMe 标准 Feature `0x0c` 和 Linux 内核参数，不维护硬盘品牌白名单，因此适用于不同容量、不同品牌及 PCIe 3.0/4.0/5.0 的本地 NVMe 控制器。SATA、SAS 和 NVMe-over-Fabrics 不使用这条本地 PCIe 处理路径，会被自动跳过。

## 使用

```bash
# 只读查看全部本地 PCIe NVMe；普通用户也可运行
./deploy/scripts/host-nvme-apst.sh check

# 写入启动配置，并对当前系统尝试立即关闭
sudo ./deploy/scripts/host-nvme-apst.sh apply

# 重启后严格核对内核参数和每个控制器
sudo ./deploy/scripts/host-nvme-apst.sh verify
```

也可以只检查指定控制器：

```bash
./deploy/scripts/host-nvme-apst.sh check /dev/nvme0 /dev/nvme1
```

设备参数只限制报告和在线命令。持久化的 `nvme_core.default_ps_max_latency_us=0` 是内核全局参数，会覆盖所有 NVMe。

## 动作语义

- `check`：只读显示当前启动参数、内核值、型号、固件、PCIe 代际和 APST Feature；非 root 用户不会发送 NVMe 管理命令。
- `persist`：只写持久化配置，不发送 NVMe 管理命令，也不修改当前运行时参数。
- `apply`：先持久化，再把运行时参数设为 `0`，最后逐控制器执行带 15 秒用户态超时的在线设置。某块盘固件不响应时记录失败、继续处理其他盘，并提示重启后验证。
- `verify`：严格要求当前启动参数最后一个值、内核参数及所有支持 APST 的目标控制器均为 `0`。

脚本支持 Debian/Ubuntu 的 `update-grub` 和 Fedora/RHEL 系的 `grubby`。遇到未知引导器会停止并给出错误，不会猜测或覆盖未知配置。脚本本身不会重启机器、重置 NVMe 控制器或卸载文件系统。

如果某型号固件曾在 NVMe 管理命令上卡住，推荐使用最稳妥的流程：`persist` → 正常重启 → `verify`。`apply` 的用户态超时不能强制打断 Linux 内核里不可中断的 NVMe 等待；这种极端情况下，等待时间仍可能达到内核的 `admin_timeout`。

系统重装会清除 `/etc` 和引导项中的持久化设置；安装新系统后需要重新运行 `apply`。仅升级内核或更换 PCIe 3.0/4.0 硬盘通常不需要修改脚本。

## 回归测试

```bash
deploy/scripts/tests/test_host_nvme_apst.sh
```

测试使用临时伪 sysfs、伪 GRUB 和伪 NVMe 命令，不会修改宿主机。
