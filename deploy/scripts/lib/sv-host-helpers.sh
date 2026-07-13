# shellcheck shell=bash
# ---------------------------------------------------------------------------
# root helper 安全边界。
#
# sudoers 绝不能指向普通用户可写的 Git 工作区。本模块只公布固定安装路径，并在
# 真正启动（非 DRY_RUN）前阻止遗留的不安全授权继续生效。
# ---------------------------------------------------------------------------

readonly SV_HOST_PERF_HELPER="/usr/local/libexec/qemu-vmate-host-performance"
readonly SV_CPU_ISO_HELPER="/usr/local/libexec/qemu-vmate-cpu-isolate"
export SV_HOST_PERF_HELPER SV_CPU_ISO_HELPER

_sv_root_helper_is_safe() {
    local path="$1"
    local metadata uid gid mode

    [[ -f "$path" && -x "$path" && ! -L "$path" ]] || return 1
    metadata="$(stat -Lc '%u %g %a' "$path" 2>/dev/null)" || return 1
    read -r uid gid mode <<<"$metadata"
    [[ "$uid" == "0" && "$gid" == "0" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    # 八进制 022 表示 group/other 可写位；任一命中都不能作为免密 root helper。
    (( (8#$mode & 8#022) == 0 ))
}

_sv_reject_legacy_workspace_sudoers() {
    [[ "${DRY_RUN:-0}" == "1" ]] && return 0

    local listing
    listing="$(sudo -n -l 2>/dev/null || true)"
    if [[ "$listing" == *"$HERE/host-performance.sh"* || \
          "$listing" == *"$HERE/host-cpu-isolate.sh"* ]]; then
        echo "ERROR: 检测到 sudoers 仍放行用户可写的工作区脚本。" >&2
        echo "       这会形成免密 root 提权路径；已拒绝启动。" >&2
        echo "       请运行: sudo $HERE/setup-host-helpers.sh" >&2
        return 1
    fi
}

_sv_reject_legacy_workspace_sudoers

# 安装文件存在时立刻验证 owner/mode；缺失由实际启用 HOST_TUNE/CPU_ISOLATE 的模块
# 给出有针对性的安装提示。这样显式关闭可选宿主调优时不强迫安装无用 helper。
for _sv_helper in "$SV_HOST_PERF_HELPER" "$SV_CPU_ISO_HELPER"; do
    if [[ -e "$_sv_helper" ]] && ! _sv_root_helper_is_safe "$_sv_helper"; then
        echo "ERROR: root helper 所有权或权限不安全: $_sv_helper" >&2
        echo "       要求 regular file、root:root 且 group/other 不可写。" >&2
        exit 1
    fi
done
unset _sv_helper
