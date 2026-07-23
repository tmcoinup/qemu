# GPU durable transaction 的纯内存 RegistryKey fixture。

function New-FakeRegistryKey {
    $key = [pscustomobject]@{
        Values=@{}; Kinds=@{}; Children=@{}; FailSetName=$null
        FlushCount=0; MutationCount=0
    }
    $key | Add-Member ScriptMethod GetValueNames { return @($this.Values.Keys) }
    $key | Add-Member ScriptMethod GetValueKind { param($Name) return $this.Kinds[$Name] }
    $key | Add-Member ScriptMethod GetValue {
        param($Name, $DefaultValue, $Options)
        if ($this.Values.ContainsKey($Name)) { return $this.Values[$Name] }
        return $DefaultValue
    }
    $key | Add-Member ScriptMethod SetValue {
        param($Name, $Value, $Kind)
        $this.MutationCount++
        if ($this.FailSetName -ceq $Name) { throw ("injected SetValue failure: " + $Name) }
        $this.Values[$Name] = $Value; $this.Kinds[$Name] = $Kind
    }
    $key | Add-Member ScriptMethod DeleteValue {
        param($Name, $ThrowOnMissing)
        $this.MutationCount++
        [void]$this.Values.Remove($Name); [void]$this.Kinds.Remove($Name)
    }
    $key | Add-Member ScriptMethod OpenSubKey {
        param($Path, $Writable)
        if ($this.Children.ContainsKey($Path)) { return $this.Children[$Path] }
        return $null
    }
    $key | Add-Member ScriptMethod CreateSubKey {
        param($Path, $Writable)
        if (-not $this.Children.ContainsKey($Path)) {
            $this.Children[$Path] = New-FakeRegistryKey
        }
        return $this.Children[$Path]
    }
    $key | Add-Member ScriptMethod Flush { $this.FlushCount++ }
    $key | Add-Member ScriptMethod Dispose {}
    return $key
}

function Set-FakeValue($Key, [string]$Name, $Value, $Kind) {
    $Key.Values[$Name] = $Value; $Key.Kinds[$Name] = $Kind
}

function Get-FixtureMutationCount {
    param($Fixture)
    $total = 0
    foreach ($key in @(
        $Fixture.Base, $Fixture.Config, $Fixture.Transaction, $Fixture.Identity,
        $Fixture.OldIdentity, $Fixture.Enum, $Fixture.Class
    )) { $total += [int]$key.MutationCount }
    return $total
}

function Set-CompleteIdentityValues {
    param($Key, [string]$IdentityId, [int]$Schema,
        [string]$SourceInstanceId, [string]$SpoofName,
        [bool]$IncludeSchema2Extensions)
    $string = [Microsoft.Win32.RegistryValueKind]::String
    $dword = [Microsoft.Win32.RegistryValueKind]::DWord
    Set-FakeValue $Key IdentitySchemaVersion $Schema $dword
    Set-FakeValue $Key IdentityId $IdentityId $string
    Set-FakeValue $Key SpoofName $SpoofName $string
    Set-FakeValue $Key SpoofVendor "NVIDIA" $string
    Set-FakeValue $Key SpoofBios "Version 86.07.42.00.96" $string
    Set-FakeValue $Key SpoofPciVendorId 0x10DE $dword
    Set-FakeValue $Key SpoofPciDeviceId 0x1C82 $dword
    Set-FakeValue $Key SpoofSubsystemVendorId 0x1043 $dword
    Set-FakeValue $Key SpoofSubsystemDeviceId 0x8613 $dword
    Set-FakeValue $Key SpoofRevisionId 0xA1 $dword
    Set-FakeValue $Key SpoofPciBusId 0 $dword
    Set-FakeValue $Key SpoofPciSlotId 6 $dword
    Set-FakeValue $Key SpoofPciFunctionId 0 $dword
    Set-FakeValue $Key SpoofRamMb 4096 $dword
    Set-FakeValue $Key SourceInstanceId $SourceInstanceId $string
    Set-FakeValue $Key IdentityMode "shallow-user-projection" $string
    if ($IncludeSchema2Extensions) {
        Set-FakeValue $Key SpoofMemoryType "GDDR5" $string
        Set-FakeValue $Key SpoofMemoryBusWidthBits 128 $dword
        Set-FakeValue $Key SpoofBaseClockKHz 1291000 $dword
        Set-FakeValue $Key SpoofBoostClockKHz 1392000 $dword
        Set-FakeValue $Key SpoofMemoryClockKHz 3504000 $dword
        Set-FakeValue $Key SpoofSliSupported 0 $dword
    }
}

function Set-AibIdentityValues {
    param($Key, $Case)
    $string = [Microsoft.Win32.RegistryValueKind]::String
    $dword = [Microsoft.Win32.RegistryValueKind]::DWord
    Set-FakeValue $Key SpoofName $Case.Name $string
    Set-FakeValue $Key SpoofVendor $Case.Vendor $string
    Set-FakeValue $Key SpoofBios $Case.Bios $string
    Set-FakeValue $Key SpoofPciVendorId $Case.PciVendor $dword
    Set-FakeValue $Key SpoofPciDeviceId $Case.Device $dword
    Set-FakeValue $Key SpoofSubsystemVendorId $Case.SubVendor $dword
    Set-FakeValue $Key SpoofSubsystemDeviceId $Case.SubDevice $dword
    Set-FakeValue $Key SpoofRevisionId $Case.Revision $dword
    Set-FakeValue $Key SpoofRamMb $Case.RamMb $dword
    Set-FakeValue $Key SpoofMemoryType $Case.MemoryType $string
    Set-FakeValue $Key SpoofMemoryBusWidthBits $Case.Width $dword
    Set-FakeValue $Key SpoofBaseClockKHz $Case.Base $dword
    Set-FakeValue $Key SpoofBoostClockKHz $Case.Boost $dword
    Set-FakeValue $Key SpoofMemoryClockKHz $Case.Memory $dword
    Set-FakeValue $Key SpoofSliSupported $Case.Sli $dword
}

function New-TransactionFixture {
    param([string]$IdentityId, [bool]$OldPointerPresent, [string]$State,
        [int]$TransactionSchema = 2)
    $string = [Microsoft.Win32.RegistryValueKind]::String
    $dword = [Microsoft.Win32.RegistryValueKind]::DWord
    $binary = [Microsoft.Win32.RegistryValueKind]::Binary
    $qword = [Microsoft.Win32.RegistryValueKind]::QWord
    $oldId = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    $source = "PCI\VEN_1AF4&DEV_1050&SUBSYS_A1011AF4&REV_A1\3&TEST&0&30"
    $enumPath = "SYSTEM\CurrentControlSet\Enum\" + $source
    $classPath = "SYSTEM\CurrentControlSet\Control\Class\" + $classGuid + "\0001"
    $base = New-FakeRegistryKey; $config = New-FakeRegistryKey
    $transaction = New-FakeRegistryKey; $identity = New-FakeRegistryKey
    $oldIdentity = New-FakeRegistryKey
    $enum = New-FakeRegistryKey; $class = New-FakeRegistryKey
    $base.Children["SOFTWARE\StealthGPU"] = $config
    $base.Children[$enumPath] = $enum; $base.Children[$classPath] = $class
    $config.Children["Transactions\" + $IdentityId] = $transaction
    $config.Children["Identities\" + $IdentityId] = $identity
    if ($OldPointerPresent) {
        $config.Children["Identities\" + $oldId] = $oldIdentity
        Set-CompleteIdentityValues $oldIdentity $oldId 2 $source `
            "NVIDIA GeForce GTX 1050 Ti (ASUS Phoenix)" $true
    }
    Set-FakeValue $transaction TransactionSchemaVersion $TransactionSchema $dword
    Set-FakeValue $transaction TransactionId $IdentityId $string
    Set-FakeValue $transaction State $State $string
    Set-FakeValue $transaction PreviousPointerPresent ([int]$OldPointerPresent) $dword
    if ($OldPointerPresent) { Set-FakeValue $transaction PreviousIdentityId $oldId $string }
    Set-FakeValue $transaction PreviousSpoofNamePresent ([int]$OldPointerPresent) $dword
    if ($OldPointerPresent) { Set-FakeValue $transaction PreviousSpoofName "NVIDIA OLD GPU" $string }
    Set-FakeValue $transaction ClassSubkey "0001" $string
    if ($TransactionSchema -eq 2) { Set-FakeValue $transaction DriverInfPath "oem3.inf" $string }
    Set-CompleteIdentityValues $identity $IdentityId 2 $source `
        "NVIDIA GeForce GTX 1050 Ti (ASUS Phoenix)" $true
    foreach ($name in $enumJournalNames) { Set-FakeValue $enum $name ("OLD-" + $name) $string }
    foreach ($name in $classJournalNames) {
        if ($name -ceq "HardwareInformation.MemorySize") {
            Set-FakeValue $class $name ([byte[]](0,0,0,128)) $binary
        } elseif ($name -ceq "HardwareInformation.qwMemorySize") {
            Set-FakeValue $class $name ([UInt64]2147483648) $qword
        } else { Set-FakeValue $class $name ("OLD-" + $name) $string }
    }
    Write-ProjectionJournal $transaction Enum $enum $enumPath $enumJournalNames
    Write-ProjectionJournal $transaction Class $class $classPath $classJournalNames
    $enumDesc = if ($TransactionSchema -eq 2) { "@oem3.inf,%viogpudod.devicedesc%;Red Hat VirtIO GPU DOD controller" } else { "NVIDIA GeForce GTX 1050 Ti (ASUS Phoenix)" }
    $enumMfg = if ($TransactionSchema -eq 2) { "@oem3.inf,%vendor%;Red Hat, Inc." } else { "NVIDIA" }
    $driverDesc = if ($TransactionSchema -eq 2) { "Red Hat VirtIO GPU DOD controller" } else { "NVIDIA GeForce GTX 1050 Ti (ASUS Phoenix)" }
    $driverProvider = if ($TransactionSchema -eq 2) { "Red Hat, Inc." } else { "NVIDIA" }
    $matchingId = if ($TransactionSchema -eq 2) { "PCI\VEN_1AF4&DEV_1050" } else { "PCI\VEN_10DE&DEV_1C82" }
    Set-FakeValue $enum FriendlyName "NVIDIA GeForce GTX 1050 Ti (ASUS Phoenix)" $string
    Set-FakeValue $enum DeviceDesc $enumDesc $string
    Set-FakeValue $enum Mfg $enumMfg $string
    foreach ($name in $classJournalNames) {
        if ($name -ceq "HardwareInformation.MemorySize") {
            Set-FakeValue $class $name ([byte[]](0,0,0,0)) $binary
        } elseif ($name -ceq "HardwareInformation.qwMemorySize") {
            Set-FakeValue $class $name ([UInt64]4294967296) $qword
        } else {
            $projected = switch -CaseSensitive ($name) {
                DriverDesc { $driverDesc; break }
                ProviderName { $driverProvider; break }
                MatchingDeviceId { $matchingId; break }
                "HardwareInformation.AdapterString" { "NVIDIA GeForce GTX 1050 Ti (ASUS Phoenix)"; break }
                "HardwareInformation.ChipType" { "GeForce GTX 1050 Ti (ASUS Phoenix)"; break }
                "HardwareInformation.DacType" { "Integrated RAMDAC"; break }
                "HardwareInformation.BiosString" { "Version 86.07.42.00.96"; break }
            }
            Set-FakeValue $class $name $projected $string
        }
    }
    Set-FakeValue $config PendingIdentity $IdentityId $string
    Set-FakeValue $config CurrentIdentity $IdentityId $string
    Set-FakeValue $config SpoofName "NVIDIA GeForce GTX 1050 Ti (ASUS Phoenix)" $string
    return [pscustomobject]@{
        Base=$base; Config=$config; Transaction=$transaction; Enum=$enum; Class=$class
        Identity=$identity; OldIdentity=$oldIdentity
        IdentityId=$IdentityId; OldId=$oldId; OldPointerPresent=$OldPointerPresent
    }
}

function Set-LegacyPreviousIdentity {
    param($Fixture, [bool]$IncludeIdentityId,
        [string]$IdentityId = $Fixture.OldId)
    $string = [Microsoft.Win32.RegistryValueKind]::String
    $dword = [Microsoft.Win32.RegistryValueKind]::DWord
    Set-FakeValue $Fixture.OldIdentity IdentitySchemaVersion 1 $dword
    if ($IncludeIdentityId) {
        Set-FakeValue $Fixture.OldIdentity IdentityId $IdentityId $string
    } else {
        [void]$Fixture.OldIdentity.Values.Remove("IdentityId")
        [void]$Fixture.OldIdentity.Kinds.Remove("IdentityId")
    }
    foreach ($name in @(
        "SpoofMemoryType", "SpoofMemoryBusWidthBits", "SpoofBaseClockKHz",
        "SpoofBoostClockKHz", "SpoofMemoryClockKHz", "SpoofSliSupported"
    )) {
        [void]$Fixture.OldIdentity.Values.Remove($name)
        [void]$Fixture.OldIdentity.Kinds.Remove($name)
    }
}

function Assert-RecoveryRejectedWithoutMutation {
    param($Fixture, [string]$Message)
    $currentBefore = [string]$Fixture.Config.Values.CurrentIdentity
    $pendingBefore = [string]$Fixture.Config.Values.PendingIdentity
    $mirrorBefore = [string]$Fixture.Config.Values.SpoofName
    $stateBefore = [string]$Fixture.Transaction.Values.State
    $enumBefore = [string]$Fixture.Enum.Values.FriendlyName
    $classBefore = [string]$Fixture.Class.Values.DriverDesc
    $rejected = $false
    try { Invoke-RecoverOrRollback -Recover | Out-Null }
    catch { $rejected = $true }
    if (-not $rejected -or
        [string]$Fixture.Config.Values.CurrentIdentity -cne $currentBefore -or
        [string]$Fixture.Config.Values.PendingIdentity -cne $pendingBefore -or
        [string]$Fixture.Config.Values.SpoofName -cne $mirrorBefore -or
        [string]$Fixture.Transaction.Values.State -cne $stateBefore -or
        [string]$Fixture.Enum.Values.FriendlyName -cne $enumBefore -or
        [string]$Fixture.Class.Values.DriverDesc -cne $classBefore) {
        throw $Message
    }
}

function Assert-RolledBack($Fixture) {
    if ($Fixture.Config.Values.ContainsKey("PendingIdentity")) { throw "PendingIdentity 未清除" }
    if ([string]$Fixture.Transaction.Values.State -cne "RolledBack") { throw "事务未标记 RolledBack" }
    if ($Fixture.OldPointerPresent) {
        if ([string]$Fixture.Config.Values.CurrentIdentity -cne $Fixture.OldId -or
            [string]$Fixture.Config.Values.SpoofName -cne "NVIDIA OLD GPU") {
            throw "旧 pointer/mirror 未恢复"
        }
    } elseif ($Fixture.Config.Values.ContainsKey("CurrentIdentity") -or
        $Fixture.Config.Values.ContainsKey("SpoofName")) {
        throw "首次安装回滚未删除 pointer/mirror"
    }
    if ([string]$Fixture.Enum.Values.FriendlyName -cne "OLD-FriendlyName") {
        throw "Enum journal 未恢复"
    }
    if ([UInt64]$Fixture.Class.Values["HardwareInformation.qwMemorySize"] -ne 2147483648) {
        throw "Class QWord journal 未恢复"
    }
    $bytes = [byte[]]$Fixture.Class.Values["HardwareInformation.MemorySize"]
    if ($bytes.Count -ne 4 -or $bytes[3] -ne 128) { throw "Class Binary journal 未恢复" }
}
