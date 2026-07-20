
# ------------------------------------------------------------------
# PRNG helpers。STEALTH_SEED=integer 可固定 Bash PRNG 的初始状态，主要供测试使用。
# ------------------------------------------------------------------
_rng_init() {
    if [[ -n "${STEALTH_SEED:-}" ]]; then
        RANDOM="$STEALTH_SEED"
    fi
}
_rand() {
    local lo=$1 hi=$2 span limit value

    (( lo <= hi )) || {
        echo "ERROR: _rand 下界大于上界: $lo > $hi" >&2
        return 2
    }
    span=$(( hi - lo + 1 ))
    # 四个 RANDOM 各提供 15 bit，组合成均匀的 60-bit 非负整数。旧实现只有
    # 30 bit，面对十位 CPU/asset 范围时永远到不了 2,073,741,823 以上。
    # 拒绝采样同时消除 `% span` 在 span 不能整除 2^60 时的取模偏差。
    limit=$(( 1152921504606846976 - (1152921504606846976 % span) ))
    while :; do
        value=$(( (RANDOM << 45) | (RANDOM << 30) | (RANDOM << 15) | RANDOM ))
        if (( value < limit )); then
            printf '%s\n' "$((lo + value % span))"
            return 0
        fi
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
_hex() {
    local w=$1 out="" chunk
    (( w > 0 )) || {
        echo "ERROR: _hex 位数必须为正整数" >&2
        return 2
    }
    # 32768 可被 4096 整除，因此每次取低 12 bit 后输出 3 个十六进制字符，
    # 不会让最高位只落在 0..7，也不需要外部随机管线。
    while (( ${#out} < w )); do
        printf -v chunk '%03x' "$((RANDOM % 4096))"
        out+="$chunk"
    done
    printf '%s\n' "${out:0:$w}"
}
_serial_asus() { echo "MB-$(_hex 6 | tr a-f A-F)$(_rand 10000 99999)"; }
_serial_msi()  { echo "$(_hex 4 | tr a-f A-F)$(_rand 100000 999999)"; }
_serial_giga() { echo "SN$(_rand 10000000 99999999)"; }
_serial_asr()  { echo "M80-$(_hex 4 | tr a-f A-F)$(_rand 1000 9999)"; }
