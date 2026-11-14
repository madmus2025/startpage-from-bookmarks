@echo off
rem Oeffnet das Einrichtungsfenster der Startseite
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Startseite.ps1" -Oberflaeche
