<#
.SYNOPSIS
  FlySolo installer - removes Microsoft Copilot from Windows 11 and keeps it gone.

.DESCRIPTION
  1. Removes the Copilot app packages (all users + provisioned)
  2. Sets Windows AI policies (Copilot removal policy, Recall off, taskbar button off)
  3. Optionally turns off AI in Notepad/Paint and the Copilot button/sidebar in Edge
  4. Installs a SYSTEM scheduled task that re-removes Copilot at every logon and daily
  5. Optionally adds AppLocker rules that block Copilot from installing or launching
  6. Installs the tray widget (shows the guard log and status)

  Every registry value it changes is backed up first; uninstall.ps1 puts them back.
  Run from an elevated (Admin) PowerShell.

.PARAMETER KeepM365App
  Leave the "Microsoft 365 Copilot" app (Microsoft.MicrosoftOfficeHub) alone.
.PARAMETER SkipEdge
  Don't set Edge policies (Edge would otherwise show "managed by your organization").
.PARAMETER SkipAppAI
  Don't turn off the AI features in Notepad and Paint.
.PARAMETER AppLocker
  Off (default), Audit (log only), or Enforce (block). Needs the AppLocker cmdlets,
  which Windows 11 Home doesn't have; on Home this is skipped with a warning.
.PARAMETER NoWidget
  Don't install the tray widget.
.PARAMETER Repair
  Re-apply everything using the options saved at install time (used by the widget).

.EXAMPLE
  .\install.ps1
.EXAMPLE
  .\install.ps1 -AppLocker Enforce -SkipEdge
#>
[CmdletBinding()]
param(
    [switch]$KeepM365App,
    [switch]$SkipEdge,
    [switch]$SkipAppAI,
    [ValidateSet('Off', 'Audit', 'Enforce')]
    [string]$AppLocker = 'Off',
    [switch]$NoWidget,
    [switch]$Repair
)

$Version = '0.1.0'
$ErrorActionPreference = 'Continue'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error 'Run this from an elevated (Admin) PowerShell.'
    exit 1
}

$Root        = Join-Path $env:ProgramData 'FlySolo'
$ConfigFile  = Join-Path $Root 'config.json'
$BackupFile  = Join-Path $Root 'registry-backup.json'
$GuardTask   = 'FlySolo'
$WidgetTask  = 'FlySoloWidget'
$RulePrefix  = 'FlySolo:'
$MsPublisher = 'CN=MICROSOFT CORPORATION, O=MICROSOFT CORPORATION, L=REDMOND, S=WASHINGTON, C=US'
$SourceDir   = $PSScriptRoot

# --------------------------------------------------------------- Repair: reuse saved options
if ($Repair) {
    if (-not (Test-Path $ConfigFile)) {
        Write-Error "Nothing to repair: $ConfigFile not found. Run a normal install first."
        exit 1
    }
    $saved = (Get-Content $ConfigFile -Raw | ConvertFrom-Json).options
    $KeepM365App = [bool]$saved.KeepM365App
    $SkipEdge    = [bool]$saved.SkipEdge
    $SkipAppAI   = [bool]$saved.SkipAppAI
    $NoWidget    = [bool]$saved.NoWidget
    $AppLocker   = [string]$saved.AppLocker
    Write-Host "Repairing with saved options (AppLocker=$AppLocker)." -ForegroundColor Cyan
}

function Write-Step([string]$Text) { Write-Host "`n== $Text ==" -ForegroundColor Cyan }

# --------------------------------------------------------------- registry with backup
$script:Backup = @{}
if (Test-Path $BackupFile) {
    try {
        (Get-Content $BackupFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object {
            $script:Backup[$_.Name] = $_.Value
        }
    } catch {
        Write-Warning "Couldn't read existing registry backup; originals already recorded may be lost."
    }
}

function Set-GuardedValue([string]$Path, [string]$Name, [int]$Value) {
    $key = "$Path|$Name"
    if (-not $script:Backup.ContainsKey($key)) {
        # Record the ORIGINAL value only once, so re-running install never overwrites it
        $existing = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        $script:Backup[$key] = [ordered]@{
            Path    = $Path
            Name    = $Name
            Existed = [bool]$existing
            Value   = if ($existing) { $existing.$Name } else { $null }
        }
    }
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
    Write-Host "  [reg] $Path\$Name = $Value" -ForegroundColor DarkGray
}

# --------------------------------------------------------------- 1. folder + files
Write-Step 'Preparing FlySolo folder'
New-Item -ItemType Directory -Path $Root -Force | Out-Null
# SYSTEM runs scripts from here, so only SYSTEM and Administrators may write; users can read.
icacls $Root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null

$sameDir = (Resolve-Path $SourceDir).Path.TrimEnd('\') -ieq (Resolve-Path $Root).Path.TrimEnd('\')
if (-not $sameDir) {
    foreach ($f in 'guard.ps1', 'install.ps1', 'uninstall.ps1') {
        $src = Join-Path $SourceDir $f
        if (-not (Test-Path $src)) { Write-Error "Missing $f next to install.ps1."; exit 1 }
        Copy-Item $src $Root -Force
    }
}

$patterns = @('*Microsoft.Copilot*', '*Microsoft.Windows.Ai.Copilot*')
if (-not $KeepM365App) { $patterns += '*Microsoft.MicrosoftOfficeHub*' }

[ordered]@{
    version   = $Version
    installed = (Get-Date).ToString('s')
    patterns  = $patterns
    options   = [ordered]@{
        KeepM365App = [bool]$KeepM365App
        SkipEdge    = [bool]$SkipEdge
        SkipAppAI   = [bool]$SkipAppAI
        NoWidget    = [bool]$NoWidget
        AppLocker   = $AppLocker
    }
} | ConvertTo-Json -Depth 4 | Set-Content -Path $ConfigFile -Encoding ASCII

# --------------------------------------------------------------- 2. remove packages now
Write-Step 'Removing Copilot packages'
& (Join-Path $Root 'guard.ps1')
$status = Get-Content (Join-Path $Root 'status.json') -Raw | ConvertFrom-Json
Write-Host "  removed: $($status.removed)   failed: $($status.failed)"
if ($status.failed -gt 0) { Write-Warning "Some removals failed; see $Root\guard.log" }

# --------------------------------------------------------------- 3. Windows AI policies
Write-Step 'Setting Windows AI policies'
foreach ($hive in 'HKLM:', 'HKCU:') {
    $wai = "$hive\SOFTWARE\Policies\Microsoft\Windows\WindowsAI"
    Set-GuardedValue $wai 'RemoveMicrosoftCopilotApp' 1
    Set-GuardedValue $wai 'DisableAIDataAnalysis' 1
    Set-GuardedValue "$hive\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" 'TurnOffWindowsCopilot' 1
}
Set-GuardedValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'AllowRecallEnablement' 0
Set-GuardedValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowCopilotButton' 0

if (-not $SkipAppAI) {
    Write-Step 'Turning off AI in Notepad and Paint'
    Set-GuardedValue 'HKLM:\SOFTWARE\Policies\WindowsNotepad' 'DisableAIFeatures' 1
    $paint = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint'
    Set-GuardedValue $paint 'DisableCocreator' 1
    Set-GuardedValue $paint 'DisableGenerativeFill' 1
    Set-GuardedValue $paint 'DisableImageCreator' 1
}

if (-not $SkipEdge) {
    Write-Step 'Hiding Copilot in Edge'
    $edge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    Set-GuardedValue $edge 'HubsSidebarEnabled' 0
    Set-GuardedValue $edge 'Microsoft365CopilotChatIconEnabled' 0
    Write-Host "  (Edge will show 'managed by your organization' - that's just these policies.)" -ForegroundColor DarkGray
}

$script:Backup | ConvertTo-Json -Depth 4 | Set-Content -Path $BackupFile -Encoding ASCII

# --------------------------------------------------------------- 4. guard task
Write-Step "Installing scheduled task '$GuardTask'"
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Root\guard.ps1`""
$triggers = @(
    (New-ScheduledTaskTrigger -AtLogOn),
    (New-ScheduledTaskTrigger -Daily -At 3am)
)
$principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
Register-ScheduledTask -TaskName $GuardTask -Action $action -Trigger $triggers -Principal $principal `
    -Settings $settings -Description 'FlySolo: removes Microsoft Copilot packages if they reappear.' -Force | Out-Null
Write-Host '  registered (runs at every logon and daily at 3am, catches up if missed)'

# --------------------------------------------------------------- 5. AppLocker (optional)
if ($AppLocker -ne 'Off') {
    Write-Step "AppLocker ($AppLocker)"
    if (-not (Get-Command Set-AppLockerPolicy -ErrorAction SilentlyContinue)) {
        Write-Warning 'AppLocker cmdlets are not available on this edition (Windows 11 Home). Skipping; the guard task still protects you.'
    } else {
        [xml]$x = Get-AppLockerPolicy -Local -Xml
        if (-not $x.AppLockerPolicy) { [xml]$x = '<AppLockerPolicy Version="1" />' }
        $col = $x.AppLockerPolicy.RuleCollection | Where-Object { $_.Type -eq 'Appx' }
        if (-not $col) {
            $col = $x.CreateElement('RuleCollection')
            $col.SetAttribute('Type', 'Appx')
            [void]$x.AppLockerPolicy.AppendChild($col)
        }

        function Add-Rule([string]$Name, [string]$Action, [string]$Publisher, [string]$Product) {
            if ($col.ChildNodes | Where-Object { $_ -is [System.Xml.XmlElement] -and $_.GetAttribute('Name') -eq $Name }) { return }
            [xml]$r = @"
<FilePublisherRule Id="$([guid]::NewGuid())" Name="$Name" Description="Added by FlySolo" UserOrGroupSid="S-1-1-0" Action="$Action">
  <Conditions>
    <FilePublisherCondition PublisherName="$Publisher" ProductName="$Product" BinaryName="*">
      <BinaryVersionRange LowSection="0.0.0.0" HighSection="*" />
    </FilePublisherCondition>
  </Conditions>
</FilePublisherRule>
"@
            [void]$col.AppendChild($x.ImportNode($r.DocumentElement, $true))
            Write-Host "  + rule: $Name ($Action)"
        }

        # The allow rule must exist: a deny-only packaged-app collection blocks Start, Settings, Store...
        Add-Rule "$RulePrefix allow all signed packaged apps" 'Allow' '*' '*'
        Add-Rule "$RulePrefix deny Microsoft Copilot" 'Deny' $MsPublisher 'MICROSOFT.COPILOT'
        if (-not $KeepM365App) {
            Add-Rule "$RulePrefix deny Microsoft 365 Copilot" 'Deny' $MsPublisher 'MICROSOFT.MICROSOFTOFFICEHUB'
        }
        $col.SetAttribute('EnforcementMode', $(if ($AppLocker -eq 'Enforce') { 'Enabled' } else { 'AuditOnly' }))

        $tmp = Join-Path $env:TEMP 'flysolo-applocker.xml'
        $x.Save($tmp)
        Set-AppLockerPolicy -XmlPolicy $tmp
        Remove-Item $tmp -Force

        sc.exe config AppIDSvc start= auto | Out-Null
        Start-Service AppIDSvc -ErrorAction SilentlyContinue
        Write-Host "  Application Identity service: $((Get-Service AppIDSvc).Status)"
    }
}

# --------------------------------------------------------------- 6. tray widget (optional)
if (-not $NoWidget) {
    Write-Step 'Installing tray widget'
    $exeSrc = @((Join-Path $SourceDir 'FlySoloWidget.exe')) | Where-Object { Test-Path $_ } | Select-Object -First 1
    $pySrc  = @((Join-Path $SourceDir 'widget\guard_widget.py'), (Join-Path $SourceDir 'guard_widget.py')) |
              Where-Object { Test-Path $_ } | Select-Object -First 1
    $widgetAction = $null

    if ($exeSrc) {
        if (-not $sameDir) { Copy-Item $exeSrc $Root -Force }
        $widgetAction = New-ScheduledTaskAction -Execute (Join-Path $Root 'FlySoloWidget.exe')
    } elseif ($pySrc) {
        $pyw = Get-Command pyw -ErrorAction SilentlyContinue
        if (-not $pyw) {
            Write-Warning 'No FlySoloWidget.exe and no Python launcher (pyw) found. Skipping the widget.'
        } else {
            if (-not $sameDir) { Copy-Item $pySrc (Join-Path $Root 'guard_widget.py') -Force }
            & py -c 'import pystray, PIL' 2>$null
            if ($LASTEXITCODE -ne 0) { Write-Warning 'Python is missing pystray/pillow. Run:  py -m pip install pystray pillow' }
            $widgetAction = New-ScheduledTaskAction -Execute $pyw.Source -Argument "`"$Root\guard_widget.py`""
        }
    } else {
        Write-Warning 'Widget files not found next to install.ps1. Skipping the widget.'
    }

    if ($widgetAction) {
        $t = New-ScheduledTaskTrigger -AtLogOn
        $t.Delay = 'PT5M'   # wait 5 minutes after logon
        $wSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        try {
            $wPrincipal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited   # BUILTIN\Users
            Register-ScheduledTask -TaskName $WidgetTask -Action $widgetAction -Trigger $t -Principal $wPrincipal `
                -Settings $wSettings -Description 'FlySolo tray widget (read-only status and log viewer).' `
                -Force -ErrorAction Stop | Out-Null
        } catch {
            $wPrincipal = New-ScheduledTaskPrincipal -GroupId 'BUILTIN\Users' -RunLevel Limited
            Register-ScheduledTask -TaskName $WidgetTask -Action $widgetAction -Trigger $t -Principal $wPrincipal `
                -Settings $wSettings -Description 'FlySolo tray widget (read-only status and log viewer).' -Force | Out-Null
        }
        Start-ScheduledTask -TaskName $WidgetTask -ErrorAction SilentlyContinue
        Write-Host '  registered (starts 5 minutes after each logon; started now)'
    }
}

# --------------------------------------------------------------- done
Write-Host "`nFlySolo $Version installed." -ForegroundColor Green
Write-Host "Files and logs: $Root"
Write-Host "Undo everything: & `"$Root\uninstall.ps1`""
Write-Host 'Restart (or sign out and back in) to finish.'
