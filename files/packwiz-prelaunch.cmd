@echo off
setlocal EnableExtensions EnableDelayedExpansion
REM Packwiz auto-sync before Prism launch (+ prefer Java 25)
cd /d "%~dp0"

if not defined INST_JAVA (
  echo [mfpack] INST_JAVA not set - run via Prism Pre-Launch only
  exit /b 1
)

echo [mfpack] ensuring Java 25 for faster NeoForge module resolve
if exist "%~dp0mfpack-java25.ps1" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0mfpack-java25.ps1"
  if errorlevel 1 (
    echo [mfpack] WARN: Java 25 helper failed - continuing on current Java
  )
) else (
  echo [mfpack] mfpack-java25.ps1 not synced yet - skipping
)

set "PACK_URL=https://app-renticeship.github.io/mfpack-packwiz/pack.toml"
set "BOOT=packwiz-installer-bootstrap.jar"
if not exist "%BOOT%" (
  echo [mfpack] missing %BOOT%
  exit /b 1
)

echo [mfpack] packwiz sync from %PACK_URL%
set "PW_OK=0"
for /L %%i in (1,1,3) do (
  if not "!PW_OK!"=="1" (
    "%INST_JAVA%" -jar "%BOOT%" -g "%PACK_URL%"
    if not errorlevel 1 (
      set "PW_OK=1"
    ) else (
      echo [mfpack] packwiz attempt %%i failed - retrying...
      ping -n 3 127.0.0.1 >nul
    )
  )
)
if not "!PW_OK!"=="1" (
  echo [mfpack] ERROR: packwiz sync failed after retries - refusing stale launch
  exit /b 1
)

if exist packwiz.json (
  echo [mfpack] pruning duplicate versions of pack-managed jars
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0packwiz-prune.ps1"
)

echo [mfpack] sync ok
exit /b 0
