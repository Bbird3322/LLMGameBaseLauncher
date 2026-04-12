@echo off
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0START.ps1"
exit /b %errorlevel%
