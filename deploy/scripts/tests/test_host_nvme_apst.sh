#!/usr/bin/env bash
# host-nvme-apst.sh 的隔离回归：不接触宿主机 /sys、/etc、/boot 或真实 NVMe。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../host-nvme-apst.sh"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/root"
FAKE_BIN="$TMP_DIR/bin"
STATE_DIR="$TMP_DIR/state"

cleanup() {
    if [[ "${KEEP_APST_TEST_TMP:-0}" == 1 ]]; then
        echo "保留测试目录：$TMP_DIR" >&2
    elif [[ "$TMP_DIR" == /tmp/tmp.* && -d "$TMP_DIR" ]]; then
        rm -rf -- "$TMP_DIR"
    else
        echo "拒绝清理非预期测试目录：$TMP_DIR" >&2
    fi
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    local needle="$1" file="$2"
    grep -Fq "$needle" "$file" || fail "$file 缺少：$needle"
}

make_controller() {
    local name="$1" transport="$2" model="$3" firmware="$4" speed="$5" width="$6"
    local base="$TEST_ROOT/sys/class/nvme/$name"
    mkdir -p "$base/device"
    printf '%s\n' "$transport" >"$base/transport"
    printf '%s\n' "$model" >"$base/model"
    printf '%s\n' "$firmware" >"$base/firmware_rev"
    printf '%s\n' live >"$base/state"
    printf '%s\n' "$speed" >"$base/device/current_link_speed"
    printf '%s\n' "$width" >"$base/device/current_link_width"
    : >"$TEST_ROOT/dev/$name"
}

mkdir -p "$TEST_ROOT"/{boot/grub,dev,etc/default/grub.d,etc/modprobe.d,proc} \
    "$TEST_ROOT/sys/class/nvme" \
    "$TEST_ROOT/sys/module/nvme_core/parameters" "$FAKE_BIN" "$STATE_DIR"
make_controller nvme0 pcie 'Samsung Test NVMe' S3FW '8.0 GT/s PCIe' 4
make_controller nvme1 pcie 'WD Test NVMe' W4FW '16.0 GT/s PCIe' 4
make_controller nvme2 tcp 'NVMe over Fabrics' NET1 '' ''
make_controller nvme3 pcie 'Kioxia Test NVMe' K5FW '32.0 GT/s PCIe' 4
printf '1\n' >"$STATE_DIR/nvme0"
printf '1\n' >"$STATE_DIR/nvme1"
printf '1\n' >"$STATE_DIR/nvme3"
printf '100000\n' >"$TEST_ROOT/sys/module/nvme_core/parameters/default_ps_max_latency_us"
printf '%s\n' 'quiet nvme_core.default_ps_max_latency_us=100000' >"$TEST_ROOT/proc/cmdline"
cat >"$TEST_ROOT/etc/default/grub" <<'EOF'
GRUB_CMDLINE_LINUX="iommu=pt nvme_core.default_ps_max_latency_us=2000"
GRUB_CMDLINE_LINUX_DEFAULT="quiet nvme_core.default_ps_max_latency_us=100000"
EOF
cat >"$TEST_ROOT/etc/default/grub.d/99-nvme-apst-off.cfg" <<'EOF'
# 由 qemu/deploy/scripts/host-nvme-apst.sh 管理。
GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} nvme_core.default_ps_max_latency_us=0"
EOF

cat >"$FAKE_BIN/update-grub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root="${VMATE_APST_TEST_ROOT:?}"
GRUB_CMDLINE_LINUX=""
GRUB_CMDLINE_LINUX_DEFAULT=""
[[ ! -r "$root/etc/default/grub" ]] || source "$root/etc/default/grub"
for fragment in "$root"/etc/default/grub.d/*.cfg; do
    [[ ! -e "$fragment" ]] || source "$fragment"
done
mkdir -p "$root/boot/grub"
printf 'linux /vmlinuz %s %s\n' "$GRUB_CMDLINE_LINUX" \
    "$GRUB_CMDLINE_LINUX_DEFAULT" >"$root/boot/grub/grub.cfg"
printf 'update-grub\n' >>"${FAKE_NVME_LOG:?}"
EOF

cat >"$FAKE_BIN/nvme" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
operation="${1:?}"
node="${2:?}"
name="${node##*/}"
state_file="${FAKE_NVME_STATE:?}/$name"
printf '%s %s\n' "$operation" "$name" >>"${FAKE_NVME_LOG:?}"
case "$operation" in
    get-feature)
        value="$(<"$state_file")"
        printf 'get-feature:0x0c, Current value:%08x\n' "$value"
        ;;
    set-feature)
        if [[ -e "${FAKE_NVME_STATE}/hang_$name" ]]; then
            sleep 10
        fi
        if ! grep -Fq 'nvme_core.default_ps_max_latency_us=0' \
                "${VMATE_APST_TEST_ROOT}/boot/grub/grub.cfg"; then
            echo 'set-feature happened before persistence' >&2
            exit 70
        fi
        printf '0\n' >"$state_file"
        echo 'set-feature: Success, value:0'
        ;;
    *) exit 2 ;;
esac
EOF
chmod +x "$TARGET" "$FAKE_BIN/update-grub" "$FAKE_BIN/nvme"

export VMATE_APST_TEST_ROOT="$TEST_ROOT"
export VMATE_APST_TEST_BIN="$FAKE_BIN"
export VMATE_APST_ADMIN_TIMEOUT=1
export FAKE_NVME_STATE="$STATE_DIR"
export FAKE_NVME_LOG="$TMP_DIR/nvme.log"
: >"$FAKE_NVME_LOG"

"$TARGET" check all >"$TMP_DIR/check.out"
assert_contains '/dev/nvme0：Samsung Test NVMe' "$TMP_DIR/check.out"
assert_contains 'PCIe 3.0 x4' "$TMP_DIR/check.out"
assert_contains '/dev/nvme1：WD Test NVMe' "$TMP_DIR/check.out"
assert_contains 'PCIe 4.0 x4' "$TMP_DIR/check.out"
assert_contains '/dev/nvme3：Kioxia Test NVMe' "$TMP_DIR/check.out"
assert_contains 'PCIe 5.0 x4' "$TMP_DIR/check.out"
if grep -Fq '/dev/nvme2' "$TMP_DIR/check.out"; then
    fail 'NVMe-over-Fabrics 控制器没有被排除'
fi

if "$TARGET" check /dev/nvme0n1 >"$TMP_DIR/namespace.out" 2>&1; then
    fail '命名空间被错误接受为控制器'
fi
assert_contains '不能传命名空间或分区' "$TMP_DIR/namespace.out"

: >"$FAKE_NVME_LOG"
"$TARGET" persist all >"$TMP_DIR/persist.out"
[[ ! -s "$FAKE_NVME_LOG" || "$(<"$FAKE_NVME_LOG")" == update-grub ]] ||
    fail 'persist 动作执行了 NVMe 管理命令'
[[ "$(<"$TEST_ROOT/sys/module/nvme_core/parameters/default_ps_max_latency_us")" == 100000 ]] ||
    fail 'persist 动作意外修改了运行时参数'
assert_contains 'options nvme_core default_ps_max_latency_us=0' \
    "$TEST_ROOT/etc/modprobe.d/99-nvme-apst-off.conf"
assert_contains 'nvme_core.default_ps_max_latency_us=0' \
    "$TEST_ROOT/boot/grub/grub.cfg"
if compgen -G "$TEST_ROOT/etc/default/grub.d/99-nvme-apst-off.cfg.bak.*" >/dev/null; then
    fail '迁移旧版受管片段时创建了不必要的备份'
fi
if grep -Eq 'nvme_core\.default_ps_max_latency_us=(100000|2000)' \
        "$TEST_ROOT/boot/grub/grub.cfg"; then
    fail 'GRUB 生成结果仍包含冲突的 APST 值'
fi

: >"$STATE_DIR/hang_nvme1"
: >"$FAKE_NVME_LOG"
"$TARGET" apply all >"$TMP_DIR/apply.out" 2>&1
assert_contains '持久化已完成；部分在线操作未响应' "$TMP_DIR/apply.out"
[[ "$(<"$STATE_DIR/nvme0")" == 0 ]] || fail 'nvme0 没有在线关闭'
[[ "$(<"$STATE_DIR/nvme1")" == 1 ]] || fail '超时控制器状态被错误修改'
[[ "$(<"$STATE_DIR/nvme3")" == 0 ]] || fail 'nvme1 超时后没有继续处理 nvme3'
[[ "$(<"$TEST_ROOT/sys/module/nvme_core/parameters/default_ps_max_latency_us")" == 0 ]] ||
    fail 'apply 没有更新运行时内核参数'
first_set_line="$(grep -n '^set-feature ' "$FAKE_NVME_LOG" | head -n 1 | cut -d: -f1)"
grub_line="$(grep -n '^update-grub$' "$FAKE_NVME_LOG" | head -n 1 | cut -d: -f1)"
[[ -n "$first_set_line" && -n "$grub_line" && "$grub_line" -lt "$first_set_line" ]] ||
    fail '在线设置发生在持久化之前'

rm -f "$STATE_DIR/hang_nvme1"
if "$TARGET" verify all >"$TMP_DIR/verify-fail.out" 2>&1; then
    fail '控制器仍开启且启动参数未生效时 verify 错误通过'
fi
printf '0\n' >"$STATE_DIR/nvme1"
printf '%s\n' 'quiet nvme_core.default_ps_max_latency_us=0' >"$TEST_ROOT/proc/cmdline"
"$TARGET" verify all >"$TMP_DIR/verify-pass.out"
assert_contains '验证通过' "$TMP_DIR/verify-pass.out"

EMPTY_ROOT="$TMP_DIR/empty"
mkdir -p "$EMPTY_ROOT"/{proc,sys/class/nvme}
: >"$EMPTY_ROOT/proc/cmdline"
VMATE_APST_TEST_ROOT="$EMPTY_ROOT" "$TARGET" check all >"$TMP_DIR/empty.out"
assert_contains 'SATA/SAS 不使用 NVMe APST，无需处理' "$TMP_DIR/empty.out"

echo 'PASS: generic single-file NVMe APST policy'
