#define MyAppName "CC Status"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "Local Codex Tools"
#define MyAppExeName "CCStatusControl.exe"

[Setup]
AppId={{B2164CC1-52ED-4B5F-907B-BA6994282155}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
VersionInfoVersion=1.0.0.0
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription={#MyAppName} Setup
VersionInfoProductName={#MyAppName}
VersionInfoProductVersion={#MyAppVersion}
DefaultDirName={localappdata}\CC Status
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\release
OutputBaseFilename=CC-Status-Setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupLogging=yes
SetupIconFile=..\assets\CCStatus.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
CloseApplications=no
RestartApplications=no
UsePreviousAppDir=no

[Files]
Source: "build\CCStatusControl.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\assets\CCStatus.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\app\*"; DestDir: "{tmp}\CCStatusPayload\app"; Excludes: "data\*"; Flags: recursesubdirs createallsubdirs deleteafterinstall
Source: "..\Install.ps1"; DestDir: "{tmp}\CCStatusPayload"; Flags: deleteafterinstall
Source: "..\Uninstall.ps1"; DestDir: "{tmp}\CCStatusPayload"; Flags: deleteafterinstall

[InstallDelete]
Type: files; Name: "{userstartup}\CC Status.lnk"
Type: filesandordirs; Name: "{userprograms}\CC Status"
Type: files; Name: "{userdesktop}\CC Status.lnk"

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "CC Status"; ValueData: """{app}\{#MyAppExeName}"" /start"; Flags: uninsdeletevalue

[Icons]
Name: "{group}\CC Status 控制中心"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\CCStatus.ico"
Name: "{group}\打开 CC Status"; Filename: "{app}\{#MyAppExeName}"; Parameters: "/start"; IconFilename: "{app}\CCStatus.ico"
Name: "{group}\退出 CC Status"; Filename: "{app}\{#MyAppExeName}"; Parameters: "/exit"; IconFilename: "{app}\CCStatus.ico"
Name: "{group}\卸载 CC Status"; Filename: "{uninstallexe}"; IconFilename: "{app}\CCStatus.ico"
Name: "{userdesktop}\CC Status"; Filename: "{app}\{#MyAppExeName}"; Parameters: "/start"; IconFilename: "{app}\CCStatus.ico"

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy RemoteSigned -File ""{tmp}\CCStatusPayload\Install.ps1"" -InstallRoot ""{app}"" -SkipShortcuts -SkipLaunch"; Flags: runhidden waituntilterminated; StatusMsg: "正在配置 CC Status 与 CLI 集成..."
Filename: "{app}\{#MyAppExeName}"; Parameters: "/start"; Description: "安装后启动 CC Status"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy RemoteSigned -File ""{app}\Uninstall.ps1"" -InstallRoot ""{app}"" -SkipShortcuts -SkipFileRemoval"; Flags: runhidden waituntilterminated; RunOnceId: "RemoveCCStatusIntegration"

[UninstallDelete]
Type: filesandordirs; Name: "{app}"
