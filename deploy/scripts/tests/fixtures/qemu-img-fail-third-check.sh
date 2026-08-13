#!/usr/bin/env bash
# 故障注入：第三次 check 对应优化盘发布后的完整性复检。
set -euo pipefail

: "${VMATE_REAL_QEMU_IMG:?缺少真实 qemu-img 路径}"
: "${VMATE_QEMU_IMG_CHECK_STATE:?缺少 check 计数文件}"

if [[ "${1:-}" == "check" ]]; then
    check_count=0
    if [[ -f "$VMATE_QEMU_IMG_CHECK_STATE" ]]; then
        read -r check_count <"$VMATE_QEMU_IMG_CHECK_STATE"
    fi
    ((check_count += 1))
    printf '%s\n' "$check_count" >"$VMATE_QEMU_IMG_CHECK_STATE"
    if (( check_count == 3 )); then
        echo "injected post-publish check failure" >&2
        exit 86
    fi
fi

exec "$VMATE_REAL_QEMU_IMG" "$@"
