#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 硬件 profile 的安全、原子持久化
#
# 调用方可能把 stealth_save_profile 放在 `if ! ...` 条件中；Bash 会在这种上下文
# 抑制函数体内的 errexit。因此这里对生成、短写、权限和 rename 的每一步都显式
# 检查，临时文件由 mktemp 在目标目录创建，既防可预测符号链接也保持原子替换。
# 本文件在 stealth-profile-io.sh 定义字段白名单后加载，不维护第二份字段表。
# ---------------------------------------------------------------------------

_stealth_write_profile_body() {
    local generated_at v

    generated_at="$(date -Iseconds)" || return 1
    printf '# stealth hardware profile — generated %s\n' "$generated_at" || return 1
    printf '# 删除此文件 (或运行 reroll-identity.sh) 重新随机化\n' || return 1
    for v in "${_STEALTH_PROFILE_VARS[@]}"; do
        [[ -v $v ]] || {
            echo "ERROR: 保存 profile 时缺少变量: $v" >&2
            return 1
        }
        printf '%s=%q\n' "$v" "${!v}" || return 1
    done
}

stealth_save_profile() {
    local path="$1" directory profile_name tmp

    directory="${path%/*}"
    [[ "$directory" != "$path" ]] || directory="."
    profile_name="${path##*/}"
    [[ -n "$profile_name" ]] || return 1
    mkdir -p -- "$directory" || return 1
    tmp="$(mktemp -- "$directory/.${profile_name}.tmp.XXXXXX")" || return 1
    if ! _stealth_write_profile_body >"$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    # profile 含 MAC/序列号，权限必须成功收紧；-T 防止异常目标目录吞掉临时文件。
    if ! chmod 0600 -- "$tmp" || ! mv -fT -- "$tmp" "$path"; then
        rm -f -- "$tmp"
        return 1
    fi
}
