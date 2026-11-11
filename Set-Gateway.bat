@echo off
setlocal
chcp 65001 >nul
pushd "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-Gateway.ps1" %*
set EXIT_CODE=%ERRORLEVEL%
if not "%EXIT_CODE%"=="0" pause
popd
exit /b %EXIT_CODE%
