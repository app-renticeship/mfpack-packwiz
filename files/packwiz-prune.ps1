$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot

if (-not (Test-Path 'packwiz.json')) {
  Write-Host '[mfpack] no packwiz.json - skip prune'
  exit 0
}

# Exact jar filenames owned by the current packwiz index (keep these).
$keep = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$j = Get-Content -Raw 'packwiz.json' | ConvertFrom-Json
foreach ($m in $j.cachedFiles.PSObject.Properties.Value) {
  if ($null -eq $m) { continue }
  $loc = [string]$m.cachedLocation
  if ($loc -like 'mods/*.jar') {
    [void]$keep.Add([IO.Path]::GetFileName($loc))
  }
}

if ($keep.Count -eq 0) {
  Write-Host '[mfpack] packwiz.json has no mods/*.jar entries - skip prune'
  exit 0
}

# Strip version / MC / loader tails so polymorph-neoforge-1.1.0 and -1.2.0 match.
function Get-Stem([string]$name) {
  $n = $name -replace '\.jar$', ''
  $n = $n -replace '[-_]v?\d.*$', ''
  return $n.ToLowerInvariant()
}

# Stems that packwiz manages (from keep list — even if the jar is not on disk yet).
$managedStems = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($name in $keep) {
  [void]$managedStems.Add((Get-Stem $name))
}

$by = @{}
Get-ChildItem 'mods' -Filter '*.jar' -ErrorAction SilentlyContinue | ForEach-Object {
  $s = Get-Stem $_.Name
  if (-not $by.ContainsKey($s)) { $by[$s] = [System.Collections.Generic.List[object]]::new() }
  $by[$s].Add($_)
}

$n = 0
foreach ($s in @($by.Keys)) {
  # Leave personal extras alone (Iris, shader helpers, etc.) unless packwiz owns that stem.
  if (-not $managedStems.Contains($s)) { continue }

  foreach ($jar in $by[$s]) {
    if ($keep.Contains($jar.Name)) { continue }
    Write-Host "[mfpack] remove stale $($jar.Name) (keeping packwiz version)"
    try {
      Remove-Item -LiteralPath $jar.FullName -Force -ErrorAction Stop
      $n++
    } catch {
      Write-Host "[mfpack] WARN could not remove $($jar.Name): $($_.Exception.Message)"
    }
  }
}

Write-Host "[mfpack] duplicate prune done ($n removed; $($keep.Count) packwiz jars protected)"
