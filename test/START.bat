@echo off
for %%I in ("%~dp0..") do set "ROOT=%%~fI"
if exist "%ROOT%\logs\startup-popup.signal" del /q "%ROOT%\logs\startup-popup.signal"
if exist "%~dp0START.ps1" (
	powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0START.ps1" -RootDir "%ROOT%"
	exit /b %errorlevel%
)

echo Launcher entrypoint not found: test\START.ps1
exit /b 1
