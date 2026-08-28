# G-11 克隆初始化版本不匹配：傻瓜修复教程

适用报错：

```text
[g11-clone-verify] ERROR: guest initialization marker does not match the current vm.conf/clone contract
```

如果诊断同时显示旧的 `schemaVersion` 或旧的 `guestLite.profileVersion`，说明克隆时
母盘内嵌的首启脚本早于当前宿主验收规则。例如旧克隆可能写出 schema 3 / Guest Lite
2.5.2，而当前流程要求 schema 4 / Guest Lite 2.6.7。这不是授权、BCD 或驱动签名问题。

## 一、先修复已经失败的克隆

下面以 VM 1 为例。VM 必须已经正常完整关机；不要强制关机，不要使用 `ntfsfix`、
`remove_hiberfile` 或强制挂载。

在仓库根目录只运行：

```bash
sudo ./deploy/scripts/repair-clone-init.sh 1
```

这条封装会完成四件事：

1. 验证 VM 仍处于 `.g11-init-required` 等待状态，并锁住停止的磁盘；
2. 生成当前 VM UUID/GPU/显示器绑定的系统 NVAPI 只读 ISO；
3. 仅离线替换 Windows 中的当前 `Finalize-Clone.ps1`、桌面 Retry 和 Guest Lite
   2.6.7 用户态载荷；
4. 删除旧的完成/错误标记，让新 finalizer 重新生成 schema 4 回执。

它保留已有的 Licensed VgpuPortable 结果、Windows 身份、驱动和私有母盘。它不会运行
`bcdedit`，不会开启 `testsigning`/`nointegritychecks`，也不会安装或替换任何内核驱动。

脚本显示 `PASS` 后依次执行：

```bash
./deploy/scripts/start-vm.sh 1
```

登录 Windows，右键桌面的 `Retry-Clone-Initialization.cmd`，选择“以管理员身份运行”。
等待它内部重启一次并最终自动完整关机，然后回到宿主执行：

```bash
sudo ./deploy/scripts/initialize-clone.sh 1
./deploy/scripts/start-vm.sh 1
```

不要在内部重启、验收或关机期间强制停止 QEMU。

## 二、一次修好母盘，供后续所有克隆使用

先只读检查：

```bash
./deploy/scripts/refresh-g11-private-base.sh win10-base --check
```

如果显示 `STALE`，执行一次：

```bash
./deploy/scripts/refresh-g11-private-base.sh win10-base
```

默认复用 `$STAGE_DIR/VgpuPortableLicensed/VgpuPortable.exe` 及其宿主内容回执，不读取
或复制新凭据。命令会通过正常 `sudo` 提示取得临时管理员权限，原子刷新已 generalize
的私有母盘，再更新同目录的 `.g11base` 交付清单。已有增量克隆继续使用各自目录里的
`.base.qcow2` inode pin，不会被母盘换代覆盖；只有之后创建的克隆使用新载荷。

如果安全目录中的 DLS token 确实已经更换，才显式传入仓库外路径：

```bash
./deploy/scripts/refresh-g11-private-base.sh win10-base \
  --token-file /安全目录/client_configuration_token.tok \
  --replace-licensed
```

不要把 token、宿主机密码或其它凭据放进仓库。没有更换 token 时不要添加
`--replace-licensed`。

刷新后，后续克隆仍按原文档执行：

```bash
./deploy/scripts/clone-from-base.sh win10-base 2 --start
# 等待 Windows 内部重启并最终完整关机
sudo ./deploy/scripts/initialize-clone.sh 2
./deploy/scripts/start-vm.sh 2
```

`clone-from-base.sh` 现在会在创建 `vm.conf` 或磁盘之前，把母盘证明中的 finalizer、
Retry 和 Sysprep answer 摘要与当前仓库逐项比较。旧母盘会直接提示运行
`refresh-g11-private-base.sh`，不会再让一批克隆到最后一步才失败。

## 三、自定义存储目录

VM 根目录不是默认 `/home/ubuntu/images/vms` 时，两条封装都支持同一个选择器：

```bash
./deploy/scripts/refresh-g11-private-base.sh win10-base \
  --vms-dir /绝对路径/G11-vms

sudo ./deploy/scripts/repair-clone-init.sh 9
```

第二条可通过环境中的 `VM_ROOT`/`VMS_DIR` 选择同一根目录，或使用统一入口：

```bash
./deploy/scripts/vmctl.sh repair-init 9 --vms-dir /绝对路径/G11-vms
```

G-11 与 V-11 始终是独立分支；这些命令只处理所选 G-11 根目录和指定 VM ID。
