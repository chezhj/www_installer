@echo off
setlocal

set "SCRIPTS_DIR=%~dp0build"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$dir = '%SCRIPTS_DIR%';" ^
  "$current = [Environment]::GetEnvironmentVariable('PATH', 'User');" ^
  "$parts = $current -split ';';" ^
  "if ($parts -notcontains $dir) {" ^
  "  [Environment]::SetEnvironmentVariable('PATH', $current + ';' + $dir, 'User');" ^
  "  Write-Host 'Added to user PATH: ' $dir" ^
  "} else {" ^
  "  Write-Host 'Already in PATH: ' $dir" ^
  "}"

echo.
echo Done. Restart your terminal for the change to take effect.
endlocal
