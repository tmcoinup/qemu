
# ------------------------------------------------------------------
# PRNG helpers. STEALTH_SEED=integer 可启用确定性重放。
# ------------------------------------------------------------------
_rng_init() {
    if [[ -n "${STEALTH_SEED:-}" ]]; then
        RANDOM="$STEALTH_SEED"
    fi
}
_rand() {
    local lo=$1 hi=$2
    echo $(( (RANDOM * 32768 + RANDOM) % (hi - lo + 1) + lo ))
}
_pick_array() {
    # _pick_array <array_name>  从 array 里随机取一个元素，stdout 输出
    local -n _arr=$1
    local n=${#_arr[@]}
    local i=$(( (RANDOM * 32768 + RANDOM) % n ))
    echo "${_arr[$i]}"
}
_hex() {
    local w=$1 out=""
    while (( ${#out} < w )); do
        out+=$(printf "%04x" $((RANDOM ^ (RANDOM<<8) ^ (RANDOM<<16) )) )
    done
    echo "${out:0:$w}"
}
_serial_asus() { echo "MB-$(_hex 6 | tr a-f A-F)$(_rand 10000 99999)"; }
_serial_msi()  { echo "$(_hex 4 | tr a-f A-F)$(_rand 100000 999999)"; }
_serial_giga() { echo "SN$(_rand 10000000 99999999)"; }
_serial_asr()  { echo "M80-$(_hex 4 | tr a-f A-F)$(_rand 1000 9999)"; }

