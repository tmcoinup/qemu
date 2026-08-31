#!/usr/bin/env bash
# Foolproof entry point for the reviewed G-11 household CPU pool.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
create_vm="$script_dir/create-vm.sh"

usage() {
    cat <<'EOF'
用法:
  ./deploy/scripts/create-home-vm.sh VM_ID --spec 2c2t|2c4t|4c4t|4c8t|6c12t [选项]

常用选项:
  --memory-size 4G|8G|12G|16G   默认 8G
  --cpu-profile PROFILE          可选固定具体 CPU；必须属于所选规格
  --board-profile PROFILE        可选固定与 CPU/容量匹配的审核主板
  --ssd-profile PROFILE          可选固定 SSD
  --gpu-profile PROFILE          可选固定显卡身份
  --gpu-vram 1024|2048           可选固定宿主 vGPU 档位
  --monitor-profile PROFILE      可选固定显示器
  --force                        覆盖已停止 VM 的现有配置

规格对应 CPU:
  2c2t   g3220
  2c4t   i3-4130
  4c4t   i5-4590（优先）、i5-4570、i5-4460
  4c8t   i7-4820k（优先 DDR3-1866）、i7-3820、i7-4790
  6c12t  i7-4960x（优先 DDR3-1866）、i7-4930k、i7-3930k

默认 8G；旧 6G 已归档。12G/16G 只会从至少四条 DIMM 插槽的审核主板中选择。
EOF
}

vm_id=
cpu_spec=
cpu_profile=
memory_size=8G
declare -a passthrough=()

while (( $# > 0 )); do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --spec)
            [[ $# -ge 2 ]] || { echo "--spec 缺少参数" >&2; exit 2; }
            case "${2,,}" in
                2c2t|2c4t|4c4t|4c8t|6c12t) cpu_spec=${2,,} ;;
                *) echo "--spec 只支持 2c2t/2c4t/4c4t/4c8t/6c12t" >&2; exit 2 ;;
            esac
            shift 2
            ;;
        --cpu-profile)
            [[ $# -ge 2 ]] || { echo "--cpu-profile 缺少参数" >&2; exit 2; }
            cpu_profile=$2
            shift 2
            ;;
        --memory-size)
            [[ $# -ge 2 ]] || { echo "--memory-size 缺少参数" >&2; exit 2; }
            case "${2^^}" in
                4G|8G|12G|16G) memory_size=${2^^} ;;
                *) echo "--memory-size 只支持 4G/8G/12G/16G" >&2; exit 2 ;;
            esac
            shift 2
            ;;
        --board-profile|--ssd-profile|--gpu-profile|--gpu-vram|\
        --monitor-profile|--keyboard-profile|--mouse-profile)
            [[ $# -ge 2 ]] || { echo "$1 缺少参数" >&2; exit 2; }
            passthrough+=("$1" "$2")
            shift 2
            ;;
        --force|--relative-mouse)
            passthrough+=("$1")
            shift
            ;;
        --platform|--memory-profile|--allow-fallback-platform|--include-fallback)
            echo "$1 会绕开家用池的规格/容量入口，create-home-vm.sh 不接受该参数" >&2
            exit 2
            ;;
        [1-9]|[1-9][0-9]*)
            [[ -z "$vm_id" ]] || { echo "只能指定一个 VM_ID" >&2; exit 2; }
            vm_id=$1
            shift
            ;;
        *)
            echo "未知参数: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ -n "$vm_id" ]] || { echo "缺少 VM_ID" >&2; usage >&2; exit 2; }
[[ -n "$cpu_spec" ]] || { echo "缺少 --spec 2c2t|2c4t|4c4t|4c8t|6c12t" >&2; usage >&2; exit 2; }

if [[ -n "$cpu_profile" ]]; then
    case "$cpu_spec:$cpu_profile" in
        2c2t:g3220|2c4t:i3-4130|\
        4c4t:i5-4460|4c4t:i5-4570|4c4t:i5-4590|\
        4c8t:i7-3820|4c8t:i7-4790|4c8t:i7-4820k|\
        6c12t:i7-3930k|6c12t:i7-4930k|6c12t:i7-4960x) ;;
        *)
            echo "CPU $cpu_profile 不属于 $cpu_spec 家用池" >&2
            exit 2
            ;;
    esac
    cpu_selector=(--cpu-profile "$cpu_profile")
else
    cpu_selector=(--cpu-spec "$cpu_spec")
fi

echo "[home-pool] VM=$vm_id 规格=$cpu_spec 内存=$memory_size CPU=${cpu_profile:-宿主兼容自动选择}" >&2
exec "$create_vm" "$vm_id" "${cpu_selector[@]}" \
    --memory-size "$memory_size" "${passthrough[@]}"
