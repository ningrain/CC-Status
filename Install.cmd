@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1"
if errorlevel 1 (
  echo.
  echo Installation failed. No existing Codex or Claude configuration should have been overwritten.
  pause
  exit /b 1
)
echo.
pause
