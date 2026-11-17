@echo off
setlocal
set "APP_DIR=%~dp0"
echo ZAU Release Assistant - diagnostic launch mode.
echo UI log: "%LOCALAPPDATA%\ZauReleaseAssistant\assistant.log"
echo Runner log: "%LOCALAPPDATA%\ZauReleaseAssistant\runner.log"
echo.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%APP_DIR%ZauReleaseAssistant.ps1"
set "PS_EXIT_CODE=%ERRORLEVEL%"
echo.
echo PowerShell process finished with exit code %PS_EXIT_CODE%.
echo This window will remain open so the result and errors can be read.
pause >nul
endlocal
