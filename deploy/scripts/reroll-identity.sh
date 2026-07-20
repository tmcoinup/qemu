#!/bin/bash
# ---------------------------------------------------------------------------
# reroll-identity.sh [INSTANCE ...]
#
# 安全门禁：旧版本会直接删除 profile，使持久 TPM state 丢失平台依据，并在
# 下次启动时随机换板。该做法现已禁用；本脚本只定位目标并给出原子 reroll
# 命令，不再删除任何身份或密钥文件。
#
# 使用 start-vm.sh --reroll 时，候选身份通过全部门禁后才原子替换 profile。
# 若已有 TPM state，启动器会拒绝 reroll，避免新 UUID/主板序列号复用旧 TPM
# 密钥；应新建 instance 或使用经过验证的密钥迁移/归档流程。
#
#  Examples:
#     reroll-identity.sh 1          # 检查 instance 1 并打印安全命令
#     reroll-identity.sh 1 2 3      # 批量检查三个实例
#     reroll-identity.sh --all      # 检查所有已有 profile 的实例
# ---------------------------------------------------------------------------
set -euo pipefail

VMS_DIR="${VMS_DIR:-/home/ubuntu/images/vms}"

usage() {
    sed -n '2,/^# --*$/p' "$0" | sed -e 's/^# *//' -e 's/^#$//' >&2
    exit "${1:-2}"
}

if (( $# == 0 )); then
    usage
fi

targets=()
if [[ "$1" == "--all" ]]; then
    shopt -s nullglob
    for f in "$VMS_DIR"/[0-9]*/profile; do
        n="${f%/profile}"; n="${n##*/}"
        targets+=("$n")
    done
    shopt -u nullglob
    if (( ${#targets[@]} == 0 )); then
        echo ">> no saved profiles found in $VMS_DIR/<N>/profile"
        exit 0
    fi
else
    for arg in "$@"; do
        if ! [[ "$arg" =~ ^[0-9]+$ ]]; then
            echo "ERROR: '$arg' is not a valid instance number" >&2
            exit 2
        fi
        targets+=("$arg")
    done
fi

blocked=0
for n in "${targets[@]}"; do
    f="$VMS_DIR/${n}/profile"
    if [[ -f "$f" ]]; then
        echo "ERROR: 为保护 profile 与 TPM state，已拒绝删除 $f" >&2
        echo "       请在下次实际启动时运行: deploy/scripts/start-vm.sh $n --reroll" >&2
        blocked=1
    else
        echo ">> instance $n had no saved profile ($f) — next launch will generate one"
    fi
done

(( blocked == 0 ))
