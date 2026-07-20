#!/usr/bin/env bash
# 将持久化 swtpm state 与平台身份、TPM 版本及前端绑定。
#
# TPM state 可能保存 BitLocker、Windows Hello 和其它密钥。平台 reroll 或版本切换
# 时绝不能把旧 state 原地覆盖成另一种 TPM；否则 profile 原子提交失败后会留下
# “旧主板 + 新 TPM”的不可恢复组合。本模块只做两件事：
#   1. 新 state 写入私有、原子的绑定元数据；
#   2. 绑定不一致时 fail closed，保留原 state 内容原样不动。
#
# 旧版启动器只可能创建 TPM 2.0 + CRB，因此允许这唯一组合在第一次升级启动时
# 补写元数据，不重建 permall，也不改变客体内已有密钥；只会把历史宽松 mode
# 收紧到 0600。

_sv_tpm_binding_content() {
    local platform_id="$1"
    local capability="$2"
    local implementation="$3"
    local version="$4"
    local frontend="$5"
    local pcr_banks="$6"

    printf 'schema=1\n'
    printf 'platform_id=%s\n' "$platform_id"
    printf 'capability=%s\n' "$capability"
    printf 'implementation=%s\n' "$implementation"
    printf 'version=%s\n' "$version"
    printf 'frontend=%s\n' "$frontend"
    printf 'pcr_banks=%s\n' "$pcr_banks"
}

_sv_tpm_binding_values_valid() {
    local platform_id="$1"
    local capability="$2"
    local implementation="$3"
    local version="$4"
    local frontend="$5"
    local pcr_banks="$6"

    [[ "$platform_id" =~ ^[a-z0-9][a-z0-9-]{7,95}$ ]] || return 1
    [[ "$capability" == firmware || "$capability" == discrete ]] || return 1
    [[ "$implementation" == intel-ptt || "$implementation" == amd-ftpm ||
       "$implementation" == discrete-module ]] || return 1
    case "$version:$frontend:$pcr_banks" in
        1.2:tpm-tis:sha1) ;;
        2.0:tpm-tis:sha1|2.0:tpm-tis:sha256|\
        2.0:tpm-tis:sha1,sha256|2.0:tpm-tis:sha256,sha1|\
        2.0:tpm-crb:sha1|2.0:tpm-crb:sha256|\
        2.0:tpm-crb:sha1,sha256|2.0:tpm-crb:sha256,sha1) ;;
        *) return 1 ;;
    esac
}

sv_tpm_bind_state() {
    local state_dir="$1"
    local state_file="$2"
    local platform_id="$3"
    local capability="$4"
    local implementation="$5"
    local version="$6"
    local frontend="$7"
    local pcr_banks="$8"
    local legacy_platform_id="${9:-}"
    local canonical_state binding_file expected actual tmp
    local state_owner state_mode state_links binding_links binding_matches=0

    _sv_tpm_binding_values_valid \
        "$platform_id" "$capability" "$implementation" \
        "$version" "$frontend" "$pcr_banks" || {
        echo "ERROR: 拒绝为非法 TPM 平台组合写入 state 绑定" >&2
        return 1
    }

    canonical_state="$(sv_swtpm_canonical_state_dir "$state_dir")" || return 1
    [[ "$state_file" == "$canonical_state/"* && "${state_file%/*}" == "$canonical_state" ]] \
        || {
        echo "ERROR: TPM state 文件不在已校验的私有目录内: $state_file" >&2
        return 1
    }
    case "$version:${state_file##*/}" in
        1.2:tpm-00.permall|2.0:tpm2-00.permall) ;;
        *)
            echo "ERROR: TPM 版本与 state 文件名不一致: $version/$state_file" >&2
            return 1
            ;;
    esac
    if [[ -L "$state_file" || ( -e "$state_file" && ! -f "$state_file" ) ]]; then
        echo "ERROR: TPM state 必须是目录内的普通文件且不能是符号链接: $state_file" >&2
        return 1
    fi
    if [[ -e "$state_file" ]]; then
        state_owner="$(stat -c '%u' -- "$state_file" 2>/dev/null)" || return 1
        state_mode="$(stat -c '%a' -- "$state_file" 2>/dev/null)" || return 1
        state_links="$(stat -c '%h' -- "$state_file" 2>/dev/null)" || return 1
        if [[ "$state_owner" != "$UID" || "$state_links" != 1 ]]; then
            echo "ERROR: TPM state owner/link count 不安全: $state_file" >&2
            return 1
        fi
    fi
    binding_file="$canonical_state/platform-binding"
    expected="$(_sv_tpm_binding_content \
        "$platform_id" "$capability" "$implementation" \
        "$version" "$frontend" "$pcr_banks")"

    if [[ -e "$binding_file" || -L "$binding_file" ]]; then
        [[ -f "$binding_file" && ! -L "$binding_file" ]] || {
            echo "ERROR: TPM state 绑定不是普通文件: $binding_file" >&2
            return 1
        }
        binding_links="$(stat -c '%h' -- "$binding_file" 2>/dev/null)" || return 1
        [[ "$(stat -c '%u' -- "$binding_file" 2>/dev/null)" == "$UID" &&
           "$(stat -c '%a' -- "$binding_file" 2>/dev/null)" == 600 &&
           "$binding_links" == 1 ]] || {
            echo "ERROR: TPM state 绑定 owner/mode 不安全: $binding_file" >&2
            return 1
        }
        actual="$(<"$binding_file")"
        if [[ "$actual" != "$expected" ]]; then
            echo "ERROR: TPM state 与当前平台/版本不一致，拒绝覆盖已有密钥" >&2
            echo "       state=$canonical_state" >&2
            echo "       expected platform=$platform_id version=$version frontend=$frontend" >&2
            return 1
        fi
        binding_matches=1
    fi

    # 没有绑定但已有 state 是升级场景。旧实现只有这一种固定组合，其他组合
    # 不能推测来源；保留文件并要求显式迁移。
    if (( ! binding_matches )) && [[ -e "$state_file" ]]; then
        if [[ "$version" != 2.0 || "$frontend" != tpm-crb ]]; then
            echo "ERROR: 未绑定的既有 TPM state 不能推断为 $version/$frontend" >&2
            return 1
        fi
        if [[ -z "$legacy_platform_id" || "$legacy_platform_id" != "$platform_id" ]]; then
            echo "ERROR: 未绑定的旧 TPM state 与当前随机平台缺少一致身份依据，拒绝接管" >&2
            echo "       old=${legacy_platform_id:-unknown} current=$platform_id" >&2
            return 1
        fi
    fi

    # 历史 swtpm 可能在 0700 目录中生成 0640 文件。身份检查全部通过后才
    # 收紧 mode，不改 state 内容；后续备份/迁移也不会因离开原目录而暴露密钥。
    if [[ -e "$state_file" && "$state_mode" != 600 ]]; then
        chmod 0600 -- "$state_file" || {
            echo "ERROR: 无法收紧 TPM state 权限: $state_file" >&2
            return 1
        }
    fi
    (( binding_matches )) && return 0

    tmp="$(mktemp -- "$canonical_state/.platform-binding.tmp.XXXXXX")" || return 1
    if ! _sv_tpm_binding_content \
        "$platform_id" "$capability" "$implementation" \
        "$version" "$frontend" "$pcr_banks" >"$tmp" ||
       ! chmod 0600 -- "$tmp" ||
       ! mv -fT -- "$tmp" "$binding_file"; then
        rm -f -- "$tmp"
        return 1
    fi
}
