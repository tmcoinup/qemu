/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * One-shot, read-only VID process-context probe for an authorized Hyper-V lab.
 *
 * The driver reads one vmwp.exe PID and one existing partition-handle value
 * from its service Parameters key.  During DriverEntry it creates one transient
 * kernel-mode thread associated with that worker process, issues only
 * VidGetHvPartitionId's inbox read-only IOCTL, waits for the thread to exit,
 * writes the result back to the Parameters key, and exposes no device or
 * user-controlled IOCTL surface.  It never registers CPUID results.
 */

#define _AMD64_
#define AMD64
#define NTDDI_VERSION 0x0A000000

#include <ntddk.h>
#include <ntifs.h>

#define VMATE_CONTRACT_VERSION 5u
#define VMATE_VID_GET_HV_PARTITION_ID_IOCTL 0x002210afu
#define VMATE_MAX_SERVICE_PATH_BYTES 1000u
#define VMATE_PROCESS_CREATE_THREAD 0x0002u

#define VMATE_STATUS_INVALID_IMAGE_FORMAT ((NTSTATUS)0xC000007BL)

DRIVER_INITIALIZE DriverEntry;

NTKERNELAPI
PCHAR
NTAPI
PsGetProcessImageFileName(
    PEPROCESS Process
    );

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
VMateIssuePartitionIdQuery(
    HANDLE PartitionHandle,
    PULONGLONG PartitionId
    )
{
    KEVENT event;
    IO_STATUS_BLOCK ioStatus;
    NTSTATUS status;

    *PartitionId = 0;
    KeInitializeEvent(&event, NotificationEvent, FALSE);
    ioStatus.Status = STATUS_UNSUCCESSFUL;
    ioStatus.Information = 0;
    status = ZwDeviceIoControlFile(
        PartitionHandle,
        &event,
        NULL,
        NULL,
        &ioStatus,
        VMATE_VID_GET_HV_PARTITION_ID_IOCTL,
        NULL,
        0,
        PartitionId,
        sizeof(*PartitionId));
    if (status == STATUS_PENDING) {
        status = KeWaitForSingleObject(&event,
                                       Executive,
                                       KernelMode,
                                       FALSE,
                                       NULL);
        if (NT_SUCCESS(status)) {
            status = ioStatus.Status;
        }
    } else if (NT_SUCCESS(status)) {
        status = ioStatus.Status;
    }
    return status;
}

typedef struct _VMATE_TARGET_THREAD_CONTEXT {
    HANDLE PartitionHandle;
    PFILE_OBJECT FileObject;
    PEPROCESS TargetProcess;
    NTSTATUS QueryStatus;
    NTSTATUS RawHandleQueryStatus;
    NTSTATUS BufferAllocationStatus;
    NTSTATUS FastIoQueryStatus;
    NTSTATUS BufferFreeStatus;
    ULONG CurrentProcessMatched;
    ULONG FastIoAvailable;
    ULONG FastIoHandled;
    ULONGLONG PartitionId;
} VMATE_TARGET_THREAD_CONTEXT, *PVMATE_TARGET_THREAD_CONTEXT;

static VOID
VMateTargetProcessThread(
    PVOID StartContext
    )
{
    PVMATE_TARGET_THREAD_CONTEXT context =
        (PVMATE_TARGET_THREAD_CONTEXT)StartContext;
    PDEVICE_OBJECT deviceObject = NULL;
    PFAST_IO_DISPATCH fastIoDispatch = NULL;
    IO_STATUS_BLOCK ioStatus;
    PVOID outputBuffer = NULL;
    SIZE_T regionSize = sizeof(ULONGLONG);
    SIZE_T freeSize = 0;
    ULONGLONG rawPartitionId = 0;
    BOOLEAN handled = FALSE;

    context->CurrentProcessMatched =
        PsGetCurrentProcess() == context->TargetProcess ? 1u : 0u;
    context->RawHandleQueryStatus = VMateIssuePartitionIdQuery(
        context->PartitionHandle,
        &rawPartitionId);
    if (NT_SUCCESS(context->RawHandleQueryStatus)) {
        context->PartitionId = rawPartitionId;
        context->QueryStatus = context->RawHandleQueryStatus;
        PsTerminateSystemThread(STATUS_SUCCESS);
    }

    context->QueryStatus = context->RawHandleQueryStatus;
    if (context->FileObject == NULL) {
        PsTerminateSystemThread(STATUS_SUCCESS);
    }
    deviceObject = IoGetRelatedDeviceObject(context->FileObject);
    if (deviceObject == NULL || deviceObject->DriverObject == NULL) {
        context->FastIoQueryStatus = STATUS_INVALID_DEVICE_STATE;
        context->QueryStatus = context->FastIoQueryStatus;
        PsTerminateSystemThread(STATUS_SUCCESS);
    }
    fastIoDispatch = deviceObject->DriverObject->FastIoDispatch;
    if (fastIoDispatch == NULL ||
        fastIoDispatch->SizeOfFastIoDispatch <
            FIELD_OFFSET(FAST_IO_DISPATCH, FastIoDeviceControl) +
                sizeof(PFAST_IO_DEVICE_CONTROL) ||
        fastIoDispatch->FastIoDeviceControl == NULL) {
        context->FastIoQueryStatus = STATUS_NOT_SUPPORTED;
        context->QueryStatus = context->FastIoQueryStatus;
        PsTerminateSystemThread(STATUS_SUCCESS);
    }
    context->FastIoAvailable = 1u;

    context->BufferAllocationStatus = ZwAllocateVirtualMemory(
        ZwCurrentProcess(),
        &outputBuffer,
        0,
        &regionSize,
        MEM_RESERVE | MEM_COMMIT,
        PAGE_READWRITE);
    if (!NT_SUCCESS(context->BufferAllocationStatus)) {
        context->FastIoQueryStatus = context->BufferAllocationStatus;
        context->QueryStatus = context->FastIoQueryStatus;
        PsTerminateSystemThread(STATUS_SUCCESS);
    }

    ioStatus.Status = STATUS_UNSUCCESSFUL;
    ioStatus.Information = 0;
    handled = fastIoDispatch->FastIoDeviceControl(
        context->FileObject,
        TRUE,
        NULL,
        0,
        outputBuffer,
        sizeof(ULONGLONG),
        VMATE_VID_GET_HV_PARTITION_ID_IOCTL,
        &ioStatus,
        deviceObject);
    context->FastIoHandled = handled ? 1u : 0u;
    context->FastIoQueryStatus = handled ?
        ioStatus.Status : STATUS_NOT_SUPPORTED;
    context->QueryStatus = context->FastIoQueryStatus;
    if (NT_SUCCESS(context->FastIoQueryStatus)) {
        context->PartitionId =
            *(volatile ULONGLONG *)outputBuffer;
    }
    context->BufferFreeStatus = ZwFreeVirtualMemory(
        ZwCurrentProcess(),
        &outputBuffer,
        &freeSize,
        MEM_RELEASE);
    PsTerminateSystemThread(STATUS_SUCCESS);
}

static NTSTATUS
VMateQueryPartitionIdInWorkerContext(
    ULONG TargetProcessId,
    ULONGLONG PartitionHandleValue,
    PBOOLEAN ImageMatched,
    PNTSTATUS DuplicateStatus,
    PNTSTATUS SystemContextQueryStatus,
    PNTSTATUS KernelHandleStatus,
    PNTSTATUS AttachedContextQueryStatus,
    PNTSTATUS TargetThreadCreateStatus,
    PNTSTATUS TargetThreadWaitStatus,
    PNTSTATUS TargetThreadRawHandleQueryStatus,
    PNTSTATUS TargetBufferAllocationStatus,
    PNTSTATUS TargetFastIoQueryStatus,
    PNTSTATUS TargetBufferFreeStatus,
    PULONG TargetCurrentProcessMatched,
    PULONG TargetFastIoAvailable,
    PULONG TargetFastIoHandled,
    PULONGLONG PartitionId
    )
{
    PEPROCESS process = NULL;
    PVOID fileObject = NULL;
    PCHAR processImage;
    KAPC_STATE apcState;
    OBJECT_ATTRIBUTES threadAttributes;
    VMATE_TARGET_THREAD_CONTEXT threadContext;
    HANDLE processHandle = NULL;
    HANDLE partitionHandle = NULL;
    HANDLE kernelPartitionHandle = NULL;
    HANDLE threadHandle = NULL;
    ULONGLONG systemPartitionId = 0;
    NTSTATUS status;

    *ImageMatched = FALSE;
    *DuplicateStatus = STATUS_UNSUCCESSFUL;
    *SystemContextQueryStatus = STATUS_UNSUCCESSFUL;
    *KernelHandleStatus = STATUS_UNSUCCESSFUL;
    *AttachedContextQueryStatus = STATUS_UNSUCCESSFUL;
    *TargetThreadCreateStatus = STATUS_UNSUCCESSFUL;
    *TargetThreadWaitStatus = STATUS_UNSUCCESSFUL;
    *TargetThreadRawHandleQueryStatus = STATUS_UNSUCCESSFUL;
    *TargetBufferAllocationStatus = STATUS_UNSUCCESSFUL;
    *TargetFastIoQueryStatus = STATUS_UNSUCCESSFUL;
    *TargetBufferFreeStatus = STATUS_UNSUCCESSFUL;
    *TargetCurrentProcessMatched = 0;
    *TargetFastIoAvailable = 0;
    *TargetFastIoHandled = 0;
    *PartitionId = 0;
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
        *SystemContextQueryStatus = VMateIssuePartitionIdQuery(
            partitionHandle, &systemPartitionId);
        status = ObReferenceObjectByHandle(partitionHandle,
                                           0,
                                           *IoFileObjectType,
                                           KernelMode,
                                           &fileObject,
                                           NULL);
        if (NT_SUCCESS(status)) {
            status = ObOpenObjectByPointer(fileObject,
                                           OBJ_KERNEL_HANDLE,
                                           NULL,
                                           0,
                                           *IoFileObjectType,
                                           KernelMode,
                                           &kernelPartitionHandle);
        }
        *KernelHandleStatus = status;
        ZwClose(partitionHandle);
        if (NT_SUCCESS(status)) {
            KeStackAttachProcess((PKPROCESS)process, &apcState);
            *AttachedContextQueryStatus = VMateIssuePartitionIdQuery(
                kernelPartitionHandle,
                &systemPartitionId);
            KeUnstackDetachProcess(&apcState);
            ZwClose(kernelPartitionHandle);
        }
    }

    threadContext.PartitionHandle =
        (HANDLE)(ULONG_PTR)PartitionHandleValue;
    threadContext.FileObject = (PFILE_OBJECT)fileObject;
    threadContext.TargetProcess = process;
    threadContext.QueryStatus = STATUS_UNSUCCESSFUL;
    threadContext.RawHandleQueryStatus = STATUS_UNSUCCESSFUL;
    threadContext.BufferAllocationStatus = STATUS_UNSUCCESSFUL;
    threadContext.FastIoQueryStatus = STATUS_UNSUCCESSFUL;
    threadContext.BufferFreeStatus = STATUS_UNSUCCESSFUL;
    threadContext.CurrentProcessMatched = 0;
    threadContext.FastIoAvailable = 0;
    threadContext.FastIoHandled = 0;
    threadContext.PartitionId = 0;
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
                                  VMateTargetProcessThread,
                                  &threadContext);
    *TargetThreadCreateStatus = status;
    if (NT_SUCCESS(status)) {
        status = ZwWaitForSingleObject(threadHandle, FALSE, NULL);
        *TargetThreadWaitStatus = status;
        ZwClose(threadHandle);
        if (NT_SUCCESS(status)) {
            status = threadContext.QueryStatus;
            *PartitionId = threadContext.PartitionId;
        }
        *TargetThreadRawHandleQueryStatus =
            threadContext.RawHandleQueryStatus;
        *TargetBufferAllocationStatus =
            threadContext.BufferAllocationStatus;
        *TargetFastIoQueryStatus = threadContext.FastIoQueryStatus;
        *TargetBufferFreeStatus = threadContext.BufferFreeStatus;
        *TargetCurrentProcessMatched =
            threadContext.CurrentProcessMatched;
        *TargetFastIoAvailable = threadContext.FastIoAvailable;
        *TargetFastIoHandled = threadContext.FastIoHandled;
    }
    if (fileObject != NULL) {
        ObDereferenceObject(fileObject);
    }
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
    ULONGLONG partitionId = 0;
    BOOLEAN imageMatched = FALSE;
    NTSTATUS inputStatus;
    NTSTATUS duplicateStatus = STATUS_UNSUCCESSFUL;
    NTSTATUS systemContextQueryStatus = STATUS_UNSUCCESSFUL;
    NTSTATUS kernelHandleStatus = STATUS_UNSUCCESSFUL;
    NTSTATUS attachedContextQueryStatus = STATUS_UNSUCCESSFUL;
    NTSTATUS targetThreadCreateStatus = STATUS_UNSUCCESSFUL;
    NTSTATUS targetThreadWaitStatus = STATUS_UNSUCCESSFUL;
    NTSTATUS targetThreadRawHandleQueryStatus = STATUS_UNSUCCESSFUL;
    NTSTATUS targetBufferAllocationStatus = STATUS_UNSUCCESSFUL;
    NTSTATUS targetFastIoQueryStatus = STATUS_UNSUCCESSFUL;
    NTSTATUS targetBufferFreeStatus = STATUS_UNSUCCESSFUL;
    ULONG targetCurrentProcessMatched = 0;
    ULONG targetFastIoAvailable = 0;
    ULONG targetFastIoHandled = 0;
    NTSTATUS queryStatus;

    UNREFERENCED_PARAMETER(DriverObject);
    inputStatus = VMateOpenParametersKey(RegistryPath, &parametersKey);
    if (!NT_SUCCESS(inputStatus)) {
        return inputStatus;
    }

    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"Completed",
                                  0);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"ContractVersion",
                                  VMATE_CONTRACT_VERSION);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"MutatingCalls",
                                  0);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"ResidentAfterProbe",
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
    if (NT_SUCCESS(inputStatus) &&
        (targetProcessIdValue == 0 ||
         targetProcessIdValue > MAXULONG ||
         partitionHandleValue == 0)) {
        inputStatus = STATUS_INVALID_PARAMETER;
    }

    queryStatus = inputStatus;
    if (NT_SUCCESS(inputStatus)) {
        queryStatus = VMateQueryPartitionIdInWorkerContext(
            (ULONG)targetProcessIdValue,
            partitionHandleValue,
            &imageMatched,
            &duplicateStatus,
            &systemContextQueryStatus,
            &kernelHandleStatus,
            &attachedContextQueryStatus,
            &targetThreadCreateStatus,
            &targetThreadWaitStatus,
            &targetThreadRawHandleQueryStatus,
            &targetBufferAllocationStatus,
            &targetFastIoQueryStatus,
            &targetBufferFreeStatus,
            &targetCurrentProcessMatched,
            &targetFastIoAvailable,
            &targetFastIoHandled,
            &partitionId);
    }

    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"InputNtStatus",
                                  (ULONG)inputStatus);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"ImageMatched",
                                  imageMatched ? 1u : 0u);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"DuplicateNtStatus",
                                  (ULONG)duplicateStatus);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"SystemContextQueryNtStatus",
                                  (ULONG)systemContextQueryStatus);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"KernelHandleNtStatus",
                                  (ULONG)kernelHandleStatus);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"AttachedContextQueryNtStatus",
                                  (ULONG)attachedContextQueryStatus);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"TargetThreadCreateNtStatus",
                                  (ULONG)targetThreadCreateStatus);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"TargetThreadWaitNtStatus",
                                  (ULONG)targetThreadWaitStatus);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"TargetThreadRawHandleQueryNtStatus",
                                  (ULONG)targetThreadRawHandleQueryStatus);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"TargetBufferAllocationNtStatus",
                                  (ULONG)targetBufferAllocationStatus);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"TargetFastIoQueryNtStatus",
                                  (ULONG)targetFastIoQueryStatus);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"TargetBufferFreeNtStatus",
                                  (ULONG)targetBufferFreeStatus);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"TargetCurrentProcessMatched",
                                  targetCurrentProcessMatched);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"TargetFastIoAvailable",
                                  targetFastIoAvailable);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"TargetFastIoHandled",
                                  targetFastIoHandled);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"QueryNtStatus",
                                  (ULONG)queryStatus);
    (VOID)VMateWriteRegistryQword(parametersKey,
                                  L"PartitionId",
                                  partitionId);
    (VOID)VMateWriteRegistryDword(parametersKey,
                                  L"Completed",
                                  1);
    ZwClose(parametersKey);

    /*
     * Deliberately fail DriverEntry after persisting the one-shot result so
     * the I/O manager immediately releases the image.  The caller accepts
     * this only when the complete v5 non-resident result is present.
     */
    return STATUS_UNSUCCESSFUL;
}
