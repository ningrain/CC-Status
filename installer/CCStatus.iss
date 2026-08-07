#define MyAppName "CC Status"
#ifndef MyAppVersion
  #error MyAppVersion must be supplied by Build-Installer.ps1
#endif
#ifndef MyVersionInfoVersion
  #error MyVersionInfoVersion must be supplied by Build-Installer.ps1
#endif
#define MyAppPublisher "Local Codex Tools"
#define MyAppExeName "CCStatusControl.exe"

[Setup]
AppId={{B2164CC1-52ED-4B5F-907B-BA6994282155}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
VersionInfoVersion={#MyVersionInfoVersion}
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription={#MyAppName} Setup
VersionInfoProductName={#MyAppName}
VersionInfoProductVersion={#MyAppVersion}
DefaultDirName={code:GetDefaultInstallRoot}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..
OutputBaseFilename=CC-Status-Setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupLogging=yes
SetupIconFile=..\assets\CCStatus.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
CloseApplications=no
RestartApplications=no
UsePreviousAppDir=yes

[Files]
Source: "build\CCStatusControl.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\VERSION"; DestDir: "{app}"; Flags: ignoreversion
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

[Code]
const
  UninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{B2164CC1-52ED-4B5F-907B-BA6994282155}_is1';
  AppMutexName = 'Local\CCStatus-SingleInstance';

function GetExistingInstallRoot(): String;
begin
  if (not RegQueryStringValue(HKCU, UninstallKey, 'InstallLocation', Result)) or
    (Result = '') then
    Result := ExpandConstant('{localappdata}\CC Status');
end;

function GetDefaultInstallRoot(Param: String): String;
begin
  Result := GetExistingInstallRoot();
end;

function RequestRunningAppExit(): Boolean;
var
  InstallRoot: String;
  ControlPath: String;
  ExitRequestPath: String;
  ResultCode: Integer;
begin
  InstallRoot := GetExistingInstallRoot();
  ControlPath := AddBackslash(InstallRoot) + '{#MyAppExeName}';
  ExitRequestPath := AddBackslash(InstallRoot) + 'data\exit.request';

  Result := FileExists(ControlPath) and
    Exec(ControlPath, '/exit', InstallRoot, SW_HIDE, ewWaitUntilTerminated, ResultCode) and
    (ResultCode = 0);
  if not Result then
  begin
    ForceDirectories(ExtractFileDir(ExitRequestPath));
    Result := SaveStringToFile(ExitRequestPath, 'Setup requested exit.', False);
  end;
end;

function StopRunningApp(): Boolean;
var
  WaitCount: Integer;
begin
  Result := True;
  if not CheckForMutexes(AppMutexName) then
    Exit;

  if (not WizardSilent) and
    (MsgBox(
      '检测到 CC Status 正在运行。点击“确定”将自动退出并继续安装。',
      mbConfirmation,
      MB_OKCANCEL
    ) <> IDOK) then
  begin
    Result := False;
    Exit;
  end;

  RequestRunningAppExit();
  for WaitCount := 1 to 40 do
  begin
    if not CheckForMutexes(AppMutexName) then
      Exit;
    Sleep(250);
  end;

  if not WizardSilent then
    MsgBox('无法自动退出 CC Status。请手动退出后重试。', mbError, MB_OK);
  Result := False;
end;

function InitializeSetup(): Boolean;
var
  InstalledVersion: String;
  InstalledPackedVersion: Int64;
  TargetPackedVersion: Int64;
  Comparison: Integer;
begin
  Result := True;
  if RegQueryStringValue(HKCU, UninstallKey, 'DisplayVersion', InstalledVersion) and
    StrToVersion(InstalledVersion, InstalledPackedVersion) and
    StrToVersion('{#MyVersionInfoVersion}', TargetPackedVersion) then
  begin
    Comparison := ComparePackedVersion(InstalledPackedVersion, TargetPackedVersion);
    if Comparison > 0 then
    begin
      if not WizardSilent then
        MsgBox(
          Format('已安装较新版本 %s，不能降级安装 %s。', [InstalledVersion, '{#MyAppVersion}']),
          mbError,
          MB_OK
        );
      Result := False;
      Exit;
    end;

    if not WizardSilent then
    begin
      if Comparison = 0 then
      begin
        if MsgBox(
          Format('CC Status %s 已安装。是否执行修复安装？', [InstalledVersion]),
          mbConfirmation,
          MB_YESNO
        ) <> IDYES then
        begin
          Result := False;
          Exit;
        end;
      end
      else
      begin
        MsgBox(
          Format('检测到 CC Status %s，将升级到 %s。', [InstalledVersion, '{#MyAppVersion}']),
          mbInformation,
          MB_OK
        );
      end;
    end;
  end;

  Result := StopRunningApp();
end;
