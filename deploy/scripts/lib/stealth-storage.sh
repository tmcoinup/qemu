#!/usr/bin/env bash
# 依据完整平台 bundle 构造唯一的 Guest 启动盘设备。
#
# 老款 DDR3 主板只能从 SATA/AHCI 启动；支持原生 NVMe boot 的平台继续使用
# 经 component catalog 绑定的审核画像。调用方必须先加载 profile 与 DISK 路径。
# shellcheck disable=SC2034 # BOOT_STORAGE_ARGS 由启动命令组装器读取。

stealth_validate_boot_storage_serial() {
    local serial="${BOOT_STORAGE_SERIAL:-}"
    local LC_ALL=C

    # 设备属性使用逗号分隔，必须在最终 argv 入口按所选品牌重新校验。
    case "${PLATFORM_BOOT_STORAGE:-nvme}" in
        nvme)
            stealth_component_storage_serial_is_valid \
                "${BOOT_STORAGE_COMPONENT_ID:-}" "$serial" >/dev/null ||
                return 1
            ;;
        sata-ahci)
            if ! [[ "$serial" =~ ^S[0-9A-F]{14}$ ||
                    "$serial" =~ ^S[0-9A-F]{3}N[0-9A-F]{9}$ ||
                    "$serial" =~ ^S[0-9A-F]{10}N$ ]] ||
               [[ "$serial" == S00000000000000 ||
                  "$serial" == SFFFFFFFFFFFFFF ||
                  "$serial" == S000N000000000 ||
                  "$serial" == SFFFNFFFFFFFFF ||
                  "$serial" == S0000000000N ||
                  "$serial" == SFFFFFFFFFFN ]]; then
                echo "ERROR: SATA BOOT_STORAGE_SERIAL 格式非法或为占位值" >&2
                return 1
            fi
            ;;
        *)
            echo "ERROR: 无法校验未知启动存储总线的序列号" >&2
            return 1
            ;;
    esac
}

stealth_build_boot_storage_args() {
    local disk_aio="${QEMU_DISK_AIO_SELECTED:-threads}"
    local drive_options

    BOOT_STORAGE_ARGS=()
    case "$disk_aio" in
        threads|native|io_uring) ;;
        *)
            echo "ERROR: 启动盘收到未验证的 AIO 后端: $disk_aio" >&2
            return 1
            ;;
    esac
    stealth_validate_boot_storage_serial || return 1
    # Windows/Linux 对未使用区域的普通全零写入会转为 qcow2 unmap，避免稀疏盘
    # 无意义扩张；非零数据语义、cache=none 与已验证 AIO 路径保持不变。
    drive_options="file=${DISK:?缺少 DISK},if=none,id=bootdisk0,format=qcow2,cache=none,aio=${disk_aio},discard=unmap,detect-zeroes=unmap"
    case "${PLATFORM_BOOT_STORAGE:-nvme}" in
        nvme)
            if [[ "${PLATFORM_STORAGE_SWITCH_REQUIRED:-0}" != 0 ||
                  "${NVME_ROLE:-boot}" != boot ||
                  "${NVME_BOOT_SUPPORTED:-0}" != 1 ||
                  "${PLATFORM_BOOT_STORAGE_POOL_ID:-}" != component-nvme ||
                  "${PLATFORM_BOOT_MODEL:-component}" != component ||
                  "${PLATFORM_BOOT_FIRMWARE:-component}" != component ||
                  "${BOOT_STORAGE_INTERFACE:-}" != nvme ||
                  "${BOOT_STORAGE_COMPONENT_ID:-}" != "${NVME_COMPONENT_ID:-}" ||
                  "${BOOT_STORAGE_MODEL:-}" != "${NVME_MODEL:-}" ||
                  "${BOOT_STORAGE_FIRMWARE:-}" != "${NVME_FIRMWARE:-}" ||
                  "${BOOT_STORAGE_SIZE_BYTES:-}" != "${NVME_SIZE_BYTES:-}" ||
                  "${BOOT_STORAGE_SERIAL:-}" != "${NVME_SERIAL:-}" ]]; then
                echo "ERROR: NVMe 启动 metadata 自相矛盾: platform=${PLATFORM_ID:-unknown}" >&2
                return 1
            fi
            BOOT_STORAGE_ARGS=(
                -drive "$drive_options"
                -device "nvme,id=nvmectl0,bus=rp1,drive=bootdisk0,serial=${BOOT_STORAGE_SERIAL:?缺少 BOOT_STORAGE_SERIAL},x-identity-profile=${NVME_COMPONENT_ID:?缺少 NVME_COMPONENT_ID},bootindex=3,model-number=${BOOT_STORAGE_MODEL:?缺少 BOOT_STORAGE_MODEL},firmware-rev=${BOOT_STORAGE_FIRMWARE:?缺少 BOOT_STORAGE_FIRMWARE},subsys-vendor-id=${NVME_SUBSYS_VEN:?缺少 NVME_SUBSYS_VEN},subsys-id=${NVME_SUBSYS_DEV:?缺少 NVME_SUBSYS_DEV},subnqn=${NVME_SUBNQN:?缺少 NVME_SUBNQN}"
            )
            ;;
        sata-ahci)
            if [[ "${PLATFORM_STORAGE_SWITCH_REQUIRED:-0}" != 1 ||
                  "${NVME_ROLE:-}" != data-only ||
                  "${NVME_BOOT_SUPPORTED:-1}" != 0 ||
                  "${PLATFORM_BOOT_STORAGE_POOL_ID:-}" != samsung-sata-pro-512gb ||
                  "${PLATFORM_BOOT_MODEL:-}" != storage-compatibility-pool ||
                  "${PLATFORM_BOOT_FIRMWARE:-}" != storage-compatibility-pool ||
                  "${BOOT_STORAGE_INTERFACE:-}" != "SATA 6 Gb/s" ||
                  -z "${BOOT_STORAGE_MODEL:-}" ||
                  -z "${BOOT_STORAGE_FIRMWARE:-}" ||
                  -z "${BOOT_STORAGE_SIZE_BYTES:-}" ||
                  -z "${BOOT_STORAGE_SERIAL:-}" ]] ||
               ! stealth_storage_compat_binding_is_current; then
                echo "ERROR: SATA compatibility 启动 metadata 自相矛盾: platform=${PLATFORM_ID:-unknown}" >&2
                return 1
            fi
            # Q35 内建 ICH9 AHCI 提供 ide.0..ide.5，每个端口只支持 unit=0。
            # 安装介质固定占 ide.0，副 ISO 占 ide.1；启动盘使用独立的第三端口，
            # 避免仅在 --iso 启动时才暴露的 unit 冲突。
            BOOT_STORAGE_ARGS=(
                -drive "$drive_options"
                -device "ide-hd,bus=ide.2,unit=0,drive=bootdisk0,bootindex=3,model=${BOOT_STORAGE_MODEL},serial=${BOOT_STORAGE_SERIAL},ver=${BOOT_STORAGE_FIRMWARE},rotation_rate=1"
            )
            ;;
        *)
            echo "ERROR: 不支持的启动存储总线: ${PLATFORM_BOOT_STORAGE:-empty}" >&2
            return 1
            ;;
    esac
    export PLATFORM_BOOT_STORAGE PLATFORM_BOOT_MODEL PLATFORM_BOOT_FIRMWARE
    export BOOT_STORAGE_COMPONENT_ID BOOT_STORAGE_MODEL BOOT_STORAGE_FIRMWARE
    export BOOT_STORAGE_SIZE_BYTES BOOT_STORAGE_SERIAL BOOT_STORAGE_INTERFACE
}
