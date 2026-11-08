@echo off
setlocal
set "L4D2_KIT_TEST_ENTRY=%~dp0tests\Test-Validation.ps1"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -Command ". ([ScriptBlock]::Create([IO.File]::ReadAllText($env:L4D2_KIT_TEST_ENTRY))) -EntryScript $env:L4D2_KIT_TEST_ENTRY"
set "kit_exit=%ERRORLEVEL%"
pause
exit /b %kit_exit%
