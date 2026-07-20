# VM 镜像与配置存储布局

## 结论

不是所有“镜像”都放在 `/home/ubuntu/images/vms`：

- Windows 安装 ISO 放在 `/home/ubuntu/images/iso`；省略启动参数时默认文件名为
  `win10.iso`；
- guest 驱动和安装产物放在 `/home/ubuntu/images/staging`；新的
  `VgpuPortable.exe` 完全离线并注入 base，不依赖 8080 HTTP，只有明确标记的
  legacy 调试流程才使用 staging HTTP；
- G-11 的实例目录、共享 base、host 资源和全局控制文件才属于 `VM_ROOT`，默认是
  `/home/ubuntu/images/vms/G-11`。V-11 使用独立分支和独立数据布局。

生产 vGPU 工具链使用“一个 VM 一个目录，共享资源集中管理”的布局：

```text
/home/ubuntu/images/                    # IMAGE_ROOT
├── iso/                                # 只读安装介质 (*.iso)
├── staging/                            # 驱动、token、guest 脚本；不是 VM 镜像
└── vms/
    ├── N/                              # V-11 旧/现行数字实例；G-11 不碰
    └── G-11/                           # G-11 VM_ROOT
        ├── shared/
        │   ├── bases/
        │   │   ├── win10-base.qcow2   # 公共、独立的克隆基线
        │   │   └── archive/
        │   └── assets/aero_arrow.cur  # host UI 资源
        ├── control/                    # 全局协调区，不是某台 VM 的 runtime
        │   ├── .storage.lock
        │   ├── vmN.start.lock
        │   ├── vmN.disk.lock
        │   └── vmN.tpm.lock
        └── vmN/                        # 一台 G-11 VM 的完整独立 bundle
            ├── vm.conf                 # 持久硬件身份和启动配置（0444）
            ├── disk.qcow2              # 该 VM 唯一的可写系统盘
            ├── nvram.fd                # 该 VM 的 UEFI 变量
            ├── tpm/
            │   ├── state/              # 持久 TPM 1.2/2.0 NVRAM、EK/Platform cert
            │   └── config/             # 该 VM 私有 local CA 配置与密钥
            ├── log/
            │   ├── qemu.log            # 所有启动模式的 QEMU stderr
            │   └── swtpm.log
            ├── run/                    # 可重建的 pid/socket/mdev recovery
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
| `vmN/vm.conf` | 是 | 否 | UUID、MAC、硬件身份与 GPU profile |
| `vmN/disk.qcow2` | 是 | 否 | Windows 和用户数据；每台 VM 独立可写 |
| `shared/bases/` | 建议 | 否 | 新实例的公共来源；`delete-vm.sh` 不会删除 |
| `vmN/nvram.fd` | 是 | 否 | UEFI boot entries，应与配置/磁盘成组备份 |
| `vmN/tpm/` | 是 | 否 | 持久 TPM NVRAM、EK/Platform cert 与私有 CA；删除等同更换物理 TPM |
| `vmN/run/` | 否 | 停机后可清理 | socket、PID、mdev recovery |
| `vmN/log/` | 按需 | 是 | 该 VM 的排障日志 |
| `control/` | 否 | 不要手工删除锁 | 全局锁和每 VM 协调锁 |
| `shared/assets/` | 建议 | 可从仓库/模板恢复 | host 窗口资源 |
| `iso/` | 按需 | 未挂载时可删 | Windows 安装介质，不属于 `VM_ROOT` |
| `staging/` | 可重建 | 未安装时可清理 | 不是系统盘；portable EXE 从这里安全注入 base，驱动版本仍必须校验 |

备份一台 VM 时可以直接保存整个 bundle；至少必须包含：

```text
vmN/vm.conf
vmN/disk.qcow2
vmN/nvram.fd
vmN/tpm/
```

`shared/bases/win10-base.qcow2` 必须是既没有 backing file、也没有 qcow2 external
data-file 的 standalone qcow2。
`create-disk.sh` 会先验证 base 格式、backing 和一致性，再复制到同目录临时文件；
只有 `qemu-img check` 成功才原子发布为 `vmN/disk.qcow2`。失败或中断不会
留下一个被后续启动器误认成有效系统盘的最终文件。

`start-vm.sh N` 缺盘时使用严格的 `create-disk.sh N --from-base`，base 缺失就拒绝；
`start-vm.sh N --install [ISO]` 缺盘时使用 `--blank`，不受公共 base 影响。两者都不
覆盖已有实例盘。
每次非 dry-run 启动还会用 `qemu-img` 核对实例盘 virtual-size 和
`vm.conf` 的 `SSD_SIZE_BYTES`；不等时拒绝启动，不会静默 resize 或改分区。

## 从旧 G-11 布局迁移

旧 G-11 bundle 位于 `/home/ubuntu/images/vms/instances/vmN`；新布局把整个 bundle
原子移动到 `/home/ubuntu/images/vms/G-11/vmN`。旧共享 `bases/`、`assets/`
分别归入 `G-11/shared/bases/`、`G-11/shared/assets/`。旧根 `run/` 不是 VM
bundle：迁移器只把旧迁移清单保存在 `G-11/control/history/`，并删除经过确认的
空锁文件；任何未知或非空条目都会阻止迁移。

`/home/ubuntu/images/vms/<N>` 是 V-11 的数字实例候选，迁移器明确忽略，绝不会
把它与同 ID 的 G-11 bundle 合并。

先执行完全只读的检查：

```bash
cd /home/ubuntu/projects/qemu
./deploy/migrate-g11-layout.sh --check
```

当前 VM、swtpm、NBD、打开文件、权限、目标冲突、symlink、非 standalone qcow2
或跨文件系统任一项不安全时，check 都会报告 `BLOCKED`。先正常停止所有 G-11 VM；
确认 check 为 `CHECK OK` 后才执行：

```bash
./deploy/migrate-g11-layout.sh --apply
```

`--apply` 同时取得旧、新两代全局锁，目录移动使用同文件系统原子 rename；中途失败
会反向恢复已完成的 bundle rename。旧迁移清单保存在新 `control/history/`，可重建
的空锁文件不作为 VM 数据迁移。不要为了通过检查而在线移动 qcow2、NVRAM、TPM
或删除仍被占用的锁。

完整逐步教程、指定路径和停机示例见
[`STORAGE-PATHS-QUICKSTART.md`](STORAGE-PATHS-QUICKSTART.md)。

`promote-base.sh` 替换公共 base 时会取得独占存储锁，因此要求所有生产 VM 停止；
它还会扫描所有托管目录中的 overlay。即使 base 文件当前缺失，只要某个 overlay
仍记录目标 base 路径，也会拒绝在该路径发布不相关的新内容。脚本不会猜测 rebase
策略；需要 overlay 的环境应先人工 flatten/rebase 并逐盘验证。

`delete-vm.sh` 使用同样的依赖扫描：若其它 qcow2 把 vmN 系统盘当 backing，删除会
被拒绝；无法解析其它托管 qcow2 metadata 时也不会放行。这样不会为了清理一台 VM
而破坏另一条 overlay 链。

## 唯一受管理布局

`deploy/create-vm.sh`、`deploy/create-disk.sh`、`deploy/start-vm.sh` 和
`deploy/stop-vm.sh` 统一管理 `$VM_ROOT/vmN/`。旧数字目录（如 `vms/<N>/` 和
`vms/_base/`）不属于 G-11 生命周期，迁移器不会自动移动或删除其中的数据。

## 自定义根目录

默认变量由 `deploy/lib/vm-storage.sh` 统一定义：

```bash
IMAGE_ROOT=/home/ubuntu/images
ISO_DIR=$IMAGE_ROOT/iso
STAGE_DIR=$IMAGE_ROOT/staging
VM_ROOT=$IMAGE_ROOT/vms/G-11
VM_INSTANCES_DIR=$VM_ROOT
VM_SHARED_DIR=$VM_ROOT/shared
VM_BASE_DIR=$VM_SHARED_DIR/bases
VM_ASSET_DIR=$VM_SHARED_DIR/assets
VM_CONTROL_DIR=$VM_ROOT/control
VM_RUN_DIR=$VM_CONTROL_DIR               # 兼容变量名；不是实例 runtime

# 仅供显式兼容/迁移工具使用；正常启动默认不回退到这些目录。
VM_CONFIG_DIR=$VM_ROOT/legacy/configs
VM_DISK_DIR=$VM_ROOT/legacy/disks
VM_NVRAM_DIR=$VM_ROOT/legacy/nvram
VM_LOG_DIR=$VM_ROOT/legacy/log
```

日常优先使用命令行：`--vm-dir ABS` 精确选择单台 bundle，
`--instances-dir ABS` 选择一组 bundle 的父目录，`--print-paths` 只读确认。整套
G-11 数据换根时才覆盖 `VM_ROOT`。旧 `VM_DISK_DIR` 的多重兼容语义不属于新部署
入口，不要继续依赖。
