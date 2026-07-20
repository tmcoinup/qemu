# VM 镜像与配置存储布局

## 结论

不是所有“镜像”都放在 `/home/ubuntu/images/vms`：

- Windows 安装 ISO 放在 `/home/ubuntu/images/iso`；省略启动参数时默认文件名为
  `win10.iso`；
- guest 驱动和安装产物放在 `/home/ubuntu/images/staging`；新的
  `VgpuPortable.exe` 完全离线并注入 base，不依赖 8080 HTTP，只有明确标记的
  legacy 调试流程才使用 staging HTTP；
- VM 的实例目录、共享 base、host 资源和全局控制文件才属于 `VM_ROOT`，默认是
  `/home/ubuntu/images/vms`。

生产 vGPU 工具链使用“一个 VM 一个目录，共享资源集中管理”的布局：

```text
/home/ubuntu/images/                    # IMAGE_ROOT
├── iso/                                # 只读安装介质 (*.iso)
├── staging/                            # 驱动、token、guest 脚本；不是 VM 镜像
└── vms/                                # VM_ROOT
    ├── bases/
    │   ├── win10-base.qcow2           # 公共、独立的克隆基线
    │   └── archive/                    # promote-base 归档的旧 base
    ├── assets/aero_arrow.cur           # host UI 资源
    ├── run/                             # 实例目录外的稳定协调区
    │   ├── .storage.lock               # 全局存储锁
    │   ├── vmN.start.lock              # 每 VM 启动锁
    │   ├── vmN.disk.lock               # 每 VM 写操作锁
    │   ├── vmN.tpm.lock                # 每 VM swtpm 生命周期锁
    │   └── storage-migration-*.tsv      # 迁移清单
    └── instances/
        └── vmN/
            ├── vm.conf                 # 持久硬件身份和启动配置（0444）
            ├── disk.qcow2              # 该 VM 唯一的可写系统盘
            ├── nvram.fd                # 该 VM 的 UEFI 变量
            ├── tpm/
            │   ├── state/              # 持久 TPM 1.2/2.0 NVRAM、EK/Platform cert
            │   └── config/             # 该 VM 私有 local CA 配置与密钥
            ├── log/
            │   ├── qemu.log            # 所有启动模式的 QEMU stderr
            │   └── swtpm.log
            ├── run/                    # 可重建的 pid/socket/mdev recovery；安装时的 autounattend.iso
            │   ├── qemu.pid
            │   ├── qmp.sock
            │   ├── monitor.sock
            │   ├── mdev.uuid
            │   ├── swtpm.pid
            │   └── swtpm.sock
            └── backups/
                ├── disks/
                └── nvram/
```

共享 OVMF code 在仓库的 `deploy/host/OVMF_CODE_4M_stealth.fd`，OVMF VARS 模板
通常是 `/usr/share/OVMF/OVMF_VARS_4M.fd`。它们是模板，不是某一台 VM 的运行数据。

## 各目录的生命周期

| 分类 | 是否必须备份 | 是否可直接删除 | 说明 |
|---|---:|---:|---|
| `instances/vmN/vm.conf` | 是 | 否 | UUID、MAC、硬件身份与 GPU profile |
| `instances/vmN/disk.qcow2` | 是 | 否 | Windows 和用户数据；每台 VM 独立可写 |
| `bases/` | 建议 | 否 | 新实例的公共来源；`delete-vm.sh` 不会删除 |
| `instances/vmN/nvram.fd` | 是 | 否 | UEFI boot entries，应与配置/磁盘成组备份 |
| `instances/vmN/tpm/` | 是 | 否 | 持久 TPM NVRAM、EK/Platform cert 与私有 CA；删除等同更换物理 TPM |
| `instances/vmN/run/` | 否 | 停机后可清理 | socket、PID、mdev recovery |
| `instances/vmN/log/` | 按需 | 是 | 该 VM 的排障日志 |
| `vms/run/` | 否 | 不要手工删除锁 | 全局锁、每 VM 协调锁和迁移清单 |
| `assets/` | 建议 | 可从仓库/模板恢复 | host 窗口资源 |
| `iso/` | 按需 | 未挂载时可删 | Windows 安装介质，不属于 `VM_ROOT` |
| `staging/` | 可重建 | 未安装时可清理 | 不是系统盘；portable EXE 从这里安全注入 base，驱动版本仍必须校验 |

备份一台 VM 时可以直接保存整个 bundle；至少必须包含：

```text
instances/vmN/vm.conf
instances/vmN/disk.qcow2
instances/vmN/nvram.fd
instances/vmN/tpm/
```

`bases/win10-base.qcow2` 必须是既没有 backing file、也没有 qcow2 external
data-file 的 standalone qcow2。
`create-disk.sh` 会先验证 base 格式、backing 和一致性，再复制到同目录临时文件；
只有 `qemu-img check` 成功才原子发布为 `instances/vmN/disk.qcow2`。失败或中断不会
留下一个被后续启动器误认成有效系统盘的最终文件。

`start-vm.sh N` 缺盘时使用严格的 `create-disk.sh N --from-base`，base 缺失就拒绝；
`start-vm.sh N --install [ISO]` 缺盘时使用 `--blank`，不受公共 base 影响。两者都不
覆盖已有实例盘。
每次非 dry-run 启动还会用 `qemu-img` 核对实例盘 virtual-size 和
`vm.conf` 的 `SSD_SIZE_BYTES`；不等时拒绝启动，不会静默 resize 或改分区。

## 从前两代布局迁移

启动器可以读取最早的平铺布局、上一版按类型分类布局和当前实例布局；新文件只写入
`instances/vmN/`。迁移器把前两代来源统一到实例目录：

| 旧路径 | 新路径 |
|---|---|
| `vms/win10-vmN.qcow2` 或 `vms/disks/win10-vmN.qcow2` | `vms/instances/vmN/disk.qcow2` |
| `vms/win10-vmN.qcow2.*` 或 `vms/disks/archive/win10-vmN.qcow2.*` | `vms/instances/vmN/backups/disks/` |
| `vms/configs/vmN.conf` | `vms/instances/vmN/vm.conf` |
| `vms/win10-base.qcow2` | `vms/bases/win10-base.qcow2` |
| `vms/win10-base.qcow2.*` | `vms/bases/archive/` |
| `vms/vmN_VARS.fd` 或 `vms/nvram/vmN_VARS.fd` | `vms/instances/vmN/nvram.fd` |
| 两代 NVRAM 备份路径 | `vms/instances/vmN/backups/nvram/` |
| `vms/log/vmN.log` | `vms/instances/vmN/log/qemu.log` |
| `images/*.iso` | `images/iso/` |

先做只读检查：

```bash
cd /home/ubuntu/projects/qemu
./deploy/migrate-vm-storage.sh --check
```

迁移必须停掉所有生产 vGPU VM：

```bash
# 先在各 guest 正常关机；必要时按数字 ID 停止
./deploy/stop-vm.sh 1

# 确认 check 不再报告 QEMU、mdev、打开文件、backing 或目标冲突
./deploy/migrate-vm-storage.sh --check

# 显式执行；同一文件系统内使用原子 rename，不复制 512 GB 表观容量
./deploy/migrate-vm-storage.sh --apply
```

迁移器具备以下保护：

- 默认只是 check，只有 `--apply` 才移动；
- `--apply` 在生成计划前先取得独占 `.storage.lock`，避免验证后由其它生命周期脚本
  创建同名目标；移动中断时会按已完成顺序反向回滚；
- 三代路径中同一逻辑文件存在多份且不是同一 inode 时拒绝选择；
- QEMU、忙碌的 start/disk lock、mdev recovery record、PID/socket 残留或任一打开文件存在时拒绝；
- PID、QMP、monitor 和 mdev recovery 不做 rename；它们必须在停机时由
  `stop-vm.sh` 清理，下次启动会直接在实例 `run/` 中重建；
- 每个待移动的 qcow2 都必须能被严格解析；metadata 损坏或伪装成 `.qcow2` 的
  raw 文件会阻断，而不是当成“无 backing”放行；
- 待移动 qcow2 只允许 standalone；相对或绝对 backing 都会阻断，避免换目录后
  相对路径改义；external data-file 同样会阻断，避免链断裂或多台 VM 共享可写
  payload；
- `file:`、`json:`、网络 block protocol 等非普通 POSIX backing/data-file 引用
  不做猜测解析，直接 fail-closed；
- 扫描 `IMAGE_ROOT` 以及显式配置在其外部的 `VM_DISK_DIR`、`VM_BASE_DIR` 和归档
  目录；任何 overlay 依赖待移动文件时阻断，即使该 overlay 属于不会被迁移的
  旧数字目录布局；
- 通过 `qemu-img info --backing-chain` 检查完整递归链，不只看第一层；链中的
  qcow2/raw 层或 external data-file 只要指向本次任一计划源（包括 ISO），就阻断；
- 扫描会跟随托管目录内的文件/目录 symlink，并在循环或 metadata 无法验证时阻断；
  待迁移的 ISO、NVRAM、qcow2 等源文件本身若是 symlink 也拒绝移动，防止相对链接
  换目录后失效；
- 只允许同一文件系统原子移动，拒绝隐式跨盘复制；
- 写入全局 `vms/run/storage-migration-*.tsv` 清单，重复执行是幂等的；
- 不删除旧 base 或 NVRAM 备份，只把它们归档。

任一 VM 仍在运行时，`--check` 报告 blocked 是正确结果；不要为了整理目录在线
`mv` 已打开的 qcow2、NVRAM、配置或日志。

`promote-base.sh` 替换公共 base 时会取得独占存储锁，因此要求所有生产 VM 停止；
它还会扫描所有托管目录中的 overlay。即使 base 文件当前缺失，只要某个 overlay
仍记录目标 base 路径，也会拒绝在该路径发布不相关的新内容。脚本不会猜测 rebase
策略；需要 overlay 的环境应先人工 flatten/rebase 并逐盘验证。

`delete-vm.sh` 使用同样的依赖扫描：若其它 qcow2 把 vmN 系统盘当 backing，删除会
被拒绝；无法解析其它托管 qcow2 metadata 时也不会放行。这样不会为了清理一台 VM
而破坏另一条 overlay 链。

## 唯一受管理布局

`deploy/create-vm.sh`、`deploy/create-disk.sh`、`deploy/start-vm.sh` 和
`deploy/stop-vm.sh` 统一管理 `instances/vmN/`。旧数字目录（如 `vms/<N>/` 和
`vms/_base/`）不属于本分支生命周期，迁移器不会自动移动或删除其中的数据。

## 自定义根目录

默认变量由 `deploy/lib/vm-storage.sh` 统一定义：

```bash
IMAGE_ROOT=/home/ubuntu/images
ISO_DIR=$IMAGE_ROOT/iso
STAGE_DIR=$IMAGE_ROOT/staging
VM_ROOT=$IMAGE_ROOT/vms
VM_INSTANCES_DIR=$VM_ROOT/instances
VM_BASE_DIR=$VM_ROOT/bases
VM_ASSET_DIR=$VM_ROOT/assets
VM_RUN_DIR=$VM_ROOT/run                  # 全局锁/清单，不是实例 runtime

# 下面是前两代布局的兼容读取/迁移来源；新文件不再写入这些目录。
VM_CONFIG_DIR=$VM_ROOT/configs
VM_DISK_DIR=$VM_ROOT/disks
VM_NVRAM_DIR=$VM_ROOT/nvram
VM_LOG_DIR=$VM_ROOT/log
```

把整套数据放到其它挂载点时，优先只覆盖 `IMAGE_ROOT` 或 `VM_ROOT`；只把实例放到
独立磁盘时显式设置 `VM_INSTANCES_DIR`。旧自动化若只设置 `VM_DISK_DIR`，脚本仍会
把它当作实例磁盘挂载点并保留旧 base/NVRAM 解析语义，但新部署不要依赖该兼容行为。
