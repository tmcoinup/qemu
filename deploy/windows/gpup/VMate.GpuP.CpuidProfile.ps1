#Requires -Version 5.1

<#
.SYNOPSIS
    规范化 P-11 硬件池中的 CPUID 身份事实。

.DESCRIPTION
    本模块只构造宿主身份扩展的期望输入，不在运行中的 VM 内修改 CPUID。
    品牌字符串按 CPUID 0x80000002..0x80000004 的 48 字节、小端寄存器顺序
    编码；family/model/stepping 只在来源资料完整时生成 Leaf 1 EAX。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-VMateGpuPCpuidOptionalProperty {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$DefaultValue = $null
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $DefaultValue }
    return $property.Value
}

function ConvertTo-VMateGpuPCpuidLeaf1Eax {
    [CmdletBinding()]
    param(
        [ValidateRange(0, 255)][int]$Family,
        [ValidateRange(0, 255)][int]$Model,
        [ValidateRange(0, 15)][int]$Stepping
    )

    $baseFamily = if ($Family -ge 15) { 15 } else { $Family }
    $extendedFamily = if ($Family -ge 15) { $Family - 15 } else { 0 }
    $baseModel = $Model -band 0x0f
    $extendedModel = if ($baseFamily -in @(6, 15)) {
        ($Model -shr 4) -band 0x0f
    } else { 0 }
    return [uint32](
        ($Stepping -band 0x0f) -bor
        (($baseModel -band 0x0f) -shl 4) -bor
        (($baseFamily -band 0x0f) -shl 8) -bor
        (($extendedModel -band 0x0f) -shl 16) -bor
        (($extendedFamily -band 0xff) -shl 20))
}

function Get-VMateGpuPCpuidTuple {
    param([Parameter(Mandatory = $true)][object]$Processor)

    $familyValue = Get-VMateGpuPCpuidOptionalProperty $Processor 'family' $null
    $modelValue = Get-VMateGpuPCpuidOptionalProperty $Processor 'model' $null
    $steppingValue = Get-VMateGpuPCpuidOptionalProperty $Processor 'stepping' $null
    $source = 'catalog-fields'
    if ($null -eq $familyValue -or $null -eq $modelValue -or
        $null -eq $steppingValue) {
        $argument = [string](Get-VMateGpuPCpuidOptionalProperty $Processor 'qemu_arg' '')
        $familyMatch = [regex]::Match($argument, '(?:^|,)family=(\d+)')
        $modelMatch = [regex]::Match($argument, '(?:^|,)model=(\d+)')
        $steppingMatch = [regex]::Match($argument, '(?:^|,)stepping=(\d+)')
        if (-not ($familyMatch.Success -and $modelMatch.Success -and
                $steppingMatch.Success)) {
            return $null
        }
        $familyValue = [int]$familyMatch.Groups[1].Value
        $modelValue = [int]$modelMatch.Groups[1].Value
        $steppingValue = [int]$steppingMatch.Groups[1].Value
        $source = 'shared-qemu-argument'
    }
    $family = [int]$familyValue
    $model = [int]$modelValue
    $stepping = [int]$steppingValue
    $leaf1 = ConvertTo-VMateGpuPCpuidLeaf1Eax $family $model $stepping
    return [pscustomobject][ordered]@{
        Family = $family
        Model = $model
        Stepping = $stepping
        Leaf1Eax = $leaf1
        Leaf1EaxHex = ('0x{0:X8}' -f $leaf1)
        Source = $source
    }
}

function ConvertTo-VMateGpuPCpuidBrandLeaves {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$BrandString)

    if ($BrandString.Length -lt 1 -or $BrandString.Length -gt 48 -or
        $BrandString -match '[^\x20-\x7e]') {
        throw 'CPUID brand string 必须是 1..48 字节可打印 ASCII。'
    }
    $bytes = New-Object byte[] 48
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        $bytes[$index] = 0x20
    }
    [Text.Encoding]::ASCII.GetBytes($BrandString).CopyTo($bytes, 0)
    $leaves = [ordered]@{}
    for ($leafIndex = 0; $leafIndex -lt 3; $leafIndex++) {
        $registers = [Collections.Generic.List[string]]::new()
        for ($register = 0; $register -lt 4; $register++) {
            $offset = ($leafIndex * 16) + ($register * 4)
            $value = [BitConverter]::ToUInt32($bytes, $offset)
            [void]$registers.Add(('0x{0:X8}' -f $value))
        }
        $leaves[('0x{0:X8}' -f (0x80000002 + $leafIndex))] =
            @($registers)
    }
    return [pscustomobject]$leaves
}

function New-VMateGpuPCpuidIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Processor)

    $brand = [string](Get-VMateGpuPCpuidOptionalProperty $Processor 'name' '')
    $fallbackVendor = Get-VMateGpuPCpuidOptionalProperty $Processor 'vendor_id' ''
    $vendor = [string](Get-VMateGpuPCpuidOptionalProperty $Processor 'manufacturer' $fallbackVendor)
    if ([String]::IsNullOrWhiteSpace($brand)) {
        return [pscustomobject][ordered]@{
            IdentityPolicy = 'host-read-only'
            EvidenceSource = 'host-native'
            VendorId = $vendor
            BrandString = ''
            BrandLeaves = $null
            Family = $null
            Model = $null
            Stepping = $null
            Leaf1Eax = $null
            Leaf1EaxHex = ''
        }
    }
    $brandLeaves = ConvertTo-VMateGpuPCpuidBrandLeaves $brand
    $tuple = Get-VMateGpuPCpuidTuple $Processor
    $explicitLeaf = Get-VMateGpuPCpuidOptionalProperty $Processor 'cpuid_leaf1_eax' $null
    if ($null -ne $explicitLeaf) {
        $explicitLeaf = [uint32][uint64]$explicitLeaf
        if ($null -ne $tuple -and [uint32]$tuple.Leaf1Eax -ne $explicitLeaf) {
            throw 'CPUID family/model/stepping 与显式 Leaf 1 EAX 不一致。'
        }
    }
    $leaf1 = if ($null -ne $explicitLeaf) { $explicitLeaf }
        elseif ($null -ne $tuple) { [uint32]$tuple.Leaf1Eax }
        else { $null }
    $evidence = [string](Get-VMateGpuPCpuidOptionalProperty $Processor 'cpuid_evidence_source' '')
    if ([String]::IsNullOrWhiteSpace($evidence)) {
        $evidence = if ($null -ne $tuple) { [string]$tuple.Source }
            else { 'derived-brand-only' }
    }
    return [pscustomobject][ordered]@{
        IdentityPolicy = 'host-extension-required'
        EvidenceSource = $evidence
        VendorId = $vendor
        BrandString = $brand
        BrandLeaves = $brandLeaves
        Family = if ($null -ne $tuple) { [int]$tuple.Family } else { $null }
        Model = if ($null -ne $tuple) { [int]$tuple.Model } else { $null }
        Stepping = if ($null -ne $tuple) { [int]$tuple.Stepping } else { $null }
        Leaf1Eax = $leaf1
        Leaf1EaxHex = if ($null -ne $leaf1) {
            '0x{0:X8}' -f [uint32]$leaf1
        } else { '' }
    }
}
