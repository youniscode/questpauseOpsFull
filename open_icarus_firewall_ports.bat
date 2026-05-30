@echo off
title ICARUS Firewall Ports
echo Opening ICARUS firewall ports...
echo.
echo Ports: 48187(STYX) 48188(STYX) 48189(PRO) 48190(PRO) 48191(ELY) 48192(ELY)
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\open_icarus_firewall_ports.ps1"
echo.
echo Done.
pause
