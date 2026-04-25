# patch-grid-strings.ps1 — 把 guest 注册表里的 "GRID RTX6000-*" 替换为指定的消费级型号名
# 用法:
#   .\patch-grid-strings.ps1 -TargetName "GeForce GTX 1050"
#   .\patch-grid-strings.ps1 -TargetName "GeForce GT 1030" -Vendor "ZOTAC"
#   # 想改成 AIB 全称："ZOTAC GAMING GeForce GTX 1050 OC" 这种直接写进 TargetName
param(
    [string]$TargetName = 'GeForce GTX 1050',
    [string]$Vendor = '',
    # Windows 看到的 PCI Device ID 会随 GPU_SPOOF 改变：
    #   GPU_SPOOF=0/subsys → DEV_1E30 (GRID/RTX6000)
    #   GPU_SPOOF=1 + gtx1050_2gb → DEV_1C81
    #   GPU_SPOOF=1 + gt1030_2gb  → DEV_1D01
    [string[]]$DeviceIdMatch = @(
        'VEN_10DE&DEV_1E30',
        'VEN_10DE&DEV_1C81',
        'VEN_10DE&DEV_1D01'
    )
)

$ErrorActionPreference = 'Stop'
$out = "C:\Windows\Temp\patch-grid-strings.out"
"" | Out-File $out
function W($s){ $s | Out-File -Append $out; Write-Host $s }

# Compose final target. Vendor 可留空：默认就 "GeForce GTX 1050" 这种参考名。
if ([string]::IsNullOrWhiteSpace($Vendor)) {
    $to = $TargetName
} else {
    $to = "$Vendor $TargetName"
}
$to = $to.Trim()
# 要替换掉的 GRID 原始名（覆盖 1Q/2Q/3Q/4Q/8Q 几个常见 profile）。
# 优先长串 ("NVIDIA GRID RTX6000-2Q") 先于短串 ("GRID RTX6000") 匹配，
# 否则命中短的会在 to 前留一个多余的 "NVIDIA " (→ "NVIDIA NVIDIA GeForce...")。
$from = 'NVIDIA GRID RTX6000-1Q','NVIDIA GRID RTX6000-2Q','NVIDIA GRID RTX6000-3Q','NVIDIA GRID RTX6000-4Q','NVIDIA GRID RTX6000-8Q','NVIDIA GRID RTX6000',
        'GRID RTX6000-1Q','GRID RTX6000-2Q','GRID RTX6000-3Q','GRID RTX6000-4Q','GRID RTX6000-8Q','GRID RTX6000'

W "==== Config ===="
W ("  TargetName = $TargetName")
W ("  Vendor     = $Vendor")
W ("  Final 'to' = $to")
W ("  DeviceIds  = $($DeviceIdMatch -join ', ')")

function RewriteKey($path) {
    if (-not (Test-Path $path)) { return }
    $props = Get-ItemProperty $path -ErrorAction SilentlyContinue
    if (-not $props) { return }
    $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' -and $_.Value -is [string] } | ForEach-Object {
        $orig = $_.Value
        $new  = $orig
        foreach ($f in $from) { $new = $new.Replace($f, $to) }
        if ($new -ne $orig) {
            W ("  $path :: $($_.Name)")
            W ("    -  $orig")
            W ("    +  $new")
            Set-ItemProperty -Path $path -Name $_.Name -Value $new -Force
        }
    }
}

$devMatchRegex = ($DeviceIdMatch | ForEach-Object { [regex]::Escape($_) }) -join '|'
W ""
W "==== Patching HKLM\SYSTEM\CurrentControlSet\Enum\PCI\* keys ===="
$pciRoot = 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI'
Get-ChildItem $pciRoot -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match $devMatchRegex } | ForEach-Object {
    $inst = $_.PSPath
    Get-ChildItem $inst -ErrorAction SilentlyContinue | ForEach-Object {
        RewriteKey $_.PSPath
        Get-ChildItem $_.PSPath -Recurse -ErrorAction SilentlyContinue | ForEach-Object { RewriteKey $_.PSPath }
    }
    RewriteKey $inst
}

# Normalize DeviceDesc format — drop the @oem6.inf,%...% prefix so Windows uses the literal
W ""
W "==== Normalizing DeviceDesc (strip oemN.inf INF reference) ===="
Get-ChildItem $pciRoot -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match $devMatchRegex } | ForEach-Object {
    Get-ChildItem $_.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
        $dd = (Get-ItemProperty $_.PSPath -Name DeviceDesc -ErrorAction SilentlyContinue).DeviceDesc
        if ($dd -and $dd -match '^@oem\d+\.inf,%[^%]+%;(.+)$') {
            $clean = $Matches[1]
            foreach ($f in $from) { $clean = $clean.Replace($f, $to) }
            W ("  $($_.PSPath) :: DeviceDesc => $clean")
            Set-ItemProperty -Path $_.PSPath -Name DeviceDesc -Value $clean -Force
        }
    }
}

W ""
W "==== Patching Control\Class\{4D36E968-...} (display GUID) ===="
$clsRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E968-E325-11CE-BFC1-08002BE10318}'
Get-ChildItem $clsRoot -ErrorAction SilentlyContinue | ForEach-Object { RewriteKey $_.PSPath }

W ""
W "==== Patching Control\Video\{...} ===="
$vidRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Video'
Get-ChildItem $vidRoot -ErrorAction SilentlyContinue | ForEach-Object {
    RewriteKey $_.PSPath
    Get-ChildItem $_.PSPath -ErrorAction SilentlyContinue | ForEach-Object { RewriteKey $_.PSPath }
}

W ""
W "==== Verifying Win32_VideoController ===="
$vc = Get-CimInstance Win32_VideoController
foreach ($c in $vc) {
    W ("Name = '$($c.Name)'")
    W ("Description = '$($c.Description)'")
    W ("VideoProcessor = '$($c.VideoProcessor)'")
}
W ""
W "==== DONE ===="
