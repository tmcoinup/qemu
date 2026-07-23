# shellcheck shell=bash
# ------------------------------------------------------------------
# PRNG helpers。STEALTH_SEED=integer 时使用“种子 + 调用域”的 SHA-256 取样。
#
# 不能只给 Bash RANDOM 赋初值：大多数调用位于 $(...) 子 shell 中，Bash 会为
# 子 shell 重新播种，导致同一个 STEALTH_SEED 仍不可复现。调用栈作为 domain
# 使不同硬件字段彼此独立，目录追加或选择顺序调整也不会串改其它字段。
# ------------------------------------------------------------------
_rng_init() {
    if [[ -n "${STEALTH_SEED:-}" ]]; then
        [[ "$STEALTH_SEED" =~ ^-?[0-9]+$ ]] || {
            echo "ERROR: STEALTH_SEED 必须是整数" >&2
            return 2
        }
    fi
}
_rand() {
    local lo=$1 hi=$2 span limit value digest material attempt=0

    (( lo <= hi )) || {
        echo "ERROR: _rand 下界大于上界: $lo > $hi" >&2
        return 2
    }
    span=$(( hi - lo + 1 ))
    # 四个 RANDOM 各提供 15 bit，组合成均匀的 60-bit 非负整数。旧实现只有
    # 30 bit，面对十位 CPU/asset 范围时永远到不了 2,073,741,823 以上。
    # 拒绝采样同时消除 `% span` 在 span 不能整除 2^60 时的取模偏差。
    limit=$(( 1152921504606846976 - (1152921504606846976 % span) ))
    material="${FUNCNAME[*]}|${BASH_SOURCE[*]}|${BASH_LINENO[*]}|$lo|$hi"
    while :; do
        if [[ -n "${STEALTH_SEED:-}" ]]; then
            digest="$(
                printf '%s' "$STEALTH_SEED|rand|$material|$attempt" |
                    sha256sum
            )" || return 2
            value=$((16#${digest:0:15}))
        else
            value=$(( (RANDOM << 45) | (RANDOM << 30) |
                      (RANDOM << 15) | RANDOM ))
        fi
        if (( value < limit )); then
            printf '%s\n' "$((lo + value % span))"
            return 0
        fi
        attempt=$((attempt + 1))
    done
}
_pick_array() {
    # _pick_array <array_name>  从 array 里随机取一个元素，stdout 输出
    local -n _arr=$1
    local n=${#_arr[@]}
    local i
    (( n > 0 )) || {
        echo "ERROR: _pick_array 不能从空数组选择" >&2
        return 2
    }
    i="$(_rand 0 "$((n - 1))")" || return
    echo "${_arr[$i]}"
}

_pick_weighted_rows() {
    # _pick_weighted_rows <array_name>，每行格式为 stable-id|正整数权重。
    local -n _weighted_rows=$1
    local row stable_id weight total=0 draw

    (( ${#_weighted_rows[@]} > 0 )) || {
        echo "ERROR: _pick_weighted_rows 不能从空数组选择" >&2
        return 2
    }
    for row in "${_weighted_rows[@]}"; do
        IFS='|' read -r stable_id weight <<<"$row"
        if [[ -z "$stable_id" || ! "$weight" =~ ^[1-9][0-9]*$ ]]; then
            echo "ERROR: 非法加权候选行: $row" >&2
            return 2
        fi
        total=$((total + weight))
    done
    draw="$(_rand 1 "$total")" || return
    for row in "${_weighted_rows[@]}"; do
        IFS='|' read -r stable_id weight <<<"$row"
        if (( draw <= weight )); then
            printf '%s\n' "$stable_id"
            return 0
        fi
        draw=$((draw - weight))
    done
    echo "ERROR: 加权选择内部状态越界" >&2
    return 2
}

_hex() {
    local w=$1 out="" chunk digest material attempt=0
    (( w > 0 )) || {
        echo "ERROR: _hex 位数必须为正整数" >&2
        return 2
    }
    if [[ -n "${STEALTH_SEED:-}" ]]; then
        material="${FUNCNAME[*]}|${BASH_SOURCE[*]}|${BASH_LINENO[*]}|$w"
        while (( ${#out} < w )); do
            digest="$(
                printf '%s' "$STEALTH_SEED|hex|$material|$attempt" |
                    sha256sum
            )" || return 2
            out+="${digest%% *}"
            attempt=$((attempt + 1))
        done
        printf '%s\n' "${out:0:$w}"
        return 0
    fi
    # 32768 可被 4096 整除，因此每次取低 12 bit 后输出 3 个十六进制字符，
    # 不会让最高位只落在 0..7，也不需要外部随机管线。
    while (( ${#out} < w )); do
        printf -v chunk '%03x' "$((RANDOM % 4096))"
        out+="$chunk"
    done
    printf '%s\n' "${out:0:$w}"
}

# 厂商序列号生成和校验共用一份策略，避免新 profile 与严格加载规则漂移。
_STEALTH_RNG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=stealth-board-serial.sh
source "$_STEALTH_RNG_DIR/stealth-board-serial.sh"
