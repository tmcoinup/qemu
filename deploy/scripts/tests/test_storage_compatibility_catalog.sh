#!/usr/bin/env bash
# 消费级 SATA 启动盘目录、完整组合绑定和 QEMU ATA 实例化专项测试。
# shellcheck disable=SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MANIFEST="$REPO_ROOT/deploy/hardware/storage-compatibility.json"
HELPER="$REPO_ROOT/deploy/scripts/storage-compat.py"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# shellcheck source=../stealth-lib.sh
source "$REPO_ROOT/deploy/scripts/stealth-lib.sh"
# shellcheck source=../lib/stealth-storage.sh
source "$REPO_ROOT/deploy/scripts/lib/stealth-storage.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_equal() {
    local actual="$1" expected="$2" description="$3"
    [[ "$actual" == "$expected" ]] ||
        fail "$description: actual=$actual expected=$expected"
}

test_manifest_and_exports() {
    assert_equal \
        "$(python3 "$HELPER" "$MANIFEST" validate)" \
        2026-07-19.1 "storage catalog revision"
    local -a ids=()
    mapfile -t ids < <(python3 "$HELPER" "$MANIFEST" list)
    (( ${#ids[@]} == 3 )) || fail "SATA SSD 池不是 3 个完整组合"

    local id expected_model expected_part expected_firmware
    while IFS='|' read -r id expected_model expected_part expected_firmware; do
        stealth_storage_compat_load "$id"
        assert_equal "$BOOT_STORAGE_COMPONENT_ID" "$id" "$id 稳定 ID"
        assert_equal "$BOOT_STORAGE_MANUFACTURER" Samsung "$id 厂商"
        assert_equal "$BOOT_STORAGE_MODEL" "$expected_model" "$id 型号"
        assert_equal "$BOOT_STORAGE_PART_NUMBER" "$expected_part" "$id 料号"
        assert_equal "$BOOT_STORAGE_FIRMWARE" "$expected_firmware" "$id 固件"
        assert_equal "$BOOT_STORAGE_SIZE_BYTES" 512110190592 "$id 容量"
        assert_equal "$BOOT_STORAGE_INTERFACE" "SATA 6 Gb/s" "$id 接口"
        stealth_storage_compat_binding_is_current ||
            fail "$id 无法按完整组合重建"
    done <<'EOF'
samsung-840-pro-512gb-sata|Samsung SSD 840 PRO 512GB|MZ-7PD512BW|DXM06B0Q
samsung-850-pro-512gb-sata|Samsung SSD 850 PRO 512GB|MZ-7KE512BW|EXM04B6Q
samsung-860-pro-512gb-sata|Samsung SSD 860 PRO 512GB|MZ-76P512BW|RVM02B6Q
EOF

    # revision 是持久化诊断，不参与条目事实等值；扩池后旧 VM 仍按 ID 重建。
    export BOOT_STORAGE_CATALOG_REVISION=2026-01-01.1
    stealth_storage_compat_binding_is_current ||
        fail "仅修改诊断 revision 导致合法旧条目失效"
    BOOT_STORAGE_MODEL="Samsung SSD 970 PRO 512GB"
    if stealth_storage_compat_binding_is_current; then
        fail "SATA 型号篡改没有被完整组合绑定拒绝"
    fi
}

test_manifest_mutations() {
    # 文件名含连字符，使用 importlib 从生产 helper 路径加载，避免在测试中
    # 复制一份 validator 规则。
    python3 - "$MANIFEST" "$HELPER" <<'PY'
import copy
import importlib.util
import pathlib
import sys

manifest_path = pathlib.Path(sys.argv[1])
helper_path = pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("storage_compat", helper_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
root = module.load_manifest(manifest_path)


def rejected(label, mutate):
    damaged = copy.deepcopy(root)
    mutate(damaged)
    try:
        module.validate_manifest(damaged)
    except ValueError:
        return
    raise SystemExit(f"mutation unexpectedly accepted: {label}")


rejected("cross-series part", lambda x: x["profiles"][0].__setitem__(
    "part_number", x["profiles"][1]["part_number"]))
rejected("wrong firmware", lambda x: x["profiles"][1].__setitem__(
    "firmware", "RVM02B6Q"))
rejected("wrong stable id", lambda x: x["profiles"][2].__setitem__(
    "id", "samsung-860-pro-other"))
rejected("no SATA2 fallback", lambda x: x["profiles"][0].__setitem__(
    "compatible_link_rates_gbps", [6]))
rejected("overstated capture", lambda x: x["profiles"][0].__setitem__(
    "identity_fidelity", "device-captured"))
rejected("non-official source", lambda x: x["profiles"][0].__setitem__(
    "source_refs", ["https://example.com/product", "https://example.com/firmware"]))
rejected("duplicate bundle", lambda x: x["profiles"].__setitem__(
    1, copy.deepcopy(x["profiles"][0])))
rejected("unknown field", lambda x: x["profiles"][0].__setitem__("typo", 1))
print("mutation checks passed")
PY
}

test_uniform_picker_uses_legal_ids() {
    local seed selected
    local -A seen=()
    for seed in $(seq 1 60); do
        export STEALTH_SEED="$seed"
        _rng_init
        selected="$(stealth_storage_compat_pick_id)"
        case "$selected" in
            samsung-840-pro-512gb-sata|\
            samsung-850-pro-512gb-sata|\
            samsung-860-pro-512gb-sata)
                seen["$selected"]=1
                ;;
            *) fail "随机选择返回目录外 ID: $selected" ;;
        esac
    done
    (( ${#seen[@]} == 3 )) || fail "多 seed 没有覆盖 3 个合法 SATA 条目"
}

test_all_sata_profiles_build_and_realize() (
    export DISK="$TMP_DIR/storage.qcow2"
    export BOOT_STORAGE_SERIAL=S123456789ABCDE
    stealth_platform_registry_load compat-haswell-i5-4570-h81 4

    local id expected_firmware serial strict
    while IFS='|' read -r id expected_firmware; do
        stealth_storage_compat_load "$id"
        stealth_build_boot_storage_args
        [[ "${BOOT_STORAGE_ARGS[*]}" == *"ide-hd,bus=ide.2,unit=0"* &&
           "${BOOT_STORAGE_ARGS[*]}" == *"model=${BOOT_STORAGE_MODEL}"* &&
           "${BOOT_STORAGE_ARGS[*]}" == *"ver=${expected_firmware}"* &&
           "${BOOT_STORAGE_ARGS[*]}" != *"nvmectl0"* ]] ||
            fail "$id 没有生成独立 SATA/AHCI 启动设备"
    done <<'EOF'
samsung-840-pro-512gb-sata|DXM06B0Q
samsung-850-pro-512gb-sata|EXM04B6Q
samsung-860-pro-512gb-sata|RVM02B6Q
EOF

    stealth_storage_compat_load samsung-860-pro-512gb-sata
    for serial in \
        S123456789ABCDE \
        S123N123456789 \
        S1234567890N; do
        export BOOT_STORAGE_SERIAL="$serial"
        stealth_build_boot_storage_args ||
            fail "安全 BOOT_STORAGE_SERIAL 被运行时门禁拒绝: $serial"
    done

    for strict in 0 1; do
        export STRICT_HARDWARE="$strict"
        export BOOT_STORAGE_SERIAL='S123456789ABCDE,model=Injected'
        if stealth_build_boot_storage_args >/dev/null 2>&1; then
            fail "STRICT_HARDWARE=$strict 接受了逗号属性注入"
        fi
        (( ${#BOOT_STORAGE_ARGS[@]} == 0 )) ||
            fail "非法序号失败后仍残留启动盘 argv"
    done
    export BOOT_STORAGE_SERIAL=S123456789ABCDE

    local qemu="$REPO_ROOT/build/qemu-system-x86_64"
    local qemu_img="$REPO_ROOT/build/qemu-img"
    [[ -x "$qemu" && -x "$qemu_img" ]] || return 0
    "$qemu_img" create -q -f qcow2 "$DISK" 16M
    "$qemu_img" create -q -f raw "$TMP_DIR/windows.iso" 2M
    "$qemu_img" create -q -f raw "$TMP_DIR/virtio-win.iso" 2M
    "$qemu_img" create -q -f raw "$TMP_DIR/chainload.img" 2M
    local -a install_media_args=(
        -drive "file=$TMP_DIR/chainload.img,if=none,id=cdhelp,format=raw,readonly=on"
        -device "virtio-blk,drive=cdhelp,bootindex=1"
        -drive "file=$TMP_DIR/windows.iso,media=cdrom,if=none,id=cd0,format=raw,readonly=on"
        -device "ide-cd,drive=cd0,bus=ide.0,unit=0,bootindex=2"
        -drive "file=$TMP_DIR/virtio-win.iso,media=cdrom,if=none,id=cd1,format=raw,readonly=on"
        -device "ide-cd,drive=cd1,bus=ide.1,unit=0"
    )
    local output
    for id in \
        samsung-840-pro-512gb-sata \
        samsung-850-pro-512gb-sata \
        samsung-860-pro-512gb-sata; do
        stealth_storage_compat_load "$id"
        stealth_build_boot_storage_args
        output="$(
            printf '%s\n' \
                '{"execute":"qmp_capabilities"}' \
                '{"execute":"quit","id":"sata-done"}' |
                timeout 8 "$qemu" \
                    -machine q35,accel=tcg -nodefaults -display none \
                    -qmp stdio "${BOOT_STORAGE_ARGS[@]}" \
                    "${install_media_args[@]}" 2>&1
        )" || fail "$id 无法由 QEMU 实例化: $output"
        grep -F '"id": "sata-done"' <<<"$output" >/dev/null ||
            fail "$id 未完成 QMP realize"
    done
)

test_manifest_and_exports
test_manifest_mutations
test_uniform_picker_uses_legal_ids
test_all_sata_profiles_build_and_realize
echo "OK: storage compatibility catalog and SATA boot bindings passed"
