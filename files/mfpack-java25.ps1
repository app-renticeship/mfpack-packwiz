# Ensure Temurin JDK 25 exists for MFPack. Prism owns instance.cfg in memory while
# running, so we only pin the file when we can; always exit 0 so Pre-Launch never
# fails with code 255.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Get-JavaMajor([string]$javaExe) {
  if (-not $javaExe -or -not (Test-Path -LiteralPath $javaExe)) { return 0 }
  $exe = $javaExe
  if ($exe -match '(?i)javaw\.exe$') { $exe = $exe -replace '(?i)javaw\.exe$','java.exe' }
  $err = Join-Path $env:TEMP 'mfpack-java-ver.err'
  $out = Join-Path $env:TEMP 'mfpack-java-ver.out'
  Remove-Item $err,$out -Force -ErrorAction SilentlyContinue
  $p = Start-Process -FilePath $exe -ArgumentList '-version' -NoNewWindow -Wait -PassThru `
    -RedirectStandardError $err -RedirectStandardOutput $out
  $text = ''
  foreach ($f in @($err, $out)) { if (Test-Path $f) { $text += Get-Content -Raw $f } }
  if ($text -match 'version "1\.(\d+)') { return [int]$Matches[1] }
  if ($text -match 'version "(\d+)') { return [int]$Matches[1] }
  return 0
}

function Find-Java25Exe {
  $prismJava = Join-Path $env:APPDATA 'PrismLauncher\java'
  if (Test-Path $prismJava) {
    foreach ($dir in Get-ChildItem $prismJava -Directory -ErrorAction SilentlyContinue) {
      foreach ($rel in @('bin\javaw.exe', 'bin\java.exe')) {
        $p = Join-Path $dir.FullName $rel
        if ((Test-Path -LiteralPath $p) -and (Get-JavaMajor $p) -ge 25) { return $p }
      }
    }
  }
  return $null
}

function Install-Temurin25 {
  $destRoot = Join-Path $env:APPDATA 'PrismLauncher\java\jdk-25-hotspot'
  $javaw = Join-Path $destRoot 'bin\javaw.exe'
  if ((Test-Path -LiteralPath $javaw) -and (Get-JavaMajor $javaw) -ge 25) { return $javaw }

  $api = 'https://api.adoptium.net/v3/binary/latest/25/ga/windows/x64/jdk/hotspot/normal/eclipse?project=jdk'
  $zip = Join-Path $env:TEMP 'mfpack-temurin25.zip'
  $extract = Join-Path $env:TEMP 'mfpack-temurin25-extract'
  Write-Host '[mfpack] downloading Eclipse Temurin JDK 25 (one-time, ~180 MB)...'
  Invoke-WebRequest -Uri $api -OutFile $zip -UseBasicParsing
  if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
  New-Item -ItemType Directory -Path $extract | Out-Null
  Expand-Archive -Path $zip -DestinationPath $extract -Force
  $jdkDir = Get-ChildItem $extract -Directory | Select-Object -First 1
  if (-not $jdkDir) { throw 'Temurin zip had no JDK folder' }
  if (Test-Path $destRoot) { Remove-Item $destRoot -Recurse -Force }
  New-Item -ItemType Directory -Force -Path (Split-Path $destRoot) | Out-Null
  Move-Item $jdkDir.FullName $destRoot
  Remove-Item $zip -Force -ErrorAction SilentlyContinue
  Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
  if (-not (Test-Path -LiteralPath $javaw)) { throw "javaw missing after install: $javaw" }
  Write-Host "[mfpack] Java 25 installed at $destRoot"
  return $javaw
}

function Set-InstanceJava25([string]$instanceCfg, [string]$javawPath) {
  if (-not (Test-Path -LiteralPath $instanceCfg)) { return }
  $raw = Get-Content -LiteralPath $instanceCfg -Raw
  $javawPath = ($javawPath -replace '\\', '/')
  function Set-Key([string]$text, [string]$key, [string]$value) {
    if ($text -match "(?m)^$key=") {
      return [regex]::Replace($text, "(?m)^$key=.*$", "$key=$value")
    }
    return ($text.TrimEnd() + "`r`n$key=$value`r`n")
  }
  $raw = Set-Key $raw 'OverrideJavaLocation' 'true'
  $raw = Set-Key $raw 'AutomaticJava' 'false'
  $raw = Set-Key $raw 'IgnoreJavaCompatibility' 'true'
  $raw = Set-Key $raw 'OverrideJavaArgs' 'true'
  $raw = Set-Key $raw 'JavaPath' $javawPath
  # Java 25 client defaults: ZGC (generational by default - never pass +ZGenerational),
  # compact headers, and Windows-friendly ZGC tuning. Keep -Dfile.encoding if present elsewhere.
  $jvm = '"-XX:+UseZGC -XX:+UseCompactObjectHeaders -XX:+DisableExplicitGC -XX:+AlwaysPreTouch -XX:+PerfDisableSharedMem -XX:+UseDynamicNumberOfGCThreads -XX:ZUncommitDelay=300 -Dfile.encoding=UTF-8"'
  $raw = Set-Key $raw 'JvmArgs' $jvm
  # Atomic-ish write
  $tmp = $instanceCfg + '.mfpack-tmp'
  Set-Content -LiteralPath $tmp -Value $raw -NoNewline
  Move-Item -LiteralPath $tmp -Destination $instanceCfg -Force
  Write-Host "[mfpack] instance.cfg -> Java 25 ($javawPath)"
}

try {
  $currentMajor = Get-JavaMajor $env:INST_JAVA
  Write-Host "[mfpack] current INST_JAVA major=$currentMajor ($env:INST_JAVA)"

  $java25 = Find-Java25Exe
  if (-not $java25) { $java25 = Install-Temurin25 }

  $cfg = $null
  if ($env:INST_DIR) { $cfg = Join-Path $env:INST_DIR 'instance.cfg' }
  elseif ($env:INST_MC_DIR) { $cfg = Join-Path (Split-Path $env:INST_MC_DIR -Parent) 'instance.cfg' }

  if ($cfg) { Set-InstanceJava25 $cfg $java25 }

  if ($currentMajor -ge 25) {
    Write-Host '[mfpack] already on Java 25+'
  } else {
    Write-Host '[mfpack] Java 25 ready. If Prism still starts 21: Settings > Java > select jdk-25-hotspot (enable Skip Java compatibility checks), then Play.'
  }
} catch {
  Write-Host "[mfpack] WARN: Java 25 helper: $($_.Exception.Message)"
}
exit 0
