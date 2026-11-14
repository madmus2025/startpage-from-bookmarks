@echo off
chcp 65001 >nul
if exist "%LOCALAPPDATA%\Startseite\Startseite.ps1" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\Startseite\Startseite.ps1" -Deinstallieren
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Startseite.ps1" -Deinstallieren
)
echo.
pause
