#Requires -Version 5.1

<#
.SYNOPSIS
    事务化启用 GPU-P VM 的 Hyper-V Enhanced Session 图形通道。

.DESCRIPTION
    Enhanced Session 固定使用 VMConnect/RDP over VMBus。调用者必须显式提供
    PowerShell Direct 凭据；凭据不会写入磁盘。guest 仅启用 Microsoft 官方
    Remote Desktop 图形策略，失败时恢复 guest 注册表、服务状态和宿主设置。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:VMateEnhancedSessionPolicyPath =
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
$script:VMateEnhancedSessionRdpPath =
    'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'

function Get-VMateHyperVEnhancedSessionHostSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$VMName)

    Import-Module Hyper-V -ErrorAction Stop
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    $hostState = Get-VMHost -ErrorAction Stop
    return [pscustomobject][ordered]@{
        VMName = [string]$vm.Name
        VMId = ([Guid]$vm.Id).ToString('D')
        VMState = [string]$vm.State
        VMVersion = [string]$vm.Version
        Transport = [string]$vm.EnhancedSessionTransportType
        HostEnhancedSessionEnabled =
            [bool]$hostState.EnableEnhancedSessionMode
    }
}

function Invoke-VMateHyperVEnhancedSessionGuestConfigure {
    param(
        [Parameter(Mandatory = $true)][string]$VMName,
        [Parameter(Mandatory = $true)][PSCredential]$GuestCredential
    )

    return Invoke-Command -VMName $VMName -Credential $GuestCredential `
        -ErrorAction Stop -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        $policyPath =
            'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
        $rdpPath =
            'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
        $targets = @(
            [pscustomobject]@{ Path = $rdpPath
                Name = 'fDenyTSConnections'; Value = 0 },
            [pscustomobject]@{ Path = $policyPath
                Name = 'bEnumerateHWBeforeSW'; Value = 1 },
            [pscustomobject]@{ Path = $policyPath
                Name = 'AVCHardwareEncodePreferred'; Value = 1 },
            [pscustomobject]@{ Path = $policyPath
                Name = 'AVC444ModePreferred'; Value = 1 }
        )

        function Get-RegistrySnapshot([object]$Target) {
            $exists = Test-Path -LiteralPath $Target.Path
            $valueExists = $false
            $value = $null
            $kind = ''
            if ($exists) {
                $key = Get-Item -LiteralPath $Target.Path -ErrorAction Stop
                $valueExists = @($key.GetValueNames() | Where-Object {
                        $_ -ceq [string]$Target.Name
                    }).Count -eq 1
                if ($valueExists) {
                    $value = $key.GetValue([string]$Target.Name, $null,
                        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    $kind = [string]$key.GetValueKind([string]$Target.Name)
                }
            }
            return [pscustomobject][ordered]@{
                Path = [string]$Target.Path
                Name = [string]$Target.Name
                KeyExisted = $exists
                ValueExisted = $valueExists
                Kind = $kind
                Value = $value
            }
        }

        function Restore-RegistrySnapshot([object]$Snapshot) {
            if ([bool]$Snapshot.ValueExisted) {
                if (-not (Test-Path -LiteralPath $Snapshot.Path)) {
                    New-Item -Path $Snapshot.Path -Force -ErrorAction Stop |
                        Out-Null
                }
                $key = Get-Item -LiteralPath $Snapshot.Path -ErrorAction Stop
                $kind = [Enum]::Parse(
                    [Microsoft.Win32.RegistryValueKind],
                    [string]$Snapshot.Kind)
                $key.SetValue([string]$Snapshot.Name, $Snapshot.Value, $kind)
            }
            elseif (Test-Path -LiteralPath $Snapshot.Path) {
                Remove-ItemProperty -LiteralPath $Snapshot.Path `
                    -Name ([string]$Snapshot.Name) -Force `
                    -ErrorAction SilentlyContinue
                if (-not [bool]$Snapshot.KeyExisted) {
                    $key = Get-Item -LiteralPath $Snapshot.Path `
                        -ErrorAction SilentlyContinue
                    if ($null -ne $key -and $key.GetValueNames().Count -eq 0 -and
                        @(Get-ChildItem -LiteralPath $Snapshot.Path `
                            -ErrorAction SilentlyContinue).Count -eq 0) {
                        Remove-Item -LiteralPath $Snapshot.Path -Force `
                            -ErrorAction SilentlyContinue
                    }
                }
            }
        }

        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        if ([Version]$os.Version -lt [Version]'10.0.10240.0') {
            throw 'Enhanced Session guest 必须为 Windows 10/Server 2016 或更高。'
        }
        $gpu = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
            Where-Object {
                [string]$_.PNPClass -ceq 'Display' -and
                [string]$_.Service -ieq 'VirtualRender' -and
                [int]$_.ConfigManagerErrorCode -eq 0
            })
        if ($gpu.Count -ne 1) {
            throw 'guest 必须恰好有一个健康的 VirtualRender GPU-P 节点。'
        }

        $beforeRegistry = @($targets | ForEach-Object {
                Get-RegistrySnapshot $_
            })
        $beforeServices = @(Get-Service TermService, SessionEnv, UmRdpService `
                -ErrorAction Stop | Select-Object Name, Status, StartType)
        if (@($beforeServices | Where-Object {
                    [string]$_.StartType -ceq 'Disabled'
                }).Count -gt 0) {
            throw 'Remote Desktop Services 中存在 Disabled 服务。'
        }
        $firewallNames = @(
            'RemoteDesktop-UserMode-In-TCP'
            'RemoteDesktop-UserMode-In-UDP'
        )
        $beforeFirewall = @($firewallNames | ForEach-Object {
            $rule = @(Get-NetFirewallRule -Name $_ -ErrorAction Stop)
            if ($rule.Count -ne 1) {
                throw "Remote Desktop 防火墙规则数量异常：$_。"
            }
            [pscustomobject][ordered]@{
                Name = [string]$rule[0].Name
                Enabled = [string]$rule[0].Enabled
                Direction = [string]$rule[0].Direction
                Action = [string]$rule[0].Action
            }
        })
        if (@($beforeFirewall | Where-Object {
                    [string]$_.Direction -cne 'Inbound' -or
                    [string]$_.Action -cne 'Allow'
                }).Count -gt 0) {
            throw 'Remote Desktop 防火墙规则不是 Inbound/Allow。'
        }
        $started = [Collections.Generic.List[string]]::new()
        $firewallEnabled = [Collections.Generic.List[string]]::new()
        try {
            foreach ($target in $targets) {
                if (-not (Test-Path -LiteralPath $target.Path)) {
                    New-Item -Path $target.Path -Force -ErrorAction Stop |
                        Out-Null
                }
                New-ItemProperty -LiteralPath $target.Path `
                    -Name $target.Name -Value ([int]$target.Value) `
                    -PropertyType DWord -Force -ErrorAction Stop | Out-Null
            }
            foreach ($service in $beforeServices) {
                if ([string]$service.Status -cne 'Running') {
                    Start-Service -Name $service.Name -ErrorAction Stop
                    [void]$started.Add([string]$service.Name)
                }
            }
            foreach ($rule in $beforeFirewall) {
                if ([string]$rule.Enabled -cne 'True') {
                    Enable-NetFirewallRule -Name $rule.Name `
                        -ErrorAction Stop
                    [void]$firewallEnabled.Add([string]$rule.Name)
                }
            }
            $rdpListening = $false
            for ($attempt = 0; $attempt -lt 30; ++$attempt) {
                $rdpListening = @(Get-NetTCPConnection -State Listen `
                    -LocalPort 3389 -ErrorAction SilentlyContinue).Count -gt 0
                if ($rdpListening) { break }
                Start-Sleep -Milliseconds 250
            }
            $afterServices = @(Get-Service TermService, SessionEnv,
                    UmRdpService -ErrorAction Stop |
                Select-Object Name, Status, StartType)
            $afterFirewall = @($firewallNames | ForEach-Object {
                Get-NetFirewallRule -Name $_ -ErrorAction Stop |
                    Select-Object Name, Enabled, Direction, Action
            })
            $afterRegistry = @($targets | ForEach-Object {
                    Get-RegistrySnapshot $_
                })
            $ready = @($afterServices | Where-Object {
                    [string]$_.Status -cne 'Running'
                }).Count -eq 0 -and
                @($afterFirewall | Where-Object {
                    [string]$_.Enabled -cne 'True' -or
                    [string]$_.Direction -cne 'Inbound' -or
                    [string]$_.Action -cne 'Allow'
                }).Count -eq 0 -and $rdpListening -and
                @($afterRegistry | Where-Object {
                    ([string]$_.Name -ceq 'fDenyTSConnections' -and
                        [int]$_.Value -ne 0) -or
                    ([string]$_.Name -cne 'fDenyTSConnections' -and
                        [int]$_.Value -ne 1)
                }).Count -eq 0
            if (-not $ready) {
                throw 'Remote Desktop guest 配置写入后回读不一致。'
            }
            return [pscustomobject][ordered]@{
                ComputerName = $env:COMPUTERNAME
                OsVersion = [string]$os.Version
                GpuName = [string]$gpu[0].Name
                Before = [pscustomobject][ordered]@{
                    Registry = $beforeRegistry
                    Services = $beforeServices
                    Firewall = $beforeFirewall
                }
                After = [pscustomobject][ordered]@{
                    Registry = $afterRegistry
                    Services = $afterServices
                    Firewall = $afterFirewall
                    RdpListening = $rdpListening
                }
                StartedServices = @($started)
                EnabledFirewallRules = @($firewallEnabled)
                Ready = $ready
                RestartRequired = @($beforeRegistry | Where-Object {
                        [string]$_.Name -ne 'fDenyTSConnections' -and
                        (-not [bool]$_.ValueExisted -or [int]$_.Value -ne 1)
                    }).Count -gt 0
            }
        }
        catch {
            $primary = $_.Exception.Message
            for ($index = $firewallEnabled.Count - 1;
                $index -ge 0; --$index) {
                Disable-NetFirewallRule -Name $firewallEnabled[$index] `
                    -ErrorAction SilentlyContinue
            }
            for ($index = $started.Count - 1; $index -ge 0; --$index) {
                Stop-Service -Name $started[$index] -Force `
                    -ErrorAction SilentlyContinue
            }
            for ($index = $beforeRegistry.Count - 1; $index -ge 0; --$index) {
                Restore-RegistrySnapshot $beforeRegistry[$index]
            }
            throw "Enhanced Session guest 配置失败并已回滚：$primary"
        }
    }
}

function Enable-VMateHyperVEnhancedSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$VMName,
        [Parameter(Mandatory = $true)][PSCredential]$GuestCredential
    )

    $before = Get-VMateHyperVEnhancedSessionHostSnapshot -VMName $VMName
    if ([string]$before.VMState -cne 'Running') {
        throw 'Enhanced Session 配置要求 VM 为 Running，以便使用 PowerShell Direct。'
    }
    if ([string]$before.Transport -cne 'VMBus') {
        throw 'Enhanced Session 传输必须预先固定为 VMBus。'
    }
    $hostChanged = -not [bool]$before.HostEnhancedSessionEnabled
    if ($hostChanged) {
        Set-VMHost -EnableEnhancedSessionMode $true -ErrorAction Stop
    }
    try {
        $guest = Invoke-VMateHyperVEnhancedSessionGuestConfigure `
            -VMName $VMName -GuestCredential $GuestCredential
        $after = Get-VMateHyperVEnhancedSessionHostSnapshot -VMName $VMName
        if (-not [bool]$after.HostEnhancedSessionEnabled -or
            [string]$after.Transport -cne 'VMBus' -or -not [bool]$guest.Ready) {
            throw 'Enhanced Session 宿主/guest 回读没有全部就绪。'
        }
    }
    catch {
        $primary = $_.Exception.Message
        if ($hostChanged) {
            try {
                Set-VMHost -EnableEnhancedSessionMode $false -ErrorAction Stop
            }
            catch {
                throw "Enhanced Session 配置失败：$primary；宿主回滚失败：$($_.Exception.Message)"
            }
        }
        throw "Enhanced Session 配置失败：$primary；宿主设置已回滚。"
    }
    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        ContractId = 'vmate-hyperv-enhanced-session-v1'
        VMName = [string]$after.VMName
        VMId = [string]$after.VMId
        Transport = 'VMBus'
        HostChanged = $hostChanged
        Before = [pscustomobject][ordered]@{
            Host = $before
            Guest = $guest.Before
        }
        After = [pscustomobject][ordered]@{
            Host = $after
            Guest = $guest.After
        }
        GpuName = [string]$guest.GpuName
        Ready = $true
        RestartRequired = [bool]$guest.RestartRequired
        CredentialPersisted = $false
        RuntimeModelSwitch = $false
    }
}

function Get-VMateHyperVEnhancedSessionStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$VMName,
        [Parameter(Mandatory = $true)][PSCredential]$GuestCredential
    )

    $hostState = Get-VMateHyperVEnhancedSessionHostSnapshot -VMName $VMName
    if ([string]$hostState.VMState -cne 'Running') {
        throw 'Enhanced Session 状态回读要求 VM 为 Running。'
    }
    $guest = Invoke-Command -VMName $VMName -Credential $GuestCredential `
        -ErrorAction Stop -ScriptBlock {
        $policy = Get-ItemProperty -LiteralPath `
            'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' `
            -ErrorAction SilentlyContinue
        $rdp = Get-ItemProperty -LiteralPath `
            'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' `
            -ErrorAction Stop
        $services = @(Get-Service TermService, SessionEnv, UmRdpService `
                -ErrorAction Stop | Select-Object Name, Status, StartType)
        $firewall = @(
            'RemoteDesktop-UserMode-In-TCP'
            'RemoteDesktop-UserMode-In-UDP'
        ) | ForEach-Object {
            Get-NetFirewallRule -Name $_ -ErrorAction Stop |
                Select-Object Name, Enabled, Direction, Action
        }
        return [pscustomobject][ordered]@{
            RdpEnabled = [int]$rdp.fDenyTSConnections -eq 0
            HardwareGpu = $null -ne $policy -and
                [int]$policy.bEnumerateHWBeforeSW -eq 1
            HardwareAvc = $null -ne $policy -and
                [int]$policy.AVCHardwareEncodePreferred -eq 1
            Avc444 = $null -ne $policy -and
                [int]$policy.AVC444ModePreferred -eq 1
            Services = $services
            Firewall = @($firewall)
            RdpListening = @(Get-NetTCPConnection -State Listen `
                -LocalPort 3389 -ErrorAction SilentlyContinue).Count -gt 0
        }
    }
    $servicesReady = @($guest.Services | Where-Object {
            [string]$_.Status -cne 'Running'
        }).Count -eq 0
    $firewallReady = @($guest.Firewall).Count -eq 2 -and
        @($guest.Firewall | Where-Object {
            [string]$_.Enabled -cne 'True' -or
            [string]$_.Direction -cne 'Inbound' -or
            [string]$_.Action -cne 'Allow'
        }).Count -eq 0
    return [pscustomobject][ordered]@{
        VMName = $hostState.VMName
        VMId = $hostState.VMId
        Transport = $hostState.Transport
        HostEnhancedSessionEnabled = $hostState.HostEnhancedSessionEnabled
        Guest = $guest
        Ready = [bool]$hostState.HostEnhancedSessionEnabled -and
            [string]$hostState.Transport -ceq 'VMBus' -and
            [bool]$guest.RdpEnabled -and [bool]$guest.HardwareGpu -and
            [bool]$guest.HardwareAvc -and [bool]$guest.Avc444 -and
            $servicesReady -and $firewallReady -and
            [bool]$guest.RdpListening
    }
}
