@echo off
set SCRIPT_DIR=%~dp0
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%claude-connect-do.ps1" %*
exit /b %ERRORLEVEL%
