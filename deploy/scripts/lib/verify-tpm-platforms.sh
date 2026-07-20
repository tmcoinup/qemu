#!/usr/bin/env bash
# 对共享平台目录与 QEMU TPM 后端做无客体启动的动态核验。

_VERIFY_TPM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=stealth-platforms.sh
# shellcheck disable=SC1091
source "$_VERIFY_TPM_LIB_DIR/stealth-platforms.sh"

verify_tpm_platforms() {
    local qemu="$1"
    local tpm_help device_help row platform_id enabled allow tuple
    local version frontend implementation
    local -A required_frontends=()

    stealth_platform_validate >/dev/null || {
        echo "FAIL: TPM 平台目录校验失败" >&2
        return 1
    }

    if command -v swtpm >/dev/null 2>&1 \
        && command -v swtpm_setup >/dev/null 2>&1; then
        echo "  swtpm        = $(swtpm --version | head -1)"
        echo "  swtpm_setup  = $(command -v swtpm_setup)"
    else
        echo "WARN: swtpm/swtpm_setup 未完整安装；严格启动会拒绝平台声明的 TPM" >&2
    fi

    # QEMU help 子命令通常以 1 退出，必须先捕获文本再判断能力。
    tpm_help="$("$qemu" -tpmdev help 2>&1 || true)"
    if ! grep -qi 'emulator' <<<"$tpm_help"; then
        echo "FAIL: QEMU 没编 CONFIG_TPM_EMULATOR" >&2
        return 1
    fi
    device_help="$("$qemu" -device help 2>&1 || true)"

    while IFS= read -r row; do
        IFS='|' read -r platform_id enabled _ <<<"$row"
        [[ "$enabled" == true ]] && allow=0 || allow=1
        tuple="$(
            if ! STRICT_HARDWARE=1 ALLOW_PLATFORM_COMPATIBILITY="$allow" \
                stealth_platform_load "$platform_id" >/dev/null 2>&1; then
                exit 1
            fi
            printf '%s|%s|%s\n' \
                "$TPM_VERSION" "$TPM_FRONTEND" "$TPM_IMPLEMENTATION"
        )" || {
            echo "FAIL: 无法读取平台 TPM 事实: $platform_id" >&2
            return 1
        }
        IFS='|' read -r version frontend implementation <<<"$tuple"
        if [[ "$frontend" != none ]]; then
            required_frontends["$frontend"]=1
        fi
        printf '  %-56s %s / %s / %s\n' \
            "$platform_id" "$implementation" "$version" "$frontend"
    done < <(stealth_platform_index)

    for frontend in "${!required_frontends[@]}"; do
        if ! grep -Fq "name \"$frontend\"" <<<"$device_help"; then
            echo "FAIL: 平台需要 $frontend，但当前 QEMU 未注册该设备" >&2
            return 1
        fi
    done
    echo "  -tpmdev emulator 与目录所需 TPM 前端均可用"
}
