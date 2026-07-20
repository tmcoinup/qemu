#requires -Version 5.1
<#
.SYNOPSIS
  Retired legacy patched-driver entry point.

.DESCRIPTION
  The old implementation modified an NVIDIA INF and trusted a private
  self-signed catalog.  That implementation has been removed, not merely
  hidden behind an option.  Use the unmodified NVIDIA/Microsoft
  production-signed vGPU package and the B-mode migration flow.
#>

throw @'
DISABLED: the legacy patched-driver installer was removed because it relied on
a modified INF and a private/self-signed catalog. Use only the unmodified
NVIDIA/Microsoft production-signed driver; this entry point never changes BCD,
certificates, DriverStore, devices, or driver files.
'@
