#include <Uefi.h>

#include <Library/BaseMemoryLib.h>
#include <Library/DevicePathLib.h>
#include <Library/MemoryAllocationLib.h>
#include <Library/PrintLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Protocol/LoadedImage.h>
#include <Protocol/SimpleFileSystem.h>

#define VMATE_BRIDGE_AUDIT_PATH L"\\EFI\\VMate\\bridge-audit.txt"
#define VMATE_STOCK_BOOT_PATH L"\\EFI\\Microsoft\\Boot\\bootmgfw.vmate-stock.efi"
#define VMATE_BRIDGE_BUFFER_SIZE 36

STATIC
UINT32
InvokeBridge (
  OUT UINT8 *Buffer,
  OUT UINT32 *EbxResult,
  OUT UINT32 *EcxResult,
  OUT UINT32 *EdxResult
  )
{
  UINTN Rax;
  UINTN Rbx;
  UINTN Rcx;
  UINTN Rdx;

  SetMem (Buffer, VMATE_BRIDGE_BUFFER_SIZE, 0);
  Rax = 0x0051530D;
  Rbx = 0;
  Rcx = 6;
  Rdx = (UINTN)Buffer;
  __asm__ __volatile__ (
    "cpuid"
    : "+a" (Rax), "=b" (Rbx), "+c" (Rcx), "+d" (Rdx)
    :
    : "memory"
    );
  *EbxResult = (UINT32)Rbx;
  *EcxResult = (UINT32)Rcx;
  *EdxResult = (UINT32)Rdx;
  return (UINT32)Rax;
}

STATIC
VOID
WriteAudit (
  IN EFI_HANDLE ImageHandle,
  IN UINT32 EaxResult,
  IN UINT32 EbxResult,
  IN UINT32 EcxResult,
  IN UINT32 EdxResult,
  IN CONST UINT8 *Buffer
  )
{
  EFI_LOADED_IMAGE_PROTOCOL *LoadedImage;
  EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *FileSystem;
  EFI_FILE_PROTOCOL *Root;
  EFI_FILE_PROTOCOL *File;
  EFI_STATUS Status;
  CHAR8 Text[384];
  UINTN Position;
  UINTN Index;
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
  Status = Root->Open (Root, &File, VMATE_BRIDGE_AUDIT_PATH,
                       EFI_FILE_MODE_READ | EFI_FILE_MODE_WRITE |
                       EFI_FILE_MODE_CREATE, 0);
  Root->Close (Root);
  if (EFI_ERROR (Status)) { return; }

  Position = AsciiSPrint (
               Text,
               sizeof (Text),
               "SchemaVersion=1\r\nEAX=%08x\r\nEBX=%08x\r\n"
               "ECX=%08x\r\nEDX=%08x\r\nBuffer=",
               EaxResult,
               EbxResult,
               EcxResult,
               EdxResult
               );
  for (Index = 0; Index < VMATE_BRIDGE_BUFFER_SIZE; ++Index) {
    Position += AsciiSPrint (&Text[Position], sizeof (Text) - Position,
                             "%02x", Buffer[Index]);
  }
  Position += AsciiSPrint (&Text[Position], sizeof (Text) - Position,
                           "\r\n");
  File->SetPosition (File, 0);
  Size = Position;
  File->Write (File, &Size, Text);
  File->Flush (File);
  File->Close (File);
}

STATIC
EFI_STATUS
StartStockBoot (
  IN EFI_HANDLE ImageHandle
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
  DevicePath = FileDevicePath (LoadedImage->DeviceHandle,
                               VMATE_STOCK_BOOT_PATH);
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
  UINT8 Buffer[VMATE_BRIDGE_BUFFER_SIZE];
  UINT32 EaxResult;
  UINT32 EbxResult;
  UINT32 EcxResult;
  UINT32 EdxResult;

  (VOID)SystemTable;
  gBS->SetWatchdogTimer (0, 0, 0, NULL);
  EaxResult = InvokeBridge (Buffer, &EbxResult, &EcxResult, &EdxResult);
  WriteAudit (ImageHandle, EaxResult, EbxResult, EcxResult, EdxResult,
              Buffer);
  return StartStockBoot (ImageHandle);
}
