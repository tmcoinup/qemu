# AMD ADL 系统级兼容层

本目录生成 Windows x86 `atiadlxy.dll` 与 x64 `atiadlxx.dll`。实现不识别
GPU-Z、HWiNFO 等进程名称；所有调用方读取同一份
`HKLM\SOFTWARE\StealthGPU` 版本化身份，因此可作为通用 AMD ADL/ADL2
硬件检测路径。

## 身份边界

- x86/x64 都强制读取 64 位注册表视图。
- 使用 `CurrentIdentity -> Identities\<token> -> CurrentIdentity/schema`
  的一致性协议，瞬态撕裂不会被永久缓存。
- 初次成功读取会缓存；`ADL_Main_Control_Refresh` 和
  `ADL2_Main_Control_Refresh` 每次都重走完整读取与验证，失败不覆盖上一份
  已验证 snapshot。
- schema-2 只发布共享 AIB 目录中的 6 块 AMD 板卡：RX 550 与 RX 560
  (`1002:699F`/`1002:67FF`) 各 3 个品牌；名称、SUBSYS、REV、容量、时钟、
  VBIOS 与物理 BDF 字段必须属于同一板卡。schema-1 generic 路径仅作旧 profile
  回查。
- 共享目录另含 12 块 NVIDIA 板卡；它们通过完整原子校验后返回 0 个 AMD
  adapter，不生成虚假的 AMD 句柄。全部 18 块板卡使用
  `1AF4:A101`–`1AF4:A112` carrier，物理主 ID 始终为 `1AF4:1050`。
- 未知型号、Red Hat/VirtIO 名称、类型错误或跨字段不一致均 fail-closed。

## 数据语义

静态身份可由 profile 证明，因而 AdapterInfo、MemoryInfo、GraphicCore、
VideoBios、ObservedClock 与 OD 默认时钟可返回一致值。GDDR5 profile 的
`SpoofMemoryClockKHz` 是 effective/NVAPI 口径；ADL 中统一换算成物理
1750 MHz（RX 550/560），OD5 再换算成 10 kHz 单位。

本分支不做 GPU 直通，无法取得真实温度、功耗、风扇、VRAM 实时占用、
PMLog 或 I2C 数据。这些接口以及所有写接口明确返回
`ADL_ERR_NOT_SUPPORTED`，不会伪造遥测。
目录没有标准、可核验的 GPU serial 字段，ADL 兼容层也不会合成序列号。

## 初始化与 context 边界

`ADL_THREADING_UNLOCKED` 是唯一接受的 X2/X3 threading model；本实现没有向
调用方承诺 `ADL_THREADING_LOCKED` 的全局串行语义，因此该值明确返回
`ADL_ERR_NOT_SUPPORTED`。X3 仅接受 AMD 公开样例定义的 create option bit 0，未知位
同样 fail-closed。ADL2 context 使用固定容量的 slot + generation 不透明句柄：销毁后
slot 可复用，旧句柄不会重新有效，也不保留永久 heap allocation。

除初始化和枚举入口外，兼容层也导出 AMD 官方的
`ADL_Main_Control_GetProcAddress` 与 `ADL2_Main_Control_GetProcAddress` 原型。

## 构建与测试

```bash
make
make check
```

`make check` 会执行：

- 宿主机身份/单位 contract 测试；
- 同进程身份 pointer 切换后的 Refresh cache 测试；
- context 首尾 slot 与 generation 编码边界测试；
- PE32/PE32+ 架构、零时间戳和导入表检查；
- GPU-Z 2.70 的 45 个动态入口与补充 ADL2 通用入口精确导出检查；
- 注册表一致性协议静态门禁；
- 双次构建 SHA256 可复现性检查；
- 单文件 500 行上限检查。

`adl-required-exports.txt` 是排序、无重复的唯一导出 manifest，可由上层
客体打包测试直接复用。
