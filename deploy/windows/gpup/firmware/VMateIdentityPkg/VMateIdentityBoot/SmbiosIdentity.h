#ifndef VMATE_SMBIOS_IDENTITY_H
#define VMATE_SMBIOS_IDENTITY_H

#include <Uefi.h>
#include "IdentityConfig.h"

typedef struct {
  UINTN RecordsVisited;
  UINTN RecordsReplaced;
  UINTN StringsUpdated;
  UINTN UpdateErrors;
} VMATE_SMBIOS_RESULT;

EFI_STATUS
VMateApplySmbiosIdentity (
  IN CONST VMATE_IDENTITY_CONFIG *Config,
  OUT VMATE_SMBIOS_RESULT *Result
  );

#endif
