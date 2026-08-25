$ErrorActionPreference = 'Stop'
$namespace = 'root/virtualization/v2'
$rows = @()

foreach ($vmName in @('pc01', 'pc02', 'P11-Lab')) {
    $computerSystem = Get-CimInstance -Namespace $namespace `
        -ClassName Msvm_ComputerSystem |
        Where-Object ElementName -eq $vmName |
        Select-Object -First 1
    if (-not $computerSystem) { continue }

    $keyboard = @(Get-CimAssociatedInstance -InputObject $computerSystem `
        -Association Msvm_SystemDevice -ResultClassName Msvm_Keyboard)
    $mouse = @(Get-CimAssociatedInstance -InputObject $computerSystem `
        -Association Msvm_SystemDevice -ResultClassName Msvm_SyntheticMouse)
    $video = @(Get-CimAssociatedInstance -InputObject $computerSystem `
        -Association Msvm_SystemDevice -ResultClassName Msvm_SyntheticDisplayController)
    $videoHeads = @(Get-CimInstance -Namespace $namespace `
        -ClassName Msvm_VideoHead | Where-Object {
            [string]$_.SystemName -ieq [string]$computerSystem.Name
        })

    $rows += [pscustomobject][ordered]@{
        VMName = $vmName
        VMId = [string]$computerSystem.Name
        EnabledState = [int]$computerSystem.EnabledState
        Keyboard = @($keyboard | Select-Object Name, ElementName,
            EnabledState, HealthState, OperationalStatus,
            StatusDescriptions, Caption, Description)
        Mouse = @($mouse | Select-Object Name, ElementName,
            EnabledState, HealthState, OperationalStatus,
            StatusDescriptions, HorizontalPosition, VerticalPosition,
            Caption, Description)
        Video = @($video | Select-Object Name, ElementName,
            EnabledState, HealthState, OperationalStatus,
            HorizontalResolution, VerticalResolution,
            CurrentRefreshRate, Caption, Description)
        VideoHeads = @($videoHeads | Select-Object Name, ElementName,
            EnabledState, HealthState, OperationalStatus,
            CurrentHorizontalResolution, CurrentVerticalResolution,
            CurrentRefreshRate, CurrentBitsPerPixel,
            MaxHorizontalResolution, MaxVerticalResolution,
            MaxRefreshRate, MinRefreshRate, Caption, Description)
    }
}

$classes = foreach ($className in @('Msvm_Keyboard',
        'Msvm_SyntheticMouse', 'Msvm_SyntheticDisplayController')) {
    $class = Get-CimClass -Namespace $namespace -ClassName $className
    [pscustomobject][ordered]@{
        ClassName = $className
        Methods = @($class.CimClassMethods | ForEach-Object {
            [pscustomobject][ordered]@{
                Name = $_.Name
                Parameters = @($_.Parameters | ForEach-Object {
                    [pscustomobject][ordered]@{
                        Name = $_.Name
                        CimType = [string]$_.CimType
                        Flags = [string]$_.Flags
                    }
                })
            }
        })
    }
}

[pscustomobject][ordered]@{
    CapturedAt = (Get-Date).ToString('o')
    VMs = $rows
    Classes = $classes
} | ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath 'C:\VMateLab\hyperv-input-api.json' -Encoding UTF8
