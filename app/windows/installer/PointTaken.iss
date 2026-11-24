; Point Taken for Windows installer (Inno Setup 6). build.ps1 compiles it after `dotnet publish`:
;   ISCC.exe /DAppVersion=0.2.0-beta.2 /DAppVersionCore=0.2.0 /DSourceDir=<publish dir> /DOutputDir=<dist>
;            /DOutputName=PointTaken-0.2.0-beta.2-windows-x64-setup PointTaken.iss
; Per-user install (no administrator prompt) into %LOCALAPPDATA%\Programs\Point Taken, Start menu entry, uninstaller.
; Records, settings and models live outside the install folder and are kept on uninstall.

#ifndef AppVersion
  #error Pass /DAppVersion=<version from VERSION>
#endif
#ifndef AppVersionCore
  #define AppVersionCore AppVersion
#endif
#ifndef SourceDir
  #error Pass /DSourceDir=<dotnet publish output>
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif
#ifndef OutputName
  #define OutputName "PointTaken-" + AppVersion + "-windows-x64-setup"
#endif

[Setup]
; never change AppId: it is how upgrades find the installed copy
AppId={{3F710704-611E-4139-9C55-2B6A3164D740}
AppName=Point Taken
AppVersion={#AppVersion}
AppVerName=Point Taken {#AppVersion}
AppPublisher=Point Taken
AppPublisherURL=https://github.com/yanshuxiang/point-taken
AppSupportURL=https://github.com/yanshuxiang/point-taken/issues
AppUpdatesURL=https://github.com/yanshuxiang/point-taken/releases
VersionInfoVersion={#AppVersionCore}
VersionInfoProductVersion={#AppVersionCore}
VersionInfoProductTextVersion={#AppVersion}
DefaultDirName={autopf}\Point Taken
DefaultGroupName=Point Taken
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Windows 10 2004: the capture exclusion the app relies on (app/windows/README.md)
MinVersion=10.0.19041
SetupIconFile=..\PointTaken.App\Assets\icon.ico
UninstallDisplayIcon={app}\PointTaken.exe
UninstallDisplayName=Point Taken
OutputDir={#OutputDir}
OutputBaseFilename={#OutputName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
AppMutex=PointTaken.Windows.SingleInstance

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
#if FileExists(AddBackslash(CompilerPath) + "Languages\ChineseSimplified.isl")
Name: "zh"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; an upgrade replaces the whole program folder: files a newer build no longer ships must not linger
Type: filesandordirs; Name: "{app}\scripts"
Type: filesandordirs; Name: "{app}\models"

[Icons]
Name: "{autoprograms}\Point Taken"; Filename: "{app}\PointTaken.exe"
Name: "{autodesktop}\Point Taken"; Filename: "{app}\PointTaken.exe"; Tasks: desktopicon

[Registry]
; "start with Windows" (set from the app's settings) points into {app}: remove it with the app
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "Point Taken"; Flags: uninsdeletevalue dontcreatekey

[Run]
Filename: "{app}\PointTaken.exe"; Description: "{cm:LaunchProgram,Point Taken}"; Flags: nowait postinstall skipifsilent
