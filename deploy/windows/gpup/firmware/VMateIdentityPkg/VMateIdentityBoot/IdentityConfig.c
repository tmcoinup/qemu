#include <Uefi.h>

#include <Library/BaseLib.h>
#include <Library/BaseMemoryLib.h>
#include <Library/MemoryAllocationLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Protocol/LoadedImage.h>
#include <Protocol/SimpleFileSystem.h>

#include "IdentityConfig.h"

#define VMATE_CONFIG_MAX_BYTES (32 * 1024)

typedef struct {
  CONST CHAR8 *Name;
  UINTN Offset;
} VMATE_STRING_FIELD;

#define VMATE_STRING_ENTRY(Field) { #Field, OFFSET_OF (VMATE_IDENTITY_CONFIG, Field) }

STATIC CONST VMATE_STRING_FIELD mStringFields[] = {
  VMATE_STRING_ENTRY (BiosVendor),
  VMATE_STRING_ENTRY (BiosVersion),
  VMATE_STRING_ENTRY (BiosDate),
  VMATE_STRING_ENTRY (SystemManufacturer),
  VMATE_STRING_ENTRY (SystemProduct),
  VMATE_STRING_ENTRY (SystemVersion),
  VMATE_STRING_ENTRY (SystemSerial),
  VMATE_STRING_ENTRY (SystemSku),
  VMATE_STRING_ENTRY (SystemFamily),
  VMATE_STRING_ENTRY (BoardManufacturer),
  VMATE_STRING_ENTRY (BoardProduct),
  VMATE_STRING_ENTRY (BoardVersion),
  VMATE_STRING_ENTRY (BoardSerial),
  VMATE_STRING_ENTRY (BoardAsset),
  VMATE_STRING_ENTRY (ChassisManufacturer),
  VMATE_STRING_ENTRY (ChassisVersion),
  VMATE_STRING_ENTRY (ChassisSerial),
  VMATE_STRING_ENTRY (ChassisAsset),
  VMATE_STRING_ENTRY (CpuManufacturer),
  VMATE_STRING_ENTRY (CpuVersion),
  VMATE_STRING_ENTRY (CpuSerial),
  VMATE_STRING_ENTRY (CpuAsset),
  VMATE_STRING_ENTRY (CpuPart),
  VMATE_STRING_ENTRY (MemoryManufacturer),
  VMATE_STRING_ENTRY (MemorySerial),
  VMATE_STRING_ENTRY (MemoryAsset),
  VMATE_STRING_ENTRY (MemoryPart)
};

STATIC
CHAR8 *
TrimAscii (
  IN CHAR8 *Value
  )
{
  CHAR8 *End;

  while ((*Value == ' ') || (*Value == '\t')) {
    ++Value;
  }
  End = Value + AsciiStrLen (Value);
  while ((End > Value) && ((End[-1] == ' ') || (End[-1] == '\t') ||
                           (End[-1] == '\r'))) {
    --End;
  }
  *End = '\0';
  return Value;
}

STATIC
EFI_STATUS
ParseDecimal (
  IN CONST CHAR8 *Text,
  IN UINTN Maximum,
  OUT UINTN *Value
  )
{
  UINTN Result;

  if ((Text == NULL) || (*Text == '\0')) {
    return EFI_INVALID_PARAMETER;
  }
  Result = 0;
  while (*Text != '\0') {
    if ((*Text < '0') || (*Text > '9')) {
      return EFI_INVALID_PARAMETER;
    }
    if (Result > ((Maximum - (UINTN)(*Text - '0')) / 10)) {
      return EFI_BAD_BUFFER_SIZE;
    }
    Result = (Result * 10) + (UINTN)(*Text - '0');
    ++Text;
  }
  if (Result == 0) {
    return EFI_INVALID_PARAMETER;
  }
  *Value = Result;
  return EFI_SUCCESS;
}

STATIC
EFI_STATUS
SetStringField (
  IN OUT VMATE_IDENTITY_CONFIG *Config,
  IN CONST CHAR8 *Name,
  IN CONST CHAR8 *Value
  )
{
  UINTN Index;
  UINTN Length;
  CHAR8 *Target;

  Length = AsciiStrLen (Value);
  if ((Length == 0) || (Length >= VMATE_IDENTITY_VALUE_SIZE)) {
    return EFI_BAD_BUFFER_SIZE;
  }
  for (Index = 0; Index < Length; ++Index) {
    if (((UINT8)Value[Index] < 0x20) || ((UINT8)Value[Index] > 0x7e)) {
      return EFI_UNSUPPORTED;
    }
  }
  for (Index = 0; Index < ARRAY_SIZE (mStringFields); ++Index) {
    if (AsciiStrCmp (Name, mStringFields[Index].Name) != 0) {
      continue;
    }
    Target = (CHAR8 *)Config + mStringFields[Index].Offset;
    if (*Target != '\0') {
      return EFI_ALREADY_STARTED;
    }
    CopyMem (Target, Value, Length + 1);
    return EFI_SUCCESS;
  }
  return EFI_NOT_FOUND;
}

STATIC
EFI_STATUS
ParseConfigBuffer (
  IN OUT CHAR8 *Buffer,
  OUT VMATE_IDENTITY_CONFIG *Config,
  OUT UINTN *ParsedFields
  )
{
  CHAR8 *Cursor;
  CHAR8 *Line;
  CHAR8 *Equals;
  CHAR8 *Name;
  CHAR8 *Value;
  EFI_STATUS Status;
  UINTN Number;
  BOOLEAN ChassisTypeSet;
  BOOLEAN MemoryTypeSet;
  BOOLEAN MemorySpeedSet;
  BOOLEAN MemoryConfiguredSpeedSet;

  SetMem (Config, sizeof (*Config), 0);
  *ParsedFields = 0;
  ChassisTypeSet = FALSE;
  MemoryTypeSet = FALSE;
  MemorySpeedSet = FALSE;
  MemoryConfiguredSpeedSet = FALSE;
  Cursor = Buffer;
  if (((UINT8)Cursor[0] == 0xef) && ((UINT8)Cursor[1] == 0xbb) &&
      ((UINT8)Cursor[2] == 0xbf)) {
    Cursor += 3;
  }

  while (*Cursor != '\0') {
    Line = Cursor;
    while ((*Cursor != '\0') && (*Cursor != '\n')) {
      ++Cursor;
    }
    if (*Cursor == '\n') {
      *Cursor++ = '\0';
    }
    Line = TrimAscii (Line);
    if ((*Line == '\0') || (*Line == '#') || (*Line == ';')) {
      continue;
    }
    Equals = Line;
    while ((*Equals != '\0') && (*Equals != '=')) {
      ++Equals;
    }
    if (*Equals != '=') {
      return EFI_INVALID_PARAMETER;
    }
    *Equals++ = '\0';
    Name = TrimAscii (Line);
    Value = TrimAscii (Equals);
    if ((*Name == '\0') || (*Value == '\0')) {
      return EFI_INVALID_PARAMETER;
    }

    Status = SetStringField (Config, Name, Value);
    if (!EFI_ERROR (Status)) {
      ++*ParsedFields;
      continue;
    }
    if (Status != EFI_NOT_FOUND) {
      return Status;
    }

    if (AsciiStrCmp (Name, "ChassisType") == 0) {
      if (ChassisTypeSet) { return EFI_ALREADY_STARTED; }
      Status = ParseDecimal (Value, 0x7f, &Number);
      if (EFI_ERROR (Status)) { return Status; }
      Config->ChassisType = (UINT8)Number;
      ChassisTypeSet = TRUE;
    } else if (AsciiStrCmp (Name, "MemoryType") == 0) {
      if (MemoryTypeSet) { return EFI_ALREADY_STARTED; }
      Status = ParseDecimal (Value, 0xff, &Number);
      if (EFI_ERROR (Status)) { return Status; }
      Config->MemoryType = (UINT8)Number;
      MemoryTypeSet = TRUE;
    } else if (AsciiStrCmp (Name, "MemorySpeed") == 0) {
      if (MemorySpeedSet) { return EFI_ALREADY_STARTED; }
      Status = ParseDecimal (Value, 0xffff, &Number);
      if (EFI_ERROR (Status)) { return Status; }
      Config->MemorySpeed = (UINT16)Number;
      MemorySpeedSet = TRUE;
    } else if (AsciiStrCmp (Name, "MemoryConfiguredSpeed") == 0) {
      if (MemoryConfiguredSpeedSet) { return EFI_ALREADY_STARTED; }
      Status = ParseDecimal (Value, 0xffff, &Number);
      if (EFI_ERROR (Status)) { return Status; }
      Config->MemoryConfiguredSpeed = (UINT16)Number;
      MemoryConfiguredSpeedSet = TRUE;
    } else {
      return EFI_NOT_FOUND;
    }
    ++*ParsedFields;
  }

  if ((*ParsedFields != (ARRAY_SIZE (mStringFields) + 4)) ||
      !ChassisTypeSet || !MemoryTypeSet || !MemorySpeedSet ||
      !MemoryConfiguredSpeedSet) {
    return EFI_NOT_READY;
  }
  return EFI_SUCCESS;
}

EFI_STATUS
VMateLoadIdentityConfig (
  IN EFI_HANDLE ImageHandle,
  OUT VMATE_IDENTITY_CONFIG *Config,
  OUT UINTN *ParsedFields
  )
{
  EFI_LOADED_IMAGE_PROTOCOL *LoadedImage;
  EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *FileSystem;
  EFI_FILE_PROTOCOL *Root;
  EFI_FILE_PROTOCOL *File;
  CHAR8 *Buffer;
  UINTN Size;
  EFI_STATUS Status;

  if ((Config == NULL) || (ParsedFields == NULL)) {
    return EFI_INVALID_PARAMETER;
  }
  Status = gBS->HandleProtocol (ImageHandle, &gEfiLoadedImageProtocolGuid,
                                (VOID **)&LoadedImage);
  if (EFI_ERROR (Status)) { return Status; }
  Status = gBS->HandleProtocol (LoadedImage->DeviceHandle,
                                &gEfiSimpleFileSystemProtocolGuid,
                                (VOID **)&FileSystem);
  if (EFI_ERROR (Status)) { return Status; }
  Status = FileSystem->OpenVolume (FileSystem, &Root);
  if (EFI_ERROR (Status)) { return Status; }
  Status = Root->Open (Root, &File, VMATE_IDENTITY_CONFIG_PATH,
                       EFI_FILE_MODE_READ, 0);
  Root->Close (Root);
  if (EFI_ERROR (Status)) { return Status; }

  Buffer = AllocateZeroPool (VMATE_CONFIG_MAX_BYTES + 1);
  if (Buffer == NULL) {
    File->Close (File);
    return EFI_OUT_OF_RESOURCES;
  }
  Size = VMATE_CONFIG_MAX_BYTES;
  Status = File->Read (File, &Size, Buffer);
  File->Close (File);
  if (!EFI_ERROR (Status) && (Size == VMATE_CONFIG_MAX_BYTES)) {
    Status = EFI_BAD_BUFFER_SIZE;
  }
  if (!EFI_ERROR (Status)) {
    Buffer[Size] = '\0';
    Status = ParseConfigBuffer (Buffer, Config, ParsedFields);
  }
  FreePool (Buffer);
  return Status;
}
