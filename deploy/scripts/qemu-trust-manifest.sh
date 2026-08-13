#!/bin/bash
# shellcheck shell=bash
# ---------------------------------------------------------------------------
# QEMU executable 精确信任清单 ABI。
#
# manifest 由若干个连续四行记录组成，旧版单记录文件天然是本格式的子集：
#   path=/canonical/qemu-system-x86_64
#   sha256=<64 个小写十六进制字符>
#   device=<十进制 st_dev>
#   inode=<十进制 st_ino>
#
# 记录之间不允许空行，字段顺序固定，重复路径和超过上限的记录一律拒绝。调用者仍须
# 根据自己的权限域传入预期 owner/mode；本库负责安全打开、格式解析、精确身份校验及
# 同目录原子重写。安装副本由 host-cpu-isolate 以 root-owned ABI 库方式加载。
# ---------------------------------------------------------------------------

# 由安装器和 root helper 同时核对，升级格式时必须同步提升 ABI 路径与版本。
# shellcheck disable=SC2034
readonly VMATE_QEMU_TRUST_ABI="1"
readonly VMATE_QEMU_TRUST_MAX_RECORDS=16
readonly VMATE_QEMU_TRUST_MAX_BYTES=131072

declare -ag QEMU_TRUST_PATHS=()
declare -ag QEMU_TRUST_SHA256S=()
declare -ag QEMU_TRUST_DEVICES=()
declare -ag QEMU_TRUST_INODES=()
QEMU_TRUST_ERROR=""
QEMU_TRUST_MATCH_INDEX=""
QEMU_TRUST_REMOVED=0

_qemu_trust_error() {
    QEMU_TRUST_ERROR="$*"
    return 1
}

qemu_trust_manifest_reset() {
    QEMU_TRUST_PATHS=()
    QEMU_TRUST_SHA256S=()
    QEMU_TRUST_DEVICES=()
    QEMU_TRUST_INODES=()
    QEMU_TRUST_ERROR=""
    QEMU_TRUST_MATCH_INDEX=""
    QEMU_TRUST_REMOVED=0
}

qemu_trust_manifest_count() {
    printf '%s\n' "${#QEMU_TRUST_PATHS[@]}"
}

qemu_trust_path_is_canonical() {
    local path="$1" LC_ALL=C
    [[ "$path" == /* && -n "$path" && ${#path} -le 4096 &&
       "$path" != *$'\r'* && "$path" != *$'\n'* &&
       ( "$path" == "/" || ( "$path" != */ && "$path" != *//* &&
         "$path" != */./* && "$path" != */. && "$path" != */../* &&
         "$path" != */.. ) ) ]]
}

qemu_trust_is_u64_decimal() {
    local value="$1" maximum=18446744073709551615 index digit limit_digit
    [[ "$value" =~ ^(0|[1-9][0-9]*)$ && ${#value} -le ${#maximum} ]] || return 1
    (( ${#value} < ${#maximum} )) && return 0
    for (( index=0; index<${#maximum}; index++ )); do
        digit="${value:index:1}"
        limit_digit="${maximum:index:1}"
        (( 10#$digit < 10#$limit_digit )) && return 0
        (( 10#$digit > 10#$limit_digit )) && return 1
    done
    return 0
}

# GNU sha256sum 会在文件名含反斜杠时给整行增加转义标记；摘要本身仍是随后连续
# 64 位十六进制。统一在这里提取，避免 installer 与 runtime 对同一文件产生歧义。
qemu_trust_file_sha256() {
    local output digest
    output="$(sha256sum -- "$1" 2>/dev/null)" || return 1
    digest="${output%% *}"
    digest="${digest#\\}"
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$digest"
}

qemu_trust_manifest_append() {
    local path="$1" sha256="$2" device="$3" inode="$4" old
    local LC_ALL=C

    qemu_trust_path_is_canonical "$path" || {
        _qemu_trust_error "path 不是 canonical absolute path: $path"
        return 1
    }
    [[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || {
        _qemu_trust_error "sha256 格式非法"
        return 1
    }
    qemu_trust_is_u64_decimal "$device" &&
        qemu_trust_is_u64_decimal "$inode" || {
        _qemu_trust_error "device/inode 必须是十进制整数"
        return 1
    }
    for old in "${QEMU_TRUST_PATHS[@]}"; do
        [[ "$old" != "$path" ]] || {
            _qemu_trust_error "manifest 含重复 path: $path"
            return 1
        }
    done
    (( ${#QEMU_TRUST_PATHS[@]} < VMATE_QEMU_TRUST_MAX_RECORDS )) || {
        _qemu_trust_error "manifest 记录超过上限 $VMATE_QEMU_TRUST_MAX_RECORDS"
        return 1
    }
    QEMU_TRUST_PATHS+=("$path")
    QEMU_TRUST_SHA256S+=("$sha256")
    QEMU_TRUST_DEVICES+=("$device")
    QEMU_TRUST_INODES+=("$inode")
}

qemu_trust_manifest_parse_file() {
    local manifest="$1" size line value path="" sha256="" device="" state=0

    qemu_trust_manifest_reset
    [[ -r "$manifest" ]] || {
        _qemu_trust_error "manifest 不可读: $manifest"
        return 1
    }
    size="$(stat -Lc '%s' -- "$manifest" 2>/dev/null)" || {
        _qemu_trust_error "无法读取 manifest 大小"
        return 1
    }
    [[ "$size" =~ ^[0-9]+$ ]] && (( size <= VMATE_QEMU_TRUST_MAX_BYTES )) || {
        _qemu_trust_error "manifest 超过大小上限 $VMATE_QEMU_TRUST_MAX_BYTES"
        return 1
    }

    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$state" in
            0)
                [[ "$line" == path=* ]] || {
                    _qemu_trust_error "记录必须以 path= 开始且不得含空行"
                    return 1
                }
                path="${line#path=}"
                state=1
                ;;
            1)
                [[ "$line" == sha256=* ]] || {
                    _qemu_trust_error "path 后必须紧跟 sha256"
                    return 1
                }
                sha256="${line#sha256=}"
                state=2
                ;;
            2)
                [[ "$line" == device=* ]] || {
                    _qemu_trust_error "sha256 后必须紧跟 device"
                    return 1
                }
                device="${line#device=}"
                state=3
                ;;
            3)
                [[ "$line" == inode=* ]] || {
                    _qemu_trust_error "device 后必须紧跟 inode"
                    return 1
                }
                value="${line#inode=}"
                qemu_trust_manifest_append "$path" "$sha256" "$device" "$value" \
                    || return 1
                state=0
                ;;
        esac
    done < "$manifest"
    (( state == 0 )) || {
        _qemu_trust_error "manifest 末尾记录不完整"
        return 1
    }
}

# 先验证路径对象，再打开并核对 fd 的 device:inode，解析期间始终读取同一个 inode。
qemu_trust_manifest_load_checked() {
    local manifest="$1" owner="$2" group="$3" mode="$4"
    local metadata path_inode fd_inode manifest_fd status=0

    [[ -f "$manifest" && ! -L "$manifest" ]] || {
        _qemu_trust_error "manifest 不是非符号链接普通文件: $manifest"
        return 1
    }
    metadata="$(stat -Lc '%u:%g:%a:%h' -- "$manifest" 2>/dev/null)" || {
        _qemu_trust_error "无法读取 manifest 元数据"
        return 1
    }
    [[ "$metadata" == "$owner:$group:$mode:1" ]] || {
        _qemu_trust_error "manifest owner/mode/link 非法: $metadata"
        return 1
    }
    path_inode="$(stat -Lc '%d:%i' -- "$manifest" 2>/dev/null)" || return 1
    exec {manifest_fd}< "$manifest" || {
        _qemu_trust_error "无法安全打开 manifest"
        return 1
    }
    fd_inode="$(stat -Lc '%d:%i' -- "/proc/$$/fd/$manifest_fd" 2>/dev/null)" \
        || status=1
    if (( status == 0 )) && [[ "$path_inode" != "$fd_inode" ]]; then
        _qemu_trust_error "manifest 在打开期间被替换"
        status=1
    fi
    if (( status == 0 )); then
        qemu_trust_manifest_parse_file "/proc/$$/fd/$manifest_fd" || status=1
    fi
    exec {manifest_fd}<&-
    (( status == 0 ))
}

qemu_trust_record_values_are_live() {
    local path="$1" sha256="$2" device="$3" inode="$4"
    local metadata digest canonical

    [[ -f "$path" && ! -L "$path" && -s "$path" && -x "$path" ]] || return 1
    canonical="$(realpath -e -- "$path" 2>/dev/null)" || return 1
    [[ "$canonical" == "$path" ]] || return 1
    metadata="$(stat -Lc '%d:%i' -- "$path" 2>/dev/null)" || return 1
    [[ "$metadata" == "$device:$inode" ]] || return 1
    digest="$(qemu_trust_file_sha256 "$path")" || return 1
    [[ "$digest" == "$sha256" ]]
}

qemu_trust_manifest_record_is_live() {
    local index="$1"
    [[ "$index" =~ ^[0-9]+$ && index -lt ${#QEMU_TRUST_PATHS[@]} ]] || return 1
    qemu_trust_record_values_are_live \
        "${QEMU_TRUST_PATHS[$index]}" "${QEMU_TRUST_SHA256S[$index]}" \
        "${QEMU_TRUST_DEVICES[$index]}" "${QEMU_TRUST_INODES[$index]}"
}

qemu_trust_manifest_has_live_record() {
    local index
    for index in "${!QEMU_TRUST_PATHS[@]}"; do
        qemu_trust_manifest_record_is_live "$index" && return 0
    done
    return 1
}

qemu_trust_manifest_find_path() {
    local wanted="$1" index
    QEMU_TRUST_MATCH_INDEX=""
    for index in "${!QEMU_TRUST_PATHS[@]}"; do
        if [[ "${QEMU_TRUST_PATHS[$index]}" == "$wanted" ]]; then
            QEMU_TRUST_MATCH_INDEX="$index"
            return 0
        fi
    done
    return 1
}

# installer 在全局安装锁内调用：严格解析旧文件，清除身份已失效的记录，同路径 upsert，
# 最后再次执行上限/重复路径检查。格式或权限损坏绝不能通过“重新安装”被静默覆盖。
qemu_trust_manifest_prepare_upsert() {
    local manifest="$1" owner="$2" group="$3"
    local new_path="$4" new_sha="$5" new_device="$6" new_inode="$7" index
    local -a keep_paths=() keep_shas=() keep_devices=() keep_inodes=()

    if [[ -e "$manifest" || -L "$manifest" ]]; then
        qemu_trust_manifest_load_checked "$manifest" "$owner" "$group" 644 \
            || return 1
        for index in "${!QEMU_TRUST_PATHS[@]}"; do
            [[ "${QEMU_TRUST_PATHS[$index]}" != "$new_path" ]] || continue
            if qemu_trust_manifest_record_is_live "$index"; then
                keep_paths+=("${QEMU_TRUST_PATHS[$index]}")
                keep_shas+=("${QEMU_TRUST_SHA256S[$index]}")
                keep_devices+=("${QEMU_TRUST_DEVICES[$index]}")
                keep_inodes+=("${QEMU_TRUST_INODES[$index]}")
            fi
        done
    fi
    qemu_trust_manifest_reset
    for index in "${!keep_paths[@]}"; do
        qemu_trust_manifest_append "${keep_paths[$index]}" "${keep_shas[$index]}" \
            "${keep_devices[$index]}" "${keep_inodes[$index]}" || return 1
    done
    qemu_trust_manifest_append "$new_path" "$new_sha" "$new_device" "$new_inode"
}

qemu_trust_manifest_remove_path() {
    local wanted="$1" index removed=0
    local -a keep_paths=() keep_shas=() keep_devices=() keep_inodes=()

    for index in "${!QEMU_TRUST_PATHS[@]}"; do
        if [[ "${QEMU_TRUST_PATHS[$index]}" == "$wanted" ]]; then
            removed=1
            continue
        fi
        keep_paths+=("${QEMU_TRUST_PATHS[$index]}")
        keep_shas+=("${QEMU_TRUST_SHA256S[$index]}")
        keep_devices+=("${QEMU_TRUST_DEVICES[$index]}")
        keep_inodes+=("${QEMU_TRUST_INODES[$index]}")
    done
    qemu_trust_manifest_reset
    for index in "${!keep_paths[@]}"; do
        qemu_trust_manifest_append "${keep_paths[$index]}" "${keep_shas[$index]}" \
            "${keep_devices[$index]}" "${keep_inodes[$index]}" || return 1
    done
    QEMU_TRUST_REMOVED="$removed"
}

qemu_trust_manifest_render() {
    local index
    for index in "${!QEMU_TRUST_PATHS[@]}"; do
        printf 'path=%s\n' "${QEMU_TRUST_PATHS[$index]}"
        printf 'sha256=%s\n' "${QEMU_TRUST_SHA256S[$index]}"
        printf 'device=%s\n' "${QEMU_TRUST_DEVICES[$index]}"
        printf 'inode=%s\n' "${QEMU_TRUST_INODES[$index]}"
    done
}

# 目标目录必须已经由调用者验证为可信；mktemp 与最终 rename 都发生在该目录内。
qemu_trust_manifest_write_atomic() {
    local destination="$1" owner="$2" group="$3" mode="$4" directory temporary

    directory="${destination%/*}"
    temporary="$(mktemp "$directory/.qemu-vmate-cpu-trust.XXXXXX")" || {
        _qemu_trust_error "无法创建 manifest 临时文件"
        return 1
    }
    if ! qemu_trust_manifest_render > "$temporary" ||
       ! chown "$owner:$group" "$temporary" 2>/dev/null ||
       ! chmod "$mode" "$temporary"; then
        rm -f -- "$temporary"
        _qemu_trust_error "无法写入 manifest 临时文件"
        return 1
    fi
    if ! mv -fT -- "$temporary" "$destination"; then
        rm -f -- "$temporary"
        _qemu_trust_error "无法原子发布 manifest"
        return 1
    fi
}
