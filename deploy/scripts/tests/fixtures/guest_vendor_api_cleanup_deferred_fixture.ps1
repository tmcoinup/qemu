$ErrorActionPreference = 'Stop'

function Import-CoordinatorFunctions {
    param([Parameter(Mandatory = $true)][string]$Path)

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw 'GPU API coordinator AST 不可用' }
    foreach ($definition in @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst]
            }, $true))) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    return $ast
}

function New-CleanupStep {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path
    )
    return [pscustomobject]@{
        Label=$Name; Script=$Path; Action='Finalize'; DesiredState='Present'
        TransactionId=''; WithPayload=$false; Deferred=$false
    }
}

function Invoke-StepsExpectingError {
    param([Parameter(Mandatory = $true)][object[]]$Steps)

    try {
        Invoke-GpuApiSteps -Steps $Steps -FailurePrefix 'fixture settlement failed'
    } catch {
        return $_
    }
    throw 'GPU API cleanup fixture 没有返回预期错误'
}

$coordinatorAst = . Import-CoordinatorFunctions -Path $env:COORDINATOR_PATH
$GpuApiCleanupDeferredExitCode = 12
$powershellExe = (Get-Process -Id $PID).Path
$PayloadDir = $env:TEST_ROOT
$TransactionId = '71111111111111111111111111111111'
$stepLog = Join-Path $env:TEST_ROOT 'gpu-api-cleanup-steps.log'
$env:VMATE_GPU_API_STEP_LOG = $stepLog
$childSource = @'
[CmdletBinding()]
param(
    [string]$Action,
    [string]$DesiredState,
    [string]$PayloadDir,
    [string]$TransactionId,
    [switch]$DeferFinalize
)
$name = [IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
[IO.File]::AppendAllText($env:VMATE_GPU_API_STEP_LOG, $name + ',')
if ($name -ceq 'deferred') { exit 12 }
if ($name -ceq 'hard') { exit 7 }
exit 0
'@
$children = @{}
foreach ($name in 'deferred', 'success', 'hard') {
    $path = Join-Path $env:TEST_ROOT ($name + '.ps1')
    [IO.File]::WriteAllText($path, $childSource, (New-Object Text.UTF8Encoding($false)))
    $children[$name] = $path
}

[IO.File]::Delete($stepLog)
$deferredError = Invoke-StepsExpectingError @(
    (New-CleanupStep 'deferred' $children.deferred),
    (New-CleanupStep 'success' $children.success)
)
if (-not (Test-GpuApiCleanupDeferredException $deferredError.Exception)) {
    throw 'child exit 12 没有聚合为 CleanupDeferred sentinel'
}
if ([IO.File]::ReadAllText($stepLog) -cne 'deferred,success,') {
    throw 'CleanupDeferred 后没有继续执行另一组件'
}

[IO.File]::Delete($stepLog)
$hardError = Invoke-StepsExpectingError @(
    (New-CleanupStep 'deferred' $children.deferred),
    (New-CleanupStep 'hard' $children.hard)
)
if (Test-GpuApiCleanupDeferredException $hardError.Exception) {
    throw '真实组件错误被 CleanupDeferred 覆盖'
}
if ($hardError.Exception.Message -notmatch 'hard Finalize 失败，退出码=7' -or
    [IO.File]::ReadAllText($stepLog) -cne 'deferred,hard,') {
    throw '真实错误优先或另一组件继续执行契约失效'
}

$rollbackError = $null
try {
    Invoke-GpuApiInstaller -Label 'deferred' -Script $children.deferred `
        -ChildAction 'Rollback' -DesiredState 'Present'
} catch {
    $rollbackError = $_
}
if ($null -eq $rollbackError -or
    (Test-GpuApiCleanupDeferredException $rollbackError.Exception) -or
    $rollbackError.Exception.Message -notmatch '退出码=12') {
    throw '非 Finalize/Recover 的 exit 12 被错误降级为 cleanup deferred'
}

$resolveDefinition = $coordinatorAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Resolve-GpuApiReservation'
    }, $true)
$resolveText = $resolveDefinition.Extent.Text
if ($resolveText.IndexOf('Invoke-GpuApiSteps') -lt 0 -or
    $resolveText.IndexOf('Invoke-GpuApiSteps') -ge
        $resolveText.IndexOf('Remove-GpuApiReservation')) {
    throw 'stale reservation 在 cleanup settlement 前被释放'
}
$directBranches = @($coordinatorAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
                $node.Extent.Text.Contains('Invoke-GpuApiSteps $steps') -and
                $node.Extent.Text.Contains(
                    'Remove-GpuApiReservation -Path $reservationPath')
        }, $true))
$directBranch = $directBranches | Sort-Object { $_.Extent.Text.Length } |
    Select-Object -First 1
if ($null -eq $directBranch -or
    $directBranch.Extent.Text.IndexOf('Invoke-GpuApiSteps $steps') -ge
        $directBranch.Extent.Text.IndexOf(
            'Remove-GpuApiReservation -Path $reservationPath')) {
    throw '显式 Finalize 在 cleanup settlement 前释放了 reservation'
}
$outerTry = @($coordinatorAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.TryStatementAst] -and
                $node.Extent.Text.Contains(
                    'Test-GpuApiCleanupDeferredException $_.Exception') -and
                $node.Extent.Text.Contains('exit $GpuApiCleanupDeferredExitCode') -and
                $node.Finally.Extent.Text.Contains('$coordinatorLock.Dispose()')
        }, $true))
if ($outerTry.Count -ne 1) {
    throw 'coordinator 外层没有唯一 CleanupDeferred exit 12/finally 契约'
}
