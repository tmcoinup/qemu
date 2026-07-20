# install-chipset-device.ps1 —— 幂等安装 Intel SMBus 的签名设备识别 INF。
#
# QEMU 当前仍实现 ICH9 SMBus 寄存器行为，但已启用的平台会把 PCI 配置身份投影为：
#   - H310: PCI\VEN_8086&DEV_A323
#   - H110: PCI\VEN_8086&DEV_A123
# Windows 10 19041 的 inbox machine.inf 不认识这两个投影 ID，因此设备管理器显示
# Code 28。Intel 官方包对两者使用 Needs_NO_DRV：它只把设备归入 System 类并赋予
# 正确名称，不包含 SYS/服务，也不会假装提供 Cannon Lake/Sunrise Point 寄存器行为。

param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $DriverDir
)

$ErrorActionPreference = 'Stop'
$RestartRequiredExitCode = 30

# 固定 INF/CAT 原字节和 WHCP 签名者。摘要防止不同版本、不同 OEM 包或被修改文件
# 混入；Authenticode 的 Windows 信任状态再证明 CAT 证书链在当前 guest 上有效。
$ChipsetPayloads = @(
    [pscustomobject]@{
        DeviceId        = 'A323'
        InfName         = 'CannonLake-HSystem.inf'
        CatName         = 'cannonlake-h.cat'
        CatalogFile     = 'CannonLake-H.cat'
        FriendlyName    = 'Intel(R) SMBus - A323'
        InfHash         = '0793ffcb29ba4dd13e62ec1c406884193cbf893d95e0b49840da609d8447a123'
        CatHash         = '9e457455e44a4215610c1160c6b3cbe345a4ee8e2af621e51ef6d1079870dba2'
        SignerThumbprint = '580E5B74E4A43390FE113F7CAD3C138E21776F1E'
    },
    [pscustomobject]@{
        DeviceId        = 'A123'
        InfName         = 'SunrisePoint-HSystem.inf'
        CatName         = 'sunrisepoint-h.cat'
        CatalogFile     = 'SunrisePoint-H.cat'
        FriendlyName    = 'Intel(R) 100 Series/C230 Series Chipset Family SMBus - A123'
        InfHash         = '4d931028bc5d6f1d28ec05f80e1b365d42a3d0ff00b0aeebe582c07dc83a1f70'
        CatHash         = 'd22cdfa1018a00aa0b61172017f7bfb8f58382bfa80545e56b2b7a16c0242b9b'
        SignerThumbprint = 'A3165BF7F09B48194C3724707023CDA874710D16'
    }
)

function Stop-ChipsetInstall {
    param(
        [Parameter(Mandatory = $true)] [string] $Message,
        [int] $Code = 50
    )

    Write-Host ('FAIL: ' + $Message) -ForegroundColor Red
    exit $Code
}

function Get-DevicePropertyValue {
    param(
        [Parameter(Mandatory = $true)] [string] $InstanceId,
        [Parameter(Mandatory = $true)] [string] $KeyName
    )

    # Code 28 节点通常没有 Class、Service 或 DriverInfPath。缺失属性属于待安装状态，
    # 返回 null 交给健康判定，不能因一次 PropertyNotFound 提前丢失目标设备。
    try {
        $property = Get-PnpDeviceProperty -InstanceId $InstanceId `
            -KeyName $KeyName -ErrorAction Stop
        return $property.Data
    } catch {
        return $null
    }
}

function ConvertTo-ProblemCode {
    param(
        [AllowNull()] [object] $PropertyValue,
        [AllowNull()] [object] $FallbackValue,
        [AllowNull()] [string] $Status
    )

    foreach ($candidate in $PropertyValue, $FallbackValue) {
        if ($null -eq $candidate) { continue }
        $text = [string] $candidate
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($text -match '^[0-9]+$') { return [int] $text }
        if ($text -ieq 'CM_PROB_NONE') { return 0 }
        if ($text -match '(?i)CM_PROB_FAILED_INSTALL|DRIVER_FAILED_LOAD') { return 28 }
    }

    # 某些早期 PnpDevice 模块不公开 ProblemCode，但会在设备完全正常时给出 OK。
    # 只对明确的 OK 使用等价值 0；其它状态保持 -1，避免把未知问题当作成功。
    if ($Status -ieq 'OK') { return 0 }
    return -1
}

function Find-ChipsetPayload {
    param([Parameter(Mandatory = $true)] [string] $InstanceId)

    foreach ($payload in $ChipsetPayloads) {
        $pattern = '(?i)^PCI\\VEN_8086&DEV_' + $payload.DeviceId + '(?:&|\\|$)'
        if ($InstanceId -match $pattern) { return $payload }
    }
    return $null
}

function Get-PresentChipsetStates {
    # 不按 Class 过滤：未绑定的目标位于“其他设备”，安装后才进入 System。
    # PresentOnly 排除克隆镜像中遗留的 ghost A123/A323，避免给不存在设备装包。
    $devices = @(Get-PnpDevice -PresentOnly -ErrorAction Stop)
    $states = @()
    foreach ($device in $devices) {
        $instanceId = [string] $device.InstanceId
        if ([string]::IsNullOrWhiteSpace($instanceId)) { continue }
        $payload = Find-ChipsetPayload -InstanceId $instanceId
        if ($null -eq $payload) { continue }

        $problemProperty = Get-DevicePropertyValue -InstanceId $instanceId `
            -KeyName 'DEVPKEY_Device_ProblemCode'
        $problemFallback = $null
        if ($null -ne $device.PSObject.Properties['ConfigManagerErrorCode']) {
            $problemFallback = $device.ConfigManagerErrorCode
        } elseif ($null -ne $device.PSObject.Properties['Problem']) {
            $problemFallback = $device.Problem
        }
        $status = [string] $device.Status
        $className = Get-DevicePropertyValue -InstanceId $instanceId `
            -KeyName 'DEVPKEY_Device_Class'
        if ([string]::IsNullOrWhiteSpace([string] $className)) {
            $className = [string] $device.Class
        }
        $friendlyName = [string] $device.FriendlyName
        if ([string]::IsNullOrWhiteSpace($friendlyName)) {
            $friendlyName = [string] (Get-DevicePropertyValue -InstanceId $instanceId `
                -KeyName 'DEVPKEY_Device_FriendlyName')
        }

        $states += [pscustomobject]@{
            InstanceId  = $instanceId
            Status      = $status
            ProblemCode = ConvertTo-ProblemCode -PropertyValue $problemProperty `
                -FallbackValue $problemFallback -Status $status
            ClassName   = [string] $className
            FriendlyName = $friendlyName
            InfPath     = [string] (Get-DevicePropertyValue -InstanceId $instanceId `
                -KeyName 'DEVPKEY_Device_DriverInfPath')
            Service     = [string] (Get-DevicePropertyValue -InstanceId $instanceId `
                -KeyName 'DEVPKEY_Device_Service')
            Payload     = $payload
        }
    }
    return @($states)
}

function Get-ChipsetStateProblems {
    param([Parameter(Mandatory = $true)] [object] $State)

    $problems = @()
    if ($State.Status -ine 'OK') { $problems += "Status=$($State.Status)" }
    if ([int] $State.ProblemCode -ne 0) {
        $problems += "ProblemCode=$($State.ProblemCode)"
    }
    if ($State.ClassName -ine 'System') { $problems += "Class=$($State.ClassName)" }
    if ($State.InfPath -notmatch '(?i)^oem[0-9]+\.inf$') {
        $problems += "InfPath=$($State.InfPath)"
    }
    if (-not [string]::IsNullOrWhiteSpace([string] $State.Service)) {
        $problems += "Service=$($State.Service)"
    }
    if ($State.FriendlyName -ine $State.Payload.FriendlyName) {
        $problems += "FriendlyName=$($State.FriendlyName)"
    }
    return @($problems)
}

function Test-AllChipsetStatesHealthy {
    param([Parameter(Mandatory = $true)] [object[]] $States)

    foreach ($state in $States) {
        if (@(Get-ChipsetStateProblems -State $state).Count -ne 0) { return $false }
    }
    return $true
}

function Test-SameInstanceSet {
    param(
        [Parameter(Mandatory = $true)] [string[]] $Expected,
        [Parameter(Mandatory = $true)] [string[]] $Actual
    )

    if ($Expected.Count -ne $Actual.Count) { return $false }
    foreach ($expectedId in $Expected) {
        if (@($Expected | Where-Object { $_ -ieq $expectedId }).Count -ne 1 -or
            @($Actual | Where-Object { $_ -ieq $expectedId }).Count -ne 1) {
            return $false
        }
    }
    return $true
}

function Write-ChipsetStates {
    param([Parameter(Mandatory = $true)] [object[]] $States)

    foreach ($state in $States) {
        Write-Host ("  PCI       : " + $state.InstanceId) -ForegroundColor Gray
        Write-Host ("  Name      : " + $state.FriendlyName) -ForegroundColor Gray
        Write-Host ("  INF/Class : " + $state.InfPath + ' / ' + $state.ClassName) `
            -ForegroundColor Gray
        Write-Host ("  PnP state : " + $state.Status + ' / Code ' +
            $state.ProblemCode) -ForegroundColor Gray
    }
}

function Assert-PlainPayloadFile {
    param(
        [Parameter(Mandatory = $true)] [string] $Root,
        [Parameter(Mandatory = $true)] [string] $FileName
    )

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $path = [IO.Path]::GetFullPath((Join-Path $rootFull $FileName))
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetDirectoryName($path))
    if ($expectedParent -ine $rootFull) { throw "payload 逃逸受控目录: $FileName" }

    $rootItem = Get-Item -LiteralPath $rootFull -Force -ErrorAction Stop
    $fileItem = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or $fileItem.PSIsContainer -or
        ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($fileItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "payload 不是受控普通文件: $FileName"
    }
    return $path
}

function Assert-ExactPayloadHash {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $ExpectedHash
    )

    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 `
        -ErrorAction Stop).Hash
    if ($actual -ine $ExpectedHash) {
        throw ([IO.Path]::GetFileName($Path) + " SHA-256 不匹配: $actual")
    }
}

function Assert-WhcpCatalog {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $ExpectedThumbprint
    )

    $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    $certificate = $signature.SignerCertificate
    $subject = if ($null -eq $certificate) { '' } else {
        [string] $certificate.Subject
    }
    $issuer = if ($null -eq $certificate) { '' } else {
        [string] $certificate.Issuer
    }
    $thumbprint = if ($null -eq $certificate) { '' } else {
        ([string] $certificate.Thumbprint).Replace(' ', '')
    }
    if ($signature.Status -ne 'Valid' -or
        $subject -notmatch '(?i)(^|,\s*)CN=Microsoft Windows Hardware Compatibility Publisher(,|$)' -or
        $issuer -notmatch '(?i)(^|,\s*)CN=Microsoft Windows Third Party Component CA 2012(,|$)' -or
        $thumbprint -ine $ExpectedThumbprint) {
        throw ([IO.Path]::GetFileName($Path) + ' 不是锁定的可信 Microsoft WHCP CAT')
    }
}

function Assert-ChipsetPayload {
    param(
        [Parameter(Mandatory = $true)] [object] $Payload,
        [Parameter(Mandatory = $true)] [string] $Root
    )

    $infPath = Assert-PlainPayloadFile -Root $Root -FileName $Payload.InfName
    $catPath = Assert-PlainPayloadFile -Root $Root -FileName $Payload.CatName
    Assert-ExactPayloadHash -Path $infPath -ExpectedHash $Payload.InfHash
    Assert-ExactPayloadHash -Path $catPath -ExpectedHash $Payload.CatHash

    # 摘要已经锁定完整内容；以下语义检查让构建/测试失败信息直接指出误用功能 INF、
    # 错 ID 或错 CAT，而不是等到 pnputil 返回一个难以定位的通用错误。
    $infText = [IO.File]::ReadAllText($infPath)
    $hardwareId = 'PCI\VEN_8086&DEV_' + $Payload.DeviceId
    if ($infText.IndexOf($hardwareId, [StringComparison]::OrdinalIgnoreCase) -lt 0 -or
        $infText.IndexOf('[Needs_NO_DRV]', [StringComparison]::OrdinalIgnoreCase) -lt 0 -or
        $infText -notmatch '(?im)^\s*Needs\s*=\s*NO_DRV\s*$' -or
        $infText.IndexOf(('CatalogFile=' + $Payload.CatalogFile),
            [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw ($Payload.InfName + ' 不符合锁定的 NO_DRV/A123/A323 契约')
    }
    Assert-WhcpCatalog -Path $catPath `
        -ExpectedThumbprint $Payload.SignerThumbprint
    return $infPath
}

try {
    $before = @(Get-PresentChipsetStates)
} catch {
    Stop-ChipsetInstall ('无法枚举当前 PnP 设备: ' + $_.Exception.Message) 50
}

if ($before.Count -eq 0) {
    Write-Host '  未发现当前平台的 A123/A323 SMBus；无需安装芯片组识别 INF。' `
        -ForegroundColor Green
    exit 0
}

Write-ChipsetStates -States $before
if (Test-AllChipsetStatesHealthy -States $before) {
    Write-Host '  Intel SMBus 识别 INF 已正确绑定，跳过 pnputil。' -ForegroundColor Green
    exit 0
}

$systemDirectory = [Environment]::SystemDirectory
$pnputil = if ([string]::IsNullOrWhiteSpace($systemDirectory)) { '' } else {
    Join-Path $systemDirectory 'pnputil.exe'
}
if ([string]::IsNullOrWhiteSpace($pnputil) -or
    -not (Test-Path -LiteralPath $pnputil -PathType Leaf)) {
    Stop-ChipsetInstall '找不到可信 System32\pnputil.exe。' 51
}

$targetIds = [string[]] @($before.InstanceId)
$deviceIdsToInstall = @($before |
    Where-Object { @(Get-ChipsetStateProblems -State $_).Count -ne 0 } |
    ForEach-Object { [string] $_.Payload.DeviceId } |
    Select-Object -Unique)
$restartRequired = $false

foreach ($deviceId in $deviceIdsToInstall) {
    $payload = @($ChipsetPayloads | Where-Object {
            $_.DeviceId -ieq $deviceId
        })
    if ($payload.Count -ne 1) {
        Stop-ChipsetInstall "设备 $deviceId 没有唯一 payload 映射。" 52
    }
    try {
        $infPath = Assert-ChipsetPayload -Payload $payload[0] -Root $DriverDir
    } catch {
        Stop-ChipsetInstall ('芯片组 payload 验证失败: ' + $_.Exception.Message) 52
    }

    Write-Host ("  安装 Microsoft WHCP 签名的 " + $payload[0].InfName + ' ...') `
        -ForegroundColor Cyan
    & $pnputil /add-driver $infPath /install
    $pnputilCode = $LASTEXITCODE
    if ($pnputilCode -eq 3010) {
        $restartRequired = $true
        continue
    }
    if ($pnputilCode -ne 0) {
        Stop-ChipsetInstall ("pnputil 安装失败，退出码=$pnputilCode。") 53
    }
}

if ($restartRequired) {
    Write-Host '  芯片组识别 INF 已提交，Windows 要求重启后完成绑定。' `
        -ForegroundColor Yellow
    exit $RestartRequiredExitCode
}

$deadline = [DateTime]::UtcNow.AddSeconds(15)
do {
    Start-Sleep -Milliseconds 250
    try {
        $after = @(Get-PresentChipsetStates)
    } catch {
        $after = @()
    }
    if ((Test-SameInstanceSet -Expected $targetIds `
            -Actual ([string[]] @($after.InstanceId))) -and
        (Test-AllChipsetStatesHealthy -States $after)) {
        Write-ChipsetStates -States $after
        Write-Host '  Intel SMBus Code 28 已清除；设备识别 INF 绑定正常。' `
            -ForegroundColor Green
        exit 0
    }
} while ([DateTime]::UtcNow -lt $deadline)

if ($after.Count -gt 0) { Write-ChipsetStates -States $after }
Stop-ChipsetInstall 'pnputil 返回成功，但 A123/A323 在 15 秒内未通过后验校验。' 54
