; Inno Setup script for DropMate (PRD §14.2). Build the app first:
;   flutter build windows --release
; then compile this file with Inno Setup 6 (iscc installer\dropmate.iss).

#define AppName "DropMate"
#define AppVersion "1.1.0"
#define BuildDir "..\build\windows\x64\runner\Release"

[Setup]
AppId={{6F5B8C1E-2C4A-4D7E-9B1F-0D3A7E5C9A21}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Sheikh Shihab Hossain
AppPublisherURL=https://github.com/iamshihab2020/DropMate
AppSupportURL=https://github.com/iamshihab2020/DropMate/issues
LicenseFile=..\LICENSE
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
OutputDir=..\build\installer
OutputBaseFilename=DropMate-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
PrivilegesRequired=admin
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\dropmate.exe

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\dropmate.exe"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\dropmate.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Run]
; Private and Public Wi-Fi, but only from the local subnet; unpaired devices are rejected by the app anyway.
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""DropMate (local network)"" dir=in action=allow program=""{app}\dropmate.exe"" enable=yes profile=private,public remoteip=localsubnet"; Flags: runhidden
Filename: "{app}\dropmate.exe"; Description: "Start DropMate"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""DropMate (local network)"""; Flags: runhidden; RunOnceId: "fw"
Filename: "{sys}\reg.exe"; Parameters: "delete ""HKCU\Software\Classes\*\shell\DropMate"" /f"; Flags: runhidden; RunOnceId: "ctx1"
Filename: "{sys}\reg.exe"; Parameters: "delete ""HKCU\Software\Classes\Directory\shell\DropMate"" /f"; Flags: runhidden; RunOnceId: "ctx2"
