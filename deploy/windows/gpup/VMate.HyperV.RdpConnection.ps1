#Requires -Version 5.1

<#
.SYNOPSIS
    为 GPU-P VM 解析当前 RDP 端点并生成无密码连接文件。

.DESCRIPTION
    优先读取 Hyper-V KVP 地址；KVP 被关闭或尚未刷新时，通过显式凭据使用
    PowerShell Direct 查询 guest 默认路由接口。仅连接实际回读且 3389 可达的地址。
    生成的 .rdp 文件不包含 password 51:b 或任何可复用凭据。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:VMateGpuPRdpContract = 'vmate-hyperv-gpup-rdp-v1'

function Test-VMateGpuPTcpEndpoint {
    param(
        [Parameter(Mandatory = $true)][ipaddress]$Address,
        [ValidateRange(1, 65535)][int]$Port = 3389,
        [ValidateRange(250, 10000)][int]$TimeoutMilliseconds = 2000
    )

    $client = New-Object Net.Sockets.TcpClient
    $waitHandle = $null
    try {
        $async = $client.BeginConnect($Address, $Port, $null, $null)
        $waitHandle = $async.AsyncWaitHandle
        if (-not $waitHandle.WaitOne($TimeoutMilliseconds)) {
            return $false
        }
        $client.EndConnect($async)
        return [bool]$client.Connected
    }
    catch { return $false }
    finally {
        if ($null -ne $waitHandle) { $waitHandle.Close() }
        $client.Dispose()
    }
}

function Get-VMateGpuPGuestNetworkState {
    param(
        [Parameter(Mandatory = $true)][string]$VMName,
        [Parameter(Mandatory = $true)][PSCredential]$GuestCredential
    )

    return Invoke-Command -VMName $VMName -Credential $GuestCredential `
        -ErrorAction Stop -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        $addresses = @(Get-NetIPAddress -AddressFamily IPv4 `
                -ErrorAction Stop | Where-Object {
                [string]$_.AddressState -eq 'Preferred' -and
                [string]$_.IPAddress -notmatch '^(127\.|169\.254\.)'
            })
        $routes = @(Get-NetRoute -AddressFamily IPv4 `
                -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Where-Object { [string]$_.State -ne 'Invalid' } |
            Sort-Object RouteMetric, InterfaceMetric)
        $ordered = [Collections.Generic.List[object]]::new()
        foreach ($route in $routes) {
            foreach ($address in @($addresses | Where-Object {
                        [int]$_.InterfaceIndex -eq [int]$route.InterfaceIndex
                    } | Sort-Object PrefixLength -Descending)) {
                if (@($ordered | Where-Object {
                            [string]$_.IPAddress -ceq
                                [string]$address.IPAddress
                        }).Count -eq 0) {
                    [void]$ordered.Add([pscustomobject][ordered]@{
                        IPAddress = [string]$address.IPAddress
                        InterfaceIndex = [int]$address.InterfaceIndex
                        InterfaceAlias = [string]$address.InterfaceAlias
                        HasDefaultRoute = $true
                    })
                }
            }
        }
        foreach ($address in $addresses) {
            if (@($ordered | Where-Object {
                        [string]$_.IPAddress -ceq [string]$address.IPAddress
                    }).Count -eq 0) {
                [void]$ordered.Add([pscustomobject][ordered]@{
                    IPAddress = [string]$address.IPAddress
                    InterfaceIndex = [int]$address.InterfaceIndex
                    InterfaceAlias = [string]$address.InterfaceAlias
                    HasDefaultRoute = $false
                })
            }
        }
        $listeners = @(Get-NetTCPConnection -State Listen -LocalPort 3389 `
            -ErrorAction SilentlyContinue)
        return [pscustomobject][ordered]@{
            ComputerName = $env:COMPUTERNAME
            Addresses = @($ordered)
            RdpListening = $listeners.Count -gt 0
        }
    }
}

function Resolve-VMateGpuPRdpEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$VMName,
        [Parameter(Mandatory = $true)][PSCredential]$GuestCredential,
        [ValidateRange(250, 10000)]
        [int]$ConnectionTimeoutMilliseconds = 2000
    )

    Import-Module Hyper-V -ErrorAction Stop
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    if ([string]$vm.State -cne 'Running') {
        throw "RDP 端点解析要求 VM 为 Running；当前 $($vm.State)。"
    }
    $guest = Get-VMateGpuPGuestNetworkState -VMName $VMName `
        -GuestCredential $GuestCredential
    if (-not [bool]$guest.RdpListening) {
        throw 'guest 没有监听 TCP 3389。'
    }

    $hostAddresses = @(Get-VMNetworkAdapter -VMName $VMName `
            -ErrorAction Stop | ForEach-Object { @($_.IPAddresses) } |
        Where-Object {
            $_ -as [ipaddress] -and
            ([ipaddress]$_).AddressFamily -eq
                [Net.Sockets.AddressFamily]::InterNetwork -and
            [string]$_ -notmatch '^(127\.|169\.254\.)'
        } | Sort-Object -Unique)
    $candidates = [Collections.Generic.List[object]]::new()
    foreach ($address in @($guest.Addresses)) {
        [void]$candidates.Add([pscustomobject][ordered]@{
            Address = [string]$address.IPAddress
            Source = if ([bool]$address.HasDefaultRoute) {
                'PowerShellDirectDefaultRoute'
            } else { 'PowerShellDirect' }
        })
    }
    foreach ($address in $hostAddresses) {
        if (@($candidates | Where-Object {
                    [string]$_.Address -ceq [string]$address
                }).Count -eq 0) {
            [void]$candidates.Add([pscustomobject][ordered]@{
                Address = [string]$address
                Source = 'HyperVKvp'
            })
        }
    }
    if ($candidates.Count -eq 0) {
        throw '没有从 Hyper-V KVP 或 PowerShell Direct 解析到 guest IPv4 地址。'
    }

    $probes = [Collections.Generic.List[object]]::new()
    $selected = $null
    foreach ($candidate in $candidates) {
        $ip = [ipaddress]::Parse([string]$candidate.Address)
        $reachable = Test-VMateGpuPTcpEndpoint -Address $ip -Port 3389 `
            -TimeoutMilliseconds $ConnectionTimeoutMilliseconds
        [void]$probes.Add([pscustomobject][ordered]@{
            Address = $ip.ToString()
            Source = [string]$candidate.Source
            Port = 3389
            Reachable = $reachable
        })
        if ($reachable -and $null -eq $selected) {
            $selected = $probes[$probes.Count - 1]
        }
    }
    if ($null -eq $selected) {
        throw 'guest 已监听 RDP，但宿主无法连接任何回读地址的 TCP 3389。'
    }
    return [pscustomobject][ordered]@{
        Address = [string]$selected.Address
        Port = 3389
        Source = [string]$selected.Source
        GuestComputerName = [string]$guest.ComputerName
        Probes = @($probes)
    }
}

function Get-VMateGpuPRdpFileText {
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][string]$UserName,
        [ValidateRange(800, 7680)][int]$Width,
        [ValidateRange(600, 4320)][int]$Height,
        [bool]$FullScreen
    )

    if ($Address -match '[\r\n]' -or $UserName -match '[\r\n]') {
        throw 'RDP 地址或用户名含无效换行。'
    }
    $screenMode = if ($FullScreen) { 2 } else { 1 }
    return (@(
        "screen mode id:i:$screenMode"
        'use multimon:i:0'
        "desktopwidth:i:$Width"
        "desktopheight:i:$Height"
        'session bpp:i:32'
        'smart sizing:i:1'
        'dynamic resolution:i:1'
        'desktopscalefactor:i:100'
        'devicescalefactor:i:100'
        "full address:s:$Address"
        'server port:i:3389'
        "username:s:$UserName"
        'prompt for credentials:i:1'
        'authentication level:i:2'
        'enablecredsspsupport:i:1'
        'negotiate security layer:i:1'
        'networkautodetect:i:1'
        'bandwidthautodetect:i:1'
        'compression:i:1'
        'videoplaybackmode:i:1'
        'audiomode:i:0'
        'redirectclipboard:i:1'
        'redirectprinters:i:0'
        'redirectcomports:i:0'
        'redirectsmartcards:i:0'
        'drivestoredirect:s:'
    ) -join "`r`n") + "`r`n"
}

function Get-VMateSignedRemoteDesktopClient {
    [CmdletBinding()]
    param()

    $mstsc = Join-Path $env:SystemRoot 'System32\mstsc.exe'
    if (-not (Test-Path -LiteralPath $mstsc -PathType Leaf)) {
        throw "找不到 inbox Remote Desktop 客户端：$mstsc"
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $mstsc
    if ([string]$signature.Status -cne 'Valid' -or
        $null -eq $signature.SignerCertificate -or
        [string]$signature.SignerCertificate.Subject -notmatch
            '(?i)(Microsoft Windows|Microsoft Corporation)') {
        throw 'Remote Desktop 客户端不是有效的 Microsoft 签名文件。'
    }
    return $mstsc
}

function Open-VMateGpuPExistingRdp {
    <#
    .SYNOPSIS
        复用已经由 Connect-VMateGpuPRdp 生成的无密码连接文件。

    .DESCRIPTION
        日常连接无需再次取得 guest 管理员密码。文件必须以当前 VMId 命名、使用
        UTF-16LE BOM、没有 password blob，且保存的 IPv4:3389 当前真实可达。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$VMName,
        [Parameter(Mandatory = $true)][string]$StateDirectory,
        [switch]$NoLaunch
    )

    Import-Module Hyper-V -ErrorAction Stop
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    $gpu = @(Get-VMGpuPartitionAdapter -VMName $VMName -ErrorAction Stop)
    if ([string]$vm.State -cne 'Running' -or $gpu.Count -ne 1) {
        throw '复用 RDP 连接要求 Running VM 且恰好一个 GPU partition adapter。'
    }
    $stateRoot = [IO.Path]::GetFullPath($StateDirectory)
    $rdpPath = Join-Path $stateRoot (([Guid]$vm.Id).ToString('D') + '.rdp')
    if (-not (Test-Path -LiteralPath $rdpPath -PathType Leaf)) {
        throw "P-11 尚未生成动态 RDP 连接文件：$rdpPath"
    }
    $item = Get-Item -LiteralPath $rdpPath -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -lt 4 -or $item.Length -gt 65536) {
        throw 'P-11 RDP 连接文件不是受支持的普通文件。'
    }
    $bytes = [IO.File]::ReadAllBytes($rdpPath)
    if ($bytes[0] -ne 0xFF -or $bytes[1] -ne 0xFE) {
        throw 'P-11 RDP 连接文件缺少 UTF-16LE BOM。'
    }
    $text = [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    if ($text -match '(?im)^password 51:b:' -or
        $text -notmatch '(?im)^prompt for credentials:i:1\s*$') {
        throw 'P-11 RDP 连接文件包含密码或关闭了每次凭据提示。'
    }
    $addresses = @([regex]::Matches($text,
            '(?im)^full address:s:(?<value>[^\r\n]+)\s*$'))
    if ($addresses.Count -ne 1) {
        throw 'P-11 RDP 连接文件必须恰好包含一个 full address。'
    }
    $address = [ipaddress]$null
    $addressText = $addresses[0].Groups['value'].Value.Trim()
    if (-not [ipaddress]::TryParse($addressText, [ref]$address) -or
        $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        throw "P-11 RDP 地址不是有效 IPv4：$addressText"
    }
    $ports = @([regex]::Matches($text,
            '(?im)^server port:i:(?<value>[0-9]+)\s*$'))
    if ($ports.Count -ne 1 -or
        [int]$ports[0].Groups['value'].Value -ne 3389) {
        throw 'P-11 RDP 连接文件端口必须恰好为 3389。'
    }
    if (-not (Test-VMateGpuPTcpEndpoint -Address $address -Port 3389)) {
        throw "P-11 guest RDP 当前不可达：${address}:3389"
    }
    $mstsc = Get-VMateSignedRemoteDesktopClient
    $result = [pscustomobject][ordered]@{
        SchemaVersion = 1
        ContractId = $script:VMateGpuPRdpContract
        Mode = 'ExistingValidatedConnection'
        VMName = [string]$vm.Name
        VMId = ([Guid]$vm.Id).ToString('D')
        Endpoint = "${address}:3389"
        RdpPath = $rdpPath
        ClientPath = $mstsc
        Launched = $false
        CredentialPersisted = $false
        PasswordPersisted = $false
        RuntimeModelSwitch = $false
        InputInjection = $false
    }
    if (-not $NoLaunch) {
        $process = Start-Process -FilePath $mstsc `
            -ArgumentList @((('"{0}"' -f $rdpPath))) -PassThru `
            -ErrorAction Stop
        $result.Launched = $true
        $result | Add-Member -NotePropertyName ProcessId `
            -NotePropertyValue ([int]$process.Id)
    }
    return $result
}

function Connect-VMateGpuPRdp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$VMName,
        [Parameter(Mandatory = $true)][PSCredential]$GuestCredential,
        [Parameter(Mandatory = $true)][string]$StateDirectory,
        [ValidateRange(800, 7680)][int]$Width = 2560,
        [ValidateRange(600, 4320)][int]$Height = 1440,
        [switch]$FullScreen,
        [switch]$NoLaunch,
        [switch]$DryRun
    )

    Import-Module Hyper-V -ErrorAction Stop
    if ($VMName -match '["\r\n]') { throw 'VMName 含无效字符。' }
    if ($GuestCredential.UserName -match '[\r\n]') {
        throw 'guest 用户名含无效字符。'
    }
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    $gpu = @(Get-VMGpuPartitionAdapter -VMName $VMName -ErrorAction Stop)
    if ([string]$vm.State -cne 'Running' -or $gpu.Count -ne 1) {
        throw '直接 RDP 连接要求 Running VM 且恰好一个 GPU partition adapter。'
    }
    if ([string]$vm.EnhancedSessionTransportType -cne 'VMBus' -or
        -not [bool](Get-VMHost -ErrorAction Stop).EnableEnhancedSessionMode) {
        throw '直接 RDP 连接要求宿主 Enhanced Session/VMBus 已就绪。'
    }
    if (Get-Command Get-VMateHyperVEnhancedSessionStatus `
            -ErrorAction SilentlyContinue) {
        $enhanced = Get-VMateHyperVEnhancedSessionStatus -VMName $VMName `
            -GuestCredential $GuestCredential
        if (-not [bool]$enhanced.Ready) {
            throw 'guest Enhanced Session/RDP 策略尚未就绪。'
        }
    }

    $endpoint = Resolve-VMateGpuPRdpEndpoint -VMName $VMName `
        -GuestCredential $GuestCredential
    $mstsc = Get-VMateSignedRemoteDesktopClient

    $fullStateDirectory = [IO.Path]::GetFullPath($StateDirectory)
    $rdpPath = Join-Path $fullStateDirectory (
        (([Guid]$vm.Id).ToString('D')) + '.rdp')
    $text = Get-VMateGpuPRdpFileText -Address $endpoint.Address `
        -UserName $GuestCredential.UserName -Width $Width -Height $Height `
        -FullScreen ([bool]$FullScreen)
    if ($text -match '(?im)^password 51:b:') {
        throw '拒绝写入包含 RDP 密码 blob 的连接文件。'
    }
    $rdpEncoding = New-Object Text.UnicodeEncoding($false, $true)
    $bytes = [byte[]]($rdpEncoding.GetPreamble() +
        $rdpEncoding.GetBytes($text))
    $sha256 = [BitConverter]::ToString(
        [Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '')

    if (-not $DryRun) {
        if (-not (Test-Path -LiteralPath $fullStateDirectory `
                -PathType Container)) {
            New-Item -Path $fullStateDirectory -ItemType Directory -Force `
                -ErrorAction Stop | Out-Null
        }
        $temporary = "$rdpPath.$PID.tmp"
        try {
            [IO.File]::WriteAllText($temporary, $text, $rdpEncoding)
            Move-Item -LiteralPath $temporary -Destination $rdpPath -Force `
                -ErrorAction Stop
        }
        finally {
            Remove-Item -LiteralPath $temporary -Force `
                -ErrorAction SilentlyContinue
        }
    }

    $result = [pscustomobject][ordered]@{
        SchemaVersion = 1
        ContractId = $script:VMateGpuPRdpContract
        VMName = [string]$vm.Name
        VMId = ([Guid]$vm.Id).ToString('D')
        Endpoint = $endpoint
        Resolution = "${Width}x${Height}"
        FullScreen = [bool]$FullScreen
        RdpPath = $rdpPath
        RdpSha256 = $sha256
        ClientPath = $mstsc
        DryRun = [bool]$DryRun
        Launched = $false
        CredentialPersisted = $false
        PasswordPersisted = $false
        RuntimeModelSwitch = $false
        InputInjection = $false
    }
    if (-not $DryRun -and -not $NoLaunch) {
        $process = Start-Process -FilePath $mstsc `
            -ArgumentList @((('"{0}"' -f $rdpPath))) -PassThru `
            -ErrorAction Stop
        $result.Launched = $true
        $result | Add-Member -NotePropertyName ProcessId `
            -NotePropertyValue ([int]$process.Id)
    }
    return $result
}
