# G-11 通用显卡身份包与 GPU-Z 选装

## 最终行为

`VgpuPortable.exe` 是所有 B/native G-11 虚拟机共用的入口。它有两个明确分离的
构建变体：

- 默认双击只安装显卡型号、板卡品牌、显存类型/厂商等身份组件和
  `vGPU Identity Query`；
- 默认不内嵌、不下载、不要求、不安装 `GPU-Z.exe`；
- GPU-Z 只有在用户显式执行 `VgpuPortable.exe /with-gpuz` 时才会选装；
- 包不绑定 VM ID/UUID。VM 新建、基础盘克隆和任意正常启动都使用同一份
  schema-2 原子目录与目录摘要；
- 显式私有授权版额外内嵌 DLS token，并在同一次运行中安装身份、原子安装 token、
  等待 NVIDIA 报告 `Licensed`，最后关闭休眠/Fast Startup；GTX 750 Ti、GT 1030、
  GTX 1050 都走同一流程；
- 不改 BCD，不开启 `testsigning`/`nointegritychecks`，不安装测试签名或
  自签名内核驱动，不替换 System32/SysWOW64 的 NVAPI。

默认路径与选装路径是两条明确分开的路径：

```text
start-vm.sh 只读 vm.conf
        │
        ├─ SMBIOS Type 11：profile + VM UUID + catalog SHA-256
        │
VgpuPortable.exe（所有 VM 共用）
        │
        ├─ 默认：身份 profile + 受保护 app-local NVAPI + 权威查询工具
        ├─ 私有授权版：上述内容 + token + Licensed 验收 + 关闭休眠/Fast Startup
        │
        └─ /with-gpuz：额外导入并验证官方 GPU-Z 2.70
```

## 一、宿主机打包

在仓库根目录执行：

```bash
./deploy/package-vgpu-one-click.sh
```

默认输出：

```text
/home/ubuntu/images/staging/VgpuPortable/VgpuPortable.exe
/home/ubuntu/images/staging/VgpuPortable/.host-bundle/
```

需要把某台实际 VM 一次收尾为可授权成品时，使用统一私有版：

```bash
chmod 600 /home/ubuntu/images/staging/client_configuration_token.tok
./deploy/package-vgpu-one-click.sh --with-license-token
```

私有输出仍叫同一个文件名，但放在独立目录：

```text
/home/ubuntu/images/staging/VgpuPortableLicensed/VgpuPortable.exe
/home/ubuntu/images/staging/VgpuPortableLicensed/.host-bundle/
```

也可从仓库外的安全路径显式选择 token：

```bash
./deploy/package-vgpu-one-click.sh \
  --token-file /安全路径/client_configuration_token.tok
```

token 必须是普通文件、`1024..1048576` 字节、非 HTML、权限不宽于 `0600`，而且
必须位于仓库外。私有 EXE 本身就是凭据，宿主权限固定为 `0600`；不要提交仓库、
公开分发或写进通用基础盘。默认不带参数的版本仍然不含 token，适合基础盘。

查看包内所有可选显卡身份：

```bash
./deploy/package-vgpu-portable.sh --list-gpu-profiles
```

当前目录包含 12 个完整原子行，覆盖 GTX 750 Ti、GT 1030、GTX 1050，
NVIDIA/ASUS/Dell/Colorful（七彩虹）/GALAX/Gigabyte/MSI 七个板卡品牌，以及 Samsung、
SK hynix、Micron 三个显存厂商。选择的是完整行；脚本不会把不同卡的板号、
VBIOS、频率、显存厂商或子系统 ID 随意拼接。

## 二、准备通用 Windows 基础盘

推荐默认方式（不放 GPU-Z）：

```bash
sudo ./deploy/install-vgpu-portable-to-base.sh --yes
```

安装器只编辑基础盘的私有临时副本，检查 qcow2、NBD、NTFS 和休眠状态后，
才归档旧基础盘并原子替换。默认只把下面一个文件写到公共桌面：

```text
C:\Users\Public\Desktop\VgpuPortable.exe
```

基础盘证明为 schema 4，其中 `gpuZIncluded=false`，GPU-Z 的路径、哈希和
字节数字段为 `null`。

只有确实希望所有克隆都预置 GPU-Z sidecar 时，才显式执行：

```bash
sudo ./deploy/install-vgpu-portable-to-base.sh --with-gpuz --yes
```

或指定已审计来源：

```bash
sudo ./deploy/install-vgpu-portable-to-base.sh \
  --gpuz-source /安全路径/GPU-Z.2.70.0.exe --yes
```

`--gpuz-source` 自动表示选装。普通部署不要加这两个参数。

## 三、新建与克隆任意 VM

列出可选行：

```bash
./deploy/scripts/clone-vgpu-base.sh --list-gpu-profiles
```

克隆任意受支持 VM ID，例如：

```bash
# 不指定 GPU：从 12 条审核行随机一次并固化
./deploy/scripts/clone-vgpu-base.sh 10 --start

# 指定 GPU：固定为所选原子行
./deploy/scripts/clone-vgpu-base.sh 11 --gpu-profile gtx1050_msi_2gb --start
./deploy/scripts/clone-vgpu-base.sh 12 --gpu-profile gtx1050_gigabyte_2gb --start
./deploy/scripts/clone-vgpu-base.sh 456 --gpu-profile gt1030_asus_2gb
```

这不是为每个 VM 重新打包。克隆器会：

1. 校验基础盘路径、inode/mtime/ctime、目录摘要和 schema-4 证明；
2. 调用统一的 `create-vm.sh`；显式 profile 原样传递，未指定则随机一条；
3. 把完整原子行写入该实例的 `vm.conf`；
4. 从独立基础盘创建实例盘；
5. 正常启动时由 `start-vm.sh` 发布只读 firmware claim；
6. guest 中同一个 `VgpuPortable.exe` 根据 claim 自动选中正确行。

直接新建配置也使用同一目录：

```bash
./deploy/scripts/create-vm.sh --list-gpu-profiles
./deploy/scripts/create-vm.sh 19
./deploy/scripts/create-vm.sh 20 --gpu-profile gtx750ti_gigabyte_2gb
```

第一条创建命令随机并固化 GPU，第二条显式固定 GPU。两种方式都只写入一次；已有
实例使用 `create-vm.sh --force` 时，未显式给出 `--gpu-profile` 会保留旧显卡策略。

显式换卡会重新校验完整行和持久化状态，避免静默换身份。

## 四、Windows 默认安装（不装 GPU-Z）

1. 正常启动 B/native VM；
2. 双击公共桌面的 `VgpuPortable.exe`；
3. 接受管理员提升；
4. 等待窗口显示 `[vGPU identity] INSTALL PASS`；
5. 双击新建的 `vGPU Identity Query` 快捷方式查看结果。

命令行静默运行：

```bat
VgpuPortable.exe /no-launch
```

只复验、不修改：

```bat
VgpuPortable.exe /verify-only /no-launch
```

成功回执位于：

```text
C:\ProgramData\QemuGpuZProfile\last-result.json
```

默认成功回执必须包含：

```json
{
  "receiptType": "vgpu-identity-portable-final",
  "schemaVersion": 3,
  "gpuZDelivery": "optional-explicit-sibling",
  "gpuZRequested": false,
  "gpuZInstalled": false,
  "gpuZExe": null,
  "testsigning": false,
  "nointegritychecks": false,
  "systemNvapiChanged": false
}
```

`VgpuIdentityQuery.exe` 同时报告真实 native transport（DEV_1E30）和目录投影的
型号、AIB 板卡、显存厂商、VBIOS、频率、位宽、带宽及核心字段，并以
`VERIFY PASS` 结束。它是本方案的权威查询入口，不依赖 GPU-Z。

### 实际 VM 的统一授权收尾

先确认 VM 使用 B/native，官方 GRID 538.33 已安装，设备为 Code 0。把
`VgpuPortableLicensed/VgpuPortable.exe` 安全复制到这台 Windows，再直接双击并
接受 UAC。不要按显卡型号选择脚本，也不要再为新 VM 运行
`finish-vgpu-install.sh`。

私有版只有在以下条件全部通过时才显示安装成功：

1. firmware claim、VM UUID、12 行 catalog、原生 `DEV_1E30`、538.33、Code 0 和
   生产签名链全部匹配；
2. token 原子安装到 NVIDIA `ClientConfigToken` 目录；失败时回滚旧 token；
3. `NVDisplay.ContainerLocalSystem` 正常运行，且 `nvidia-smi -q` 明确报告
   `License Status : Licensed`；
4. `powercfg /hibernate off` 成功，`HiberbootEnabled=0`，`hiberfil.sys` 不再存在；
5. BCD 仍为 `testsigning=False`、`nointegritychecks=False`，系统 NVAPI 未改动。

成功窗口会额外显示：

```text
License:   Licensed
Power:     hibernation/Fast Startup disabled
Next:      fully shut down Windows, then cold-start normally
```

随后执行 Windows“关机”，等 QEMU 窗口自然退出，再用普通启动命令冷启动。私有版
回执为 schema 4，并在
`C:\ProgramData\QemuGpuZProfile\last-result.json` 记录 token 哈希、授权状态和电源
状态；回执不会记录 token 内容。

## 五、以后从官网选装 GPU-Z

当前经过二进制和调用路径审计的唯一文件是 TechPowerUp GPU-Z 2.70 x86：

```text
文件名：GPU-Z.exe
字节数：11642144
SHA-256：6CB0EF29682452DE81A9576808881685161411A1FAD00938BA04131159979C29
ProductVersion：2.70.0
签名：有效、非自签、TechPowerUp
```

操作步骤：

1. 用户自行从 TechPowerUp 官方渠道取得 GPU-Z；
2. 核对它确实是上面的 2.70 x86 审计文件；
3. 重命名为 `GPU-Z.exe`；
4. 放到 `VgpuPortable.exe` 同目录；
5. 在该目录打开命令提示符，执行：

```bat
VgpuPortable.exe /with-gpuz
```

静默安装但不自动打开 GPU-Z：

```bat
VgpuPortable.exe /with-gpuz /no-launch
```

选装成功后，受保护副本和快捷方式位于：

```text
C:\ProgramData\QemuGpuZProfile\applications\identity-...\GPU-Z.exe
C:\Users\Public\Desktop\GPU-Z (vGPU profile).lnk
```

必须从 `GPU-Z (vGPU profile)` 快捷方式启动，才能使用同目录受保护的
app-local NVAPI。不要把 shim 放进 Windows 或 GPU-Z 的其他安装目录。

官网以后发布的更新版本不会自动放行。即使签名有效，只要字节数、哈希、
版本或已审计 ABI 不一致，`/with-gpuz` 就会在任何 profile 写入前失败。
先更新资产目录、重新审计调用路径、提升契约并重建包，才能支持新版本。

## 六、通用性和底层边界

- VM ID：支持 `1..2147483647`，包内没有 VM ID/UUID；
- 型号/品牌/显存：host 目录、guest JSON、编译的 NVAPI 目录、固件 claim 和
  回执共享同一 SHA-256；
- 新建/克隆：均调用 `create-vm.sh` 和同一 `vgpu-profiles.sh`，不另做品牌分支；
- 底层 transport：仍是生产签名 GRID 538.33、native DEV_1E30、Code 0；
- 身份投影：只在受保护的 32 位 app-local 用户态目录生效；
- 系统边界：不改 Driver Store、内核驱动、BCD、System32/SysWOW64 NVAPI；
- GPU-Z：不参与默认安装、基础盘默认证明或权威查询，仅为显式选装消费者。

## 七、常见错误

| 现象 | 处理 |
|---|---|
| 默认双击提示缺少 GPU-Z | 使用的仍是旧 V3/1.3.0 包；重新构建并确认 V4/1.4.0 |
| `/with-gpuz` 提示缺少同目录文件 | 把官方审计文件精确命名为 `GPU-Z.exe` 并放到 EXE 同目录 |
| `/with-gpuz` 提示大小/哈希/签名错误 | 不是审计的 2.70 x86；不要绕过，先完成新版本审计 |
| Query 显示 claim/catalog 不一致 | 该 VM 的 `vm.conf`、当前启动 claim 与 EXE 目录不同步；重建包或正常重启 |
| Query 不以 `VERIFY PASS` 结束 | 按输出字段排查；不要用第三方界面截图代替权威查询结果 |
| Code 43、驱动签名错误或多块 Display | 先修复生产签名 GRID 驱动和拓扑；身份脚本会拒绝继续 |
| base/clone 拒绝 schema | 用新版安装器重新准备 base；默认应为 schema 4、`gpuZIncluded=false` |

任何失败都不要通过开启测试签名、关闭完整性检查、修改 BCD 或安装自签名内核
驱动来绕过。
