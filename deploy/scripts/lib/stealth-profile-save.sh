#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 硬件 profile 的安全、原子持久化
#
# 调用方可能把 stealth_save_profile 放在 `if ! ...` 条件中；Bash 会在这种上下文
# 抑制函数体内的 errexit。因此这里对生成、短写、权限和 rename 的每一步都显式
# 检查，临时文件由 mktemp 在目标目录创建，既防可预测符号链接也保持原子替换。
# 本文件在 stealth-profile-io.sh 定义字段白名单后加载，不维护第二份字段表。
# ---------------------------------------------------------------------------

stealth_profile_sha256() {
    local path="$1" digest _

    [[ -f "$path" && ! -L "$path" ]] || return 1
    read -r digest _ < <(sha256sum -- "$path") || return 1
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$digest"
}

_stealth_profile_require_hash() {
    local path="$1" expected="$2" actual

    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
    actual="$(stealth_profile_sha256 "$path")" || return 1
    [[ "$actual" == "$expected" ]]
}

_stealth_write_profile_body() {
    local generated_at v

    generated_at="$(date -Iseconds)" || return 1
    printf '# stealth hardware profile — generated %s\n' "$generated_at" || return 1
    printf '# 不要删除此文件；使用 start-vm.sh <实例> --reroll 原子更新身份\n' || return 1
    for v in "${_STEALTH_PROFILE_VARS[@]}"; do
        [[ -v $v ]] || {
            echo "ERROR: 保存 profile 时缺少变量: $v" >&2
            return 1
        }
        printf '%s=%q\n' "$v" "${!v}" || return 1
    done
}

stealth_save_profile() {
    local path="$1" expected_hash="${2:-}"
    local directory profile_name tmp

    directory="${path%/*}"
    [[ "$directory" != "$path" ]] || directory="."
    profile_name="${path##*/}"
    [[ -n "$profile_name" && ! -L "$path" ]] || return 1
    if [[ -n "$expected_hash" ]]; then
        _stealth_profile_require_hash "$path" "$expected_hash" || return 1
    fi
    mkdir -p -- "$directory" || return 1
    tmp="$(mktemp -- "$directory/.${profile_name}.tmp.XXXXXX")" || return 1
    if ! _stealth_write_profile_body >"$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    # profile 在加载后的门禁阶段可能被手工编辑或被不遵守实例锁的进程替换。
    # rename 前再次比较原始摘要，避免用旧内存快照静默覆盖较新的磁盘内容。
    if ! chmod 0600 -- "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    if [[ -n "$expected_hash" ]] &&
       ! _stealth_profile_require_hash "$path" "$expected_hash"; then
        rm -f -- "$tmp"
        return 1
    fi
    # profile 含 MAC/序列号，权限必须成功收紧；-T 防止异常目标目录吞掉临时文件。
    if ! mv -fT -- "$tmp" "$path"; then
        rm -f -- "$tmp"
        return 1
    fi
}

stealth_backup_profile_for_migration() {
    local path="$1" expected_hash="${2:-${_STEALTH_LOADED_PROFILE_HASH:-}}"
    local backup="${path}.pre-catalog-migration.${expected_hash}"
    local directory profile_name tmp backup_hash backup_owner backup_mode

    _stealth_profile_require_hash "$path" "$expected_hash" || return 1
    if [[ -e "$backup" || -L "$backup" ]]; then
        [[ -f "$backup" && ! -L "$backup" ]] || return 1
        backup_hash="$(stealth_profile_sha256 "$backup")" || return 1
        backup_owner="$(stat -c '%u' -- "$backup")" || return 1
        backup_mode="$(stat -c '%a' -- "$backup")" || return 1
        [[ "$backup_hash" == "$expected_hash" &&
           "$backup_owner" == "$UID" &&
           "$backup_mode" == 400 ]] || return 1
        _stealth_profile_require_hash "$path" "$expected_hash" || return 1
        printf '%s\n' "$backup"
        return 0
    fi
    directory="${path%/*}"
    [[ "$directory" != "$path" ]] || directory="."
    profile_name="${path##*/}"
    tmp="$(mktemp -- "$directory/.${profile_name}.backup.XXXXXX")" ||
        return 1
    if ! cp --reflink=auto --preserve=mode,timestamps -- "$path" "$tmp" ||
       ! chmod 0400 -- "$tmp" ||
       ! _stealth_profile_require_hash "$tmp" "$expected_hash" ||
       ! _stealth_profile_require_hash "$path" "$expected_hash" ||
       ! mv -nT -- "$tmp" "$backup"; then
        rm -f -- "$tmp"
        return 1
    fi
    # GNU mv -n 在目标竞态出现时也返回成功；此时保留先到达的完整备份。
    if [[ -e "$tmp" ]]; then
        rm -f -- "$tmp"
        [[ -f "$backup" && ! -L "$backup" ]] || return 1
    fi
    backup_hash="$(stealth_profile_sha256 "$backup")" || return 1
    backup_owner="$(stat -c '%u' -- "$backup")" || return 1
    backup_mode="$(stat -c '%a' -- "$backup")" || return 1
    [[ "$backup_hash" == "$expected_hash" &&
       "$backup_owner" == "$UID" &&
       "$backup_mode" == 400 ]] || return 1
    _stealth_profile_require_hash "$path" "$expected_hash" || return 1
    printf '%s\n' "$backup"
}
