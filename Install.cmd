@echo off
setlocal
set "L4D2_KIT_ENTRY=%~dp0scripts\LanKit.ps1"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -Command "& ([ScriptBlock]::Create([IO.File]::ReadAllText($env:L4D2_KIT_ENTRY))) -Action Install -EntryScript $env:L4D2_KIT_ENTRY"
set "kit_exit=%ERRORLEVEL%"
if not "%kit_exit%"=="0" echo Installation failed. Read the error above. No execution policy was changed.
pause
exit /b %kit_exit%
