#!/usr/bin/env bash
# shellcheck disable=SC2034 # 常量由 source 本库的启动器/离线工具消费。
# VMate qcow2 性能布局的单一事实源。
#
# 128 KiB cluster 配合 Extended L2 后，每个 subcluster 正好是 4 KiB：
#   128 KiB / 32 = 4 KiB
# 这既降低带 backing overlay 的小写入 COW 放大，又与 ext4/NTFS 常见块大小一致。
# Extended L2 的 L2 映射覆盖公式为 cache * cluster / 16；64 MiB L2 cache
# 因而覆盖 512 GiB。8 MiB refcount cache 在 16-bit refcount 下也覆盖 512 GiB。
# 当前全部启动盘精确小于 512 GiB，所以每个实例最多只需约 72 MiB 元数据缓存。
#
# lazy_refcounts 保持关闭：默认策略不能用宿主异常掉电后的全表重建换取写性能。
# discard-no-unref 保留 qcow2 cluster 映射，同时仍由 discard=unmap 向文件层打洞，
# 避免“释放映射 -> 文件尾重新分配”长期制造 qcow2 元数据碎片。

if [[ "${VMATE_QCOW2_PERFORMANCE_LOADED:-0}" == 1 ]]; then
    return 0
fi
VMATE_QCOW2_PERFORMANCE_LOADED=1

readonly VMATE_QCOW2_CLUSTER_SIZE=131072
readonly VMATE_QCOW2_L2_CACHE_SIZE=67108864
readonly VMATE_QCOW2_REFCOUNT_CACHE_SIZE=8388608
readonly VMATE_QCOW2_CACHE_CLEAN_INTERVAL=0

readonly VMATE_QCOW2_CREATE_OPTIONS="compat=1.1,cluster_size=${VMATE_QCOW2_CLUSTER_SIZE},extended_l2=on,preallocation=metadata,lazy_refcounts=off"
readonly VMATE_QCOW2_RUNTIME_OPTIONS="l2-cache-size=${VMATE_QCOW2_L2_CACHE_SIZE},refcount-cache-size=${VMATE_QCOW2_REFCOUNT_CACHE_SIZE},cache-clean-interval=${VMATE_QCOW2_CACHE_CLEAN_INTERVAL},discard-no-unref=on"

vmate_qcow2_l2_coverage_bytes() {
    printf '%s\n' "$((
        VMATE_QCOW2_L2_CACHE_SIZE * VMATE_QCOW2_CLUSTER_SIZE / 16
    ))"
}

vmate_qcow2_refcount_coverage_bytes() {
    printf '%s\n' "$((
        VMATE_QCOW2_REFCOUNT_CACHE_SIZE * VMATE_QCOW2_CLUSTER_SIZE * 8 / 16
    ))"
}
