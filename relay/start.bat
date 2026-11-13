@echo off
title AI NPCs - voice service
cd /d "%~dp0"

echo Starting the AI NPCs voice service on http://localhost:7171 ...
echo Leave this window open while you play. Close it to stop the service.
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "relay.ps1"

echo.
echo Voice service stopped. Press any key to close.
pause >nul
