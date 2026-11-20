# CopilotGuard

Remove Microsoft Copilot from Windows 11 and **keep it gone**, without breaking anything else.

Uninstalling Copilot is easy. Keeping it uninstalled is not: Store and Office updates bring it back.
CopilotGuard removes it, sets the policies that tell Windows you don't want it, and installs a small
watchdog that removes it again if it comes back. A tray widget shows you what the watchdog has done.

- Works on **Windows 11 Home and Pro** (and Enterprise/Education)
- Plain PowerShell you can read before running. No downloads, no telemetry, no network calls
- Every registry change is backed up, and `uninstall.ps1` puts everything back

> Not affiliated with Microsoft. "Copilot" is a Microsoft trademark, used here only to describe what this tool removes.

## Install

1. Download `CopilotGuard.zip` from [Releases](../../releases) and extract it.
2. Open **PowerShell as Administrator** in the extracted folder and run:

```powershell
Get-ChildItem *.ps1, *.exe | Unblock-File
Set-ExecutionPolicy -Scope Process Bypass -Force
.\install.ps1
```

3. Restart, or sign out and back in.

### Options

| Option | What it does |
|---|---|
| `-KeepM365App` | Leave the **Microsoft 365 Copilot** app alone (it's the renamed Office hub app; keep it if you use it to launch Office) |
| `-SkipEdge` | Don't touch Edge. Otherwise Edge shows "managed by your organization", which is just these policies |
| `-SkipAppAI` | Don't turn off the AI features in Notepad and Paint |
| `-AppLocker Audit` / `-AppLocker Enforce` | Add AppLocker rules that stop Copilot from installing or launching at all. **Pro/Enterprise/Education only**: Home doesn't have the AppLocker cmdlets. Try `Audit` first, then `Enforce` |
| `-NoWidget` | Skip the tray widget |
| `-Repair` | Re-apply everything with the options you installed with (the widget's Repair button does this) |

## The tray widget

Starts 5 minutes after you log in and stays in the tray (Windows 11 may hide it under the **^**; drag it onto the taskbar to keep it visible).

- **Green**: all quiet. **Red**: the guard removed something, or Copilot is installed right now. **Gray**: checking.
- Click it for the guard log and status. It re-checks every 15 minutes and shows a notification when something changes.
- **Run guard now** and **Repair** ask for admin rights (UAC) when you click them. The widget itself never runs as admin.

## What it changes (all of it)

**Removed app packages** (for all users, and from the image new user profiles are created from):
`Microsoft.Copilot`, `Microsoft.Windows.Ai.Copilot.*`, and `Microsoft.MicrosoftOfficeHub` (unless `-KeepM365App`)

**Registry values** (originals saved to `registry-backup.json`):

| Key                                                                  | Value                                                              | Set to | Purpose                                             |
|----------------------------------------------------------------------|--------------------------------------------------------------------|--------|-----------------------------------------------------|
| `HKLM` and `HKCU\SOFTWARE\Policies\Microsoft\Windows\WindowsAI`      | `RemoveMicrosoftCopilotApp`                                        | 1      | Microsoft's own Copilot removal policy              |
| same                                                                 | `DisableAIDataAnalysis`                                            | 1      | Recall snapshots off                                |
| `HKLM` and `HKCU\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot` | `TurnOffWindowsCopilot`                                            | 1      | Legacy setting (deprecated, harmless)               |
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI`                 | `AllowRecallEnablement`                                            | 0      | Recall can't be turned on                           |
| `HKCU\...\Explorer\Advanced`                                         | `ShowCopilotButton`                                                | 0      | Taskbar button                                      |
| `HKLM\SOFTWARE\Policies\WindowsNotepad`                              | `DisableAIFeatures`                                                | 1      | Notepad AI (skip with `-SkipAppAI`)                 |
| `HKLM\...\Policies\Paint`                                            | `DisableCocreator`, `DisableGenerativeFill`, `DisableImageCreator` | 1      | Paint AI (skip with `-SkipAppAI`)                   |
| `HKLM\SOFTWARE\Policies\Microsoft\Edge`                              | `HubsSidebarEnabled`, `Microsoft365CopilotChatIconEnabled`         | 0      | Edge sidebar/Copilot button (skip with `-SkipEdge`) |

**Scheduled tasks**
- `CopilotGuard`: runs `guard.ps1` as SYSTEM at every logon and daily at 3am (catches up if the PC was off)
- `CopilotGuardWidget`: starts the tray widget 5 minutes after each logon, as the logged-in user

**AppLocker** (only with `-AppLocker`): an *allow all signed packaged apps* rule plus *deny* rules for the Copilot packages. All are named `CopilotGuard: ...`, and uninstall removes only those. The allow rule matters: a packaged-app collection with only deny rules would block Start, Settings and the Store.

**Files**: `C:\ProgramData\CopilotGuard\` (scripts, `config.json`, `guard.log`, `status.json`, backup). Only SYSTEM and Administrators can write there, since the SYSTEM task runs scripts from it.

## Uninstall

```powershell
& "$env:ProgramData\CopilotGuard\uninstall.ps1"           # add -KeepLogs to keep the log
```

Run it as the same user who installed (some values are per-user). Uninstalling does not reinstall Copilot; if you want it back:
`winget install --id 9NHT9RB2F4HD --source msstore`

## FAQ

**Copilot came back anyway?** Check the widget, or `C:\ProgramData\CopilotGuard\guard.log`. The guard removes it at the next logon or within a day. On Pro, `-AppLocker Enforce` stops it from installing at all.

**Will this break Office?** Removing the Microsoft 365 Copilot app doesn't uninstall Word/Excel/Outlook; it removes the launcher app. Use `-KeepM365App` if you rely on it.

**Why does Edge say "managed by your organization"?** Because CopilotGuard set Edge policies. Reinstall with `-SkipEdge` if that bothers you.

**Antivirus flagged the widget exe?** Unsigned PyInstaller builds sometimes get false positives. The exe is built by GitHub Actions from the source in this repo (see the workflow), and each release includes a SHA-256 hash. You can also run the widget from source instead (below).

## Run or build from source

```powershell
winget install -e --id Python.Python.3.12
py -m pip install pystray pillow
.\install.ps1            # from a repo checkout: uses widget\guard_widget.py with your Python
```

Build the exe yourself:

```powershell
py -m pip install pyinstaller pystray pillow
py -m PyInstaller --onefile --noconsole --name CopilotGuardWidget widget\guard_widget.py
```

## License

MIT. See [LICENSE](LICENSE).
