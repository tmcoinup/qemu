# G-11 Sysprep 私有基础镜像：傻瓜制作与克隆

这条流程的结果是：制作方只在模板里执行一次 Sysprep；每台克隆拥有独立的
Windows SID、MachineGuid、计算机名和 VM UUID；授权版 `VgpuPortable.exe` 在每台
克隆首次启动时只运行一次。随后自动安装该 VM 专属的 x86/x64 系统 NVAPI、内部
重启一次；同一条链还会自动应用 Guest Lite 2.6.7 克隆快速路径，关闭 Defender 实时扫描、三种
防火墙 profile，同时保留 `MpsSvc` Auto/Running，关闭系统/软件更新、资讯、天气、商店、OneDrive、通知和
审核过的后台高占用项；开启游戏模式、关闭 Game DVR、选择高性能电源/NVIDIA 最高
性能、固定 DNF High 优先级并安全清理超过 24 小时的固定 Temp 文件，将默认声音静音，并把输入顺序设为 en-US/US keyboard 第一、
zh-CN/Microsoft Pinyin 第二，同时保留桌面背景、字体和精确回滚基线。验收显示器身份后
Windows 完整关机。用户只需在 VMate 点一次“初始”，宿主便会校验全部结果、核对
本机没有重复的 Machine SID、MachineGuid、计算机名或 VM UUID，并刷新显示器缓存。

这里的“关闭防火墙”是可验证的运行态：三个 profile 均关闭，MpsSvc 为
Auto/Running/PID>0；这既保留 Windows AppContainer/NVIDIA 控制面板注册能力，也保留
组件维护和精确回滚能力，不删除服务、规则、BFE 或系统文件。

## 重要结论

- 不需要先运行无凭据通用版、再运行授权版。正常成功路径只调用驱动绑定的授权 V8 版一次；
  只有首次明确失败、管理员执行恢复脚本时才会再次尝试。
- 文件固定放在 `C:\ProgramData\VMate\G11`，不依赖可能因光驱/数据盘变化而改变的
  `D:` 盘符。
- 基础镜像内预置的是授权 `VgpuPortable.exe`、首启脚本和 OOBE 应答文件；
  `package-system-nvapi-projection.sh` 的产物绑定 VM ID、UUID、GPU profile、显示器
  profile 和 `vm.conf` 哈希，不能预先烘焙。VMate 创建克隆时会自动生成它，以只读
  光盘挂入，来宾复制到受保护的 `ProgramData` 后完成安装和重启验证。
- `package-g11-sysprep-kit.sh` 是制作模板所需公开文件的唯一封装入口；一次运行会编译
  Guest Lite EXE，并把 Seal、篡改防护只读门禁、实验克隆状态回滚器、应答文件、
  Finalize、Retry、固定 manifest 的 Guest Lite 自动载荷全部归集进一个
  `G11SysprepKit` 目录。工具包不含授权 EXE 或 token；关机后仍须运行本页第二节的
  私有 base 总命令，克隆才会自动完成授权链。
- `build-g11-private-base.sh` 每次都会先从当前 checkout 重新打包授权 EXE，再离线注入
  Finalize、Retry、Guest Lite 和应答文件；已有且凭据未变化的授权 EXE 只作为可信旧输入
  校验，不会跳过当前源码构建。因此普通源码升级不需要加 `--replace-licensed`；该参数只在
  token、profile catalog 或驱动封装合同有意变更时使用。
- 生产驱动快速门禁只接受 Windows 10 x64 标准 DriverStore 目录
  `nvgridsw.inf_amd64_<16 位十六进制哈希>`，并把运行中的 `nvlddmkm.sys`、活动
  `oemN.inf`、DriverStore INF 与 NVIDIA/WHCP catalog 逐一绑定。它不再执行耗时的
  全量在线 DISM 驱动扫描，也不会放宽生产签名要求。
- token 可以由多台 VM 共用，但只进入私有 EXE 和私有 qcow2；不会写入 Git 或 deb。
- 独立手工版 Guest Lite EXE 静态链接编译器支持，只依赖 Windows 10 自带 DLL、
  PowerShell 5.1 和系统命令；不会向来宾安装 Python、Java、VC++/.NET 运行库或
  常驻第三方服务。私有母盘的自动首启链不运行这个独立 EXE，而是验证并直接执行
  母盘内固定的 Guest Lite 脚本载荷。
- Guest Lite 回滚状态使用稳定的 `MachineGuid + RID-500 用户 SID` 绑定；系统 NVAPI
  重命名 Windows 后仍可验收，但绝不会接受另一台 Windows 或另一名用户的状态。
- DLS 固定为 `dls.gvmates.com:443`。
- 不开启 `testsigning`、`nointegritychecks`，不修改 BCD，不安装测试签名或自签名
  内核驱动。

## Guest Lite 怎么编译、怎样进入母盘、放在哪里

先区分两种用途：

- 完整 `G11SysprepKit` 同时归集两种公开载荷：`Payload` 供 G-11 私有母盘无人值守
  首启使用；`Standalone-GuestLite/G11GuestLite.exe` 只供其他已有 Windows 手工运行。
- G-11 私有母盘的自动链不运行独立 EXE。`Seal-G11-Template.cmd` 会自动把 `Payload`
  中经过 `clone-manifest.json` 固定摘要校验的 PS1/CMD 载荷预置到 `ProgramData`，
  首次克隆时由 `Finalize-Clone.ps1` 直接运行 `CloneApply`。

### 1. 一次编译并归集完整目录

在宿主安装一次编译和 manifest 校验依赖：

```bash
sudo apt update
sudo apt install -y mingw-w64 jq
```

然后在项目根目录只运行一个封装脚本：

```bash
cd /home/ubuntu/projects/qemu
./deploy/package-g11-sysprep-kit.sh --replace
```

它会编译一次 64 位 Windows 用户态 `G11GuestLite.exe`，自动创建并原子发布下面的
完整目录：

```text
/home/ubuntu/images/staging/G11SysprepKit/
├── Assert-G11-Template-Ready.ps1          # 只读检查篡改防护/VM 绑定状态
├── Assert-G11-Sysprep-Servicing-Ready.ps1 # 只读检查更新/组件维护状态
├── Collect-Sysprep-Diagnostics.ps1        # Sysprep 失败时只读生成报告
├── G11-Sysprep-README.txt
├── Invoke-G11-Sysprep.ps1                 # 静默执行并按本次 Panther 增量验收
├── Reset-G11-Template-State.ps1           # 用保存基线回滚实验克隆状态
├── Seal-G11-Template.cmd                  # Windows 中唯一要运行的入口
├── g11-sysprep-clone.xml
├── Payload/
│   ├── Finalize-Clone.ps1
│   ├── Retry-Clone-Initialization.cmd
│   └── GuestLite/
│       ├── clone-manifest.json
│       ├── G11-Guest-Lite.ps1
│       ├── 01-OneClick-Apply.cmd
│       ├── 02-Audit.cmd
│       ├── 03-Rollback.cmd
│       └── README.txt
├── Standalone-GuestLite/
│   └── G11GuestLite.exe                  # 其他已有 Windows 手工版，模板中不要运行
└── Template-Reset/
    ├── GuestLite/G11-Guest-Lite.ps1      # 只由 Reset 调用 Rollback
    └── GuestPerformance/Optimize-Guest.ps1
```

脚本会自动把发布用 CMD 转成 CRLF，按 manifest 验证 Guest Lite 每个文件的 SHA-256
和大小，并验证 EXE 已生成；不需要手工寻找、复制或改名 Finalize/Retry。`--replace`
只会覆盖脚本自己生成的旧三文件版或当前完整目录；发现操作员额外文件、缺失文件、
符号链接或异常类型会拒绝删除。

这个完整目录不含 token、宿主凭据、VM 身份、授权 `VgpuPortable.exe` 或内核驱动；
编译和封装本身不会修改任何 Windows。若只是给已有 Windows 单独制作只读 Guest Lite
ISO，才另用 `./deploy/package-guest-lite.sh`；制作 G-11 私有母盘不需要再运行它。

编译后可运行完整回归：

```bash
./deploy/tests/vgpu/test_guest_lite_package.sh
./deploy/tests/vgpu/test_g11_sysprep_private_flow_static.sh
```

### 2. 一键封装进新的 G-11 私有母盘

把上面生成的整个 `G11SysprepKit` 目录复制成模板 Windows 的
`C:\G11SysprepKit`。**不要**把工具包放在 `C:\ProgramData\VMate\G11` 或其子目录；
那个位置是 Seal 自动生成的首启目标目录，不是工具包来源。不要在模板中运行
`Standalone-GuestLite/G11GuestLite.exe`；
模板阶段提前 Apply 会生成绑定模板 `MachineGuid` 和用户 SID 的回滚状态，不能带给
克隆。管理员只运行根目录中的 `Seal-G11-Template.cmd`；它会先只读确认 Windows 10、
管理员、篡改防护已手工关闭，并拒绝已经安装过每 VM 系统 NVAPI 投影的克隆；随后按
保存基线依次回滚 Guest Lite 和性能实验状态，清理旧首启结果，再把 Finalize、Retry
和 Guest Lite `Payload` 预置到 `C:\ProgramData\VMate\G11`，紧接着只读检查 CBS、
Windows Update、待重启、DISM pending package 和 Reserved Storage 功能状态，最后以
`/quiet` 执行 Sysprep 并完整关机。门禁或回滚失败时不会启动 Sysprep，也不会靠改
Defender 注册表/ACL、`ReserveManager` 或 Sysprep 状态注册表绕过。

模板关机后，回宿主运行一个私有母盘总命令：

```bash
./deploy/build-g11-private-base.sh 1 win10-base \
  --vms-dir=/home/ubuntu/images/vms
```

其中 `1` 是已经 Sysprep 关机的模板 VM ID。总命令会构建并注入仓库外 token 对应的
授权 `VgpuPortable.exe`，同时用仓库当前版本再次校验/刷新 Finalize、Retry、Guest Lite
和应答文件。这样即使复制工具包后仓库发生更新，母盘最终也只接受一套彼此匹配的
载荷；不需要手工挂载镜像。

母盘内固定目录如下（这里故意没有 `G11GuestLite.exe`）：

```text
C:\ProgramData\VMate\G11\
├── VgpuPortable.exe
├── Finalize-Clone.ps1
├── Retry-Clone-Initialization.cmd
└── GuestLite\
    ├── clone-manifest.json
    ├── G11-Guest-Lite.ps1
    ├── 01-OneClick-Apply.cmd
    ├── 02-Audit.cmd
    ├── 03-Rollback.cmd
    └── README.txt
```

每台克隆第一次启动时，finalizer 会先验证 manifest 和上述每个文件的 SHA-256/大小，
再执行 Guest Lite。Apply 后，该克隆自己的回滚基线、审计文件和本地工具固定放在：

```text
C:\ProgramData\G11GuestLite\
├── state.json                 # 绑定本克隆 MachineGuid + RID-500 SID 的原始回滚基线
├── enforce-last.txt           # SYSTEM 补强任务最近一次回执
├── reports\                   # 审计报告
└── tools\                     # 本地 Apply/Audit/Rollback 脚本
```

`C:\ProgramData\VMate\G11\GuestLite` 是母盘携带的、受 manifest 保护的首启源载荷；
`C:\ProgramData\G11GuestLite` 是每台克隆首次 Apply 后生成的独立状态目录。两者不要
混放，也不要把后一目录从模板或另一台 VM 复制过来。

### 3. 把新版 Guest Lite 刷新进已有母盘

仓库中的 finalizer/Guest Lite 更新后，先只读检查；只有显示 `STALE` 才执行刷新：

```bash
./deploy/scripts/refresh-g11-private-base.sh win10-base --check
./deploy/scripts/refresh-g11-private-base.sh win10-base   # 仅 STALE 时运行
```

刷新脚本会原子更新母盘中的 Guest Lite/finalizer，并重新生成传输清单。不要把单个 PS1、
CMD 或自行修改的 `clone-manifest.json` 直接塞进 qcow2；manifest、finalizer 固定摘要和
版本必须成套一致，否则构建或首启会拒绝。刷新只影响之后创建的克隆，已有失败克隆按
本文“失败时怎么做”使用 `repair-clone-init.sh`。

## 一、制作模板 Windows

1. 在 G-11 模板 VM 中安装 Windows、原版生产签名 GRID 538.33 驱动和业务软件；
   保留至少一个日常使用的、有密码的本地管理员账户。
2. 正常启动一次，确认 NVIDIA 设备是 `DEV_1E30`、驱动版本
   `31.0.15.3833`、设备状态 Code 0。
3. 在“Windows 更新”中安装全部更新并正常重启；重复检查，直到没有“正在安装”或
   “需要重启”。Sysprep 不能在更新/组件维护仍占用 Reserved Storage 时运行。
4. 最后一次更新重启后，打开“Windows 安全中心 → 病毒和威胁防护 → 管理设置”，
   手工关闭一次“篡改防护”。自动链不会绕过该开关；未关闭时 Seal 会明确拒绝。
5. 模板阶段不要运行任何 `VgpuPortable.exe` 或
   `Standalone-GuestLite/G11GuestLite.exe`，也不要只给当前用户安装/更新 Microsoft
   Store 应用；前两者会污染克隆首次运行/回滚基线，后者可能导致 Sysprep 校验失败。
6. 在宿主项目目录只运行一次完整归集命令：

   ```bash
   ./deploy/package-g11-sysprep-kit.sh --replace
   ```

   输出会自动创建 `/home/ubuntu/images/staging/G11SysprepKit`，编译 Guest Lite EXE，
   并归集 Seal、应答文件、Finalize、Retry 和 Guest Lite。`--replace` 可以安全升级旧
   三文件版或刷新当前完整封装；目录里有额外/缺失内容时会拒绝覆盖。

7. 把输出的整个 `G11SysprepKit` 目录复制为模板中的 `C:\G11SysprepKit`；不要复制到
   `C:\ProgramData\VMate\G11`。
8. 在 Windows 中右键“以管理员身份运行”`Seal-G11-Template.cmd`，按 `Y`。脚本会先
   显示篡改防护门禁结果；如果这是 vm1/vm2 一类在首次初始化中途失败的实验克隆，
   它会按 `state.json` 保存的原始基线回滚后再删除旧状态。不要提前手工删这些目录。
9. 只有门禁和回滚都显示 `[PASS]` 后，脚本才把公开 Payload 预置到
   `C:\ProgramData\VMate\G11`；随后只读复核 Windows servicing 状态，并执行：

   ```text
   Sysprep.exe /generalize /oobe /shutdown /quiet /unattend:g11-sysprep-clone.xml
   ```

10. 等模板完整关机。成功后不要再启动这个源 VM。

应答文件已在 `specialize` 和 `oobeSystem` 固定输入顺序为 US
(`0409:00000409`) 第一、Microsoft Pinyin
(`0804:{81D4E9C9-1D3B-41BC-9E6C-4B40BF79E35E}{FA550B04-5AD7-411F-A5AC-CA038EC515D7}`)
第二。US 键盘是 Windows 10 自带组件，离线封装不需要 en-US 显示语言 CAB。当前不把
整个 Windows UI 改为英文；若以后需要英文界面，必须另备与目标 build/架构/补丁严格
匹配的微软官方 Language Pack/FOD CAB，不能使用随机或不匹配的语言包。

应答文件会隐藏 OOBE 页面并自动登录内置 Administrator 一次，但不会绕过
`/generalize`。该临时空密码账户被限制为仅本机控制台登录，初始化成功前会清除
自动登录；有另一个可用的本地管理员时会禁用该临时账户。如果模板误删了其他
管理员，流程会保留内置 Administrator，避免成功后无人能够登录；首次进入桌面后
应立即为它设置密码或创建日常管理员。应答文件故意不写 `ComputerName`，让 Windows 使用正常的
`DESKTOP-XXXXXXX` 随机名称；不要改回 `ComputerName=*`，否则 Windows 会从
Administrator/组织信息派生出 `ADMINS-*` 一类前缀。首启包还会按 V-11 的精确规则
把最终名称锁定为 `DESKTOP-` 加该 VM UUID 的前 7 位，并借用本来就需要的内部验收
重启生效，不增加一次重启。

自动首启成功时不要求按键：它会内部重启一次、验收后自动完整关机。第一次自动重启
后，用户一登录就会看到置顶的“克隆初始化仍在继续”状态窗。**进入桌面不代表初始化
已经完成**；状态窗明确要求不要关机、重启或注销，并显示已等待时间。最终 marker
写入后它会切换为“正在自动关机”，随后才出现 Windows 的关机提示。后台失败时状态
窗会直接给出错误文件和桌面 Retry 入口。任何阶段失败时，第一次登录的黑色窗口也会
保留错误并停在“请按任意键继续”，同时把 UTF-8 完整错误写入
`C:\ProgramData\VMate\G11\clone-initialization-error.txt`；无需靠一闪而过的红字猜错。

2026-08-27 在 `gtx750_asus_1gb`/AOC 2470W 的全新 vm3 实测：QEMU 启动后约
13 分 39 秒写入最终 marker，约 14 分 04 秒完整关机；其中授权 portable 主体约
1 分 39 秒，Guest Lite 首轮主体约 1 分 19 秒。旧流程同机约 22 分钟，本次缩短约
8 分钟（约 36%）。这是一次实测而非固定 SLA；Windows 更新、存储速度、DLS 网络和
首次设备枚举仍会影响总时长。

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
2. 构建 VM 无关、全 profile 通用、固定 R535/GRID 538.33 的授权 V8 `VgpuPortable.exe`；
3. 离线注入授权 EXE，并再次校验/刷新首次启动脚本、Guest Lite 和 OOBE 应答文件；
4. 生成本机绑定的 schema-8 证明，精确记录 R535/`31.0.15.3833` 和 V8 launcher，
   并声明每 VM 系统 NVAPI 两阶段首启为必需项；
5. 在 `--base-dir` 中给同一个 qcow2 生成 `.g11base` 传输清单，不复制第二份镜像。

### 只在“封装成功、portable 打包失败”时续跑

如果终端已经明确显示“基础镜像封装完成”和新 qcow2 大小，随后才在
`package-vgpu-one-click.sh` 阶段失败，不要重新压缩几十 GiB，也不要删除刚生成的
qcow2。以同一个源 VM ID、同一个 base 名称显式续跑。例如 vm9 的 `g-1` 遇到
“licensed portable EXE receipt does not match this token/catalog/driver”时，只执行：

```bash
./deploy/build-g11-private-base.sh 9 g-1 \
  --resume-sealed --replace-licensed
```

`--replace-licensed` 只用于错误已经明确说明 token/catalog/driver 封装合同不匹配的
情况；单纯网络或编译工具临时失败时去掉它。`--resume-sealed` 不是自动推断：不写该
参数时仍必须执行正常 seal，同名 qcow2 已存在就会拒绝，不会悄悄跳过封装。

续跑开始前会先做失败即停的安全门禁：源 VM 的启动锁、QEMU 进程以及源盘/base 文件
占用都表明 VM 已停止；现有 base 是普通、单 hard-link、`qemu-img check` 通过且没有
backing/data-file 的 standalone qcow2；它与当前源盘 virtual size 相同且时间不早于
源盘，并由 `qemu-img compare` 确认逻辑内容逐扇区一致；同名 `.g11base`、
`.vgpu-portable.json` 和 installer/export 事务残留全部不存在。打包前的 base
设备号/inode/大小/纳秒 mtime 还会形成状态摘要，注入器取得全局存储锁后必须再次匹配。
任一条件不满足都不要手工伪造或删除证明文件来绕过，请保留终端错误并核对实际状态。
续跑模式不能再带 `--compression-type`、`--compression-parallel` 或 `--no-progress`，
因为这些只属于不会重跑的 seal 阶段。通过门禁后，脚本仍会从当前 checkout 重新打包，
然后继续离线注入和生成 `.g11base`。

私有 qcow2 在注入授权凭据前会强制设为宿主当前用户独占读写（`0600`）；不要为了
方便共享而放宽权限，跨电脑交付请使用受控介质复制 `.qcow2 + .g11base`。

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

只有确认 token、profile catalog 或驱动封装合同已变更时才加
`--replace-licensed`。不要把 base 目录提交 Git，也不要放到公共网盘；qcow2 内含
授权凭据。

## 三、本机直接从同一个镜像克隆

不需要先“导入回本机”，也不需要再复制到旧的 `shared/bases/`。直接运行与 V-11
同形的默认命令；它会从 `/home/ubuntu/images/vms/_base` 取镜像，并默认创建
V-11 式增量盘：

仓库的 finalizer/Guest Lite 有升级后，先做一次只读检查；显示 `STALE` 时按提示刷新
一次母盘，后面的所有克隆都会使用新载荷：

```bash
./deploy/scripts/refresh-g11-private-base.sh win10-base --check
./deploy/scripts/refresh-g11-private-base.sh win10-base   # 仅 STALE 时运行
```

```bash
./deploy/scripts/clone-from-base.sh win10-base 9 --start
```

此命令返回后不要立即再次启动或强制停止 VM9。等待 Windows 自动完成一次内部重启，
随后让 QEMU 因来宾完整关机自行退出。命令行环境再执行下面两条；图形界面中等价操作
是点一次“初始”，成功后再点“启动”：

```bash
sudo ./deploy/scripts/initialize-clone.sh 9
./deploy/scripts/start-vm.sh 9
```

`initialize-clone.sh` 只接受完整关机的干净 NTFS；它会只读验证 Licensed、GRID
538.33/Code 0、独立 Windows 身份、系统 NVAPI、Guest Lite SYSTEM 回执及
`MpsSvc=Auto/Running/PID>0`，再离线刷新显示器缓存并发布 `.g11-initialized`。
失败时不会清除 `.g11-init-required`，也不会把半成品 VM 标记为可用。不要使用
`ntfsfix`、`remove_hiberfile` 或强制挂载跳过门禁。

例如要固定为 1GB 显存池，并选择 Core i7-4820K、4 核 8 线程、ASUS P9X79、
Elpida DDR3-1866 双通道 8GB（4GB ×2），以及 Samsung 970 PRO 512GB
PCIe 3.0 ×4 NVMe 这套审核组合，直接在克隆命令里指定；不需要提前创建配置，
也不需要写 `--linked`（它已经是默认值）：

```bash
./deploy/scripts/clone-from-base.sh win10-base 1 \
  --gpu-vram 1024 \
  --platform i7-4820k-p9x79-elpida-8g \
  --ssd-profile samsung-970-pro-512gb \
  --start
```

这套搭配的共同上限是 LGA2011/X79、DDR3-1866 和 CPU 直连 PCIe Gen3。8GB 由两条
同型号 4GB DIMM 组成，按双通道工作。P9X79 没有原生 M.2，970 PRO 通过已审核的
被动 M.2-to-PCIe Gen3 ×4 转接路径连接，不冒充板载 M.2。i7-4820K 本身不带核显，
P9X79 也没有处理器核显输出，因此不存在需要伪造的“主板已禁用核显”状态；正常 vGPU
启动使用 `-vga none`，只呈现 NVIDIA vGPU，安装/救援时的临时标准 VGA 不属于核显。

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

1. 优先使用“首次初始化在系统 NVAPI 安装前失败”的实验克隆，或一直保留的专用模板
   VM，再安装 Windows/业务软件更新。已经完成系统 NVAPI 初始化的普通克隆绑定了
   自己的 VM UUID/profile，不能直接封成母盘；Seal 会明确拒绝，不能手工删除其状态
   目录来冒充已回滚。
2. 在 Windows 安全中心手工关闭篡改防护，把最新 `G11SysprepKit` 放入维护 VM，
   管理员运行 `Seal-G11-Template.cmd`。Seal 会先按保存基线回滚 Guest Lite/性能实验
   状态、清理旧首启标记，再执行 Sysprep；等待完整关机。
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
   - 校验固定 Guest Lite manifest，自动关闭 Defender、防火墙 profile、更新，并保留 MpsSvc、
     云盘、资讯天气、通知、商店/消费 App 和审核过的后台项，将默认声音静音；输入顺序
     固定为 en-US/US 第一、Microsoft Pinyin 第二，并保留其他语言、背景、字体及回滚基线；
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

- 新版 Seal 使用微软的 `/quiet` 自动化参数，不再等待“无法验证你的 Windows 安装”
  模态弹窗；也不再信任 Sysprep 不可靠的进程返回码。它比较调用前后的 Panther 日志，
  只用本次新增错误判定失败，再把 `C:\G11SysprepKit\Sysprep-Diagnostics.txt` 自动
  保存并打开。看到
  `0x800F0975` / `reserved storage is in use` 时，不要删 Appx，也不要修改
  `ReserveManager` 或 Sysprep 状态注册表；先安装全部 Windows 更新并正常重启，重复
  到没有更新/重启待处理，再确认篡改防护关闭，只重新运行 Seal。微软对这个错误的
  处理也是完成更新和重启。脚本会提前拦截公开可见的 pending/busy 信号，但微软没有
  “Reserved Storage 当前正在占用”的权威只读接口，因此不会冒充自动修复，也绝不以
  `Set-ReservedStorageState` 作探针。
- 若报告显示 `0x80073cf2` 以及某个包“installed for a user, but not provisioned for
  all users”，只处理报告点名的精确 Appx 包及所属模板用户；不要运行“删除全部 Appx”
  的脚本。
- 自动首启成功不等待按键：5 秒后内部重启，最终验收后自动关机。失败时窗口会
  保留红色错误并停在“请按任意键继续”，同时写入下面的完整错误文件。
- 第一次自动重启后即使已经进入桌面，也必须等“克隆初始化仍在继续”状态窗切换为
  完成并让 VM 自动关机；桌面出现不是完成信号。若在最终自动关机前误点了 Windows
  的正常关机，先重新启动同一台 VM，登录后让保留的启动续跑任务继续，仍不要执行宿主
  “初始”。若再次启动后仍失败或长时间不自动关机，再按下一条运行 Retry。若曾直接
  关闭 QEMU/断电，则先让 Windows 正常启动并完成文件系统自检；不要用 `ntfsfix`、
  `remove_hiberfile` 或强制挂载。
- 首次启动失败时 VM 不会自动关机；在已经打开的 Windows 中查看
  `C:\ProgramData\VMate\G11\clone-initialization-error.txt`，修复网络/驱动后，
  右键管理员运行桌面的 `Retry-Clone-Initialization.cmd`。
- 最新 Retry 会自动识别已经完成的系统 NVAPI 验证，直接续跑 Complete 验收，不会
  重复 Apply 或覆盖 Guest Lite 的首次回滚基线。状态允许计算机名改变，但仍严格绑定
  MachineGuid 和 RID-500 SID；SYSTEM 任务以启动前后的 `LastRunTime` 单调变化确认
  本次运行，不依赖容易受时区/调度延迟影响的两秒时间窗口。
- 若错误包含 `Only cataloged GDDR5 ...`（尤其 Gigabyte GTX 750 / Elpida=3），或
  Guest Lite 报 `property 'Name' cannot be found`，说明克隆使用的是旧私有 EXE/旧
  Guest Lite 载荷。不要开启测试签名或修改 BCD。已经失败的克隆先完整关机，在宿主
  执行 `sudo ./deploy/scripts/repair-clone-init.sh ID`；后续克隆再执行一次
  `./deploy/scripts/refresh-g11-private-base.sh win10-base` 刷新母盘。
- 若“初始”诊断显示旧 `schemaVersion` 或旧 `guestLite.profileVersion`，使用同一条
  `repair-clone-init.sh ID`。它会保留 Licensed 结果和正式驱动，仅离线更新用户态
  finalizer/Guest Lite 与 VM 绑定 ISO；完整步骤见
  [`G11-CLONE-PAYLOAD-RECOVERY.md`](G11-CLONE-PAYLOAD-RECOVERY.md)。
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
- [Sysprep 命令行与 `/quiet`](https://learn.microsoft.com/windows-hardware/manufacture/desktop/sysprep-command-line-options)
- [Windows Setup `ImageState`](https://learn.microsoft.com/windows-hardware/manufacture/desktop/windows-setup-states)
- [PersistAllDeviceInstalls](https://learn.microsoft.com/windows-hardware/customize/desktop/unattend/microsoft-windows-pnpsysprep-persistalldeviceinstalls)
- [Sysprep process overview](https://learn.microsoft.com/windows-hardware/manufacture/desktop/sysprep-process-overview)
- [Sysprep/捕获失败：Reserved Storage 与 Appx 的官方处理](https://learn.microsoft.com/troubleshoot/mem/configmgr/os-deployment/windows-11-image-capture-fail)
- [DISM Reserved Storage 命令说明](https://learn.microsoft.com/windows-hardware/manufacture/desktop/dism-storage-reserve)
- [Sysprep 遇到 Microsoft Store Appx 不一致](https://learn.microsoft.com/troubleshoot/windows-client/setup-upgrade-and-drivers/sysprep-fails-remove-or-update-store-apps)
- [AutoLogon](https://learn.microsoft.com/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-autologon)
- [AdministratorPassword Value](https://learn.microsoft.com/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-useraccounts-administratorpassword-value)
