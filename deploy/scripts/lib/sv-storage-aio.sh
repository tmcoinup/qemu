# shellcheck shell=bash
# 在任何 profile/磁盘/TPM/host tune 副作用前选择宿主文件 AIO 后端。
# 该值只进入 host BlockBackend，不写入硬件 profile，也不改变 guest 控制器身份。

: "${QEMU_DISK_AIO:=auto}"

sv_storage_aio_probe() {
    local mode="$1"
    local probe="${QEMU_AIO_PROBE:-$HERE/lib/qemu-aio-probe.py}"

    [[ -f "$probe" ]] || {
        echo "ERROR: 缺少 QEMU AIO active-read probe: $probe" >&2
        return 1
    }
    python3 "$probe" "$QEMU" "$mode" --quiet
}

sv_storage_select_aio() {
    case "$QEMU_DISK_AIO" in
        threads)
            QEMU_DISK_AIO_SELECTED=threads
            ;;
        native|io_uring)
            if ! sv_storage_aio_probe "$QEMU_DISK_AIO"; then
                echo "ERROR: 显式 QEMU_DISK_AIO=$QEMU_DISK_AIO 未通过实际 O_DIRECT 读取" >&2
                return 1
            fi
            QEMU_DISK_AIO_SELECTED="$QEMU_DISK_AIO"
            ;;
        auto)
            # QEMU_CAP_CHECK=0 常用于没有真实 QEMU 的 argv fixture；此时保持历史
            # threads，不能让性能探测破坏非生产调试入口。
            if [[ "${QEMU_CAP_CHECK:-1}" != 1 ]]; then
                QEMU_DISK_AIO_SELECTED=threads
            elif sv_storage_aio_probe io_uring; then
                QEMU_DISK_AIO_SELECTED=io_uring
            elif sv_storage_aio_probe native; then
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
    echo ">> disk aio:    $QEMU_DISK_AIO_SELECTED (policy=$QEMU_DISK_AIO)"
}

sv_storage_select_aio || exit $?
