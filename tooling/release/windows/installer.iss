#ifndef BundleDir
  #error BundleDir is required
#endif
#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef ArtifactName
  #error ArtifactName is required
#endif
#ifndef AppIdentity
  #define AppIdentity "D6F269D7-2D17-45D6-A8E4-E2B3A9704779"
#endif

[Setup]
AppId={{{#AppIdentity}}
AppName=Fideflow
AppVersion={#AppVersion}
AppPublisher=Fideflow
DefaultDirName={localappdata}\Programs\Fideflow
DefaultGroupName=Fideflow
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
AppMutex=Local\Fideflow.Running
SetupMutex=Local\Fideflow.Setup
CloseApplications=no
RestartApplications=no
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\fideflow.exe
OutputBaseFilename={#ArtifactName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupIconFile=..\..\..\apps\fideflow_flutter\windows\runner\resources\app_icon.ico
#ifdef SigningCommand
SignTool=ff $f
SignedUninstaller=yes
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\Fideflow"; Filename: "{app}\fideflow.exe"; WorkingDir: "{app}"
Name: "{userdesktop}\Fideflow"; Filename: "{app}\fideflow.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\fideflow.exe"; Description: "Launch Fideflow"; Flags: nowait postinstall skipifsilent

[Code]
function InitializeSetup(): Boolean;
begin
  Result := True;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Existing, Requested: String;
  ExistingVersion, RequestedVersion: Int64;
begin
  Result := '';
  if RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{{#AppIdentity}}_is1', 'DisplayVersion', Existing) then
  begin
    Requested := '{#AppVersion}';
    if StrToVersion(Existing, ExistingVersion) and StrToVersion(Requested, RequestedVersion) and
       (ComparePackedVersion(ExistingVersion, RequestedVersion) > 0) then
      Result := 'A newer version of Fideflow is installed. Downgrade is not supported.';
  end;
end;

// User data, DPAPI credentials, playback checkpoints and caches live outside
// {app}; no uninstall rule removes or modifies those directories.
