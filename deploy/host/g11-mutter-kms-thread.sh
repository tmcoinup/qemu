#!/usr/bin/env bash
# Reversible Ubuntu GNOME/Mutter high-rate mouse workaround.
#
# The production actions only manage one explicitly marked block in
# /etc/environment.  They never restart GNOME Shell, log the user out, or
# print the rest of the environment file.
set -euo pipefail

readonly G11_BEGIN_MARKER='# BEGIN G11 MANAGED MUTTER KMS THREAD'
readonly G11_SETTING='MUTTER_DEBUG_KMS_THREAD_TYPE=user'
readonly G11_END_MARKER='# END G11 MANAGED MUTTER KMS THREAD'
readonly PRODUCTION_ENV_FILE='/etc/environment'

usage() {
    cat <<'EOF'
用法：
  ./deploy/host/g11-mutter-kms-thread.sh status
  ./deploy/host/g11-mutter-kms-thread.sh status --json
  sudo ./deploy/host/g11-mutter-kms-thread.sh enable
  sudo ./deploy/host/g11-mutter-kms-thread.sh disable

enable/disable 只管理 /etc/environment 中带明确 G11 marker 的块。
机器接口 status --json 只输出固定枚举状态，不回显环境变量值。
命令不会自动注销、重启 GNOME Shell 或重启宿主机。
EOF
}

fail() {
    echo "[g11-mutter-kms] ERROR: $*" >&2
    exit 1
}

info() {
    echo "[g11-mutter-kms] $*"
}

action=${1:-status}
status_format=text
case "$action" in
    status)
        case $# in
            0|1) ;;
            2)
                [[ "$2" == --json ]] || {
                    usage >&2
                    exit 2
                }
                status_format=json
                ;;
            *)
                usage >&2
                exit 2
                ;;
        esac
        ;;
    enable|disable)
        [[ $# -eq 1 ]] || {
            usage >&2
            exit 2
        }
        ;;
    -h|--help)
        [[ $# -eq 1 ]] || {
            usage >&2
            exit 2
        }
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

test_mode=${G11_MUTTER_TEST_MODE:-0}
case "$test_mode" in
    0|1) ;;
    *) fail 'G11_MUTTER_TEST_MODE 只能是 0 或 1' ;;
esac

env_file=${G11_MUTTER_ENV_FILE:-$PRODUCTION_ENV_FILE}
proc_root=${G11_MUTTER_PROC_ROOT:-/proc}
test_shell_pid=${G11_MUTTER_TEST_SHELL_PID:-}

if ((test_mode)); then
    [[ "$env_file" != "$PRODUCTION_ENV_FILE" ]] ||
        fail '测试模式拒绝把 /etc/environment 当作目标'
    [[ "$env_file" == /* ]] || fail '测试目标必须是绝对路径'
    [[ "$proc_root" == /* ]] || fail '测试 proc root 必须是绝对路径'
else
    [[ "$env_file" == "$PRODUCTION_ENV_FILE" ]] ||
        fail '生产模式只允许操作 /etc/environment'
    [[ "$proc_root" == /proc ]] ||
        fail 'G11_MUTTER_PROC_ROOT 只允许用于测试模式'
    [[ -z "$test_shell_pid" ]] ||
        fail 'G11_MUTTER_TEST_SHELL_PID 只允许用于测试模式'
fi

[[ ! -L "$env_file" ]] || fail "拒绝操作符号链接：$env_file"
if [[ -e "$env_file" ]]; then
    [[ -f "$env_file" ]] || fail "目标不是普通文件：$env_file"
    [[ -r "$env_file" ]] || fail "目标不可读：$env_file"
fi

# Results populated by inspect_config.  A managed block is valid only when it
# is exactly BEGIN + the supported assignment + END.  This makes disable safe:
# it can never erase text that was not written by this helper.
managed_block=0
unmanaged_assignments=0
config_error=''

inspect_config() {
    local line
    local in_block=0
    local begin_count=0
    local end_count=0
    local managed_lines=0

    managed_block=0
    unmanaged_assignments=0
    config_error=''
    [[ -e "$env_file" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$G11_BEGIN_MARKER" ]]; then
            begin_count=$((begin_count + 1))
            if ((in_block || begin_count > 1)); then
                config_error='发现重复或嵌套的 G11 BEGIN marker'
            fi
            in_block=1
            continue
        fi
        if [[ "$line" == "$G11_END_MARKER" ]]; then
            end_count=$((end_count + 1))
            if ((!in_block || end_count > 1)); then
                config_error='发现无配对或重复的 G11 END marker'
            fi
            in_block=0
            continue
        fi

        if ((in_block)); then
            managed_lines=$((managed_lines + 1))
            if [[ "$line" != "$G11_SETTING" ]]; then
                config_error='G11 marker 块含有未知内容，拒绝自动改写'
            fi
        elif [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?MUTTER_DEBUG_KMS_THREAD_TYPE[[:space:]]*= ]]; then
            unmanaged_assignments=$((unmanaged_assignments + 1))
        fi
    done <"$env_file"

    if ((in_block || begin_count != end_count)); then
        config_error='G11 marker 块不完整'
    elif ((begin_count == 1)); then
        if ((managed_lines != 1)); then
            config_error='G11 marker 块不是唯一受管赋值'
        elif [[ -z "$config_error" ]]; then
            managed_block=1
        fi
    elif ((begin_count > 1)); then
        config_error='发现多个 G11 marker 块'
    fi

    if ((managed_block && unmanaged_assignments)); then
        config_error='受管块之外还存在 MUTTER_DEBUG_KMS_THREAD_TYPE 赋值'
    fi
}

prepare_atomic_temp() {
    local target_dir target_base

    target_dir=$(dirname -- "$env_file")
    target_base=$(basename -- "$env_file")
    [[ -d "$target_dir" ]] || fail "目标目录不存在：$target_dir"
    atomic_temp=$(mktemp "$target_dir/.${target_base}.g11.XXXXXX") ||
        fail '无法在目标目录创建原子临时文件'
    if [[ -e "$env_file" ]]; then
        # Preserve owner, group, mode, ACL and xattrs on the same-filesystem
        # temporary inode before replacing its contents.
        cp --preserve=all -- "$env_file" "$atomic_temp" ||
            fail '无法保留 /etc/environment 的属性'
    else
        : >"$atomic_temp"
        chmod 0644 "$atomic_temp"
        if ((!test_mode)); then
            chown 0:0 "$atomic_temp"
        fi
    fi
}

publish_atomic_temp() {
    local before_meta after_meta target_dir

    if [[ -e "$env_file" ]]; then
        before_meta=$(stat -c '%a:%u:%g' -- "$env_file")
        after_meta=$(stat -c '%a:%u:%g' -- "$atomic_temp")
        [[ "$before_meta" == "$after_meta" ]] ||
            fail '临时文件权限/属主与原文件不一致，已拒绝发布'
    fi
    sync -f "$atomic_temp" 2>/dev/null || true
    mv -fT -- "$atomic_temp" "$env_file"
    atomic_temp=''
    target_dir=$(dirname -- "$env_file")
    sync -f "$target_dir" 2>/dev/null || true
}

enable_workaround() {
    local final_newline=1

    ((test_mode || EUID == 0)) ||
        fail 'enable 必须显式使用 sudo 运行；脚本不会保存凭据'
    inspect_config
    [[ -z "$config_error" ]] || fail "$config_error"
    if ((unmanaged_assignments)); then
        fail '发现非 G11 管理的 MUTTER_DEBUG_KMS_THREAD_TYPE；为避免覆盖人工配置，未作修改'
    fi
    if ((managed_block)); then
        info '官方 workaround 已由 G11 marker 管理，无需重复写入'
        info '当前登录会话不会被改变；请用 status 核对是否已重新登录生效'
        return 0
    fi

    atomic_temp=''
    trap '[[ -z "${atomic_temp:-}" ]] || rm -f -- "$atomic_temp"' EXIT
    prepare_atomic_temp
    if [[ -s "$env_file" ]]; then
        final_newline=$(tail -c 1 -- "$env_file" | wc -l)
    fi
    {
        [[ ! -e "$env_file" ]] || command cat -- "$env_file"
        if [[ -s "$env_file" ]] && ((final_newline == 0)); then
            printf '\n'
        fi
        printf '%s\n%s\n%s\n' \
            "$G11_BEGIN_MARKER" "$G11_SETTING" "$G11_END_MARKER"
    } >"$atomic_temp"
    publish_atomic_temp
    trap - EXIT

    info '已原子写入 G11 受管块：MUTTER_DEBUG_KMS_THREAD_TYPE=user'
    info '没有自动注销或重启；保存工作并正常关闭 VM 后，注销再登录才会生效'
}

disable_workaround() {
    ((test_mode || EUID == 0)) ||
        fail 'disable 必须显式使用 sudo 运行；脚本不会保存凭据'
    inspect_config
    [[ -z "$config_error" ]] || fail "$config_error"
    if ((!managed_block)); then
        if ((unmanaged_assignments)); then
            fail '检测到非 G11 管理的赋值；disable 不会删除人工配置'
        fi
        info '未发现 G11 受管块，无需回滚'
        return 0
    fi

    atomic_temp=''
    trap '[[ -z "${atomic_temp:-}" ]] || rm -f -- "$atomic_temp"' EXIT
    prepare_atomic_temp
    awk -v begin="$G11_BEGIN_MARKER" -v end="$G11_END_MARKER" '
        $0 == begin { in_block = 1; next }
        $0 == end   { in_block = 0; next }
        !in_block   { print }
    ' "$env_file" >"$atomic_temp"
    publish_atomic_temp
    trap - EXIT

    info '已原子移除 G11 受管块；其他 /etc/environment 内容未改写'
    info '没有自动注销或重启；注销再登录后才会回到 Mutter 默认 KMS thread'
}

read_process_env() {
    local pid=$1 name=$2
    local environ_file="$proc_root/$pid/environ"

    [[ -r "$environ_file" ]] || return 1
    tr '\0' '\n' <"$environ_file" |
        sed -n "s/^${name}=//p" | head -n 1
}

find_shell_pid() {
    local requested_uid candidate session_type first=''

    if [[ -n "$test_shell_pid" ]]; then
        [[ "$test_shell_pid" =~ ^[1-9][0-9]*$ ]] ||
            fail '测试 gnome-shell PID 必须是正整数'
        printf '%s\n' "$test_shell_pid"
        return 0
    fi

    requested_uid=${SUDO_UID:-$(id -u)}
    if [[ "$proc_root" == /proc ]] && command -v pgrep >/dev/null 2>&1; then
        while IFS= read -r candidate; do
            [[ -n "$candidate" ]] || continue
            [[ -n "$first" ]] || first=$candidate
            session_type=$(read_process_env "$candidate" XDG_SESSION_TYPE || true)
            if [[ "$session_type" == wayland ]]; then
                printf '%s\n' "$candidate"
                return 0
            fi
        done < <(pgrep -u "$requested_uid" -x gnome-shell 2>/dev/null || true)
    fi
    [[ -z "$first" ]] || printf '%s\n' "$first"
}

# Read scheduler data without exposing thread names, PIDs or arbitrary proc
# contents through the JSON contract.  Linux /proc stat fields 40 and 41 are
# rt_priority and policy.  The sched fallback keeps the existing fake-proc
# test interface small and deterministic.
read_task_scheduling() {
    local task_dir=$1 stat_line after_comm policy='' rt_priority=''
    local -a fields=()

    if [[ -r "$task_dir/stat" ]]; then
        IFS= read -r stat_line <"$task_dir/stat" || true
        if [[ "$stat_line" == *') '* ]]; then
            after_comm=${stat_line##*) }
            read -r -a fields <<<"$after_comm"
            if ((${#fields[@]} >= 39)); then
                rt_priority=${fields[37]}
                policy=${fields[38]}
            fi
        fi
    fi
    if [[ ! "$policy" =~ ^[0-9]+$ || ! "$rt_priority" =~ ^[0-9]+$ ]]; then
        if [[ -r "$task_dir/sched" ]]; then
            policy=$(awk '$1 == "policy" {print $3; exit}' "$task_dir/sched")
            rt_priority=$(awk \
                '$1 == "rt_priority" {print $3; exit}' "$task_dir/sched")
        fi
    fi

    case "$policy" in
        1) policy=fifo ;;
        2) policy=rr ;;
        0|3|4|5|6|7) policy=other ;;
        *) policy=unknown ;;
    esac
    [[ "$rt_priority" =~ ^[0-9]+$ ]] || rt_priority=unknown
    printf '%s %s\n' "$policy" "$rt_priority"
}

# Results populated by inspect_kms_threads.  "realtime" deliberately means
# only FIFO/RR with a positive realtime priority: a merely separate KMS
# thread is not enough to recommend the workaround.
kms_thread_state=unknown

inspect_kms_threads() {
    local shell_pid=$1 task_root task_dir comm policy priority
    local found=0 task_seen=0 task_scan_unknown=0
    local known_non_rt=0 scheduling_unknown=0
    local highest_priority=0

    task_root="$proc_root/$shell_pid/task"
    if [[ ! -d "$task_root" || ! -r "$task_root" ]]; then
        kms_thread_state=unknown
        return
    fi
    for task_dir in "$task_root/"[0-9]*; do
        [[ -d "$task_dir" ]] || continue
        task_seen=1
        if [[ ! -r "$task_dir/comm" ]]; then
            task_scan_unknown=1
            continue
        fi
        IFS= read -r comm <"$task_dir/comm" || true
        [[ "$comm" == 'KMS thread' ]] || continue
        found=1
        read -r policy priority < <(read_task_scheduling "$task_dir")
        if [[ "$policy" == fifo || "$policy" == rr ]]; then
            if [[ "$priority" =~ ^[0-9]+$ ]] && ((priority > 0)); then
                if ((priority > highest_priority)); then
                    highest_priority=$priority
                fi
            else
                scheduling_unknown=1
            fi
        elif [[ "$policy" == other && "$priority" =~ ^[0-9]+$ ]]; then
            known_non_rt=1
        else
            scheduling_unknown=1
        fi
    done

    if ((!task_seen || (!found && task_scan_unknown))); then
        kms_thread_state=unknown
    elif ((!found)); then
        kms_thread_state=absent
    elif ((highest_priority > 0)); then
        kms_thread_state=realtime
    elif ((scheduling_unknown)); then
        kms_thread_state=unknown
    elif ((known_non_rt)); then
        kms_thread_state=normal
    else
        kms_thread_state=unknown
    fi
}

show_json_status() {
    local config_state=absent managed_json=false
    local shell_pid='' shell_name='' gnome_shell_json=false
    local shell_candidate_json=false
    local session_type=absent session_mode=absent current_mode=''
    local raw_session_type='' recommendation=unknown relogin_required=false

    inspect_config
    if [[ -n "$config_error" ]]; then
        config_state=invalid
    elif ((managed_block)); then
        config_state=managed-user
        managed_json=true
    elif ((unmanaged_assignments)); then
        config_state=unmanaged
    fi

    shell_pid=$(find_shell_pid || true)
    if [[ -n "$shell_pid" && -d "$proc_root/$shell_pid" ]]; then
        shell_candidate_json=true
        if [[ -r "$proc_root/$shell_pid/comm" ]]; then
            IFS= read -r shell_name <"$proc_root/$shell_pid/comm" || true
        fi
        if [[ "$shell_name" == gnome-shell ]]; then
            gnome_shell_json=true
        fi
        if [[ -r "$proc_root/$shell_pid/environ" ]]; then
            raw_session_type=$(read_process_env "$shell_pid" XDG_SESSION_TYPE || true)
            case "$raw_session_type" in
                wayland|x11) session_type=$raw_session_type ;;
                '') session_type=unknown ;;
                *) session_type=unknown ;;
            esac
            current_mode=$(read_process_env \
                "$shell_pid" MUTTER_DEBUG_KMS_THREAD_TYPE || true)
            case "$current_mode" in
                user|kernel) session_mode=$current_mode ;;
                '') session_mode=unset ;;
                *) session_mode=other ;;
            esac
        else
            session_type=unknown
            session_mode=unknown
        fi
        inspect_kms_threads "$shell_pid"
    else
        kms_thread_state=absent
    fi

    # Configuration conflicts always win: VMate must never take ownership of
    # an administrator's assignment or guess how to repair a malformed block.
    if [[ "$config_state" == invalid || "$config_state" == unmanaged ]]; then
        recommendation=conflict
    elif [[ "$shell_candidate_json" != true ]]; then
        recommendation=not-applicable
    elif [[ "$gnome_shell_json" != true ]]; then
        recommendation=unknown
    elif [[ "$session_type" == x11 ]]; then
        recommendation=not-applicable
    elif [[ "$session_type" != wayland ]]; then
        recommendation=unknown
    elif [[ "$session_mode" == user ]]; then
        if [[ "$kms_thread_state" == absent ]]; then
            if [[ "$managed_json" == true ]]; then
                recommendation=ready
            else
                # This is the observable state immediately after disable: the
                # file is clean but the old Shell still carries user mode.
                recommendation=relogin
                relogin_required=true
            fi
        else
            recommendation=unknown
        fi
    elif [[ "$session_mode" == kernel || "$session_mode" == unset ]]; then
        case "$kms_thread_state" in
            realtime)
                if [[ "$managed_json" == true ]]; then
                    recommendation=relogin
                    relogin_required=true
                else
                    recommendation=enable
                fi
                ;;
            absent|normal) recommendation=not-applicable ;;
            *) recommendation=unknown ;;
        esac
    else
        recommendation=unknown
    fi

    # All string values below come from closed enums.  Do not add paths,
    # process IDs, desktop names or raw environment values to this interface.
    printf '{"schema":1,'
    printf '"config":"%s",' "$config_state"
    printf '"session_type":"%s","session_mode":"%s",' \
        "$session_type" "$session_mode"
    printf '"kms_thread":"%s","recommendation":"%s",' \
        "$kms_thread_state" "$recommendation"
    printf '"managed":%s,"relogin_required":%s}\n' \
        "$managed_json" "$relogin_required"
}

show_kms_thread() {
    local shell_pid=$1 task_dir tid comm scheduling policy rt_priority
    local found=0

    for task_dir in "$proc_root/$shell_pid/task/"[0-9]*; do
        [[ -d "$task_dir" ]] || continue
        [[ -r "$task_dir/comm" ]] || continue
        IFS= read -r comm <"$task_dir/comm" || true
        [[ "$comm" == 'KMS thread' ]] || continue
        found=1
        tid=${task_dir##*/}
        scheduling='unknown'
        if [[ "$proc_root" == /proc ]] && command -v ps >/dev/null 2>&1; then
            scheduling=$(ps -L -p "$shell_pid" -o tid=,cls=,rtprio= 2>/dev/null |
                awk -v wanted="$tid" '
                    $1 == wanted {
                        $1 = ""
                        sub(/^[[:space:]]+/, "")
                        print
                        exit
                    }
                ' || true)
            [[ -n "$scheduling" ]] || scheduling='unknown'
        elif [[ -r "$task_dir/sched" ]]; then
            policy=$(awk '$1 == "policy" {print $3; exit}' "$task_dir/sched")
            rt_priority=$(awk '$1 == "rt_priority" {print $3; exit}' "$task_dir/sched")
            scheduling="policy=${policy:-?}, rt_priority=${rt_priority:-?}"
        fi
        info "当前独立 KMS thread：TID=$tid，调度=$scheduling"
    done

    if ((!found)); then
        info '当前未发现独立 KMS thread（user 模式通常在 Shell 主循环处理 KMS）'
    fi
}

show_status() {
    local shell_pid='' current_mode=''

    inspect_config
    info "配置文件：$env_file"
    if [[ -n "$config_error" ]]; then
        info "配置状态：INVALID（$config_error）"
    elif ((managed_block)); then
        info '配置状态：G11 workaround 已写入（user）'
    elif ((unmanaged_assignments)); then
        info '配置状态：发现非 G11 管理的 MUTTER_DEBUG_KMS_THREAD_TYPE；不会覆盖'
    else
        info '配置状态：未启用 G11 workaround（Mutter 默认 kernel 模式）'
    fi

    shell_pid=$(find_shell_pid || true)
    if [[ -z "$shell_pid" || ! -d "$proc_root/$shell_pid" ]]; then
        info '当前会话：未找到调用用户的 gnome-shell；配置只会在下次登录时读取'
        info '本工具不会自动注销、重启 GNOME Shell 或重启宿主机'
        [[ -z "$config_error" ]]
        return
    fi

    current_mode=$(read_process_env "$shell_pid" MUTTER_DEBUG_KMS_THREAD_TYPE || true)
    case "$current_mode" in
        user)
            info "当前 gnome-shell：PID=$shell_pid，环境=user（workaround 已在本会话生效）"
            ;;
        kernel)
            info "当前 gnome-shell：PID=$shell_pid，环境=kernel（显式默认模式）"
            ;;
        '')
            info "当前 gnome-shell：PID=$shell_pid，环境未设置（默认 kernel 模式）"
            ;;
        *)
            info "当前 gnome-shell：PID=$shell_pid，环境为未知值（未回显具体内容）"
            ;;
    esac
    show_kms_thread "$shell_pid"

    if ((managed_block)) && [[ "$current_mode" != user ]]; then
        info '结论：文件已写入，但当前会话尚未生效；保存工作后注销并重新登录'
    elif ((!managed_block)) && [[ "$current_mode" == user ]]; then
        info '结论：文件已回滚，但当前会话仍是 user；注销并重新登录后恢复默认'
    elif [[ "$current_mode" == user ]]; then
        info '结论：当前会话正在使用 user KMS 模式'
    else
        info '结论：当前会话仍在使用默认独立/实时 KMS thread 路径'
    fi
    info '本工具不会自动注销、重启 GNOME Shell 或重启宿主机'
    [[ -z "$config_error" ]]
}

case "$action" in
    status)
        if [[ "$status_format" == json ]]; then
            show_json_status
        else
            show_status
        fi
        ;;
    enable)  enable_workaround ;;
    disable) disable_workaround ;;
esac
