#!/usr/bin/env bash
# 验证 QEMU 精确信任清单 ABI：旧单项兼容、多项共存、陈旧项隔离、严格格式、
# 有界 upsert/remove，以及同目录原子发布。测试只操作临时目录，不修改宿主安装。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"
TRUST_LIBRARY="$REPO_ROOT/deploy/scripts/qemu-trust-manifest.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" message="$3"
    [[ "$actual" == "$expected" ]] \
        || fail "$message: expected='$expected' actual='$actual'"
}

assert_parse_rejected() {
    local manifest="$1" message="$2"
    if qemu_trust_manifest_parse_file "$manifest"; then
        fail "$message"
    fi
    [[ -n "$QEMU_TRUST_ERROR" ]] || fail "$message：缺少明确错误原因"
}

snapshot_executable() {
    local executable="$1" metadata digest
    SNAPSHOT_PATH="$(realpath -e -- "$executable")" || fail "无法规范化 fixture"
    metadata="$(stat -Lc '%d %i' -- "$SNAPSHOT_PATH")"
    read -r SNAPSHOT_DEVICE SNAPSHOT_INODE <<< "$metadata"
    digest="$(sha256sum -- "$SNAPSHOT_PATH")"
    SNAPSHOT_SHA256="${digest%% *}"
    [[ "$SNAPSHOT_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail "fixture 摘要格式非法"
}

append_snapshot_record() {
    local executable="$1" manifest="$2"
    snapshot_executable "$executable"
    {
        printf 'path=%s\n' "$SNAPSHOT_PATH"
        printf 'sha256=%s\n' "$SNAPSHOT_SHA256"
        printf 'device=%s\n' "$SNAPSHOT_DEVICE"
        printf 'inode=%s\n' "$SNAPSHOT_INODE"
    } >> "$manifest"
}

append_raw_record() {
    local manifest="$1" path="$2" sha256="$3" device="$4" inode="$5"
    {
        printf 'path=%s\n' "$path"
        printf 'sha256=%s\n' "$sha256"
        printf 'device=%s\n' "$device"
        printf 'inode=%s\n' "$inode"
    } >> "$manifest"
}

make_executable() {
    local source="$1" destination="$2"
    mkdir -p -- "${destination%/*}"
    cp -- "$source" "$destination"
    chmod 0755 "$destination"
}

tmp="$(mktemp -d)"
cleanup() {
    chmod 0755 "$tmp/read-only" 2>/dev/null || true
    rm -rf -- "$tmp"
}
trap cleanup EXIT

# shellcheck source=../qemu-trust-manifest.sh
source "$TRUST_LIBRARY"

owner="$(id -u)"
group="$(id -g)"
zeros="$(printf '%064d' 0)"
ones="$(printf '%064d' 1)"
qemu_a="$tmp/installed QEMU/qemu-system-x86_64"
qemu_b="$tmp/development/qemu-system-x86_64"
qemu_c="$tmp/third/qemu-system-x86_64"
make_executable /bin/true "$qemu_a"
make_executable /bin/false "$qemu_b"
make_executable /bin/echo "$qemu_c"

test_legacy_single_record() {
    local manifest="$tmp/legacy.conf" hardlink="$tmp/legacy-hardlink.conf"
    local symlink="$tmp/legacy-symlink.conf"

    : > "$manifest"
    append_snapshot_record "$qemu_a" "$manifest"
    chmod 0644 "$manifest"
    local expected_path="$SNAPSHOT_PATH" expected_sha="$SNAPSHOT_SHA256"
    local expected_device="$SNAPSHOT_DEVICE" expected_inode="$SNAPSHOT_INODE"

    qemu_trust_manifest_load_checked "$manifest" "$owner" "$group" 644 \
        || fail "旧四行单记录无法加载: $QEMU_TRUST_ERROR"
    assert_eq 1 "$(qemu_trust_manifest_count)" "旧单记录计数错误"
    assert_eq "$expected_path" "${QEMU_TRUST_PATHS[0]}" "旧单记录 path 错误"
    assert_eq "$expected_sha" "${QEMU_TRUST_SHA256S[0]}" "旧单记录 sha256 错误"
    assert_eq "$expected_device" "${QEMU_TRUST_DEVICES[0]}" "旧单记录 device 错误"
    assert_eq "$expected_inode" "${QEMU_TRUST_INODES[0]}" "旧单记录 inode 错误"
    qemu_trust_manifest_has_live_record || fail "旧单记录未被识别为有效项"
    qemu_trust_manifest_find_path "$expected_path" || fail "无法按 path 查找旧记录"
    assert_eq 0 "$QEMU_TRUST_MATCH_INDEX" "旧记录 path 索引错误"

    chmod 0600 "$manifest"
    if qemu_trust_manifest_load_checked "$manifest" "$owner" "$group" 644; then
        fail "checked loader 接受了错误 mode"
    fi
    chmod 0644 "$manifest"
    ln "$manifest" "$hardlink"
    if qemu_trust_manifest_load_checked "$manifest" "$owner" "$group" 644; then
        fail "checked loader 接受了多硬链接 manifest"
    fi
    rm -f -- "$hardlink"
    ln -s "$manifest" "$symlink"
    if qemu_trust_manifest_load_checked "$symlink" "$owner" "$group" 644; then
        fail "checked loader 接受了符号链接 manifest"
    fi
    return 0
}

test_multiple_and_stale_records() {
    local manifest="$tmp/multi.conf" missing="$tmp/retired/qemu-system-x86_64"
    local all_stale="$tmp/all-stale.conf" tampered="$tmp/tampered.conf"

    : > "$manifest"
    append_raw_record "$manifest" "$missing" "$zeros" 1 1
    append_snapshot_record "$qemu_a" "$manifest"
    local live_path="$SNAPSHOT_PATH"
    append_snapshot_record "$qemu_b" "$manifest"
    chmod 0644 "$manifest"

    qemu_trust_manifest_parse_file "$manifest" \
        || fail "多记录 manifest 无法解析: $QEMU_TRUST_ERROR"
    assert_eq 3 "$(qemu_trust_manifest_count)" "多记录计数错误"
    qemu_trust_manifest_record_is_live 0 && fail "不存在的记录被判为有效"
    qemu_trust_manifest_record_is_live 1 || fail "陈旧项阻断了第一项有效记录"
    qemu_trust_manifest_record_is_live 2 || fail "陈旧项阻断了第二项有效记录"
    qemu_trust_manifest_has_live_record || fail "stale+live manifest 被整体判为失效"
    qemu_trust_manifest_find_path "$live_path" || fail "多记录无法按路径选择"
    assert_eq 1 "$QEMU_TRUST_MATCH_INDEX" "多记录 path 选择了错误记录"
    qemu_trust_manifest_record_is_live 99 && fail "越界记录索引被接受"

    : > "$all_stale"
    append_raw_record "$all_stale" "$missing" "$zeros" 1 1
    append_raw_record "$all_stale" "$tmp/retired-two/qemu-system-x86_64" "$ones" 2 2
    qemu_trust_manifest_parse_file "$all_stale" \
        || fail "结构合法的全陈旧 manifest 无法解析"
    if qemu_trust_manifest_has_live_record; then
        fail "全陈旧 manifest 被判为至少含一个有效项"
    fi

    : > "$tampered"
    snapshot_executable "$qemu_a"
    append_raw_record "$tampered" "$SNAPSHOT_PATH" "$ones" \
        "$SNAPSHOT_DEVICE" "$SNAPSHOT_INODE"
    qemu_trust_manifest_parse_file "$tampered" || fail "篡改 tuple 应保持结构可解析"
    if qemu_trust_manifest_has_live_record; then
        fail "sha256 篡改记录被判为有效"
    fi
    return 0
}

test_malformed_duplicate_and_bounds() {
    local bad="$tmp/bad.conf" over_records="$tmp/over-records.conf"
    local oversized="$tmp/oversized.conf" u64="$tmp/u64.conf" index
    local -a malformed=(
        $'\n'
        $'path=/x\ndevice=1\nsha256=0000000000000000000000000000000000000000000000000000000000000000\ninode=1\n'
        $'path=/x\nsha256=0000000000000000000000000000000000000000000000000000000000000000\ndevice=1\n'
        $'unknown=value\n'
        $'path=relative\nsha256=0000000000000000000000000000000000000000000000000000000000000000\ndevice=1\ninode=1\n'
        $'path=/x\nsha256=BAD\ndevice=1\ninode=1\n'
        $'path=/x\nsha256=0000000000000000000000000000000000000000000000000000000000000000\ndevice=x\ninode=1\n'
    )

    for index in "${!malformed[@]}"; do
        printf '%s' "${malformed[$index]}" > "$bad"
        assert_parse_rejected "$bad" "非法格式 #$index 被接受"
    done

    : > "$bad"
    append_raw_record "$bad" "$tmp/duplicate/qemu-system-x86_64" "$zeros" 1 1
    append_raw_record "$bad" "$tmp/duplicate/qemu-system-x86_64" "$ones" 2 2
    assert_parse_rejected "$bad" "重复 path 被接受"

    # Bash 只有有符号机器字长，不能用算术扩展验证完整 u64；ABI 必须精确接受
    # 2^64-1，同时拒绝溢出值和非规范前导零，与 Rust 消费端 parse<u64> 对齐。
    : > "$u64"
    append_raw_record "$u64" "$tmp/u64-max/qemu-system-x86_64" "$zeros" \
        18446744073709551615 18446744073709551615
    qemu_trust_manifest_parse_file "$u64" \
        || fail "u64 最大值被错误拒绝: $QEMU_TRUST_ERROR"
    assert_eq 18446744073709551615 "${QEMU_TRUST_DEVICES[0]}" "u64 device 最大值变化"
    assert_eq 18446744073709551615 "${QEMU_TRUST_INODES[0]}" "u64 inode 最大值变化"
    : > "$u64"
    append_raw_record "$u64" "$tmp/u64-overflow/qemu-system-x86_64" "$zeros" \
        18446744073709551616 1
    assert_parse_rejected "$u64" "超过 u64 的 device 被接受"
    : > "$u64"
    append_raw_record "$u64" "$tmp/u64-leading-zero/qemu-system-x86_64" "$zeros" 01 1
    assert_parse_rejected "$u64" "带前导零的 device 被接受"

    : > "$over_records"
    for ((index=0; index<=VMATE_QEMU_TRUST_MAX_RECORDS; index++)); do
        append_raw_record "$over_records" "$tmp/missing-$index/qemu-system-x86_64" \
            "$zeros" 1 "$((index + 1))"
    done
    assert_parse_rejected "$over_records" "超过记录数上限的 manifest 被接受"

    truncate -s "$((VMATE_QEMU_TRUST_MAX_BYTES + 1))" "$oversized"
    assert_parse_rejected "$oversized" "超过字节上限的 manifest 被接受"

    : > "$bad"
    qemu_trust_manifest_parse_file "$bad" || fail "空 manifest 应可表示注销后的零记录"
    assert_eq 0 "$(qemu_trust_manifest_count)" "空 manifest 计数错误"
    qemu_trust_manifest_has_live_record && fail "空 manifest 被判为有效"
    return 0
}

test_upsert_union_replacement_and_cleanup() {
    local manifest="$tmp/upsert.conf" stale="$tmp/obsolete/qemu-system-x86_64"
    local path_a sha_a inode_a path_b
    local path_c sha_c device_c inode_c replacement="$tmp/qemu-a-replacement"

    : > "$manifest"
    append_snapshot_record "$qemu_a" "$manifest"
    path_a="$SNAPSHOT_PATH"; sha_a="$SNAPSHOT_SHA256"
    inode_a="$SNAPSHOT_INODE"
    append_snapshot_record "$qemu_b" "$manifest"
    path_b="$SNAPSHOT_PATH"
    append_raw_record "$manifest" "$stale" "$zeros" 8 9
    chmod 0644 "$manifest"

    snapshot_executable "$qemu_c"
    path_c="$SNAPSHOT_PATH"; sha_c="$SNAPSHOT_SHA256"
    device_c="$SNAPSHOT_DEVICE"; inode_c="$SNAPSHOT_INODE"
    qemu_trust_manifest_prepare_upsert "$manifest" "$owner" "$group" \
        "$path_c" "$sha_c" "$device_c" "$inode_c" \
        || fail "多路径 upsert 失败: $QEMU_TRUST_ERROR"
    assert_eq 3 "$(qemu_trust_manifest_count)" "upsert 未保留两项有效记录或未清陈旧项"
    assert_eq "$path_a" "${QEMU_TRUST_PATHS[0]}" "upsert 改变既有记录顺序"
    assert_eq "$path_b" "${QEMU_TRUST_PATHS[1]}" "upsert 未保留第二项有效记录"
    assert_eq "$path_c" "${QEMU_TRUST_PATHS[2]}" "upsert 未追加新记录"
    [[ " ${QEMU_TRUST_PATHS[*]} " != *" $stale "* ]] || fail "upsert 未清除陈旧记录"

    # 用原子 rename 模拟同路径 QEMU 升级；旧 inode/摘要必须被新 tuple 精确替换，
    # 其它仍有效路径继续保留。
    cp /bin/false "$replacement"
    chmod 0755 "$replacement"
    mv -fT -- "$replacement" "$qemu_a"
    snapshot_executable "$qemu_a"
    [[ "$SNAPSHOT_INODE" != "$inode_a" || "$SNAPSHOT_SHA256" != "$sha_a" ]] \
        || fail "同路径替换 fixture 未改变身份"
    qemu_trust_manifest_render > "$manifest"
    chmod 0644 "$manifest"
    qemu_trust_manifest_prepare_upsert "$manifest" "$owner" "$group" \
        "$SNAPSHOT_PATH" "$SNAPSHOT_SHA256" "$SNAPSHOT_DEVICE" "$SNAPSHOT_INODE" \
        || fail "同路径 upsert 失败: $QEMU_TRUST_ERROR"
    assert_eq 3 "$(qemu_trust_manifest_count)" "同路径 upsert 改变记录总数"
    qemu_trust_manifest_find_path "$path_a" || fail "同路径 upsert 丢失目标 path"
    assert_eq "$SNAPSHOT_SHA256" "${QEMU_TRUST_SHA256S[$QEMU_TRUST_MATCH_INDEX]}" \
        "同路径 upsert 未替换摘要"
    assert_eq "$SNAPSHOT_INODE" "${QEMU_TRUST_INODES[$QEMU_TRUST_MATCH_INDEX]}" \
        "同路径 upsert 未替换 inode"
    return 0
}

test_remove_and_atomic_write() {
    local manifest="$tmp/remove-source.conf" destination="$tmp/published.conf"
    local expected="$tmp/expected.conf" old_inode new_inode victim="$tmp/victim"

    : > "$manifest"
    append_snapshot_record "$qemu_a" "$manifest"
    local path_a="$SNAPSHOT_PATH"
    append_snapshot_record "$qemu_b" "$manifest"
    local path_b="$SNAPSHOT_PATH"
    qemu_trust_manifest_parse_file "$manifest" || fail "remove fixture 无法解析"

    qemu_trust_manifest_remove_path "$path_a" || fail "remove 命中路径失败"
    assert_eq 1 "$QEMU_TRUST_REMOVED" "remove 命中没有报告 removed=1"
    assert_eq 1 "$(qemu_trust_manifest_count)" "remove 命中后的计数错误"
    assert_eq "$path_b" "${QEMU_TRUST_PATHS[0]}" "remove 删除了错误记录"
    qemu_trust_manifest_remove_path "$tmp/not-registered" || fail "remove 未命中失败"
    assert_eq 0 "$QEMU_TRUST_REMOVED" "remove 未命中错误报告 removed=1"
    assert_eq 1 "$(qemu_trust_manifest_count)" "remove 未命中改变了记录"

    printf 'old\n' > "$destination"
    chmod 0600 "$destination"
    old_inode="$(stat -Lc '%i' -- "$destination")"
    qemu_trust_manifest_render > "$expected"
    qemu_trust_manifest_write_atomic "$destination" "$owner" "$group" 644 \
        || fail "原子发布失败: $QEMU_TRUST_ERROR"
    new_inode="$(stat -Lc '%i' -- "$destination")"
    [[ "$new_inode" != "$old_inode" ]] || fail "原子发布没有通过 rename 替换 inode"
    cmp -s "$expected" "$destination" || fail "原子发布内容与 render 不一致"
    assert_eq "$owner:$group:644:1" \
        "$(stat -Lc '%u:%g:%a:%h' -- "$destination")" "原子发布元数据错误"
    ! compgen -G "$tmp/.qemu-vmate-cpu-trust.*" >/dev/null \
        || fail "原子发布遗留了 staging 文件"

    # destination 是 symlink 时 rename 必须替换链接本身，不能跟随并覆盖 victim。
    printf 'DO-NOT-CHANGE\n' > "$victim"
    rm -f -- "$destination"
    ln -s "$victim" "$destination"
    qemu_trust_manifest_write_atomic "$destination" "$owner" "$group" 644 \
        || fail "原子发布无法安全替换 symlink 目录项"
    [[ ! -L "$destination" && "$(<"$victim")" == DO-NOT-CHANGE ]] \
        || fail "原子发布跟随 symlink 修改了 victim"

    qemu_trust_manifest_remove_path "$path_b" || fail "remove 最后一项失败"
    assert_eq 1 "$QEMU_TRUST_REMOVED" "remove 最后一项未报告命中"
    assert_eq 0 "$(qemu_trust_manifest_count)" "remove 最后一项后未变为空清单"
    qemu_trust_manifest_write_atomic "$destination" "$owner" "$group" 644 \
        || fail "无法原子发布空 manifest"
    [[ ! -s "$destination" ]] || fail "零记录 manifest 不是空文件"
    return 0
}

test_legacy_single_record
test_multiple_and_stale_records
test_malformed_duplicate_and_bounds
test_upsert_union_replacement_and_cleanup
test_remove_and_atomic_write

bash -n "$TRUST_LIBRARY" "$0"
echo "PASS: QEMU trust manifest legacy/multi/stale/upsert/remove/atomic contract"
