#!/usr/bin/env bash
# V-11 家用 X79 一键入口：只暴露用户要求的 4C/8T、6C/12T 和四档内存。
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
start_vm="$script_dir/start-vm.sh"

usage() {
    cat <<'EOF'
用法：
  ./start-home-vm.sh INSTANCE --spec 4c8t|6c12t [--memory-size 4G|8G|12G|16G] [start-vm 参数]
  ./start-home-vm.sh --list

示例：
  ./start-home-vm.sh 11 --spec 4c8t
  ./start-home-vm.sh 12 --spec 6c12t --memory-size 16G --headless
  ./start-home-vm.sh 13 --spec 4c8t --platform-id=intel-lga2011-i7-3820-gigabyte-ga-x79-up4

新实例或 --reroll 默认内存是 8G，并优先：
  4c8t  -> Core i7-4820K + ASUS P9X79 + DDR3-1866
  6c12t -> Core i7-4960X + ASUS P9X79 + DDR3-1866

已有实例沿用其已保存的原子硬件 profile；要换平台/容量，请显式评估后使用 --reroll。
EOF
}

list_pool() {
    cat <<'EOF'
CPU（真实零售型号/料号）：
  4C/8T : Core i7-4820K / BX80633I74820K / DDR3-1866
          Core i7-3820  / BX80619I73820  / DDR3-1600
  6C/12T: Core i7-4960X / BX80633I74960X / DDR3-1866
          Core i7-4930K / BX80633I74930K / DDR3-1866
          Core i7-3930K / BX80619I73930K / DDR3-1600

主板：
  ASUS P9X79                     8 槽，最高 DDR3-1866
  Gigabyte GA-X79-UP4 rev. 1.0   8 槽，最高 DDR3-1866
  ASRock X79 Extreme4            4 槽，最高 DDR3-1600

内存：Samsung M378B5773/5273DH0-CMA（1866，优先）、
      Kingston KVR16N11S6/2、KVR16N11S8/4（1600）、
      SK hynix HMT325/HMT351U6CFR8C-PB（1600）。
容量：4G / 8G / 12G / 16G；默认 8G。12G/16G 只允许至少四槽主板。
EOF
}

instance=""
spec=""
memory_size="8G"
memory_explicit=0
platform_id=""
platform_explicit=0
reroll=0
declare -a passthrough=()

while (( $# > 0 )); do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --list)
            list_pool
            exit 0
            ;;
        --spec=*)
            spec="${1#*=}"
            ;;
        --spec)
            shift
            (( $# > 0 )) || { echo "ERROR: --spec 缺少值" >&2; exit 2; }
            spec="$1"
            ;;
        --memory-size=*)
            memory_size="${1#*=}"
            memory_explicit=1
            ;;
        --memory-size)
            shift
            (( $# > 0 )) || { echo "ERROR: --memory-size 缺少值" >&2; exit 2; }
            memory_size="$1"
            memory_explicit=1
            ;;
        --platform-id=*)
            platform_id="${1#*=}"
            platform_explicit=1
            ;;
        --cpus=*|--ram=*)
            echo "ERROR: CPU/内存由 --spec 和 --memory-size 统一设置，不能再传 $1" >&2
            exit 2
            ;;
        --)
            shift
            passthrough+=("$@")
            break
            ;;
        -*)
            [[ "$1" == --reroll ]] && reroll=1
            passthrough+=("$1")
            ;;
        *)
            if [[ -n "$instance" ]]; then
                echo "ERROR: 多余位置参数 '$1'" >&2
                usage >&2
                exit 2
            fi
            instance="$1"
            ;;
    esac
    shift
done

[[ -x "$start_vm" ]] || { echo "ERROR: 找不到可执行启动器 $start_vm" >&2; exit 1; }
[[ "$instance" =~ ^[1-9][0-9]{0,9}$ ]] || {
    echo "ERROR: INSTANCE 必须是 1–10 位正整数且不能有前导零" >&2
    usage >&2
    exit 2
}

case "${spec,,}" in
    4c8t) cpus=8; preferred_platform="intel-lga2011-i7-4820k-asus-p9x79" ;;
    6c12t) cpus=12; preferred_platform="intel-lga2011-i7-4960x-asus-p9x79" ;;
    *) echo "ERROR: --spec 只能是 4c8t 或 6c12t" >&2; exit 2 ;;
esac
spec="${spec,,}"

if (( platform_explicit )); then
    [[ -n "$platform_id" ]] || { echo "ERROR: --platform-id 不能为空" >&2; exit 2; }
    case "$spec:$platform_id" in
        4c8t:intel-lga2011-i7-3820-asus-p9x79|\
        4c8t:intel-lga2011-i7-3820-gigabyte-ga-x79-up4|\
        4c8t:intel-lga2011-i7-3820-asrock-x79-extreme4|\
        4c8t:intel-lga2011-i7-4820k-asus-p9x79|\
        4c8t:intel-lga2011-i7-4820k-gigabyte-ga-x79-up4|\
        4c8t:intel-lga2011-i7-4820k-asrock-x79-extreme4|\
        6c12t:intel-lga2011-i7-3930k-asus-p9x79|\
        6c12t:intel-lga2011-i7-3930k-gigabyte-ga-x79-up4|\
        6c12t:intel-lga2011-i7-3930k-asrock-x79-extreme4|\
        6c12t:intel-lga2011-i7-4930k-asus-p9x79|\
        6c12t:intel-lga2011-i7-4930k-gigabyte-ga-x79-up4|\
        6c12t:intel-lga2011-i7-4930k-asrock-x79-extreme4|\
        6c12t:intel-lga2011-i7-4960x-asus-p9x79|\
        6c12t:intel-lga2011-i7-4960x-gigabyte-ga-x79-up4|\
        6c12t:intel-lga2011-i7-4960x-asrock-x79-extreme4) ;;
        *)
            echo "ERROR: 平台 $platform_id 与规格 $spec 不匹配，或不属于审核 X79 池" >&2
            exit 2
            ;;
    esac
fi

image_root="${IMAGE_ROOT:-/home/ubuntu/images}"
vms_dir="${VMS_DIR:-${image_root%/}/vms}"
profile_path="${VM_DIR:-${vms_dir%/}/$instance}/profile"
new_identity=0
if [[ ! -s "$profile_path" ]] || (( reroll )); then
    new_identity=1
    (( platform_explicit )) || platform_id="$preferred_platform"
fi

ram_mib=""
if (( memory_explicit || new_identity )); then
    case "${memory_size^^}" in
        4G) ram_mib=4096 ;;
        8G) ram_mib=8192 ;;
        12G) ram_mib=12288 ;;
        16G) ram_mib=16384 ;;
        *) echo "ERROR: --memory-size 只能是 4G、8G、12G 或 16G" >&2; exit 2 ;;
    esac
fi

declare -a launch=("$start_vm" "$instance" "--cpus=$cpus")
[[ -z "$ram_mib" ]] || launch+=("--ram=$ram_mib")
[[ -z "$platform_id" ]] || launch+=("--platform-id=$platform_id")
launch+=("${passthrough[@]}")
exec "${launch[@]}"
