param([Parameter(Mandatory=$true)][string]$Run)
$ErrorActionPreference = 'Stop'
if ($Run -notmatch '^[A-Za-z0-9_-]+$') { throw 'Invalid run identifier' }
$Exp = Split-Path -Parent $PSScriptRoot
$Out = Join-Path $Exp "results\$Run"
if (Test-Path -LiteralPath $Out) { throw 'Use a new run identifier' }
New-Item -ItemType Directory -Path $Out | Out-Null
$Sources = Get-Content -LiteralPath (Join-Path $Exp 'cases\public_sources.json') -Raw | ConvertFrom-Json
$Manifest = foreach ($Source in $Sources) {
    $Target = Join-Path $Out $Source.file
    Invoke-WebRequest -UseBasicParsing -Uri $Source.url -OutFile $Target
    [pscustomobject]@{url=$Source.url; file=$Source.file; retrieved_utc=[DateTime]::UtcNow.ToString('o'); bytes=(Get-Item -LiteralPath $Target).Length; sha256=(Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash.ToLowerInvariant()}
}
$Manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Out 'sources_manifest.json') -Encoding utf8
$Manifest | Format-Table file,bytes,sha256
