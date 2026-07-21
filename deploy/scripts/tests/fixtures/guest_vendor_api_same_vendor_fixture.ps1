$ErrorActionPreference = 'Stop'

function Import-TestFunctions {
    param([Parameter(Mandatory = $true)][string]$Path)

    $source = [IO.File]::ReadAllText($Path)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput(
        $source, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw ('AST 不可用：' + $Path) }
    foreach ($definition in @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst]
            }, $true))) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }
}

# 只导入生产函数，不执行各脚本的 Windows 入口。文件事务全部在 mktemp 目录运行。
. Import-TestFunctions $env:COORDINATOR_PATH
. Import-TestFunctions $env:NVAPI_VALIDATION_PATH
. Import-TestFunctions $env:NVAPI_INSTALL_PATH
. Import-TestFunctions $env:NVAPI_TRANSACTION_PATH
. Import-TestFunctions $env:ADL_INSTALL_PATH
. Import-TestFunctions $env:ADL_TRANSACTION_PATH

$nvapiInstaller = 'nvapi-fixture'
$adlInstaller = 'adl-fixture'
$nvapiX86Hash = Get-LowerSha256 $env:NVAPI_X86
$nvapiX64Hash = Get-LowerSha256 $env:NVAPI_X64
$adlX86Hash = Get-LowerSha256 $env:ADL_X86
$adlX64Hash = Get-LowerSha256 $env:ADL_X64

function New-SameVendorFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]
        [ValidateSet('NVIDIA', 'AMD')][string]$Vendor
    )

    $root = Join-Path $env:TEST_ROOT $Name
    $x86 = Join-Path $root 'x86'
    $x64 = Join-Path $root 'x64'
    $null = [IO.Directory]::CreateDirectory($x86)
    $null = [IO.Directory]::CreateDirectory($x64)
    $nvapiEntries = @(
        [pscustomobject]@{
            FileName='nvapi.dll'; Source=$env:NVAPI_X86; Directory=$x86
            Target=(Join-Path $x86 'nvapi.dll'); ExpectedHash=$nvapiX86Hash
            HistoricalHashes=@(); Machine=0x014C; Magic=0x010B
            DesiredState=''; State=''; ObservedHash=''; Stage=''; Backup=''
            Discard=''; CommitAction=''
        },
        [pscustomobject]@{
            FileName='nvapi64.dll'; Source=$env:NVAPI_X64; Directory=$x64
            Target=(Join-Path $x64 'nvapi64.dll'); ExpectedHash=$nvapiX64Hash
            HistoricalHashes=@(); Machine=0x8664; Magic=0x020B
            DesiredState=''; State=''; ObservedHash=''; Stage=''; Backup=''
            Discard=''; CommitAction=''
        }
    )
    $adlEntries = @(
        [pscustomobject]@{
            FileName='atiadlxy.dll'; Source=$env:ADL_X86; Directory=$x86
            Target=(Join-Path $x86 'atiadlxy.dll'); ExpectedHash=$adlX86Hash
            HistoricalHashes=@(); Machine=0x014C; Magic=0x010B
            DesiredState=''; State=''; ObservedHash=''; Stage=''; Backup=''
            Discard=''; CommitAction=''
        },
        [pscustomobject]@{
            FileName='atiadlxx.dll'; Source=$env:ADL_X86; Directory=$x86
            Target=(Join-Path $x86 'atiadlxx.dll'); ExpectedHash=$adlX86Hash
            HistoricalHashes=@(); Machine=0x014C; Magic=0x010B
            DesiredState=''; State=''; ObservedHash=''; Stage=''; Backup=''
            Discard=''; CommitAction=''
        },
        [pscustomobject]@{
            FileName='atiadlxx.dll'; Source=$env:ADL_X64; Directory=$x64
            Target=(Join-Path $x64 'atiadlxx.dll'); ExpectedHash=$adlX64Hash
            HistoricalHashes=@(); Machine=0x8664; Magic=0x020B
            DesiredState=''; State=''; ObservedHash=''; Stage=''; Backup=''
            Discard=''; CommitAction=''
        }
    )
    if ($Vendor -ceq 'NVIDIA') {
        [IO.File]::Copy($env:NVAPI_X86, $nvapiEntries[0].Target)
        [IO.File]::Copy($env:NVAPI_X64, $nvapiEntries[1].Target)
    } else {
        [IO.File]::Copy($env:ADL_X86, $adlEntries[0].Target)
        [IO.File]::Copy($env:ADL_X86, $adlEntries[1].Target)
        [IO.File]::Copy($env:ADL_X64, $adlEntries[2].Target)
    }
    return [pscustomobject]@{
        Root=$root; Vendor=$Vendor; NvapiEntries=$nvapiEntries; AdlEntries=$adlEntries
    }
}

function Assert-ReceiptActions {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Expected
    )

    $actual = @((Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json).Entries.Action)
    if (($actual -join ',') -cne ($Expected -join ',')) {
        throw ('receipt Action 错误：' + ($actual -join ','))
    }
}

function Invoke-SameVendorPlan {
    param(
        [Parameter(Mandatory = $true)]$Fixture,
        [Parameter(Mandatory = $true)][string]$TransactionId
    )

    $plan = @(New-GpuApiVendorPlan $Fixture.Vendor)
    $actualPlan = @($plan | ForEach-Object {
            $_.Label + ':' + $_.DesiredState + ':' + [bool]$_.WithPayload
        }) -join ','
    $expectedPlan = if ($Fixture.Vendor -ceq 'NVIDIA') {
        'ADL:Absent:False,NVAPI:Present:True'
    } else {
        'NVAPI:Absent:False,ADL:Present:True'
    }
    if ($actualPlan -cne $expectedPlan) {
        throw ($Fixture.Vendor + ' coordinator 计划错误：' + $actualPlan)
    }

    foreach ($component in $plan) {
        if ($component.Label -ceq 'NVAPI') {
            foreach ($entry in $Fixture.NvapiEntries) {
                $entry.DesiredState = $component.DesiredState
            }
            $receipt = Join-Path $Fixture.Root 'nvapi-receipt.json'
            Publish-SystemProjectionEntries $Fixture.NvapiEntries $receipt $TransactionId
            $expected = if ($component.DesiredState -ceq 'Present') {
                @('Unchanged', 'Unchanged')
            } else { @('UnchangedAbsent', 'UnchangedAbsent') }
            Assert-ReceiptActions $receipt $expected
            Finalize-NvapiProjectionReceipt $Fixture.NvapiEntries $receipt $TransactionId
        } else {
            foreach ($entry in $Fixture.AdlEntries) {
                $entry.DesiredState = $component.DesiredState
            }
            $receipt = Join-Path $Fixture.Root 'adl-receipt.json'
            Publish-AdlProjection $Fixture.AdlEntries $receipt $TransactionId
            $expected = if ($component.DesiredState -ceq 'Present') {
                @('Unchanged', 'Unchanged', 'Unchanged')
            } else { @('UnchangedAbsent', 'UnchangedAbsent', 'UnchangedAbsent') }
            Assert-ReceiptActions $receipt $expected
            Finalize-AdlProjectionReceipt $Fixture.AdlEntries $receipt $TransactionId
        }
        if (Test-Path -LiteralPath $receipt) {
            throw ($component.Label + ' Finalize 遗留 receipt')
        }
    }
}

function Assert-SameVendorSurface {
    param([Parameter(Mandatory = $true)]$Fixture)

    $nvapiPresent = @($Fixture.NvapiEntries | Where-Object {
            Test-Path -LiteralPath $_.Target
        }).Count
    $adlPresent = @($Fixture.AdlEntries | Where-Object {
            Test-Path -LiteralPath $_.Target
        }).Count
    if ($Fixture.Vendor -ceq 'NVIDIA') {
        if ($nvapiPresent -ne 2 -or $adlPresent -ne 0) {
            throw 'NVIDIA→NVIDIA 重跑后系统表面不互斥'
        }
        foreach ($entry in $Fixture.NvapiEntries) {
            Assert-NvapiBinary $entry.Target $entry.ExpectedHash $entry.Machine $entry.Magic
        }
    } else {
        if ($nvapiPresent -ne 0 -or $adlPresent -ne 3) {
            throw 'AMD→AMD 重跑后系统表面不互斥'
        }
        foreach ($entry in $Fixture.AdlEntries) {
            Assert-AdlBinary $entry.Target $entry.ExpectedHash $entry.Machine $entry.Magic
        }
    }
    $temporary = @(Get-ChildItem -LiteralPath $Fixture.Root -File -Recurse -Force |
        Where-Object { $_.Name -match '\.vmate-(stage|backup|rollback)-' })
    if ($temporary.Count -ne 0) { throw '同厂商 Finalize 遗留临时文件' }
}

$nvidia = New-SameVendorFixture 'nvidia-to-nvidia' 'NVIDIA'
Invoke-SameVendorPlan $nvidia '81111111111111111111111111111111'
Assert-SameVendorSurface $nvidia

$amd = New-SameVendorFixture 'amd-to-amd' 'AMD'
Invoke-SameVendorPlan $amd '82222222222222222222222222222222'
Assert-SameVendorSurface $amd
