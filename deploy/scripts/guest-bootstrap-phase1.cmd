@echo off
REM Phase 1: set password + enable RDP only, no iso dependency.
net user Administrator 123456 /active:yes
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v UserAuthentication /t REG_DWORD /d 0 /f
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v SecurityLayer /t REG_DWORD /d 1 /f
netsh advfirewall firewall set rule group="remote desktop" new enable=Yes
sc config TermService start= auto
net start TermService
echo === phase1 done ===
