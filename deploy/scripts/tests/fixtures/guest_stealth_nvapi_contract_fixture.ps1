$ErrorActionPreference = 'Stop'

# 这个 host-only fixture 只解析 PowerShell AST，不执行 guest 注册表或系统目录写入。
# 抽离后主测试保持在 500 行内，而 identity/GPU API 的跨组件顺序断言仍集中在一处。
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $env:APPLY_PATH, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw 'apply AST 不可用' }
$applyText = $ast.Extent.Text
foreach ($supportMarker in @("Join-Path `$PSScriptRoot 'gpu-spoof-apply-support.ps1'",
        '$transactionHelperSource, $registryCoreSource, $applySupportSource',
        '. $applySupportSource')) {
    if (-not $applyText.Contains($supportMarker)) {
        throw ('apply 缺少 support helper fail-closed 接线：' + $supportMarker)
    }
}
$tokens = $null
$errors = $null
$supportAst = [Management.Automation.Language.Parser]::ParseFile(
    $env:APPLY_SUPPORT_PATH, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw 'apply support AST 不可用' }
foreach ($functionName in @('Get-GpuSpoofAutoDetectProfile',
        'Enable-GpuSpoofDisplayDevices', 'Install-GpuSpoofScheduledTasks',
        'Invoke-GpuSpoofPnpRefresh', 'Invoke-GpuSpoofDisplayModeVerification')) {
    $definitions = @($supportAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq $functionName
        }, $true))
    if ($definitions.Count -ne 1) { throw ('apply support 函数不唯一：' + $functionName) }
}
$nvapiParameter = @($ast.ParamBlock.Parameters | Where-Object {
        $_.Name.VariablePath.UserPath -eq 'NvapiPayloadDir'
    })
if ($nvapiParameter.Count -ne 1 -or $null -eq $nvapiParameter[0].DefaultValue) {
    throw 'NvapiPayloadDir 必须是保留 standalone 兼容的可选参数'
}
$guard = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.TryStatementAst] -and
        $null -ne $node.Finally -and
        $node.Finally.Extent.Text.Contains('-RollbackIdentity')
    }, $true)
if ($null -eq $guard) { throw '缺少 identity durable finally' }
$body = $guard.Body.Extent.Text
$finally = $guard.Finally.Extent.Text
foreach ($marker in @(
        '& $powershellExe @gpuApiInstallArgs',
        '-CommitIdentity $identityTransactionId',
        '-CompleteIdentity $identityTransactionId',
        '$completeInspection = & $identityHelperSource -InspectIdentity',
        '$completeResolution = & $identityHelperSource -RollbackIdentity',
        '$resolvedState -ceq',
        '& $powershellExe @gpuApiFinalizeArgs')) {
    if (-not $body.Contains($marker)) {
        throw ('GPU API/identity 原子窗口缺少：' + $marker)
    }
}
$installOffset = $body.IndexOf('& $powershellExe @gpuApiInstallArgs')
$commitOffset = $body.IndexOf('-CommitIdentity $identityTransactionId')
$completeOffset = $body.IndexOf('-CompleteIdentity $identityTransactionId')
$finalizeOffset = $body.IndexOf('& $powershellExe @gpuApiFinalizeArgs')
if (-not ($installOffset -lt $commitOffset -and
        $commitOffset -lt $completeOffset -and
        $completeOffset -lt $finalizeOffset)) {
    throw 'Prepare → Commit → Complete → Finalize 顺序错误'
}
$readerRollbackOffset = $finally.IndexOf('& $powershellExe @gpuApiRecoveryArgs')
$identityRollbackOffset = $finally.IndexOf('-RollbackIdentity $identityTransactionId')
if ($readerRollbackOffset -lt 0 -or $identityRollbackOffset -lt 0 -or
    $identityRollbackOffset -ge $readerRollbackOffset) {
    throw '失败路径没有先恢复旧 pointer、再恢复历史 reader'
}
if (-not $finally.Contains('-not $identityCompletionUnresolved')) {
    throw 'Complete 状态无法裁决时仍会破坏两份 durable journal'
}

$tokens = $null
$errors = $null
$identityAst = [Management.Automation.Language.Parser]::ParseFile(
    $env:IDENTITY_HELPER_PATH, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw 'identity helper AST 不可用' }
$needle = 'ParameterSetName -eq ' + [char]39 + 'Inspect' + [char]39
$inspect = $identityAst.Find({
        param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Extent.Text.Contains($needle)
    }, $true)
if ($null -eq $inspect) { throw '缺少 Complete 只读 Inspect 参数集' }
$inspectText = $inspect.Extent.Text
if (-not $inspectText.Contains('Read-TransactionReceipt')) {
    throw 'Inspect 未读取 durable receipt'
}
foreach ($writer in @('.SetValue(', '.DeleteValue(', 'Invoke-TransactionRollback',
        'Set-CurrentIdentityPointer', 'Clear-PendingIdentity')) {
    if ($inspectText.Contains($writer)) {
        throw ('Inspect 不是只读操作：' + $writer)
    }
}
