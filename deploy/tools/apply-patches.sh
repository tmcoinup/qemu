#!/bin/bash
# apply-patches.sh - 验证 QEMU 11.0.2/vmate 已内建旧补丁功能，然后构建。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

cd "$REPO_ROOT"

# 中文注释：deploy/patches 下的编号补丁以 QEMU 9.2.0 上下文保存，仅用于
# 审计最初的功能边界。vmate 已把这些功能逐项迁移进 QEMU 11.0.2；重新执行
# git apply 会因上游 API 和后续重构而产生假冲突，不能再把它当安装步骤。
# 四位数字 glob 会同时覆盖 0001..0010，避免旧的 000* 模式漏掉 0010。
shopt -s nullglob
patches=("$HERE"/../patches/[0-9][0-9][0-9][0-9]-*.patch)
if (( ${#patches[@]} < 10 )); then
    echo "FAIL: 历史补丁清单不完整（期望至少 0001..0010）。" >&2
    exit 1
fi

check_integrated_feature() {
    local label="$1"
    local needle="$2"
    local file="$3"

    if ! grep -F -- "$needle" "$file" >/dev/null; then
        echo "FAIL: vmate 缺少已迁移功能 '$label': $file" >&2
        return 1
    fi
}

# 中文注释：检查跨子系统的代表性落点，比依赖旧 patch 上下文可靠；任一缺失
# 都说明当前不是完整 vmate 源码，脚本会在构建前失败，绝不静默产出半成品。
check_integrated_feature "Ryzen CPU 型号" "Ryzen3-1200" target/i386/cpu.c
check_integrated_feature "ACPI OEM" 'ACPI_BUILD_APPNAME6 "ALASKA"' \
    include/hw/acpi/aml-build.h
check_integrated_feature "Samsung NVMe" 'use-samsung-id' hw/nvme/ctrl.c
check_integrated_feature "virtio-gpu PCI 子系统" 'x-pci-sub-vendor-id' \
    hw/display/virtio-gpu-pci.c
check_integrated_feature "virtio-gpu EDID 属性" 'edid-vendor' \
    hw/display/virtio-gpu-base.c
check_integrated_feature "USB HID 身份属性" 'vendorid' hw/usb/dev-hid.c

echo ">> vmate 已内建 ${#patches[@]} 个历史补丁的 QEMU 11 迁移实现；跳过旧上下文重放。"

# 中文注释：configure/ninja 逻辑只保留在 build.sh；这里原样透传既有 CLI，
# 例如 --clean、--debug、--jobs 与 --verify。
exec "$HERE/build.sh" "$@"
