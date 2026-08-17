# G-11 VM 路径傻瓜教程

这套规则只有一句话：一台 VM 就是 `/home/ubuntu/images/vms/<数字ID>/` 一个完整
文件夹。默认不再有 `G-11/`，目录名也不再带 `vm` 前缀。

## 一、先看路径，不启动

```bash
cd /home/ubuntu/projects/qemu
./deploy/scripts/vmctl.sh path 2
```

VM 2 的关键输出应是：

```text
VM_ROOT=/home/ubuntu/images/vms
VM_DIR=/home/ubuntu/images/vms/2
VM_CONFIG=/home/ubuntu/images/vms/2/vm.conf
VM_DISK=/home/ubuntu/images/vms/2/disk.qcow2
VM_NVRAM=/home/ubuntu/images/vms/2/nvram.fd
VM_TPM=/home/ubuntu/images/vms/2/tpm
VM_RUN=/home/ubuntu/images/vms/2/run
VM_START_LOCK=/home/ubuntu/images/vms/2/run/start.lock
VM_DISK_LOCK=/home/ubuntu/images/vms/2/run/disk.lock
VM_TPM_LOCK=/home/ubuntu/images/vms/2/run/tpm.lock
```

`path`/`--print-paths` 只解析路径，不创建目录、不迁移文件、不启动 QEMU。路径不对就
先修正，不要继续启动。

## 二、默认目录结构

```text
/home/ubuntu/images/vms/
├── 1/                         # VM 1，全部私有文件都在这里
│   ├── vm.conf
│   ├── disk.qcow2
│   ├── nvram.fd
│   ├── tpm/
│   ├── log/
│   ├── run/
│   │   ├── start.lock
│   │   ├── disk.lock
│   │   └── tpm.lock
│   └── backups/
├── 2/                         # VM 2，同样是一个完整 bundle
├── shared/
│   ├── bases/
│   └── assets/
└── control/
    ├── .storage.lock          # 整套存储的全局锁，不是 VM 残留
    └── history/               # 有旧布局迁移时才可能存在
```

`control/` 不再保存 `vm2.start.lock`、`vm2.disk.lock`、`vm2.tpm.lock`。这三个文件
跟着 VM 2 放在 `2/run/`，删除 `2/` 时会一起消失。`control/.storage.lock` 仍会存在，
因为它协调所有 VM 的迁移、base 和生命周期；它不是任何一台 VM 的文件。

## 三、第一次从旧目录升级

旧版可能存在以下任一种或两种布局：

```text
/home/ubuntu/images/vms/G-11/vm2
/home/ubuntu/images/vms/instances/vm2
```

不要手工拼接文件。先把所有 G-11 VM 正常停止，然后只读检查：

```bash
cd /home/ubuntu/projects/qemu
./deploy/scripts/vmctl.sh migrate --check
```

看到最后一行 `CHECK OK` 后再执行：

```bash
./deploy/scripts/vmctl.sh migrate --apply
```

如果输出含 `Permission denied`（常见于 root 创建的 TPM/备份），不要 chmod 或漏扫：

```bash
sudo -v
sudo ./deploy/scripts/vmctl.sh migrate --check
sudo ./deploy/scripts/vmctl.sh migrate --apply     # 仅在上一条显示 CHECK OK 后执行
```

sudo 密码只在终端交互输入，绝不能写入仓库、配置或命令参数。

再次确认：

```bash
./deploy/scripts/vmctl.sh migrate --check
./deploy/scripts/vmctl.sh path 2
```

迁移结果是把完整 bundle 原子移动到 `/home/ubuntu/images/vms/2`，共享 base/assets
归入 `/home/ubuntu/images/vms/shared/`，旧平铺的 VM 锁被清理；确认空后也会移除
多余的 `G-11/` 目录。

如果输出 `BLOCKED`，不要强行 `mv` 或删锁。常见原因如下：

- VM、swtpm、NBD 或其它进程仍在使用文件；
- `/home/ubuntu/images/vms/2` 已经存在；
- 两代旧目录里同时存在同一个 ID；
- 数字目标里已有 V-11 的 `profile`、`ovmf-vars.fd` 或 `tpm-state`；
- qcow2 有 backing/external data-file，或外部 overlay 依赖旧绝对路径；
- 路径含 symlink、未知控制文件或权限不安全。

迁移器不会覆盖、补齐或合并冲突目录。先备份并确认它们分别属于哪一个分支；G-11
应改用空闲 ID，或按下一节放到另一套根目录。

## 四、日常启动、停止和状态

```bash
cd /home/ubuntu/projects/qemu

# 启动 VM 2
./deploy/scripts/vmctl.sh start 2

# 查看运行状态和实际路径
./deploy/scripts/vmctl.sh status 2

# 优雅关机
./deploy/scripts/vmctl.sh stop 2

# guest 不响应时才强制停止
./deploy/scripts/vmctl.sh stop 2 --force
```

所有生命周期脚本都使用同一个数字 bundle。`run/` 中的 PID/socket 会在停止时清理；
零字节 `*.lock` 留在 bundle 内是正常的协调文件。

## 五、删除一台 VM

推荐使用封装，它会检查 QEMU、mdev、锁、打开的磁盘和其它 qcow2 backing 依赖：

```bash
cd /home/ubuntu/projects/qemu
./deploy/scripts/vmctl.sh stop 2
./deploy/scripts/vmctl.sh status 2
./deploy/scripts/vmctl.sh delete 2
```

最后一条会列出准确目录并要求 `y/N` 确认。已经做过独立备份且确定不需要交互时才用：

```bash
./deploy/scripts/vmctl.sh delete 2 -y
```

它删除整个 `/home/ubuntu/images/vms/2/`，包括 TPM、日志、备份、未知的 per-VM
附加文件和 `run/*.lock`；不会删除 `shared/bases/` 或其它数字 VM。

### 我就是想用 rm

可以，但 `rm` 会绕过 qcow2 依赖、mdev 和锁检查。必须先停止并确认 ID，且目标只能是
一个明确的数字目录：

```bash
cd /home/ubuntu/projects/qemu
./deploy/scripts/vmctl.sh stop 2
./deploy/scripts/vmctl.sh status 2             # 必须显示 VM_STATUS=stopped
./deploy/scripts/vmctl.sh path 2               # 必须显示 VM_DIR=/home/ubuntu/images/vms/2
rm -rf -- /home/ubuntu/images/vms/2
```

不要对变量、通配符、`/home/ubuntu/images/vms` 根目录或 `shared/control` 执行递归
删除。按新布局删除 `2/` 后，不会留下 VM 2 的 start/disk/tpm 锁；你仍会看到全局
`control/.storage.lock`，这是正常且必须保留的。

## 六、指定另一套完整目录

例如把 G-11 全部数据放到 `/mnt/fast/vms`：

```bash
sudo mkdir -p /mnt/fast/vms
sudo chown "$USER:$USER" /mnt/fast/vms

cd /home/ubuntu/projects/qemu
./deploy/scripts/vmctl.sh path 2 --vms-dir /mnt/fast/vms
./deploy/scripts/vmctl.sh start 2 --vms-dir /mnt/fast/vms
./deploy/scripts/vmctl.sh status 2 --vms-dir /mnt/fast/vms
./deploy/scripts/vmctl.sh stop 2 --vms-dir /mnt/fast/vms
./deploy/scripts/vmctl.sh delete 2 --vms-dir /mnt/fast/vms
```

最终结构是：

```text
/mnt/fast/vms/
├── 2/
├── shared/
└── control/
```

`--vms-dir` 改的是整套根目录，所以 `shared` 和 `control` 也一起改变。对同一台 VM
每次都要传同一个值。长期固定时可以只在当前 shell 中设置环境变量：

```bash
export VMS_DIR=/mnt/fast/vms
./deploy/scripts/vmctl.sh path 2
./deploy/scripts/vmctl.sh start 2
./deploy/scripts/vmctl.sh stop 2
```

封装不会保存宿主机密码、token 或其它凭据。需要 sudo/宿主认证时只通过批准的安全
渠道或运行时环境提供，绝不能写进仓库。

### 把旧 G-11 直接迁到自定义根

`--vms-dir` 在迁移命令中表示目标根：

```bash
./deploy/scripts/vmctl.sh migrate --check --vms-dir /mnt/fast/vms
./deploy/scripts/vmctl.sh migrate --apply --vms-dir /mnt/fast/vms
```

先保证目标根为空并与来源处于可安全 rename 的文件系统条件下。任何已存在的数字
目标都会阻止迁移，不会被覆盖。

## 七、只精确指定一台 VM

启动、停止和查路径还支持 `--vm-dir`：

```bash
mkdir -p /mnt/special-vms
./deploy/scripts/vmctl.sh path 2 --vm-dir /mnt/special-vms/2
./deploy/scripts/vmctl.sh start 2 --vm-dir /mnt/special-vms/2
./deploy/scripts/vmctl.sh stop 2 --vm-dir /mnt/special-vms/2
```

末级目录必须正好是 ID：VM 2 只能使用 `/.../2`，`/.../vm2`、`/.../3` 都会被
拒绝。目标本身可以尚不存在，但父目录必须已经存在，且路径不能经过 symlink。

`--vm-dir` 只改变这一台 VM 的 bundle；公共 `shared/control` 仍在默认根。
如果目标是整套搬家，始终优先用 `--vms-dir`。旧 `--instances-dir` 只为兼容已有
调用保留，同样不移动 `shared/control`。

## 八、V-11 与 G-11 同机使用

V-11 和 G-11 是独立分支，只是目录分类规则相同。不要把 V-11 的 `profile`、
`ovmf-vars.fd`、`tpm-state/` 与 G-11 的 `vm.conf`、`nvram.fd`、`tpm/` 放入同一个
数字目录。

最简单的做法是使用不同 ID；需要同号时给 G-11 单独指定根：

```bash
./deploy/scripts/vmctl.sh start 2 --vms-dir /home/ubuntu/images/g11-vms
```

G-11 检测到典型 V-11 状态时会 fail closed，不会自动合并或删除。

## 九、最终自检

```bash
cd /home/ubuntu/projects/qemu

# 旧布局检查应为 CHECK OK / 没有待迁移项
./deploy/scripts/vmctl.sh migrate --check

# 确认每台 VM 都是数字目录
find /home/ubuntu/images/vms -mindepth 1 -maxdepth 1 -type d -printf '%f\n'

# 确认 VM 2 的三个锁只在自己的 run/ 下
find /home/ubuntu/images/vms/2/run -maxdepth 1 -type f -name '*.lock' -print

# 全局 control 中不应再有旧式 vmN 生命周期锁
find /home/ubuntu/images/vms/control -maxdepth 1 -type f \
  \( -name 'vm*.start.lock' -o -name 'vm*.disk.lock' -o -name 'vm*.tpm.lock' \) \
  -print
```

最后一条正常情况下没有输出；`control/.storage.lock` 应继续保留。
