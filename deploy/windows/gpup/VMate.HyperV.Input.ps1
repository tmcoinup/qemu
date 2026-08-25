#Requires -Version 5.1

<#
.SYNOPSIS
    通过 Hyper-V WMI v2 的虚拟键盘和合成鼠标直接发送输入。

.DESCRIPTION
    输入会话的传输模式固定为 DirectHyperVCim，不提供运行中切换。模块对重复
    key/button down 做去重，并在批次失败或会话关闭时尽力释放已按下状态，避免
    网络重试或前端重复事件造成连续输入。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:VMateHyperVInputNamespace = 'root/virtualization/v2'
$script:VMateHyperVInputTransport = 'DirectHyperVCim'

function Get-VMateHyperVInputObjectProperty {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$DefaultValue = $null
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $DefaultValue }
    return $property.Value
}

function Assert-VMateHyperVInputEnvironment {
    if ($env:OS -cne 'Windows_NT') {
        throw 'Hyper-V 直连输入只能在 Windows Hyper-V 宿主运行。'
    }
    foreach ($name in @('Get-CimInstance', 'Get-CimAssociatedInstance',
            'Invoke-CimMethod')) {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            throw "缺少 Hyper-V 直连输入所需命令：$name"
        }
    }
}

function Get-VMateHyperVInputComputerSystem {
    param([Parameter(Mandatory = $true)][string]$VMName)

    $matches = @(Get-CimInstance -Namespace $script:VMateHyperVInputNamespace `
            -ClassName Msvm_ComputerSystem -ErrorAction Stop |
        Where-Object { [string]$_.ElementName -ieq $VMName })
    if ($matches.Count -ne 1) {
        throw "Hyper-V VM [$VMName] 的 Msvm_ComputerSystem 必须恰好一条，实际 $($matches.Count)。"
    }
    if ([int]$matches[0].EnabledState -ne 2) {
        throw "Hyper-V VM [$VMName] 必须为 Running 才能建立输入会话。"
    }
    return $matches[0]
}

function Get-VMateHyperVInputAssociatedDevice {
    param(
        [Parameter(Mandatory = $true)][object]$ComputerSystem,
        [Parameter(Mandatory = $true)][ValidateSet(
            'Msvm_Keyboard', 'Msvm_SyntheticMouse')][string]$ClassName,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $rows = @(Get-CimAssociatedInstance -InputObject $ComputerSystem `
        -Association Msvm_SystemDevice -ResultClassName $ClassName `
        -ErrorAction Stop)
    if ($rows.Count -ne 1) {
        throw "Hyper-V VM [$($ComputerSystem.ElementName)] 的 $Label 必须恰好一条，实际 $($rows.Count)。"
    }
    $device = $rows[0]
    $operational = @($device.OperationalStatus | ForEach-Object { [int]$_ })
    if ([int]$device.EnabledState -ne 2 -or
        [int]$device.HealthState -ne 5 -or $operational -notcontains 2) {
        throw ("Hyper-V VM [$($ComputerSystem.ElementName)] 的 $Label 不健康：" +
            "Enabled=$($device.EnabledState), Health=$($device.HealthState), " +
            "Operational=$($operational -join ',')。")
    }
    return $device
}

function Get-VMateHyperVInputVideoHead {
    param([Parameter(Mandatory = $true)][object]$Session)

    $rows = @(Get-CimInstance -Namespace $script:VMateHyperVInputNamespace `
            -ClassName Msvm_VideoHead -ErrorAction Stop |
        Where-Object {
            [string]$_.SystemName -ieq [string]$Session.VMId
        })
    if ($rows.Count -ne 1) {
        throw "Hyper-V VM [$($Session.VMName)] 的 Msvm_VideoHead 必须恰好一条，实际 $($rows.Count)。"
    }
    $head = $rows[0]
    $width = [int](Get-VMateHyperVInputObjectProperty $head `
        'CurrentHorizontalResolution' 0)
    $height = [int](Get-VMateHyperVInputObjectProperty $head `
        'CurrentVerticalResolution' 0)
    $refresh = [int](Get-VMateHyperVInputObjectProperty $head `
        'CurrentRefreshRate' 0)
    if ($width -lt 1 -or $height -lt 1 -or $refresh -lt 1) {
        throw "Hyper-V VM [$($Session.VMName)] 的当前视频模式不可用。"
    }
    return [pscustomobject][ordered]@{
        Width = $width
        Height = $height
        RefreshRate = $refresh
        BitsPerPixel = [int](Get-VMateHyperVInputObjectProperty $head `
            'CurrentBitsPerPixel' 0)
    }
}

function New-VMateHyperVInputSession {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()]
        [string]$VMName)

    Assert-VMateHyperVInputEnvironment
    $computerSystem = Get-VMateHyperVInputComputerSystem $VMName
    $keyboard = Get-VMateHyperVInputAssociatedDevice $computerSystem `
        Msvm_Keyboard '虚拟键盘'
    $mouse = Get-VMateHyperVInputAssociatedDevice $computerSystem `
        Msvm_SyntheticMouse '合成鼠标'
    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        Transport = $script:VMateHyperVInputTransport
        VMName = [string]$computerSystem.ElementName
        VMId = [string]$computerSystem.Name
        ComputerSystem = $computerSystem
        Keyboard = $keyboard
        Mouse = $mouse
        PressedKeys = [Collections.Generic.HashSet[uint32]]::new()
        PressedButtons = [Collections.Generic.HashSet[uint32]]::new()
        Closed = $false
    }
}

function Assert-VMateHyperVInputSession {
    param([Parameter(Mandatory = $true)][object]$Session)

    if ([int](Get-VMateHyperVInputObjectProperty $Session `
            'SchemaVersion' 0) -ne 1 -or
        [string](Get-VMateHyperVInputObjectProperty $Session `
            'Transport' '') -cne $script:VMateHyperVInputTransport) {
        throw '输入会话 schema 或固定传输类型无效。'
    }
    if ([bool](Get-VMateHyperVInputObjectProperty $Session 'Closed' $true)) {
        throw "Hyper-V VM [$($Session.VMName)] 的输入会话已关闭。"
    }
}

function Invoke-VMateHyperVInputMethod {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$MethodName,
        [Parameter(Mandatory = $true)][hashtable]$Arguments
    )

    $result = Invoke-CimMethod -InputObject $InputObject `
        -MethodName $MethodName -Arguments $Arguments -ErrorAction Stop
    $returnProperty = $result.PSObject.Properties['ReturnValue']
    if ($null -ne $returnProperty -and [uint32]$returnProperty.Value -ne 0) {
        throw "$MethodName 返回错误码 $($returnProperty.Value)。"
    }
    return $result
}

function ConvertTo-VMateHyperVInputScanCode {
    param([Parameter(Mandatory = $true)][object]$Value)

    $text = ([string]$Value).Trim()
    try {
        $code = if ($text -match '^0[xX][0-9a-fA-F]+$') {
            [Convert]::ToUInt32($text.Substring(2), 16)
        }
        elseif ($text -match '^\d+$') { [uint32]$text }
        else { throw 'format' }
    }
    catch {
        throw "键盘 MakeCode 无效：$text"
    }
    $plain = $code -ge 1 -and $code -le 0xFF
    $extended = $code -ge 0xE001 -and $code -le 0xE0FF
    if (-not $plain -and -not $extended) {
        throw "键盘 MakeCode 超出支持范围：$text"
    }
    return [uint32]$code
}

function Test-VMateHyperVKeyPressed {
    param(
        [Parameter(Mandatory = $true)][object]$Session,
        [Parameter(Mandatory = $true)][uint32]$KeyCode
    )

    $result = Invoke-VMateHyperVInputMethod $Session.Keyboard `
        'IsKeyPressed' @{ KeyCode = $KeyCode }
    return [bool](Get-VMateHyperVInputObjectProperty $result 'KeyState' $false)
}

function Send-VMateHyperVKeyEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Session,
        [Parameter(Mandatory = $true)][ValidateSet('Down', 'Up')]
        [string]$Action,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()]
        [object[]]$Code
    )

    Assert-VMateHyperVInputSession $Session
    if ($Code.Count -gt 16) {
        throw '单个键盘输入批次最多允许 16 个 MakeCode。'
    }
    $codes = @($Code | ForEach-Object {
        ConvertTo-VMateHyperVInputScanCode $_
    })
    if (@($codes | Sort-Object -Unique).Count -ne $codes.Count) {
        throw '同一键盘输入批次不能包含重复 MakeCode。'
    }

    $forwarded = [Collections.Generic.List[uint32]]::new()
    $suppressed = [Collections.Generic.List[uint32]]::new()
    if ($Action -ceq 'Down') {
        try {
            foreach ($keyCode in $codes) {
                if ($Session.PressedKeys.Contains($keyCode) -or
                    (Test-VMateHyperVKeyPressed $Session $keyCode)) {
                    [void]$Session.PressedKeys.Add($keyCode)
                    [void]$suppressed.Add($keyCode)
                    continue
                }
                [void](Invoke-VMateHyperVInputMethod $Session.Keyboard `
                    'PressKey' @{ KeyCode = $keyCode })
                [void]$Session.PressedKeys.Add($keyCode)
                [void]$forwarded.Add($keyCode)
            }
        }
        catch {
            $primary = $_.Exception.Message
            if ($forwarded.Count -gt 0) {
                for ($index = $forwarded.Count - 1; $index -ge 0; $index--) {
                    $keyCode = $forwarded[$index]
                    try {
                        [void](Invoke-VMateHyperVInputMethod $Session.Keyboard `
                            'ReleaseKey' @{ KeyCode = $keyCode })
                    } catch { }
                    [void]$Session.PressedKeys.Remove($keyCode)
                }
            }
            throw "键盘按下批次失败并已释放本批次按键：$primary"
        }
    }
    else {
        foreach ($keyCode in $codes) {
            $isPressed = $Session.PressedKeys.Contains($keyCode)
            if (-not $isPressed) {
                $isPressed = Test-VMateHyperVKeyPressed $Session $keyCode
            }
            if (-not $isPressed) {
                [void]$suppressed.Add($keyCode)
                continue
            }
            [void](Invoke-VMateHyperVInputMethod $Session.Keyboard `
                'ReleaseKey' @{ KeyCode = $keyCode })
            [void]$Session.PressedKeys.Remove($keyCode)
            [void]$forwarded.Add($keyCode)
        }
    }
    return [pscustomobject][ordered]@{
        VMName = $Session.VMName
        Transport = $Session.Transport
        Action = $Action
        Forwarded = @($forwarded)
        Suppressed = @($suppressed)
        PressedKeyCount = $Session.PressedKeys.Count
    }
}

function Get-VMateHyperVMousePosition {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Session)

    Assert-VMateHyperVInputSession $Session
    $Session.Mouse = Get-VMateHyperVInputAssociatedDevice `
        $Session.ComputerSystem Msvm_SyntheticMouse '合成鼠标'
    return [pscustomobject][ordered]@{
        X = [int]$Session.Mouse.HorizontalPosition
        Y = [int]$Session.Mouse.VerticalPosition
    }
}

function Test-VMateHyperVMouseButtonPressed {
    param(
        [Parameter(Mandatory = $true)][object]$Session,
        [Parameter(Mandatory = $true)][ValidateRange(0, 2)]
        [uint32]$ButtonIndex
    )

    $result = Invoke-VMateHyperVInputMethod $Session.Mouse `
        'GetButtonState' @{ ButtonIndex = $ButtonIndex }
    return [bool](Get-VMateHyperVInputObjectProperty $result 'IsDown' $false)
}

function Set-VMateHyperVMouseButton {
    param(
        [Parameter(Mandatory = $true)][object]$Session,
        [Parameter(Mandatory = $true)][ValidateRange(0, 2)]
        [uint32]$ButtonIndex,
        [Parameter(Mandatory = $true)][bool]$IsDown
    )

    $knownDown = $Session.PressedButtons.Contains($ButtonIndex)
    if (-not $knownDown) {
        $knownDown = Test-VMateHyperVMouseButtonPressed $Session $ButtonIndex
    }
    if ($knownDown -eq $IsDown) {
        if ($IsDown) { [void]$Session.PressedButtons.Add($ButtonIndex) }
        return $false
    }
    [void](Invoke-VMateHyperVInputMethod $Session.Mouse `
        'SetButtonState' @{ ButtonIndex = $ButtonIndex; IsDown = $IsDown })
    if ($IsDown) { [void]$Session.PressedButtons.Add($ButtonIndex) }
    else { [void]$Session.PressedButtons.Remove($ButtonIndex) }
    return $true
}

function Send-VMateHyperVMouseEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Session,
        [Parameter(Mandatory = $true)][ValidateSet('Absolute', 'Relative')]
        [string]$Type,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()]
        [object[]]$Position,
        [ValidateRange(-1, 2)][int]$ButtonIndex = -1,
        [ValidateSet('', 'Down', 'Up')][string]$ButtonAction = ''
    )

    Assert-VMateHyperVInputSession $Session
    if ($Position.Count -gt 128) {
        throw '单个鼠标输入批次最多允许 128 组坐标。'
    }
    if (($ButtonIndex -lt 0) -xor [String]::IsNullOrEmpty($ButtonAction)) {
        throw 'ButtonIndex 和 ButtonAction 必须同时提供或同时省略。'
    }
    $mode = Get-VMateHyperVInputVideoHead $Session
    $current = Get-VMateHyperVMousePosition $Session
    $resolved = [Collections.Generic.List[object]]::new()
    foreach ($point in $Position) {
        $xProperty = $point.PSObject.Properties['X']
        $yProperty = $point.PSObject.Properties['Y']
        if ($null -eq $xProperty -or $null -eq $yProperty) {
            throw '鼠标坐标必须同时包含 X 和 Y。'
        }
        $x = [int64]$xProperty.Value
        $y = [int64]$yProperty.Value
        if ($Type -ceq 'Relative') {
            $x += [int64]$current.X
            $y += [int64]$current.Y
        }
        $x = [Math]::Max(0, [Math]::Min([int64]$mode.Width - 1, $x))
        $y = [Math]::Max(0, [Math]::Min([int64]$mode.Height - 1, $y))
        $current = [pscustomobject]@{ X = [int]$x; Y = [int]$y }
        if ($resolved.Count -eq 0 -or
            $resolved[$resolved.Count - 1].X -ne $current.X -or
            $resolved[$resolved.Count - 1].Y -ne $current.Y) {
            [void]$resolved.Add($current)
        }
    }

    $buttonChanged = $false
    $buttonPressedByBatch = $false
    try {
        if ($ButtonAction -ceq 'Down') {
            $buttonChanged = Set-VMateHyperVMouseButton $Session `
                ([uint32]$ButtonIndex) $true
            $buttonPressedByBatch = $buttonChanged
        }
        foreach ($point in $resolved) {
            [void](Invoke-VMateHyperVInputMethod $Session.Mouse `
                'SetAbsolutePosition' @{
                    HorizontalPosition = [int]$point.X
                    VerticalPosition = [int]$point.Y
                })
        }
        if ($ButtonAction -ceq 'Up') {
            $buttonChanged = Set-VMateHyperVMouseButton $Session `
                ([uint32]$ButtonIndex) $false
        }
    }
    catch {
        $primary = $_.Exception.Message
        if ($buttonPressedByBatch) {
            try {
                [void](Set-VMateHyperVMouseButton $Session `
                    ([uint32]$ButtonIndex) $false)
            } catch { }
        }
        throw "鼠标输入批次失败：$primary"
    }
    return [pscustomobject][ordered]@{
        VMName = $Session.VMName
        Transport = $Session.Transport
        Type = $Type
        ForwardedPositionCount = $resolved.Count
        FinalPosition = $current
        ButtonChanged = $buttonChanged
        PressedButtonCount = $Session.PressedButtons.Count
        Resolution = $mode
    }
}

function Close-VMateHyperVInputSession {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Session)

    if ([bool](Get-VMateHyperVInputObjectProperty $Session 'Closed' $true)) {
        return [pscustomobject]@{ Closed = $true; ReleaseErrors = @() }
    }
    $errors = [Collections.Generic.List[string]]::new()
    foreach ($keyCode in @($Session.PressedKeys)) {
        try {
            [void](Invoke-VMateHyperVInputMethod $Session.Keyboard `
                'ReleaseKey' @{ KeyCode = [uint32]$keyCode })
        }
        catch { [void]$errors.Add($_.Exception.Message) }
    }
    foreach ($buttonIndex in @($Session.PressedButtons)) {
        try {
            [void](Invoke-VMateHyperVInputMethod $Session.Mouse `
                'SetButtonState' @{
                    ButtonIndex = [uint32]$buttonIndex
                    IsDown = $false
                })
        }
        catch { [void]$errors.Add($_.Exception.Message) }
    }
    $Session.PressedKeys.Clear()
    $Session.PressedButtons.Clear()
    $Session.Closed = $true
    return [pscustomobject][ordered]@{
        Closed = $true
        ReleaseErrors = @($errors)
    }
}
