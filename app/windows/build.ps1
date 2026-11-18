# Builds Point Taken for Windows: runs the tests, publishes a self-contained x64 build (no .NET needed on the user's
# PC) and packs it as dist\PointTaken-<version>-windows-x64.zip plus its .sha256 (docs/发布与命名规则.md).
#   powershell -ExecutionPolicy Bypass -File app\windows\build.ps1 [-SkipTests] [-Run]
# -Run starts the built app afterwards. The version comes from PointTaken.App.csproj <Version>.
param([switch]$SkipTests, [switch]$Run)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Resolve-Path (Join-Path $here '..\..')
. (Join-Path $here 'env.ps1')
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw '.NET 8 SDK not found: install it (https://dot.net) or set DOTNET_ROOT.' }

[xml]$proj = Get-Content (Join-Path $here 'PointTaken.App\PointTaken.App.csproj')
$version = ($proj.Project.PropertyGroup | Where-Object { $_.Version } | Select-Object -First 1).Version
$name = "PointTaken-$version-windows-x64"
$dist = Join-Path $root 'dist'
$stage = Join-Path $dist $name
Write-Host "Point Taken $version"

if (-not $SkipTests) {
    Write-Host '== tests'
    dotnet test (Join-Path $here 'PointTaken.Core.Tests') --nologo -v q
    if ($LASTEXITCODE) { throw 'tests failed' }
}

Write-Host '== publish'
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
dotnet publish (Join-Path $here 'PointTaken.App') -c Release -r win-x64 --self-contained true -p:DebugType=none -o $stage --nologo -v q
if ($LASTEXITCODE) { throw 'publish failed' }
Copy-Item (Join-Path $root 'LICENSE'), (Join-Path $root 'NOTICE') $stage -ErrorAction SilentlyContinue
Copy-Item (Join-Path $here 'README.md') (Join-Path $stage '使用说明.md') -ErrorAction SilentlyContinue

Write-Host '== zip'
$zip = Join-Path $dist "$name.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path $stage -DestinationPath $zip
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $name.zip" | Set-Content -Encoding ascii "$zip.sha256"
Write-Host "dist\$name.zip  ($([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB)"
if ($Run) { Start-Process (Join-Path $stage 'PointTaken.exe') }
