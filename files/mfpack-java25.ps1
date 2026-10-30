# Prefer Java 25 for MFPack (JDK module-resolver fix; see Nitro docs).
# Downloads Eclipse Temurin 25 once into Prism's java folder, then points this
# instance at it. Prism has already chosen INST_JAVA for *this* launch, so if we
# switch the instance we exit 1 and ask for one relaunch.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Get-JavaMajor([string]$javaExe) {
  if (-not $javaExe -or -not (Test-Path $javaExe)) { return 0 }
  $p = Start-Process -FilePath $javaExe -ArgumentList '-version' -NoNewWindow -Wait -PassThru `
    -RedirectStandardError (Join-Path $env:TEMP 'mfpack-java-ver.err') `
    -RedirectStandardOutput (Join-Path $env:TEMP 'mfpack-java-ver.out')
  $text = ''
  foreach ($f in @((Join-Path $env:TEMP 'mfpack-java-ver.err'), (Join-Path $env:TEMP 'mfpack-java-ver.out'))) {
    if (Test-Path $f) { $text += Get-Content -Raw $f }
  }
  if ($text -match 'version "1\.(\d+)') { return [int]$Matches[1] }
  if ($text -match 'version "(\d+)') { return [int]$Matches[1] }
  return 0
}

function Find-Java25Exe {
  $candidates = @()
  $prismJava = Join-Path $env:APPDATA 'PrismLauncher\java'
  if (Test-Path $prismJava) {
    Get-ChildItem $prismJava -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      foreach ($rel in @('bin\javaw.exe', 'bin\java.exe')) {
        $p = Join-Path $_.FullName $rel
        if (Test-Path $p) { $candidates += $p }
      }
    }
  }
  foreach ($root in @(
      "${env:ProgramFiles}\Eclipse Adoptium",
      "${env:ProgramFiles}\Java",
      "${env:ProgramFiles}\Microsoft",
      "${env:LOCALAPPDATA}\Programs\Eclipse Adoptium"
    )) {
    if (Test-Path $root) {
      Get-ChildItem $root -Recurse -Filter 'javaw.exe' -ErrorAction SilentlyContinue -Depth 4 |
        ForEach-Object { $candidates += $_.FullName }
    }
  }
  foreach ($c in $candidates) {
    if ((Get-JavaMajor $c) -ge 25) { return $c }
  }
  return $null
}

function Install-Temurin25 {
  $destRoot = Join-Path $env:APPDATA 'PrismLauncher\java\jdk-25-hotspot'
  $javaw = Join-Path $destRoot 'bin\javaw.exe'
  if ((Test-Path $javaw) -and (Get-JavaMajor $javaw) -ge 25) { return $javaw }

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
  $javaw = Join-Path $destRoot 'bin\javaw.exe'
  if (-not (Test-Path $javaw)) { throw "javaw missing after install: $javaw" }
  Write-Host "[mfpack] Java 25 installed at $destRoot"
  return $javaw
}

function Set-InstanceJava25([string]$instanceCfg, [string]$javawPath) {
  if (-not (Test-Path $instanceCfg)) {
    Write-Host "[mfpack] no instance.cfg at $instanceCfg - skip Java pin"
    return
  }
  $raw = Get-Content -Raw $instanceCfg
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
  $raw = Set-Key $raw 'JavaPath' $javawPath
  # -XX:+ZGenerational is obsolete on 25+ (ZGC is generational by default)
  if ($raw -match '(?m)^JvmArgs=') {
    $raw = [regex]::Replace($raw, '(?m)^JvmArgs=(.*)$', {
      param($m)
      $args = $m.Groups[1].Value -replace '\s*-XX:\+ZGenerational', ''
      "JvmArgs=$args"
    })
  }
  Set-Content -Path $instanceCfg -Value $raw -NoNewline
  Write-Host "[mfpack] instance.cfg -> Java 25 ($javawPath)"
}

$currentMajor = Get-JavaMajor $env:INST_JAVA
Write-Host "[mfpack] current INST_JAVA major=$currentMajor ($env:INST_JAVA)"

$java25 = Find-Java25Exe
if (-not $java25) {
  try {
    $java25 = Install-Temurin25
  } catch {
    Write-Host "[mfpack] WARN: could not install Java 25: $($_.Exception.Message)"
    Write-Host '[mfpack] continuing on current Java'
    exit 0
  }
}

$cfg = $null
if ($env:INST_DIR) {
  $cfg = Join-Path $env:INST_DIR 'instance.cfg'
} elseif ($env:INST_MC_DIR) {
  $cfg = Join-Path (Split-Path $env:INST_MC_DIR -Parent) 'instance.cfg'
}
if ($cfg) { Set-InstanceJava25 $cfg $java25 }

if ($currentMajor -ge 25) {
  Write-Host '[mfpack] already on Java 25+'
  exit 0
}

# Do not exit non-zero: Prism treats that as a failed Pre-Launch (code 255).
# This launch keeps INST_JAVA (already chosen); the next Play uses Java 25.
Write-Host '[mfpack] Java 25 pinned for next launch (this Play still uses the current Java).'
exit 0
