@echo off
if exist "%~dp0claude-niang\runtime\claude-niang-launcher.exe" (
  start "" "%~dp0claude-niang\runtime\claude-niang-launcher.exe" open && exit /b 0
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude-niang\runtime\start-supervisor.ps1"
