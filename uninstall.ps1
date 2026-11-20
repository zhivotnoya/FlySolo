<#
.SYNOPSIS
  FlySolo uninstaller - removes everything install.ps1 set up and restores
  the registry values it changed.

.DESCRIPTION
  - Stops the tray widget and removes both scheduled tasks
  - Removes only the AppLocker rules FlySolo added (others are left alone)
  - Restores every registry value from registry-backup.json (deleting ones that
    didn't exist before)
  - Deletes %ProgramData%\FlySolo (unless -KeepLogs)

  It does NOT reinstall Copilot. If you want it back:
      winget install --id 9NHT9RB2F4HD --source msstore

  Run from an elevated PowerShell, as the same user who ran install.ps1
  (the per-user registry values live in that user's profile).

.PARAMETER KeepLogs
  Keep guard.log and status.json; remove everything else.
#>
[CmdletBinding()]
param([switch]$KeepLogs)

$ErrorActionPreference = 'Continue'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error 'Run this from an elevated (Admin) PowerShell.'
    exit 1
}

$Root       = Join-Path $env:ProgramData 'FlySolo'
$BackupFile = Join-Path $Root 'registry-backup.json'
$RulePrefix = 'FlySolo:'

function Write-Step([string]$Text) { Write-Host "`n== $Text ==" -ForegroundColor Cyan }

# --------------------------------------------------------------- widget + tasks
Write-Step 'Stopping widget and removing scheduled tasks'
Get-Process -Name 'FlySoloWidget' -ErrorAction SilentlyContinue | Stop-Process -Force
Get-CimInstance Win32_Process -Filter "Name='pythonw.exe' OR Name='pyw.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*guard_widget.py*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

foreach ($task in 'FlySoloWidget', 'FlySolo') {
    if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $task -Confirm:$false
        Write-Host "  removed task $task"
    }
}

# --------------------------------------------------------------- AppLocker rules
if (Get-Command Get-AppLockerPolicy -ErrorAction SilentlyContinue) {
    Write-Step 'Removing FlySolo AppLocker rules'
    [xml]$x = Get-AppLockerPolicy -Local -Xml
    $col = $x.AppLockerPolicy.RuleCollection | Where-Object { $_.Type -eq 'Appx' }
    if ($col) {
        $ours = @($col.ChildNodes | Where-Object { $_ -is [System.Xml.XmlElement] -and $_.GetAttribute('Name') -like "$RulePrefix*" })
        foreach ($rule in $ours) {
            [void]$col.RemoveChild($rule)
            Write-Host "  - rule: $($rule.GetAttribute('Name'))"
        }
        if ($ours.Count -gt 0) {
            if (-not ($col.ChildNodes | Where-Object { $_ -is [System.Xml.XmlElement] })) {
                $col.SetAttribute('EnforcementMode', 'NotConfigured')
            }
            $tmp = Join-Path $env:TEMP 'flysolo-applocker.xml'
            $x.Save($tmp)
            Set-AppLockerPolicy -XmlPolicy $tmp
            Remove-Item $tmp -Force
        } else {
            Write-Host '  none found'
        }
    }
}

# --------------------------------------------------------------- registry
Write-Step 'Restoring registry values'
if (Test-Path $BackupFile) {
    $backup = Get-Content $BackupFile -Raw | ConvertFrom-Json
    foreach ($entry in $backup.PSObject.Properties.Value) {
        if ($entry.Existed) {
            if (-not (Test-Path $entry.Path)) { New-Item -Path $entry.Path -Force | Out-Null }
            New-ItemProperty -Path $entry.Path -Name $entry.Name -Value $entry.Value -PropertyType DWord -Force | Out-Null
            Write-Host "  restored $($entry.Path)\$($entry.Name) = $($entry.Value)" -ForegroundColor DarkGray
        } else {
            Remove-ItemProperty -Path $entry.Path -Name $entry.Name -ErrorAction SilentlyContinue
            Write-Host "  removed  $($entry.Path)\$($entry.Name)" -ForegroundColor DarkGray
            # Clean up keys we created that are now empty
            $key = Get-Item -Path $entry.Path -ErrorAction SilentlyContinue
            if ($key -and $key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0) {
                Remove-Item -Path $entry.Path -ErrorAction SilentlyContinue
            }
        }
    }
} else {
    Write-Warning "No registry backup found at $BackupFile; registry left as-is."
}

# --------------------------------------------------------------- files
Write-Step 'Removing files'
if (Test-Path $Root) {
    if ($KeepLogs) {
        Get-ChildItem $Root -Exclude 'guard.log', 'status.json' | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  kept logs in $Root"
    } else {
        Remove-Item $Root -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  removed $Root"
    }
}

Write-Host "`nFlySolo removed. Copilot was NOT reinstalled; to get it back:" -ForegroundColor Green
Write-Host '  winget install --id 9NHT9RB2F4HD --source msstore'
Write-Host 'Restart (or sign out and back in) to finish.'
