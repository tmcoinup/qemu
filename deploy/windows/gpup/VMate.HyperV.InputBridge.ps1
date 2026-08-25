#Requires -Version 5.1

<#
.SYNOPSIS
    提供与授权 Win10 样例输入 API 路径兼容的本机 Hyper-V 输入桥。

.DESCRIPTION
    仅监听 127.0.0.1，固定使用 DirectHyperVCim，不接受远程绑定或运行中传输
    切换。每个 VM 保持一个长生命周期输入会话，用于按键去重和断开时释放。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'VMate.HyperV.Input.ps1')

function Get-VMateHyperVInputBridgeRequiredValue {
    param(
        [Parameter(Mandatory = $true)][Collections.Specialized.NameValueCollection]$Query,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $value = [string]$Query[$Name]
    if ([String]::IsNullOrWhiteSpace($value)) {
        throw [ArgumentException]::new("缺少请求参数：$Name")
    }
    return $value.Trim()
}

function ConvertTo-VMateHyperVInputBridgePositions {
    param([Parameter(Mandatory = $true)][string]$Value)

    $parts = @($Value.Split(',') | Where-Object {
            -not [String]::IsNullOrWhiteSpace($_)
        })
    if ($parts.Count -eq 0 -or $parts.Count -gt 128) {
        throw [ArgumentException]::new('pos 必须包含 1 到 128 组坐标。')
    }
    return @($parts | ForEach-Object {
        if ($_.Trim() -notmatch '^(-?\d+):(-?\d+)$') {
            throw [ArgumentException]::new("pos 坐标格式无效：$_")
        }
        try {
            $x = [int]$Matches[1]
            $y = [int]$Matches[2]
        }
        catch {
            throw [ArgumentException]::new("pos 坐标越界：$_")
        }
        [pscustomobject][ordered]@{ X = $x; Y = $y }
    })
}

function ConvertTo-VMateHyperVInputBridgeCodes {
    param([Parameter(Mandatory = $true)][string]$Value)

    $parts = @($Value.Split(',') | Where-Object {
            -not [String]::IsNullOrWhiteSpace($_)
        })
    if ($parts.Count -eq 0 -or $parts.Count -gt 16) {
        throw [ArgumentException]::new('code 必须包含 1 到 16 个 MakeCode。')
    }
    try {
        return @($parts | ForEach-Object {
            ConvertTo-VMateHyperVInputScanCode $_
        })
    }
    catch {
        throw [ArgumentException]::new($_.Exception.Message)
    }
}

function Get-VMateHyperVInputBridgeSession {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Sessions,
        [Parameter(Mandatory = $true)][string]$VMName
    )

    $key = $VMName.Trim().ToLowerInvariant()
    if (-not $Sessions.ContainsKey($key)) {
        $Sessions[$key] = New-VMateHyperVInputSession -VMName $VMName
    }
    return $Sessions[$key]
}

function Invoke-VMateHyperVInputBridgeRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][Collections.Specialized.NameValueCollection]$Query,
        [Parameter(Mandatory = $true)][hashtable]$Sessions
    )

    $normalizedPath = $Path.Trim().ToLowerInvariant()
    if ($normalizedPath -ceq '/help') {
        return [pscustomobject][ordered]@{
            Success = $true
            Transport = 'DirectHyperVCim'
            RuntimeModeSwitchAllowed = $false
            ListenScope = 'LoopbackOnly'
            Routes = @('/sendMouse', '/getMousePosition',
                '/sendKey', '/getResolution')
        }
    }
    if ($normalizedPath -notin @('/sendmouse', '/getmouseposition',
            '/sendkey', '/getresolution')) {
        throw [Management.Automation.ItemNotFoundException]::new(
            "未知输入桥路径：$Path")
    }

    $vmName = Get-VMateHyperVInputBridgeRequiredValue $Query 'vm'
    $session = Get-VMateHyperVInputBridgeSession $Sessions $vmName
    switch ($normalizedPath) {
        '/sendkey' {
            $actionValue = (Get-VMateHyperVInputBridgeRequiredValue `
                $Query 'action').ToLowerInvariant()
            if ($actionValue -notin @('down', 'up')) {
                throw [ArgumentException]::new('action 只允许 down 或 up。')
            }
            $codes = ConvertTo-VMateHyperVInputBridgeCodes `
                (Get-VMateHyperVInputBridgeRequiredValue $Query 'code')
            $data = Send-VMateHyperVKeyEvent -Session $session `
                -Action ([Globalization.CultureInfo]::InvariantCulture.TextInfo.
                    ToTitleCase($actionValue)) -Code $codes
        }
        '/sendmouse' {
            $typeValue = (Get-VMateHyperVInputBridgeRequiredValue `
                $Query 'type').ToLowerInvariant()
            if ($typeValue -notin @('absolute', 'relative')) {
                throw [ArgumentException]::new(
                    'type 只允许 absolute 或 relative。')
            }
            $positions = ConvertTo-VMateHyperVInputBridgePositions `
                (Get-VMateHyperVInputBridgeRequiredValue $Query 'pos')
            $button = [string]$Query['button']
            $buttonAction = [string]$Query['buttonAction']
            if ([String]::IsNullOrWhiteSpace($button) -xor
                [String]::IsNullOrWhiteSpace($buttonAction)) {
                throw [ArgumentException]::new(
                    'button 和 buttonAction 必须同时提供或同时省略。')
            }
            $parameters = @{
                Session = $session
                Type = [Globalization.CultureInfo]::InvariantCulture.TextInfo.
                    ToTitleCase($typeValue)
                Position = $positions
            }
            if (-not [String]::IsNullOrWhiteSpace($button)) {
                $buttonIndex = switch ($button.Trim().ToLowerInvariant()) {
                    'left' { 0 }
                    'middle' { 1 }
                    'right' { 2 }
                    default {
                        throw [ArgumentException]::new(
                            'button 只允许 left、middle 或 right。')
                    }
                }
                $normalizedAction = $buttonAction.Trim().ToLowerInvariant()
                if ($normalizedAction -notin @('down', 'up')) {
                    throw [ArgumentException]::new(
                        'buttonAction 只允许 down 或 up。')
                }
                $parameters.ButtonIndex = $buttonIndex
                $parameters.ButtonAction =
                    [Globalization.CultureInfo]::InvariantCulture.TextInfo.
                        ToTitleCase($normalizedAction)
            }
            $data = Send-VMateHyperVMouseEvent @parameters
        }
        '/getmouseposition' {
            $data = Get-VMateHyperVMousePosition -Session $session
        }
        '/getresolution' {
            $data = Get-VMateHyperVInputVideoHead -Session $session
        }
    }
    return [pscustomobject][ordered]@{
        Success = $true
        VM = $session.VMName
        Transport = $session.Transport
        Data = $data
    }
}

function Write-VMateHyperVInputBridgeResponse {
    param(
        [Parameter(Mandatory = $true)][Net.HttpListenerResponse]$Response,
        [Parameter(Mandatory = $true)][int]$StatusCode,
        [Parameter(Mandatory = $true)][object]$Body
    )

    $json = $Body | ConvertTo-Json -Depth 8 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = 'application/json; charset=utf-8'
    $Response.ContentLength64 = $bytes.Length
    $Response.Headers['Cache-Control'] = 'no-store'
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Start-VMateHyperVInputBridge {
    [CmdletBinding()]
    param(
        [ValidateRange(1024, 65535)][int]$Port = 18082,
        [ValidateRange(1, 300)][int]$RequestTimeoutSeconds = 15
    )

    Assert-VMateHyperVInputEnvironment
    $prefix = "http://127.0.0.1:$Port/"
    $listener = [Net.HttpListener]::new()
    $listener.Prefixes.Add($prefix)
    $listener.TimeoutManager.EntityBody =
        [TimeSpan]::FromSeconds($RequestTimeoutSeconds)
    $sessions = @{}
    try {
        $listener.Start()
        Write-Output ([pscustomobject][ordered]@{
            Status = 'Listening'
            Prefix = $prefix
            Transport = 'DirectHyperVCim'
            RuntimeModeSwitchAllowed = $false
        })
        while ($listener.IsListening) {
            $context = $listener.GetContext()
            try {
                if ([string]$context.Request.HttpMethod -cne 'GET') {
                    throw [InvalidOperationException]::new(
                        '输入桥只接受 GET。')
                }
                $body = Invoke-VMateHyperVInputBridgeRequest `
                    -Path $context.Request.Url.AbsolutePath `
                    -Query $context.Request.QueryString -Sessions $sessions
                Write-VMateHyperVInputBridgeResponse `
                    $context.Response 200 $body
            }
            catch [Management.Automation.ItemNotFoundException] {
                Write-VMateHyperVInputBridgeResponse $context.Response 404 `
                    ([pscustomobject]@{ Success = $false; Error = $_.Exception.Message })
            }
            catch [ArgumentException] {
                Write-VMateHyperVInputBridgeResponse $context.Response 400 `
                    ([pscustomobject]@{ Success = $false; Error = $_.Exception.Message })
            }
            catch {
                Write-VMateHyperVInputBridgeResponse $context.Response 409 `
                    ([pscustomobject]@{ Success = $false; Error = $_.Exception.Message })
            }
        }
    }
    finally {
        foreach ($session in @($sessions.Values)) {
            try { [void](Close-VMateHyperVInputSession $session) }
            catch { }
        }
        if ($listener.IsListening) { $listener.Stop() }
        $listener.Close()
    }
}
