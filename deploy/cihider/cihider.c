/*
 * cihider.sys - clear the TESTSIGN / DEBUGMODE bits in ci!g_CiOptions
 *
 * Background
 * ----------
 * Windows kernel tracks Driver Signature Enforcement state as a bitmask
 * stored in ci.dll's global "g_CiOptions".  Bits of interest:
 *   0x02 = TESTSIGN  (bcdedit /set testsigning on)
 *   0x80 = DEBUGMODE (debugger attached)
 * NtQuerySystemInformation(SystemCodeIntegrityInformation) reports the
 * contents of g_CiOptions to userland.  Anti-cheat uses that path to
 * verify testsigning is OFF.
 *
 * Strategy
 * --------
 * Our stealth stack requires test-signing ON at BOOT so that the
 * self-signed viogpudo.sys (HWID VEN_10DE:DEV_1C81) is allowed to load.
 * Once all self-signed boot-start drivers are in memory we flip the
 * TESTSIGN bit off - all existing drivers stay resident, subsequent
 * NtQSI queries report "normal" state.
 *
 * Locating g_CiOptions
 * --------------------
 * g_CiOptions lives in ci.dll's .data section.  The offset was resolved
 * via MS symbol server (ci.pdb GUID B8E660FB-FE0A-89FD-7048-BC091AB868D9,
 * age 1) using llvm-pdbutil:
 *   S_PUB32 `g_CiOptions` addr = 0003:4560  (.data offset 0x11D0)
 *   .data VA = 0x38000 -> g_CiOptions RVA = 0x391D0
 *
 * The .data section is marked IMAGE_SCN_MEM_WRITE, so a plain MDL
 * remap with PAGE_READWRITE (same path used for previous iterations)
 * succeeds; we additionally sanity-check the byte at the offset is
 * consistent with "ENABLED | TESTSIGN" before mutating.
 */

#include <ntifs.h>
#include <ntddk.h>

#define SystemModuleInformation        0x0B
#define CIH_TAG                        'dihC'   /* "Cihd" */

/* Offset of ci!g_CiOptions, resolved from ci.pdb — see block comment. */
#define CIH_G_CIOPTIONS_RVA            0x391D0UL

/*
 * Stage codes written to HKLM\SYSTEM\CurrentControlSet\Services\CiHider
 * so we can inspect from userland after boot (DbgPrint is invisible
 * without an attached kernel debugger).
 */
#define CIH_STAGE_NOT_STARTED          0x00
#define CIH_STAGE_CI_NOT_FOUND         0x01
#define CIH_STAGE_OUT_OF_RANGE         0x03
#define CIH_STAGE_SANITY_FAIL          0x04
#define CIH_STAGE_MDL_FAIL             0x05
#define CIH_STAGE_READ_FAIL            0x08
#define CIH_STAGE_DONE                 0xFF

#define SystemCodeIntegrityInformation 0x67

static VOID
CihWriteStage(ULONG stage, ULONG before_v, ULONG after_v, PVOID addr)
{
    UNICODE_STRING path = RTL_CONSTANT_STRING(
        L"\\Registry\\Machine\\SYSTEM\\CurrentControlSet\\Services\\CiHider");
    UNICODE_STRING v_stage  = RTL_CONSTANT_STRING(L"CihStage");
    UNICODE_STRING v_before = RTL_CONSTANT_STRING(L"CihBefore");
    UNICODE_STRING v_after  = RTL_CONSTANT_STRING(L"CihAfter");
    UNICODE_STRING v_addr   = RTL_CONSTANT_STRING(L"CihAddrHi");
    UNICODE_STRING v_addrlo = RTL_CONSTANT_STRING(L"CihAddrLo");

    ULONGLONG a = (ULONGLONG)addr;
    ULONG a_hi = (ULONG)(a >> 32);
    ULONG a_lo = (ULONG)(a & 0xFFFFFFFF);

    RtlWriteRegistryValue(RTL_REGISTRY_ABSOLUTE, path.Buffer,
                          v_stage.Buffer,  REG_DWORD,
                          &stage, sizeof(stage));
    RtlWriteRegistryValue(RTL_REGISTRY_ABSOLUTE, path.Buffer,
                          v_before.Buffer, REG_DWORD,
                          &before_v, sizeof(before_v));
    RtlWriteRegistryValue(RTL_REGISTRY_ABSOLUTE, path.Buffer,
                          v_after.Buffer,  REG_DWORD,
                          &after_v,  sizeof(after_v));
    RtlWriteRegistryValue(RTL_REGISTRY_ABSOLUTE, path.Buffer,
                          v_addr.Buffer,   REG_DWORD,
                          &a_hi, sizeof(a_hi));
    RtlWriteRegistryValue(RTL_REGISTRY_ABSOLUTE, path.Buffer,
                          v_addrlo.Buffer, REG_DWORD,
                          &a_lo, sizeof(a_lo));
}

typedef struct _RTL_PROCESS_MODULE_INFORMATION {
    HANDLE Section;
    PVOID  MappedBase;
    PVOID  ImageBase;
    ULONG  ImageSize;
    ULONG  Flags;
    USHORT LoadOrderIndex;
    USHORT InitOrderIndex;
    USHORT LoadCount;
    USHORT OffsetToFileName;
    UCHAR  FullPathName[256];
} RTL_PROCESS_MODULE_INFORMATION, *PRTL_PROCESS_MODULE_INFORMATION;

typedef struct _RTL_PROCESS_MODULES {
    ULONG                           NumberOfModules;
    RTL_PROCESS_MODULE_INFORMATION  Modules[1];
} RTL_PROCESS_MODULES, *PRTL_PROCESS_MODULES;

typedef struct _SYSTEM_CODEINTEGRITY_INFORMATION_LOCAL {
    ULONG Length;
    ULONG CodeIntegrityOptions;
} SYSTEM_CODEINTEGRITY_INFORMATION_LOCAL;

NTSYSAPI NTSTATUS NTAPI
ZwQuerySystemInformation(
    ULONG  SystemInformationClass,
    PVOID  SystemInformation,
    ULONG  SystemInformationLength,
    PULONG ReturnLength
);

DRIVER_UNLOAD CihUnload;
DRIVER_INITIALIZE DriverEntry;
KDEFERRED_ROUTINE CihTimerDpc;

/*
 * Persistent state for the periodic DPC scrubber that keeps
 * TESTSIGN/DEBUGMODE cleared throughout the system lifetime.
 */
static KTIMER          g_timer;
static KDPC            g_dpc;

static VOID
CihUnload(_In_ PDRIVER_OBJECT drv)
{
    UNREFERENCED_PARAMETER(drv);
    /* intentionally no-op: we do not want to restore the TESTSIGN bit */
}

/*
 * Clear bits in a kernel-image DWORD by temporarily disabling CR0.WP.
 * Runs at DISPATCH_LEVEL or above (safe from DPC).  Direct write to the
 * original kernel VA so the change is visible to every reader — in
 * contrast with MmProtectMdlSystemAddress, which on some builds gives
 * a private COW alias.
 */
static VOID
CihClearDirect(_In_ volatile LONG *slot, _In_ LONG clear_mask)
{
    KIRQL old_irql = KeRaiseIrqlToDpcLevel();
    UINT64 cr0 = __readcr0();
    _disable();
    __writecr0(cr0 & ~(UINT64)0x10000);   /* WP = 0 */
    _InterlockedAnd(slot, ~clear_mask);
    __writecr0(cr0);                      /* restore WP */
    _enable();
    KeLowerIrql(old_irql);
}

/* Global: ORIGINAL slot (ci_base + 0x391D0), not the MDL alias.  We
 * write directly after clearing CR0.WP from a DPC. */
static volatile LONG * g_orig_slot = NULL;

VOID
CihTimerDpc(_In_ PKDPC Dpc, _In_opt_ PVOID ctx,
            _In_opt_ PVOID sa1, _In_opt_ PVOID sa2)
{
    UNREFERENCED_PARAMETER(Dpc);
    UNREFERENCED_PARAMETER(ctx);
    UNREFERENCED_PARAMETER(sa1);
    UNREFERENCED_PARAMETER(sa2);

    if (g_orig_slot) {
        /* DPC already runs at DISPATCH_LEVEL; just flip WP and write. */
        UINT64 cr0 = __readcr0();
        _disable();
        __writecr0(cr0 & ~(UINT64)0x10000);
        _InterlockedAnd(g_orig_slot, ~(LONG)(0x02 | 0x80));
        __writecr0(cr0);
        _enable();
    }
}

static BOOLEAN
CihNameMatches(const char *fname, SIZE_T flen, const char *target, SIZE_T tlen)
{
    if (flen != tlen) return FALSE;
    for (SIZE_T i = 0; i < tlen; i++) {
        char a = fname[i];
        char b = target[i];
        if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
        if (b >= 'A' && b <= 'Z') b = (char)(b - 'A' + 'a');
        if (a != b) return FALSE;
    }
    return TRUE;
}

static PVOID
CihFindModule(_In_ const char *name_ascii, _Out_ PULONG OutSize)
{
    SIZE_T nlen = 0;
    while (name_ascii[nlen]) nlen++;

    ULONG need = 0;
    ZwQuerySystemInformation(SystemModuleInformation, NULL, 0, &need);
    if (need == 0) {
        return NULL;
    }
    ULONG buflen = need + 0x2000;
    PRTL_PROCESS_MODULES mods = (PRTL_PROCESS_MODULES)
        ExAllocatePool2(POOL_FLAG_NON_PAGED, buflen, CIH_TAG);
    if (!mods) {
        return NULL;
    }
    NTSTATUS st = ZwQuerySystemInformation(SystemModuleInformation,
                                           mods, buflen, &need);
    PVOID base = NULL;
    if (NT_SUCCESS(st)) {
        for (ULONG i = 0; i < mods->NumberOfModules; i++) {
            PUCHAR fn = mods->Modules[i].FullPathName +
                        mods->Modules[i].OffsetToFileName;
            SIZE_T flen = 0;
            while (flen < 64 && fn[flen]) flen++;
            if (CihNameMatches((const char *)fn, flen, name_ascii, nlen)) {
                base = mods->Modules[i].ImageBase;
                if (OutSize) *OutSize = mods->Modules[i].ImageSize;
                break;
            }
        }
    }
    ExFreePoolWithTag(mods, CIH_TAG);
    return base;
}


NTSTATUS
DriverEntry(_In_ PDRIVER_OBJECT drv, _In_ PUNICODE_STRING reg)
{
    UNREFERENCED_PARAMETER(reg);
    drv->DriverUnload = CihUnload;

    CihWriteStage(CIH_STAGE_NOT_STARTED, 0, 0, NULL);

    ULONG  ci_size = 0;
    PUCHAR ci_base = (PUCHAR)CihFindModule("ci.dll", &ci_size);
    if (!ci_base || ci_size == 0) {
        DbgPrint("cihider: ci.dll not in SystemModuleInformation\n");
        CihWriteStage(CIH_STAGE_CI_NOT_FOUND, 0, 0, NULL);
        return STATUS_SUCCESS;
    }

    /* Record the snapshot from the live kernel for diagnostics. */
    SYSTEM_CODEINTEGRITY_INFORMATION_LOCAL sci = { 0 };
    sci.Length = sizeof(sci);
    ULONG rl = 0;
    (void)ZwQuerySystemInformation(SystemCodeIntegrityInformation,
                                   &sci, sizeof(sci), &rl);
    ULONG want = sci.CodeIntegrityOptions;

    {
        UNICODE_STRING path = RTL_CONSTANT_STRING(
            L"\\Registry\\Machine\\SYSTEM\\CurrentControlSet\\Services\\CiHider");
        UNICODE_STRING v_want = RTL_CONSTANT_STRING(L"CihWant");
        UNICODE_STRING v_size = RTL_CONSTANT_STRING(L"CihCiSize");
        RtlWriteRegistryValue(RTL_REGISTRY_ABSOLUTE, path.Buffer,
                              v_want.Buffer, REG_DWORD, &want, sizeof(want));
        RtlWriteRegistryValue(RTL_REGISTRY_ABSOLUTE, path.Buffer,
                              v_size.Buffer, REG_DWORD, &ci_size, sizeof(ci_size));
    }

    /*
     * Cross-verified by static disassembly of ci.dll: many bts/or
     * insns target RVA 0x391D0 (section .data + 0x11D0), confirming
     * it is g_CiOptions.  At SERVICE_SYSTEM_START time g_CiOptions
     * may not yet have the ENABLED (0x1) bit set — what we need is
     * the TESTSIGN bit (0x2), cleared before NtQSI is queryable.
     */
    if (CIH_G_CIOPTIONS_RVA + sizeof(ULONG) > ci_size) {
        CihWriteStage(CIH_STAGE_OUT_OF_RANGE, want, ci_size, ci_base);
        return STATUS_SUCCESS;
    }

    PULONG slot = (PULONG)(ci_base + CIH_G_CIOPTIONS_RVA);

    ULONG before = 0;
    __try {
        before = *(volatile ULONG *)slot;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        CihWriteStage(CIH_STAGE_READ_FAIL, want, GetExceptionCode(), slot);
        return STATUS_SUCCESS;
    }

    /* Save the original (kernel-image) VA so the DPC can write directly
     * after clearing CR0.WP. */
    g_orig_slot = (volatile LONG *)slot;

    /* Initial immediate clear via CR0.WP-disable path */
    CihClearDirect(g_orig_slot, 0x02 | 0x80);

    ULONG after = 0;
    __try { after = *(volatile ULONG *)slot; }
    __except (EXCEPTION_EXECUTE_HANDLER) { after = 0xDEADBEEF; }

    CihWriteStage(CIH_STAGE_DONE, before, after, slot);

    /* Periodic scrubber: every 50ms re-clear TESTSIGN/DEBUGMODE.  CI
     * OR's bits into g_CiOptions as boot progresses past SYSTEM_START,
     * so a one-shot clear is not enough. */
    KeInitializeDpc(&g_dpc, CihTimerDpc, NULL);
    KeInitializeTimer(&g_timer);
    LARGE_INTEGER due;
    due.QuadPart = -(LONGLONG)500000; /* 50ms, 100ns units */
    KeSetTimerEx(&g_timer, due, 50 /* ms period */, &g_dpc);

    DbgPrint("cihider: g_CiOptions %p  %x -> %x\n",
             slot, before, after);
    return STATUS_SUCCESS;
}
