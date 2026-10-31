# Force FTB Chunks map off M so Xaero can own it. Idempotent.
$ErrorActionPreference = "Continue"
$opt = Join-Path $PSScriptRoot "options.txt"
if (-not (Test-Path -LiteralPath $opt)) { exit 0 }
$raw = Get-Content -LiteralPath $opt -Raw
if ($null -eq $raw) { exit 0 }
$orig = $raw
function Set-OptKey([string]$text, [string]$name, [string]$value) {
  $line = "${name}:${value}"
  if ($text -match ("(?m)^" + [regex]::Escape($name) + ":")) {
    return [regex]::Replace($text, ("(?m)^" + [regex]::Escape($name) + ":.*$"), $line)
  }
  return ($text.TrimEnd() + "`r`n" + $line + "`r`n")
}
$raw = Set-OptKey $raw "key_key.ftbchunks.map" "key.keyboard.unknown"
$raw = Set-OptKey $raw "key_key.ftbchunks.claim_manager" "key.keyboard.unknown"
$raw = Set-OptKey $raw "key_gui.xaero_open_map" "key.keyboard.m"
if ($raw -ne $orig) {
  Set-Content -LiteralPath $opt -Value $raw -NoNewline
  Write-Host "[mfpack] unbound FTB Chunks map key (M left for Xaero)"
}
exit 0
