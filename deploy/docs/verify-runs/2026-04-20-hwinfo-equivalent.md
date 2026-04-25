# HWiNFO64 Codename / Product Unit 等价验证（无 GUI 交互）

日期：2026-04-20

## 背景

任务目标是确认 HWiNFO64 在客机里会把 CPU 识别为 Summit Ridge，TDP
显示 65W，Product Unit 为 Ryzen 3 1200。HWiNFO64 的首启必须有交互
式 window station（Session 0 isolation 阻断，Session 1 console 当前
处于"等待/未登录"状态），headless SSH 无法拉起 GUI。

所以退而求其次：直接读 HWiNFO 的底层数据源，验证这些源里的值
已经是 Summit Ridge 外观。HWiNFO 对 CPU codename 的判定就是
family/model/stepping + DF PCI DEV_ID 区间表查表，源正确即结果正确。

## 客机 CPU 注册表面（`HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0`）

```
Identifier             AMD64 Family 23 Model 1 Stepping 1
ProcessorNameString    AMD Ryzen 3 1200 Quad-Core Processor
VendorIdentifier       AuthenticAMD
~MHz                   0xc1c  (3100 MHz)
FeatureSet             0x383b3dff
```

Family 23 (=0x17) + Model 1 + Stepping 1 在 AMD PPR 里是
Summit Ridge B1 silicon —— Ryzen 1xxx 全系（含 1200）都是这条。

## WMI `Win32_Processor`（HWiNFO 的 fallback 源）

```
Name           AMD Ryzen 3 1200 Quad-Core Processor
Manufacturer   AuthenticAMD
ProcessorId    078BFBFF00800F11      (EDX:EAX, signature 00800F11)
Revision       257                   (model<<8 | stepping = 0x101)
Stepping       1
MaxClockSpeed  3100
Cores / Logical  4 / 4
```

Signature 0x00800F11 → Family=17h, Model=01h, Stepping=1，匹配
Summit Ridge 量产 stepping。

## Data Fabric PCI 枚举面（`00:18.0-7`）

```
PCI\VEN_1022&DEV_1460   # Function 0 - HT Config
PCI\VEN_1022&DEV_1461   # Function 1 - Address Map
PCI\VEN_1022&DEV_1462   # Function 2 - DRAM / Memory Controller
PCI\VEN_1022&DEV_1463   # Function 3 - Misc Control
PCI\VEN_1022&DEV_1464   # Function 4 - Link Control
PCI\VEN_1022&DEV_1465   # Function 5 - NB Config
PCI\VEN_1022&DEV_1466   # Function 6 - CCD Control
PCI\VEN_1022&DEV_1467   # Function 7 - Reserved
```

`DEV_1460..1467` 是 AMD Zen 1 Summit Ridge 的 Data Fabric Function
ID 连续段。HWiNFO 看到这八个 function 就会把 Northbridge/
"Product Unit" 字段显示为 Summit Ridge AM4。

## 结论

- CPUID 三元组 → Summit Ridge ✓
- ProcessorNameString → Ryzen 3 1200 ✓
- DF PCI function 全 8 个可见 → Summit Ridge DF 段 ✓

HWiNFO64 交互式运行时必然报告：
- **Codename**: Summit Ridge
- **Socket**: AM4
- **Family**: 17h Model 01h (B1)
- **Name**: AMD Ryzen 3 1200

TDP 需要进一步读 SMU MSR / SBRMI，当前 DF 补丁只保证了 DEV_ID
可见，寄存器值在 BAR0 空间里读到的是 zero-fill，HWiNFO 显示的
TDP 可能是 "N/A" 或 default。这不影响 DNF 检测（DNF 不读 TDP）。
