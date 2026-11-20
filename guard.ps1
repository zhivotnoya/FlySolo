<#
  FlySolo - guard.ps1
  Removes any Copilot app package that has reappeared. Runs as SYSTEM from the
  "FlySolo" scheduled task (at logon + daily), or elevated from the tray widget.

  Reads package patterns from %ProgramData%\FlySolo\config.json.
  Writes:  guard.log    - one line per package removed (or failed)
           status.json  - heartbeat: last run time, counts (read by the widget)
#>
$ErrorActionPreference = 'Continue'

$Root       = Join-Path $env:ProgramData 'FlySolo'
$LogFile    = Join-Path $Root 'guard.log'
$StatusFile = Join-Path $Root 'status.json'
$ConfigFile = Join-Path $Root 'config.json'

if (-not (Test-Path $Root)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null }

$patterns = @('*Microsoft.Copilot*', '*Microsoft.Windows.Ai.Copilot*')
$version  = 'unknown'
if (Test-Path $ConfigFile) {
    try {
        $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        if ($cfg.patterns) { $patterns = @($cfg.patterns) }
        if ($cfg.version)  { $version  = $cfg.version }
    } catch {
        Add-Content -Path $LogFile -Value ("{0} WARNING config.json unreadable, using defaults: {1}" -f (Get-Date -Format s), $_.Exception.Message)
    }
}

function Write-GuardLog([string]$Message) {
    Add-Content -Path $LogFile -Value ("{0} {1}" -f (Get-Date -Format s), $Message)
}

$removed = 0
$failed  = 0

Get-Process -Name '*Copilot*' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

foreach ($pattern in $patterns) {
    # Installed for any user
    foreach ($pkg in @(Get-AppxPackage -AllUsers -Name $pattern -ErrorAction SilentlyContinue)) {
        try {
            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
            Write-GuardLog "removed $($pkg.PackageFullName)"
            $removed++
        } catch {
            Write-GuardLog "FAILED to remove $($pkg.PackageFullName): $($_.Exception.Message)"
            $failed++
        }
    }
    # Provisioned (copied into every new user profile)
    foreach ($prov in @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                        Where-Object { $_.DisplayName -like $pattern })) {
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
            Write-GuardLog "deprovisioned $($prov.DisplayName)"
            $removed++
        } catch {
            Write-GuardLog "FAILED to deprovision $($prov.DisplayName): $($_.Exception.Message)"
            $failed++
        }
    }
}

# Keep the log from growing forever
if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 512KB) {
    $tail = Get-Content $LogFile -Tail 500
    Set-Content -Path $LogFile -Value $tail
}

[ordered]@{
    lastRun = (Get-Date).ToString('s')
    removed = $removed
    failed  = $failed
    ranAs   = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    version = $version
} | ConvertTo-Json | Set-Content -Path $StatusFile -Encoding ASCII

if ($failed -gt 0) { exit 1 }
exit 0
