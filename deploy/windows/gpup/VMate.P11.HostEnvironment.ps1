#Requires -Version 5.1

<#
.SYNOPSIS
    P-11 宿主运行环境的统一检测、修复与重启判定。

.DESCRIPTION
    该模块只管理 P-11 明确依赖的 Windows/Hyper-V/GPU-P 宿主环境。它不会修改
    guest BCD。默认产品路径使用标准 GPU-P 与 guest EFI SMBIOS 投影，宿主也要求
    testsigning=off。RequireTestSigning 只保留给隔离实验，不是 21 套 profile 的
    正常启动条件。

    修复动作只写入目标配置；需要重新引导才能生效时返回 RebootRequired，调用方
    必须在重启前阻断 VM 启动。自动重启动作由安装目录 repair-env.ps1 统一协调，
    避免检测模块在被其它脚本复用时意外重启宿主。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$codeIntegrityModule = Join-Path $PSScriptRoot 'VMate.Windows.CodeIntegrity.ps1'
if (-not (Test-Path -LiteralPath $codeIntegrityModule -PathType Leaf)) {
    throw "P-11 Code Integrity 模块不存在：$codeIntegrityModule"
}
. $codeIntegrityModule

$espBootManagerModule = Join-Path $PSScriptRoot 'VMate.P11.EspBootManager.ps1'
$coldStartArtifactsModule = Join-Path $PSScriptRoot 'VMate.P11.ColdStartArtifacts.ps1'
$gpuPColdStartIsolationModule = Join-Path $PSScriptRoot 'VMate.HyperV.GpuPColdStartIsolation.ps1'
foreach ($modulePath in @($espBootManagerModule, $coldStartArtifactsModule,
        $gpuPColdStartIsolationModule)) {
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "P-11 宿主环境依赖模块不存在：$modulePath"
    }
    . $modulePath
}
function Get-VMateP11GpuPColdStartTransactionStatus {
    $commonData = [Environment]::GetFolderPath('CommonApplicationData')
    if ([String]::IsNullOrWhiteSpace($commonData)) {
        return [pscustomobject][ordered]@{
            Healthy = $false
            PendingCount = 0
            Transactions = @()
            Errors = @('无法解析 ProgramData。')
        }
    }
    $directory = Join-Path $commonData 'VMate\GpuP\cold-start-transactions'
    $transactions = [Collections.Generic.List[object]]::new()
    $errors = [Collections.Generic.List[string]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $directory -Filter '*.json' -File `
            -ErrorAction SilentlyContinue)) {
        try {
            $document = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 |
                ConvertFrom-Json -ErrorAction Stop
            if ([int]$document.SchemaVersion -ne 1 -or
                [string]$document.ContractId -cne 'vmate-p11-gpup-cold-start-transaction-v1' -or
                [Guid]$document.VMId -eq [Guid]::Empty -or
                [String]::IsNullOrWhiteSpace([string]$document.VMName)) {
                throw 'schema/contract/VM identity 无效'
            }
            [void]$transactions.Add([pscustomobject][ordered]@{
                Path = $file.FullName
                VMName = [string]$document.VMName
                VMId = ([Guid]$document.VMId).ToString('D')
                Phase = [string]$document.Phase
                UpdatedAtUtc = [string]$document.UpdatedAtUtc
            })
        }
        catch {
            [void]$errors.Add("$($file.FullName)：$($_.Exception.Message)")
        }
    }
    return [pscustomobject][ordered]@{
        Healthy = $transactions.Count -eq 0 -and $errors.Count -eq 0
        PendingCount = $transactions.Count
        Transactions = @($transactions)
        Errors = @($errors)
    }
}
function Invoke-VMateP11BcdEdit {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $output = @(& "$env:SystemRoot\System32\bcdedit.exe" @Arguments 2>&1 |
        ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0) {
        throw "bcdedit $($Arguments -join ' ') 失败：$($output -join ' ')"
    }
    return @($output)
}
function Get-VMateP11OptionalFeatureState {
    param([Parameter(Mandatory = $true)][string]$Name)
    $escaped = $Name.Replace("'", "''")
    $feature = Get-CimInstance Win32_OptionalFeature `
        -Filter "Name='$escaped'" -ErrorAction Stop
    if ($null -eq $feature) { return 'Missing' }
    switch ([int]$feature.InstallState) {
        1 { return 'Enabled' }
        2 { return 'Disabled' }
        3 { return 'Absent' }
        default { return "Unknown:$([int]$feature.InstallState)" }
    }
}
function Resolve-VMateP11HostPartitionCommand {
    foreach ($name in @('Get-VMHostPartitionableGpu',
            'Get-VMPartitionableGpu')) {
        $command = Get-Command -Name $name -ErrorAction SilentlyContinue
        if ($null -ne $command) { return $command }
    }
    return $null
}
function Resolve-VMateP11ArtifactPath {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$Value
    )
    if ([IO.Path]::IsPathRooted($Value)) {
        return [IO.Path]::GetFullPath($Value)
    }
    return [IO.Path]::GetFullPath((Join-Path `
        ([IO.Path]::GetDirectoryName($ManifestPath)) $Value))
}
function Get-VMateP11ArtifactManifestPath {
    $commonData = [Environment]::GetFolderPath('CommonApplicationData')
    if ([String]::IsNullOrWhiteSpace($commonData)) {
        throw '无法解析 ProgramData。'
    }
    return Join-Path $commonData 'VMate\GpuP\cpuid-artifacts.json'
}
function Get-VMateP11ManifestProperty {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or
        [String]::IsNullOrWhiteSpace([string]$property.Value)) {
        throw "冷启动工件清单缺少 $Name。"
    }
    return $property.Value
}
function Assert-VMateP11ArtifactFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [Parameter(Mandatory = $true)][string]$Label,
        [switch]$RequireValidSignature,
        [switch]$RequireMicrosoftSigner
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "$Label 不存在：$fullPath"
    }
    if ($ExpectedSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw "$Label 的清单 SHA-256 格式无效。"
    }
    $actual = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash
    if ($actual -cne $ExpectedSha256.ToUpperInvariant()) {
        throw "$Label SHA-256 漂移：$fullPath"
    }
    $signer = ''
    if ($RequireValidSignature -or $RequireMicrosoftSigner) {
        $signature = Get-AuthenticodeSignature -LiteralPath $fullPath
        if ([string]$signature.Status -cne 'Valid' -or
            $null -eq $signature.SignerCertificate) {
            throw "$Label Authenticode 签名无效：$fullPath"
        }
        $signer = [string]$signature.SignerCertificate.Subject
        if ($RequireMicrosoftSigner -and
            $signer -notmatch '(?i)(Microsoft Windows|Microsoft Corporation)') {
            throw "$Label 不是 Microsoft 签名：$fullPath"
        }
    }
    return [pscustomobject][ordered]@{
        Path = $fullPath
        Sha256 = $actual
        Signer = $signer
    }
}
function Get-VMateP11ForeignKernelActivity {
    $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            [string]$_.Name -match '(?i)(VMSpoofer|WinRing)' -or
            [string]$_.ExecutablePath -match '(?i)(VMSpoofer|WinRing)'
        } | Select-Object Name, ProcessId, ExecutablePath)
    $drivers = @(Get-CimInstance Win32_SystemDriver `
        -ErrorAction SilentlyContinue | Where-Object {
            [string]$_.State -ieq 'Running' -and
            ([string]$_.Name -match '(?i)(WinRing|Spoof)' -or
             [string]$_.PathName -match '(?i)(VMSpoofer|WinRing|Spoof)')
        } | Select-Object Name, State, PathName)
    return [pscustomobject][ordered]@{
        Active = $processes.Count -gt 0 -or $drivers.Count -gt 0
        Processes = $processes
        Drivers = $drivers
    }
}
function Get-VMateP11HostEnvironmentStatus {
    [CmdletBinding()]
    param([bool]$RequireTestSigning = $false)
    $problems = [Collections.Generic.List[string]]::new()
    $rebootReasons = [Collections.Generic.List[string]]::new()
    $featureStates = [ordered]@{}
    foreach ($name in @('HypervisorPlatform', 'Microsoft-Hyper-V-All',
            'Microsoft-Hyper-V-Management-PowerShell')) {
        try { $featureStates[$name] = Get-VMateP11OptionalFeatureState $name }
        catch { $featureStates[$name] = "Error:$($_.Exception.Message)" }
        if ([string]$featureStates[$name] -cne 'Enabled') {
            [void]$problems.Add("Windows 功能 $name 未启用：$($featureStates[$name])")
            [void]$rebootReasons.Add("Windows 功能 $name 需要完成启用")
        }
    }
    $hypervisorPresent = $false
    try {
        $hypervisorPresent = [bool](Get-CimInstance Win32_ComputerSystem `
            -ErrorAction Stop).HypervisorPresent
    }
    catch { [void]$problems.Add("无法读取 HypervisorPresent：$($_.Exception.Message)") }
    if (-not $hypervisorPresent) {
        [void]$problems.Add('Hyper-V hypervisor 当前未运行。')
        [void]$rebootReasons.Add('Hyper-V hypervisor 需要重新引导')
    }
    $moduleReady = $null -ne (Get-Module -ListAvailable -Name Hyper-V)
    if (-not $moduleReady) { [void]$problems.Add('Hyper-V PowerShell 模块不可用。') }
    $vmms = Get-Service vmms -ErrorAction SilentlyContinue
    $vmmsRunning = $null -ne $vmms -and [string]$vmms.Status -ceq 'Running'
    if (-not $vmmsRunning) { [void]$problems.Add('Hyper-V VMMS 服务未运行。') }
    $codeIntegrity = $null
    $bcdReadable = $true
    try { $codeIntegrity = Get-VMateWindowsCodeIntegrityStatus }
    catch {
        $bcdReadable = $false
        [void]$problems.Add("无法验证宿主 BCD/Code Integrity：$($_.Exception.Message)")
    }
    if ($null -ne $codeIntegrity) {
        if (-not $codeIntegrity.Enabled) {
            [void]$problems.Add("Code Integrity 当前未启用：$($codeIntegrity.OptionsHex)")
            [void]$rebootReasons.Add('恢复 Code Integrity 需要重新引导')
        }
        if ($codeIntegrity.DebugModeActive) {
            [void]$problems.Add('宿主内核调试模式处于活动状态。')
        }
        if ($codeIntegrity.NoIntegrityChecksConfigured) {
            [void]$problems.Add('BCD nointegritychecks=Yes，必须恢复为 No。')
            [void]$rebootReasons.Add('关闭 nointegritychecks 需要重新引导')
        }
        if ([string]$codeIntegrity.HypervisorLaunchType -ine 'Auto') {
            [void]$problems.Add(
                "BCD hypervisorlaunchtype=$($codeIntegrity.HypervisorLaunchType)，必须恢复为 Auto。")
            [void]$rebootReasons.Add('恢复 Hyper-V 启动项需要重新引导')
        }
        if ($RequireTestSigning) {
            if (-not $codeIntegrity.TestSigningConfigured) {
                [void]$problems.Add('BCD testsigning 尚未配置为 Yes。')
                [void]$rebootReasons.Add('启用宿主 testsigning 需要重新引导')
            }
            if (-not $codeIntegrity.TestSigningActive) {
                [void]$problems.Add(
                    "本次内核 TestSigningActive=False：$($codeIntegrity.OptionsHex)")
                [void]$rebootReasons.Add('本次内核尚未激活 test signing')
            }
        }
        else {
            if ($codeIntegrity.TestSigningConfigured) {
                [void]$problems.Add('BCD testsigning=Yes；P-11 默认产品路径要求关闭。')
                [void]$rebootReasons.Add('关闭宿主 testsigning 需要重新引导')
            }
            if ($codeIntegrity.TestSigningActive) {
                [void]$problems.Add('本次宿主内核仍处于 test signing 运行态。')
                [void]$rebootReasons.Add('退出宿主 test signing 运行态需要重新引导')
            }
        }
    }
    $espBootManager = Get-VMateP11EspBootManagerStatus
    if (-not $espBootManager.Readable) {
        [void]$problems.Add(
            "无法验证实际 ESP Windows 启动管理器：$($espBootManager.Error)")
    }
    elseif (-not $espBootManager.Trusted) {
        $active = if ($null -eq $espBootManager.Active) { 'unknown' }
            else {
                "$($espBootManager.Active.SignatureStatus)/" +
                    "$($espBootManager.Active.Sha256)"
            }
        [void]$problems.Add(
            "实际 ESP bootmgfw.efi 不是 Microsoft 签名原版：$active")
        [void]$rebootReasons.Add(
            '恢复 Microsoft 签名的 Windows 启动管理器需要重新引导')
        if ($null -eq $espBootManager.RecoveryCandidate) {
            [void]$problems.Add(
                'ESP 且 Windows 目录均没有可用的 Microsoft 启动管理器恢复源。')
        }
    }
    $partitionableGpuCount = 0
    $partitionCommand = $null
    if ($moduleReady -and $vmmsRunning) {
        try {
            Import-Module Hyper-V -ErrorAction Stop
            $partitionCommand = Resolve-VMateP11HostPartitionCommand
            if ($null -eq $partitionCommand) {
                throw '缺少 partitionable GPU 枚举 cmdlet。'
            }
            $partitionableGpuCount = @(& $partitionCommand -ErrorAction Stop).Count
            if ($partitionableGpuCount -lt 1) {
                [void]$problems.Add('Hyper-V 没有报告 partitionable GPU。')
            }
        }
        catch { [void]$problems.Add("GPU-P 枚举失败：$($_.Exception.Message)") }
    }
    $artifacts = Test-VMateP11ColdStartArtifactManifest
    if ($RequireTestSigning -and -not $artifacts.Valid) {
        [void]$problems.Add("21 套自定义 profile 工件无效：$($artifacts.Error)")
    }
    $foreign = Get-VMateP11ForeignKernelActivity
    if ($foreign.Active) {
        [void]$problems.Add('检测到外部内核/GPU 配置工具仍在运行。')
        [void]$rebootReasons.Add('需要清洁重启以清除外部内核工具运行态')
    }
    $gpuPColdStartTransactions =
        Get-VMateP11GpuPColdStartTransactionStatus
    if ($gpuPColdStartTransactions.PendingCount -gt 0) {
        [void]$problems.Add(
            "存在 $($gpuPColdStartTransactions.PendingCount) 个未完成的 GPU-P 冷启动事务。")
    }
    foreach ($errorText in @($gpuPColdStartTransactions.Errors)) {
        [void]$problems.Add("GPU-P 冷启动恢复日志无效：$errorText")
    }
    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        ContractId = 'vmate-p11-host-environment-v1'
        Ready = $problems.Count -eq 0
        RebootRequired = $rebootReasons.Count -gt 0
        RequireTestSigning = $RequireTestSigning
        HypervisorPresent = $hypervisorPresent
        FeatureStates = [pscustomobject]$featureStates
        HyperVModuleReady = $moduleReady
        VmmsRunning = $vmmsRunning
        PartitionableGpuCount = $partitionableGpuCount
        PartitionCommand = if ($null -eq $partitionCommand) { '' } else {
            [string]$partitionCommand.Name
        }
        BcdReadable = $bcdReadable
        CodeIntegrity = $codeIntegrity
        EspBootManager = $espBootManager
        ColdStartArtifacts = $artifacts
        GpuPColdStartTransactions = $gpuPColdStartTransactions
        ForeignKernelActivity = $foreign
        Problems = @($problems)
        RebootReasons = @($rebootReasons | Sort-Object -Unique)
    }
}
function Repair-VMateP11HostEnvironment {
    [CmdletBinding()]
    param([bool]$RequireTestSigning = $false)
    if (-not (Test-VMateP11Administrator)) {
        throw 'P-11 宿主环境修复需要管理员 PowerShell。'
    }
    $changes = [Collections.Generic.List[string]]::new()
    $before = Get-VMateP11HostEnvironmentStatus `
        -RequireTestSigning:$RequireTestSigning
    foreach ($name in @('HypervisorPlatform', 'Microsoft-Hyper-V-All',
            'Microsoft-Hyper-V-Management-PowerShell')) {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $name `
            -ErrorAction Stop
        if ([string]$feature.State -ne 'Enabled') {
            [void](Enable-WindowsOptionalFeature -Online -FeatureName $name `
                -All -NoRestart -ErrorAction Stop)
            [void]$changes.Add("Feature:$name")
        }
    }
    [void](Invoke-VMateP11BcdEdit -Arguments @('/set', '{current}',
            'hypervisorlaunchtype', 'auto'))
    if ($RequireTestSigning) {
        [void](Invoke-VMateP11BcdEdit -Arguments @('/set', '{current}',
                'testsigning', 'on'))
    }
    else {
        [void](Invoke-VMateP11BcdEdit -Arguments @('/set', '{current}',
                'testsigning', 'off'))
    }
    [void](Invoke-VMateP11BcdEdit -Arguments @('/set', '{current}',
            'nointegritychecks', 'off'))
    if (-not $before.EspBootManager.Trusted) {
        $espRepair = Repair-VMateP11EspBootManager
        if ($espRepair.Changed) {
            [void]$changes.Add('EspBootManager:MicrosoftStock')
        }
    }
    $vmms = Get-Service vmms -ErrorAction SilentlyContinue
    if ($null -ne $vmms) {
        Set-Service vmms -StartupType Automatic -ErrorAction Stop
        if ([string]$vmms.Status -ne 'Running') {
            try { Start-Service vmms -ErrorAction Stop }
            catch { [void]$changes.Add('VMMS:StartPendingReboot') }
        }
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        # 自动重启后的复检任务以 LocalSystem 运行；SYSTEM 已拥有 Hyper-V
        # 所需权限，不应被当作交互用户写入本地组。
        if ([string]$identity.User.Value -cne 'S-1-5-18') {
            $groupSid = New-Object `
                Security.Principal.SecurityIdentifier('S-1-5-32-578')
            $groupName = $groupSid.Translate(
                [Security.Principal.NTAccount]).Value.Split('\')[-1]
            $member = @(Get-LocalGroupMember -Group $groupName `
                -ErrorAction Stop | Where-Object {
                    [string]$_.SID.Value -ceq [string]$identity.User.Value
                })
            if ($member.Count -eq 0) {
                Add-LocalGroupMember -Group $groupName -Member $identity.Name `
                    -ErrorAction Stop
                [void]$changes.Add("HyperVAdministrators:$($identity.Name)")
            }
        }
    }
    finally { $identity.Dispose() }
    if (Get-Module -ListAvailable -Name Hyper-V) {
        Import-Module Hyper-V -ErrorAction Stop
        $p11Vms = @(Get-VM -ErrorAction Stop | Where-Object {
                [string]$_.Name -match '^VMate-P11-(?:[1-9][0-9]{0,2}|1000)$' })
        $configurationLock = Enter-VMateGpuPConfigurationLock
        try {
            foreach ($pending in @((Get-VMateP11GpuPColdStartTransactionStatus).Transactions)) {
                $pendingVm = @($p11Vms | Where-Object {
                        [Guid]$_.Id -eq [Guid]$pending.VMId -and
                        [string]$_.Name -ceq [string]$pending.VMName })
                if ($pendingVm.Count -ne 1) {
                    throw "GPU-P 冷启动恢复日志无法唯一匹配 P-11 VM：$($pending.VMName)/$($pending.VMId)"
                }
                $recovery = Repair-VMateHyperVGpuPColdStartTransaction `
                    -VM $pendingVm[0]
                if ([string]$recovery.Status -ceq 'Recovered') {
                    [void]$changes.Add("GpuPColdStartRecovered:$($pending.VMName)")
                }
            }
        }
        finally {
            Exit-VMateGpuPConfigurationLock -Mutex $configurationLock
        }
        foreach ($vm in $p11Vms) {
            if ([string]$vm.AutomaticStartAction -ne 'Nothing' -or
                [string]$vm.AutomaticStopAction -ne 'ShutDown') {
                Set-VM -VM $vm -AutomaticStartAction Nothing `
                    -AutomaticStopAction ShutDown -ErrorAction Stop
                [void]$changes.Add("P11AutoStartSafe:$($vm.Name)")
            }
        }
    }
    if ($RequireTestSigning) {
        $artifact = Test-VMateP11ColdStartArtifactManifest
        if (-not $artifact.Valid) {
            $artifact = New-VMateP11ColdStartArtifactManifest `
                -GpuPRoot $PSScriptRoot -Path $artifact.Path
            [void]$changes.Add('ColdStartArtifactManifest')
        }
    }
    $after = Get-VMateP11HostEnvironmentStatus `
        -RequireTestSigning:$RequireTestSigning
    $rebootReasons = [Collections.Generic.List[string]]::new()
    foreach ($reason in @($before.RebootReasons)) {
        [void]$rebootReasons.Add([string]$reason)
    }
    if (@($changes | Where-Object {
                [string]$_ -like 'HyperVAdministrators:*'
            }).Count -gt 0) {
        [void]$rebootReasons.Add('当前用户的 Hyper-V 管理令牌需要刷新')
    }
    if (@($changes | Where-Object {
                [string]$_ -ceq 'VMMS:StartPendingReboot'
            }).Count -gt 0) {
        [void]$rebootReasons.Add('VMMS 服务需要重新引导后启动')
    }
    if ($before.ForeignKernelActivity.Active) {
        [void]$rebootReasons.Add('清除外部内核/GPU 配置工具运行态')
    }
    $rebootRequired = $rebootReasons.Count -gt 0
    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        ContractId = 'vmate-p11-host-environment-repair-v1'
        Changes = @($changes | Sort-Object -Unique)
        RebootRequired = $rebootRequired
        RebootReasons = @($rebootReasons | Sort-Object -Unique)
        ReadyNow = $after.Ready
        Before = $before
        After = $after
    }
}
function Assert-VMateP11HostEnvironment {
    [CmdletBinding()]
    param([bool]$RequireTestSigning = $false)
    $status = Get-VMateP11HostEnvironmentStatus `
        -RequireTestSigning:$RequireTestSigning
    if (-not $status.Ready) {
        $reboot = if ($status.RebootRequired) { '；必须先完成宿主自动重启' }
            else { '' }
        throw "P-11 宿主环境未通过门禁$reboot：$($status.Problems -join '；')"
    }
    return $status
}
