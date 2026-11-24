# Builds Point Taken for Windows: runs the tests, publishes a self-contained x64 build (no .NET needed on the user's
# PC), signs its executables, and packs it as dist\PointTaken-<version>-windows-x64.zip and
# dist\PointTaken-<version>-windows-x64-setup.exe (Inno Setup), each with a .sha256 (docs/发布与命名规则.md).
#   powershell -ExecutionPolicy Bypass -File app\windows\build.ps1 [-SkipTests] [-Run] [-Sign <thumbprint>] [-NoInstaller]
# The version comes from the repository's VERSION file (Directory.Build.props reads the same file).
#
# -Sign: the code-signing certificate's thumbprint (Cert:\CurrentUser\My or LocalMachine\My); POINT_TAKEN_SIGN_CERT
# works too. Without one nothing is signed (a warning says so).
# -Stage runs one part, for signing services that sign between the parts (.github/workflows/release.yml):
#   publish   tests + dotnet publish into dist\PointTaken-<version>-windows-x64\ (+ sign it with -Sign)
#   package   zip that folder, build the installer (+ sign the installer with -Sign)
#   checksum  write the .sha256 files (after every file is signed: signing changes the bytes)
#   all       the three in order (default)
# -Run starts the built app afterwards.
param(
    [switch]$SkipTests,
    [switch]$Run,
    [switch]$NoInstaller,
    [string]$Sign = $env:POINT_TAKEN_SIGN_CERT,
    [ValidateSet('all', 'publish', 'package', 'checksum')][string]$Stage = 'all'
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = (Resolve-Path (Join-Path $here '..\..')).Path
. (Join-Path $here 'env.ps1')

$version = (Get-Content -Raw (Join-Path $root 'VERSION')).Trim()
if ($version -notmatch '^(\d+\.\d+\.\d+)(-[0-9A-Za-z.-]+)?$') { throw "VERSION is not a semantic version: '$version'" }
$versionCore = $Matches[1]
$name = "PointTaken-$version-windows-x64"
$dist = Join-Path $root 'dist'
$stageDir = Join-Path $dist $name
$zip = Join-Path $dist "$name.zip"
$setupName = "$name-setup"
$setup = Join-Path $dist "$setupName.exe"
Write-Host "Point Taken $version ($Stage)"

function Find-SignTool {
    $kits = 'C:\Program Files (x86)\Windows Kits\10\bin'
    $tool = Get-ChildItem $kits -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\x64\\' } | Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
    if (-not $tool) { throw 'signtool.exe not found: install the Windows SDK' }
    $tool
}

function Invoke-Sign([string[]]$files) {
    if (-not $Sign) {
        Write-Warning ('not signed: ' + (($files | ForEach-Object { Split-Path $_ -Leaf }) -join ', ') + ' (no -Sign / POINT_TAKEN_SIGN_CERT)')
        return
    }
    Write-Host '== sign'
    $signtool = Find-SignTool
    & $signtool sign /sha1 $Sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /d 'Point Taken' $files
    if ($LASTEXITCODE) { throw 'signing failed' }
    foreach ($f in $files) {
        $s = Get-AuthenticodeSignature $f
        Write-Host ("  {0}: {1} | {2}" -f (Split-Path $f -Leaf), $s.SignerCertificate.Subject, $s.TimeStamperCertificate.Subject)
    }
}

function Find-Iscc {
    $candidates = @()
    if ($env:INNO_SETUP_DIR) { $candidates += Join-Path $env:INNO_SETUP_DIR 'ISCC.exe' }
    $candidates += 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe', 'C:\Program Files\Inno Setup 6\ISCC.exe',
                   (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
    $found = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $found) { $found = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source }
    $found
}

if ($Stage -in 'all', 'publish') {
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw '.NET 8 SDK not found: install it (https://dot.net) or set DOTNET_ROOT.' }
    if (-not $SkipTests) {
        Write-Host '== tests'
        dotnet test (Join-Path $here 'PointTaken.Core.Tests') -c Release --nologo -v q
        if ($LASTEXITCODE) { throw 'tests failed' }
    }

    Write-Host '== publish'
    if (Test-Path $stageDir) { Remove-Item -Recurse -Force $stageDir }
    dotnet publish (Join-Path $here 'PointTaken.App') -c Release -r win-x64 --self-contained true -p:DebugType=none -o $stageDir --nologo -v q
    if ($LASTEXITCODE) { throw 'publish failed' }
    Copy-Item (Join-Path $root 'LICENSE'), (Join-Path $root 'NOTICE') $stageDir
    Copy-Item (Join-Path $here 'README.md') (Join-Path $stageDir '使用说明.md')

    # the app's own files; the .NET runtime's files keep Microsoft's signatures
    Invoke-Sign ('PointTaken.exe', 'PointTaken.dll', 'PointTaken.Core.dll' | ForEach-Object { Join-Path $stageDir $_ })
}

if ($Stage -in 'all', 'package') {
    if (-not (Test-Path (Join-Path $stageDir 'PointTaken.exe'))) { throw "nothing to package: run -Stage publish first ($stageDir)" }
    Write-Host '== zip'
    if (Test-Path $zip) { Remove-Item -Force $zip }
    Compress-Archive -Path $stageDir -DestinationPath $zip
    Write-Host "dist\$name.zip  ($([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB)"

    if (-not $NoInstaller) {
        Write-Host '== installer'
        $iscc = Find-Iscc
        if (-not $iscc) { throw 'Inno Setup 6 not found (ISCC.exe): install it (https://jrsoftware.org/isdl.php, or `choco install innosetup`), set INNO_SETUP_DIR, or pass -NoInstaller' }
        if (Test-Path $setup) { Remove-Item -Force $setup }
        & $iscc /Q "/DAppVersion=$version" "/DAppVersionCore=$versionCore" "/DSourceDir=$stageDir" "/DOutputDir=$dist" "/DOutputName=$setupName" (Join-Path $here 'installer\PointTaken.iss')
        if ($LASTEXITCODE) { throw 'installer build failed' }
        Invoke-Sign @($setup)
        Write-Host "dist\$setupName.exe  ($([math]::Round((Get-Item $setup).Length / 1MB, 1)) MB)"
    }
}

if ($Stage -in 'all', 'checksum') {
    Write-Host '== sha256'
    foreach ($f in @($zip, $setup)) {
        if (-not (Test-Path $f)) { continue }
        $hash = (Get-FileHash $f -Algorithm SHA256).Hash.ToLowerInvariant()
        # LF only: `shasum -a 256 -c` / `sha256sum -c` read a CR as part of the file name
        [IO.File]::WriteAllText("$f.sha256", "$hash  $(Split-Path $f -Leaf)`n", [Text.Encoding]::ASCII)
        Write-Host "  $hash  $(Split-Path $f -Leaf)"
    }
}

if ($Run) { Start-Process (Join-Path $stageDir 'PointTaken.exe') }
