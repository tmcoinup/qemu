# shellcheck shell=bash
# ---------------------------------------------------------------------------
# 实例磁盘创建与 profile 容量一致性校验。
#
# 单独拆分的原因：磁盘虚拟容量是硬件身份的一部分，既要在 Linux 启动器中复用，
# 也要能由无 KVM、无宿主网络权限的单元测试独立验证。
# ---------------------------------------------------------------------------

sv_prepare_disk() {
    # 组件清单已经把型号、固件、PCI ID 和容量绑成一个原子 bundle；这里不允许
    # 用型号字符串猜容量，更不能对历史镜像静默 resize。
    : "${DISK:?缺少 DISK}"
    : "${QEMU_IMG:?缺少 QEMU_IMG}"
    : "${NVME_SIZE_BYTES:?profile 缺 NVME_SIZE_BYTES}"
    : "${NVME_MODEL:?profile 缺 NVME_MODEL}"

    if [[ ! -f "$DISK" ]]; then
        if [[ "${DRY_RUN:-0}" == "1" ]]; then
            echo ">> disk:        [DRY_RUN] 跳过创建 $DISK"
        elif [[ -n "${BASE_IMAGE:-}" ]]; then
            if [[ ! -f "$BASE_IMAGE" ]]; then
                echo "ERROR: BASE_IMAGE='$BASE_IMAGE' 不存在" >&2
                return 1
            fi
            echo ">> 从 base 镜像克隆: $BASE_IMAGE"
            echo ">>   -> $DISK (qcow2 增量层)"
            "$QEMU_IMG" create -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$DISK" >/dev/null
        else
            local size_gib
            size_gib=$(( NVME_SIZE_BYTES / 1024 / 1024 / 1024 ))
            echo ">> creating fresh qcow2 at $DISK"
            echo ">>   model     : $NVME_MODEL"
            echo ">>   raw bytes : $NVME_SIZE_BYTES  (~${size_gib} GiB Windows-side)"
            "$QEMU_IMG" create -f qcow2 -o preallocation=off,cluster_size=65536 \
                "$DISK" "$NVME_SIZE_BYTES"
        fi
    fi

    # qemu-img 的 virtual-size 才是 Windows/Linux guest 看到的块设备容量。每次
    # 启动都校验，覆盖历史磁盘、外部 base image 和 profile 被手工修改的情况。
    if [[ -f "$DISK" ]]; then
        local disk_info_json
        if ! disk_info_json=$("$QEMU_IMG" info --output=json "$DISK"); then
            echo "ERROR: 无法读取磁盘元数据: $DISK" >&2
            return 1
        fi
        if ! DISK_VIRTUAL_SIZE=$(python3 -c \
            'import json, sys; value=json.load(sys.stdin).get("virtual-size"); print(value if isinstance(value, int) else "")' \
            <<<"$disk_info_json"); then
            echo "ERROR: qemu-img 返回了无法解析的 JSON: $DISK" >&2
            return 1
        fi
        if [[ ! "$DISK_VIRTUAL_SIZE" =~ ^[0-9]+$ ]]; then
            echo "ERROR: qemu-img 未返回有效 virtual-size: $DISK" >&2
            return 1
        fi
        if [[ "$DISK_VIRTUAL_SIZE" != "$NVME_SIZE_BYTES" ]]; then
            echo "ERROR: 磁盘虚拟容量与硬件 profile 不一致" >&2
            echo "       disk=$DISK virtual-size=$DISK_VIRTUAL_SIZE" >&2
            echo "       profile.NVME_SIZE_BYTES=$NVME_SIZE_BYTES model=$NVME_MODEL" >&2
            echo "       请换用匹配容量的 base image，或显式重建该实例磁盘。" >&2
            return 1
        fi
        # du 报告宿主真实分配量，只用于运维；不能把它当成 guest 可见容量。
        DISK_HOST_ALLOCATED_BYTES=$(du -B1 "$DISK" | awk 'NR == 1 { print $1 }')
    else
        # DRY_RUN 首次生成不会落盘；实际启动一定会进入上面的严格校验。
        DISK_VIRTUAL_SIZE="DRY_RUN-not-created"
        DISK_HOST_ALLOCATED_BYTES="DRY_RUN-not-created"
    fi
    export DISK_VIRTUAL_SIZE DISK_HOST_ALLOCATED_BYTES
}
