/**
  G-11 installation-media chainloader.

  The helper is booted from a tiny FAT volume.  It skips that volume (marked
  with HELPER.MARK), finds another SimpleFileSystem containing the removable
  media fallback path, and starts it through its real device path.  Keeping
  the device path is important: Windows Boot Manager uses it to find the BCD
  and the remaining files on the installation ISO.

  SPDX-License-Identifier: BSD-2-Clause-Patent
**/

#include <Uefi.h>
#include <Protocol/DevicePath.h>
#include <Protocol/LoadedImage.h>
#include <Protocol/SimpleFileSystem.h>

#define G11_END_DEVICE_PATH_LENGTH  4U
#define G11_MAX_DEVICE_PATH_LENGTH  65535U
#define G11_DISCOVERY_ATTEMPTS      3U
#define G11_DISCOVERY_DELAY_US      1000000U

STATIC CONST EFI_GUID  mLoadedImageProtocolGuid = EFI_LOADED_IMAGE_PROTOCOL_GUID;
STATIC CONST EFI_GUID  mSimpleFileSystemProtocolGuid = EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID;
STATIC CONST EFI_GUID  mDevicePathProtocolGuid = EFI_DEVICE_PATH_PROTOCOL_GUID;

STATIC CHAR16  mHelperMarker[] = L"\\HELPER.MARK";
STATIC CHAR16  mWindowsBootPath[] = L"\\EFI\\BOOT\\BOOTX64.EFI";
STATIC CHAR16  mWindowsBootWimPath[] = L"\\sources\\boot.wim";

STATIC
UINT16
G11DevicePathNodeLength (
  IN CONST EFI_DEVICE_PATH_PROTOCOL  *Node
  )
{
  return (UINT16)(Node->Length[0] | ((UINT16)Node->Length[1] << 8));
}

STATIC
VOID
G11SetDevicePathNodeLength (
  OUT EFI_DEVICE_PATH_PROTOCOL  *Node,
  IN  UINT16                    Length
  )
{
  Node->Length[0] = (UINT8)Length;
  Node->Length[1] = (UINT8)(Length >> 8);
}

STATIC
EFI_STATUS
G11DevicePathSize (
  IN  CONST EFI_DEVICE_PATH_PROTOCOL  *DevicePath,
  OUT UINTN                           *Size
  )
{
  CONST EFI_DEVICE_PATH_PROTOCOL  *Node;
  UINTN                           Total;
  UINT16                          NodeLength;

  if ((DevicePath == NULL) || (Size == NULL)) {
    return EFI_INVALID_PARAMETER;
  }

  Node  = DevicePath;
  Total = 0;
  while (Total < G11_MAX_DEVICE_PATH_LENGTH) {
    NodeLength = G11DevicePathNodeLength (Node);
    if (NodeLength < sizeof (EFI_DEVICE_PATH_PROTOCOL)) {
      return EFI_COMPROMISED_DATA;
    }

    if ((Total + NodeLength) > G11_MAX_DEVICE_PATH_LENGTH) {
      return EFI_BAD_BUFFER_SIZE;
    }

    Total += NodeLength;
    if ((Node->Type == END_DEVICE_PATH_TYPE) &&
        (Node->SubType == END_ENTIRE_DEVICE_PATH_SUBTYPE)) {
      *Size = Total;
      return EFI_SUCCESS;
    }

    Node = (CONST EFI_DEVICE_PATH_PROTOCOL *)((CONST UINT8 *)Node + NodeLength);
  }

  return EFI_BAD_BUFFER_SIZE;
}

STATIC
EFI_STATUS
G11BuildFileDevicePath (
  IN  EFI_BOOT_SERVICES          *BootServices,
  IN  EFI_DEVICE_PATH_PROTOCOL   *BasePath,
  IN  CONST CHAR16               *FileName,
  OUT EFI_DEVICE_PATH_PROTOCOL   **FileDevicePath
  )
{
  EFI_STATUS                Status;
  EFI_DEVICE_PATH_PROTOCOL  *Path;
  EFI_DEVICE_PATH_PROTOCOL  *FileNode;
  EFI_DEVICE_PATH_PROTOCOL  *EndNode;
  UINTN                     BaseSize;
  UINTN                     FileNameChars;
  UINTN                     FileNodeSize;
  UINTN                     TotalSize;

  if ((BootServices == NULL) || (BasePath == NULL) ||
      (FileName == NULL) || (FileDevicePath == NULL)) {
    return EFI_INVALID_PARAMETER;
  }

  *FileDevicePath = NULL;
  Status = G11DevicePathSize (BasePath, &BaseSize);
  if (EFI_ERROR (Status)) {
    return Status;
  }

  FileNameChars = 0;
  while (FileName[FileNameChars] != L'\0') {
    ++FileNameChars;
  }

  ++FileNameChars;
  FileNodeSize = sizeof (EFI_DEVICE_PATH_PROTOCOL) +
                 (FileNameChars * sizeof (CHAR16));
  TotalSize = BaseSize - G11_END_DEVICE_PATH_LENGTH + FileNodeSize +
              G11_END_DEVICE_PATH_LENGTH;
  if ((FileNodeSize > 0xffffU) || (TotalSize > G11_MAX_DEVICE_PATH_LENGTH)) {
    return EFI_BAD_BUFFER_SIZE;
  }

  Status = BootServices->AllocatePool (
                           EfiBootServicesData,
                           TotalSize,
                           (VOID **)&Path
                           );
  if (EFI_ERROR (Status)) {
    return Status;
  }

  BootServices->CopyMem (
                  Path,
                  BasePath,
                  BaseSize - G11_END_DEVICE_PATH_LENGTH
                  );
  FileNode = (EFI_DEVICE_PATH_PROTOCOL *)((UINT8 *)Path + BaseSize -
                                          G11_END_DEVICE_PATH_LENGTH);
  FileNode->Type    = MEDIA_DEVICE_PATH;
  FileNode->SubType = MEDIA_FILEPATH_DP;
  G11SetDevicePathNodeLength (FileNode, (UINT16)FileNodeSize);
  BootServices->CopyMem (
                  (UINT8 *)FileNode + sizeof (EFI_DEVICE_PATH_PROTOCOL),
                  (VOID *)FileName,
                  FileNameChars * sizeof (CHAR16)
                  );

  EndNode = (EFI_DEVICE_PATH_PROTOCOL *)((UINT8 *)FileNode + FileNodeSize);
  EndNode->Type    = END_DEVICE_PATH_TYPE;
  EndNode->SubType = END_ENTIRE_DEVICE_PATH_SUBTYPE;
  G11SetDevicePathNodeLength (EndNode, G11_END_DEVICE_PATH_LENGTH);

  *FileDevicePath = Path;
  return EFI_SUCCESS;
}

STATIC
BOOLEAN
G11VolumeContainsFile (
  IN EFI_FILE_PROTOCOL  *Root,
  IN CHAR16             *Path
  )
{
  EFI_FILE_PROTOCOL  *File;
  EFI_STATUS         Status;

  File = NULL;
  Status = Root->Open (Root, &File, Path, EFI_FILE_MODE_READ, 0);
  if (EFI_ERROR (Status)) {
    return FALSE;
  }

  File->Close (File);
  return TRUE;
}

EFI_STATUS
EFIAPI
UefiMain (
  IN EFI_HANDLE        ImageHandle,
  IN EFI_SYSTEM_TABLE  *SystemTable
  )
{
  EFI_BOOT_SERVICES                 *BootServices;
  EFI_LOADED_IMAGE_PROTOCOL         *LoadedImage;
  EFI_SIMPLE_FILE_SYSTEM_PROTOCOL   *FileSystem;
  EFI_FILE_PROTOCOL                 *Root;
  EFI_DEVICE_PATH_PROTOCOL          *BasePath;
  EFI_DEVICE_PATH_PROTOCOL          *BootPath;
  EFI_HANDLE                        *Handles;
  EFI_HANDLE                        ChildImage;
  EFI_STATUS                        Status;
  EFI_STATUS                        LastStatus;
  UINTN                             HandleCount;
  UINTN                             Attempt;
  UINTN                             Index;

  if ((SystemTable == NULL) || (SystemTable->BootServices == NULL)) {
    return EFI_INVALID_PARAMETER;
  }

  BootServices = SystemTable->BootServices;
  LoadedImage  = NULL;
  Status = BootServices->HandleProtocol (
                           ImageHandle,
                           (EFI_GUID *)&mLoadedImageProtocolGuid,
                           (VOID **)&LoadedImage
                           );
  if (EFI_ERROR (Status)) {
    return Status;
  }

  LastStatus = EFI_NOT_FOUND;
  for (Attempt = 0; Attempt < G11_DISCOVERY_ATTEMPTS; ++Attempt) {
    Handles     = NULL;
    HandleCount = 0;
    Status = BootServices->LocateHandleBuffer (
                             ByProtocol,
                             (EFI_GUID *)&mSimpleFileSystemProtocolGuid,
                             NULL,
                             &HandleCount,
                             &Handles
                             );
    if (EFI_ERROR (Status)) {
      LastStatus = Status;
    } else {
      for (Index = 0; Index < HandleCount; ++Index) {
        if (Handles[Index] == LoadedImage->DeviceHandle) {
          continue;
        }

        FileSystem = NULL;
        Status = BootServices->HandleProtocol (
                                 Handles[Index],
                                 (EFI_GUID *)&mSimpleFileSystemProtocolGuid,
                                 (VOID **)&FileSystem
                                 );
        if (EFI_ERROR (Status)) {
          LastStatus = Status;
          continue;
        }

        Root = NULL;
        Status = FileSystem->OpenVolume (FileSystem, &Root);
        if (EFI_ERROR (Status)) {
          LastStatus = Status;
          continue;
        }

        if (G11VolumeContainsFile (Root, mHelperMarker) ||
            !G11VolumeContainsFile (Root, mWindowsBootPath) ||
            !G11VolumeContainsFile (Root, mWindowsBootWimPath)) {
          Root->Close (Root);
          continue;
        }

        Root->Close (Root);
        BasePath = NULL;
        Status = BootServices->HandleProtocol (
                                 Handles[Index],
                                 (EFI_GUID *)&mDevicePathProtocolGuid,
                                 (VOID **)&BasePath
                                 );
        if (EFI_ERROR (Status)) {
          LastStatus = Status;
          continue;
        }

        BootPath = NULL;
        Status = G11BuildFileDevicePath (
                   BootServices,
                   BasePath,
                   mWindowsBootPath,
                   &BootPath
                   );
        if (EFI_ERROR (Status)) {
          LastStatus = Status;
          continue;
        }

        ChildImage = NULL;
        Status = BootServices->LoadImage (
                                 FALSE,
                                 ImageHandle,
                                 BootPath,
                                 NULL,
                                 0,
                                 &ChildImage
                                 );
        BootServices->FreePool (BootPath);
        if (EFI_ERROR (Status)) {
          LastStatus = Status;
          if (ChildImage != NULL) {
            BootServices->UnloadImage (ChildImage);
          }
          continue;
        }

        Status = BootServices->StartImage (ChildImage, NULL, NULL);
        LastStatus = Status;
      }

      BootServices->FreePool (Handles);
    }

    if ((Attempt + 1) < G11_DISCOVERY_ATTEMPTS) {
      BootServices->Stall (G11_DISCOVERY_DELAY_US);
    }
  }
  return LastStatus;
}
