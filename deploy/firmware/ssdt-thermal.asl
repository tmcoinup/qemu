/*
 * SSDT: 给伪 OEM Windows guest 注入一个最小但合规的 ACPI 热区 + 风扇。
 *
 * 动机
 * ----
 * QEMU 默认 DSDT 不带 \_SB.TZxx / Fan 设备；裸金属桌面机出厂 ACPI 都至少有
 * 一个 ThermalZone（CPU package thermal）+ 一个 chassis Fan。反作弊扫描
 * `Get-CimInstance Win32_TemperatureProbe` / `Win32_Fan` 全空，或解析 ACPI 表
 * 树找不到 `_TZ` 域，都是弱 VM 指纹。
 *
 * 实现策略
 * --------
 * 最小可读 SSDT：一个 ThermalZone 返回固定 40°C 室温读数 + 一个 PNP0C0B
 * 风扇设备（status 报"运行中"）。**故意保持简洁**：不写 _PSL / _ALx /
 * _AC0..9 关联表——它们要求精确的处理器/风扇拓扑，写错反而暴露异常。
 *
 * 温度返回值是 deci-Kelvin（dK = 10 × K）：
 *   - 40°C = 313.15K = 3131.5 → 写 0x0C3C (3132) "正常空闲温度"
 *   - 85°C 被动散热阈值      → 0x0DFE (3582)
 *   - 105°C 临界关机          → 0x0EC6 (3782)
 *
 * 命名空间冲突防御
 * ----------------
 * 用 `TZQE` / `FANE` 后缀（QEmu）防止跟 base DSDT 或其它 SSDT 撞名。
 * QEMU q35 base DSDT 不定义任何 ThermalZone，所以理论上无冲突；后缀仅做
 * 防御。OEM ID = "ALASKA"、OEM Table ID = "ThermZon" 与 aml-build.h
 * patched ACPI OEM 一致，跨表对照不矛盾。
 */
DefinitionBlock ("", "SSDT", 2, "ALASKA", "ThermZon", 0x00000001)
{
    External (\_SB_, DeviceObj)

    Scope (\_SB)
    {
        ThermalZone (TZQE)
        {
            // 当前温度——deci-Kelvin。返回 40°C 空闲值。
            Method (_TMP, 0, NotSerialized)
            {
                Return (0x0C3C)
            }
            // Critical shutdown 阈值——105°C，与桌面 CPU 真实 Tcase Max 接近。
            Method (_CRT, 0, NotSerialized)
            {
                Return (0x0EC6)
            }
            // Passive cooling 阈值——85°C 开始软件降频。
            Method (_PSV, 0, NotSerialized)
            {
                Return (0x0DFE)
            }
            // 控制因子：_TC1 / _TC2 经验值，决定 OS 调节响应曲线
            Method (_TC1, 0, NotSerialized) { Return (0x04) }
            Method (_TC2, 0, NotSerialized) { Return (0x03) }
            // Sample period 1 秒 (单位 0.1s)
            Method (_TSP, 0, NotSerialized) { Return (0x0A) }
        }

        Device (FANE)
        {
            Name (_HID, EisaId ("PNP0C0B"))
            // _STA 返回 0x0F = present + enabled + show in UI + functional
            Method (_STA, 0, NotSerialized)
            {
                Return (0x0F)
            }
        }
    }
}
