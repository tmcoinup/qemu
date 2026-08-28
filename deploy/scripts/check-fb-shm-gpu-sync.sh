#!/usr/bin/env bash
# Read-only fb-shm synchronized GPU preview audit.
# This wrapper never connects to QMP/fb-shm, changes a VM, or writes host state.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
static_test="$repo_root/deploy/tests/qemu/test_fb_shm_gpu_sync_static.sh"
default_qemu="$repo_root/build/qemu-system-x86_64"

readonly READ_ONLY_CONTRACT="source,binary,proc,unix-socket-metadata"
failures=0

usage() {
    cat <<'EOF'
用法：
  ./deploy/scripts/check-fb-shm-gpu-sync.sh source
  ./deploy/scripts/check-fb-shm-gpu-sync.sh binary [QEMU二进制]
  ./deploy/scripts/check-fb-shm-gpu-sync.sh runtime VM编号
  ./deploy/scripts/check-fb-shm-gpu-sync.sh all VM编号 [QEMU二进制]

说明：
  source   运行 fb-shm GPU-sync 静态源码合同测试。
  binary   只读核对指定 QEMU；默认使用 build/qemu-system-x86_64。
  runtime  只读核对运行中 vmN 的 QEMU 映像、preview 参数和 Unix socket。
  all      依次完成以上三项。

本工具不会连接 QMP 或 fb-shm 控制 socket，不会启动、停止、暂停或重启 VM，
不会修改 BCD/安全设置，也不会安装驱动。它不能证明画面像素正在变化；动态验收
请按 deploy/docs/G11-FB-SHM-GPU-SYNC.md 操作。
EOF
}

pass() {
    printf '[fb-shm-sync] OK: %s\n' "$*"
}

fail() {
    printf '[fb-shm-sync] FAIL: %s\n' "$*" >&2
    failures=$((failures + 1))
}

binary_has() {
    local binary=$1 needle=$2

    [[ -r "$binary" ]] && LC_ALL=C grep -aFqm1 -- "$needle" "$binary"
}

audit_source() {
    if [[ ! -f "$static_test" ]]; then
        fail "缺少静态测试：${static_test#"$repo_root"/}"
        return
    fi
    if bash "$static_test"; then
        pass "源码合同通过"
    else
        fail "源码合同失败"
    fi
}

audit_binary() {
    local binary=${1:-$default_qemu}
    local object_help

    if [[ ! -x "$binary" ]]; then
        fail "QEMU 不存在或不可执行：$binary"
        printf '[fb-shm-sync] 提示：先增量构建；本工具不会替你构建或重启 VM。\n' >&2
        return
    fi

    object_help=$("$binary" -object fb-shm,help 2>&1 || true)
    if grep -Fq 'fb-shm options:' <<<"$object_help"; then
        pass "二进制包含 fb-shm object"
    else
        fail "二进制不包含 fb-shm object"
    fi

    if binary_has "$binary" \
            'synchronized GPU preview requires EGL_ANDROID_native_fence_sync'; then
        pass "二进制包含 acquire-fence 安全拒绝路径"
    else
        fail "二进制缺少 GPU_SYNC acquire-fence 合同；可能尚未重编"
    fi
    if binary_has "$binary" 'lease expired; dropping stalled consumer'; then
        pass "二进制包含单帧 lease 超时退役路径"
    else
        fail "二进制缺少 pending-frame lease 保护；可能尚未重编"
    fi
}

load_cmdline() {
    local pid=$1
    local -n out=$2

    out=()
    [[ -r "/proc/$pid/cmdline" ]] || return 1
    mapfile -d '' -t out <"/proc/$pid/cmdline"
    ((${#out[@]} > 0))
}

is_vm_name() {
    local value=$1 vm_id=$2

    [[ "$value" == "vm$vm_id" || "$value" == "vm$vm_id,"* ]]
}

find_vm_pids() {
    local vm_id=$1 proc pid index
    local -a argv=()

    for proc in /proc/[0-9]*; do
        pid=${proc##*/}
        load_cmdline "$pid" argv || continue
        [[ "${argv[0]##*/}" == qemu-system-* ]] || continue
        for ((index = 0; index + 1 < ${#argv[@]}; index++)); do
            if [[ "${argv[index]}" == -name ]] &&
                    is_vm_name "${argv[index + 1]}" "$vm_id"; then
                printf '%s\n' "$pid"
                break
            fi
        done
    done
}

preview_object_from_argv() {
    local vm_id=$1
    shift
    local index candidate expected="fb-shm,id=dgame-preview-vm${vm_id}"
    local -a argv=("$@")

    for ((index = 0; index + 1 < ${#argv[@]}; index++)); do
        [[ "${argv[index]}" == -object ]] || continue
        candidate=${argv[index + 1]}
        if [[ "$candidate" == "$expected" || "$candidate" == "$expected,"* ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

object_path() {
    local object=$1 field
    local -a fields=()

    IFS=',' read -r -a fields <<<"$object"
    for field in "${fields[@]}"; do
        if [[ "$field" == path=* ]]; then
            printf '%s\n' "${field#path=}"
            return 0
        fi
    done
    return 1
}

audit_runtime() {
    local vm_id=$1 pid exe preview socket_path
    local -a pids=() argv=()

    if [[ ! "$vm_id" =~ ^[1-9][0-9]*$ ]]; then
        printf '[fb-shm-sync] VM 编号必须是正整数：%s\n' "$vm_id" >&2
        exit 2
    fi

    mapfile -t pids < <(find_vm_pids "$vm_id")
    if ((${#pids[@]} == 0)); then
        fail "没有找到精确名称为 vm${vm_id} 的运行中 QEMU"
        return
    fi
    if ((${#pids[@]} != 1)); then
        fail "找到多个 vm${vm_id} QEMU PID：${pids[*]}"
        return
    fi
    pid=${pids[0]}
    if ! load_cmdline "$pid" argv; then
        fail "无权读取 /proc/$pid/cmdline"
        return
    fi

    exe=$(readlink -- "/proc/$pid/exe" 2>/dev/null || true)
    if [[ -z "$exe" ]]; then
        fail "无权读取 /proc/$pid/exe"
    elif [[ "$exe" == *' (deleted)' ]]; then
        fail "运行中 QEMU 映像已被替换：$exe；需由操作员完整关机后再启动"
    else
        pass "vm${vm_id} PID=$pid exe=$exe"
    fi

    if ! preview=$(preview_object_from_argv "$vm_id" "${argv[@]}"); then
        fail "vm${vm_id} 未携带 dgame-preview-vm${vm_id} fb-shm object"
        return
    fi
    if ! socket_path=$(object_path "$preview"); then
        fail "preview object 缺少显式 path"
        return
    fi
    if [[ "$socket_path" != /* ]]; then
        fail "preview socket 不是绝对路径：$socket_path"
    elif [[ -L "$socket_path" ]]; then
        fail "preview canonical socket 不应是符号链接：$socket_path"
    elif [[ ! -S "$socket_path" ]]; then
        fail "preview Unix socket 不存在：$socket_path"
    else
        pass "preview endpoint=$socket_path（只检查文件类型，未连接）"
    fi

    if [[ -n "$exe" && "$exe" != *' (deleted)' ]]; then
        if binary_has "/proc/$pid/exe" \
                'synchronized GPU preview requires EGL_ANDROID_native_fence_sync' &&
                binary_has "/proc/$pid/exe" \
                'lease expired; dropping stalled consumer'; then
            pass "运行中映像包含 GPU_SYNC/fence/lease 合同"
        else
            fail "运行中映像缺少新合同；构建新 QEMU 不会热替换旧进程"
        fi
    fi
}

command_name=${1:---help}
case "$command_name" in
    source)
        (($# == 1)) || { usage >&2; exit 2; }
        audit_source
        ;;
    binary)
        (($# <= 2)) || { usage >&2; exit 2; }
        audit_binary "${2:-$default_qemu}"
        ;;
    runtime)
        (($# == 2)) || { usage >&2; exit 2; }
        audit_runtime "$2"
        ;;
    all)
        (($# == 2 || $# == 3)) || { usage >&2; exit 2; }
        audit_source
        audit_binary "${3:-$default_qemu}"
        audit_runtime "$2"
        ;;
    -h|--help|help)
        usage
        exit 0
        ;;
    *)
        printf '[fb-shm-sync] 未知命令：%s\n' "$command_name" >&2
        usage >&2
        exit 2
        ;;
esac

printf '[fb-shm-sync] READ_ONLY=%s\n' "$READ_ONLY_CONTRACT"
if ((failures)); then
    printf '[fb-shm-sync] RESULT=not-ready failures=%d\n' "$failures" >&2
    exit 1
fi
printf '[fb-shm-sync] RESULT=ready\n'
