/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * One-shot CPUID brand extension for an authorized, paused Hyper-V lab VM.
 *
 * The image has no device object or user IOCTL surface.  DriverEntry consumes
 * one explicitly selected vmwp.exe PID/partition handle and exactly 48 ASCII
 * brand bytes from its transient service key.  A kernel thread associated with
 * that vmwp validates the inbox VID partition ID and registers only leaves
 * 0x80000002..0x80000004.  Partial application is rolled back before the image
 * deliberately fails DriverEntry and unloads.
 */

#define _AMD64_
#define AMD64
#define NTDDI_VERSION 0x0A000000

#include <ntddk.h>
#include <ntifs.h>

#define VMATE_CONTRACT_VERSION 2u
#define VMATE_VID_GET_HV_PARTITION_ID_IOCTL 0x002210afu
#define VMATE_VID_REGISTER_CPUID_RESULT_IOCTL 0x00221134u
#define VMATE_VID_UNREGISTER_CPUID_RESULT_IOCTL 0x002211b0u
#define VMATE_PROCESS_CREATE_THREAD 0x0002u
#define VMATE_MAX_SERVICE_PATH_BYTES 1000u
#define VMATE_BRAND_BYTES 48u
#define VMATE_BRAND_LEAF_COUNT 3u
#define VMATE_CPUID_ALWAYS_OVERRIDE 1u

#define VMATE_STATUS_INVALID_IMAGE_FORMAT ((NTSTATUS)0xC000007BL)
#define VMATE_STATUS_PARTITION_MISMATCH ((NTSTATUS)0xC0000034L)

DRIVER_INITIALIZE DriverEntry;

NTKERNELAPI
PCHAR
NTAPI
PsGetProcessImageFileName(
    PEPROCESS Process
    );

typedef struct _VMATE_CPUID_REGISTER_INPUT {
    ULONG Leaf;
    UCHAR Flags;
    UCHAR Reserved[3];
    ULONG Result[4];
    ULONG Mask[4];
} VMATE_CPUID_REGISTER_INPUT, *PVMATE_CPUID_REGISTER_INPUT;

_Static_assert(sizeof(VMATE_CPUID_REGISTER_INPUT) == 40,
               "VID CPUID registration input must be exactly 40 bytes");

typedef struct _VMATE_CPUID_THREAD_CONTEXT {
    PFILE_OBJECT FileObject;
    PEPROCESS TargetProcess;
    ULONGLONG ExpectedPartitionId;
    UCHAR Brand[VMATE_BRAND_BYTES];
    NTSTATUS QueryStatus;
    NTSTATUS BufferAllocationStatus;
    NTSTATUS BufferFreeStatus;
    NTSTATUS RegisterStatus[VMATE_BRAND_LEAF_COUNT];
    NTSTATUS RollbackStatus[VMATE_BRAND_LEAF_COUNT];
    ULONGLONG ObservedPartitionId;
    ULONG CurrentProcessMatched;
    ULONG FastIoAvailable;
    ULONG FastIoHandled;
    ULONG MutatingCalls;
    ULONG RollbackCalls;
    ULONG Applied;
} VMATE_CPUID_THREAD_CONTEXT, *PVMATE_CPUID_THREAD_CONTEXT;

static BOOLEAN
VMateAsciiEqualsInsensitive(
    const CHAR *Left,
    const CHAR *Right
    )
{
    ULONG index;

    if (Left == NULL || Right == NULL) {
        return FALSE;
    }
    for (index = 0; Right[index] != '\0'; ++index) {
        CHAR left = Left[index];
        CHAR right = Right[index];

        if (left >= 'A' && left <= 'Z') {
            left = (CHAR)(left - 'A' + 'a');
        }
        if (right >= 'A' && right <= 'Z') {
            right = (CHAR)(right - 'A' + 'a');
        }
        if (left != right || left == '\0') {
            return FALSE;
        }
    }
    return Left[index] == '\0';
}

static NTSTATUS
VMateOpenParametersKey(
    PUNICODE_STRING RegistryPath,
    PHANDLE ParametersKey
    )
{
    static const WCHAR suffix[] = L"\\Parameters";
    WCHAR pathBuffer[VMATE_MAX_SERVICE_PATH_BYTES / sizeof(WCHAR)];
    UNICODE_STRING path;
    OBJECT_ATTRIBUTES attributes;
    USHORT suffixBytes = (USHORT)(sizeof(suffix) - sizeof(WCHAR));
    USHORT sourceIndex;
    USHORT suffixIndex;

    if (RegistryPath == NULL || ParametersKey == NULL ||
        RegistryPath->Buffer == NULL ||
        RegistryPath->Length + suffixBytes + sizeof(WCHAR) >
            sizeof(pathBuffer)) {
        return STATUS_NAME_TOO_LONG;
    }
    for (sourceIndex = 0;
         sourceIndex < RegistryPath->Length / sizeof(WCHAR);
         ++sourceIndex) {
        pathBuffer[sourceIndex] = RegistryPath->Buffer[sourceIndex];
    }
    for (suffixIndex = 0;
         suffixIndex < suffixBytes / sizeof(WCHAR);
         ++suffixIndex) {
        pathBuffer[sourceIndex + suffixIndex] = suffix[suffixIndex];
    }
    pathBuffer[sourceIndex + suffixIndex] = L'\0';
    path.Buffer = pathBuffer;
    path.Length = (USHORT)(RegistryPath->Length + suffixBytes);
    path.MaximumLength = (USHORT)(path.Length + sizeof(WCHAR));
    InitializeObjectAttributes(&attributes,
                               &path,
                               OBJ_CASE_INSENSITIVE | OBJ_KERNEL_HANDLE,
                               NULL,
                               NULL);
    return ZwOpenKey(ParametersKey,
                     KEY_QUERY_VALUE | KEY_SET_VALUE,
                     &attributes);
}

static NTSTATUS
VMateReadRegistryInteger(
    HANDLE ParametersKey,
    PCWSTR Name,
    ULONG ExpectedType,
    PULONGLONG Value
    )
{
    UCHAR informationBuffer[
        sizeof(KEY_VALUE_PARTIAL_INFORMATION) + sizeof(ULONGLONG)];
    PKEY_VALUE_PARTIAL_INFORMATION information;
    UNICODE_STRING valueName;
    ULONG resultLength = 0;
    ULONG expectedLength;
    ULONG index;
    NTSTATUS status;

    RtlInitUnicodeString(&valueName, Name);
    information = (PKEY_VALUE_PARTIAL_INFORMATION)informationBuffer;
    status = ZwQueryValueKey(ParametersKey,
                             &valueName,
                             KeyValuePartialInformation,
                             information,
                             sizeof(informationBuffer),
                             &resultLength);
    if (!NT_SUCCESS(status)) {
        return status;
    }
    expectedLength = ExpectedType == REG_DWORD ?
        sizeof(ULONG) : sizeof(ULONGLONG);
    if (information->Type != ExpectedType ||
        information->DataLength != expectedLength) {
        return STATUS_OBJECT_TYPE_MISMATCH;
    }
    *Value = 0;
    for (index = 0; index < expectedLength; ++index) {
        *Value |= ((ULONGLONG)information->Data[index]) << (index * 8u);
    }
    return STATUS_SUCCESS;
}

static NTSTATUS
VMateReadRegistryBrand(
    HANDLE ParametersKey,
    PUCHAR Brand
    )
{
    UCHAR informationBuffer[
        sizeof(KEY_VALUE_PARTIAL_INFORMATION) + VMATE_BRAND_BYTES];
    PKEY_VALUE_PARTIAL_INFORMATION information;
    UNICODE_STRING valueName;
    ULONG resultLength = 0;
    ULONG index;
    NTSTATUS status;

    RtlInitUnicodeString(&valueName, L"BrandBytes");
    information = (PKEY_VALUE_PARTIAL_INFORMATION)informationBuffer;
    status = ZwQueryValueKey(ParametersKey,
                             &valueName,
                             KeyValuePartialInformation,
                             information,
                             sizeof(informationBuffer),
                             &resultLength);
    if (!NT_SUCCESS(status)) {
        return status;
    }
    if (information->Type != REG_BINARY ||
        information->DataLength != VMATE_BRAND_BYTES) {
        return STATUS_OBJECT_TYPE_MISMATCH;
    }
    for (index = 0; index < VMATE_BRAND_BYTES; ++index) {
        if (information->Data[index] < 0x20u ||
            information->Data[index] > 0x7eu) {
            return STATUS_INVALID_PARAMETER;
        }
        Brand[index] = information->Data[index];
    }
    return STATUS_SUCCESS;
}

static NTSTATUS
VMateWriteRegistryDword(
    HANDLE ParametersKey,
    PCWSTR Name,
    ULONG Value
    )
{
    UNICODE_STRING valueName;

    RtlInitUnicodeString(&valueName, Name);
    return ZwSetValueKey(ParametersKey,
                         &valueName,
                         0,
                         REG_DWORD,
                         &Value,
                         sizeof(Value));
}

static NTSTATUS
VMateWriteRegistryQword(
    HANDLE ParametersKey,
    PCWSTR Name,
    ULONGLONG Value
    )
{
    UNICODE_STRING valueName;

    RtlInitUnicodeString(&valueName, Name);
    return ZwSetValueKey(ParametersKey,
                         &valueName,
                         0,
                         REG_QWORD,
                         &Value,
                         sizeof(Value));
}

static NTSTATUS
VMateQueryPartitionIdFastIo(
    PFILE_OBJECT FileObject,
    PULONGLONG PartitionId,
    PNTSTATUS BufferAllocationStatus,
    PNTSTATUS BufferFreeStatus,
    PULONG FastIoAvailable,
    PULONG FastIoHandled
    )
{
    PDEVICE_OBJECT deviceObject;
    PFAST_IO_DISPATCH fastIoDispatch;
    IO_STATUS_BLOCK ioStatus;
    PVOID outputBuffer = NULL;
    SIZE_T regionSize = sizeof(ULONGLONG);
    SIZE_T freeSize = 0;
    BOOLEAN handled;
    NTSTATUS status;

    *PartitionId = 0;
    *BufferAllocationStatus = STATUS_UNSUCCESSFUL;
    *BufferFreeStatus = STATUS_UNSUCCESSFUL;
    *FastIoAvailable = 0;
    *FastIoHandled = 0;
    if (FileObject == NULL) {
        return STATUS_INVALID_HANDLE;
    }
    deviceObject = IoGetRelatedDeviceObject(FileObject);
    if (deviceObject == NULL || deviceObject->DriverObject == NULL) {
        return STATUS_INVALID_DEVICE_STATE;
    }
    fastIoDispatch = deviceObject->DriverObject->FastIoDispatch;
    if (fastIoDispatch == NULL ||
        fastIoDispatch->SizeOfFastIoDispatch <
            FIELD_OFFSET(FAST_IO_DISPATCH, FastIoDeviceControl) +
                sizeof(PFAST_IO_DEVICE_CONTROL) ||
        fastIoDispatch->FastIoDeviceControl == NULL) {
        return STATUS_NOT_SUPPORTED;
    }
    *FastIoAvailable = 1;
    *BufferAllocationStatus = ZwAllocateVirtualMemory(
        ZwCurrentProcess(),
        &outputBuffer,
        0,
        &regionSize,
        MEM_RESERVE | MEM_COMMIT,
        PAGE_READWRITE);
    if (!NT_SUCCESS(*BufferAllocationStatus)) {
        return *BufferAllocationStatus;
    }

    ioStatus.Status = STATUS_UNSUCCESSFUL;
    ioStatus.Information = 0;
    handled = fastIoDispatch->FastIoDeviceControl(
        FileObject,
        TRUE,
        NULL,
        0,
        outputBuffer,
        sizeof(ULONGLONG),
        VMATE_VID_GET_HV_PARTITION_ID_IOCTL,
        &ioStatus,
        deviceObject);
    *FastIoHandled = handled ? 1u : 0u;
    status = handled ? ioStatus.Status : STATUS_NOT_SUPPORTED;
    if (NT_SUCCESS(status)) {
        *PartitionId = *(volatile ULONGLONG *)outputBuffer;
    }
    *BufferFreeStatus = ZwFreeVirtualMemory(
        ZwCurrentProcess(),
        &outputBuffer,
        &freeSize,
        MEM_RELEASE);
    if (NT_SUCCESS(status) && !NT_SUCCESS(*BufferFreeStatus)) {
        return *BufferFreeStatus;
    }
    return status;
}

static NTSTATUS
VMateIssueBufferedIoctl(
    PFILE_OBJECT FileObject,
    ULONG IoControlCode,
    PVOID InputBuffer,
    ULONG InputBufferLength
    )
{
    PDEVICE_OBJECT deviceObject;
    PIO_STACK_LOCATION stack;
    PIRP irp;
    KEVENT event;
    IO_STATUS_BLOCK ioStatus;
    NTSTATUS status;

    deviceObject = IoGetRelatedDeviceObject(FileObject);
    if (deviceObject == NULL) {
        return STATUS_INVALID_DEVICE_STATE;
    }
    KeInitializeEvent(&event, NotificationEvent, FALSE);
    ioStatus.Status = STATUS_UNSUCCESSFUL;
    ioStatus.Information = 0;
    irp = IoBuildDeviceIoControlRequest(IoControlCode,
                                        deviceObject,
                                        InputBuffer,
                                        InputBufferLength,
                                        NULL,
                                        0,
                                        FALSE,
                                        &event,
                                        &ioStatus);
    if (irp == NULL) {
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    stack = IoGetNextIrpStackLocation(irp);
    stack->FileObject = FileObject;
    status = IoCallDriver(deviceObject, irp);
    if (status == STATUS_PENDING) {
        status = KeWaitForSingleObject(&event,
                                       Executive,
                                       KernelMode,
                                       FALSE,
                                       NULL);
        if (NT_SUCCESS(status)) {
            status = ioStatus.Status;
        }
    }
    else if (ioStatus.Status != STATUS_UNSUCCESSFUL) {
        status = ioStatus.Status;
    }
    return status;
}

static VOID
VMateInitializeRegisterInput(
    PVMATE_CPUID_REGISTER_INPUT Input,
    ULONG LeafIndex,
    PUCHAR Brand
    )
{
    ULONG registerIndex;
    ULONG byteIndex;

    Input->Leaf = 0x80000002u + LeafIndex;
    /*
     * vid.dll maps this byte to the Hyper-V CPUID result parameter's
     * always_override field.  Brand leaf 0x80000004 is commonly all zero on
     * shorter host brand strings, so a value of zero silently leaves that
     * leaf unchanged even though registration itself succeeds.
     */
    Input->Flags = VMATE_CPUID_ALWAYS_OVERRIDE;
    Input->Reserved[0] = 0;
    Input->Reserved[1] = 0;
    Input->Reserved[2] = 0;
    for (registerIndex = 0; registerIndex < 4; ++registerIndex) {
        ULONG value = 0;
        ULONG offset = (LeafIndex * 16u) + (registerIndex * 4u);

        for (byteIndex = 0; byteIndex < 4; ++byteIndex) {
            value |= ((ULONG)Brand[offset + byteIndex]) <<
                (byteIndex * 8u);
        }
        Input->Result[registerIndex] = value;
        Input->Mask[registerIndex] = MAXULONG;
    }
}

static VOID
VMateCpuidTargetThread(
    PVOID StartContext
    )
{
    PVMATE_CPUID_THREAD_CONTEXT context =
        (PVMATE_CPUID_THREAD_CONTEXT)StartContext;
    VMATE_CPUID_REGISTER_INPUT input;
    ULONG leafIndex;
    ULONG registeredCount = 0;

    context->CurrentProcessMatched =
        PsGetCurrentProcess() == context->TargetProcess ? 1u : 0u;
    if (context->CurrentProcessMatched == 0) {
        context->QueryStatus = STATUS_ACCESS_DENIED;
        PsTerminateSystemThread(STATUS_SUCCESS);
    }
    context->QueryStatus = VMateQueryPartitionIdFastIo(
        context->FileObject,
        &context->ObservedPartitionId,
        &context->BufferAllocationStatus,
        &context->BufferFreeStatus,
        &context->FastIoAvailable,
        &context->FastIoHandled);
    if (!NT_SUCCESS(context->QueryStatus) ||
        context->ObservedPartitionId != context->ExpectedPartitionId) {
        if (NT_SUCCESS(context->QueryStatus)) {
            context->QueryStatus = VMATE_STATUS_PARTITION_MISMATCH;
        }
        PsTerminateSystemThread(STATUS_SUCCESS);
    }

    for (leafIndex = 0;
         leafIndex < VMATE_BRAND_LEAF_COUNT;
         ++leafIndex) {
        VMateInitializeRegisterInput(&input, leafIndex, context->Brand);
        context->MutatingCalls++;
        context->RegisterStatus[leafIndex] = VMateIssueBufferedIoctl(
            context->FileObject,
            VMATE_VID_REGISTER_CPUID_RESULT_IOCTL,
            &input,
            sizeof(input));
        if (!NT_SUCCESS(context->RegisterStatus[leafIndex])) {
            break;
        }
        registeredCount++;
    }
    if (registeredCount == VMATE_BRAND_LEAF_COUNT) {
        context->Applied = 1;
        PsTerminateSystemThread(STATUS_SUCCESS);
    }

    while (registeredCount > 0) {
        ULONG leaf;

        registeredCount--;
        leaf = 0x80000002u + registeredCount;
        context->MutatingCalls++;
        context->RollbackCalls++;
        context->RollbackStatus[registeredCount] =
            VMateIssueBufferedIoctl(
                context->FileObject,
                VMATE_VID_UNREGISTER_CPUID_RESULT_IOCTL,
                &leaf,
                sizeof(leaf));
    }
    PsTerminateSystemThread(STATUS_SUCCESS);
}

static NTSTATUS
VMateApplyCpuidBrand(
    ULONG TargetProcessId,
    ULONGLONG PartitionHandleValue,
    ULONGLONG ExpectedPartitionId,
    PUCHAR Brand,
    PBOOLEAN ImageMatched,
    PNTSTATUS DuplicateStatus,
    PNTSTATUS ThreadCreateStatus,
    PNTSTATUS ThreadWaitStatus,
    PVMATE_CPUID_THREAD_CONTEXT Result
    )
{
    PEPROCESS process = NULL;
    PVOID fileObject = NULL;
    PCHAR processImage;
    OBJECT_ATTRIBUTES threadAttributes;
    HANDLE processHandle = NULL;
    HANDLE partitionHandle = NULL;
    HANDLE threadHandle = NULL;
    ULONG index;
    NTSTATUS status;

    *ImageMatched = FALSE;
    *DuplicateStatus = STATUS_UNSUCCESSFUL;
    *ThreadCreateStatus = STATUS_UNSUCCESSFUL;
    *ThreadWaitStatus = STATUS_UNSUCCESSFUL;
    Result->FileObject = NULL;
    Result->TargetProcess = NULL;
    Result->ExpectedPartitionId = ExpectedPartitionId;
    Result->QueryStatus = STATUS_UNSUCCESSFUL;
    Result->BufferAllocationStatus = STATUS_UNSUCCESSFUL;
    Result->BufferFreeStatus = STATUS_UNSUCCESSFUL;
    Result->ObservedPartitionId = 0;
    Result->CurrentProcessMatched = 0;
    Result->FastIoAvailable = 0;
    Result->FastIoHandled = 0;
    Result->MutatingCalls = 0;
    Result->RollbackCalls = 0;
    Result->Applied = 0;
    for (index = 0; index < VMATE_BRAND_BYTES; ++index) {
        Result->Brand[index] = Brand[index];
    }
    for (index = 0; index < VMATE_BRAND_LEAF_COUNT; ++index) {
        Result->RegisterStatus[index] = STATUS_UNSUCCESSFUL;
        Result->RollbackStatus[index] = STATUS_NOT_FOUND;
    }

    status = PsLookupProcessByProcessId((HANDLE)(ULONG_PTR)TargetProcessId,
                                        &process);
    if (!NT_SUCCESS(status)) {
        return status;
    }
    processImage = PsGetProcessImageFileName(process);
    *ImageMatched = VMateAsciiEqualsInsensitive(processImage, "vmwp.exe");
    if (!*ImageMatched) {
        ObDereferenceObject(process);
        return VMATE_STATUS_INVALID_IMAGE_FORMAT;
    }
    status = ObOpenObjectByPointer(process,
                                   OBJ_KERNEL_HANDLE,
                                   NULL,
                                   PROCESS_DUP_HANDLE |
                                       VMATE_PROCESS_CREATE_THREAD,
                                   *PsProcessType,
                                   KernelMode,
                                   &processHandle);
    if (!NT_SUCCESS(status)) {
        *DuplicateStatus = status;
        ObDereferenceObject(process);
        return status;
    }
    status = ZwDuplicateObject(
        processHandle,
        (HANDLE)(ULONG_PTR)PartitionHandleValue,
        ZwCurrentProcess(),
        &partitionHandle,
        0,
        OBJ_KERNEL_HANDLE,
        DUPLICATE_SAME_ACCESS);
    *DuplicateStatus = status;
    if (NT_SUCCESS(status)) {
        status = ObReferenceObjectByHandle(partitionHandle,
                                           0,
                                           *IoFileObjectType,
                                           KernelMode,
                                           &fileObject,
                                           NULL);
        ZwClose(partitionHandle);
    }
    if (!NT_SUCCESS(status)) {
        ZwClose(processHandle);
        ObDereferenceObject(process);
        return status;
    }

    Result->FileObject = (PFILE_OBJECT)fileObject;
    Result->TargetProcess = process;
    InitializeObjectAttributes(&threadAttributes,
                               NULL,
                               OBJ_KERNEL_HANDLE,
                               NULL,
                               NULL);
    status = PsCreateSystemThread(&threadHandle,
                                  SYNCHRONIZE,
                                  &threadAttributes,
                                  processHandle,
                                  NULL,
                                  VMateCpuidTargetThread,
                                  Result);
    *ThreadCreateStatus = status;
    if (NT_SUCCESS(status)) {
        status = ZwWaitForSingleObject(threadHandle, FALSE, NULL);
        *ThreadWaitStatus = status;
        ZwClose(threadHandle);
        if (NT_SUCCESS(status)) {
            status = Result->Applied != 0 ?
                STATUS_SUCCESS : Result->QueryStatus;
            if (NT_SUCCESS(status)) {
                for (index = 0;
                     index < VMATE_BRAND_LEAF_COUNT;
                     ++index) {
                    if (!NT_SUCCESS(Result->RegisterStatus[index])) {
                        status = Result->RegisterStatus[index];
                        break;
                    }
                }
            }
        }
    }
    ObDereferenceObject(fileObject);
    ZwClose(processHandle);
    ObDereferenceObject(process);
    return status;
}

NTSTATUS
NTAPI
DriverEntry(
    PDRIVER_OBJECT DriverObject,
    PUNICODE_STRING RegistryPath
    )
{
    HANDLE parametersKey = NULL;
    ULONGLONG targetProcessIdValue = 0;
    ULONGLONG partitionHandleValue = 0;
    ULONGLONG expectedPartitionId = 0;
    UCHAR brand[VMATE_BRAND_BYTES];
    VMATE_CPUID_THREAD_CONTEXT result;
    BOOLEAN imageMatched = FALSE;
    NTSTATUS duplicateStatus = STATUS_UNSUCCESSFUL;
    NTSTATUS threadCreateStatus = STATUS_UNSUCCESSFUL;
    NTSTATUS threadWaitStatus = STATUS_UNSUCCESSFUL;
    NTSTATUS inputStatus;
    NTSTATUS applyStatus;

    UNREFERENCED_PARAMETER(DriverObject);
    inputStatus = VMateOpenParametersKey(RegistryPath, &parametersKey);
    if (!NT_SUCCESS(inputStatus)) {
        return inputStatus;
    }
    (VOID)VMateWriteRegistryDword(parametersKey, L"Completed", 0);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"ContractVersion",
                                  VMATE_CONTRACT_VERSION);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"ResidentAfterApply",
                                  0);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"WhitelistedLeafCount",
                                  VMATE_BRAND_LEAF_COUNT);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"AlwaysOverride",
                                  VMATE_CPUID_ALWAYS_OVERRIDE);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"RuntimeModelSwitch",
                                  0);

    inputStatus = VMateReadRegistryInteger(parametersKey,
                                           L"TargetProcessId",
                                           REG_DWORD,
                                           &targetProcessIdValue);
    if (NT_SUCCESS(inputStatus)) {
        inputStatus = VMateReadRegistryInteger(parametersKey,
                                               L"PartitionHandle",
                                               REG_QWORD,
                                               &partitionHandleValue);
    }
    if (NT_SUCCESS(inputStatus)) {
        inputStatus = VMateReadRegistryInteger(parametersKey,
                                               L"ExpectedPartitionId",
                                               REG_QWORD,
                                               &expectedPartitionId);
    }
    if (NT_SUCCESS(inputStatus)) {
        inputStatus = VMateReadRegistryBrand(parametersKey, brand);
    }
    if (NT_SUCCESS(inputStatus) &&
        (targetProcessIdValue == 0 ||
         targetProcessIdValue > MAXULONG ||
         partitionHandleValue == 0 ||
         expectedPartitionId == 0)) {
        inputStatus = STATUS_INVALID_PARAMETER;
    }

    applyStatus = inputStatus;
    if (NT_SUCCESS(inputStatus)) {
        applyStatus = VMateApplyCpuidBrand(
            (ULONG)targetProcessIdValue,
            partitionHandleValue,
            expectedPartitionId,
            brand,
            &imageMatched,
            &duplicateStatus,
            &threadCreateStatus,
            &threadWaitStatus,
            &result);
    }
    else {
        ULONG index;

        result.QueryStatus = STATUS_UNSUCCESSFUL;
        result.BufferAllocationStatus = STATUS_UNSUCCESSFUL;
        result.BufferFreeStatus = STATUS_UNSUCCESSFUL;
        result.ObservedPartitionId = 0;
        result.CurrentProcessMatched = 0;
        result.FastIoAvailable = 0;
        result.FastIoHandled = 0;
        result.MutatingCalls = 0;
        result.RollbackCalls = 0;
        result.Applied = 0;
        for (index = 0; index < VMATE_BRAND_LEAF_COUNT; ++index) {
            result.RegisterStatus[index] = STATUS_UNSUCCESSFUL;
            result.RollbackStatus[index] = STATUS_NOT_FOUND;
        }
    }

    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"InputNtStatus",
                                  (ULONG)inputStatus);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"ApplyNtStatus",
                                  (ULONG)applyStatus);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"ImageMatched",
                                  imageMatched ? 1u : 0u);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"DuplicateNtStatus",
                                  (ULONG)duplicateStatus);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"ThreadCreateNtStatus",
                                  (ULONG)threadCreateStatus);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"ThreadWaitNtStatus",
                                  (ULONG)threadWaitStatus);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"CurrentProcessMatched",
                                  result.CurrentProcessMatched);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"PartitionQueryNtStatus",
                                  (ULONG)result.QueryStatus);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"BufferAllocationNtStatus",
                                  (ULONG)result.BufferAllocationStatus);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"BufferFreeNtStatus",
                                  (ULONG)result.BufferFreeStatus);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"FastIoAvailable",
                                  result.FastIoAvailable);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"FastIoHandled",
                                  result.FastIoHandled);
    (VOID)VMateWriteRegistryQword(parametersKey,
                                  L"ObservedPartitionId",
                                  result.ObservedPartitionId);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"RegisterLeaf80000002NtStatus",
                                  (ULONG)result.RegisterStatus[0]);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"RegisterLeaf80000003NtStatus",
                                  (ULONG)result.RegisterStatus[1]);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"RegisterLeaf80000004NtStatus",
                                  (ULONG)result.RegisterStatus[2]);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"RollbackLeaf80000002NtStatus",
                                  (ULONG)result.RollbackStatus[0]);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"RollbackLeaf80000003NtStatus",
                                  (ULONG)result.RollbackStatus[1]);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"RollbackLeaf80000004NtStatus",
                                  (ULONG)result.RollbackStatus[2]);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"MutatingCalls",
                                  result.MutatingCalls);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"RollbackCalls",
                                  result.RollbackCalls);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"Applied",
                                  result.Applied);
    (VOID)VMateWriteRegistryDword(parametersKey, L"Completed", 1);
    ZwClose(parametersKey);

    return STATUS_UNSUCCESSFUL;
}
