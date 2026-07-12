#!/bin/bash
# stealth-lib.sh —— 共享的 SMBIOS / 磁盘 / MAC / GPU 随机化库，被 start-vm.sh
# 等启动脚本 source。
#
# 使用：source 之后调用：
#   stealth_pick_profile        生成一份新身份并 export 全部字段
#   stealth_load_profile <path> 从文件载入并 export
#   stealth_save_profile <path> 持久化到文件
#   stealth_print_profile       打印身份
#   stealth_smbios_args         输出 -smbios 行（每行一条，commas 已转义）
#   stealth_qemu_cpu_arg        输出 -cpu 后的完整字符串

# ------------------------------------------------------------------
# 本库已按职责拆分为 lib/stealth-*.sh（审计 P1#5 重构，行为对调用方透明：
# source 本文件后所有原函数 / 数组照常可用）。按依赖顺序 source。
# ------------------------------------------------------------------
_SL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SL_DIR/lib/stealth-rng.sh"          # PRNG + 主板 serial 生成器
source "$_SL_DIR/lib/stealth-pools.sh"        # CPU/主板/GPU/NVMe/内存/外设 随机池
source "$_SL_DIR/lib/stealth-gen.sh"          # NVMe/DIMM/显示器/USB serial + MAC/UUID
source "$_SL_DIR/lib/stealth-pick.sh"         # stealth_pick_profile
source "$_SL_DIR/lib/stealth-profile-io.sh"   # 白名单 + save / load(安全解析)
source "$_SL_DIR/lib/stealth-print.sh"        # stealth_print_profile
source "$_SL_DIR/lib/stealth-smbios.sh"       # stealth_qemu_cpu_arg + stealth_smbios_args
