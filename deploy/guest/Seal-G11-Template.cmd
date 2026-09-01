@echo off
setlocal EnableExtensions
title VMate G-11 Sysprep Template Seal

fltmc >nul 2>&1
if errorlevel 1 (
  powershell.exe -NoLogo -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

set "ANSWER=%~dp0g11-sysprep-clone.xml"
set "DIAGNOSTIC=%~dp0Collect-Sysprep-Diagnostics.ps1"
set "READINESS=%~dp0Assert-G11-Template-Ready.ps1"
set "SERVICING_READINESS=%~dp0Assert-G11-Sysprep-Servicing-Ready.ps1"
set "RESET=%~dp0Reset-G11-Template-State.ps1"
set "STORAGE_PORTABILITY=%~dp0Prepare-G11-Storage-Portability.ps1"
set "SYSPREP_RUNNER=%~dp0Invoke-G11-Sysprep.ps1"
if not exist "%ANSWER%" (
  echo [ERROR] Missing %ANSWER%
  pause
  exit /b 2
)
set "PAYLOAD=%~dp0Payload"
set "GUESTLITE=%PAYLOAD%\GuestLite"
for %%F in (
  "%PAYLOAD%\Finalize-Clone.ps1"
  "%PAYLOAD%\Retry-Clone-Initialization.cmd"
  "%GUESTLITE%\clone-manifest.json"
  "%GUESTLITE%\G11-Guest-Lite.ps1"
  "%GUESTLITE%\01-OneClick-Apply.cmd"
  "%GUESTLITE%\02-Audit.cmd"
  "%GUESTLITE%\03-Rollback.cmd"
  "%GUESTLITE%\README.txt"
  "%~dp0Standalone-GuestLite\G11GuestLite.exe"
  "%DIAGNOSTIC%"
  "%READINESS%"
  "%SERVICING_READINESS%"
  "%RESET%"
  "%STORAGE_PORTABILITY%"
  "%SYSPREP_RUNNER%"
  "%~dp0Template-Reset\GuestLite\G11-Guest-Lite.ps1"
  "%~dp0Template-Reset\GuestPerformance\Optimize-Guest.ps1"
) do (
  if not exist "%%~F" (
    echo [ERROR] Incomplete G11SysprepKit. Missing %%~F
    pause
    exit /b 2
  )
)

set "KIT_ROOT=%~dp0"
set "DEST=%ProgramData%\VMate\G11"
powershell.exe -NoLogo -NoProfile -NonInteractive -Command "$kit=[IO.Path]::GetFullPath($env:KIT_ROOT).TrimEnd([IO.Path]::DirectorySeparatorChar); $dest=[IO.Path]::GetFullPath($env:DEST).TrimEnd([IO.Path]::DirectorySeparatorChar); $prefix=$dest+[IO.Path]::DirectorySeparatorChar; if ($kit.Equals($dest,[StringComparison]::OrdinalIgnoreCase) -or $kit.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { exit 23 }"
if errorlevel 1 (
  echo [ERROR] G11SysprepKit cannot be stored in or below %DEST%.
  echo Move the complete kit to C:\G11SysprepKit, then run this file there.
  pause
  exit /b 2
)

echo This will generalize Windows, skip interactive OOBE in every clone,
echo roll back clone-bound experiment state, stage the complete public first-boot
echo payload, and fully shut down this template.
echo It also enables and verifies the inbox storahci/stornvme boot paths.
echo Do not boot this source again after success.
echo.
choice /C YN /N /M "Continue? [Y/N] "
if errorlevel 2 exit /b 0

powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%READINESS%"
if errorlevel 1 (
  echo [ERROR] Template readiness gate failed. Sysprep was not started.
  pause
  exit /b 1
)

powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%RESET%"
if errorlevel 1 (
  echo [ERROR] Clone-bound state could not be reset. Sysprep was not started.
  pause
  exit /b 1
)

powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%STORAGE_PORTABILITY%"
if errorlevel 1 (
  echo [ERROR] SATA/NVMe storage portability preparation failed. Sysprep was not started.
  pause
  exit /b 1
)

set "GUESTLITE_NEW=%DEST%\GuestLite.new"
if not exist "%DEST%" (
  mkdir "%DEST%"
  if errorlevel 1 goto :stage_error
)
if exist "%GUESTLITE_NEW%" rmdir /s /q "%GUESTLITE_NEW%"
mkdir "%GUESTLITE_NEW%"
if errorlevel 1 goto :stage_error
for %%F in (
  clone-manifest.json
  G11-Guest-Lite.ps1
  01-OneClick-Apply.cmd
  02-Audit.cmd
  03-Rollback.cmd
  README.txt
) do (
  copy /b /y "%GUESTLITE%\%%F" "%GUESTLITE_NEW%\%%F" >nul
  if errorlevel 1 goto :stage_error
)
copy /b /y "%PAYLOAD%\Finalize-Clone.ps1" "%DEST%\Finalize-Clone.ps1.new" >nul
if errorlevel 1 goto :stage_error
copy /b /y "%PAYLOAD%\Retry-Clone-Initialization.cmd" "%DEST%\Retry-Clone-Initialization.cmd.new" >nul
if errorlevel 1 goto :stage_error
copy /b /y "%STORAGE_PORTABILITY%" "%DEST%\Prepare-G11-Storage-Portability.ps1.new" >nul
if errorlevel 1 goto :stage_error
move /y "%DEST%\Finalize-Clone.ps1.new" "%DEST%\Finalize-Clone.ps1" >nul
if errorlevel 1 goto :stage_error
move /y "%DEST%\Retry-Clone-Initialization.cmd.new" "%DEST%\Retry-Clone-Initialization.cmd" >nul
if errorlevel 1 goto :stage_error
move /y "%DEST%\Prepare-G11-Storage-Portability.ps1.new" "%DEST%\Prepare-G11-Storage-Portability.ps1" >nul
if errorlevel 1 goto :stage_error
if exist "%DEST%\GuestLite" rmdir /s /q "%DEST%\GuestLite"
if exist "%DEST%\GuestLite" goto :stage_error
move /y "%GUESTLITE_NEW%" "%DEST%\GuestLite" >nul
if errorlevel 1 goto :stage_error
if not exist "%PUBLIC%\Desktop" (
  mkdir "%PUBLIC%\Desktop"
  if errorlevel 1 goto :stage_error
)
copy /b /y "%PAYLOAD%\Retry-Clone-Initialization.cmd" "%PUBLIC%\Desktop\Retry-Clone-Initialization.cmd" >nul
if errorlevel 1 goto :stage_error
echo [PASS] Public Finalize, Retry, and Guest Lite payload staged in %DEST%.

powercfg.exe /hibernate off
if errorlevel 1 (
  echo [ERROR] Could not disable hibernation/Fast Startup.
  pause
  exit /b 1
)

powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SERVICING_READINESS%"
if errorlevel 1 (
  echo [ERROR] Windows servicing readiness gate failed. Sysprep was not started.
  echo Install all Windows updates and use Restart until nothing is pending, then run Seal again.
  pause
  exit /b 1
)

powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SYSPREP_RUNNER%" -AnswerFile "%ANSWER%" -DiagnosticScript "%DIAGNOSTIC%" -DiagnosticOutput "%~dp0Sysprep-Diagnostics.txt"
if errorlevel 1 (
  echo [ERROR] Sysprep did not complete. The automatic diagnostic result is shown above.
  echo Do not rerun Reset or Sysprep directly. Fix only the reported blocker, then run Seal again.
  pause
  exit /b 1
)
exit /b 0

:stage_error
echo [ERROR] Could not stage the complete public first-boot payload.
echo Sysprep was not started. Fix the reported file/disk/permission issue and retry.
pause
exit /b 1
