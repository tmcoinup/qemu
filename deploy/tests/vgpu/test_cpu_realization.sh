#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LIB="$REPO_ROOT/deploy/lib/cpu-realization.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local expected=$1 actual=$2 label=$3
    [[ "$actual" == "$expected" ]] ||
        fail "$label: expected '$expected', got '$actual'"
}

mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/qemu-system-x86_64" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == --version ]]; then
    echo 'QEMU emulator version 11.0.2 (G-11 fake)'
    exit 0
fi

for spd_var in QEMU_SPD_TYPE QEMU_SPD_MODULE_MB QEMU_SPD_MODULE_MB_LIST \
        QEMU_SPD_SPEED_MT QEMU_SPD_SLOTS QEMU_SPD_RANK_LIST \
        QEMU_SPD_DEVICE_WIDTH_LIST QEMU_SPD_MODULE_MFR_JEP106_LIST \
        QEMU_SPD_DRAM_MFR_JEP106_LIST QEMU_SPD_SERIAL_LIST \
        QEMU_SPD_PART_LIST; do
    [[ ! -v "$spd_var" ]] || {
        echo "qemu-system-x86_64: leaked full-VM SPD variable: $spd_var" >&2
        exit 97
    }
done

printf '%s\n' "$*" >>"$FAKE_QEMU_LOG"

cpu_spec=
previous=
for argument in "$@"; do
    if [[ "$previous" == -cpu ]]; then
        cpu_spec=$argument
        break
    fi
    previous=$argument
done

[[ -n "$cpu_spec" ]] || {
    echo 'qemu-system-x86_64: missing -cpu' >&2
    exit 2
}

model=${cpu_spec%%,*}
case "$cpu_spec" in
    *,enforce=on) enforcement=on ;;
    *,enforce=off) enforcement=off ;;
    *)
        echo 'qemu-system-x86_64: missing enforce property' >&2
        exit 2
        ;;
esac

qmp_success() {
    echo '{"QMP":{"version":{"qemu":{"major":11,"minor":0,"micro":2}},"capabilities":[]}}'
    echo '{"return":{}}'
}

case "$model" in
    Intel-Pentium-G3220|Core-i3-4130|Core-i5-4460|Core-i5-4570|Core-i5-4590|Core-i7-4790)
        qmp_success
        ;;
    Core-i5-6500|Core-i3-8100)
        if [[ "$enforcement" == on ]]; then
            echo 'qemu-system-x86_64: warning: host doesn'\''t support requested feature: CPUID.clflushopt' >&2
            echo 'qemu-system-x86_64: Host doesn'\''t support requested features' >&2
            exit 1
        fi
        qmp_success
        ;;
    MissingModel)
        echo "qemu-system-x86_64: unable to find CPU model '$model'" >&2
        exit 1
        ;;
    KvmDown)
        echo 'qemu-system-x86_64: failed to initialize KVM: Permission denied' >&2
        exit 1
        ;;
    GenericFailure)
        echo 'qemu-system-x86_64: machine initialization failed' >&2
        exit 1
        ;;
    CompatFailure)
        if [[ "$enforcement" == on ]]; then
            echo 'qemu-system-x86_64: Host doesn'\''t support requested features' >&2
        else
            echo 'qemu-system-x86_64: compatibility realization failed' >&2
        fi
        exit 1
        ;;
    BadProtocol)
        echo 'not a QMP greeting'
        ;;
    SlowModel)
        sleep 4
        ;;
    *)
        echo "qemu-system-x86_64: unknown CPU model '$model'" >&2
        exit 1
        ;;
esac
EOF
chmod +x "$TMP_DIR/bin/qemu-system-x86_64"

export FAKE_QEMU_LOG="$TMP_DIR/qemu.log"
: >"$FAKE_QEMU_LOG"

# shellcheck source=../../lib/cpu-realization.sh
source "$LIB"

# A Broadwell-class host fully realizes every reviewed Haswell desktop CPU,
# including the distinct 2C/2T, 2C/4T and 4C/4T topologies.  Classification
# comes from QEMU/KVM, never a library-side host/model table.
for model in Intel-Pentium-G3220 Core-i3-4130 Core-i5-4460 Core-i5-4570 \
        Core-i5-4590 Core-i7-4790; do
    g11_cpu_capability_probe "$TMP_DIR/bin/qemu-system-x86_64" "$model" ||
        fail "$model enforce=on realization was rejected"
    assert_eq supported "$G11_CPU_CAPABILITY_CLASS" "$model class"
    assert_eq G11_CPU_CAP_OK_ENFORCED "$G11_CPU_CAPABILITY_REASON" \
        "$model reason"
    assert_eq 0 "$G11_CPU_CAPABILITY_ENFORCE_RC" "$model enforce rc"
done


# Full-VM SPD state inherited by a shell must never poison the fixed 64 MiB
# CPU-only probe.  The fake QEMU above rejects any leaked knob.
export QEMU_SPD_TYPE=DDR3 QEMU_SPD_MODULE_MB=4096 \
    QEMU_SPD_MODULE_MB_LIST=4096,4096 QEMU_SPD_SPEED_MT=1600 QEMU_SPD_SLOTS=2 \
    QEMU_SPD_RANK_LIST=2,1 QEMU_SPD_DEVICE_WIDTH_LIST=8,8 \
    QEMU_SPD_MODULE_MFR_JEP106_LIST=80CE,80CE \
    QEMU_SPD_DRAM_MFR_JEP106_LIST=80CE,80CE \
    QEMU_SPD_SERIAL_LIST=89ABCDEF,01234567 \
    QEMU_SPD_PART_LIST=M378B5273DH0-CK0,M378B5773DH0-CK0
g11_cpu_capability_probe "$TMP_DIR/bin/qemu-system-x86_64" Core-i5-4460 ||
    fail 'inherited SPD environment poisoned CPU realization'
unset QEMU_SPD_TYPE QEMU_SPD_MODULE_MB QEMU_SPD_MODULE_MB_LIST \
    QEMU_SPD_SPEED_MT QEMU_SPD_SLOTS QEMU_SPD_RANK_LIST \
    QEMU_SPD_DEVICE_WIDTH_LIST QEMU_SPD_MODULE_MFR_JEP106_LIST \
    QEMU_SPD_DRAM_MFR_JEP106_LIST QEMU_SPD_SERIAL_LIST QEMU_SPD_PART_LIST
assert_eq supported "$G11_CPU_CAPABILITY_CLASS" 'SPD-isolated probe class'

# Skylake/Coffee Lake profiles have feature gaps on Broadwell.  They are
# compatibility-capable only when an enforce=off realization actually works.
for model in Core-i5-6500 Core-i3-8100; do
    g11_cpu_capability_probe "$TMP_DIR/bin/qemu-system-x86_64" "$model" ||
        fail "$model compatibility realization was rejected"
    assert_eq compatibility "$G11_CPU_CAPABILITY_CLASS" "$model class"
    assert_eq G11_CPU_CAP_HOST_FEATURE_GAP "$G11_CPU_CAPABILITY_REASON" \
        "$model reason"
    assert_eq 0 "$G11_CPU_CAPABILITY_COMPAT_RC" "$model compatibility rc"
done

# New VM creation fails closed unless enforce=on worked; legacy launch keeps
# the established masked-feature policy.
g11_cpu_realization_gate "$TMP_DIR/bin/qemu-system-x86_64" \
    Core-i5-4590 new || fail 'supported new VM gate was denied'
assert_eq allow "$G11_CPU_GATE_DECISION" 'supported new decision'
assert_eq G11_CPU_GATE_ALLOW_ENFORCED "$G11_CPU_GATE_REASON" \
    'supported new gate reason'

if g11_cpu_realization_gate "$TMP_DIR/bin/qemu-system-x86_64" \
        Core-i5-6500 new; then
    fail 'compatibility-only CPU was accepted for a new VM'
fi
assert_eq compatibility "$G11_CPU_CAPABILITY_CLASS" 'new compatibility class'
assert_eq deny "$G11_CPU_GATE_DECISION" 'new compatibility decision'
assert_eq G11_CPU_GATE_NEW_REQUIRES_ENFORCED "$G11_CPU_GATE_REASON" \
    'new compatibility gate reason'

g11_cpu_realization_gate "$TMP_DIR/bin/qemu-system-x86_64" \
    Core-i5-6500 legacy || fail 'legacy compatibility policy was not preserved'
assert_eq allow "$G11_CPU_GATE_DECISION" 'legacy compatibility decision'
assert_eq G11_CPU_GATE_ALLOW_LEGACY_COMPATIBILITY "$G11_CPU_GATE_REASON" \
    'legacy compatibility gate reason'

if g11_cpu_realization_gate "$TMP_DIR/bin/qemu-system-x86_64" \
        Core-i5-4590 invalid-lifecycle; then
    fail 'invalid lifecycle was accepted'
fi
assert_eq G11_CPU_GATE_INVALID_LIFECYCLE "$G11_CPU_GATE_REASON" \
    'invalid lifecycle reason'

if g11_cpu_capability_probe "$TMP_DIR/bin/qemu-system-x86_64" \
        MissingModel; then
    fail 'missing CPU model was accepted'
fi
assert_eq unsupported "$G11_CPU_CAPABILITY_CLASS" 'missing model class'
assert_eq G11_CPU_CAP_MODEL_UNAVAILABLE "$G11_CPU_CAPABILITY_REASON" \
    'missing model reason'

if g11_cpu_capability_probe "$TMP_DIR/bin/qemu-system-x86_64" KvmDown; then
    fail 'unavailable KVM was accepted'
fi
assert_eq unavailable "$G11_CPU_CAPABILITY_CLASS" 'KVM unavailable class'
assert_eq G11_CPU_CAP_KVM_UNAVAILABLE "$G11_CPU_CAPABILITY_REASON" \
    'KVM unavailable reason'

if g11_cpu_capability_probe "$TMP_DIR/bin/qemu-system-x86_64" \
        GenericFailure; then
    fail 'generic enforced failure entered compatibility mode'
fi
assert_eq unsupported "$G11_CPU_CAPABILITY_CLASS" 'generic failure class'
assert_eq G11_CPU_CAP_ENFORCED_FAILED "$G11_CPU_CAPABILITY_REASON" \
    'generic failure reason'

if g11_cpu_capability_probe "$TMP_DIR/bin/qemu-system-x86_64" \
        CompatFailure; then
    fail 'failed enforce=off realization was accepted'
fi
assert_eq unsupported "$G11_CPU_CAPABILITY_CLASS" 'compat failure class'
assert_eq G11_CPU_CAP_COMPAT_FAILED "$G11_CPU_CAPABILITY_REASON" \
    'compat failure reason'

if g11_cpu_capability_probe "$TMP_DIR/bin/qemu-system-x86_64" BadProtocol; then
    fail 'non-QMP success was accepted'
fi
assert_eq unavailable "$G11_CPU_CAPABILITY_CLASS" 'protocol failure class'
assert_eq G11_CPU_CAP_PROBE_PROTOCOL "$G11_CPU_CAPABILITY_REASON" \
    'protocol failure reason'

G11_CPU_PROBE_TIMEOUT_SECONDS=1
if g11_cpu_capability_probe "$TMP_DIR/bin/qemu-system-x86_64" SlowModel; then
    fail 'timed-out probe was accepted'
fi
unset G11_CPU_PROBE_TIMEOUT_SECONDS
assert_eq unavailable "$G11_CPU_CAPABILITY_CLASS" 'timeout class'
assert_eq G11_CPU_CAP_PROBE_TIMEOUT "$G11_CPU_CAPABILITY_REASON" \
    'timeout reason'

before_lines=$(wc -l <"$FAKE_QEMU_LOG")
if g11_cpu_capability_probe "$TMP_DIR/bin/qemu-system-x86_64" \
        'Core-i5-4590,enforce=off'; then
    fail 'CPU option injection was accepted'
fi
after_lines=$(wc -l <"$FAKE_QEMU_LOG")
assert_eq "$before_lines" "$after_lines" 'invalid model invoked QEMU'
assert_eq G11_CPU_CAP_INVALID_MODEL "$G11_CPU_CAPABILITY_REASON" \
    'invalid model reason'

if g11_cpu_capability_probe "$TMP_DIR/bin/does-not-exist" Core-i5-4590; then
    fail 'missing QEMU executable was accepted'
fi
assert_eq G11_CPU_CAP_QEMU_UNAVAILABLE "$G11_CPU_CAPABILITY_REASON" \
    'missing QEMU reason'

printf '#!/usr/bin/env bash\necho not-qemu\n' >"$TMP_DIR/bin/not-qemu"
chmod +x "$TMP_DIR/bin/not-qemu"
if g11_cpu_capability_probe "$TMP_DIR/bin/not-qemu" Core-i5-4590; then
    fail 'non-QEMU executable was accepted'
fi
assert_eq G11_CPU_CAP_QEMU_INVALID "$G11_CPU_CAPABILITY_REASON" \
    'non-QEMU reason'

# Every real probe is paused, device-free, display-free and has no storage or
# network argument.  This is the read-only safety boundary of the probe.
while IFS= read -r invocation; do
    [[ "$invocation" == *'-nodefaults'* ]] || fail 'probe lacked -nodefaults'
    [[ "$invocation" == *'-no-user-config'* ]] || fail 'probe read user config'
    [[ "$invocation" == *'-display none'* ]] || fail 'probe enabled display'
    [[ "$invocation" == *' -S'* ]] || fail 'probe was not paused'
    [[ "$invocation" != *'-drive'* ]] || fail 'probe attached storage'
    [[ "$invocation" != *'-netdev'* ]] || fail 'probe attached networking'
done <"$FAKE_QEMU_LOG"

report=$(g11_cpu_capability_report)
[[ "$report" == *'class=unavailable'* ]] || fail 'report omitted class'
[[ "$report" == *'reason=G11_CPU_CAP_QEMU_INVALID'* ]] ||
    fail 'report omitted stable reason code'

echo 'PASS: G-11 CPU realization gate classifies enforced and legacy compatibility safely'
