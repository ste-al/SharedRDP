@echo off
rem Opens the Shared Remote Desktop dashboard without a console window.
rem Keep this file next to SharedRdp-Dashboard.ps1 and Connect-SharedRdp.ps1.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0SharedRdp-Dashboard.ps1" %*
