#!/bin/bash
# ---------------------------------------------------------------------------
# host-performance.sh
#
# Once-per-boot host tuning for the stealth VMs. Requires sudo.
# Run before launching win10-ryzen3-stealth.sh.
# ---------------------------------------------------------------------------
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "rerunning with sudo..."
    exec sudo -E bash "$0" "$@"
fi

# CPU governor -> performance on every policy
for p in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -w "$p" ]] && echo performance > "$p"
done

# Huge pages (2 MiB pages; reserve 8 GiB * max instances you plan to launch).
# Skip silently if /proc/sys/vm/nr_hugepages isn't writable.
if [[ -w /proc/sys/vm/nr_hugepages ]]; then
    # Default 8 GiB * 4 VMs = 16384 pages of 2 MiB
    : "${HUGEPAGES:=16384}"
    echo "$HUGEPAGES" > /proc/sys/vm/nr_hugepages
    echo ">> reserved $HUGEPAGES 2MiB hugepages ($(( HUGEPAGES*2 )) MiB)"
fi

# Disable transparent hugepage defrag jitter (still allow madvise)
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo never    > /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || true

# KVM halt poll: bigger window reduces vCPU wakeup latency
if [[ -w /sys/module/kvm/parameters/halt_poll_ns ]]; then
    echo 500000 > /sys/module/kvm/parameters/halt_poll_ns
fi

# Stop irqbalance (pin IRQs manually for the VM if you need determinism).
systemctl stop irqbalance 2>/dev/null || true

# NVMe: switch scheduler to 'none' so qcow2 I/O stays predictable.
for d in /sys/block/nvme*n*/queue/scheduler; do
    [[ -w "$d" ]] && echo none > "$d"
done

# Optional: disable mitigations inside KVM guests (still leaves host mitigations).
# Commenting out because it increases detection risk if guests check IA32_ARCH_CAP.
# echo 1 > /sys/module/kvm/parameters/mitigations 2>/dev/null || true

echo "host tuned."
