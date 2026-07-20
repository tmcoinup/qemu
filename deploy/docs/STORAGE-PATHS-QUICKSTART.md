# G-11 VM 路径傻瓜教程

本文只讲一件事：每台 G-11 VM 使用一个完整、独立的 bundle，不再把同一台
VM 的磁盘、NVRAM、TPM、日志和运行文件散落在多个旧目录中。

## 先记住这三个命令

在仓库目录执行：

```bash
cd /home/ubuntu/projects/qemu

# 1. 使用默认位置，只看路径，不启动
./deploy/start-vm.sh 2 --print-paths

# 2. 使用默认位置，真正启动
./deploy/start-vm.sh 2

# 3. 精确指定一个完整 bundle，只看路径，不启动
./deploy/start-vm.sh 2 \
  --vm-dir /mnt/fast-vms/G-11/vm2 \
  --print-paths
```

`--print-paths` 只解析并显示路径：不创建目录、不写配置、不迁移文件，也不启动
QEMU。第一次整理路径时，永远先加它确认，再去掉它真正启动。

也可以只记住内置封装：

```bash
./deploy/vmctl.sh path 2
./deploy/vmctl.sh start 2
./deploy/vmctl.sh stop 2
./deploy/vmctl.sh status 2
```

自定义路径直接追加同一个 `--vm-dir` 或 `--instances-dir`；封装不会保存凭据或
建立隐藏映射。

## 默认目录长什么样

G-11 的默认根目录是：

```text
/home/ubuntu/images/vms/G-11
```

也就是默认 `VM_ROOT=/home/ubuntu/images/vms/G-11`，实例规则是
`$VM_ROOT/vm<ID>`。

默认的 VM 2 是：

```text
/home/ubuntu/images/vms/G-11/vm2
```

完整布局如下：

```text
/home/ubuntu/images/vms/
└── G-11/                         # G-11 的 VM_ROOT
    ├── shared/                   # 多台 G-11 VM 可共享的只读/模板资源
    │   ├── bases/
    │   └── assets/
    ├── control/                  # 全局锁、协调记录；不是 VM bundle
    ├── vm1/                      # VM 1 的完整 bundle
    │   ├── vm.conf
    │   ├── disk.qcow2
    │   ├── nvram.fd
    │   ├── tpm/
    │   ├── log/
    │   ├── run/
    │   └── backups/
    └── vm2/                      # VM 2 的完整 bundle
        ├── vm.conf
        ├── disk.qcow2
        ├── nvram.fd
        ├── tpm/
        ├── log/
        ├── run/
        └── backups/
```

每台 VM 的以下内容都必须留在自己的 bundle 内：

| 项目 | 作用 | 能否与另一台 VM 共用 |
|---|---|---:|
| `vm.conf` | VM ID、硬件身份和启动配置 | 否 |
| `disk.qcow2` | 该 VM 的可写系统盘 | 否 |
| `nvram.fd` | 该 VM 的 UEFI 变量 | 否 |
| `tpm/` | 该 VM 的 TPM 状态和私有资料 | 否 |
| `log/` | 该 VM 的日志 | 否 |
| `run/` | 该 VM 的 PID、socket 等可重建运行态 | 否 |
| `backups/` | 该 VM 自己的备份 | 否 |

只有 `shared/bases/` 和 `shared/assets/` 是 G-11 VM 之间的共享区。
`control/` 只放锁和协调记录，绝不能再把某台 VM 的磁盘、NVRAM 或 TPM 放进去。
`--vm-dir` 和 `--instances-dir` 只改变实例 bundle 的位置；在默认配置下，共享资源
和协调区仍分别是 `/home/ubuntu/images/vms/G-11/shared` 与
`/home/ubuntu/images/vms/G-11/control`。以 `--print-paths` 的实际输出为准。

## 三种选路径的方法

`<vm-id>` 必须是正整数。`ABS` 必须是绝对路径，即以 `/` 开头。自定义父目录必须
提前创建、可写且不能经过符号链接；完整的 `vm<ID>` 目标目录可以尚不存在，脚本会
在真正创建 VM 时生成它。

| 命令 | 最终 bundle | 适用场景 |
|---|---|---|
| `start-vm.sh ID` | `/home/ubuntu/images/vms/G-11/vm<ID>` | 日常默认用法 |
| `start-vm.sh ID --instances-dir ABS` | `ABS/vm<ID>` | 把一组 VM 放到同一块盘 |
| `start-vm.sh ID --vm-dir ABS` | 正好是 `ABS` | 精确选择单台 VM，`ABS` 末级必须是 `vm<ID>` |

### 用默认路径

```bash
./deploy/start-vm.sh 2 --print-paths
./deploy/start-vm.sh 2
```

两条命令选择的都是：

```text
/home/ubuntu/images/vms/G-11/vm2
```

### 指定一组 VM 的父目录

```bash
./deploy/start-vm.sh 2 \
  --instances-dir /mnt/nvme0/G-11-instances \
  --print-paths
```

最终 bundle 是：

```text
/mnt/nvme0/G-11-instances/vm2
```

这里脚本会自动追加 `vm2`。同一组中的 VM 3 可使用同一个父目录：

```bash
./deploy/start-vm.sh 3 \
  --instances-dir /mnt/nvme0/G-11-instances \
  --print-paths
```

它会选择 `/mnt/nvme0/G-11-instances/vm3`，不会与 VM 2 混用。

### 精确指定单台 VM 的 bundle

```bash
./deploy/start-vm.sh 2 \
  --vm-dir /mnt/nvme0/special/vm2 \
  --print-paths
```

最终 bundle 正好是：

```text
/mnt/nvme0/special/vm2
```

`--vm-dir` 不会再追加 `vm2`。因此参数必须直接指向包含 `vm.conf`、
`disk.qcow2`、`nvram.fd`、`tpm/` 等内容的完整 bundle，而且路径末级名称必须
与 ID 精确匹配：ID 2 只能使用末级为 `vm2` 的路径；末级为其他名称或 `vm3`
都会被拒绝。

`--vm-dir` 和 `--instances-dir` 是两种不同选择，不能同时使用。路径包含空格时，
必须用引号包住整个路径：

```bash
./deploy/start-vm.sh 2 \
  --vm-dir "/mnt/fast disk/G-11/vm2" \
  --print-paths
```

## 显式路径不会偷用旧文件

只要使用了 `--vm-dir` 或 `--instances-dir`，脚本就只认选中的 bundle。某个必需
文件缺失时应直接报错，不会再回退搜索这些旧位置：

```text
/home/ubuntu/images/vms/2              # V-11 候选，不属于 G-11 fallback
/home/ubuntu/images/vms/run/...
/home/ubuntu/images/vms/instances/...
/home/ubuntu/images/vms/win10-vm2.qcow2
```

这是故意的安全设计。例如明确选择了
`/mnt/nvme0/G-11-instances/vm2`，就不能读取这里的 `vm.conf`，却又偷偷使用默认
目录中的旧磁盘或 NVRAM。混搭可能造成启动错系统盘、UEFI 状态错配、BitLocker
恢复，甚至把一台 VM 的 TPM 身份交给另一台 VM。

如果 `--print-paths` 显示的位置不符合预期，不要启动；先修正参数或完成迁移。

## 把现在的散乱目录整理好

目前可能同时存在：

```text
/home/ubuntu/images/vms/2                 # V-11 的现行候选
/home/ubuntu/images/vms/run/              # G-11 旧协调锁和清单
/home/ubuntu/images/vms/instances/vm...   # G-11 旧 bundle
```

三者不能混为一类。本次 G-11 bundle 迁移的来源范围严格限定为
`/home/ubuntu/images/vms/instances/vm<ID>`。`/home/ubuntu/images/vms/2` 留给
V-11，必须原地保留或在 V-11 流程中另行处理，绝不能自动迁到 G-11，也不能拿其中
任何文件补齐 G-11 的 VM 2。

不要按目录名猜哪一份是有效 VM，也不要把几处同 ID 的文件直接合并。整理原则是：

1. 每个分支内的每个 ID 最终只有一个完整 bundle；V-11 与 G-11 的同号 ID 仍是
   两台独立 VM。
2. 一台 VM 的配置、磁盘、NVRAM 和 TPM 必须成组迁移。
3. 根 `run/` 是 G-11 的旧全局协调区，只包含锁、清单等协调数据，不是任何 VM 的
   bundle；不能把它迁入 `vm<ID>`。
4. 同一个 ID 若在两处都有磁盘或 NVRAM，视为冲突。先人工确认哪份是正确实例，
   另一份先隔离备份，绝不能覆盖或拼接。

新布局使用 `/home/ubuntu/images/vms/G-11/control` 承担全局协调职责。旧根
`run/` 不作为 bundle 迁移来源；迁移器只保留已识别的迁移清单并删除经过确认的
空锁。出现未知文件、非空锁或符号链接时会直接 `BLOCKED`，不得手工绕过检查。

### 第一步：全部停机

必须先在 Windows 中正常关机，再确认相关 QEMU 已退出。仍在运行时，禁止移动、
复制后删除或重命名 qcow2、NVRAM、TPM、PID 和 socket。

使用默认位置时，可以先按现有管理方式停止每个 VM，例如：

```bash
cd /home/ubuntu/projects/qemu
./deploy/stop-vm.sh 2
./deploy/stop-vm.sh 3
```

使用过自定义路径的 VM，停止时必须传入与启动时完全相同的选择器。例如：

```bash
# 启动时使用了 --vm-dir
./deploy/stop-vm.sh 2 \
  --vm-dir /mnt/nvme0/special/vm2

# 启动时使用了 --instances-dir
./deploy/stop-vm.sh 3 \
  --instances-dir /mnt/nvme0/G-11-instances
```

不要用默认路径的 `stop-vm.sh ID` 去停止一台从自定义 bundle 启动的 VM；否则可能
查看错误的 PID、QMP socket 或 mdev 协调记录。

然后只读检查是否仍有 QEMU：

```bash
pgrep -a qemu-system-x86_64 || true
```

看到任何相关 VM 进程，都不要继续迁移。仅仅“窗口关了”或“找不到 PID 文件”
不能证明 VM 已停机。

### 第二步：只读盘点

先运行封装好的只读检查，不做删除：

```bash
./deploy/vmctl.sh migrate --check
```

它只计划旧 G-11 `instances/vm<ID>`、共享 base/assets 和旧协调区；V-11 数字目录
始终显示为 out of scope。权限不足、仍有 QEMU/swtpm、打开文件、目标冲突、
非 standalone qcow2 或跨文件系统都会 `BLOCKED`。若旧 bundle 内有 root-only
TPM/备份，先通过批准的管理员渠道取得权限，再用交互式 `sudo` 复查：

```bash
sudo ./deploy/vmctl.sh migrate --check
```

不要把 sudo 密码写入命令、脚本或仓库。之后若同样使用 `sudo ... --apply`，迁移器
会把新建的 G-11 根、共享容器和协调目录所有权恢复给发起 sudo 的原用户；移动的
VM payload 保持原有 owner/mode。

需要人工复核时再列出旧目录：

```bash
find /home/ubuntu/images/vms \
  -maxdepth 4 \
  \( -name vm.conf -o -name '*.qcow2' -o -name '*.fd' -o -name '*.sock' \) \
  -print
```

按 VM ID 记录 `vms/instances/vm<ID>` 中每一份 `vm.conf`、磁盘、NVRAM 和 TPM。
`vms/2` 只登记为 V-11 候选，不参与 G-11 内容比较或合并；`vms/run` 只登记为
G-11 旧协调区，不登记为 VM。

### 第三步：确定唯一目标

推荐把 G-11 VM 统一到默认布局：

| 旧位置示例 | 新位置 |
|---|---|
| `/home/ubuntu/images/vms/instances/vm2` | `/home/ubuntu/images/vms/G-11/vm2` |
| `/home/ubuntu/images/vms/instances/vm3` | `/home/ubuntu/images/vms/G-11/vm3` |
| `/home/ubuntu/images/vms/instances/vm4` | `/home/ubuntu/images/vms/G-11/vm4` |

`/home/ubuntu/images/vms/2` 不在此表中，因为它是 V-11 现行候选，没有任何自动
G-11 目标。

如果 VM 已经在另一块盘形成完整 bundle，也可以不搬回默认位置，而是用
`--vm-dir` 精确选择它，或用 `--instances-dir` 统一选择那块盘上的父目录。

同一文件系统且 `--check` 已显示 `CHECK OK` 时，显式应用原子目录迁移：

```bash
sudo ./deploy/vmctl.sh migrate --apply
```

迁移的是整个 bundle，不能只搬 `disk.qcow2`。工具拒绝隐式跨文件系统复制；确需
跨盘时应另做完整复制、校验和切换计划，验证新位置后才按精确路径清理旧目录。

### 第四步：启动前核对

对每台 VM 都先执行：

```bash
./deploy/start-vm.sh 2 --print-paths
```

如果用了自定义父目录：

```bash
./deploy/start-vm.sh 2 \
  --instances-dir /mnt/nvme0/G-11-instances \
  --print-paths
```

如果用了精确 bundle：

```bash
./deploy/start-vm.sh 2 \
  --vm-dir /mnt/nvme0/special/vm2 \
  --print-paths
```

确认显示的配置、磁盘、NVRAM、TPM、日志和 runtime 全部属于同一个 bundle，
再去掉 `--print-paths`，一次只启动一台并验证。

### 第五步：最后才清理旧目录

只有同时满足以下条件才删除旧文件：

- 新 bundle 已完整备份；
- `--print-paths` 的所有实例路径都正确；
- 新位置的 VM 已成功启动、关机并再次启动；
- 已确认没有 qcow2 backing chain、挂载、NBD 或进程仍引用旧路径；
- 同一 ID 没有未处理的冲突副本。

不要直接执行带通配符的 `rm -rf /home/ubuntu/images/vms/*`。更稳妥的做法是先把
确认无用的旧目录改名为带日期的隔离目录，完成一轮验证后再按精确绝对路径删除。
`control/` 中仍在使用的锁也不要手工删除。

## 固定路径的小封装

若一台 VM 永远放在同一自定义位置，可以在仓库外创建一个不含凭据的启动包装器：

```bash
#!/usr/bin/env bash
set -euo pipefail

exec /home/ubuntu/projects/qemu/deploy/start-vm.sh \
  2 \
  --vm-dir /mnt/nvme0/special/vm2 \
  "$@"
```

先用包装器传入 `--print-paths` 检查：

```bash
/usr/local/bin/start-g11-vm2 --print-paths
```

包装器只固定 VM ID 和路径。不要在脚本、`vm.conf`、systemd unit 或仓库中写宿主机
用户名、密码、token、私钥等凭据。确实需要凭据时，通过批准的安全渠道或运行时
环境变量提供。

## V-11 和 G-11 必须独立

V-11 与 G-11 是两个独立分支；G-11 是 vGPU 方案。即使两边有相同文件名或部分
配置，也不能让它们指向同一个可写 bundle、`disk.qcow2`、`nvram.fd`、`tpm/`、
`run/` 或 `control/`。

推荐至少按方案分根：

```text
/home/ubuntu/images/vms/V-11/...
/home/ubuntu/images/vms/G-11/...
```

共享 base 前也必须明确验证其用途和只读属性；不能因为两个分支“看起来相同”就
直接共享某台 VM 的可写磁盘或身份状态。切换分支不会自动迁移 VM 数据。

## 安全红线

这次只是宿主机上的 VM 存储路径整理，不需要也不允许通过降低 Windows 内核安全性
来“修复”启动问题：

- 不开启 `testsigning`；
- 不开启 `nointegritychecks`；
- 不修改 BCD；
- 不安装任何测试签名或自签名的内核驱动；
- 不把宿主机凭据写入仓库。

迁移后如果 Windows 进入恢复界面，先检查该 VM 是否配到了错误的磁盘、NVRAM 或
TPM。不要用关闭签名校验、修改 BCD 或安装不可信驱动来掩盖路径混用问题。
