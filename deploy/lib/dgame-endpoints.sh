#!/usr/bin/env bash
# DGame compatibility endpoints for G-11 runtime sockets.
#
# G-11 owns canonical sockets below each VM's run directory.  DGame discovers
# them through the stable /tmp/qemu-stealth-N.* names.  Keep that discovery
# policy in one place and never replace an endpoint we do not own.

dgame_endpoint_validate_id() {
    [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

dgame_endpoint_path() {
    local vm_id=${1:-} suffix=${2:-} root=${3:-/tmp}

    dgame_endpoint_validate_id "$vm_id" || {
        echo "DGame endpoint VM ID must be a positive integer: ${vm_id:-<empty>}" >&2
        return 2
    }
    case "$suffix" in
        qmp|qmp.proxy|fb|mon) ;;
        *)
            echo "unsupported DGame endpoint suffix: ${suffix:-<empty>}" >&2
            return 2
            ;;
    esac
    [[ "$root" == /* && "$root" != *$'\n'* && "$root" != *$'\r'* ]] || {
        echo "DGame endpoint root must be an absolute path: $root" >&2
        return 2
    }
    printf '%s/qemu-stealth-%s.%s\n' "${root%/}" "$vm_id" "$suffix"
}

dgame_preview_socket_path() {
    local run_dir=${1:-}

    [[ "$run_dir" == /* && "$run_dir" != *$'\n'* &&
       "$run_dir" != *$'\r'* ]] || {
        echo "DGame preview run directory must be absolute: $run_dir" >&2
        return 2
    }
    printf '%s/dgame-fb-shm.sock\n' "${run_dir%/}"
}

dgame_endpoint_alias_install() {
    local alias_path=${1:-} target_path=${2:-} current parent

    [[ "$alias_path" == /* && "$target_path" == /* &&
       "$alias_path" != "$target_path" ]] || {
        echo "DGame endpoint alias and target must be distinct absolute paths" >&2
        return 2
    }
    parent=$(dirname -- "$alias_path")
    [[ -d "$parent" && ! -L "$parent" ]] || {
        echo "DGame endpoint parent is missing or unsafe: $parent" >&2
        return 1
    }
    if [[ -L "$alias_path" ]]; then
        current=$(readlink -- "$alias_path") || return 1
        if [[ "$current" == "$target_path" ]]; then
            return 0
        fi
        echo "refusing to replace foreign DGame endpoint alias: $alias_path -> $current" >&2
        return 1
    fi
    if [[ -e "$alias_path" || -S "$alias_path" ]]; then
        echo "refusing to replace existing DGame endpoint: $alias_path" >&2
        return 1
    fi
    ln -s -- "$target_path" "$alias_path"
}

dgame_endpoint_alias_remove() {
    local alias_path=${1:-} target_path=${2:-} current

    [[ "$alias_path" == /* && "$target_path" == /* ]] || return 2
    [[ -L "$alias_path" ]] || return 0
    current=$(readlink -- "$alias_path") || return 1
    if [[ "$current" != "$target_path" ]]; then
        echo "preserving foreign DGame endpoint alias: $alias_path -> $current" >&2
        return 0
    fi
    rm -f -- "$alias_path"
}
