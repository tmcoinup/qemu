#!/usr/bin/env bash
# QEMU CPU 预检测试替身：忽略 argv，只模拟最小 QMP stdout 与缺特性路径。
set -euo pipefail
cat >/dev/null
case "${VMATE_QEMU_STUB_MODE:-good}" in
    good)
        printf '%s\n' \
            '{"QMP":{"version":{"qemu":{"major":11}}}}' \
            '{"return":{},"id":"vmate-cap"}' \
            '{"return":{},"id":"vmate-quit"}'
        ;;
    warning)
        echo 'qemu: warning: host does not support requested feature'
        exit 1
        ;;
    silent)
        exit 0
        ;;
    *)
        echo "unknown stub mode" >&2
        exit 2
        ;;
esac
