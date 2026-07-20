#!/usr/bin/env bash
# TPM 平台字段的 profile 兼容迁移。
#
# 2026-07-19 以前的 schema-1 profile 已经绑定 PLATFORM_ID，但尚未持久化 TPM
# 能力。直接要求新字段会让已有 VM 无法启动；使用固定默认值又会继续制造
# “主板与 TPM 无关”的旧问题。因此仅在六个字段全部缺失时，从同一个、已经严格
# 校验过的 manifest 平台重新读取规范值。部分缺失视为截断或篡改，必须拒绝。
#
# schema-0 profile 没有可信平台 ID，只能为无既有 state 的显式非严格诊断保留
# 升级前语义：TPM 2.0 + CRB。这不会把 legacy 身份提升为受支持平台；若已经有
# 未绑定 state，运行时因无法证明原主板而拒绝自动接管，必须新建 instance 或走
# 经过验证的迁移流程。

_STEALTH_TPM_PROFILE_VARS=(
    TPM_CAPABILITY
    TPM_SUPPORTED
    TPM_IMPLEMENTATION
    TPM_VERSION
    TPM_FRONTEND
    TPM_PCR_BANKS
)

_stealth_manifest_tpm_tuple() (
    local platform_id="$1"

    stealth_platform_load "$platform_id" >/dev/null || return 1
    printf '%s|%s|%s|%s|%s|%s\n' \
        "$TPM_CAPABILITY" "$TPM_SUPPORTED" "$TPM_IMPLEMENTATION" \
        "$TPM_VERSION" "$TPM_FRONTEND" "$TPM_PCR_BANKS"
)

stealth_fill_profile_tpm_facts() {
    local present_array_name="$1"
    local -n present_keys="$present_array_name"
    local field present_count=0 tuple

    for field in "${_STEALTH_TPM_PROFILE_VARS[@]}"; do
        [[ -n "${present_keys[$field]:-}" ]] && ((present_count += 1))
    done

    if [[ "${PLATFORM_SCHEMA_VERSION:-0}" == "1" ]]; then
        if (( present_count != 0 && present_count != ${#_STEALTH_TPM_PROFILE_VARS[@]} )); then
            echo "ERROR: schema-1 profile 的 TPM 平台字段不完整" >&2
            return 1
        fi
        if (( present_count == 0 )); then
            tuple="$(_stealth_manifest_tpm_tuple "${PLATFORM_ID:-}")" || {
                echo "ERROR: 无法从平台清单补齐旧 profile 的 TPM 事实" >&2
                return 1
            }
            IFS='|' read -r \
                TPM_CAPABILITY TPM_SUPPORTED TPM_IMPLEMENTATION \
                TPM_VERSION TPM_FRONTEND TPM_PCR_BANKS <<<"$tuple"
            for field in "${_STEALTH_TPM_PROFILE_VARS[@]}"; do
                present_keys["$field"]=1
            done
            echo ">> profile:     从 PLATFORM_ID 补齐旧版 TPM 平台字段" >&2
        fi
        return 0
    fi

    : "${TPM_CAPABILITY:=firmware}"
    : "${TPM_SUPPORTED:=1}"
    if [[ "${CPU_VENDOR:-AuthenticAMD}" == "GenuineIntel" ]]; then
        : "${TPM_IMPLEMENTATION:=intel-ptt}"
    else
        : "${TPM_IMPLEMENTATION:=amd-ftpm}"
    fi
    : "${TPM_VERSION:=2.0}"
    : "${TPM_FRONTEND:=tpm-crb}"
    : "${TPM_PCR_BANKS:=sha256}"
}
