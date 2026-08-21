#!/usr/bin/env bash
# shellcheck shell=bash
# Fail-closed loader for the host-wide vGPU resource policy.

# Usage:
#   vgpu_host_config_load FILE CONTEXT [VARIABLE_TO_UNSET ...]
# Returns 3 only when FILE truly does not exist.  Any existing symlink,
# directory, unreadable file, disappearance race, shell syntax error, or failed
# source operation is an unsafe configuration and returns 2.  Assignments made
# by a valid file intentionally remain in the caller's shell.
vgpu_host_config_load() {
    local path=$1 context=${2:-vGPU-host-config} variable
    shift 2

    if [[ ! -e "$path" && ! -L "$path" ]]; then
        return 3
    fi
    if [[ ! -f "$path" || -L "$path" || ! -r "$path" ]]; then
        printf '%s VGPU_HOST_CONFIG 必须是可读普通非符号链接文件: %s\n' \
            "$context" "$path" >&2
        return 2
    fi
    for variable in "$@"; do
        if [[ ! "$variable" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            printf '%s VGPU_HOST_CONFIG loader 收到非法变量名: %s\n' \
                "$context" "$variable" >&2
            return 2
        fi
        unset "$variable"
    done
    # Parse the complete file before executing any assignment.  Without this
    # pass, a syntax error near EOF could leave earlier assignments applied
    # even though the caller correctly aborts the operation.
    if ! bash -n -- "$path"; then
        printf '%s VGPU_HOST_CONFIG 加载失败（语法检查）: %s\n' \
            "$context" "$path" >&2
        return 2
    fi
    # This explicit conditional is required because callers commonly invoke
    # the loader from an `if` or `cmd || exit` context, where Bash would
    # otherwise suppress errexit inside this function and swallow a bad file.
    if ! source "$path"; then
        printf '%s VGPU_HOST_CONFIG 加载失败: %s\n' "$context" "$path" >&2
        return 2
    fi
}
