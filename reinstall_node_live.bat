@echo off
powershell -NoProfile -ExecutionPolicy Bypass -Command "& { Unregister-ScheduledTask -TaskName 'QP Node Live Status' -TaskPath '\QuestPauseOps\' -Confirm:$false -ErrorAction SilentlyContinue }"
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\QuestPauseOps\scripts\deploy_scheduled_tasks.ps1" -TaskName "QP Node Live Status"
pause
