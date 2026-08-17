# shellcheck shell=bash
# 在磁盘、TPM、mdev 等资源副作用前选择宿主文件 AIO 后端。
# 该值只进入 host BlockBackend，不改变 guest 控制器或硬件身份。

G11_STORAGE_AIO_LIB_DIR="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P
)"

g11_storage_aio_probe() {
    local mode=$1
    local probe=${QEMU_AIO_PROBE:-$G11_STORAGE_AIO_LIB_DIR/qemu-aio-probe.py}

    [[ -f "$probe" ]] || {
        echo "ERROR: 缺少 QEMU AIO active-read probe: $probe" >&2
        return 1
    }
    python3 "$probe" "$QEMU_BIN" "$mode" --quiet
}

g11_storage_select_aio() {
    local policy=${QEMU_DISK_AIO:-auto}

    case "$policy" in
        threads)
            QEMU_DISK_AIO_SELECTED=threads
            ;;
        native|io_uring)
            if ! g11_storage_aio_probe "$policy"; then
                echo "ERROR: 显式 QEMU_DISK_AIO=$policy 未通过实际 O_DIRECT 读取" >&2
                return 1
            fi
            QEMU_DISK_AIO_SELECTED=$policy
            ;;
        auto)
            # dry-run 没有资格代表当前宿主探测结果，使用始终可用的保守后端。
            # 真实启动仍严格按 io_uring -> native -> threads 顺序 active-read。
            if [[ "${DRY_RUN:-0}" == 1 || "${QEMU_CAP_CHECK:-1}" != 1 ]]; then
                QEMU_DISK_AIO_SELECTED=threads
            elif g11_storage_aio_probe io_uring; then
                QEMU_DISK_AIO_SELECTED=io_uring
            elif g11_storage_aio_probe native; then
                QEMU_DISK_AIO_SELECTED=native
            else
                QEMU_DISK_AIO_SELECTED=threads
            fi
            ;;
        *)
            echo "ERROR: QEMU_DISK_AIO 只支持 auto、io_uring、native 或 threads" >&2
            return 2
            ;;
    esac
    export QEMU_DISK_AIO_SELECTED
    echo ">> disk aio:    $QEMU_DISK_AIO_SELECTED (policy=$policy)"
}
