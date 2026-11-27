@echo off
setlocal
cd /d "%~dp0"
if exist "%~dp0VidNapLauncher.exe" (
    start "" "%~dp0VidNapLauncher.exe"
    exit /b 0
)
if not exist "%~dp0VidNap.ps1" (
    echo VidNap.ps1 is missing. Restore the complete application folder.
    pause
    exit /b 2
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -File "%~dp0VidNap.ps1"
set "vidnapExit=%errorlevel%"
if not "%vidnapExit%"=="0" pause
exit /b %vidnapExit%
