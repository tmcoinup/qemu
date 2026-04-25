#!/usr/bin/env bash
# analyze-minidump.sh — extract bug check info from a Windows minidump on Linux.
#
# Windows MINIDUMP_HEADER (32 bytes) layout:
#   uint32_t Signature   = 'MDMP' (0x504D444D)
#   uint32_t Version     (low 16 bits = MINIDUMP_VERSION)
#   uint32_t NumberOfStreams
#   uint32_t StreamDirectoryRva
#   uint32_t CheckSum
#   uint32_t TimeDateStamp
#   uint64_t Flags
#
# We just want the bug check code which lives in the EXCEPTION_STREAM (type 6)
# or SYSTEM_INFO_STREAM (type 7) for kernel dumps. Easiest cheat: search for
# the marker bytes and dump the BugCheckParameters from the SystemInfo block.
#
# For cleaner analysis, copy the .dmp to a Windows machine + open with WinDbg
# (`!analyze -v`).
set -e

DMP="${1:-}"
if [[ -z "$DMP" || ! -f "$DMP" ]]; then
    echo "usage: $0 <minidump.dmp>" >&2
    exit 1
fi

echo "[file] $DMP ($(stat -c '%s' "$DMP") bytes)"

# Quick signature check
SIG=$(head -c 4 "$DMP" | xxd -p)
echo "[sig ] $SIG (expect 4d444d50 = 'MDMP')"

# Common bug check codes for our setup:
#   0x113 = VIDEO_DXGKRNL_FATAL_ERROR  (display kernel)
#   0x119 = VIDEO_SCHEDULER_INTERNAL_ERROR
#   0x117 = VIDEO_TDR_TIMEOUT_DETECTED
#   0x109 = CRITICAL_STRUCTURE_CORRUPTION (PatchGuard)
#   0x139 = KERNEL_SECURITY_CHECK_FAILURE
#   0x1A  = MEMORY_MANAGEMENT
#   0x3B  = SYSTEM_SERVICE_EXCEPTION
#   0x7E  = SYSTEM_THREAD_EXCEPTION_NOT_HANDLED
#   0xC4  = DRIVER_VERIFIER_DETECTED_VIOLATION
#   0xEF  = CRITICAL_PROCESS_DIED
#   0x9F  = DRIVER_POWER_STATE_FAILURE
#   0xC2  = BAD_POOL_CALLER

# Use radare2 / volatility / strings as fallback to pull bug check
if command -v r2 >/dev/null 2>&1; then
    r2 -nn -c 'pf BugCheck=Q4 @ entry0; q' "$DMP" 2>/dev/null || true
fi

echo
echo '[strings hint] looking for ntoskrnl / viogpudo / dxgkrnl / nv* in dump...'
strings -n 6 -e l "$DMP" 2>/dev/null | grep -iE 'BugCheck|ntoskrnl|viogpudo|dxgkrnl|virtio|nvlddmkm|VIDEO_|CRITICAL_|SYSTEM_THREAD' | head -30

echo
echo 'For full !analyze -v: copy this .dmp to a Windows + WinDbg machine.'
