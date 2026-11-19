# CI: make sure Inno Setup 6 (ISCC.exe) is there for app/windows/build.ps1, and tell later steps where it is.
$ErrorActionPreference = 'Stop'
$dirs = 'C:\Program Files (x86)\Inno Setup 6', 'C:\Program Files\Inno Setup 6'
$dir = $dirs | Where-Object { Test-Path (Join-Path $_ 'ISCC.exe') } | Select-Object -First 1
if (-not $dir) {
    Write-Host 'Inno Setup not on the runner image: installing it with Chocolatey'
    choco install innosetup --yes --no-progress
    if ($LASTEXITCODE) { throw 'choco install innosetup failed' }
    $dir = $dirs | Where-Object { Test-Path (Join-Path $_ 'ISCC.exe') } | Select-Object -First 1
    if (-not $dir) { throw 'ISCC.exe not found after installing Inno Setup' }
}
Write-Host "Inno Setup: $dir"
# AppendAllText writes UTF-8 without a BOM (Out-File -Encoding utf8 in Windows PowerShell 5.1 would add one)
if ($env:GITHUB_ENV) { [IO.File]::AppendAllText($env:GITHUB_ENV, "INNO_SETUP_DIR=$dir`n") }
