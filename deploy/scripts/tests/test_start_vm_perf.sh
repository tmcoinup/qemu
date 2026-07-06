#!/usr/bin/env bash
# Validate the launcher-side storage path without booting a guest.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"
QEMU="${QEMU:-$REPO_ROOT/build/qemu-system-x86_64}"
QEMU_IMG="${QEMU_IMG:-$REPO_ROOT/build/qemu-img}"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_executable() {
    local path="$1"
    [[ -x "$path" ]] || fail "missing executable: $path"
}

qmp_quit() {
    local sock="$1"
    python3 - "$sock" <<'PY'
import socket
import sys
import time

sock_path = sys.argv[1]
client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
for _ in range(50):
    try:
        client.connect(sock_path)
        break
    except FileNotFoundError:
        time.sleep(0.1)
else:
    raise SystemExit("QMP socket did not appear")

# QMP sends a greeting first; read it before enabling capabilities.
client.recv(4096)
client.sendall(b'{"execute":"qmp_capabilities","id":"caps"}\n')
client.recv(4096)
client.sendall(b'{"execute":"quit","id":"quit"}\n')
client.settimeout(2.0)
try:
    while True:
        data = client.recv(4096)
        if not data or b'"id":"quit"' in data or b'"id": "quit"' in data:
            break
except TimeoutError:
    pass
client.close()
PY
}

test_dry_run_has_safe_nvme_storage() {
    local out="$1"
    local nvme_line

    DRY_RUN=1 TPM=0 HOST_TUNE=0 INSTANCE=9876 \
        "$START_VM" --no-sdl --no-fb-shm --no-bridge > "$out"

    nvme_line="$(grep -F -- "nvme,id=nvmectl0" "$out" || true)"
    [[ "$nvme_line" != *"iothread=io1"* ]] \
        || fail "dry-run argv must not bind emulated nvme to iothread"
    grep -Fx -- "iothread,id=io1" "$out" >/dev/null \
        && fail "dry-run argv must not create unused nvme iothread"
    [[ "$nvme_line" == *"use-samsung-id=on"* ]] \
        || fail "dry-run argv lost Samsung NVMe identity"
    [[ "$nvme_line" == *"model-number=Samsung"* && "$nvme_line" == *"firmware-rev="* ]] \
        || fail "dry-run argv lost model/firmware spoofing"
    [[ "$nvme_line" == *"serial="* ]] \
        || fail "dry-run argv lost NVMe serial"
}

test_qemu_accepts_samsung_nvme() {
    local img="$1"
    local sock="$2"
    local err="$3"
    local qemu_pid=""

    "$QEMU_IMG" create -q -f qcow2 "$img" 64M
    "$QEMU" \
        -machine q35,accel=tcg \
        -nodefaults \
        -display none \
        -S \
        -drive file="$img",if=none,id=nvm0,format=qcow2,cache=none,aio=threads \
        -device pcie-root-port,id=rp1,bus=pcie.0,slot=1 \
        -device nvme,id=nvmectl0,bus=rp1,drive=nvm0,use-samsung-id=on,serial=test123,model-number="Samsung SSD 970 EVO 1TB",firmware-rev=1B2QEXE7 \
        -qmp unix:"$sock",server=on,wait=off \
        2> "$err" &
    qemu_pid=$!

    for _ in $(seq 1 50); do
        [[ -S "$sock" ]] && break
        kill -0 "$qemu_pid" 2>/dev/null || {
            sed -n '1,80p' "$err" >&2
            fail "qemu exited before QMP became ready"
        }
        sleep 0.1
    done

    [[ -S "$sock" ]] || fail "qemu did not create QMP socket"
    qmp_quit "$sock"
    wait "$qemu_pid"

    if [[ -s "$err" ]]; then
        sed -n '1,80p' "$err" >&2
        fail "qemu emitted stderr while accepting Samsung nvme identity"
    fi
}

test_qmp_multi_accepts_two_clients() {
    local sock="$1"
    local err="$2"
    local qemu_pid=""

    "$QEMU" \
        -machine q35,accel=tcg \
        -nodefaults \
        -display none \
        -S \
        -qmp unix:"$sock",server=on,wait=off,multi=on \
        2> "$err" &
    qemu_pid=$!

    python3 - "$sock" <<'PY'
import json
import socket
import sys
import time

sock_path = sys.argv[1]

def connect_qmp(name):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    for _ in range(50):
        try:
            client.connect(sock_path)
            break
        except FileNotFoundError:
            time.sleep(0.1)
    else:
        raise SystemExit(f"{name}: QMP socket did not appear")
    stream = client.makefile("rwb", buffering=0)
    greeting = json.loads(stream.readline())
    assert "QMP" in greeting, greeting
    stream.write(json.dumps({
        "execute": "qmp_capabilities",
        "id": f"{name}-caps",
    }).encode() + b"\n")
    caps = json.loads(stream.readline())
    assert caps.get("id") == f"{name}-caps", caps
    assert "return" in caps, caps
    return client, stream

c1, s1 = connect_qmp("c1")
c2, s2 = connect_qmp("c2")

s1.write(b'{"execute":"query-status","id":"one"}\n')
s2.write(b'{"execute":"query-status","id":"two"}\n')
r1 = json.loads(s1.readline())
r2 = json.loads(s2.readline())
assert r1.get("id") == "one" and "return" in r1, r1
assert r2.get("id") == "two" and "return" in r2, r2

s1.write(b'{"execute":"quit","id":"quit"}\n')
c2.close()
c1.close()
PY

    wait "$qemu_pid"

    if [[ -s "$err" ]]; then
        sed -n '1,80p' "$err" >&2
        fail "qemu emitted stderr while serving multi-client QMP"
    fi
}

test_proxy_dry_run_uses_native_qmp_multi() {
    local out="$1"

    DRY_RUN=1 TPM=0 HOST_TUNE=0 INSTANCE=9878 PROXY=1 \
        "$START_VM" --no-sdl --no-fb-shm --no-bridge > "$out"

    grep -Fx -- "unix:/tmp/qemu-stealth-9878.qmp,server=on,wait=off,multi=on" "$out" >/dev/null \
        || fail "dry-run --proxy did not enable native QMP multi=on"
}

test_custom_image_root_dry_run() {
    local root="$1"
    local out="$2"
    local disk_path="$root/vms/9877/disk.qcow2"

    IMAGE_ROOT="$root" DRY_RUN=1 TPM=0 HOST_TUNE=0 INSTANCE=9877 \
        "$START_VM" --no-sdl --no-fb-shm --no-bridge > "$out"

    grep -F -- "$disk_path" "$out" >/dev/null \
        || fail "dry-run did not honor IMAGE_ROOT for disk path"
    grep -F -- "/home/ubuntu/images/vms/9877" "$out" >/dev/null \
        && fail "dry-run leaked default image root with custom IMAGE_ROOT"
    [[ ! -e "$root/vms" ]] \
        || fail "dry-run created VM directory under custom IMAGE_ROOT"
}

test_qemu_service_cpu_flags_dry_run() {
    local out="$1"

    DRY_RUN=1 TPM=0 HOST_TUNE=0 INSTANCE=9879 \
        "$START_VM" --no-sdl --no-fb-shm --no-bridge --svc-cpu > "$out"

    DRY_RUN=1 TPM=0 HOST_TUNE=0 INSTANCE=9880 \
        "$START_VM" --no-sdl --no-fb-shm --no-bridge --svc-cpus=2 > "$out"

    DRY_RUN=1 TPM=0 HOST_TUNE=0 INSTANCE=9881 \
        "$START_VM" --no-sdl --no-fb-shm --no-bridge --no-svc-cpus > "$out"

    QEMU_SVC_CPUS=1 DRY_RUN=1 TPM=0 HOST_TUNE=0 INSTANCE=9882 \
        "$START_VM" --no-sdl --no-fb-shm --no-bridge > "$out"

    DRY_RUN=1 TPM=0 HOST_TUNE=0 INSTANCE=9883 \
        "$START_VM" --no-sdl --no-fb-shm --no-bridge --qemu-service-cpu > "$out"

    if DRY_RUN=1 TPM=0 HOST_TUNE=0 INSTANCE=9884 \
        "$START_VM" --no-sdl --no-fb-shm --no-bridge --svc-cpus=bad > "$out" 2>&1
    then
        fail "invalid --svc-cpus value should fail"
    fi
    grep -F -- "QEMU_SERVICE_CPUS 必须是非负整数" "$out" >/dev/null \
        || fail "invalid --svc-cpus did not explain the validation error"
}

test_cpu_pm_keeps_low_latency_default_dry_run() {
    local out="$1"

    DRY_RUN=1 TPM=0 HOST_TUNE=0 INSTANCE=9891 \
        "$START_VM" --no-sdl --no-fb-shm --no-bridge > "$out"

    grep -Fx -- "mem-lock=off,cpu-pm=on" "$out" >/dev/null \
        || fail "default dry-run must keep cpu-pm=on for low-latency guests"

    QEMU_CPU_PM=0 DRY_RUN=1 TPM=0 HOST_TUNE=0 INSTANCE=9892 \
        "$START_VM" --no-sdl --no-fb-shm --no-bridge > "$out"

    grep -Fx -- "mem-lock=off,cpu-pm=off" "$out" >/dev/null \
        || fail "QEMU_CPU_PM=0 must explicitly disable cpu-pm"
}

test_gl_display_keeps_historical_default_dry_run() {
    local out="$1"
    local vga_line

    DISPLAY=:0 DRY_RUN=1 TPM=0 HOST_TUNE=0 INSTANCE=9886 \
        "$START_VM" --no-fb-shm --no-bridge > "$out"

    vga_line="$(grep -F -- "virtio-vga-gl" "$out" || true)"
    [[ -n "$vga_line" ]] \
        || fail "default SDL dry-run did not keep virtio-vga-gl"
    [[ "$vga_line" != *"blob=true"* && "$vga_line" != *"hostmem="* ]] \
        || fail "default SDL dry-run must keep historical texture-only device"

    DISPLAY=:0 GPU_ZEROCOPY=1 GPU_HOSTMEM=512M DRY_RUN=1 TPM=0 HOST_TUNE=0 INSTANCE=9887 \
        "$START_VM" --no-fb-shm --no-bridge > "$out"

    vga_line="$(grep -F -- "virtio-vga-gl" "$out" || true)"
    [[ "$vga_line" == *"blob=true"* ]] \
        || fail "GPU_ZEROCOPY=1 did not enable virtio-gpu blob resources"
    [[ "$vga_line" == *"hostmem=512M"* ]] \
        || fail "GPU_ZEROCOPY=1 did not honor GPU_HOSTMEM"

    DISPLAY=:0 GPU_ZEROCOPY=0 DRY_RUN=1 TPM=0 HOST_TUNE=0 INSTANCE=9888 \
        "$START_VM" --no-fb-shm --no-bridge > "$out"

    vga_line="$(grep -F -- "virtio-vga-gl" "$out" || true)"
    [[ "$vga_line" != *"blob=true"* && "$vga_line" != *"hostmem="* ]] \
        || fail "GPU_ZEROCOPY=0 should keep historical texture-only device"

    DISPLAY=:0 DRY_RUN=1 TPM=0 HOST_TUNE=0 INSTANCE=9890 \
        "$START_VM" --gpu-sdl-egl --no-fb-shm --no-bridge > "$out"

    grep -Fx -- "sdl,gl=on,show-cursor=off" "$out" >/dev/null \
        || fail "--gpu-sdl-egl must keep an SDL window display"
    grep -Fx -- "egl-headless" "$out" >/dev/null \
        && fail "--gpu-sdl-egl must not select headless display"
    vga_line="$(grep -F -- "virtio-vga-gl" "$out" || true)"
    [[ "$vga_line" == *"blob=true"* && "$vga_line" == *"hostmem=256M"* ]] \
        || fail "--gpu-sdl-egl did not keep virtio-vga-gl blob/hostmem enabled"
}

test_gpu_headless_display_dry_run() {
    local out="$1"
    local vga_line

    DRY_RUN=1 TPM=0 HOST_TUNE=0 INSTANCE=9889 \
        "$START_VM" --gpu-headless --no-fb-shm --no-bridge > "$out"

    grep -Fx -- "egl-headless" "$out" >/dev/null \
        || fail "--gpu-headless did not select egl-headless display"
    grep -Fx -- "sdl,gl=on,show-cursor=off" "$out" >/dev/null \
        && fail "--gpu-headless should not create an SDL window"

    vga_line="$(grep -F -- "virtio-vga-gl" "$out" || true)"
    [[ "$vga_line" == *"blob=true"* && "$vga_line" == *"hostmem=256M"* ]] \
        || fail "--gpu-headless did not keep virtio-vga-gl blob/hostmem enabled"
}

test_hotkey_capture_option_removed() {
    local out="$1"

    # 旧版 --hotkey-capture 会启动宿主侧 F4 监听/截图守护进程。现在这个功能已删除，
    # 所以入口必须在 CLI 解析阶段直接失败，避免任何后续启动路径重新导出触发 socket。
    if DRY_RUN=1 TPM=0 HOST_TUNE=0 INSTANCE=9885 \
        "$START_VM" --no-sdl --no-fb-shm --no-bridge --hotkey-capture > "$out" 2>&1
    then
        fail "removed --hotkey-capture option should fail"
    fi
    grep -F -- "unknown flag '--hotkey-capture'" "$out" >/dev/null \
        || fail "removed --hotkey-capture option did not fail at CLI parsing"

    # 主启动脚本和 SDL 前端都不应再保留宿主热键捕获的环境变量或函数名。
    if grep -F -- "QEMU_HOTKEY_TRIGGER" \
        "$REPO_ROOT/ui/sdl2.c" \
        "$REPO_ROOT/deploy/scripts/start-vm.sh" \
        "$REPO_ROOT/deploy/scripts/lib/sv-cli.sh" \
        "$REPO_ROOT/deploy/scripts/lib/sv-assemble.sh" >/dev/null
    then
        fail "hotkey trigger environment hook is still present"
    fi
}

test_cpu_isolate_scripts_parse() {
    bash -n "$REPO_ROOT/deploy/scripts/lib/sv-cli.sh"
    bash -n "$REPO_ROOT/deploy/scripts/lib/sv-cpupin.sh"
    bash -n "$REPO_ROOT/deploy/scripts/host-cpu-isolate.sh"

    grep -F -- "\"\${QEMU_SERVICE_CPUS:-0}\" <<'PY' &" "$REPO_ROOT/deploy/scripts/lib/sv-cpupin.sh" >/dev/null \
        || fail "cpu pinner must pass QEMU_SERVICE_CPUS as argv, not rely on export"
    grep -F -- 'sys.argv[5]' "$REPO_ROOT/deploy/scripts/lib/sv-cpupin.sh" >/dev/null \
        || fail "cpu pinner Python must read service CPU count from argv"
    grep -F -- 'read_held_vcpu_cpus' "$REPO_ROOT/deploy/scripts/lib/sv-cpupin.sh" >/dev/null \
        || fail "cpu pinner must separately count existing vCPU pins"
    grep -F -- 'primary_pool_size_after_reserve' "$REPO_ROOT/deploy/scripts/lib/sv-cpupin.sh" >/dev/null \
        || fail "cpu pinner must check physical-primary capacity before keeping host reserve"
    grep -F -- 'primary_pool_size_after_reserve(reserve) < vcpu_primary_demand' "$REPO_ROOT/deploy/scripts/lib/sv-cpupin.sh" >/dev/null \
        || fail "HOST_RESERVE_CORES=auto must shrink before assigning vCPUs to SMT siblings"
}

main() {
    require_executable "$START_VM"
    require_executable "$QEMU"
    require_executable "$QEMU_IMG"

    local out img sock err multi_sock multi_err image_root
    out="$(mktemp)"
    img="$(mktemp --suffix=.qcow2)"
    sock="$(mktemp -u)"
    err="$(mktemp)"
    multi_sock="$(mktemp -u)"
    multi_err="$(mktemp)"
    image_root="$(mktemp -d)"
    trap 'rm -f "${out:-}" "${img:-}" "${sock:-}" "${err:-}" "${multi_sock:-}" "${multi_err:-}"; rm -rf "${image_root:-}"' EXIT

    test_dry_run_has_safe_nvme_storage "$out"
    test_qemu_accepts_samsung_nvme "$img" "$sock" "$err"
    test_qmp_multi_accepts_two_clients "$multi_sock" "$multi_err"
    test_proxy_dry_run_uses_native_qmp_multi "$out"
    test_custom_image_root_dry_run "$image_root" "$out"
    test_qemu_service_cpu_flags_dry_run "$out"
    test_cpu_pm_keeps_low_latency_default_dry_run "$out"
    test_gl_display_keeps_historical_default_dry_run "$out"
    test_gpu_headless_display_dry_run "$out"
    test_hotkey_capture_option_removed "$out"
    test_cpu_isolate_scripts_parse
    echo "PASS: start-vm NVMe storage portability path"
}

main "$@"
