#include <Uefi.h>

#include <IndustryStandard/SmBios.h>
#include <Library/BaseMemoryLib.h>
#include <Library/MemoryAllocationLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Protocol/Smbios.h>

#include "SmbiosIdentity.h"

#define VMATE_MAX_SMBIOS_TARGETS 128
#define VMATE_MAX_SMBIOS_RECORD_SIZE (64 * 1024)

typedef struct {
  EFI_SMBIOS_HANDLE Handle;
  EFI_SMBIOS_TYPE Type;
  UINT8 Strings[9];
  BOOLEAN Populated;
} VMATE_SMBIOS_TARGET;

STATIC
UINTN
GetRecordSize (
  IN CONST EFI_SMBIOS_TABLE_HEADER *Record
  )
{
  CONST UINT8 *Cursor;
  CONST UINT8 *Start;

  Start = (CONST UINT8 *)Record;
  Cursor = Start + Record->Length;
  while ((UINTN)(Cursor - Start) < (VMATE_MAX_SMBIOS_RECORD_SIZE - 1)) {
    if ((Cursor[0] == 0) && (Cursor[1] == 0)) {
      return (UINTN)(Cursor + 2 - Start);
    }
    ++Cursor;
  }
  return 0;
}

STATIC
EFI_STATUS
FindRecord (
  IN EFI_SMBIOS_PROTOCOL *Smbios,
  IN EFI_SMBIOS_HANDLE Wanted,
  OUT EFI_SMBIOS_TABLE_HEADER **Record
  )
{
  EFI_SMBIOS_HANDLE Handle;
  EFI_STATUS Status;

  Handle = SMBIOS_HANDLE_PI_RESERVED;
  do {
    Status = Smbios->GetNext (Smbios, &Handle, NULL, Record, NULL);
    if (EFI_ERROR (Status)) { return Status; }
  } while (Handle != Wanted);
  return EFI_SUCCESS;
}

STATIC
EFI_STATUS
ReplaceNumericFields (
  IN EFI_SMBIOS_PROTOCOL *Smbios,
  IN CONST VMATE_IDENTITY_CONFIG *Config,
  IN CONST VMATE_SMBIOS_TARGET *Target,
  OUT BOOLEAN *Replaced
  )
{
  EFI_SMBIOS_TABLE_HEADER *Record;
  EFI_SMBIOS_TABLE_HEADER *Original;
  EFI_SMBIOS_TABLE_HEADER *Modified;
  EFI_SMBIOS_HANDLE Handle;
  EFI_STATUS Status;
  UINTN Size;
  BOOLEAN Changed;

  *Replaced = FALSE;
  if ((Target->Type != SMBIOS_TYPE_SYSTEM_ENCLOSURE) &&
      (Target->Type != SMBIOS_TYPE_MEMORY_DEVICE)) {
    return EFI_SUCCESS;
  }
  Status = FindRecord (Smbios, Target->Handle, &Record);
  if (EFI_ERROR (Status)) { return Status; }
  Size = GetRecordSize (Record);
  if (Size == 0) { return EFI_COMPROMISED_DATA; }
  Original = AllocateCopyPool (Size, Record);
  Modified = AllocateCopyPool (Size, Record);
  if ((Original == NULL) || (Modified == NULL)) {
    if (Original != NULL) { FreePool (Original); }
    if (Modified != NULL) { FreePool (Modified); }
    return EFI_OUT_OF_RESOURCES;
  }

  Changed = FALSE;
  if ((Target->Type == SMBIOS_TYPE_SYSTEM_ENCLOSURE) &&
      (Record->Length > OFFSET_OF (SMBIOS_TABLE_TYPE3, Type))) {
    SMBIOS_TABLE_TYPE3 *Type3;
    UINT8 NewType;

    Type3 = (SMBIOS_TABLE_TYPE3 *)Modified;
    NewType = (UINT8)((Type3->Type & 0x80) | (Config->ChassisType & 0x7f));
    Changed = (Type3->Type != NewType);
    Type3->Type = NewType;
  } else if ((Target->Type == SMBIOS_TYPE_MEMORY_DEVICE) &&
             Target->Populated) {
    SMBIOS_TABLE_TYPE17 *Type17;

    Type17 = (SMBIOS_TABLE_TYPE17 *)Modified;
    if (Record->Length > OFFSET_OF (SMBIOS_TABLE_TYPE17, MemoryType)) {
      Changed = Changed || (Type17->MemoryType != Config->MemoryType);
      Type17->MemoryType = Config->MemoryType;
    }
    if (Record->Length >= (OFFSET_OF (SMBIOS_TABLE_TYPE17, Speed) +
                           sizeof (Type17->Speed))) {
      Changed = Changed || (Type17->Speed != Config->MemorySpeed);
      Type17->Speed = Config->MemorySpeed;
    }
    if (Record->Length >=
        (OFFSET_OF (SMBIOS_TABLE_TYPE17, ConfiguredMemoryClockSpeed) +
         sizeof (Type17->ConfiguredMemoryClockSpeed))) {
      Changed = Changed ||
        (Type17->ConfiguredMemoryClockSpeed != Config->MemoryConfiguredSpeed);
      Type17->ConfiguredMemoryClockSpeed = Config->MemoryConfiguredSpeed;
    }
  }

  if (!Changed) {
    FreePool (Original);
    FreePool (Modified);
    return EFI_SUCCESS;
  }
  Status = Smbios->Remove (Smbios, Target->Handle);
  if (!EFI_ERROR (Status)) {
    Handle = Target->Handle;
    Status = Smbios->Add (Smbios, NULL, &Handle, Modified);
    if (EFI_ERROR (Status)) {
      Handle = Target->Handle;
      Smbios->Add (Smbios, NULL, &Handle, Original);
    } else {
      *Replaced = TRUE;
    }
  }
  FreePool (Original);
  FreePool (Modified);
  return Status;
}

STATIC
VOID
SaveStringIndices (
  IN CONST EFI_SMBIOS_TABLE_HEADER *Record,
  OUT VMATE_SMBIOS_TARGET *Target
  )
{
  SetMem (Target->Strings, sizeof (Target->Strings), 0);
  Target->Populated = TRUE;
  switch (Record->Type) {
    case SMBIOS_TYPE_BIOS_INFORMATION: {
      CONST SMBIOS_TABLE_TYPE0 *Value = (CONST SMBIOS_TABLE_TYPE0 *)Record;
      Target->Strings[0] = Value->Vendor;
      Target->Strings[1] = Value->BiosVersion;
      Target->Strings[2] = Value->BiosReleaseDate;
      break;
    }
    case SMBIOS_TYPE_SYSTEM_INFORMATION: {
      CONST SMBIOS_TABLE_TYPE1 *Value = (CONST SMBIOS_TABLE_TYPE1 *)Record;
      Target->Strings[0] = Value->Manufacturer;
      Target->Strings[1] = Value->ProductName;
      Target->Strings[2] = Value->Version;
      Target->Strings[3] = Value->SerialNumber;
      Target->Strings[4] = Value->SKUNumber;
      Target->Strings[5] = Value->Family;
      break;
    }
    case SMBIOS_TYPE_BASEBOARD_INFORMATION: {
      CONST SMBIOS_TABLE_TYPE2 *Value = (CONST SMBIOS_TABLE_TYPE2 *)Record;
      Target->Strings[0] = Value->Manufacturer;
      Target->Strings[1] = Value->ProductName;
      Target->Strings[2] = Value->Version;
      Target->Strings[3] = Value->SerialNumber;
      Target->Strings[4] = Value->AssetTag;
      break;
    }
    case SMBIOS_TYPE_SYSTEM_ENCLOSURE: {
      CONST SMBIOS_TABLE_TYPE3 *Value = (CONST SMBIOS_TABLE_TYPE3 *)Record;
      Target->Strings[0] = Value->Manufacturer;
      Target->Strings[1] = Value->Version;
      Target->Strings[2] = Value->SerialNumber;
      Target->Strings[3] = Value->AssetTag;
      break;
    }
    case SMBIOS_TYPE_PROCESSOR_INFORMATION: {
      CONST SMBIOS_TABLE_TYPE4 *Value = (CONST SMBIOS_TABLE_TYPE4 *)Record;
      Target->Strings[0] = Value->ProcessorManufacturer;
      Target->Strings[1] = Value->ProcessorVersion;
      Target->Strings[2] = Value->SerialNumber;
      Target->Strings[3] = Value->AssetTag;
      Target->Strings[4] = Value->PartNumber;
      break;
    }
    case SMBIOS_TYPE_MEMORY_DEVICE: {
      CONST SMBIOS_TABLE_TYPE17 *Value = (CONST SMBIOS_TABLE_TYPE17 *)Record;
      Target->Populated = (Value->Size != 0);
      Target->Strings[0] = Value->Manufacturer;
      Target->Strings[1] = Value->SerialNumber;
      Target->Strings[2] = Value->AssetTag;
      Target->Strings[3] = Value->PartNumber;
      break;
    }
    default:
      break;
  }
}

STATIC
VOID
UpdateOneString (
  IN EFI_SMBIOS_PROTOCOL *Smbios,
  IN EFI_SMBIOS_HANDLE Handle,
  IN UINT8 Index,
  IN CONST CHAR8 *Value,
  IN OUT VMATE_SMBIOS_RESULT *Result
  )
{
  UINTN Number;
  EFI_STATUS Status;

  if (Index == 0) {
    ++Result->UpdateErrors;
    return;
  }
  Number = Index;
  Status = Smbios->UpdateString (Smbios, &Handle, &Number, (CHAR8 *)Value);
  if (EFI_ERROR (Status)) {
    ++Result->UpdateErrors;
  } else {
    ++Result->StringsUpdated;
  }
}

#define UPDATE(Target, Slot, Field) \
  UpdateOneString (Smbios, (Target)->Handle, (Target)->Strings[(Slot)], \
                   Config->Field, Result)

STATIC
VOID
UpdateTargetStrings (
  IN EFI_SMBIOS_PROTOCOL *Smbios,
  IN CONST VMATE_IDENTITY_CONFIG *Config,
  IN CONST VMATE_SMBIOS_TARGET *Target,
  IN OUT VMATE_SMBIOS_RESULT *Result
  )
{
  if (!Target->Populated) { return; }
  switch (Target->Type) {
    case SMBIOS_TYPE_BIOS_INFORMATION:
      UPDATE (Target, 0, BiosVendor);
      UPDATE (Target, 1, BiosVersion);
      UPDATE (Target, 2, BiosDate);
      break;
    case SMBIOS_TYPE_SYSTEM_INFORMATION:
      UPDATE (Target, 0, SystemManufacturer);
      UPDATE (Target, 1, SystemProduct);
      UPDATE (Target, 2, SystemVersion);
      UPDATE (Target, 3, SystemSerial);
      UPDATE (Target, 4, SystemSku);
      UPDATE (Target, 5, SystemFamily);
      break;
    case SMBIOS_TYPE_BASEBOARD_INFORMATION:
      UPDATE (Target, 0, BoardManufacturer);
      UPDATE (Target, 1, BoardProduct);
      UPDATE (Target, 2, BoardVersion);
      UPDATE (Target, 3, BoardSerial);
      UPDATE (Target, 4, BoardAsset);
      break;
    case SMBIOS_TYPE_SYSTEM_ENCLOSURE:
      UPDATE (Target, 0, ChassisManufacturer);
      UPDATE (Target, 1, ChassisVersion);
      UPDATE (Target, 2, ChassisSerial);
      UPDATE (Target, 3, ChassisAsset);
      break;
    case SMBIOS_TYPE_PROCESSOR_INFORMATION:
      UPDATE (Target, 0, CpuManufacturer);
      UPDATE (Target, 1, CpuVersion);
      UPDATE (Target, 2, CpuSerial);
      UPDATE (Target, 3, CpuAsset);
      UPDATE (Target, 4, CpuPart);
      break;
    case SMBIOS_TYPE_MEMORY_DEVICE:
      UPDATE (Target, 0, MemoryManufacturer);
      UPDATE (Target, 1, MemorySerial);
      UPDATE (Target, 2, MemoryAsset);
      UPDATE (Target, 3, MemoryPart);
      break;
    default:
      break;
  }
}

EFI_STATUS
VMateApplySmbiosIdentity (
  IN CONST VMATE_IDENTITY_CONFIG *Config,
  OUT VMATE_SMBIOS_RESULT *Result
  )
{
  EFI_SMBIOS_PROTOCOL *Smbios;
  EFI_SMBIOS_TABLE_HEADER *Record;
  EFI_SMBIOS_HANDLE Handle;
  VMATE_SMBIOS_TARGET Targets[VMATE_MAX_SMBIOS_TARGETS];
  UINTN Count;
  UINTN Index;
  EFI_STATUS Status;
  BOOLEAN Replaced;

  if ((Config == NULL) || (Result == NULL)) { return EFI_INVALID_PARAMETER; }
  SetMem (Result, sizeof (*Result), 0);
  SetMem (Targets, sizeof (Targets), 0);
  Status = gBS->LocateProtocol (&gEfiSmbiosProtocolGuid, NULL, (VOID **)&Smbios);
  if (EFI_ERROR (Status)) { return Status; }

  Count = 0;
  Handle = SMBIOS_HANDLE_PI_RESERVED;
  while (!EFI_ERROR (Smbios->GetNext (Smbios, &Handle, NULL, &Record, NULL))) {
    ++Result->RecordsVisited;
    if ((Record->Type != SMBIOS_TYPE_BIOS_INFORMATION) &&
        (Record->Type != SMBIOS_TYPE_SYSTEM_INFORMATION) &&
        (Record->Type != SMBIOS_TYPE_BASEBOARD_INFORMATION) &&
        (Record->Type != SMBIOS_TYPE_SYSTEM_ENCLOSURE) &&
        (Record->Type != SMBIOS_TYPE_PROCESSOR_INFORMATION) &&
        (Record->Type != SMBIOS_TYPE_MEMORY_DEVICE)) {
      continue;
    }
    if (Count >= VMATE_MAX_SMBIOS_TARGETS) { return EFI_OUT_OF_RESOURCES; }
    Targets[Count].Handle = Handle;
    Targets[Count].Type = Record->Type;
    SaveStringIndices (Record, &Targets[Count]);
    ++Count;
  }

  for (Index = 0; Index < Count; ++Index) {
    Status = ReplaceNumericFields (Smbios, Config, &Targets[Index], &Replaced);
    if (EFI_ERROR (Status)) {
      ++Result->UpdateErrors;
      continue;
    }
    if (Replaced) { ++Result->RecordsReplaced; }
    UpdateTargetStrings (Smbios, Config, &Targets[Index], Result);
  }
  return (Result->UpdateErrors == 0) ? EFI_SUCCESS : EFI_DEVICE_ERROR;
}
