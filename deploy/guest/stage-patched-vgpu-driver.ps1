#requires -Version 5.1
<#
.SYNOPSIS
  Retired legacy patched vGPU pre-stager.

.DESCRIPTION
  The former code changed nvgridsw.inf and created a private catalog.  It has
  been removed so this file cannot be re-enabled by deleting a leading guard.
  Production migration stages only the hash-locked, byte-for-byte original
  NVIDIA package.
#>
[CmdletBinding()]
param(
    [string]$ArtifactRoot = 'C:\nv\retired-patched-vgpu-driver'
)

throw @'
DISABLED: the legacy pre-stager was removed because it modified an NVIDIA INF
and created a private/self-signed catalog. Use only the hash-locked, unmodified
NVIDIA/Microsoft production-signed package in the B-mode migration flow. This
entry point never changes BCD, certificates, DriverStore, devices, or files.
'@
