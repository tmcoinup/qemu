#!/usr/bin/env bash
# Build the small read-only answer ISO consumed by Windows Setup.  This helper
# is sourced by start-vm.sh; the subshell keeps its temporary trap local.

windows_unattend_build_iso() (
    set -euo pipefail

    local template=${1:?template is required}
    local output=${2:?output ISO is required}
    local computer_name=${3:?computer name is required}
    local builder=${XORRISO:-xorriso}
    local output_dir stage_dir tmp_iso build_log placeholder_count

    [[ -r "$template" ]] || {
        echo "[unattend] template 不存在或不可读: $template" >&2
        return 1
    }
    [[ "$computer_name" =~ ^DESKTOP-[A-Z0-9]{7}$ ]] || {
        echo "[unattend] ComputerName 必须是 DESKTOP- 加 7 位大写字母/数字: $computer_name" >&2
        return 2
    }
    command -v "$builder" >/dev/null 2>&1 || {
        echo "[unattend] 缺少 xorriso；请安装: sudo apt install xorriso" >&2
        return 1
    }

    placeholder_count=$(awk -v RS='__COMPUTER_NAME__' 'END { print NR - 1 }' "$template")
    [[ "$placeholder_count" == 1 ]] || {
        echo "[unattend] template 必须且只能包含一个 __COMPUTER_NAME__" >&2
        return 1
    }

    output_dir=$(dirname "$output")
    mkdir -p "$output_dir"
    stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/vgpu-unattend.XXXXXX")
    tmp_iso=$(mktemp "${output}.tmp.XXXXXX")
    build_log=$(mktemp "${output}.xorriso.XXXXXX")
    trap 'rm -rf -- "$stage_dir" "$tmp_iso" "$build_log"' EXIT

    sed "s/__COMPUTER_NAME__/${computer_name}/" \
        "$template" >"$stage_dir/Autounattend.xml"

    if ! "$builder" -as mkisofs -quiet -J -r -V OEMDRV \
            -o "$tmp_iso" "$stage_dir" > /dev/null 2>"$build_log"; then
        sed 's/^/[unattend] xorriso: /' "$build_log" >&2
        return 1
    fi
    [[ -s "$tmp_iso" ]] || {
        echo "[unattend] xorriso 未生成有效 ISO: $tmp_iso" >&2
        return 1
    }
    chmod 0600 "$tmp_iso"
    mv -f -- "$tmp_iso" "$output"
)
