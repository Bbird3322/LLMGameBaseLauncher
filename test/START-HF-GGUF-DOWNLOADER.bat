@echo off
setlocal
set "ROOT_DIR=%~dp0.."
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%ROOT_DIR%\scripts\hf-gguf-downloader.ps1"
