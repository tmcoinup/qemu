#!/usr/bin/env bash
# 故障注入：验证非目标厂商 Removed receipt 在 Finalize/Rollback 中断点的幂等与保留边界。
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
NVAPI_DIR="$REPO_ROOT/deploy/nvapi-shim"
ADL_DIR="$REPO_ROOT/deploy/adl-shim"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

rg -F '@(1, 2, 3, 4, 5) -contains $schema' "$IDENTITY_BINDING" >/dev/null \
    || fail "GPU API durable reader 未兼容 transaction schema-1..5"
rg -F '$identity.TransactionSchema -ne 5' "$IDENTITY_BINDING" >/dev/null \
    || fail "GPU API Install 未锁定 transaction schema-5"

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

COORDINATOR_PATH="$COORDINATOR" IDENTITY_BINDING_PATH="$IDENTITY_BINDING" \
NVAPI_INSTALL_PATH="$NVAPI_INSTALL" \
NVAPI_VALIDATION_PATH="$NVAPI_VALIDATION" \
NVAPI_TRANSACTION_PATH="$NVAPI_TRANSACTION" \
ADL_INSTALL_PATH="$ADL_INSTALL" ADL_TRANSACTION_PATH="$ADL_TRANSACTION" \
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
    }

    # coordinator recovery 必须同时服从 durable identity State、Vendor 和精确
    # previous pointer；Prepared/Committed 不得提前收口，旧事务不得覆盖后续事务。
    . Import-Functions $env:COORDINATOR_PATH
    . Import-Functions $env:IDENTITY_BINDING_PATH
    $nvapiInstaller = "nvapi-fixture"; $adlInstaller = "adl-fixture"
    $reservationDir = Join-Path $env:TEST_ROOT "reservations"
    [IO.Directory]::CreateDirectory($reservationDir) | Out-Null
    $reservationPath = Join-Path $reservationDir "active"
    $firstId = "71111111111111111111111111111111"
    $otherId = "72222222222222222222222222222222"
    New-GpuApiReservation $reservationPath $firstId "NVIDIA"
    $lease = Read-GpuApiReservation $reservationPath
    if ($lease.TransactionId -cne $firstId -or $lease.Vendor -cne "NVIDIA" -or
        $lease.IsLegacy) { throw "新版 reservation 没有持久化 GUID/vendor" }
    try {
        $null = Remove-GpuApiReservation $reservationPath $otherId
        throw "错误 owner 释放了 reservation"
    } catch {
        if ($_.Exception.Message -ceq "错误 owner 释放了 reservation") { throw }
    }
    if (-not (Test-Path $reservationPath)) { throw "owner 冲突破坏了 reservation" }
    $null = Remove-GpuApiReservation $reservationPath $firstId
    [IO.File]::WriteAllText($reservationPath, $firstId + "`n")
    $legacy = Read-GpuApiReservation $reservationPath
    if (-not $legacy.IsLegacy -or $legacy.Vendor -cne "LegacyBothPresent") {
        throw "旧 GUID reservation 没有迁移为 LegacyBothPresent"
    }
    $null = Remove-GpuApiReservation $reservationPath $firstId

    function New-TestIdentityPointer {
        param([string]$Value)
        return [pscustomobject]@{
            Present=(-not [string]::IsNullOrWhiteSpace($Value)); Value=$Value
        }
    }
    $script:durableState = ""; $script:durablePointer = ""
    $script:durablePrevious = ""; $script:durablePending = ""
    $script:durableVendor = "NVIDIA"; $script:durableSchema = 5
    $script:identityLookupId = ""; $script:settlementSteps = @()
    function Get-GpuApiIdentityDurableState {
        param([string]$TransactionId)
        $script:identityLookupId = $TransactionId
        return [pscustomobject]@{
            State=$script:durableState; Vendor=$script:durableVendor
            TransactionSchema=$script:durableSchema
            CurrentIdentity=(New-TestIdentityPointer $script:durablePointer)
            PreviousIdentity=(New-TestIdentityPointer $script:durablePrevious)
            PendingIdentity=(New-TestIdentityPointer $script:durablePending)
        }
    }
    function Invoke-GpuApiSteps {
        param([object[]]$Steps, [string]$FailurePrefix)
        $script:settlementSteps = @($Steps)
    }
    # Install 的 CLI Vendor 只作 assertion；真正值来自仍处 Prepared/Pending 的
    # durable staged identity。相反 Vendor 和复用 Completed GUID 都必须在 reservation 前拒绝。
    $installId = "72111111111111111111111111111111"
    $oldId = "72199999999999999999999999999999"
    $script:durableState = "Prepared"; $script:durablePointer = $oldId
    $script:durablePrevious = $oldId; $script:durablePending = $installId
    $script:durableVendor = "NVIDIA"
    if ((Assert-GpuApiInstallIdentityBinding $installId "NVIDIA") -cne "NVIDIA") {
        throw "Prepared staged vendor 没有成为 Install 唯一厂商"
    }
    $script:durableSchema = 4
    $legacyInstallRejected = $false
    try { $null = Assert-GpuApiInstallIdentityBinding $installId "NVIDIA" }
    catch { $legacyInstallRejected = $true }
    if (-not $legacyInstallRejected) { throw "schema-4 Prepared 被新 Install 接受" }
    $script:durableSchema = 5
    foreach ($attempt in @(
        [pscustomobject]@{ State="Prepared"; Vendor="AMD"; Current=$oldId; Pending=$installId },
        [pscustomobject]@{ State="Completed"; Vendor="AMD"; Current=$installId; Pending="" }
    )) {
        $script:durableState = $attempt.State; $script:durablePointer = $attempt.Current
        $script:durablePending = $attempt.Pending
        try {
            $null = Assert-GpuApiInstallIdentityBinding $installId $attempt.Vendor
            throw "相反 Vendor 或 Completed GUID 被 Install 接受"
        } catch {
            if ($_.Exception.Message -ceq "相反 Vendor 或 Completed GUID 被 Install 接受") {
                throw
            }
        }
    }

    $rejected = @(
        [pscustomobject]@{ Id="73111111111111111111111111111111"; State="Prepared"
            Current="73000000000000000000000000000000"; Previous="73000000000000000000000000000000"; DurableVendor="NVIDIA" },
        [pscustomobject]@{ Id="73222222222222222222222222222222"; State="Committed"
            Current="73222222222222222222222222222222"; Previous="73000000000000000000000000000000"; DurableVendor="NVIDIA" },
        [pscustomobject]@{ Id="73333333333333333333333333333333"; State="Completed"
            Current="73000000000000000000000000000000"; Previous="73000000000000000000000000000000"; DurableVendor="NVIDIA" },
        [pscustomobject]@{ Id="73444444444444444444444444444444"; State="RolledBack"
            Current="73999999999999999999999999999999"; Previous="73000000000000000000000000000000"; DurableVendor="NVIDIA" },
        [pscustomobject]@{ Id="73555555555555555555555555555555"; State="Completed"
            Current="73555555555555555555555555555555"; Previous="73000000000000000000000000000000"; DurableVendor="AMD" }
    )
    foreach ($case in $rejected) {
        New-GpuApiReservation $reservationPath $case.Id "NVIDIA"
        $script:durableState = $case.State
        $script:durablePointer = $case.Current; $script:durablePrevious = $case.Previous
        $script:durableVendor = $case.DurableVendor; $script:durablePending = ""
        $script:identityLookupId = ""; $script:settlementSteps = @()
        try {
            $null = Resolve-GpuApiReservation $reservationPath
            throw "未完成/矛盾 identity 被错误裁决"
        } catch {
            if ($_.Exception.Message -ceq "未完成/矛盾 identity 被错误裁决") { throw }
        }
        if ($script:identityLookupId -cne $case.Id -or
            $script:settlementSteps.Count -ne 0 -or
            -not (Test-Path $reservationPath)) {
            throw ("拒绝裁决仍调用 child 或删除 reservation：" + $case.State)
        }
        $null = Remove-GpuApiReservation $reservationPath $case.Id
    }
    $allowed = @(
        [pscustomobject]@{ Id="74111111111111111111111111111111"; Vendor="NVIDIA"
            State="Completed"; Current="74111111111111111111111111111111"
            Previous="74000000000000000000000000000000"; Action="Finalize"
            Expected="ADL:Absent,NVAPI:Present" },
        [pscustomobject]@{ Id="74222222222222222222222222222222"; Vendor="AMD"
            State="RolledBack"; Current="74000000000000000000000000000000"
            Previous="74000000000000000000000000000000"; Action="Rollback"
            Expected="ADL:Present,NVAPI:Absent" }
    )
    foreach ($case in $allowed) {
        New-GpuApiReservation $reservationPath $case.Id $case.Vendor
        $script:durableState = $case.State
        $script:durablePointer = $case.Current; $script:durablePrevious = $case.Previous
        $script:durableVendor = $case.Vendor; $script:durablePending = ""
        $script:settlementSteps = @()
        $resolution = Resolve-GpuApiReservation $reservationPath
        $actual = @($script:settlementSteps | ForEach-Object {
            $_.Label + ":" + $_.DesiredState
        }) -join ","
        $bad = @($script:settlementSteps | Where-Object {
            $_.Action -cne $case.Action -or $_.TransactionId -cne $case.Id
        })
        if ($resolution.Action -cne $case.Action -or $actual -cne $case.Expected -or
            $bad.Count -or (Test-Path $reservationPath)) {
            throw ("durable identity settlement 错误：" + $case.State + "/" + $actual)
        }
    }

    # 旧 reservation 只有“两家 Present”语义，显式 Vendor 会错误缩小恢复计划；
    # missing-receipt Rollback 则必须直接 no-op，不能扫描或触碰后来出现的未知 DLL。
    $coordinatorSource = [IO.File]::ReadAllText($env:COORDINATOR_PATH)
    $coordinatorTokens = $null; $coordinatorErrors = $null
    $coordinatorAst = [Management.Automation.Language.Parser]::ParseInput(
        $coordinatorSource, [ref]$coordinatorTokens, [ref]$coordinatorErrors)
    if ($coordinatorErrors.Count -gt 0) { throw "coordinator AST 不可用" }

    # 显式 Finalize/Rollback 不能绕过 identity durable state：先用
    # TransactionId 取得唯一允许的收口动作，再与请求的 Action 做严格比较。
    $directBranches = @($coordinatorAst.FindAll({
        param($node)
        if ($node -isnot [Management.Automation.Language.IfStatementAst]) {
            return $false
        }
        $text = $node.Extent.Text
        return $text.Contains("Assert-GpuApiReservationOwner") -and
            $text.Contains("Get-GpuApiIdentitySettlementAction `$TransactionId") -and
            $text.Contains("`$requiredAction -cne `$Action")
    }, $true))
    $directBranch = $directBranches | Sort-Object { $_.Extent.Text.Length } |
        Select-Object -First 1
    if ($null -eq $directBranch) {
        throw "显式 Finalize/Rollback 缺少 durable settlement 门禁"
    }
    $settlementCalls = @($directBranch.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -ceq "Get-GpuApiIdentitySettlementAction"
    }, $true))
    $actionComparisons = @($directBranch.FindAll({
        param($node)
        $node -is [Management.Automation.Language.BinaryExpressionAst] -and
            $node.Operator.ToString() -ceq "Cne" -and
            $node.Left.Extent.Text -ceq "`$requiredAction" -and
            $node.Right.Extent.Text -ceq "`$Action"
    }, $true))
    if ($settlementCalls.Count -ne 1 -or $actionComparisons.Count -ne 1) {
        throw "显式收口未严格比较 requiredAction/Action"
    }
    if (-not $directBranch.Extent.Text.Contains("([string]`$lease.Vendor)")) {
        throw "显式收口没有用 reservation Vendor 复核 durable identity"
    }

    # Install 只能作为 identity-bound 延迟收口事务；两个参数任一
    # 缺失都必须在创建 reservation 之前拒绝。
    $installGuards = @($coordinatorAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Extent.Text.Contains(
                "GPU API Install 只允许作为 identity-bound deferred 事务运行") -and
            $node.Extent.Text.Contains(
                "deferred GPU API Install 必须复用 identity TransactionId")
    }, $true))
    $installGuard = $installGuards | Sort-Object { $_.Extent.Text.Length } |
        Select-Object -First 1
    $installActionChecks = if ($null -eq $installGuard) { @() } else {
        @($installGuard.Clauses[0].Item1.FindAll({
            param($node)
            $node -is [Management.Automation.Language.BinaryExpressionAst] -and
                $node.Left.Extent.Text -ceq "`$Action" -and
                $node.Right -is [Management.Automation.Language.ConstantExpressionAst] -and
                [string]$node.Right.Value -ceq "Install"
        }, $true))
    }
    if ($null -eq $installGuard -or $installActionChecks.Count -ne 1 -or
        -not $installGuard.Extent.Text.Contains("if (-not `$DeferFinalize)") -or
        -not $installGuard.Extent.Text.Contains("IsNullOrWhiteSpace(`$TransactionId)") -or
        -not $installGuard.Extent.Text.Contains("Assert-GpuApiInstallIdentityBinding")) {
        throw "Install 缺少 DeferFinalize/TransactionId/staged identity 绑定门禁"
    }
    if (-not $coordinatorSource.Contains(
        "旧版双 Present reservation 只允许使用 -Vendor Auto 收口")) {
        throw "coordinator 缺少 legacy 显式 Vendor 拒绝门禁"
    }
    foreach ($spec in @(
        [pscustomobject]@{ Path=$env:NVAPI_INSTALL_PATH; Marker="NVAPI rollback 收据已不存在" },
        [pscustomobject]@{ Path=$env:ADL_INSTALL_PATH; Marker="ADL rollback 收据已不存在" })) {
        $tokens=$null; $errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile(
            $spec.Path,[ref]$tokens,[ref]$errors)
        $guards=@($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
                $node.Extent.Text.Contains("Test-Path -LiteralPath `$receiptPath") -and
                $node.Extent.Text.Contains($spec.Marker)
        },$true))
        $guard=$guards | Sort-Object { $_.Extent.Text.Length } | Select-Object -First 1
        if($null -eq $guard -or $null -eq $guard.ElseClause -or
            $guard.ElseClause.Extent.Text -match
                "Get-.*Snapshot|Move-|Remove-Item|Assert-.*Binary") {
            throw ("missing-receipt Rollback 不是未知目标 no-op：" + $spec.Path)
        }
    }

    function Assert-RemovedLifecycle {
        param(
            [string]$Label,
            [scriptblock]$NewEntries,
            [scriptblock]$Publish,
            [scriptblock]$Finalize,
            [scriptblock]$Rollback,
            [string]$IdPrefix
        )

        # 模拟 Finalize 已删除全部 backup、但进程在删除 receipt 前被终止。
        $finalRoot = Join-Path $env:TEST_ROOT ($Label + "-finalize")
        $finalEntries = @(& $NewEntries $finalRoot)
        $finalId = $IdPrefix + "1111111111111111111111111111111"
        $finalReceipt = Join-Path $finalRoot ($finalId + ".json")
        & $Publish $finalEntries $finalReceipt $finalId
        foreach ($entry in $finalEntries) {
            if (-not (Test-Path -LiteralPath $entry.Backup) -or
                (Test-Path -LiteralPath $entry.Target)) {
                throw ($Label + " Removed Prepare 状态错误")
            }
            Remove-Item -LiteralPath $entry.Backup -Force
        }
        & $Finalize $finalEntries $finalReceipt $finalId
        if ((Test-Path -LiteralPath $finalReceipt) -or
            @($finalEntries | Where-Object { Test-Path -LiteralPath $_.Target }).Count) {
            throw ($Label + " backup 已删后的幂等 Finalize 未只清理 receipt")
        }

        # 若同名目标在收口前被未知字节重建，事务不再拥有该路径；Finalize 与
        # Rollback 都必须失败，并保留每个未知 target、托管 backup 和 receipt。
        $unknownRoot = Join-Path $env:TEST_ROOT ($Label + "-unknown")
        $unknownEntries = @(& $NewEntries $unknownRoot)
        $unknownId = $IdPrefix + "2222222222222222222222222222222"
        $unknownReceipt = Join-Path $unknownRoot ($unknownId + ".json")
        & $Publish $unknownEntries $unknownReceipt $unknownId
        $expected = @{}
        foreach ($entry in $unknownEntries) {
            [IO.File]::WriteAllText($entry.Target,
                ("unknown-" + $Label + "-" + $entry.FileName + "-" + $entry.Machine))
            $expected[$entry.Target] = (Get-FileHash $entry.Target -Algorithm SHA256).Hash
            $expected[$entry.Backup] = (Get-FileHash $entry.Backup -Algorithm SHA256).Hash
        }
        foreach ($operation in @($Finalize, $Rollback)) {
            try {
                & $operation $unknownEntries $unknownReceipt $unknownId
                throw ($Label + " 未知 target 被错误收口")
            } catch {
                if ($_.Exception.Message -ceq ($Label + " 未知 target 被错误收口")) {
                    throw
                }
            }
            if (-not (Test-Path -LiteralPath $unknownReceipt)) {
                throw ($Label + " 未知 target 失败后丢失 receipt")
            }
            foreach ($path in $expected.Keys) {
                if (-not (Test-Path -LiteralPath $path) -or
                    (Get-FileHash $path -Algorithm SHA256).Hash -cne $expected[$path]) {
                    throw ($Label + " 未知 target 失败后修改了 target/backup：" + $path)
                }
            }
        }
    }

    # NVAPI 与 ADL installer 含少量同名通用函数，因此逐组件导入、立即完成测试。
    . Import-Functions $env:NVAPI_VALIDATION_PATH
    . Import-Functions $env:NVAPI_INSTALL_PATH
    . Import-Functions $env:NVAPI_TRANSACTION_PATH
    $nvX86Hash = (Get-FileHash $env:NVAPI_X86 -Algorithm SHA256).Hash.ToLowerInvariant()
    $nvX64Hash = (Get-FileHash $env:NVAPI_X64 -Algorithm SHA256).Hash.ToLowerInvariant()
    function New-NvRemovedEntries {
        param([string]$Root)
        $x86 = Join-Path $Root "x86"; $x64 = Join-Path $Root "x64"
        [IO.Directory]::CreateDirectory($x86) | Out-Null
        [IO.Directory]::CreateDirectory($x64) | Out-Null
        $entries = @(
            [pscustomobject]@{ FileName="nvapi.dll"; Source=$env:NVAPI_X86
                Directory=$x86; Target=(Join-Path $x86 "nvapi.dll")
                ExpectedHash=$nvX86Hash; HistoricalHashes=@(); Machine=0x014C
                Magic=0x010B; DesiredState="Absent"; State=""; ObservedHash=""
                Stage=""; Backup=""; Discard=""; CommitAction="" },
            [pscustomobject]@{ FileName="nvapi64.dll"; Source=$env:NVAPI_X64
                Directory=$x64; Target=(Join-Path $x64 "nvapi64.dll")
                ExpectedHash=$nvX64Hash; HistoricalHashes=@(); Machine=0x8664
                Magic=0x020B; DesiredState="Absent"; State=""; ObservedHash=""
                Stage=""; Backup=""; Discard=""; CommitAction="" }
        )
        [IO.File]::Copy($env:NVAPI_X86, $entries[0].Target)
        [IO.File]::Copy($env:NVAPI_X64, $entries[1].Target)
        return $entries
    }
    Assert-RemovedLifecycle "NVAPI" ${function:New-NvRemovedEntries} `
        { param($e,$p,$i) Publish-SystemProjectionEntries $e $p $i } `
        { param($e,$p,$i) Finalize-NvapiProjectionReceipt $e $p $i } `
        { param($e,$p,$i) Rollback-NvapiProjectionReceipt $e $p $i } "5"

    . Import-Functions $env:ADL_INSTALL_PATH
    . Import-Functions $env:ADL_TRANSACTION_PATH
    $adlX86Hash = (Get-FileHash $env:ADL_X86 -Algorithm SHA256).Hash.ToLowerInvariant()
    $adlX64Hash = (Get-FileHash $env:ADL_X64 -Algorithm SHA256).Hash.ToLowerInvariant()
    function New-AdlRemovedEntries {
        param([string]$Root)
        $x86 = Join-Path $Root "x86"; $x64 = Join-Path $Root "x64"
        [IO.Directory]::CreateDirectory($x86) | Out-Null
        [IO.Directory]::CreateDirectory($x64) | Out-Null
        $entries = @(
            [pscustomobject]@{ FileName="atiadlxy.dll"; Source=$env:ADL_X86
                Directory=$x86; Target=(Join-Path $x86 "atiadlxy.dll")
                ExpectedHash=$adlX86Hash; HistoricalHashes=@(); Machine=0x014C
                Magic=0x010B; DesiredState="Absent"; State=""; ObservedHash=""
                Stage=""; Backup=""; Discard=""; CommitAction="" },
            [pscustomobject]@{ FileName="atiadlxx.dll"; Source=$env:ADL_X86
                Directory=$x86; Target=(Join-Path $x86 "atiadlxx.dll")
                ExpectedHash=$adlX86Hash; HistoricalHashes=@(); Machine=0x014C
                Magic=0x010B; DesiredState="Absent"; State=""; ObservedHash=""
                Stage=""; Backup=""; Discard=""; CommitAction="" },
            [pscustomobject]@{ FileName="atiadlxx.dll"; Source=$env:ADL_X64
                Directory=$x64; Target=(Join-Path $x64 "atiadlxx.dll")
                ExpectedHash=$adlX64Hash; HistoricalHashes=@(); Machine=0x8664
                Magic=0x020B; DesiredState="Absent"; State=""; ObservedHash=""
                Stage=""; Backup=""; Discard=""; CommitAction="" }
        )
        [IO.File]::Copy($env:ADL_X86, $entries[0].Target)
        [IO.File]::Copy($env:ADL_X86, $entries[1].Target)
        [IO.File]::Copy($env:ADL_X64, $entries[2].Target)
        return $entries
    }
    Assert-RemovedLifecycle "ADL" ${function:New-AdlRemovedEntries} `
        { param($e,$p,$i) Publish-AdlProjection $e $p $i } `
        { param($e,$p,$i) Finalize-AdlProjectionReceipt $e $p $i } `
        { param($e,$p,$i) Rollback-AdlProjectionReceipt $e $p $i } "6"
' || fail "Removed receipt 幂等 Finalize 或未知目标保留测试失败"

[[ "$(wc -l < "$0")" -le 500 ]] || fail "Removed recovery 测试超过 500 行"

echo "OK: Removed receipts survive finalize interruption and unknown target races"
