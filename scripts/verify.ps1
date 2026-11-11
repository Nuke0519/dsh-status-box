# One-command verification for the Windows companion (and anything else available).
#
#   pwsh -File scripts\verify.ps1
#
# Layers: plugin client (node, if installed) -> bridge protocol smoke -> WinForms build.

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$fail = 0
function Note($text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Ok($text) { Write-Host "PASS $text" -ForegroundColor Green }
function Bad($text) { Write-Host "FAIL $text" -ForegroundColor Red; $script:fail = 1 }
function Skip($text) { Write-Host "SKIP $text" -ForegroundColor Yellow }

Note '1/3 plugin client'
if (Get-Command node -ErrorAction SilentlyContinue) {
    node --check client.js
    if ($LASTEXITCODE -eq 0) { Ok 'client.js syntax' } else { Bad 'client.js syntax' }
    node --test tests/*.cjs | Out-Null
    if ($LASTEXITCODE -eq 0) { Ok 'pure function tests' } else { Bad 'pure function tests' }
} else {
    Skip 'node not installed'
}

Note '2/3 bridge protocol'
dotnet run --project windows\tests\BridgeSmoke -c Release | Select-Object -Last 2
if ($LASTEXITCODE -eq 0) { Ok 'bridge smoke' } else { Bad 'bridge smoke' }

Note '3/3 Windows companion'
dotnet build windows\src\DSHStatusBox.App -c Release -v q --nologo | Select-Object -Last 3
if ($LASTEXITCODE -eq 0) { Ok 'WinForms app builds' } else { Bad 'WinForms app builds' }

Note 'result'
if ($fail -eq 0) { Write-Host 'ALL CHECKS PASSED' -ForegroundColor Green } else { Write-Host 'SOME CHECKS FAILED' -ForegroundColor Red }
exit $fail
