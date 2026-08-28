# G-11 Sysprep clone one-shot finalizer. Windows PowerShell 5.1 compatible.
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Complete', 'Notice')]
    [string]$Phase = 'Auto'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Root = Join-Path $env:ProgramData 'VMate\G11'
$Portable = Join-Path $Root 'VgpuPortable.exe'
$Result = Join-Path $env:ProgramData 'QemuGpuZProfile\last-result.json'
$Marker = Join-Path $Root 'clone-initialization.json'
$ErrorFile = Join-Path $Root 'clone-initialization-error.txt'
$DlsHost = 'dls.gvmates.com'
$DlsPort = 443
$ExpectedDriver = '31.0.15.3833'
$ExpectedPnpPrefix = 'PCI\VEN_10DE&DEV_1E30'
$ProjectionStateRoot = Join-Path $env:ProgramData 'G11\SystemNvapiProjection'
$ProjectionReceiptRoot = Join-Path $ProjectionStateRoot 'receipts'
$ContinuationTaskName = 'VMate-G11-Clone-Continuation'
$ContinuationNoticeTaskName = 'VMate-G11-Clone-Notice'
$GuestLiteRoot = Join-Path $Root 'GuestLite'
$GuestLiteManifestPath = Join-Path $GuestLiteRoot 'clone-manifest.json'
$GuestLiteStatePath = Join-Path $env:ProgramData 'G11GuestLite\state.json'
$GuestLiteEnforcementLogPath = Join-Path $env:ProgramData `
    'G11GuestLite\enforce-last.txt'
$GuestLiteProfileVersion = '2.6.4'
$ExpectedGuestLiteManifestSha256 = '1C3A590BFBF8BF37FE7743475D75A9FEE8DA454346C740AEA6F6D7F98FD13E70'
$GuestLiteEnglishInputTip = '0409:00000409'
$GuestLitePinyinLanguageTags = @('zh-CN', 'zh-Hans-CN')
$GuestLitePinyinInputTip = '0804:{81D4E9C9-1D3B-41BC-9E6C-4B40BF79E35E}{FA550B04-5AD7-411F-A5AC-CA038EC515D7}'

function Write-AtomicUtf8Json {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $temporary = "$Path.new.$PID"
    $json = $Value | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Get-GuestUuid {
    $products = @(Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop)
    if ($products.Count -ne 1) {
        throw "Expected one Win32_ComputerSystemProduct; observed $($products.Count)."
    }
    return ([Guid]$products[0].UUID).ToString('D').ToLowerInvariant()
}

function Get-WindowsOsIdentity {
    $machineGuidValue = [string](Get-ItemProperty -LiteralPath `
        'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid `
        -ErrorAction Stop).MachineGuid
    try {
        $machineGuid = ([Guid]$machineGuidValue).ToString('D').ToLowerInvariant()
    } catch {
        throw "Windows MachineGuid is invalid: $machineGuidValue"
    }

    $machineSids = @(Get-CimInstance Win32_UserAccount -OperationTimeoutSec 15 `
        -ErrorAction Stop |
        Where-Object { [bool]$_.LocalAccount } |
        ForEach-Object {
            $match = [regex]::Match([string]$_.SID,
                '^(S-1-5-21-[0-9]+-[0-9]+-[0-9]+)-[0-9]+$')
            if ($match.Success) { $match.Groups[1].Value }
        } | Sort-Object -Unique)
    if ($machineSids.Count -ne 1) {
        throw "Expected one local Windows machine SID; observed $($machineSids.Count)."
    }
    $computerName = [string]$env:COMPUTERNAME
    if ($computerName -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$') {
        throw "Windows computer name is invalid: $computerName"
    }
    return [pscustomobject]@{
        MachineGuid = $machineGuid
        MachineSid = [string]$machineSids[0]
        ComputerName = $computerName.ToUpperInvariant()
    }
}

function Test-DlsEndpoint {
    param([int]$TimeoutMilliseconds = 3000)
    $client = New-Object Net.Sockets.TcpClient
    try {
        $pending = $client.BeginConnect($DlsHost, $DlsPort, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            return $false
        }
        $client.EndConnect($pending)
        return $client.Connected
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Wait-DlsEndpoint {
    $deadline = [DateTime]::UtcNow.AddMinutes(5)
    do {
        if (Test-DlsEndpoint) { return }
        Start-Sleep -Seconds 5
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Cannot connect to ${DlsHost}:${DlsPort} after five minutes."
}

function Disable-OneShotAutoLogon {
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -LiteralPath $winlogon -Name AutoAdminLogon -Value '0' `
        -ErrorAction Stop
    foreach ($name in @('DefaultPassword', 'AutoLogonCount', 'ForceAutoLogon')) {
        Remove-ItemProperty -LiteralPath $winlogon -Name $name -Force `
            -ErrorAction SilentlyContinue
    }
}

function Finalize-BootstrapAdministrator {
    $accounts = @(Get-CimInstance Win32_UserAccount -OperationTimeoutSec 15 `
        -ErrorAction Stop | Where-Object {
            [bool]$_.LocalAccount -and [string]$_.SID -match '-500$'
        })
    if ($accounts.Count -ne 1) {
        throw "Expected one built-in Administrator account; observed $($accounts.Count)."
    }

    $administratorGroups = @(Get-CimInstance Win32_Group -OperationTimeoutSec 15 `
        -ErrorAction Stop | Where-Object {
            [bool]$_.LocalAccount -and [string]$_.SID -ceq 'S-1-5-32-544'
        })
    if ($administratorGroups.Count -ne 1) {
        throw "Expected one local Administrators group; observed $($administratorGroups.Count)."
    }
    $otherEnabledAdministrators = @(Get-CimAssociatedInstance `
        -InputObject $administratorGroups[0] -Association Win32_GroupUser `
        -OperationTimeoutSec 15 -ErrorAction Stop | Where-Object {
            $_.CimClass.CimClassName -ceq 'Win32_UserAccount' -and
            [bool]$_.LocalAccount -and -not [bool]$_.Disabled -and
            [string]$_.SID -cne [string]$accounts[0].SID
        })

    # A template is supposed to retain a separate daily administrator, but a
    # missing account must never turn a successful clone into an unusable
    # machine.  Keep the RID-500 account available for the local console when
    # it is the only administrator; LimitBlankPasswordUse remains enabled.
    $activeSwitch = '/active:no'
    if ($otherEnabledAdministrators.Count -eq 0) {
        $activeSwitch = '/active:yes'
        Write-Warning 'No other enabled local administrator exists; keeping the built-in Administrator available for local-console sign-in.'
    }
    $net = Join-Path $env:SystemRoot 'System32\net.exe'
    $output = @(& $net user ([string]$accounts[0].Name) $activeSwitch 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not finalize the built-in Administrator state: $($output -join ' ')"
    }
}

function Read-And-ValidateResult {
    param([Parameter(Mandatory = $true)][string]$GuestUuid)
    if (-not (Test-Path -LiteralPath $Result -PathType Leaf)) {
        throw "VgpuPortable result is missing: $Result"
    }
    $receipt = Get-Content -LiteralPath $Result -Raw -Encoding UTF8 |
        ConvertFrom-Json -ErrorAction Stop
    if ([string]$receipt.receiptType -cne 'vgpu-identity-portable-final' -or
        [int]$receipt.schemaVersion -ne 4 -or
        [string]$receipt.bindingMode -cne 'portable-auto' -or
        -not [bool]$receipt.privateLicensedFinalizer) {
        throw 'VgpuPortable did not publish the licensed private schema-4 result.'
    }
    if (([Guid]$receipt.observedVmUuid).ToString('D').ToLowerInvariant() -cne $GuestUuid) {
        throw 'VgpuPortable result belongs to another VM UUID.'
    }
    if ([string]$receipt.driverVersion -cne $ExpectedDriver -or
        [string]$receipt.pnpDeviceId -notlike "$ExpectedPnpPrefix*") {
        throw 'The final NVIDIA device is not native DEV_1E30 with GRID 538.33.'
    }
    if ([string]$receipt.license.licenseStatus -cne 'Licensed') {
        throw 'NVIDIA vGPU license status is not Licensed.'
    }
    if ([bool]$receipt.testsigning -or [bool]$receipt.nointegritychecks -or
        [bool]$receipt.systemNvapiChanged) {
        throw 'The final result violates the production code-integrity/NVAPI policy.'
    }
    $controllers = @(Get-CimInstance Win32_VideoController -ErrorAction Stop |
        Where-Object { [string]$_.PNPDeviceID -like "$ExpectedPnpPrefix*" })
    if ($controllers.Count -ne 1 -or
        [uint32]$controllers[0].ConfigManagerErrorCode -ne 0 -or
        [string]$controllers[0].DriverVersion -cne $ExpectedDriver) {
        throw 'Expected exactly one Code-0 GRID 538.33 DEV_1E30 display controller.'
    }
    return $receipt
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-PlainFile([string]$Path, [string]$Context) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item -isnot [IO.FileInfo] -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Context must be a regular, non-reparse file: $Path"
    }
    return $item
}

function Read-And-ValidateGuestLitePayload {
    $manifestItem = Get-PlainFile $GuestLiteManifestPath `
        'Guest Lite clone manifest'
    if ((Get-Sha256 $manifestItem.FullName) -cne
        $ExpectedGuestLiteManifestSha256) {
        throw 'Guest Lite clone manifest differs from the attested finalizer.'
    }
    $manifest = Get-Content -LiteralPath $manifestItem.FullName -Raw `
        -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $expectedNames = @(
        '01-OneClick-Apply.cmd', '02-Audit.cmd', '03-Rollback.cmd',
        'G11-Guest-Lite.ps1', 'README.txt'
    )
    $files = @($manifest.files)
    $names = @($files | ForEach-Object { [string]$_.name } | Sort-Object)
    if ([int]$manifest.schemaVersion -ne 1 -or
        [string]$manifest.profileVersion -cne $GuestLiteProfileVersion -or
        $files.Count -ne $expectedNames.Count -or
        (($names -join '|') -cne (($expectedNames | Sort-Object) -join '|'))) {
        throw 'Guest Lite clone manifest has an unexpected schema or file set.'
    }
    foreach ($row in $files) {
        $name = [string]$row.name
        if ($name -cnotmatch '^(?:0[123]-(?:OneClick-Apply|Audit|Rollback)\.cmd|G11-Guest-Lite\.ps1|README\.txt)$' -or
            [string]$row.sha256 -cnotmatch '^[0-9A-F]{64}$' -or
            [int64]$row.bytes -le 0) {
            throw "Guest Lite clone manifest entry is invalid: $name"
        }
        $item = Get-PlainFile (Join-Path $GuestLiteRoot $name) `
            "Guest Lite asset '$name'"
        if ([int64]$item.Length -ne [int64]$row.bytes -or
            (Get-Sha256 $item.FullName) -cne [string]$row.sha256) {
            throw "Guest Lite clone asset failed its content check: $name"
        }
    }
    return (Join-Path $GuestLiteRoot 'G11-Guest-Lite.ps1')
}

function Open-GuestLiteUserHive {
    param([Parameter(Mandatory = $true)][string]$UserSid)

    $loadedRoot = "Registry::HKEY_USERS\$UserSid"
    if (Test-Path -LiteralPath $loadedRoot -PathType Container) {
        return [pscustomobject]@{
            RootPath = $loadedRoot
            MountName = ''
            LoadedByThisProcess = $false
        }
    }

    $profiles = @(Get-CimInstance Win32_UserProfile -OperationTimeoutSec 15 `
        -ErrorAction Stop | Where-Object {
            [string]$_.SID -ceq $UserSid -and
            -not [string]::IsNullOrWhiteSpace([string]$_.LocalPath)
        })
    if ($profiles.Count -ne 1) {
        throw "Expected one Windows profile for Guest Lite SID $UserSid; observed $($profiles.Count)."
    }
    $hiveItem = Get-PlainFile (Join-Path ([string]$profiles[0].LocalPath) `
        'NTUSER.DAT') 'Guest Lite user registry hive'
    $mountName = "G11GuestLiteVerify_$PID"
    $mountRoot = "Registry::HKEY_USERS\$mountName"
    if (Test-Path -LiteralPath $mountRoot) {
        throw "Temporary Guest Lite registry mount already exists: $mountName"
    }
    $regExe = Join-Path $env:SystemRoot 'System32\reg.exe'
    $loadOutput = @(& $regExe load "HKU\$mountName" `
        $hiveItem.FullName 2>&1)
    if ($LASTEXITCODE -ne 0 -or
        -not (Test-Path -LiteralPath $mountRoot -PathType Container)) {
        throw "Could not load the Guest Lite user registry hive: $($loadOutput -join ' ')"
    }
    return [pscustomobject]@{
        RootPath = $mountRoot
        MountName = $mountName
        LoadedByThisProcess = $true
    }
}

function Close-GuestLiteUserHive {
    param([Parameter(Mandatory = $true)][object]$Hive)

    if (-not [bool]$Hive.LoadedByThisProcess) { return }
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    $regExe = Join-Path $env:SystemRoot 'System32\reg.exe'
    $unloadOutput = @(& $regExe unload "HKU\$($Hive.MountName)" 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not unload the temporary Guest Lite user registry hive: $($unloadOutput -join ' ')"
    }
}

function Resolve-GuestLiteRegistryPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$UserHive
    )

    if ($Path.StartsWith('HKCU:\', [StringComparison]::OrdinalIgnoreCase)) {
        return ('{0}\{1}' -f [string]$UserHive.RootPath,
            $Path.Substring(6))
    }
    return $Path
}

function Read-And-ValidateGuestLiteState {
    param([switch]$RequireFirewallReady)

    $stateItem = Get-PlainFile $GuestLiteStatePath `
        'Guest Lite rollback state'
    $state = Get-Content -LiteralPath $stateItem.FullName -Raw -Encoding UTF8 |
        ConvertFrom-Json -ErrorAction Stop
    $osIdentity = Get-WindowsOsIdentity
    try {
        $stateMachineGuid = ([Guid]([string]$state.MachineGuid)).ToString('D').ToLowerInvariant()
    } catch {
        throw "Guest Lite rollback state contains an invalid MachineGuid: $($state.MachineGuid)"
    }
    $bootstrapAccounts = @(Get-CimInstance Win32_UserAccount `
        -OperationTimeoutSec 15 -ErrorAction Stop | Where-Object {
            [bool]$_.LocalAccount -and [string]$_.SID -match '-500$'
        })
    if ($bootstrapAccounts.Count -ne 1 -or
        [int]$state.SchemaVersion -ne 6 -or
        $stateMachineGuid -cne [string]$osIdentity.MachineGuid -or
        [string]$state.UserSid -cne [string]$bootstrapAccounts[0].SID) {
        throw 'Guest Lite rollback state is not bound to this clone/bootstrap user.'
    }
    $audioBaseline = $state.PSObject.Properties['AudioEndpoint']
    $languageBaseline = $state.PSObject.Properties['UserLanguageList']
    $nvidiaBaseline = $state.PSObject.Properties['NvidiaPowerMode']
    $dnfBaseline = $state.PSObject.Properties['DnfProcesses']
    $cleanupSummary = $state.PSObject.Properties['LastTemporaryCleanup']
    if ($null -eq $audioBaseline -or
        -not [bool]$audioBaseline.Value.Available -or
        $null -eq $languageBaseline -or
        -not [bool]$languageBaseline.Value.Available -or
        $null -eq $nvidiaBaseline -or
        -not [bool]$nvidiaBaseline.Value.Available -or
        $null -eq $dnfBaseline -or
        $null -eq $cleanupSummary -or
        [int]$cleanupSummary.Value.MinimumAgeHours -ne 24 -or
        [int]$cleanupSummary.Value.RootsProcessed -lt 1) {
        throw 'Guest Lite rollback state lacks the audio/language/NVIDIA/DNF baseline or the temporary-cleanup receipt.'
    }

    $task = Get-ScheduledTask -TaskPath '\' `
        -TaskName 'G11GuestLite-EnforceProfile' -ErrorAction Stop
    if (-not [bool]$task.Settings.Enabled -or
        [string]$task.Principal.RunLevel -cne 'Highest' -or
        [string]$task.Principal.UserId -notin @('SYSTEM', 'S-1-5-18')) {
        throw 'Guest Lite Local System enforcement task is absent or unsafe.'
    }
    foreach ($policyPath in @(
        (Join-Path $env:SystemRoot 'System32\GroupPolicy\Machine\Registry.pol'),
        (Join-Path $env:SystemRoot 'System32\GroupPolicy\User\Registry.pol'),
        (Join-Path $env:SystemRoot 'System32\GroupPolicy\gpt.ini')
    )) {
        if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) {
            throw "Guest Lite local-policy persistence is missing: $policyPath"
        }
    }

    $userHive = Open-GuestLiteUserHive -UserSid ([string]$state.UserSid)
    try {
        foreach ($expected in @(
            [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications'; Name = 'ToastEnabled'; Value = 0; Type = 'DWord' },
            [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications'; Name = 'NoToastApplicationNotification'; Value = 1; Type = 'DWord' },
            [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications'; Name = 'NoToastApplicationNotificationOnLockScreen'; Value = 1; Type = 'DWord' },
            [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'DisableNotificationCenter'; Value = 1; Type = 'DWord' },
            [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search'; Name = 'SearchboxTaskbarMode'; Value = 0; Type = 'DWord' },
            [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'; Name = 'AllowGameDVR'; Value = 0; Type = 'DWord' },
            [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'HistoricalCaptureEnabled'; Value = 0; Type = 'DWord' },
            [pscustomobject]@{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_Enabled'; Value = 0; Type = 'DWord' },
            [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\GameBar'; Name = 'AllowAutoGameMode'; Value = 1; Type = 'DWord' },
            [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\GameBar'; Name = 'AutoGameModeEnabled'; Value = 1; Type = 'DWord' },
            [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\DNF.exe\PerfOptions'; Name = 'CpuPriorityClass'; Value = 3; Type = 'DWord' },
            [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\DNFClient.exe\PerfOptions'; Name = 'CpuPriorityClass'; Value = 3; Type = 'DWord' },
            [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\DNFChina.exe\PerfOptions'; Name = 'CpuPriorityClass'; Value = 3; Type = 'DWord' },
            [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\DNFLauncher.exe\PerfOptions'; Name = 'CpuPriorityClass'; Value = 3; Type = 'DWord' },
            [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications'; Name = 'DisableNotifications'; Value = 1; Type = 'DWord' },
            [pscustomobject]@{ Path = 'HKCU:\Control Panel\International\User Profile'; Name = 'InputMethodOverride'; Value = '0409:00000409'; Type = 'String' }
        )) {
            $resolvedPath = Resolve-GuestLiteRegistryPath `
                -Path ([string]$expected.Path) -UserHive $userHive
            $key = Get-Item -LiteralPath $resolvedPath -ErrorAction Stop
            try {
                if (@($key.GetValueNames()) -notcontains [string]$expected.Name) {
                    throw "Guest Lite setting is missing: $($expected.Path)\$($expected.Name)"
                }
                $actual = $key.GetValue(
                    [string]$expected.Name, $null,
                    [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
                )
                $matches = if ([string]$expected.Type -ceq 'DWord') {
                    [int64]$actual -eq [int64]$expected.Value
                } else {
                    [string]$actual -ceq [string]$expected.Value
                }
                if (-not $matches) {
                    throw "Guest Lite setting differs: $($expected.Path)\$($expected.Name) current=$actual desired=$($expected.Value)"
                }
            } finally {
                $key.Close()
            }
        }

        # The continuation task runs as Local System after the internal reboot.
        # Get-WinUserLanguageList would therefore inspect SYSTEM's HKCU. Read the
        # saved clone user's hive directly so notification and input assertions
        # are bound to state.UserSid in both interactive and SYSTEM phases.
        $languageRoot = '{0}\Control Panel\International\User Profile' -f `
            [string]$userHive.RootPath
        $languageKey = Get-Item -LiteralPath $languageRoot -ErrorAction Stop
        try {
            $languageList = @($languageKey.GetValue(
                'Languages', [string[]]@(),
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
            ))
        } finally {
            $languageKey.Close()
        }
        if ($languageList.Count -lt 2 -or
            [string]$languageList[0] -ine 'en-US' -or
            [string]$languageList[1] -notin $GuestLitePinyinLanguageTags) {
            throw 'Guest Lite input order is not en-US/US first and zh-CN/Microsoft Pinyin second.'
        }
        foreach ($input in @(
            [pscustomobject]@{ Language = [string]$languageList[0]; Tip = $GuestLiteEnglishInputTip },
            [pscustomobject]@{ Language = [string]$languageList[1]; Tip = $GuestLitePinyinInputTip }
        )) {
            $inputKey = Get-Item -LiteralPath (Join-Path $languageRoot `
                ([string]$input.Language)) -ErrorAction Stop
            try {
                if (@($inputKey.GetValueNames()) -inotcontains [string]$input.Tip) {
                    throw "Guest Lite input method is missing: $($input.Language)/$($input.Tip)"
                }
            } finally {
                $inputKey.Close()
            }
        }
    } finally {
        Close-GuestLiteUserHive -Hive $userHive
    }

    $firewall = Get-CimInstance Win32_Service -Filter "Name='MpsSvc'" `
        -ErrorAction Stop
    if ([string]$firewall.StartMode -cne 'Auto') {
        throw "Guest Lite did not preserve MpsSvc Automatic startup: $($firewall.StartMode)"
    }
    if ($RequireFirewallReady -and
        ([string]$firewall.State -cne 'Running' -or
         [uint32]$firewall.ProcessId -eq 0)) {
        throw "MpsSvc is unavailable after clone verification reboot: state=$($firewall.State) pid=$($firewall.ProcessId)"
    }
    $bfe = Get-CimInstance Win32_Service -Filter "Name='BFE'" -ErrorAction Stop
    if ([string]$bfe.StartMode -cne 'Auto' -or
        [string]$bfe.State -cne 'Running') {
        throw "Guest Lite did not preserve the Base Filtering Engine: start=$($bfe.StartMode) state=$($bfe.State)"
    }
    return [pscustomobject]@{
        UserSid = [string]$state.UserSid
        FirewallStartMode = [string]$firewall.StartMode
        FirewallState = [string]$firewall.State
        FirewallProcessId = [uint32]$firewall.ProcessId
        Notifications = 'disabled'
        TaskbarSearch = 'hidden'
        DefaultInputMethod = '0409:00000409'
        InputOrder = 'en-US/US,zh-CN/Microsoft-Pinyin'
        Audio = 'muted'
        GameMode = 'enabled'
        GameDvr = 'disabled'
        NvidiaPowerMode = 'prefer-maximum-performance'
        DnfPriority = 'high-on-launch'
        TemporaryCleanup = 'stale-files-over-24h-completed'
        BackgroundProcesses = 'reviewed-stopped'
    }
}

function Read-And-ValidateGuestLiteEnforcementReceipt {
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedUserSid,
        [Parameter(Mandatory = $true)][string]$ExpectedMachineGuid,
        [Parameter(Mandatory = $true)][string]$ExpectedComputerName,
        [Parameter(Mandatory = $true)][DateTime]$MinimumGeneratedTime
    )

    $logItem = Get-PlainFile $GuestLiteEnforcementLogPath `
        'Guest Lite enforcement log'
    $lines = @(Get-Content -LiteralPath $logItem.FullName -Encoding UTF8)
    $generatedLines = @($lines | Where-Object {
        [string]$_ -match '^generated=.+ mode=Enforce$'
    })
    if ($generatedLines.Count -ne 1) {
        throw 'Guest Lite enforcement log has no unique generated receipt.'
    }
    $generatedMatch = [regex]::Match(
        [string]$generatedLines[0], '^generated=(.+) mode=Enforce$'
    )
    if (-not $generatedMatch.Success) {
        throw 'Guest Lite enforcement log has an invalid generated receipt.'
    }
    try {
        $generatedAt = [DateTimeOffset]::Parse(
            [string]$generatedMatch.Groups[1].Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
    } catch {
        throw 'Guest Lite enforcement generated time is invalid.'
    }
    if ($generatedAt.UtcDateTime -lt $MinimumGeneratedTime.ToUniversalTime()) {
        throw 'Guest Lite enforcement receipt predates the current Windows boot.'
    }

    $expectedIdentity = 'identity=validated computer={0} machineGuid={1} sid={2}' -f
        $ExpectedComputerName, $ExpectedMachineGuid, $ExpectedUserSid
    if ($lines -cnotcontains $expectedIdentity) {
        throw 'Guest Lite enforcement receipt does not match this clone identity.'
    }
    foreach ($requiredLine in @(
        'firewallService=automatic-running',
        'audio=default-render-muted',
        'processes=reviewed-stopped',
        'nvidiaPowerMode=prefer-maximum-performance',
        'dnfPriority=high-if-running',
        'result=pass failures=0'
    )) {
        if ($lines -cnotcontains $requiredLine) {
            throw "Guest Lite enforcement receipt is incomplete: $requiredLine"
        }
    }
    return $generatedAt
}

function Invoke-And-WaitGuestLiteEnforcement {
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedUserSid,
        [Parameter(Mandatory = $true)][string]$ExpectedMachineGuid,
        [Parameter(Mandatory = $true)][string]$ExpectedComputerName
    )

    $taskPath = '\'
    $taskName = 'G11GuestLite-EnforceProfile'
    $deadline = [DateTime]::Now.AddMinutes(10)
    $operatingSystems = @(Get-CimInstance Win32_OperatingSystem `
        -OperationTimeoutSec 15 -ErrorAction Stop)
    if ($operatingSystems.Count -ne 1) {
        throw "Expected one Windows operating system; observed $($operatingSystems.Count)."
    }
    $lastBootTime = [DateTime]$operatingSystems[0].LastBootUpTime

    # Do not race the delayed startup/logon trigger. Its clean, identity-bound
    # current-boot receipt is already the required post-reboot SYSTEM run.
    do {
        $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName `
            -ErrorAction Stop
        if ([string]$task.State -notin @('Running', 'Queued')) { break }
        Start-Sleep -Seconds 2
    } while ([DateTime]::Now -lt $deadline)
    if ([string]$task.State -in @('Running', 'Queued')) {
        throw 'Guest Lite enforcement task did not become idle within ten minutes.'
    }

    $info = Get-ScheduledTaskInfo -TaskPath $taskPath `
        -TaskName $taskName -ErrorAction Stop
    $receipt = $null
    if ([int64]$info.LastTaskResult -eq 0 -and
        $info.LastRunTime -gt $lastBootTime) {
        try {
            $receipt = Read-And-ValidateGuestLiteEnforcementReceipt `
                -ExpectedUserSid $ExpectedUserSid `
                -ExpectedMachineGuid $ExpectedMachineGuid `
                -ExpectedComputerName $ExpectedComputerName `
                -MinimumGeneratedTime $lastBootTime
            Write-Host 'Reusing the clean Guest Lite SYSTEM enforcement receipt from this Windows boot.' `
                -ForegroundColor DarkGray
        } catch {
            $receipt = $null
        }
    }

    if ($null -eq $receipt) {
        $previousRunTime = $info.LastRunTime
        Start-ScheduledTask -TaskPath $taskPath -TaskName $taskName `
            -ErrorAction Stop
        $deadline = [DateTime]::Now.AddMinutes(10)
        $completed = $false
        do {
            Start-Sleep -Seconds 2
            $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName `
                -ErrorAction Stop
            $info = Get-ScheduledTaskInfo -TaskPath $taskPath `
                -TaskName $taskName -ErrorAction Stop
            if ([string]$task.State -notin @('Running', 'Queued') -and
                $info.LastRunTime -gt $previousRunTime) {
                $completed = $true
                break
            }
        } while ([DateTime]::Now -lt $deadline)
        if (-not $completed) {
            throw 'Guest Lite enforcement task did not finish within ten minutes.'
        }
        if ([int64]$info.LastTaskResult -ne 0) {
            throw "Guest Lite enforcement task failed: result=$($info.LastTaskResult), lastRun=$($info.LastRunTime.ToString('o'))."
        }
        $receipt = Read-And-ValidateGuestLiteEnforcementReceipt `
            -ExpectedUserSid $ExpectedUserSid `
            -ExpectedMachineGuid $ExpectedMachineGuid `
            -ExpectedComputerName $ExpectedComputerName `
            -MinimumGeneratedTime $lastBootTime
    }
    return [pscustomobject]@{
        LastRunTime = $info.LastRunTime.ToString('o')
        LastTaskResult = [int64]$info.LastTaskResult
    }
}

function Invoke-GuestLiteCloneProfile {
    $script = Read-And-ValidateGuestLitePayload
    $powerShell = Join-Path $env:SystemRoot `
        'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Mode CloneApply' `
        -f $script.Replace('"', '""')
    $logRoot = Join-Path $Root 'logs'
    if (-not (Test-Path -LiteralPath $logRoot -PathType Container)) {
        New-Item -Path $logRoot -ItemType Directory -Force -ErrorAction Stop |
            Out-Null
    }
    $logRootItem = Get-Item -LiteralPath $logRoot -Force -ErrorAction Stop
    if ($logRootItem -isnot [IO.DirectoryInfo] -or
        ($logRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Clone log root must be a regular, non-reparse directory: $logRoot"
    }
    $standardOutput = Join-Path $logRoot 'guest-lite-clone-apply-output.txt'
    $standardError = Join-Path $logRoot 'guest-lite-clone-apply-error.txt'
    Remove-Item -LiteralPath $standardOutput, $standardError -Force `
        -ErrorAction SilentlyContinue
    $process = Start-Process -FilePath $powerShell -ArgumentList $arguments `
        -WorkingDirectory $GuestLiteRoot -WindowStyle Hidden `
        -RedirectStandardOutput $standardOutput `
        -RedirectStandardError $standardError -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        $detail = ''
        foreach ($candidate in @($standardError, $standardOutput)) {
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                continue
            }
            $candidateDetail = (@(Get-Content -LiteralPath $candidate -Tail 12 `
                -ErrorAction SilentlyContinue) -join ' | ').Trim()
            if (-not [string]::IsNullOrWhiteSpace($candidateDetail)) {
                $detail = $candidateDetail
                break
            }
        }
        throw "Guest Lite clone profile failed with exit code $($process.ExitCode). Review the exact protected/failed items in the preserved logs; Tamper Protection must be turned off manually and must not be bypassed. Logs: $standardOutput / $standardError. $detail"
    }
    return (Read-And-ValidateGuestLiteState)
}

function Read-ProjectionPayloadCandidate {
    param(
        [Parameter(Mandatory = $true)][string]$CandidateRoot,
        [Parameter(Mandatory = $true)][string]$GuestUuid,
        [Parameter(Mandatory = $true)]$PortableReceipt
    )
    $manifestPath = Join-Path $CandidateRoot 'system-nvapi-manifest.json'
    $contractPath = Join-Path $CandidateRoot 'system-nvapi-contract.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $contractPath -PathType Leaf)) {
        return $null
    }
    $rootItem = Get-Item -LiteralPath $CandidateRoot -Force -ErrorAction Stop
    if ($rootItem -isnot [IO.DirectoryInfo] -or
        ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "System NVAPI payload root is not a plain directory: $CandidateRoot"
    }
    $manifestItem = Get-PlainFile $manifestPath 'System NVAPI manifest'
    $contractItem = Get-PlainFile $contractPath 'System NVAPI contract'
    $manifest = Get-Content -LiteralPath $manifestItem.FullName -Raw -Encoding UTF8 |
        ConvertFrom-Json -ErrorAction Stop
    $contract = Get-Content -LiteralPath $contractItem.FullName -Raw -Encoding UTF8 |
        ConvertFrom-Json -ErrorAction Stop
    if ([string]$contract.purpose -cne 'g11-system-nvapi-projection') {
        return $null
    }
    try {
        $contractUuid = ([Guid]$contract.vmUuid).ToString('D').ToLowerInvariant()
    } catch {
        throw "System NVAPI contract has an invalid VM UUID: $contractPath"
    }
    if ($contractUuid -cne $GuestUuid) { return $null }
    if ([int]$contract.schemaVersion -ne 4 -or
        [string]$contract.contractId -cnotmatch '^[0-9A-F]{64}$' -or
        [int64]$contract.vmId -lt 1 -or [int64]$contract.vmId -gt 2147483647 -or
        [string]$contract.profile.key -cne [string]$PortableReceipt.gpuProfile -or
        [string]$contract.monitor.key -cnotmatch '^[a-z0-9][a-z0-9-]{0,47}$' -or
        [string]$contract.transport.targetPnpId -cne $ExpectedPnpPrefix -or
        [string]$contract.transport.driverVersion -cne $ExpectedDriver -or
        [string]$manifest.purpose -cne 'g11-system-nvapi-projection' -or
        [int]$manifest.schemaVersion -ne 1 -or
        [string]$manifest.contractId -cne [string]$contract.contractId) {
        throw 'System NVAPI package is not bound to this licensed VM/profile.'
    }
    $coordinator = Get-PlainFile (Join-Path $CandidateRoot `
        'install-system-nvapi-projection.ps1') 'System NVAPI coordinator'
    if ((Get-Sha256 $coordinator.FullName) -cne
        [string]$contract.payload.coordinatorSha256) {
        throw 'System NVAPI coordinator digest differs from the VM-bound contract.'
    }
    return [pscustomobject]@{
        Root = $rootItem.FullName
        Manifest = $manifest
        Contract = $contract
        Coordinator = $coordinator.FullName
    }
}

function Find-SystemProjectionPayload {
    param(
        [Parameter(Mandatory = $true)][string]$GuestUuid,
        [Parameter(Mandatory = $true)]$PortableReceipt
    )
    $candidateRoots = @{}
    if (Test-Path -LiteralPath $ProjectionStateRoot -PathType Container) {
        foreach ($directory in @(Get-ChildItem -LiteralPath $ProjectionStateRoot `
                -Directory -Force -ErrorAction Stop)) {
            if ($directory.Name -cmatch '^[0-9A-F]{64}$') {
                $candidateRoots[$directory.FullName] = $true
            }
        }
    }
    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        try {
            if ($drive.IsReady) {
                $candidateRoots[$drive.RootDirectory.FullName] = $true
            }
        } catch {
            # A removable drive can disappear while Windows enumerates it.
        }
    }
    $matches = @()
    foreach ($candidate in @($candidateRoots.Keys | Sort-Object)) {
        $payload = Read-ProjectionPayloadCandidate -CandidateRoot $candidate `
            -GuestUuid $GuestUuid -PortableReceipt $PortableReceipt
        if ($null -ne $payload) { $matches += $payload }
    }
    $contractIds = @($matches | ForEach-Object {
            [string]$_.Contract.contractId
        } | Sort-Object -Unique)
    if ($contractIds.Count -ne 1) {
        throw "Expected one VM-bound system NVAPI contract; observed $($contractIds.Count)."
    }
    $durableRoot = Join-Path $ProjectionStateRoot $contractIds[0]
    $preferred = @($matches | Where-Object {
            [string]$_.Root -ieq $durableRoot
        })
    if ($preferred.Count -eq 1) { return $preferred[0] }
    return @($matches | Where-Object {
            [string]$_.Contract.contractId -ceq $contractIds[0]
        })[0]
}

function Read-And-ValidateProjectionReceipt {
    param(
        [Parameter(Mandatory = $true)]$Projection,
        [Parameter(Mandatory = $true)][string]$GuestUuid,
        [Parameter(Mandatory = $true)]$PortableReceipt
    )
    $contract = $Projection.Contract
    $receiptPath = Join-Path $ProjectionReceiptRoot (
        ([string]$contract.contractId) + '-validated.json')
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
        return $null
    }
    $item = Get-PlainFile $receiptPath 'System NVAPI validated receipt'
    $receipt = Get-Content -LiteralPath $item.FullName -Raw -Encoding UTF8 |
        ConvertFrom-Json -ErrorAction Stop
    if ([int]$receipt.schemaVersion -ne 2 -or
        [string]$receipt.purpose -cne 'g11-system-nvapi-projection' -or
        [string]$receipt.state -cne 'validated' -or
        [string]$receipt.contractId -cne [string]$contract.contractId -or
        [int64]$receipt.vmId -ne [int64]$contract.vmId -or
        ([Guid]$receipt.vmUuid).ToString('D').ToLowerInvariant() -cne $GuestUuid -or
        [string]$receipt.gpuProfile -cne [string]$PortableReceipt.gpuProfile -or
        [string]$receipt.monitorProfile -cne [string]$contract.monitor.key -or
        [string]$receipt.driverVersion -cne $ExpectedDriver -or
        -not [bool]$receipt.driverSigned -or
        [string]$receipt.displayInstanceId -notlike "$ExpectedPnpPrefix*" -or
        [string]$receipt.monitorInstanceId -notlike 'DISPLAY\*' -or
        [string]$receipt.shimX86Sha256 -cne [string]$contract.payload.shimX86Sha256 -or
        [string]$receipt.shimX64Sha256 -cne [string]$contract.payload.shimX64Sha256 -or
        [bool]$receipt.testsigning -or [bool]$receipt.nointegritychecks -or
        [string]$receipt.bcdSha256 -cnotmatch '^[0-9A-F]{64}$') {
        throw 'System NVAPI validated receipt does not match this VM or production policy.'
    }
    return $receipt
}

function Test-ProjectionPendingReceipt {
    param(
        [Parameter(Mandatory = $true)]$Projection,
        [Parameter(Mandatory = $true)][string]$GuestUuid
    )
    $contract = $Projection.Contract
    $path = Join-Path $ProjectionReceiptRoot (
        ([string]$contract.contractId) + '-pending-reboot.json')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    $item = Get-PlainFile $path 'System NVAPI pending receipt'
    $receipt = Get-Content -LiteralPath $item.FullName -Raw -Encoding UTF8 |
        ConvertFrom-Json -ErrorAction Stop
    if ([int]$receipt.schemaVersion -ne 2 -or
        [string]$receipt.purpose -cne 'g11-system-nvapi-projection' -or
        [string]$receipt.state -cne 'pending-reboot' -or
        [string]$receipt.contractId -cne [string]$contract.contractId -or
        ([Guid]$receipt.vmUuid).ToString('D').ToLowerInvariant() -cne $GuestUuid -or
        [bool]$receipt.testsigning -or [bool]$receipt.nointegritychecks) {
        throw 'System NVAPI pending receipt is invalid.'
    }
    return $true
}

function ConvertFrom-Utf8Base64 {
    param([Parameter(Mandatory = $true)][string]$Value)
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value))
}

function Show-CloneContinuationNotice {
    # Keep this source file ASCII so Windows PowerShell 5.1 can load it without
    # relying on a BOM. User-facing Chinese text is decoded only at runtime.
    $title = ConvertFrom-Utf8Base64 `
        'Vk1hdGUgRy0xMSDlhYvpmobliJ3lp4vljJbov5vooYzkuK0='
    $headingText = ConvertFrom-Utf8Base64 `
        '5YWL6ZqG5Yid5aeL5YyW5LuN5Zyo57un57ut'
    $rebootText = ConvertFrom-Utf8Base64 `
        '6L+Z5piv56ys5LiA5qyh5YWL6ZqG5ZCO55qE6Ieq5Yqo6YeN5ZCv44CC6L+b5YWl5qGM6Z2i5LiN5Luj6KGo5Yid5aeL5YyW5bey57uP5a6M5oiQ44CC'
    $doNotStopText = ConvertFrom-Utf8Base64 `
        '6K+35Yu/5YWz5py644CB6YeN5ZCv5oiW5rOo6ZSA44CC5a6M5oiQ5ZCO6Jma5ouf5py65Lya6Ieq5Yqo5YWz5py644CC'
    $stageText = ConvertFrom-Utf8Base64 `
        '5b2T5YmN77ya5q2j5Zyo5a6M5oiQ6YeN5ZCv5ZCO55qE6amx5Yqo5LiO57O757uf5qOA5p+l4oCm4oCm'
    $elapsedPrefix = ConvertFrom-Utf8Base64 '5bey562J5b6F77ya'
    $minuteText = ConvertFrom-Utf8Base64 'IOWIhiA='
    $secondText = ConvertFrom-Utf8Base64 'IOenkg=='
    $completedText = ConvertFrom-Utf8Base64 `
        '5Yid5aeL5YyW5bey57uP5a6M5oiQ77yM6Jma5ouf5py65q2j5Zyo6Ieq5Yqo5YWz5py64oCm4oCm'
    $failedText = ConvertFrom-Utf8Base64 `
        '5Yid5aeL5YyW5aSx6LSl77yM6K+35Yu/5by65Yi25YWz5py644CC'
    $errorPathText = ConvertFrom-Utf8Base64 `
        '6K+35p+l55yL6ZSZ6K+v5paH5Lu277ya'
    $retryText = ConvertFrom-Utf8Base64 `
        '5L+u5aSN5ZCO77yM6K+35Lul566h55CG5ZGY6Lqr5Lu96L+Q6KGM5qGM6Z2i55qEIFJldHJ5LUNsb25lLUluaXRpYWxpemF0aW9uLmNtZOOAgg=='
    $closeText = ConvertFrom-Utf8Base64 '5YWz6Zet'
    $bodyText = $rebootText + [Environment]::NewLine + [Environment]::NewLine +
        $doNotStopText + [Environment]::NewLine + [Environment]::NewLine + $stageText

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        [System.Windows.Forms.Application]::EnableVisualStyles()

        $form = New-Object System.Windows.Forms.Form
        $form.Text = $title
        $form.ClientSize = New-Object System.Drawing.Size(640, 300)
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $form.ControlBox = $false
        $form.ShowInTaskbar = $true
        $form.TopMost = $true

        $heading = New-Object System.Windows.Forms.Label
        $heading.Location = New-Object System.Drawing.Point(28, 24)
        $heading.Size = New-Object System.Drawing.Size(584, 42)
        $heading.Font = New-Object System.Drawing.Font(
            $form.Font.FontFamily, 18,
            [System.Drawing.FontStyle]::Bold)
        $heading.Text = $headingText

        $body = New-Object System.Windows.Forms.Label
        $body.Location = New-Object System.Drawing.Point(30, 78)
        $body.Size = New-Object System.Drawing.Size(580, 112)
        $body.Font = New-Object System.Drawing.Font(
            $form.Font.FontFamily, 11,
            [System.Drawing.FontStyle]::Regular)
        $body.Text = $bodyText

        $progress = New-Object System.Windows.Forms.ProgressBar
        $progress.Location = New-Object System.Drawing.Point(32, 202)
        $progress.Size = New-Object System.Drawing.Size(576, 22)
        $progress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        $progress.MarqueeAnimationSpeed = 30

        $elapsedLabel = New-Object System.Windows.Forms.Label
        $elapsedLabel.Location = New-Object System.Drawing.Point(30, 239)
        $elapsedLabel.Size = New-Object System.Drawing.Size(430, 26)

        $closeButton = New-Object System.Windows.Forms.Button
        $closeButton.Location = New-Object System.Drawing.Point(510, 235)
        $closeButton.Size = New-Object System.Drawing.Size(98, 32)
        $closeButton.Text = $closeText
        $closeButton.Visible = $false
        $closeButton.Add_Click({ $form.Close() })

        $form.Controls.AddRange(@(
            $heading, $body, $progress, $elapsedLabel, $closeButton
        ))

        $started = [DateTime]::UtcNow
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 1000
        $timer.Add_Tick({
            $elapsed = [DateTime]::UtcNow - $started
            $elapsedLabel.Text = ('{0}{1}{2}{3}{4}' -f
                $elapsedPrefix, [int][Math]::Floor($elapsed.TotalMinutes),
                $minuteText, $elapsed.Seconds, $secondText)

            # Check the error first because a shutdown scheduling failure can be
            # reported after the host-ready marker has already been committed.
            if (Test-Path -LiteralPath $ErrorFile -PathType Leaf) {
                $timer.Stop()
                $heading.Text = $failedText
                $body.Text = $errorPathText + [Environment]::NewLine +
                    $ErrorFile + [Environment]::NewLine + [Environment]::NewLine +
                    $retryText
                $progress.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
                $progress.Value = 0
                $form.ControlBox = $true
                $closeButton.Visible = $true
            } elseif (Test-Path -LiteralPath $Marker -PathType Leaf) {
                $timer.Stop()
                $heading.Text = $completedText
                $body.Text = $doNotStopText
                $progress.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
                $progress.Value = 100
            }
        })
        $form.Add_FormClosed({
            $timer.Stop()
            $timer.Dispose()
        })
        $timer.Start()
        [System.Windows.Forms.Application]::Run($form)
    } catch {
        # A minimal built-in fallback still gives the operator an explicit
        # warning if WinForms cannot initialize in the interactive session.
        try {
            $shell = New-Object -ComObject WScript.Shell
            $null = $shell.Popup($bodyText, 900, $title, 0x1030)
        } catch { }
    }
}

function Resolve-ScheduledTaskUserSid {
    param([Parameter(Mandatory = $true)][string]$Identity)
    try {
        if ($Identity -match '^S-1-[0-9]+(?:-[0-9]+)+$') {
            $sid = New-Object System.Security.Principal.SecurityIdentifier `
                -ArgumentList $Identity
        } else {
            $account = New-Object System.Security.Principal.NTAccount `
                -ArgumentList $Identity
            $sid = $account.Translate(
                [System.Security.Principal.SecurityIdentifier])
        }
        return [string]$sid.Value
    } catch {
        throw "Scheduled task identity cannot be resolved to a SID: $Identity"
    }
}

function Register-CloneContinuationNoticeTask {
    param([Parameter(Mandatory = $true)][string]$UserSid)
    if ($UserSid -notmatch '^S-1-5-21-[0-9]+-[0-9]+-[0-9]+-[0-9]+$') {
        throw "Cannot register clone continuation notice for invalid user SID: $UserSid"
    }
    $powerShell = Join-Path $env:SystemRoot `
        'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Phase Notice' `
        -f $PSCommandPath
    $action = New-ScheduledTaskAction -Execute $powerShell -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserSid
    $principal = New-ScheduledTaskPrincipal -UserId $UserSid `
        -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $ContinuationNoticeTaskName -Action $action `
        -Trigger $trigger -Principal $principal -Settings $settings -Force |
        Out-Null
    $task = Get-ScheduledTask -TaskName $ContinuationNoticeTaskName `
        -ErrorAction Stop
    # Task Scheduler may normalize a SID principal to COMPUTER\Account when it
    # reads the registered task back. Compare the resolved SID instead of the
    # two equivalent textual forms so a valid interactive notice is not
    # rejected during the first clone boot.
    $observedUserSid = Resolve-ScheduledTaskUserSid `
        -Identity ([string]$task.Principal.UserId)
    if ($observedUserSid -cne $UserSid) {
        throw 'Could not register the interactive clone continuation notice task.'
    }
}

function Register-CloneContinuationTask {
    param([Parameter(Mandatory = $true)][string]$UserSid)
    $powerShell = Join-Path $env:SystemRoot `
        'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Phase Complete' `
        -f $PSCommandPath
    $action = New-ScheduledTaskAction -Execute $powerShell -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT120S'
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::FromMinutes(12))
    try {
        Register-ScheduledTask -TaskName $ContinuationTaskName -Action $action `
            -Trigger $trigger -Principal $principal -Settings $settings -Force |
            Out-Null
        $task = Get-ScheduledTask -TaskName $ContinuationTaskName -ErrorAction Stop
        if ([string]$task.Principal.UserId -cne 'SYSTEM' -or
            [string]$task.Principal.RunLevel -cne 'Highest') {
            throw 'Could not register the SYSTEM clone continuation task.'
        }
        Register-CloneContinuationNoticeTask -UserSid $UserSid
    } catch {
        Unregister-CloneContinuationTask
        throw
    }
}

function Unregister-CloneContinuationTask {
    foreach ($taskName in @($ContinuationTaskName, $ContinuationNoticeTaskName)) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false `
            -ErrorAction SilentlyContinue
    }
}

function Restart-ForProjectionVerification {
    & "$env:SystemRoot\System32\shutdown.exe" /r /t 5 /f /d p:4:2 `
        /c 'VMate G-11 system NVAPI verification'
    if ($LASTEXITCODE -ne 0) {
        throw "shutdown.exe could not schedule the verification reboot: $LASTEXITCODE"
    }
}

function Wait-ForProjectionReceipt {
    param(
        [Parameter(Mandatory = $true)]$Projection,
        [Parameter(Mandatory = $true)][string]$GuestUuid,
        [Parameter(Mandatory = $true)]$PortableReceipt
    )
    $deadline = [DateTime]::UtcNow.AddMinutes(8)
    do {
        $receipt = Read-And-ValidateProjectionReceipt -Projection $Projection `
            -GuestUuid $GuestUuid -PortableReceipt $PortableReceipt
        if ($null -ne $receipt) { return $receipt }
        Start-Sleep -Seconds 5
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'System NVAPI verification did not publish a validated receipt within eight minutes.'
}

if ($Phase -ceq 'Notice') {
    Show-CloneContinuationNotice
    exit 0
}

$readyForHost = $false
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Clone initialization must run as Administrator.'
    }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "VMate G-11 directory is missing: $Root"
    }
    $guestUuid = Get-GuestUuid
    $osIdentity = Get-WindowsOsIdentity
    $receipt = $null
    if (Test-Path -LiteralPath $Result -PathType Leaf) {
        $receipt = Read-And-ValidateResult -GuestUuid $guestUuid
    } else {
        if (-not (Test-Path -LiteralPath $Portable -PathType Leaf)) {
            throw "Licensed VgpuPortable.exe is missing: $Portable"
        }
        Wait-DlsEndpoint
        $logRoot = Join-Path $Root 'logs'
        if (-not (Test-Path -LiteralPath $logRoot -PathType Container)) {
            New-Item -Path $logRoot -ItemType Directory -Force `
                -ErrorAction Stop | Out-Null
        }
        $logRootItem = Get-Item -LiteralPath $logRoot -Force `
            -ErrorAction Stop
        if ($logRootItem -isnot [IO.DirectoryInfo] -or
            ($logRootItem.Attributes -band
                [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Clone log root must be a regular, non-reparse directory: $logRoot"
        }
        $portableOutput = Join-Path $logRoot 'vgpu-portable-output.txt'
        $portableError = Join-Path $logRoot 'vgpu-portable-error.txt'
        Remove-Item -LiteralPath $portableOutput, $portableError -Force `
            -ErrorAction SilentlyContinue
        $process = Start-Process -FilePath $Portable -ArgumentList '/no-launch' `
            -WorkingDirectory $Root -WindowStyle Hidden `
            -RedirectStandardOutput $portableOutput `
            -RedirectStandardError $portableError -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            $details = @()
            foreach ($candidate in @($portableError, $portableOutput)) {
                if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                    continue
                }
                $candidateDetail = (@(Get-Content -LiteralPath $candidate `
                    -Tail 24 -ErrorAction SilentlyContinue) -join ' | ').Trim()
                if (-not [string]::IsNullOrWhiteSpace($candidateDetail)) {
                    $details += ('{0}: {1}' -f
                        [IO.Path]::GetFileName($candidate), $candidateDetail)
                }
            }
            $detail = if ($details.Count -eq 0) {
                'No child output was captured.'
            } else {
                $details -join ' || '
            }
            throw ("VgpuPortable.exe failed with exit code {0}. Logs: {1} / {2}. {3}" -f
                $process.ExitCode, $portableOutput, $portableError, $detail)
        }
        $receipt = Read-And-ValidateResult -GuestUuid $guestUuid
    }

    $projection = Find-SystemProjectionPayload -GuestUuid $guestUuid `
        -PortableReceipt $receipt
    $projectionReceipt = Read-And-ValidateProjectionReceipt `
        -Projection $projection -GuestUuid $guestUuid -PortableReceipt $receipt
    $resumeVerifiedProjection = $null -ne $projectionReceipt

    # Run after licensed vGPU/DLS validation but before the existing internal
    # projection reboot. The trusted clone-only mode keeps the interactive
    # user's exact rollback baseline and starts its Local System enforcement
    # task immediately, so that same reboot also verifies MpsSvc is available
    # boot. Complete mode only verifies. An interactive Auto retry safely
    # reapplies the currently attested profile while retaining the original
    # state.json baseline; this upgrades older clones and newly added settings.
    $guestLiteState = if ($Phase -ceq 'Complete') {
        $null = Read-And-ValidateGuestLitePayload
        Read-And-ValidateGuestLiteState -RequireFirewallReady
    } else {
        Invoke-GuestLiteCloneProfile
    }
    if ($null -ne $projectionReceipt -and $Phase -cne 'Complete' -and
        [string]$guestLiteState.FirewallState -cne 'Stopped') {
        Register-CloneContinuationTask `
            -UserSid ([string]$guestLiteState.UserSid)
        Disable-OneShotAutoLogon
        Remove-Item -LiteralPath $ErrorFile -Force -ErrorAction SilentlyContinue
        Restart-ForProjectionVerification
        exit 0
    }
    if ($null -eq $projectionReceipt) {
        if ($Phase -ceq 'Complete') {
            $projectionReceipt = Wait-ForProjectionReceipt `
                -Projection $projection -GuestUuid $guestUuid `
                -PortableReceipt $receipt
        } else {
            Register-CloneContinuationTask `
                -UserSid ([string]$guestLiteState.UserSid)
            Disable-OneShotAutoLogon
            Remove-Item -LiteralPath $ErrorFile -Force -ErrorAction SilentlyContinue
            if (Test-ProjectionPendingReceipt -Projection $projection `
                    -GuestUuid $guestUuid) {
                Restart-ForProjectionVerification
            } else {
                & $projection.Coordinator -Action Install `
                    -PayloadDir $projection.Root -Reboot
                if (-not (Test-ProjectionPendingReceipt -Projection $projection `
                            -GuestUuid $guestUuid)) {
                    throw 'System NVAPI installer returned without a pending-reboot receipt.'
                }
            }
            # The VM stays in the same QEMU process.  The coordinator has copied
            # every manifest-pinned file into protected ProgramData and ejected
            # the VM-bound ISO; the host removes that temporary optical stack
            # before this internal verification reboot.
            exit 0
        }
    }

    # A host-ready receipt is issued only after one current-boot, identity-bound
    # SYSTEM run has re-disabled reviewed services/tasks/processes and returned
    # a clean result. Reuse the startup-triggered run when it already satisfies
    # that contract; otherwise request exactly one measured fallback run.
    $guestLiteEnforcement = Invoke-And-WaitGuestLiteEnforcement `
        -ExpectedUserSid ([string]$guestLiteState.UserSid) `
        -ExpectedMachineGuid ([string]$osIdentity.MachineGuid) `
        -ExpectedComputerName ([string]$osIdentity.ComputerName)
    $guestLiteState = Read-And-ValidateGuestLiteState -RequireFirewallReady

    $safeMarker = [ordered]@{
        schemaVersion = 4
        state = 'ready-for-host-initialization'
        completedUtc = [DateTime]::UtcNow.ToString('o')
        observedVmUuid = $guestUuid
        machineSid = $osIdentity.MachineSid
        machineGuid = $osIdentity.MachineGuid
        computerName = $osIdentity.ComputerName
        gpuProfile = [string]$receipt.gpuProfile
        pnpDeviceId = [string]$receipt.pnpDeviceId
        driverVersion = [string]$receipt.driverVersion
        licenseStatus = 'Licensed'
        testsigning = $false
        nointegritychecks = $false
        guestLite = [ordered]@{
            state = 'validated'
            profileVersion = $GuestLiteProfileVersion
            userSid = [string]$guestLiteState.UserSid
            rollbackBaseline = 'C:\ProgramData\G11GuestLite\state.json'
            enforcementTask = '\G11GuestLite-EnforceProfile'
            enforcementLastRun = [string]$guestLiteEnforcement.LastRunTime
            enforcementLastResult = [int64]$guestLiteEnforcement.LastTaskResult
            firewallService = 'MpsSvc'
            firewallStartMode = [string]$guestLiteState.FirewallStartMode
            firewallState = [string]$guestLiteState.FirewallState
            firewallProcessId = [uint32]$guestLiteState.FirewallProcessId
            baseFilteringEngine = 'preserved-running'
            appearance = 'background-and-font-preserved'
            notifications = [string]$guestLiteState.Notifications
            taskbarSearch = [string]$guestLiteState.TaskbarSearch
            defaultInputMethod = [string]$guestLiteState.DefaultInputMethod
            inputOrder = [string]$guestLiteState.InputOrder
            audio = [string]$guestLiteState.Audio
            gameMode = [string]$guestLiteState.GameMode
            gameDvr = [string]$guestLiteState.GameDvr
            nvidiaPowerMode = [string]$guestLiteState.NvidiaPowerMode
            dnfPriority = [string]$guestLiteState.DnfPriority
            temporaryCleanup = [string]$guestLiteState.TemporaryCleanup
            backgroundProcesses = [string]$guestLiteState.BackgroundProcesses
        }
        systemNvapiProjection = [ordered]@{
            state = 'validated'
            contractId = [string]$projection.Contract.contractId
            vmId = [int]$projection.Contract.vmId
            vmUuid = $guestUuid
            gpuProfile = [string]$projectionReceipt.gpuProfile
            monitorProfile = [string]$projectionReceipt.monitorProfile
            driverVersion = [string]$projectionReceipt.driverVersion
            driverSigned = [bool]$projectionReceipt.driverSigned
            testsigning = $false
            nointegritychecks = $false
        }
    }
    Disable-OneShotAutoLogon
    Unregister-CloneContinuationTask
    Finalize-BootstrapAdministrator
    Remove-Item -LiteralPath $ErrorFile -Force -ErrorAction SilentlyContinue
    Write-AtomicUtf8Json -Value $safeMarker -Path $Marker
    $readyForHost = $true
    & "$env:SystemRoot\System32\shutdown.exe" /s /t 10 /d p:4:2 `
        /c 'VMate G-11 clone initialization completed'
    if ($LASTEXITCODE -ne 0) {
        throw "shutdown.exe failed with exit code $LASTEXITCODE."
    }
} catch {
    if (-not $readyForHost) {
        Remove-Item -LiteralPath $Marker -Force -ErrorAction SilentlyContinue
    }
    try { Disable-OneShotAutoLogon } catch { }
    $message = @(
        "[$([DateTime]::UtcNow.ToString('o'))] G-11 clone initialization failed."
        $_.Exception.ToString()
        ''
        'Fix the reported issue, then run Retry-Clone-Initialization.cmd as Administrator.'
        'The normal workflow runs VgpuPortable once, then uses one internal reboot for system NVAPI verification.'
    ) -join [Environment]::NewLine
    [IO.File]::WriteAllText($ErrorFile, $message, (New-Object Text.UTF8Encoding($false)))
    Write-Error $message
    exit 1
}
