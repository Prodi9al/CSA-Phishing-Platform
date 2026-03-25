@echo off
set SCRIPT_DIR=%~dp0
pushd %SCRIPT_DIR%
powershell -ExecutionPolicy Bypass -File ".\launch.ps1"
popd
pause
