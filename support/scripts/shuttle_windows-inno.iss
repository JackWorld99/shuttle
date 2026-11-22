; Shuttle Windows installer (Inno Setup 6)
; Copied from LocalSend's compile_windows_exe-inno.iss and modified. Differences from upstream:
; - Name, exe and AppId are Shuttle's own. With the same AppId as the official LocalSend, the two would
;   overwrite and uninstall each other.
; - The MSIX helper sections are removed: on uninstall, upstream runs
;   Get-AppxPackage LocalSend.App | Remove-AppxPackage, which would remove the official LocalSend's component.
;   Our exe is unsigned, so it could not install the MSIX helper anyway (the portable zip leaves it out too).
; - Per-user install only: no administrator rights and no "install for all users" question. Default location:
;   %LOCALAPPDATA%\Programs\Shuttle.
; - The UI follows the Windows display language: Simplified Chinese on Chinese Windows, English everywhere else
;   (no language dialog).
; - If Shuttle is running before install / uninstall, setup asks to quit it from the tray first.
; - On uninstall, asks whether to delete the settings too (default: no), and removes the autostart entry and the
;   "Send to" shortcut that Shuttle itself created.
; - Auto-update: after downloading and verifying a new installer, Shuttle starts it like this:
;     Shuttle-Setup-x.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SHUTTLEUPDATE=1 [/PORTABLE=1] [/HIDDEN=1] /DIR=<program folder> /LOG=<log file>
;   and then quits. In update mode there is no "please quit" dialog: setup waits up to 30 seconds for Shuttle to
;   exit, reopens Shuttle once installed (with --hidden, back to the tray, if /HIDDEN=1 was given), and reopens
;   the old version if the install did not succeed.
;   /PORTABLE=1 = portable copy: installs into its own folder without an uninstaller, Start menu or desktop
;   shortcuts (like the portable zip).
;
; Settings file: a settings.json next to Shuttle.exe is used if present (portable mode), otherwise
; %APPDATA%\Shuttle\settings.json (see app/lib/provider/persistence_provider.dart). The installer contains no
; settings.json and leaves an existing one alone on upgrade (installing over an older version).
;
; Build (for CI see .github/workflows/shareme_windows.yml):
;   iscc "/DPayloadDir=<Release folder of flutter build windows, with the VC runtime DLLs added>" "/DResultDir=<output folder>"
;        "/DMyAppVersion=<version from support/scripts/shuttle_version.sh>" support\scripts\shuttle_windows-inno.iss
; The exe is unsigned, so there is no SignTool.

#ifndef PayloadDir
  #define PayloadDir "..\..\app\build\windows\x64\runner\Release"
#endif
#ifndef ResultDir
  #define ResultDir "..\..\app\build\installer"
#endif
#ifndef MyAppVersion
  #define MyAppVersion "1.18.2"
#endif

#define MyAppName "Shuttle"
#define MyAppExeName "Shuttle.exe"

[Setup]
; Shuttle's own AppId. Do not change it: upgrades rely on it to recognize an existing install, and a different
; AppId would install a second copy.
AppId={{7840FBA4-023A-4668-BCE2-D17981C43955}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppName}
DefaultDirName={autopf}\{#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir={#ResultDir}
OutputBaseFilename=Shuttle-Setup-{#MyAppVersion}
SetupIconFile=..\..\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
; Portable update (/PORTABLE=1): no uninstaller and no entry in "Installed apps" (the portable-mode use of
; Uninstallable described in the Inno Setup documentation)
Uninstallable=not IsPortable
CreateUninstallRegKey=not IsPortable
Compression=lzma
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible
; Pick the language from the Windows display language instead of asking (English, the first entry, is the fallback)
ShowLanguageDialog=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "..\build\windows\inno\ChineseSimplified.isl"

[CustomMessages]
english.ShuttleRunning=Shuttle is running.%n%nFind the Shuttle icon in the tray at the bottom right of the screen, right-click it and choose Exit, then click Retry.
english.DeleteSettings=Also delete Shuttle's settings?%n%nThey hold this computer's device identity and pairings. If you delete them and install again, your phone has to scan the QR code to pair again.%n%nIf you're not sure, choose No.
chinesesimplified.ShuttleRunning=Shuttle 正在运行。%n%n请在屏幕右下角的托盘里找到 Shuttle 图标，右键选「退出」，然后点「重试」。
chinesesimplified.DeleteSettings=要不要同时删除 Shuttle 的设置？%n%n设置里有这台电脑的设备身份和配对记录。删了以后再安装，手机要重新扫码配对。%n%n不确定就选「否」。

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#PayloadDir}\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs
; NOTE: Don't use "Flags: ignoreversion" on any shared system files

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Check: not IsPortable
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon; Check: not IsPortable

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
; Auto-update: reopen Shuttle after a silent install too (the entry above has skipifsilent, so it does not run
; when silent)
Filename: "{app}\{#MyAppExeName}"; Parameters: "{code:RelaunchParams}"; WorkingDir: "{app}"; Flags: nowait; Check: IsUpdate

[UninstallDelete]
; "Send to" shortcut created when the context menu option is turned on in the app's settings
; (app/lib/util/native/context_menu_helper.dart)
Type: files; Name: "{userappdata}\Microsoft\Windows\SendTo\{#MyAppName}.lnk"

[Code]
const
  RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';

var
  { Update mode: the installation has completed }
  UpdateInstalled: Boolean;

function IsUpdate(): Boolean;
begin
  Result := ExpandConstant('{param:SHUTTLEUPDATE|0}') = '1';
end;

function IsPortable(): Boolean;
begin
  Result := ExpandConstant('{param:PORTABLE|0}') = '1';
end;

{ Relaunch after install: if Shuttle was hidden in the tray (/HIDDEN=1), pass --hidden so it goes back to the
  tray (startHiddenFlag in app/lib/util/native/autostart_helper.dart) }
function RelaunchParams(Param: String): String;
begin
  if ExpandConstant('{param:HIDDEN|0}') = '1' then
    Result := '--hidden'
  else
    Result := '';
end;

{ Uses WMI to look for any process named Shuttle.exe (portable copies count too: two running copies would
  compete for the port and share one device identity).
  If the query fails, assume it is not running; Inno itself prompts later if files are in use. }
function IsShuttleRunning(): Boolean;
var
  Locator, Service, Procs: Variant;
begin
  Result := False;
  try
    Locator := CreateOleObject('WbemScripting.SWbemLocator');
    Service := Locator.ConnectServer('.', 'root\CIMV2');
    Procs := Service.ExecQuery('SELECT ProcessId FROM Win32_Process WHERE Name = ''{#MyAppExeName}''');
    Result := Procs.Count > 0;
  except
    Result := False;
  end;
end;

{ Whether the Shuttle.exe at the given path is running (path compared case-insensitively). If the query fails,
  assume it is not running.
  Update mode waits only for the copy being updated: when a portable copy was updated while another Shuttle was
  running on the same PC, waiting for "any process named Shuttle.exe" timed out after 30 seconds and the update
  was abandoned. }
function IsShuttleRunningAt(ExePath: String): Boolean;
var
  Locator, Service, Procs, Proc: Variant;
  I: Integer;
begin
  Result := False;
  try
    Locator := CreateOleObject('WbemScripting.SWbemLocator');
    Service := Locator.ConnectServer('.', 'root\CIMV2');
    Procs := Service.ExecQuery('SELECT ExecutablePath FROM Win32_Process WHERE Name = ''{#MyAppExeName}''');
    for I := 0 to Procs.Count - 1 do
    begin
      try
        Proc := Procs.ItemIndex(I);
        if CompareText(Proc.ExecutablePath, ExePath) = 0 then
        begin
          Result := True;
          Exit;
        end;
      except
        { Skip processes whose path cannot be read (e.g. another user's) }
      end;
    end;
  except
    Result := False;
  end;
end;

{ The Shuttle.exe being updated in update mode: /DIR from the command line plus the exe name }
function UpdateTargetExe(): String;
begin
  Result := AddBackslash(ExpandConstant('{param:DIR|}')) + '{#MyAppExeName}';
end;

{ Never force-close Shuttle on the user's behalf: if it is killed while writing its settings, settings.json
  could be corrupted and the device identity lost.
  In a silent install (/SUPPRESSMSGBOXES) the dialog takes its default answer "Cancel", so setup exits instead
  of hanging. }
function WaitUntilShuttleClosed(): Boolean;
begin
  Result := True;
  while IsShuttleRunning() do
  begin
    if SuppressibleMsgBox(CustomMessage('ShuttleRunning'), mbError, MB_RETRYCANCEL, IDCANCEL) = IDCANCEL then
    begin
      Result := False;
      Exit;
    end;
  end;
end;

{ Update mode: Shuttle quits by itself after starting the installer, so wait up to 30 seconds without a dialog.
  Only waits for the copy in /DIR (see IsShuttleRunningAt). }
function WaitForShuttleExit(): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to 60 do
  begin
    if not IsShuttleRunningAt(UpdateTargetExe()) then
    begin
      Result := True;
      Exit;
    end;
    Sleep(500);
  end;
  Log('Shuttle did not exit within 30 seconds; not updating');
end;

function InitializeSetup(): Boolean;
begin
  if IsUpdate() then
    Result := WaitForShuttleExit()
  else
    Result := WaitUntilShuttleClosed();
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    UpdateInstalled := True;
end;

// Update mode, install failed (files in use, disk full, timed out waiting for Shuttle to exit, ...; Inno has
// already rolled back): if the Shuttle being updated is not running, reopen the old version so the user is not
// left without Shuttle. Without this, giving up after the wait timed out left no Shuttle running, because it had
// already quit for the update.
// The install location constant ({app}) may not be set yet at this point, so use /DIR from the command line.
procedure DeinitializeSetup();
var
  OldExe: String;
  ResultCode: Integer;
begin
  if IsUpdate() and not UpdateInstalled then
  begin
    OldExe := UpdateTargetExe();
    if FileExists(OldExe) and not IsShuttleRunningAt(OldExe) then
    begin
      Log('Update not completed, reopening the old version: ' + OldExe);
      Exec(OldExe, RelaunchParams(''), ExtractFileDir(OldExe), SW_SHOWNORMAL, ewNoWait, ResultCode);
    end;
  end;
end;

function InitializeUninstall(): Boolean;
begin
  Result := WaitUntilShuttleClosed();
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  RunValue: String;
begin
  if CurUninstallStep = usUninstall then
  begin
    { Run entry written by the app's autostart setting (app/lib/util/native/autostart_helper.dart); only delete
      it if it points to this install location }
    if RegQueryStringValue(HKCU, RunKey, '{#MyAppName}', RunValue) then
      if Pos(Lowercase(ExpandConstant('{app}\{#MyAppExeName}')), Lowercase(RunValue)) > 0 then
        RegDeleteValue(HKCU, RunKey, '{#MyAppName}');
  end;

  if CurUninstallStep = usPostUninstall then
  begin
    { Default "No": after uninstalling and reinstalling, the device identity and pairings are still there.
      A silent uninstall also answers "No". }
    if SuppressibleMsgBox(CustomMessage('DeleteSettings'), mbConfirmation, MB_YESNO or MB_DEFBUTTON2, IDNO) = IDYES then
    begin
      DeleteFile(ExpandConstant('{app}\settings.json'));
      { Files next to the settings file: the previous version's backup settings.json.bak, a leftover .tmp that
        was never swapped in, and copies of corrupt files (.corrupt-<time>) }
      DelTree(ExpandConstant('{app}\settings.json.*'), False, True, False);
      DelTree(ExpandConstant('{userappdata}\{#MyAppName}'), True, True, True);
      RemoveDir(ExpandConstant('{app}'));
    end;
  end;
end;
