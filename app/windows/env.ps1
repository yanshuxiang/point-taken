# Dot-source before building: keeps the .NET SDK's first-run files and the NuGet cache off C:.
#   . app\windows\env.ps1; dotnet build app\windows\PointTaken.Windows.sln
# DOTNET_ROOT may already point at an SDK; else the one in D:\tools\dotnet is used when it exists.
if (-not $env:DOTNET_ROOT -and (Test-Path 'D:\tools\dotnet\dotnet.exe')) { $env:DOTNET_ROOT = 'D:\tools\dotnet' }
if ($env:DOTNET_ROOT) { $env:PATH = "$env:DOTNET_ROOT;$env:PATH" }
if (Test-Path 'D:\') {
    if (-not $env:NUGET_PACKAGES) { $env:NUGET_PACKAGES = 'D:\AI-cache\nuget' }
    if (-not $env:DOTNET_CLI_HOME) { $env:DOTNET_CLI_HOME = 'D:\AI-cache\dotnet-home' }
    $env:TEMP = 'D:\AI-cache\tmp'; $env:TMP = 'D:\AI-cache\tmp'
    New-Item -ItemType Directory -Force $env:NUGET_PACKAGES, $env:DOTNET_CLI_HOME, $env:TEMP | Out-Null
}
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
