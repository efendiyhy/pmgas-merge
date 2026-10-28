@echo off
setlocal
cd /d "%~dp0"
if exist "%~dp0launch.ps1" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch.ps1"
) else (
  echo File launch.ps1 tidak ditemukan.
  pause
)
