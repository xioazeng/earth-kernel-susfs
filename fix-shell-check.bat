@echo off
setlocal EnableDelayedExpansion
title DSH shell diagnostic

set "OUT=%~dp0dsh-shell-diagnostic.txt"

echo ============================================================>"%OUT%"
echo  DSH shell failure diagnostic>con
echo  Windows 0xC0000142 = STATUS_DLL_INIT_FAILED>con
echo ============================================================>>"%OUT%"
echo.>>"%OUT%"

call :section "1. Windows version / build"
call :run "cmd /c ver"
call :run "cmd /c wmic os get Caption,Version,BuildNumber /value"

call :section "2. PowerShell 7 (pwsh) - THE SUSPECT"
call :which pwsh
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" (
  echo [found] %ProgramFiles%\PowerShell\7\pwsh.exe>>"%OUT%"
) else (
  echo [MISSING] %ProgramFiles%\PowerShell\7\pwsh.exe>>"%OUT%"
)
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" (
  echo --- pwsh -NoProfile -Command "$PSVersionTable" --->>"%OUT%"
  "%ProgramFiles%\PowerShell\7\pwsh.exe" -NoProfile -Command "$PSVersionTable | Out-String" >>"%OUT%" 2>&1
  echo exit code: !errorlevel!>>"%OUT%"
) else (
  echo [MISSING] %ProgramFiles%\PowerShell\7\pwsh.exe>>"%OUT%"
)

call :section "3. Windows PowerShell 5.1 (for comparison)"
call :run "powershell -NoProfile -Command $PSVersionTable.PSVersion.ToString()"

call :section "4. cmd.exe and basic process creation"
call :run "cmd /c echo hello-from-cmd"

call :section "5. Resource exhaustion checks"
call :run "cmd /c tasklist /fi \"imagename eq pwsh.exe\""
call :run "cmd /c tasklist /fi \"imagename eq powershell.exe\""
echo --- process count --->>"%OUT%"
cmd /c "tasklist /fo csv /nh | find /c /v \"\"" >>"%OUT%" 2>&1

call :section "6. Disk space / RAM"
call :run "cmd /c wmic logicaldisk get Caption,FreeSpace,Size"
call :run "cmd /c wmic ComputerSystem get TotalPhysicalMemory,NumberOfLogicalProcessors /value"

call :section "7. TEMP writability (pwsh needs this at startup)"
if "%TEMP%"=="" (echo [FAIL] TEMP is EMPTY>>"%OUT%") else (echo [ok] TEMP=%TEMP%>>"%OUT%")
if exist "%LOCALAPPDATA%\Temp" (echo [ok] LOCALAPPDATA\Temp exists>>"%OUT%") else (echo [FAIL] LOCALAPPDATA\Temp missing>>"%OUT%")
echo test>"%TEMP%\_dsh_write_test.txt" 2>nul && (echo [ok] TEMP is writable>>"%OUT%" & del "%TEMP%\_dsh_write_test.txt") || echo [FAIL] TEMP is NOT writable>>"%OUT%"

call :section "8. .NET / hostfxr (pwsh 7 depends on this)"
if exist "%ProgramFiles%\dotnet\host\fxr" (
  echo [found] %ProgramFiles%\dotnet\host\fxr>>"%OUT%"
  dir /b "%ProgramFiles%\dotnet\host\fxr">>"%OUT%" 2>&1
) else (
  echo [MISSING] %ProgramFiles%\dotnet\host\fxr>>"%OUT%"
)
call :run "cmd /c dotnet --list-runtimes"

call :section "9. Check for corrupted/failed PowerShell modules"
call :run "cmd /c sfc /verifyonly"

call :section "10. Security software (common blocker)"
call :run "cmd /c wmic /namespace:\\root\SecurityCenter2 path AntiVirusProduct get displayName,productState /value"

call :section "11. WSL availability (needed for kernel compile)"
call :run "cmd /c wsl --status"
call :run "cmd /c wsl -l -v"

echo.
echo ============================================================>con
echo  DONE - please send me this file:>con
echo  %OUT%>con
echo ============================================================>>"%OUT%"
echo.
echo.
echo Report saved to: %OUT%
echo.
pause
exit /b 0

:section
echo.
echo ------------------------------------------------------------
echo  %~1
echo ------------------------------------------------------------
echo.>>"%OUT%"
echo ------------------------------------------------------------ >>"%OUT%"
echo  %~1>>"%OUT%"
echo ------------------------------------------------------------ >>"%OUT%"
exit /b 0

:run
echo --- %~1 --->>"%OUT%"
cmd /c %~1 >>"%OUT%" 2>&1
echo exit code: !errorlevel!>>"%OUT%"
exit /b 0

:which
where %~1 >>"%OUT%" 2>&1
if !errorlevel!==0 (echo [found] %~1>>"%OUT%") else (echo [MISSING] %~1>>"%OUT%")
exit /b 0
