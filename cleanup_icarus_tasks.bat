@echo off
title ICARUS Task Cleanup
echo ========================================
echo  ICARUS Schedule Cleanup + Redeploy
echo ========================================
echo.
echo Step 1: Remove 9 old ICARUS tasks
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\cleanup_icarus_tasks.ps1"
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
echo.
echo Step 2: Register 3 new ICARUS tasks
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\deploy_scheduled_tasks.ps1" -TaskName "*ICARUS*"
echo.
echo Done. ICARUS task schedule reorganized.
echo.
pause
