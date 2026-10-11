@echo off
setlocal
if not exist "%~dp0install-shortcut.ps1" (
    echo ERROR: install-shortcut.ps1 could not be found beside this installer.
    echo Extract the complete TrackStudy ZIP and try again.
    pause
    exit /b 1
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0install-shortcut.ps1"
set "shortcut_result=%errorlevel%"
echo.
pause
exit /b %shortcut_result%
