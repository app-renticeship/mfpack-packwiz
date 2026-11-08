# Seeds Distant Horizons LOD cache for this server (client-side). Never fails the launch, never overwrites a real cache.
$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot
try {
  $url = 'https://github.com/app-renticeship/mfpack-packwiz/releases/download/dh-seed-1/seed.sqlite'
  $sha = '9634bb23be547cca7fa1124aa71f5dfa408c99ec0fb377b6fe2801071771bcf6'
  $key = 'bgoc0eih1nhd4@minecraft@@overworld'
  $minBytes = 50MB
  $root = Join-Path $PSScriptRoot 'Distant_Horizons_server_data'
  $targets = New-Object 'System.Collections.Generic.List[string]'
  foreach ($name in @('mc%2Emfserver%2Exyz25565', 'The+Illustrious+MFPack')) {
    $targets.Add((Join-Path (Join-Path $root $name) $key))
  }
  if (Test-Path $root) {
    foreach ($d in Get-ChildItem $root -Directory) {
      $k = Join-Path $d.FullName $key
      if (Test-Path $k) { $targets.Add($k) }
    }
  }
  $need = @()
  foreach ($t in ($targets | Select-Object -Unique)) {
    $db = Join-Path $t 'DistantHorizons.sqlite'
    if (-not (Test-Path $db) -or (Get-Item $db).Length -lt $minBytes) { $need += $t }
  }
  if ($need.Count -eq 0) { Write-Host '[mfpack] DH cache present - no seed needed'; exit 0 }

  $tmpDir = Join-Path $PSScriptRoot '.mfpack-dhseed'
  New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
  $tmp = Join-Path $tmpDir 'seed.sqlite'
  $ok = $false
  for ($i = 1; $i -le 3 -and -not $ok; $i++) {
    Write-Host "[mfpack] downloading LOD seed (~500 MB, one time), attempt $i"
    & curl.exe -L --fail --silent --show-error -C - -o $tmp $url
    if ((Test-Path $tmp) -and ((Get-FileHash $tmp -Algorithm SHA256).Hash.ToLower() -eq $sha)) { $ok = $true }
    elseif (Test-Path $tmp) { Remove-Item $tmp -Force }
  }
  if (-not $ok) { Write-Host '[mfpack] WARN LOD seed download failed - continuing without it'; exit 0 }

  foreach ($t in $need) {
    New-Item -ItemType Directory -Force -Path $t | Out-Null
    $db = Join-Path $t 'DistantHorizons.sqlite'
    Remove-Item "$db-wal","$db-shm" -Force -ErrorAction SilentlyContinue
    Copy-Item $tmp $db -Force
    Write-Host "[mfpack] LOD seed installed: $t"
  }
  Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
} catch {
  Write-Host "[mfpack] WARN LOD seed step failed: $($_.Exception.Message)"
}
exit 0
