# G-11 Sysprep 私有基础镜像：傻瓜制作与克隆

这条流程的结果是：制作方只在模板里执行一次 Sysprep；每台克隆拥有独立的
Windows SID、MachineGuid、计算机名和 VM UUID；授权版 `VgpuPortable.exe` 在每台
克隆首次启动时只运行一次。随后自动安装该 VM 专属的 x86/x64 系统 NVAPI、内部
重启一次、验收显示器身份并完整关机。用户只需在 VMate 点一次“初始”，宿主便会
校验全部结果、核对本机没有重复的 Machine SID、MachineGuid、计算机名或 VM UUID，
刷新显示器缓存并启动 VM。

## 重要结论

- 不需要先运行无凭据通用版、再运行授权版。正常成功路径只调用授权 V7 版一次；
  只有首次明确失败、管理员执行恢复脚本时才会再次尝试。
- 文件固定放在 `C:\ProgramData\VMate\G11`，不依赖可能因光驱/数据盘变化而改变的
  `D:` 盘符。
- 基础镜像内预置的是授权 `VgpuPortable.exe`、首启脚本和 OOBE 应答文件；
  `package-system-nvapi-projection.sh` 的产物绑定 VM ID、UUID、GPU profile、显示器
  profile 和 `vm.conf` 哈希，不能预先烘焙。VMate 创建克隆时会自动生成它，以只读
  光盘挂入，来宾复制到受保护的 `ProgramData` 后完成安装和重启验证。
- token 可以由多台 VM 共用，但只进入私有 EXE 和私有 qcow2；不会写入 Git 或 deb。
- DLS 固定为 `dls.gvmates.com:443`。
- 不开启 `testsigning`、`nointegritychecks`，不修改 BCD，不安装测试签名或自签名
  内核驱动。

## 一、制作模板 Windows

1. 在 G-11 模板 VM 中安装 Windows、原版生产签名 GRID 538.33 驱动和业务软件；
   保留至少一个日常使用的、有密码的本地管理员账户。
2. 正常启动一次，确认 NVIDIA 设备是 `DEV_1E30`、驱动版本
   `31.0.15.3833`、设备状态 Code 0。
3. 模板阶段不要运行任何 `VgpuPortable.exe`，也不要只给当前用户安装/更新
   Microsoft Store 应用；后者可能导致 Sysprep 校验失败。
4. 在宿主项目目录运行：

   ```bash
   ./deploy/package-g11-sysprep-kit.sh
   ```

   仓库里的应答文件更新后，刷新现有 staging 封装只需：

   ```bash
   ./deploy/package-g11-sysprep-kit.sh --replace
   ```

   `--replace` 只接受原封装的三个普通文件；目录里有额外内容时会拒绝覆盖。

5. 把输出的整个 `G11SysprepKit` 目录复制到模板 Windows。
6. 在 Windows 中右键“以管理员身份运行”`Seal-G11-Template.cmd`，按 `Y`。
7. 脚本会执行：

   ```text
   Sysprep.exe /generalize /oobe /shutdown /unattend:g11-sysprep-clone.xml
   ```

8. 等模板完整关机。成功后不要再启动这个源 VM。

应答文件会隐藏 OOBE 页面并自动登录内置 Administrator 一次，但不会绕过
`/generalize`。该临时空密码账户被限制为仅本机控制台登录，初始化成功前会清除
自动登录；有另一个可用的本地管理员时会禁用该临时账户。如果模板误删了其他
管理员，流程会保留内置 Administrator，避免成功后无人能够登录；首次进入桌面后
应立即为它设置密码或创建日常管理员。应答文件故意不写 `ComputerName`，让 Windows 使用正常的
`DESKTOP-XXXXXXX` 随机名称；不要改回 `ComputerName=*`，否则 Windows 会从
Administrator/组织信息派生出 `ADMINS-*` 一类前缀。首启包还会按 V-11 的精确规则
把最终名称锁定为 `DESKTOP-` 加该 VM UUID 的前 7 位，并借用本来就需要的内部验收
重启生效，不增加一次重启。

自动首启成功时不要求按键：它会内部重启一次、验收后自动完整关机。任何阶段失败
时，黑色窗口会保留错误并停在“请按任意键继续”，同时把 UTF-8 完整错误写入
`C:\ProgramData\VMate\G11\clone-initialization-error.txt`；无需靠一闪而过的红字猜错。

## 二、关机后宿主只运行一个总命令

默认 token 放在仓库外的：

```text
$STAGE_DIR/client_configuration_token.tok
```

然后运行。参数和 V-11 尽量保持一致：前两个位置参数仍是“源 VM ID、base 名称”，
存储目录使用与 V-11 相同的 `VMS_DIR/_base` 默认值：

```bash
./deploy/build-g11-private-base.sh 1 win10-base \
  --vms-dir=/home/ubuntu/images/vms
```

其中 `1` 是刚才模板 VM 的 ID。总命令会顺序完成：

1. 把已 Sysprep 关机的实例盘封装成独立 qcow2；
2. 构建 VM 无关、全 profile 通用的授权 V7 `VgpuPortable.exe`；
3. 离线注入授权 EXE、首次启动脚本和 OOBE 应答文件；
4. 生成本机绑定的 schema-7 证明，声明每 VM 系统 NVAPI 两阶段首启为必需项；
5. 在 `--base-dir` 中给同一个 qcow2 生成 `.g11base` 传输清单，不复制第二份镜像。

成功后的目录直接采用 V-11 风格，不套额外的 `*-g11-private/` 子目录：

```text
/home/ubuntu/images/vms/_base/
├── win10-base.qcow2                         # 唯一镜像：本机克隆 + 对外交付
├── win10-base.g11base                       # 很小的传输校验清单
└── win10-base.qcow2.vgpu-portable.json      # 很小的本机证明
```

没有 `archive/`，也没有第二个 `win10-base.qcow2`。制作期间的隐藏回滚文件只在事务
尚未验证完成时存在；成功后立即删除。与 V-11 一样，如果同名最终 base 已存在，脚本
拒绝猜测覆盖；确认旧版可以淘汰后，删除旧 qcow2 及同名两个小元数据文件再重跑。

压缩阶段默认使用本项目已验证的 qcow2 `zstd`，并行度为当前可用 CPU
数（最多 16），终端会持续显示百分比。封装开始时会先做 zstd 能力探测；
不支持时会在清理或修改源盘之前拒绝继续。需要兼容旧 QEMU 时可显式回退：

```bash
./deploy/build-g11-private-base.sh 1 win10-base \
  --vms-dir=/home/ubuntu/images/vms \
  --compression-type zlib
```

调整并行度时使用 `--compression-parallel 1..16`。一般不要加
`--no-progress`；该选项只用于不能显示动态进度的日志系统。导入时 VMate 会在
复制前检查目标电脑的 `qemu-img` 能否读取交付镜像的压缩格式。

不写 `--vms-dir` 时，G-11 与 V-11 一样固定使用 `/home/ubuntu/images/vms`；不写
`--base-dir` 时固定使用 `VMS_DIR/_base`。不会自动探测或回退到旧的 `g11-vms`
目录。自定义目录时仍是一个命令：

```bash
./deploy/build-g11-private-base.sh 1 win10-base \
  --vms-dir=/自定义/G11实例目录 \
  --base-dir=/自定义/base目录
```

使用其它仓库外 token 时：

```bash
./deploy/build-g11-private-base.sh 1 win10-base \
  --vms-dir=/自定义/G11实例目录 \
  --base-dir=/自定义/base目录 \
  --token-file /安全路径/client_configuration_token.tok
```

只有确认 token 已更换时才加 `--replace-licensed`。不要把 base 目录提交 Git，也不要
放到公共网盘；qcow2 内含授权凭据。

## 三、本机直接从同一个镜像克隆

不需要先“导入回本机”，也不需要再复制到旧的 `shared/bases/`。直接运行与 V-11
同形的默认命令；它会从 `/home/ubuntu/images/vms/_base` 取镜像，并默认创建
V-11 式增量盘：

```bash
./deploy/scripts/clone-from-base.sh win10-base 9 --start
```

例如要固定为 1GB 显存池，并选择 i3-4130、2 核 4 线程、H81M-K、Samsung
双通道 4GB 这套审核组合，直接在克隆命令里指定；不需要提前创建配置，也不需要写
`--linked`（它已经是默认值）：

```bash
./deploy/scripts/clone-from-base.sh win10-base 1 \
  --gpu-vram 1024 \
  --platform i3-4130-h81m-k-samsung-4g \
  --start
```

新 VM 的磁盘关系如下：

```text
/home/ubuntu/images/vms/9/
├── .base.qcow2   # 母盘 inode 的隐藏 hard-link pin；不是第二份 57GB 数据
└── disk.qcow2    # 可写增量盘；刚创建通常只有几百 KB，之后只随 VM 写入增长
```

`ls -lh .base.qcow2` 会显示母盘的逻辑文件大小，单独对 VM 目录执行 `du` 也可能把
这个共享 inode 计入显示；这不表示又占用了一份母盘空间。查看本 VM 真正新增的
可写数据用：

```bash
du -h /home/ubuntu/images/vms/9/disk.qcow2
qemu-img info /home/ubuntu/images/vms/9/disk.qcow2
```

`qemu-img info` 必须显示 `backing file: .base.qcow2`。如果确实需要完全独立、可单独
搬走但约占一份母盘空间的实例，才显式加 `--full-copy`。

首次启动时会短暂出现一个只读 `HL-DT-ST DVDRAM GH24NS50 / XP02` 光驱，专门承载
该 VM 的 UUID/profile 合同。文件完整复制到受保护的 ProgramData 后，Windows 会
弹出介质，宿主立即热拔整个 `scsi-cd + usb-bot`；内部验收重启以及以后普通启动都
不再显示光驱。这个临时设备使用审核过的真机型号且没有虚构序列号，不需要手工卸载。

同一次自动初始化会把所选 monitor 的 EDID/`EDID_OVERRIDE` 写入，并通过 Windows
SetupAPI 发布设备管理器的 live FriendlyName。`vmctl.sh monitor N --force` 只处理
关机磁盘里的 EDID、NVIDIA 模式和缓存，不能在 VM 关机时直接改变一个尚未运行的
PnP devnode；新克隆无需手工点“更新驱动程序”。

等价的路径写法：

```bash
./deploy/scripts/clone-from-base.sh \
  /home/ubuntu/images/vms/_base/win10-base.qcow2 9 \
  --vms-dir=/home/ubuntu/images/vms --start
```

### 用克隆机更新母盘

1. 让维护 VM 正常完成首次初始化，再安装 Windows/业务软件更新。
2. 把最新 `G11SysprepKit` 放入维护 VM，管理员运行
   `Seal-G11-Template.cmd`，等待 Sysprep 完整关机。
3. 推荐先发布新名称，便于验收：

   ```bash
   ./deploy/build-g11-private-base.sh 9 win10-base-v2 \
     --vms-dir=/home/ubuntu/images/vms
   ```

   `seal-base.sh` 会读取完整 backing chain 并压平为新的 standalone 母盘；不会把
   `.base.qcow2` 依赖带进交付镜像。
4. 新克隆选择 `win10-base-v2`。已有 VM 仍通过自己的 hard-link pin 使用旧母盘，
   不会被新母盘静默改写。确认淘汰旧版后再删除旧 base 名称及其两个小元数据；当
   最后一台旧 VM 删除时，旧母盘 inode 才自动释放。

不要原地写入 `_base/win10-base.qcow2`，也不要删除实例目录中的
`.base.qcow2`。母盘更新必须发布为新 inode；现有增量盘不能安全地“继承”母盘更新。

## 四、另一台电脑导入和创建

另一台兼容 G-11 宿主安装 VMate deb 后：

1. 只把 `.g11base` 与同目录的 `.qcow2` 一起复制到目标电脑；不要改名。本机绑定的
   `.qcow2.vgpu-portable.json` 不用复制，目标电脑会重新生成。
2. 打开 VMate，切换到 G-11。
3. 新建 VM，点“添加镜像”，只选择 `.g11base`。
4. VMate 校验完整 qcow2 哈希后复制镜像，并按目标电脑的新路径、inode 和时间重新
   生成本地证明；源交付文件会保留。
5. 选择刚导入的基础镜像，点“创建并启动”。
6. 不需要操作 OOBE，也不要双击 EXE。克隆会自动完成：
   - Windows specialize，生成独立 OS 身份；
   - 连接 `dls.gvmates.com:443`；
   - 运行授权 `VgpuPortable.exe /no-launch` 一次；
   - 验证 VM UUID/profile、DEV_1E30、GRID 538.33、Code 0、Licensed；
   - 应用性能设置并关闭休眠/Fast Startup；
   - 从只读初始化光盘复制 VM-bound 系统 NVAPI 包到受保护的 `ProgramData`；
   - 安装 x86/x64 系统 NVAPI 与显示器身份，内部自动重启一次；
   - 验证生产签名驱动、Code Integrity、x86/x64 收据和显示器身份后完整关机。
7. VMate 出现“初始/完成初始化”后点一次，并完成管理员认证。
8. VMate 会只读复核来宾结果、系统 NVAPI 合同和独立 OS 身份，与本机已初始化
   G-11 VM 查重，离线刷新该 VM 的显示器缓存，然后自动启动 VM。

首次启动期间会暂时跳过宿主离线显示器刷新；“初始”成功时才统一刷新。这样新克隆
只经历一次自动首启、一次来宾内部自动重启、一次最终完整关机和一次“初始”，不需要
用户额外运行软件、关机或刷新。

## Sysprep 会不会删驱动

`/generalize` 会移除模板中的已配置设备实例，让克隆在 `specialize` 阶段重新执行
PnP 枚举；它不会把第三方驱动包从 Driver Store 删除。为了适配其它兼容电脑，本
方案明确保持 `PersistAllDeviceInstalls=false`。不要为了“保留设备”把它改为 true；
该设置只适合硬件完全相同的部署，跨电脑时可能留下错误设备状态。

每个目标宿主仍须满足同一套 G-11 生产环境合同；“可移植”不表示可以绕过 GPU
型号、mdev、生产签名 GRID 版本或宿主环境检查。

## 失败时怎么做

- 自动首启成功不等待按键：5 秒后内部重启，最终验收后自动关机。失败时窗口会
  保留红色错误并停在“请按任意键继续”，同时写入下面的完整错误文件。
- 首次启动失败时 VM 不会自动关机；在已经打开的 Windows 中查看
  `C:\ProgramData\VMate\G11\clone-initialization-error.txt`，修复网络/驱动后，
  右键管理员运行桌面的 `Retry-Clone-Initialization.cmd`。
- 若错误停在“安装32/64位程序共用的单显卡系统投影”之后，并报告原生 D3D12
  tier 11，说明该克隆使用了旧版“tier 0 强制门禁”初始化包。母盘不用重做；先
  关闭实验 VM，在宿主执行 `./deploy/scripts/vmctl.sh repair-init ID`，再启动它并
  管理员运行桌面恢复脚本。新版会如实警告签名 transport 的 DXR 差异，只在
  x86/x64 D3D12 无法枚举/查询时停止。修复完成会直接删除旧的每 VM 初始化包，
  不创建 archive。
- 如果失败后的 VM 已经关机，先点一次“初始”保留错误状态，再点“进入 Windows
  修复”（侧栏为“修复首启”）。恢复脚本成功自动关机后再点一次“初始”。这些都是
  失败恢复入口；正常成功路径不会显示。
- “初始”失败时不会清除等待标记，也不会启动 VM。按界面错误修复宿主依赖后再点
  一次即可。当前宿主会把来宾保存的错误原文直接显示在“初始”失败信息中；不要在
  记录错误前删除该 VM。
- 不要使用 `ntfsfix`、`remove_hiberfile` 或强制挂载来掩盖休眠/脏卷。应让 Windows
  正常启动并完整关机。

## 官方依据

- [Sysprep (Generalize) a Windows installation](https://learn.microsoft.com/windows-hardware/manufacture/desktop/sysprep--generalize--a-windows-installation)
- [PersistAllDeviceInstalls](https://learn.microsoft.com/windows-hardware/customize/desktop/unattend/microsoft-windows-pnpsysprep-persistalldeviceinstalls)
- [Sysprep process overview](https://learn.microsoft.com/windows-hardware/manufacture/desktop/sysprep-process-overview)
- [AutoLogon](https://learn.microsoft.com/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-autologon)
- [AdministratorPassword Value](https://learn.microsoft.com/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-useraccounts-administratorpassword-value)
