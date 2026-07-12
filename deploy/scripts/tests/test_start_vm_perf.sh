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

def execute(stream, command, ident):
    stream.write(json.dumps({"execute": command, "id": ident}).encode() + b"\n")
    while True:
        response = json.loads(stream.readline())
        if response.get("id") == ident:
            assert "return" in response, response
            return response["return"]

def wait_for_child_count(stream, tag, expected=1):
    # 中文注释：HUP、dispatcher 收尾和主线程 retire BH 都是异步的；通过常驻
    # c1 轮询，确认短连接对应的 monitor/chardev 真正回收到基线。
    for attempt in range(200):
        entries = execute(stream, "query-chardev", f"{tag}-{attempt}")
        children = [
            entry for entry in entries
            if entry.get("label", "").startswith("qmp-multi-")
        ]
        if len(children) == expected:
            return children
        time.sleep(0.01)
    raise AssertionError(f"{tag}: QMP child count did not return to {expected}")

# 中文注释：c1 保持常驻，反复创建并关闭第二个 client，模拟 vmate 的
# query-status 短连接。每个 transient child 都必须删除，不能按连接数增长。
s2.close()
c2.close()
wait_for_child_count(s1, "initial-close")
for index in range(32):
    client, stream = connect_qmp(f"short-{index}")
    status = execute(stream, "query-status", f"short-status-{index}")
    assert "status" in status, status
    stream.close()
    client.close()
    wait_for_child_count(s1, f"short-close-{index}")

# 中文注释：覆盖“命令已提交但不读响应就断开”的竞态。query-qmp-schema
# 响应足够大，能触发 dispatcher active request 与 socket HUP 并行收尾。
for index in range(16):
    client, stream = connect_qmp(f"active-{index}")
    stream.write(json.dumps({
        "execute": "query-qmp-schema",
        "id": f"active-schema-{index}",
    }).encode() + b"\n")
    stream.close()
    client.close()
    wait_for_child_count(s1, f"active-close-{index}")

# 半包 JSON 断开必须同样释放 parser/monitor，且不能影响常驻连接。
for index in range(8):
    client, stream = connect_qmp(f"partial-{index}")
    stream.write(b'{"execute":"query-status"')
    stream.close()
    client.close()
    wait_for_child_count(s1, f"partial-close-{index}")

children = execute(s1, "query-chardev", "retire-count")
children = [
    entry for entry in children
    if entry.get("label", "").startswith("qmp-multi-")
]
assert len(children) == 1, children

# 中文注释：quit 不能只写完就立刻关 socket；在慢宿主或并发测试时，
# QEMU 可能还没从 socket 读到完整命令，父 shell 随后 wait 就会卡住。
# 读到 quit 响应后再关闭，确保临时 QEMU 进入退出流程。
c1.settimeout(2.0)
s1.write(b'{"execute":"quit","id":"quit"}\n')
while True:
    quit_resp = json.loads(s1.readline())
    if quit_resp.get("id") == "quit":
        assert "return" in quit_resp, quit_resp
        break
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

test_cpu_pm_keeps_upstream_default_dry_run() {
    local out="$1"

    DRY_RUN=1 TPM=0 HOST_TUNE=0 INSTANCE=9891 \
        "$START_VM" --no-sdl --no-fb-shm --no-bridge > "$out"

    grep -Fx -- "mem-lock=off,cpu-pm=off" "$out" >/dev/null \
        || fail "default dry-run must keep cpu-pm=off for portable multi-VM guests"

    QEMU_CPU_PM=1 DRY_RUN=1 TPM=0 HOST_TUNE=0 INSTANCE=9892 \
        "$START_VM" --no-sdl --no-fb-shm --no-bridge > "$out"

    grep -Fx -- "mem-lock=off,cpu-pm=on" "$out" >/dev/null \
        || fail "QEMU_CPU_PM=1 must explicitly enable cpu-pm"
}

test_phenom_cpu_masks_missing_3dnow() {
    local out="$1"

    (
        source "$REPO_ROOT/deploy/scripts/stealth-lib.sh"
        CPU_CUR_MHZ=3200
        CPU_VENDOR=AuthenticAMD
        CPU_QEMU_ARG="phenom,model-id=AMD Phenom(tm) II X4 955 Processor"
        # 中文注释：用可控 flags 模拟新 AMD 宿主缺 3DNow 的情况，验证旧
        # Phenom/Athlon II profile 启动时会主动关闭 QEMU phenom 的 3DNow 位。
        STEALTH_HOST_CPU_FLAGS="fpu sse sse2"
        stealth_qemu_cpu_arg
    ) > "$out"
    grep -F -- ",-3dnow," "$out" >/dev/null \
        || fail "phenom CPU arg must mask missing 3dnow"
    grep -F -- ",-3dnowext," "$out" >/dev/null \
        || fail "phenom CPU arg must mask missing 3dnowext"

    (
        source "$REPO_ROOT/deploy/scripts/stealth-lib.sh"
        # 以下全局变量由已 source 的函数按名称读取，ShellCheck 无法静态跟踪。
        # shellcheck disable=SC2034
        CPU_CUR_MHZ=3200
        # shellcheck disable=SC2034
        CPU_VENDOR=AuthenticAMD
        # shellcheck disable=SC2034
        CPU_QEMU_ARG="phenom,model-id=AMD Phenom(tm) II X4 955 Processor"
        # shellcheck disable=SC2034
        STEALTH_HOST_CPU_FLAGS="fpu sse sse2 3dnow 3dnowext"
        stealth_qemu_cpu_arg
    ) > "$out"
    if grep -F -- ",-3dnow," "$out" >/dev/null; then
        fail "phenom CPU arg must not mask 3dnow when host supports it"
    fi
    if grep -F -- ",-3dnowext," "$out" >/dev/null; then
        fail "phenom CPU arg must not mask 3dnowext when host supports it"
    fi
}

test_gl_display_uses_qemu11_sdl_default_dry_run() {
    local out="$1"
    local vga_line

    DISPLAY=:0 DRY_RUN=1 TPM=0 HOST_TUNE=0 INSTANCE=9886 \
        "$START_VM" --no-fb-shm --no-bridge > "$out"

    # 中文注释：默认名与兼容名都必须走 QEMU 11 官方 SDL/GL 参数；EGL 由
    # QEMU 自行探测，启动器不得再导出旧的私有开关或创建 X11 子窗口。
    grep -F -- ': "${GPU_DISPLAY:=sdl}"' "$REPO_ROOT/deploy/scripts/lib/sv-cli.sh" >/dev/null \
        || fail "default GPU_DISPLAY must stay on official SDL/GL"
    if grep -F -- "SDL_NATIVE_EGL" \
        "$REPO_ROOT/deploy/scripts/start-vm.sh" \
        "$REPO_ROOT/deploy/scripts/lib/sv-cli.sh" \
        "$REPO_ROOT/deploy/scripts/lib/sv-devices.sh" \
        "$REPO_ROOT/deploy/scripts/lib/sv-assemble.sh" >/dev/null
    then
        fail "launcher must not retain the private SDL native-EGL environment hook"
    fi
    grep -Fx -- "sdl,gl=on,show-cursor=off" "$out" >/dev/null \
        || fail "default SDL dry-run must keep the SDL/GL window display"
    grep -Fx -- "egl-headless" "$out" >/dev/null \
        && fail "default SDL dry-run must not select egl-headless"
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
        || fail "--gpu-sdl-egl compatibility name must use official SDL/GL"
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
    test_cpu_pm_keeps_upstream_default_dry_run "$out"
    test_phenom_cpu_masks_missing_3dnow "$out"
    test_gl_display_uses_qemu11_sdl_default_dry_run "$out"
    test_gpu_headless_display_dry_run "$out"
    test_hotkey_capture_option_removed "$out"
    test_cpu_isolate_scripts_parse
    echo "PASS: start-vm NVMe storage portability path"
}

main "$@"
