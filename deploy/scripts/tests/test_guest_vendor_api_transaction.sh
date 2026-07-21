#!/usr/bin/env bash
# 验证发布包可携带两家 GPU API，但 guest 系统目录始终只保留当前 profile 的一家。
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
COORDINATOR="$REPO_ROOT/deploy/guest-stealth/install-gpu-api-system.ps1"
IDENTITY_BINDING="$REPO_ROOT/deploy/guest-stealth/gpu-api-identity-binding.ps1"
NVAPI_INSTALL="$REPO_ROOT/deploy/guest-stealth/install-nvapi-system.ps1"
NVAPI_VALIDATION="$REPO_ROOT/deploy/guest-stealth/nvapi-system-validation.ps1"
NVAPI_TRANSACTION="$REPO_ROOT/deploy/guest-stealth/nvapi-system-transaction.ps1"
ADL_INSTALL="$REPO_ROOT/deploy/guest-stealth/install-adl-system.ps1"
ADL_TRANSACTION="$REPO_ROOT/deploy/guest-stealth/adl-system-transaction.ps1"
APPLY="$REPO_ROOT/deploy/scripts/apply-gpu-spoof.ps1"
NVAPI_DIR="$REPO_ROOT/deploy/nvapi-shim"
ADL_DIR="$REPO_ROOT/deploy/adl-shim"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for path in "$COORDINATOR" "$IDENTITY_BINDING" "$NVAPI_INSTALL" \
        "$NVAPI_VALIDATION" "$NVAPI_TRANSACTION" \
        "$ADL_INSTALL" "$ADL_TRANSACTION" "$APPLY" \
        "$NVAPI_DIR/nvapi.dll" "$NVAPI_DIR/nvapi64.dll" \
        "$ADL_DIR/atiadlxy.dll" "$ADL_DIR/atiadlxx.dll"; do
    [[ -f "$path" ]] || fail "缺少厂商互斥事务文件：$path"
done

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

COORDINATOR_PATH="$COORDINATOR" NVAPI_INSTALL_PATH="$NVAPI_INSTALL" \
NVAPI_VALIDATION_PATH="$NVAPI_VALIDATION" \
NVAPI_TRANSACTION_PATH="$NVAPI_TRANSACTION" ADL_INSTALL_PATH="$ADL_INSTALL" \
ADL_TRANSACTION_PATH="$ADL_TRANSACTION" APPLY_PATH="$APPLY" \
NVAPI_X86="$NVAPI_DIR/nvapi.dll" NVAPI_X64="$NVAPI_DIR/nvapi64.dll" \
ADL_X86="$ADL_DIR/atiadlxy.dll" ADL_X64="$ADL_DIR/atiadlxx.dll" \
TEST_ROOT="$TEST_ROOT" pwsh -NoLogo -NoProfile -NonInteractive -Command '
    $ErrorActionPreference = "Stop"

    function Import-Functions {
        param([string]$Path)
        $source = [IO.File]::ReadAllText($Path)
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput(
            $source, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw ("AST 不可用：" + $Path) }
        foreach ($definition in @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst]
        }, $true))) {
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        return $ast
    }

    function Assert-ScriptParameter {
        param([string]$Path, [string]$Name, [string]$Default, [string[]]$Values)
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            $Path, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw ("AST 不可用：" + $Path) }
        $parameter = @($ast.ParamBlock.Parameters | Where-Object {
            $_.Name.VariablePath.UserPath -ceq $Name
        })
        if ($parameter.Count -ne 1) { throw ("缺少唯一参数：" + $Name) }
        if ([string]$parameter[0].DefaultValue.SafeGetValue() -cne $Default) {
            throw ($Name + " 默认值必须为 " + $Default)
        }
        $validateSet = @($parameter[0].Attributes | Where-Object {
            $_.TypeName.Name -ceq "ValidateSet"
        })
        if ($validateSet.Count -ne 1) { throw ($Name + " 缺少 ValidateSet") }
        $actual = @($validateSet[0].PositionalArguments | ForEach-Object {
            [string]$_.SafeGetValue()
        })
        if (($actual -join ",") -cne ($Values -join ",")) {
            throw ($Name + " ValidateSet 错误：" + ($actual -join ","))
        }
    }

    function Assert-Plan {
        param([string]$Vendor, [string[]]$Expected)
        $plan = @(New-GpuApiVendorPlan $Vendor)
        $actual = @($plan | ForEach-Object {
            $_.Label + ":" + $_.DesiredState + ":" + [bool]$_.WithPayload
        })
        if (($actual -join ",") -cne ($Expected -join ",")) {
            throw ($Vendor + " 厂商计划错误：" + ($actual -join ","))
        }
    }

    Assert-ScriptParameter $env:COORDINATOR_PATH "Vendor" "Auto" `
        @("Auto", "NVIDIA", "AMD")
    Assert-ScriptParameter $env:NVAPI_INSTALL_PATH "DesiredState" "Present" `
        @("Present", "Absent")
    Assert-ScriptParameter $env:ADL_INSTALL_PATH "DesiredState" "Present" `
        @("Present", "Absent")

    $coordinatorAst = . Import-Functions $env:COORDINATOR_PATH
    Assert-Plan "NVIDIA" @("ADL:Absent:False", "NVAPI:Present:True")
    Assert-Plan "AMD" @("NVAPI:Absent:False", "ADL:Present:True")

    # 直接执行 coordinator 的顶层状态机，但用纯内存 installer/reservation 替身。
    # 这样测试的是生产计划、全量 Preflight、Prepare 和反向 Rollback，而不是复制
    # 一份测试专用协调算法。所有 Windows 系统目录写入都由替身截获。
    $runtimeStatements = @($coordinatorAst.EndBlock.Statements | Where-Object {
        $_ -isnot [Management.Automation.Language.FunctionDefinitionAst]
    })
    $runtimeStart = -1
    for ($index = 0; $index -lt $runtimeStatements.Count; $index++) {
        if ($runtimeStatements[$index].Extent.Text.Contains("DeferFinalize")) {
            $runtimeStart = $index
            break
        }
    }
    if ($runtimeStart -lt 0) { throw "无法定位 coordinator 顶层状态机" }
    $bodyText = @($runtimeStatements[$runtimeStart..($runtimeStatements.Count - 1)] |
        ForEach-Object { $_.Extent.Text }) -join "`n"
    $coordinatorBody = [scriptblock]::Create($bodyText)

    function Invoke-CoordinatorFixture {
        param(
            [string]$FixtureVendor,
            [string]$FailLabel = "",
            [ValidateSet("Install", "Preflight")][string]$FixtureAction = "Install"
        )
        $script:fixtureCalls = New-Object Collections.Generic.List[string]
        $script:fixtureReservation = $false
        $script:fixtureFailLabel = $FailLabel
        # coordinator 的生产 binding helper 会读 Windows Registry64。此 fixture 只验证
        # 已裁决 vendor 后的组件调度，因此用临时 helper 保持请求值并避免 host 注册表依赖。
        $identityBindingHelper = Join-Path $env:TEST_ROOT "identity-binding-fixture.ps1"
        $bindingFixtureSource = "function Assert-GpuApiInstallIdentityBinding { " +
            "param([string]`$TransactionId,[string]`$RequestedVendor) " +
            "return `$RequestedVendor }"
        [IO.File]::WriteAllText($identityBindingHelper, $bindingFixtureSource)
        function Assert-GpuApiCoordinatorFiles { }
        function Get-GpuApiReservationDirectory { return $env:TEST_ROOT }
        function Open-GpuApiCoordinatorLock {
            param([string]$Directory)
            return [IO.MemoryStream]::new()
        }
        function New-GpuApiReservation {
            param([string]$Path, [string]$TransactionId, [string]$Vendor)
            $script:fixtureReservation = $true
        }
        function Remove-GpuApiReservation {
            param([string]$Path, [string]$TransactionId)
            $script:fixtureReservation = $false
        }
        function Assert-GpuApiReservationOwner { }
        function Invoke-GpuApiInstaller {
            param(
                [string]$Label, [string]$Script, [string]$ChildAction,
                [string]$DesiredState, [string]$ChildTransactionId,
                [switch]$WithPayload, [switch]$Deferred
            )
            $script:fixtureCalls.Add(
                ($Label + ":" + $DesiredState + ":" + $ChildAction))
            if ($ChildAction -ceq "Install" -and
                $Label -ceq $script:fixtureFailLabel) {
                throw ("injected " + $Label + " prepare failure")
            }
        }

        $Action = $FixtureAction
        $Vendor = $FixtureVendor
        $PayloadDir = $env:TEST_ROOT
        $nvapiInstaller = "nvapi-installer"
        $adlInstaller = "adl-installer"
        $powershellExe = "powershell-fixture"
        $TransactionId = if ($FixtureAction -ceq "Install") {
            "11111111111111111111111111111111"
        } else { "" }
        $DeferFinalize = $FixtureAction -ceq "Install"
        $message = ""
        try { $null = & $coordinatorBody } catch { $message = $_.Exception.Message }
        return [pscustomobject]@{
            Calls=@($script:fixtureCalls); Error=$message
            Reservation=$script:fixtureReservation
        }
    }

    function Assert-Calls {
        param($Result, [string[]]$Expected, [bool]$Reservation)
        if (($Result.Calls -join ",") -cne ($Expected -join ",")) {
            throw ("coordinator 调用顺序错误：" + ($Result.Calls -join ",") +
                "；error=" + $Result.Error)
        }
        if ([bool]$Result.Reservation -ne $Reservation) {
            throw "coordinator reservation 收口状态错误"
        }
    }

    $nvidiaFailure = Invoke-CoordinatorFixture "NVIDIA" "NVAPI"
    Assert-Calls $nvidiaFailure @(
        "ADL:Absent:Preflight", "NVAPI:Present:Preflight",
        "ADL:Absent:Install", "NVAPI:Present:Install",
        "NVAPI:Present:Rollback", "ADL:Absent:Rollback") $false
    if (-not $nvidiaFailure.Error) { throw "NVIDIA->NVAPI 故障注入未失败" }

    $amdFailure = Invoke-CoordinatorFixture "AMD" "ADL"
    Assert-Calls $amdFailure @(
        "NVAPI:Absent:Preflight", "ADL:Present:Preflight",
        "NVAPI:Absent:Install", "ADL:Present:Install",
        "ADL:Present:Rollback", "NVAPI:Absent:Rollback") $false
    if (-not $amdFailure.Error) { throw "AMD->ADL 故障注入未失败" }

    # Auto 只是安全默认值，不能让正式 Install/Preflight 猜测克隆前的旧厂商。
    $autoResult = Invoke-CoordinatorFixture "Auto" "" "Preflight"
    if (-not $autoResult.Error -or $autoResult.Calls.Count -ne 0 -or
        $autoResult.Reservation) {
        throw "Auto Preflight 没有在任何 child/reservation 动作前被拒绝"
    }

    function Get-TreeDigest {
        param([string]$Root)
        return (@(Get-ChildItem -LiteralPath $Root -File -Recurse -Force |
            Sort-Object FullName | ForEach-Object {
                $_.FullName.Substring($Root.Length) + "|" +
                    (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            }) -join "`n")
    }

    function Write-LegacyReceipt {
        param([object[]]$Entries, [string]$Path, [string]$Id, [int]$Schema)
        $records = @($Entries | ForEach-Object {
            [ordered]@{
                FileName=$_.FileName; Target=$_.Target
                ExpectedHash=$_.ExpectedHash; PreviousHash=$_.ExpectedHash
                Action="Unchanged"; Stage=""; Backup=""; Discard=""
            }
        })
        [IO.File]::WriteAllText($Path, ([ordered]@{
            SchemaVersion=$Schema; TransactionId=$Id; Entries=$records
        } | ConvertTo-Json -Depth 4))
    }

    # 先运行全部 NVAPI fixture，随后才载入含同名通用 helper 的 ADL 函数，避免测试
    # 进程里的函数名覆盖影响任一生产状态机。
    $null = . Import-Functions $env:NVAPI_VALIDATION_PATH
    $null = . Import-Functions $env:NVAPI_INSTALL_PATH
    $null = . Import-Functions $env:NVAPI_TRANSACTION_PATH
    $nvX86Hash = (Get-FileHash $env:NVAPI_X86 -Algorithm SHA256).Hash.ToLowerInvariant()
    $nvX64Hash = (Get-FileHash $env:NVAPI_X64 -Algorithm SHA256).Hash.ToLowerInvariant()
    function New-NvEntries {
        param([string]$Root, [string]$DesiredState, [switch]$Seed)
        $x86 = Join-Path $Root "x86"; $x64 = Join-Path $Root "x64"
        [IO.Directory]::CreateDirectory($x86) | Out-Null
        [IO.Directory]::CreateDirectory($x64) | Out-Null
        $entries = @(
            [pscustomobject]@{ FileName="nvapi.dll"; Source=$env:NVAPI_X86
                Directory=$x86; Target=(Join-Path $x86 "nvapi.dll")
                ExpectedHash=$nvX86Hash; HistoricalHashes=@(); Machine=0x014C
                Magic=0x010B; DesiredState=$DesiredState; State=""; ObservedHash=""
                Stage=""; Backup=""; Discard=""; CommitAction="" },
            [pscustomobject]@{ FileName="nvapi64.dll"; Source=$env:NVAPI_X64
                Directory=$x64; Target=(Join-Path $x64 "nvapi64.dll")
                ExpectedHash=$nvX64Hash; HistoricalHashes=@(); Machine=0x8664
                Magic=0x020B; DesiredState=$DesiredState; State=""; ObservedHash=""
                Stage=""; Backup=""; Discard=""; CommitAction="" }
        )
        if ($Seed) {
            [IO.File]::Copy($env:NVAPI_X86, $entries[0].Target)
            [IO.File]::Copy($env:NVAPI_X64, $entries[1].Target)
        }
        return $entries
    }

    $nvidiaNv = @(New-NvEntries (Join-Path $env:TEST_ROOT "nvidia") "Present")
    $nvidiaNvReceipt = Join-Path $env:TEST_ROOT "nv-present.json"
    $nvidiaNvId = "21111111111111111111111111111111"
    Publish-SystemProjectionEntries $nvidiaNv $nvidiaNvReceipt $nvidiaNvId
    Finalize-NvapiProjectionReceipt $nvidiaNv $nvidiaNvReceipt $nvidiaNvId

    $amdNv = @(New-NvEntries (Join-Path $env:TEST_ROOT "amd") "Absent" -Seed)
    $amdNvReceipt = Join-Path $env:TEST_ROOT "nv-removed.json"
    $amdNvId = "22222222222222222222222222222222"
    Publish-SystemProjectionEntries $amdNv $amdNvReceipt $amdNvId
    $nvActions = @((Get-Content $amdNvReceipt -Raw | ConvertFrom-Json).Entries.Action)
    if (($nvActions -join ",") -cne "Removed,Removed") {
        throw ("NVAPI Absent receipt 不是 Removed：" + ($nvActions -join ","))
    }
    Finalize-NvapiProjectionReceipt $amdNv $amdNvReceipt $amdNvId
    $amdNvRepeat = @(New-NvEntries (Join-Path $env:TEST_ROOT "amd") "Absent")
    $amdNvRepeatReceipt = Join-Path $env:TEST_ROOT "nv-absent.json"
    $amdNvRepeatId = "23333333333333333333333333333333"
    Publish-SystemProjectionEntries $amdNvRepeat $amdNvRepeatReceipt $amdNvRepeatId
    $nvAbsentActions = @((Get-Content $amdNvRepeatReceipt -Raw |
        ConvertFrom-Json).Entries.Action)
    if (($nvAbsentActions -join ",") -cne "UnchangedAbsent,UnchangedAbsent") {
        throw "NVAPI 重跑没有写入 UnchangedAbsent receipt"
    }
    Finalize-NvapiProjectionReceipt $amdNvRepeat $amdNvRepeatReceipt $amdNvRepeatId

    # 旧 NVAPI schema-2 Unchanged 收据必须继续可读，才能恢复升级前中断事务。
    $legacyNv = @(New-NvEntries (Join-Path $env:TEST_ROOT "legacy-nv") "Present" -Seed)
    $legacyNvPath = Join-Path $env:TEST_ROOT "24444444444444444444444444444444.json"
    Write-LegacyReceipt $legacyNv $legacyNvPath `
        "24444444444444444444444444444444" 2
    $null = @(Read-NvapiProjectionReceipt $legacyNv $legacyNvPath `
        "24444444444444444444444444444444")

    # AMD profile 遇到未知 NVAPI 时，全量预检必须在 receipt/stage/首目标 Move 前失败。
    $unknownNv = @(New-NvEntries (Join-Path $env:TEST_ROOT "unknown-nv") "Absent" -Seed)
    [IO.File]::WriteAllText($unknownNv[1].Target, "real-or-unknown-nvidia")
    $beforeNv = Get-TreeDigest $unknownNv[0].Directory
    $beforeNv += "`n" + (Get-TreeDigest $unknownNv[1].Directory)
    $unknownNvReceipt = Join-Path $env:TEST_ROOT "unknown-nv.json"
    try {
        Publish-SystemProjectionEntries $unknownNv $unknownNvReceipt `
            "25555555555555555555555555555555"
        throw "未知 NVAPI 被错误移除"
    } catch {
        if ($_.Exception.Message -ceq "未知 NVAPI 被错误移除") { throw }
    }
    $afterNv = Get-TreeDigest $unknownNv[0].Directory
    $afterNv += "`n" + (Get-TreeDigest $unknownNv[1].Directory)
    if ($beforeNv -cne $afterNv -or (Test-Path $unknownNvReceipt)) {
        throw "未知 NVAPI 预检失败前后产生了写入"
    }

    $null = . Import-Functions $env:ADL_INSTALL_PATH
    $null = . Import-Functions $env:ADL_TRANSACTION_PATH
    $adlX86Hash = (Get-FileHash $env:ADL_X86 -Algorithm SHA256).Hash.ToLowerInvariant()
    $adlX64Hash = (Get-FileHash $env:ADL_X64 -Algorithm SHA256).Hash.ToLowerInvariant()
    function New-AdlEntries {
        param([string]$Root, [string]$DesiredState, [switch]$Seed)
        $x86 = Join-Path $Root "x86"; $x64 = Join-Path $Root "x64"
        [IO.Directory]::CreateDirectory($x86) | Out-Null
        [IO.Directory]::CreateDirectory($x64) | Out-Null
        $entries = @(
            [pscustomobject]@{ FileName="atiadlxy.dll"; Source=$env:ADL_X86
                Directory=$x86; Target=(Join-Path $x86 "atiadlxy.dll")
                ExpectedHash=$adlX86Hash; HistoricalHashes=@(); Machine=0x014C
                Magic=0x010B; DesiredState=$DesiredState; State=""; ObservedHash=""
                Stage=""; Backup=""; Discard=""; CommitAction="" },
            [pscustomobject]@{ FileName="atiadlxx.dll"; Source=$env:ADL_X86
                Directory=$x86; Target=(Join-Path $x86 "atiadlxx.dll")
                ExpectedHash=$adlX86Hash; HistoricalHashes=@(); Machine=0x014C
                Magic=0x010B; DesiredState=$DesiredState; State=""; ObservedHash=""
                Stage=""; Backup=""; Discard=""; CommitAction="" },
            [pscustomobject]@{ FileName="atiadlxx.dll"; Source=$env:ADL_X64
                Directory=$x64; Target=(Join-Path $x64 "atiadlxx.dll")
                ExpectedHash=$adlX64Hash; HistoricalHashes=@(); Machine=0x8664
                Magic=0x020B; DesiredState=$DesiredState; State=""; ObservedHash=""
                Stage=""; Backup=""; Discard=""; CommitAction="" }
        )
        if ($Seed) {
            [IO.File]::Copy($env:ADL_X86, $entries[0].Target)
            [IO.File]::Copy($env:ADL_X86, $entries[1].Target)
            [IO.File]::Copy($env:ADL_X64, $entries[2].Target)
        }
        return $entries
    }

    $nvidiaAdl = @(New-AdlEntries (Join-Path $env:TEST_ROOT "nvidia") "Absent" -Seed)
    $nvidiaAdlReceipt = Join-Path $env:TEST_ROOT "adl-removed.json"
    $nvidiaAdlId = "31111111111111111111111111111111"
    Publish-AdlProjection $nvidiaAdl $nvidiaAdlReceipt $nvidiaAdlId
    $adlActions = @((Get-Content $nvidiaAdlReceipt -Raw | ConvertFrom-Json).Entries.Action)
    if (($adlActions -join ",") -cne "Removed,Removed,Removed") {
        throw ("ADL Absent receipt 不是 Removed：" + ($adlActions -join ","))
    }
    Finalize-AdlProjectionReceipt $nvidiaAdl $nvidiaAdlReceipt $nvidiaAdlId
    $nvidiaAdlRepeat = @(New-AdlEntries (Join-Path $env:TEST_ROOT "nvidia") "Absent")
    $nvidiaAdlRepeatReceipt = Join-Path $env:TEST_ROOT "adl-absent.json"
    $nvidiaAdlRepeatId = "32222222222222222222222222222222"
    Publish-AdlProjection $nvidiaAdlRepeat $nvidiaAdlRepeatReceipt $nvidiaAdlRepeatId
    $adlAbsentActions = @((Get-Content $nvidiaAdlRepeatReceipt -Raw |
        ConvertFrom-Json).Entries.Action)
    if (($adlAbsentActions -join ",") -cne `
        "UnchangedAbsent,UnchangedAbsent,UnchangedAbsent") {
        throw "ADL 重跑没有写入 UnchangedAbsent receipt"
    }
    Finalize-AdlProjectionReceipt $nvidiaAdlRepeat $nvidiaAdlRepeatReceipt `
        $nvidiaAdlRepeatId

    $amdAdl = @(New-AdlEntries (Join-Path $env:TEST_ROOT "amd") "Present")
    $amdAdlReceipt = Join-Path $env:TEST_ROOT "adl-present.json"
    $amdAdlId = "33333333333333333333333333333333"
    Publish-AdlProjection $amdAdl $amdAdlReceipt $amdAdlId
    Finalize-AdlProjectionReceipt $amdAdl $amdAdlReceipt $amdAdlId

    # 旧 ADL schema-1 收据同样必须可恢复。
    $legacyAdl = @(New-AdlEntries (Join-Path $env:TEST_ROOT "legacy-adl") "Present" -Seed)
    $legacyAdlPath = Join-Path $env:TEST_ROOT "34444444444444444444444444444444.json"
    Write-LegacyReceipt $legacyAdl $legacyAdlPath `
        "34444444444444444444444444444444" 1
    $null = @(Read-AdlProjectionReceipt $legacyAdl $legacyAdlPath `
        "34444444444444444444444444444444")

    # NVIDIA profile 遇到 AMD 基础镜像中的未知 ADL，必须完整保留三目标。
    $unknownAdl = @(New-AdlEntries (Join-Path $env:TEST_ROOT "unknown-adl") "Absent" -Seed)
    [IO.File]::WriteAllText($unknownAdl[2].Target, "real-or-unknown-amd")
    $beforeAdl = Get-TreeDigest (Join-Path $env:TEST_ROOT "unknown-adl")
    $unknownAdlReceipt = Join-Path $env:TEST_ROOT "unknown-adl.json"
    try {
        Publish-AdlProjection $unknownAdl $unknownAdlReceipt `
            "35555555555555555555555555555555"
        throw "未知 ADL 被错误移除"
    } catch {
        if ($_.Exception.Message -ceq "未知 ADL 被错误移除") { throw }
    }
    if ($beforeAdl -cne (Get-TreeDigest (Join-Path $env:TEST_ROOT "unknown-adl")) -or
        (Test-Path $unknownAdlReceipt)) {
        throw "未知 ADL 预检失败前后产生了写入"
    }

    # 两个切换 fixture 的最终系统表面必须严格互斥，同时保留所选厂商双架构。
    if (-not (Test-Path $nvidiaNv[0].Target) -or
        -not (Test-Path $nvidiaNv[1].Target) -or
        @($nvidiaAdl | Where-Object { Test-Path $_.Target }).Count -ne 0) {
        throw "NVIDIA-from-AMD 最终仍混有 ADL 或缺少双架构 NVAPI"
    }
    if (-not (Test-Path $amdAdl[0].Target) -or
        -not (Test-Path $amdAdl[1].Target) -or
        -not (Test-Path $amdAdl[2].Target) -or
        @($amdNv | Where-Object { Test-Path $_.Target }).Count -ne 0) {
        throw "AMD-from-NVIDIA 最终仍混有 NVAPI 或缺少双架构 ADL"
    }

    $applySource = [IO.File]::ReadAllText($env:APPLY_PATH)
    $vendorArgument = [char]39 + "-Vendor" + [char]39 + ", `$gpuApiVendor"
    if (-not $applySource.Contains(
        "`$gpuApiVendor = [string]`$stagedIdentity.SpoofVendor") -or
        -not $applySource.Contains($vendorArgument)) {
        throw "apply 没有把 staged identity 的 canonical vendor 传给 coordinator"
    }
' || fail "厂商互斥计划、切换、预检或事务回滚测试失败"

# 仍禁止按游戏/检测工具进程名分流或注入；修复只能由版本化 profile 厂商裁决。
if rg -ni \
    'Get-Process|ProcessName|MainWindowTitle|CreateRemoteThread|WriteProcessMemory|AppInit_DLLs|Image File Execution Options|Copy-Item.*GPU-Z|GPU-Z\.exe|HWiNFO(32|64)?\.exe|AIDA64\.exe' \
        "$COORDINATOR" "$NVAPI_INSTALL" "$ADL_INSTALL" "$APPLY" >&2; then
    fail "厂商互斥实现含按进程适配或注入路径"
fi

[[ "$(wc -l < "$COORDINATOR")" -le 500 ]] \
    || fail "统一厂商 API coordinator 超过 500 行"
[[ "$(wc -l < "$0")" -le 500 ]] \
    || fail "厂商互斥事务测试超过 500 行"

echo "OK: profile-selected vendor API publication is mutually exclusive and durable"
