# G-11 桥接网络与 VLAN：一条命令完成宿主配置

本页只适用于 **G-11/vGPU 分支**。V-11 与 G-11 是两个独立分支；G-11 使用
自己的 helper、状态目录和 `g11t<VM_ID>` TAP，不复用或覆盖 V-11 的运行时。

## 为什么 Windows 显示“未识别的网络”

如果 Windows 已经识别到 `Intel(R) Gigabit CT Desktop Adapter`，链路为
`1000/1000 Mbps`，但只有 `fe80::` 地址而没有 IPv4，网卡和驱动通常是正常的。
这表示 guest 没收到 DHCP：常见原因是 QEMU 接入了一个没有物理上联的空 `br0`。

配置完成后的拓扑是：

```text
普通 LAN（untagged） ─┐
业务 VLAN（tagged）  ─┴─ 物理网卡 ─ br0（VLAN filtering）
                                      ├─ 默认 VM：原生 LAN
                                      └─ --vlan-id N：g11tN access/PVID N
```

宿主的 DHCP 地址、默认路由和 DNS 从物理网卡迁到 `br0`；物理网卡只作为二层
端口。Windows 仍看到普通以太网，不需要在 guest 内创建 VLAN 接口。

## 第一次只执行这一条

请在宿主的**本地桌面/控制台**打开终端，执行：

```bash
cd /home/ubuntu/projects/qemu
./deploy/scripts/setup-bridge.sh
```

不需要预先填写网卡名或手工编辑 Netplan。脚本会自动：

1. 识别唯一、已连接的有线物理网卡，并拒绝 Wi-Fi、无 carrier 或有歧义的环境；
2. 检查 Netplan、NetworkManager、QEMU helper、systemd 回滚等依赖；
3. 若发现 G-11 VM，要求输入 `STOP vm8`（多个 VM 会一并列出），只允许正常
   关机；无法正常关机时不会强杀；
4. 通过系统 `sudo` 提示读取宿主密码；密码不会进入参数、环境变量、日志或仓库；
5. 离线验证合并后的 Netplan，创建 VLAN-aware `br0`，并迁移宿主 DHCP；
6. 启动独立回滚 watchdog，检查 bridge、上联、IPv4、默认路由和原网关；
7. 自动检查成功后，要求输入屏幕上显示的 `KEEP <网卡名>` 才提交。

如果网络检查失败、超时、输入不一致、终端中断或脚本异常，watchdog 会恢复迁移
前的 G-11 受管配置并重新应用网络。不要在 SSH 会话中做首次迁移；脚本默认也会
拒绝这样做。

已经正确配置的机器再次运行同一命令会做完整一致性检查并直接成功，不会反复迁网，
也不会静默改变已有 VLAN 白名单或授权用户。

## 启动 VM

以后统一从 `deploy/scripts/` 启停。

普通 LAN（默认，不携带 VLAN）：

```bash
./deploy/scripts/start-vm.sh 8
```

首次安装 Windows：

```bash
./deploy/scripts/start-vm.sh 8 --install /home/ubuntu/images/iso/win10.iso
```

把 VM 接入 VLAN 11：

```bash
./deploy/scripts/start-vm.sh 8 --vlan-id 11
```

也可只对本次进程使用环境变量：

```bash
VLAN_ID=11 ./deploy/scripts/start-vm.sh 8
```

命令行优先于环境变量。VLAN 不会写进 `vm.conf`；不携带 `--vlan-id` 就始终回到
默认原生 LAN。VID 必须为 `1..4094` 且在宿主白名单内；无效或未授权 VID 会在
QEMU 启动前失败，不会回退到普通 LAN。

停止 VM：

```bash
./deploy/scripts/stop-vm.sh 8
```

启动失败、正常退出和停止流程都会回收对应 TAP、bridge VLAN 条目及 root-owned
状态；启动/停止/宿主迁网使用同一组锁，避免旧 VM 的清理误伤刚启动的新 VM。

## 交换机和 DHCP 仍需具备的条件

脚本只配置这台 Ubuntu 宿主，不能替你修改外部交换机或路由器：

- 默认 LAN 必须以 untagged/native 流量到达宿主端口；
- 使用 `--vlan-id 11` 时，交换机到宿主的端口必须允许 tagged VLAN 11；
- VLAN 11 内必须存在 DHCP 服务器或由 Windows 使用管理员规划的静态地址；
- 上游防火墙、VLAN 间路由和互联网出口由你的网络设备决定。

若交换机未放行 VLAN，Windows 会再次表现为有链路但拿不到 IPv4。这不是 QEMU
网卡驱动故障。

## 验证

宿主只读检查：

```bash
./deploy/scripts/setup-bridge.sh inspect
./deploy/scripts/setup-bridge.sh verify
```

`inspect` 完全以当前用户读取公开状态；VLAN-aware 宿主公开拓扑健康时会显示
`status=privileged-verify-required`，表示还需运行下一条 `verify`，并不表示需要
重新建桥。`verify` 仍然不修改网络，但会通过系统
`sudo` 只读检查权限为 `0440` 的 sudoers 授权片段和其它 root-owned 安装契约。
这避免把“普通用户无权读取”误报成“VLAN runtime 未安装”。已经完成配置后再次执行
无参数的一键命令，也会先走同一套只读提权校验；全部健康时不会重应用 Netplan。
若 sudo 认证被取消、拒绝或中断，命令会立即退出，既不会把它当成契约损坏，也不会
停止 VM 或进入网络修复。

Windows PowerShell：

```powershell
ipconfig /all
ping <该 LAN 或 VLAN 的网关地址>
```

应看到 Intel 网卡取得 IPv4、默认网关和 DNS。整个网络功能不修改 BCD，不开启
`testsigning`/`nointegritychecks`，也不安装测试签名或自签名内核驱动。

## 高级选项：收紧 VLAN 白名单

全新部署默认允许合法 VID `1-4094`，方便一条命令完成通用 VLAN trunk。生产环境
建议按实际业务收紧，例如：

```bash
./deploy/scripts/setup-bridge.sh apply \
  --mode vlan-aware \
  --allowed-vlans 1,11,20,30-39
```

`apply` 同样要求 root、本地 TTY 和确认流程。已有配置损坏、不可信，或重跑时授权
用户不一致，脚本会失败关闭，绝不会退回更宽的 `1-4094`。白名单格式支持单个 VID
和闭区间，以英文逗号分隔。

## 自动安装的 G-11 文件

| 路径 | 用途 |
|---|---|
| `/etc/netplan/00-qemu-g11-uplink.yaml` | 物理上联的安全提前声明 |
| `/etc/netplan/99-qemu-g11-br0.yaml` | DHCP bridge 与 VLAN filtering 配置 |
| `/etc/qemu/g11-bridge.conf` | root-owned bridge 事实与启动前检查依据 |
| `/etc/qemu/g11-vlan.conf` | bridge、上联、授权 UID/GID 和 VID 白名单 |
| `/etc/qemu/bridge.conf` | 只允许 QEMU helper 使用 `br0` |
| `/usr/local/libexec/qemu-g11-*` | 独立 bridge、VLAN、downscript 与回滚 helper |
| `/run/qemu-g11-vlan/` | 每个活动 TAP 的 root-owned 临时状态 |
| `/var/lib/qemu-g11-network/transactions/` | 权限为 0700 的迁网事务和回滚证据 |

仓库和这些配置都不保存宿主密码。

## 故障处理

- 首次迁移前就报错：按报错修复多上联、Wi-Fi、静态/双栈、无 carrier 或依赖
  问题，然后重新执行同一条命令；脚本尚未改网络。
- `KEEP` 前断网：等待 watchdog 自动回滚，不要反复启动另一份 setup。
- 网络已验证并输入 `KEEP`，但旧版本提示
  `qemu-g11-vlan-bridge: host network maintenance is active`：这是旧 setup 在
  启动持久化 service 前未释放维护锁；bridge 本身无需回滚。更新到当前脚本后，
  等 setup 完全退出并执行
  `sudo systemctl restart qemu-g11-vlan-bridge.service`，再运行本页的 `verify`。
- 默认 LAN 正常、指定 VLAN 无 DHCP：先检查交换机 trunk、该 VID 的 DHCP 和
  `/etc/qemu/g11-vlan.conf` 白名单。
- 启动提示 bridge 健康检查失败：重新运行 `./deploy/scripts/setup-bridge.sh`，不要用
  `BRIDGE_UPLINK_CHECK=off` 掩盖生产网络问题。

仅在明确设计为无物理上联的实验室隔离 bridge 时，才可单次使用：

```bash
BRIDGE_UPLINK_CHECK=off ./deploy/scripts/start-vm.sh <vm_id>
```

它不会提供 LAN 或互联网，也不是“未识别的网络”的修复方案。
