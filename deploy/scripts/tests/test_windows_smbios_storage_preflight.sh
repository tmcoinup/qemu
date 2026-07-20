#!/usr/bin/env bash
# Windows SMBIOS 深层参数与持久化目标前置门禁回归。
#
# fake QEMU 只实现无副作用的 -dump-vmstate 协议；存储负测在 WHPX 探测前
# 失败，用于证明错误不会创建 VmRoot、profile 或 OVMF vars。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PREFLIGHT="$REPO_ROOT/deploy/windows/lib/VMate.Preflight.ps1"
LAUNCHER="$REPO_ROOT/deploy/windows/start-vm.ps1"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_text() {
    local needle="$1"
    local file="$2"
    grep -F -- "$needle" "$file" >/dev/null \
        || fail "missing '$needle' in $file"
}

test_static_contract() {
    local property storage_line whpx_line commit_line

    require_text 'function Assert-VMateQemuSmbiosCapabilities' "$PREFLIGHT"
    require_text "'-dump-vmstate' \$dumpPath" "$PREFLIGHT"
    require_text "Assert-VMateQemuSmbiosCapabilities -Qemu \$Qemu" "$PREFLIGHT"
    for property in \
        sock_pfx manufacturer version serial part max-speed current-speed \
        processor-family voltage external-clock processor-upgrade \
        processor-characteristics loc_pfx bank speed configured-speed \
        memory-type type-detail rank device-width spd-ee1004; do
        require_text "$property=" "$PREFLIGHT"
    done

    require_text "Assert-VMateWritableDirectoryTarget -Path \$VmRoot" "$LAUNCHER"
    require_text 'function Assert-VMateReadableNonEmptyFile' "$PREFLIGHT"
    require_text '[System.IO.FileAccess]::Read' "$PREFLIGHT"
    require_text "if (\$length -eq 0)" "$PREFLIGHT"
    require_text "Assert-VMateReadableNonEmptyFile -Path \$inputFile.Value" \
        "$LAUNCHER"
    require_text "Assert-VMateOvmfStorageReady -Template \$OvmfVarsTemplate" \
        "$LAUNCHER"
    require_text "Assert-VMateWritableDirectoryTarget -Path \$runRoot -Label '运行目录'" \
        "$LAUNCHER"
    storage_line="$(grep -n 'Assert-VMateOvmfStorageReady' "$LAUNCHER" |
        tail -n1 | cut -d: -f1)"
    whpx_line="$(grep -n 'Assert-VMateWhpxReady -Qemu' "$LAUNCHER" |
        tail -n1 | cut -d: -f1)"
    commit_line="$(grep -n 'Commit-VMateHardwareProfile' "$LAUNCHER" |
        tail -n1 | cut -d: -f1)"
    (( storage_line < whpx_line && whpx_line < commit_line )) \
        || fail 'storage preflight is not ordered before WHPX/profile commit'
}

write_fake_qemu() {
    local target="$1"

    cat >"$target" <<'FAKE_QEMU'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${VMATE_FAKE_LOG:?}"
type4=''
type17=''
dump=''
previous=''
for argument in "$@"; do
    if [[ "$previous" == '-smbios' && "$argument" == type=4,* ]]; then
        type4="$argument"
    elif [[ "$previous" == '-smbios' && "$argument" == type=17,* ]]; then
        type17="$argument"
    elif [[ "$previous" == '-dump-vmstate' ]]; then
        dump="$argument"
    fi
    previous="$argument"
done

for specification in \
    type4:sock_pfx type4:manufacturer type4:version type4:serial type4:part \
    type4:max-speed type4:current-speed type4:processor-family type4:voltage \
    type4:external-clock type4:processor-upgrade \
    type4:processor-characteristics type17:loc_pfx type17:bank \
    type17:manufacturer type17:serial type17:part type17:speed \
    type17:configured-speed type17:memory-type type17:type-detail type17:rank \
    type17:voltage type17:device-width type17:spd-ee1004; do
    type="${specification%%:*}"
    property="${specification#*:}"
    value="$type4"
    [[ "$type" == 'type4' ]] || value="$type17"
    if [[ "${VMATE_FAKE_MISSING:-}" == "smbios:$specification" ]]; then
        echo "Invalid parameter '$property'" >&2
        exit 23
    fi
    [[ "$value" == *",$property="* ]] || {
        echo "canary omitted $specification" >&2
        exit 24
    }
done
printf '{"vmstate":{}}\n' >"${dump:?missing dump-vmstate path}"
FAKE_QEMU
    chmod +x "$target"
}

test_smbios_canary() {
    local shell_bin="$1"
    local tmp fake log dump_path

    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    fake="$tmp/qemu-system-x86_64"
    log="$tmp/qemu.log"
    : >"$log"
    write_fake_qemu "$fake"

    # shellcheck disable=SC2016
    VMATE_PREFLIGHT="$PREFLIGHT" VMATE_FAKE_QEMU="$fake" VMATE_FAKE_LOG="$log" \
        "$shell_bin" -NoLogo -NoProfile -NonInteractive -Command '
            $ErrorActionPreference = "Stop"
            . $env:VMATE_PREFLIGHT
            function Assert-ProbeFails {
                param([string]$Missing)
                $env:VMATE_FAKE_MISSING = $Missing
                try {
                    Assert-VMateQemuSmbiosCapabilities `
                        -Qemu $env:VMATE_FAKE_QEMU
                } catch {
                    if ($_.Exception.Message -notmatch "SMBIOS Type 4/17") {
                        throw "缺失属性错误不可诊断：$($_.Exception.Message)"
                    }
                    return
                }
                throw "旧 QEMU 缺失 $Missing 时未被拒绝"
            }

            $env:VMATE_FAKE_MISSING = ""
            Assert-VMateQemuSmbiosCapabilities -Qemu $env:VMATE_FAKE_QEMU
            foreach ($missing in @(
                "smbios:type4:processor-family",
                "smbios:type4:voltage",
                "smbios:type4:external-clock",
                "smbios:type4:processor-upgrade",
                "smbios:type4:processor-characteristics",
                "smbios:type17:configured-speed",
                "smbios:type17:memory-type",
                "smbios:type17:type-detail",
                "smbios:type17:rank",
                "smbios:type17:voltage",
                "smbios:type17:device-width",
                "smbios:type17:spd-ee1004"
            )) {
                Assert-ProbeFails -Missing $missing
            }
        '

    while read -r dump_path; do
        [[ ! -e "$dump_path" ]] \
            || fail "SMBIOS canary left temporary vmstate behind: $dump_path"
    done < <(awk '{
        for (i = 1; i < NF; i++) {
            if ($i == "-dump-vmstate") {
                print $(i + 1)
            }
        }
    }' "$log")
}

test_locked_firmware_is_unreadable() {
    local shell_bin="$1"
    local tmp

    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    printf 'locked-firmware' >"$tmp/locked.fd"
    # 在同一进程用 FileShare.None 独占文件，跨 Windows/Linux PowerShell
    # 稳定证明 helper 不是仅依赖 Test-Path/Get-Item 的表面检查。
    # shellcheck disable=SC2016
    VMATE_PREFLIGHT="$PREFLIGHT" VMATE_LOCKED_FIRMWARE="$tmp/locked.fd" \
        "$shell_bin" -NoLogo -NoProfile -NonInteractive -Command '
            $ErrorActionPreference = "Stop"
            . $env:VMATE_PREFLIGHT
            $stream = [System.IO.File]::Open(
                $env:VMATE_LOCKED_FIRMWARE, [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            try {
                try {
                    Assert-VMateReadableNonEmptyFile `
                        -Path $env:VMATE_LOCKED_FIRMWARE -Label "OVMF code"
                    throw "独占锁定的固件通过了可读性探针"
                } catch {
                    if ($_.Exception.Message -notmatch "OVMF code 不可读") {
                        throw
                    }
                }
            } finally {
                $stream.Dispose()
            }
        '
}

test_storage_failures_leave_vmroot_absent() {
    local shell_bin="$1"
    local tmp mismatch blocker run_blocked readonly_vars empty_output
    local -a common

    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    mkdir -p "$tmp/user"
    printf '0123456789abcdef' >"$tmp/template.fd"
    printf 'bad' >"$tmp/mismatch.fd"
    printf 'firmware-code' >"$tmp/code.fd"
    touch "$tmp/disk.qcow2" "$tmp/empty-code.fd" "$tmp/empty-template.fd"
    common=(
        -NoLogo -NoProfile -NonInteractive -File "$LAUNCHER"
        -Qemu /bin/true -Disk "$tmp/disk.qcow2"
        -OvmfCode "$tmp/code.fd" -OvmfVarsTemplate "$tmp/template.fd"
    )

    empty_output="$tmp/empty-code.out"
    if USERPROFILE="$tmp/user" "$shell_bin" -NoLogo -NoProfile \
        -NonInteractive -File "$LAUNCHER" -Qemu /bin/true \
        -Disk "$tmp/disk.qcow2" -OvmfCode "$tmp/empty-code.fd" \
        -OvmfVarsTemplate "$tmp/template.fd" -VmRoot "$tmp/vm-empty-code" \
        -OvmfVars "$tmp/empty-code-vars.fd" -FbShmPath "$tmp/fb.sock" \
        >"$empty_output" 2>&1; then
        fail 'empty OVMF code passed readable/non-empty preflight'
    fi
    require_text 'OVMF code 为空文件' "$empty_output"
    [[ ! -e "$tmp/vm-empty-code" && ! -e "$tmp/empty-code-vars.fd" ]] \
        || fail 'empty OVMF code created VM/profile/NVRAM state'

    empty_output="$tmp/empty-template.out"
    if USERPROFILE="$tmp/user" "$shell_bin" -NoLogo -NoProfile \
        -NonInteractive -File "$LAUNCHER" -Qemu /bin/true \
        -Disk "$tmp/disk.qcow2" -OvmfCode "$tmp/code.fd" \
        -OvmfVarsTemplate "$tmp/empty-template.fd" \
        -VmRoot "$tmp/vm-empty-template" \
        -OvmfVars "$tmp/empty-template-vars.fd" -FbShmPath "$tmp/fb.sock" \
        >"$empty_output" 2>&1; then
        fail 'empty OVMF vars template passed readable/non-empty preflight'
    fi
    require_text 'OVMF vars 模板 为空文件' "$empty_output"
    [[ ! -e "$tmp/vm-empty-template" &&
        ! -e "$tmp/empty-template-vars.fd" ]] \
        || fail 'empty OVMF vars template created VM/profile/NVRAM state'

    mismatch="$tmp/mismatch.out"
    if USERPROFILE="$tmp/user" "$shell_bin" "${common[@]}" \
        -VmRoot "$tmp/vm-mismatch" -OvmfVars "$tmp/mismatch.fd" \
        -FbShmPath "$tmp/fb.sock" >"$mismatch" 2>&1; then
        fail 'wrong-sized existing OVMF vars passed preflight'
    fi
    require_text '已有 OVMF vars 与模板长度不同' "$mismatch"
    [[ ! -e "$tmp/vm-mismatch" ]] \
        || fail 'OVMF length failure created VmRoot/profile state'

    mkdir "$tmp/vars-directory"
    if USERPROFILE="$tmp/user" "$shell_bin" "${common[@]}" \
        -VmRoot "$tmp/vm-directory" -OvmfVars "$tmp/vars-directory" \
        -FbShmPath "$tmp/fb.sock" >"$tmp/directory.out" 2>&1; then
        fail 'directory-backed OVMF vars passed Leaf preflight'
    fi
    require_text '已有 OVMF vars 不是文件' "$tmp/directory.out"
    [[ ! -e "$tmp/vm-directory" ]] \
        || fail 'OVMF Leaf failure created VmRoot/profile state'

    readonly_vars="$tmp/readonly-vars.fd"
    cp "$tmp/template.fd" "$readonly_vars"
    chmod 400 "$readonly_vars"
    if USERPROFILE="$tmp/user" "$shell_bin" "${common[@]}" \
        -VmRoot "$tmp/vm-readonly" -OvmfVars "$readonly_vars" \
        -FbShmPath "$tmp/fb.sock" >"$tmp/readonly.out" 2>&1; then
        fail 'read-only existing OVMF vars passed ReadWrite preflight'
    fi
    require_text '已有 OVMF vars 不可读写' "$tmp/readonly.out"
    [[ ! -e "$tmp/vm-readonly" ]] \
        || fail 'OVMF ReadWrite failure created VmRoot/profile state'

    blocker="$tmp/not-a-directory"
    touch "$blocker"
    if USERPROFILE="$tmp/user" "$shell_bin" "${common[@]}" \
        -VmRoot "$blocker/vm" -OvmfVars "$tmp/new-vars.fd" \
        -FbShmPath "$tmp/fb.sock" >"$tmp/parent.out" 2>&1; then
        fail 'non-directory VmRoot parent passed write preflight'
    fi
    require_text '父路径不是目录' "$tmp/parent.out"
    [[ ! -e "$blocker/vm" ]] \
        || fail 'VmRoot parent failure created a VM directory'

    run_blocked="$tmp/run-blocked"
    touch "$run_blocked"
    # 直接驱动同一个 helper，稳定覆盖 Windows 运行目录被普通文件占用的失败。
    # shellcheck disable=SC2016
    if VMATE_PREFLIGHT="$PREFLIGHT" VMATE_RUN_BLOCKED="$run_blocked" \
        "$shell_bin" -NoLogo -NoProfile -NonInteractive -Command '
            . $env:VMATE_PREFLIGHT
            Assert-VMateWritableDirectoryTarget -Path $env:VMATE_RUN_BLOCKED `
                -Label "运行目录"
        ' >"$tmp/run.out" 2>&1; then
        fail 'file-backed runRoot passed directory write preflight'
    fi
    require_text '父路径不是目录' "$tmp/run.out"
}

test_static_contract
shell_bin="$(command -v pwsh || command -v powershell || true)"
if [[ -z "$shell_bin" ]]; then
    echo 'SKIP: PowerShell not found; SMBIOS/storage dynamic checks skipped'
else
    test_smbios_canary "$shell_bin"
    test_locked_firmware_is_unreadable "$shell_bin"
    test_storage_failures_leave_vmroot_absent "$shell_bin"
fi
echo 'OK: Windows SMBIOS/storage preflight checks passed'
