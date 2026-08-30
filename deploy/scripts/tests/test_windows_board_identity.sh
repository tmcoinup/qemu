#!/usr/bin/env bash
# Windows 共享主板厂商策略、序列生成器和原子品牌绑定回归。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
POWERSHELL="$(command -v pwsh || command -v powershell || true)"

if [[ -z "$POWERSHELL" ]]; then
    echo "PASS: PowerShell unavailable; Windows board identity test skipped"
    exit 0
fi

REPO_ROOT="$REPO_ROOT" "$POWERSHELL" -NoLogo -NoProfile -NonInteractive \
    -Command '
        $ErrorActionPreference = "Stop"
        . "$env:REPO_ROOT/deploy/windows/lib/VMate.Profile.ps1"

        function Assert-BoardTest {
            param([bool]$Condition, [string]$Message)
            if (-not $Condition) {
                throw $Message
            }
        }

        function Assert-BoardThrows {
            param([scriptblock]$Action, [string]$Message)
            $thrown = $false
            try {
                & $Action
            } catch {
                $thrown = $true
            }
            if (-not $thrown) {
                throw $Message
            }
        }

        $manifest = Read-VMateHardwareManifest `
            "$env:REPO_ROOT/deploy/hardware/platforms.json"
        $platforms = @($manifest.platforms | Where-Object {
                $_.status -eq "supported"
            })
        $brands = @($platforms.board.manufacturer | Sort-Object -Unique)
        Assert-BoardTest (($brands -join "|") -eq
            "ASRock|ASUSTeK COMPUTER INC.|Gigabyte Technology Co., Ltd.|Micro-Star International Co., Ltd.") `
            "Windows 启用平台未覆盖 ASRock/ASUS/GIGABYTE/MSI 四个主板品牌。"

        $samples = @{}
        foreach ($platform in $platforms) {
            $seen = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::Ordinal)
            foreach ($iteration in 1..16) {
                $serial = New-VMateBoardSerial -Platform $platform
                Assert-VMateBoardSerial -Platform $platform -Serial $serial
                Assert-BoardTest ($seen.Add($serial)) `
                    "主板序列号生成器重复：$($platform.id)"
                $samples[[string]$platform.board.manufacturer] = $serial
            }
            switch ([string]$platform.board.manufacturer) {
                "ASUSTeK COMPUTER INC." {
                    Assert-BoardTest ($serial -cmatch
                        "^[A-Z0-9]{2}S[A-Z0-9]{9}$") `
                        "ASUS 序列号未遵循第三位 S 的 12 字符结构。"
                }
                "Micro-Star International Co., Ltd." {
                    $code = ([string]$platform.board.subsystem_device).
                        Replace("0x", "").ToUpperInvariant()
                    Assert-BoardTest ($serial.StartsWith(
                            "601-$code-", [StringComparison]::Ordinal) -and
                        $serial.Length -eq 23) `
                        "MSI 序列号未绑定主板 MS code。"
                }
                "Gigabyte Technology Co., Ltd." {
                    $year = ([int]$platform.release_year % 100).ToString("00")
                    $week = [int]$serial.Substring(4, 2)
                    Assert-BoardTest ($serial.StartsWith(
                            "SN$year", [StringComparison]::Ordinal) -and
                        $week -ge 1 -and $week -le 53) `
                        "GIGABYTE 序列号未使用有效 YYWW 日期码。"
                }
                "ASRock" {
                    Assert-BoardTest ($serial -cmatch "^[A-Z0-9]{12}$") `
                        "ASRock 序列号未遵循 12 字符大写结构。"
                }
            }
        }

        $msi = @($platforms | Where-Object {
                $_.board.manufacturer -eq
                    "Micro-Star International Co., Ltd."
            })[0]
        Assert-BoardThrows {
            Assert-VMateBoardSerial $msi "601-7979-01SB0123456789"
        } "Windows MSI 校验器接受了其它主板的 board code。"
        $gigabyte = @($platforms | Where-Object {
                $_.board.manufacturer -eq
                    "Gigabyte Technology Co., Ltd."
            })[0]
        $year = ([int]$gigabyte.release_year % 100).ToString("00")
        Assert-BoardThrows {
            Assert-VMateBoardSerial $gigabyte "SN${year}0000000000"
        } "Windows GIGABYTE 校验器接受了第 00 周。"
        $asus = @($platforms | Where-Object {
                $_.board.manufacturer -eq "ASUSTeK COMPUTER INC."
            })[0]
        Assert-VMateBoardSerial $asus "MB123456789012" $true
        Assert-BoardThrows {
            Assert-VMateBoardSerial $asus "MB123456789012"
        } "旧版 ASUS 序列号未被限制在旧 profile 兼容路径。"

        $tampered = $msi | ConvertTo-Json -Depth 64 | ConvertFrom-Json
        $tampered.board.manufacturer = "ASUSTeK COMPUTER INC."
        Assert-BoardThrows {
            [void](Get-VMateBoardVendorPolicy $tampered)
        } "Windows 主板策略接受了 MSI subsystem 与 ASUS 品牌混搭。"

        $asrock = @($platforms | Where-Object {
                $_.board.manufacturer -eq "ASRock"
            })[0]
        Assert-BoardThrows {
            Assert-VMateBoardSerial $asrock "asrock123456"
        } "Windows ASRock 校验器接受了小写序列号。"
    '

echo "PASS: Windows multi-brand board identity"
