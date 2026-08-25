#include <Uefi.h>

#include <Library/DevicePathLib.h>
#include <Library/BaseMemoryLib.h>
#include <Library/MemoryAllocationLib.h>
#include <Library/PrintLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Protocol/LoadedImage.h>
#include <Protocol/SimpleFileSystem.h>

#include "IdentityConfig.h"
#include "SmbiosIdentity.h"

#define VMATE_STATUS_PATH L"\\EFI\\VMate\\identity-status.txt"
#define VMATE_STOCK_BOOT_PATH L"\\EFI\\Microsoft\\Boot\\bootmgfw.vmate-stock.efi"
#define VMATE_FALLBACK_BOOT_PATH L"\\EFI\\Boot\\bootx64.efi"

STATIC
VOID
WriteStatus (
  IN EFI_HANDLE ImageHandle,
  IN EFI_STATUS ConfigStatus,
  IN UINTN ParsedFields,
  IN EFI_STATUS IdentityStatus,
  IN CONST VMATE_SMBIOS_RESULT *Result
  )
{
  EFI_LOADED_IMAGE_PROTOCOL *LoadedImage;
  EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *FileSystem;
  EFI_FILE_PROTOCOL *Root;
  EFI_FILE_PROTOCOL *File;
  EFI_STATUS Status;
  CHAR8 Buffer[512];
  UINTN Size;

  Status = gBS->HandleProtocol (ImageHandle, &gEfiLoadedImageProtocolGuid,
                                (VOID **)&LoadedImage);
  if (EFI_ERROR (Status)) { return; }
  Status = gBS->HandleProtocol (LoadedImage->DeviceHandle,
                                &gEfiSimpleFileSystemProtocolGuid,
                                (VOID **)&FileSystem);
  if (EFI_ERROR (Status)) { return; }
  Status = FileSystem->OpenVolume (FileSystem, &Root);
  if (EFI_ERROR (Status)) { return; }
  Status = Root->Open (Root, &File, VMATE_STATUS_PATH,
                       EFI_FILE_MODE_READ | EFI_FILE_MODE_WRITE |
                       EFI_FILE_MODE_CREATE, 0);
  Root->Close (Root);
  if (EFI_ERROR (Status)) { return; }
  File->SetPosition (File, 0);
  Size = AsciiSPrint (
           Buffer,
           sizeof (Buffer),
           "SchemaVersion=1\r\nConfigStatus=0x%lx\r\nParsedFields=%u\r\n"
           "IdentityStatus=0x%lx\r\nRecordsVisited=%u\r\n"
           "RecordsReplaced=%u\r\nStringsUpdated=%u\r\nUpdateErrors=%u\r\n",
           (UINT64)ConfigStatus,
           (UINT32)ParsedFields,
           (UINT64)IdentityStatus,
           (UINT32)Result->RecordsVisited,
           (UINT32)Result->RecordsReplaced,
           (UINT32)Result->StringsUpdated,
           (UINT32)Result->UpdateErrors
           );
  File->Write (File, &Size, Buffer);
  File->Flush (File);
  File->Close (File);
}

STATIC
EFI_STATUS
StartBootImage (
  IN EFI_HANDLE ImageHandle,
  IN CONST CHAR16 *Path
  )
{
  EFI_LOADED_IMAGE_PROTOCOL *LoadedImage;
  EFI_LOADED_IMAGE_PROTOCOL *ChildImage;
  EFI_DEVICE_PATH_PROTOCOL *DevicePath;
  EFI_HANDLE ChildHandle;
  EFI_STATUS Status;

  Status = gBS->HandleProtocol (ImageHandle, &gEfiLoadedImageProtocolGuid,
                                (VOID **)&LoadedImage);
  if (EFI_ERROR (Status)) { return Status; }
  DevicePath = FileDevicePath (LoadedImage->DeviceHandle, Path);
  if (DevicePath == NULL) { return EFI_OUT_OF_RESOURCES; }
  ChildHandle = NULL;
  Status = gBS->LoadImage (FALSE, ImageHandle, DevicePath, NULL, 0,
                           &ChildHandle);
  FreePool (DevicePath);
  if (EFI_ERROR (Status)) { return Status; }

  Status = gBS->HandleProtocol (ChildHandle, &gEfiLoadedImageProtocolGuid,
                                (VOID **)&ChildImage);
  if (!EFI_ERROR (Status)) {
    ChildImage->LoadOptions = LoadedImage->LoadOptions;
    ChildImage->LoadOptionsSize = LoadedImage->LoadOptionsSize;
  }
  return gBS->StartImage (ChildHandle, NULL, NULL);
}

EFI_STATUS
EFIAPI
UefiMain (
  IN EFI_HANDLE ImageHandle,
  IN EFI_SYSTEM_TABLE *SystemTable
  )
{
  VMATE_IDENTITY_CONFIG Config;
  VMATE_SMBIOS_RESULT Result;
  EFI_STATUS ConfigStatus;
  EFI_STATUS IdentityStatus;
  EFI_STATUS BootStatus;
  UINTN ParsedFields;

  (VOID)SystemTable;
  gBS->SetWatchdogTimer (0, 0, 0, NULL);
  ParsedFields = 0;
  SetMem (&Result, sizeof (Result), 0);
  ConfigStatus = VMateLoadIdentityConfig (ImageHandle, &Config,
                                         &ParsedFields);
  if (EFI_ERROR (ConfigStatus)) {
    IdentityStatus = EFI_NOT_READY;
  } else {
    IdentityStatus = VMateApplySmbiosIdentity (&Config, &Result);
  }
  WriteStatus (ImageHandle, ConfigStatus, ParsedFields, IdentityStatus,
               &Result);

  BootStatus = StartBootImage (ImageHandle, VMATE_STOCK_BOOT_PATH);
  if (EFI_ERROR (BootStatus)) {
    BootStatus = StartBootImage (ImageHandle, VMATE_FALLBACK_BOOT_PATH);
  }
  return BootStatus;
}
