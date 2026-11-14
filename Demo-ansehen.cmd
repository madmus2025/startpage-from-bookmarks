@echo off
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Startseite.ps1" -Demo -Ausgabe "%~dp0demo.html" -Oeffnen
