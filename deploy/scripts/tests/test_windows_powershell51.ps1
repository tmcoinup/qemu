#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
}
if ($PSVersionTable.PSVersion.Major -ne 5 -or
    $PSVersionTable.PSVersion.Minor -ne 1) {
    throw "本门禁必须由 Windows PowerShell 5.1 执行，实际：$($PSVersionTable.PSVersion)"
}

$runtimeRoot = Join-Path $RepoRoot 'deploy/windows'
$profileTest = Join-Path $RepoRoot `
    'deploy/scripts/tests/test_windows_profile_integrity.ps1'
$dnfGuestRoot = Join-Path $RepoRoot 'deploy/scripts/guest'
$dnfScripts = foreach ($name in 'dnf-fix-deps.ps1', `
        'dnf-fix-installers.ps1', 'dnf-fix-directx.ps1') {
    Get-Item -LiteralPath (Join-Path $dnfGuestRoot $name)
}
$scripts = @(Get-ChildItem -LiteralPath $runtimeRoot -Recurse -Filter '*.ps1') +
    @(Get-Item -LiteralPath $profileTest) +
    @($dnfScripts) +
    @(Get-Item -LiteralPath $MyInvocation.MyCommand.Path)
foreach ($script in $scripts) {
    $bytes = [System.IO.File]::ReadAllBytes($script.FullName)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xef -or
        $bytes[1] -ne 0xbb -or $bytes[2] -ne 0xbf) {
        throw "Windows PowerShell 5.1 脚本缺少 UTF-8 BOM：$($script.FullName)"
    }
    # 使用 inbox 5.1 自己的 AST，而不是让 pwsh 7 代替兼容性证明。
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $script.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw "PowerShell 5.1 AST 失败：$($script.FullName)；$($errors -join '; ')"
    }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
    ('vmate-ps51-' + [Guid]::NewGuid().ToString('N'))
$oldUserProfile = $env:USERPROFILE
try {
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
    $env:USERPROFILE = Join-Path $testRoot 'user'
    New-Item -ItemType Directory -Force -Path $env:USERPROFILE | Out-Null
    $disk = Join-Path $testRoot 'disk.qcow2'
    $code = Join-Path $testRoot 'code.fd'
    $vars = Join-Path $testRoot 'vars.fd'
    foreach ($path in @($disk, $code, $vars)) {
        [System.IO.File]::WriteAllBytes($path, (New-Object byte[] 1))
    }
    $vmRoot = Join-Path $testRoot 'vm'
    $launcher = Join-Path $runtimeRoot 'start-vm.ps1'
    $output = @(& $launcher -Qemu $env:ComSpec -VmRoot $vmRoot -Disk $disk `
        -OvmfCode $code -OvmfVarsTemplate $vars `
        -HardwareManifest (Join-Path $RepoRoot 'deploy/hardware/platforms.json') `
        -ComponentManifest (Join-Path $RepoRoot 'deploy/hardware/components.json') `
        -PlatformId 'intel-lga1151-i3-9100f-asus-prime-h310m-a-r2' `
        -FbShmPath (Join-Path $testRoot 'fb.sock') -GpuGlProbe Unavailable `
        -DryRunHostCpuName 'Intel(R) Core(TM) i3-9100F CPU @ 3.60GHz' -DryRun)
    if ($output -notcontains 'whpx,hyperv=off,kernel-irqchip=off' -or
        @($output | Where-Object {
                $_ -like 'intel-hda,id=hda,bus=pcie.0,addr=0x4,*'
            }).Count -ne 1) {
        throw 'Windows PowerShell 5.1 DryRun 缺少严格 WHPX 或固定 HDA BDF。'
    }
    if (Test-Path -LiteralPath $vmRoot) {
        throw 'Windows PowerShell 5.1 DryRun 写入了 VM/profile 状态。'
    }

    & $profileTest -RepoRoot $RepoRoot
    Write-Output 'OK: native Windows PowerShell 5.1 compatibility checks passed'
} finally {
    $env:USERPROFILE = $oldUserProfile
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
