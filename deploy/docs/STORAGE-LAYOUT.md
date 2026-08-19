# VM 镜像与配置存储布局

## 结论

G-11 现在参考 V-11 的实例分类方式：默认直接使用
`/home/ubuntu/images/vms/<数字ID>`，不再创建 `G-11/` 或 `vm<ID>/` 这一层。

一台 VM 的配置、磁盘、NVRAM、TPM、日志、备份、PID、socket 和生命周期锁都放在
自己的数字目录中。删除整台 VM 时只处理这一个目录，不会再在全局 `control/` 留下
`vm2.start.lock`、`vm2.disk.lock`、`vm2.tpm.lock` 一类残留。

```text
/home/ubuntu/images/                    # IMAGE_ROOT
├── iso/                                # Windows 安装 ISO；不是某台 VM 的状态
├── staging/                            # guest 安装产物；不是系统盘
└── vms/                                # VMS_DIR / VM_ROOT（默认）
    ├── 1/                              # VM 1 的完整 bundle
    ├── 2/                              # VM 2 的完整 bundle
    │   ├── vm.conf                     # 持久硬件身份和启动配置
    │   ├── disk.qcow2                  # 该 VM 唯一的可写系统盘
    │   ├── nvram.fd                    # 该 VM 独立的 UEFI 变量
    │   ├── tpm/
    │   │   ├── state/                  # TPM 持久状态
    │   │   └── config/                 # 该 VM 私有的 local CA 配置
    │   ├── log/
    │   │   ├── qemu.log
    │   │   └── swtpm.log
    │   ├── run/                        # 该 VM 的运行态与锁
    │   │   ├── qemu.pid
    │   │   ├── qmp.sock
    │   │   ├── monitor.sock
    │   │   ├── mdev.uuid
    │   │   ├── swtpm.pid
    │   │   ├── swtpm.sock
    │   │   ├── start.lock
    │   │   ├── disk.lock
    │   │   ├── tpm.lock
    │   │   ├── optical.lock
    │   │   └── usb-directory.lock
    │   └── backups/
    │       ├── disks/
    │       └── nvram/
    ├── shared/                         # 多台 G-11 VM 共用的模板/资源
    │   ├── bases/
    │   │   ├── win10-ltsc-v1.qcow2
    │   │   ├── win10-ltsc-v1.qcow2.vgpu-portable.json
    │   │   ├── win11-vgpu-v2.qcow2
    │   │   ├── win11-vgpu-v2.qcow2.vgpu-portable.json
    │   │   └── archive/
    │   ├── assets/
    │   └── usb/                        # 多台 VM 共用的只读工具 U 盘根目录
    │       ├── G11GuestLite/
    │       ├── G11GuestPerformance/
    │       └── 其他工具各自的目录/
    └── control/                        # 只允许全局协调数据
        ├── .storage.lock
        └── history/                    # 旧布局迁移记录（存在迁移时）
```

`control/.storage.lock` 是整套存储的全局协调锁，不属于某台 VM，也不是删除 VM 后的
残留。每台 VM 的零字节锁文件则位于该 VM 的 `run/`；停止后保留是正常现象，
删除整个数字目录时会一起删除。

共享 OVMF code 在仓库的 `deploy/host/OVMF_CODE_4M_stealth.fd`，OVMF VARS 模板
通常位于 `/usr/share/OVMF/OVMF_VARS_4M.fd`。模板不是某台 VM 的运行数据；从模板
生成的 `nvram.fd` 必须放回该 VM 的数字目录。

## 生命周期与备份

| 路径 | 是否备份 | 停机后能否单独清理 | 说明 |
|---|---:|---:|---|
| `<ID>/vm.conf` | 必须 | 否 | UUID、MAC、硬件身份、GPU profile |
| `<ID>/disk.qcow2` | 必须 | 否 | Windows 和用户数据 |
| `<ID>/nvram.fd` | 必须 | 否 | UEFI boot 状态，应与磁盘成组恢复 |
| `<ID>/tpm/` | 必须 | 否 | 删除等同于更换 TPM，可能触发密钥/BitLocker 恢复 |
| `<ID>/run/` | 不必 | 可重建 | PID、socket、mdev recovery 和每 VM 锁 |
| `<ID>/log/` | 按需 | 可以 | 该 VM 的排障日志 |
| `<ID>/backups/` | 视内容 | 否 | 该 VM 自己的历史磁盘/NVRAM |
| `shared/bases/` | 建议 | 否 | 新实例来源，不随单台 VM 删除 |
| `shared/assets/` | 建议 | 可重建 | host UI 资源 |
| `shared/usb/` | 按需 | 可以 | 公共只读工具 U 盘；每个工具只管理自己的子目录 |
| `control/` | 不必 | 不要手删 | 全局协调锁和迁移记录 |

备份和恢复时，最稳妥的办法是让 VM 完整关机后复制整个 `<ID>/`。至少要把
`vm.conf`、`disk.qcow2`、`nvram.fd` 和 `tpm/` 作为同一组处理。

`shared/bases/<BASE_NAME>.qcow2` 必须是没有 backing file、也没有 external
data-file 的 standalone qcow2。每个镜像的 portable 证明紧邻它并使用
`<BASE_NAME>.qcow2.vgpu-portable.json`；clone 必须点名，绝不猜测“最新”镜像。
创建磁盘、替换 base、迁移和删除脚本都会检查 qcow2 依赖；无法证明安全时会拒绝
操作，不会猜测 rebase 策略。

## V-11 与 G-11 的边界

两个分支都采用 `vms/<数字ID>` 的分类方式，但它们仍是独立方案，不能把同号目录
里的文件互相补齐或合并。

G-11 在写入数字目录前会检查 V-11 的典型状态标记：`profile`、`ovmf-vars.fd`、
`tpm-state/`、`tpm12-state/`。发现这些标记时会拒绝启动、创建或迁移。处理方式只有
两种：为 G-11 使用未占用的 ID，或用 `--vms-dir` 指向另一套完整根目录。

## 指定整套存储目录

默认值由 `deploy/lib/vm-storage.sh` 统一定义：

```bash
IMAGE_ROOT=/home/ubuntu/images
VMS_DIR=$IMAGE_ROOT/vms
VM_ROOT=$VMS_DIR
VM_INSTANCES_DIR=$VM_ROOT
VM_SHARED_DIR=$VM_ROOT/shared
VM_BASE_DIR=$VM_SHARED_DIR/bases
VM_ASSET_DIR=$VM_SHARED_DIR/assets
VM_CONTROL_DIR=$VM_ROOT/control
VM_RUN_DIR=$VM_CONTROL_DIR          # 兼容变量名；不是实例 run/
```

推荐用 `--vms-dir ABS` 一次移动整套根目录，包括数字 VM、`shared/` 和 `control/`：

```bash
./deploy/scripts/vmctl.sh path 2 --vms-dir /mnt/fast/vms
./deploy/scripts/vmctl.sh start 2 --vms-dir /mnt/fast/vms
./deploy/scripts/vmctl.sh stop 2 --vms-dir /mnt/fast/vms
./deploy/scripts/vmctl.sh delete 2 --vms-dir /mnt/fast/vms
```

也可以通过运行时环境变量 `VMS_DIR=/mnt/fast/vms` 指定；不要把宿主机凭据写入
仓库、配置或封装脚本。

`--vm-dir /mnt/fast/vms/2` 只精确选择单台 VM，末级目录必须正好是数字 ID。
`--instances-dir` 为旧调用兼容保留，只改变实例父目录而不移动 `shared/control`；
新部署优先使用语义完整的 `--vms-dir`。

## 从旧 G-11 布局迁移

迁移器识别两代旧来源：

```text
/home/ubuntu/images/vms/G-11/vmN
/home/ubuntu/images/vms/instances/vmN
```

目标统一为：

```text
/home/ubuntu/images/vms/N
```

先停止所有 G-11 VM，再执行只读检查：

```bash
cd /home/ubuntu/projects/qemu
./deploy/scripts/vmctl.sh migrate --check
```

只有输出 `CHECK OK` 才应用：

```bash
./deploy/scripts/vmctl.sh migrate --apply
```

若检查遇到 root-owned TPM/备份目录并报告 `Permission denied`，在交互终端只通过
运行时 sudo 重跑；密码不要写入仓库或脚本：

```bash
sudo -v
sudo ./deploy/scripts/vmctl.sh migrate --check
sudo ./deploy/scripts/vmctl.sh migrate --apply     # 仍然只在 CHECK OK 后执行
```

sudo 模式只为完整读取和移动原 bundle；迁移器会把新建的根协调目录所有权恢复给
原调用用户，bundle 内原有文件的所有权和权限保持不变。

迁移器会一起整理旧 `bases/assets`、清除确认未被占用的旧平铺 VM 锁，并在安全时
移除空的 `G-11/` 目录。任一数字目标已存在、两代旧来源使用同一 ID、VM 仍运行、
锁被占用、存在 symlink、qcow2 不是 standalone，或外部 overlay 依赖旧路径，都会
`BLOCKED`；它绝不覆盖或合并目标。

迁移到自定义根目录时，同一参数表示目标：

```bash
./deploy/scripts/vmctl.sh migrate --check --vms-dir /mnt/fast/vms
./deploy/scripts/vmctl.sh migrate --apply --vms-dir /mnt/fast/vms
```

完整可复制教程见
[`STORAGE-PATHS-QUICKSTART.md`](STORAGE-PATHS-QUICKSTART.md)。
