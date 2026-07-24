#define MyAppName "Any2MD"
#define MyAppVersion "0.1.0"
#define MyAppExeName "any2md_desktop.exe"

[Setup]
AppId={{26B9F730-6763-4E8B-9197-17683960DC25}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher=Any2MD
DefaultDirName={localappdata}\Programs\Any2MD
DefaultGroupName=Any2MD
PrivilegesRequired=lowest
OutputDir=Output
OutputBaseFilename=Any2MD-0.1.0-windows-x64
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#MyAppExeName}

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Any2MD"; Filename: "{app}\{#MyAppExeName}"
Name: "{userdesktop}\Any2MD"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加图标："

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "启动 Any2MD"; Flags: nowait postinstall skipifsilent
