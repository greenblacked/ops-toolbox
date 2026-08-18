<#
.SYNOPSIS
    Read-only health report for a Windows workstation.

.DESCRIPTION
    The Windows counterpart of macos-initial-setup/workstation_doctor.sh: it
    looks, it never touches. Sections:

      security   BitLocker protection on C: and Microsoft Defender state
      reboot     the registry flags Windows sets when a restart is pending
      disk       free space on C:
      wsl        whether WSL is installed, and the distros it knows about
      policy     the effective execution policy, and the scope that set it

    Every probe is best-effort by design. Get-BitLockerVolume does not exist on
    Home editions, Get-MpComputerStatus is absent where Defender has been
    replaced by another product, and both answer more fully when elevated. A
    probe that cannot answer says so and the report carries on - a diagnostic
    tool that dies on the first missing cmdlet is worse than no diagnostic tool,
    because it stops before the part you needed.

    There is no -DryRun because there is nothing to preview. -Action takes one
    value, 'report', which is the read-only default the contract checks look
    for; wsl_manage.ps1 takes the same route with its 'list' default.

.EXAMPLE
    .\workstation_doctor.ps1
    .\workstation_doctor.ps1 -Action report
    .\workstation_doctor.ps1 -MinFreePercent 20

.NOTES
    Exit codes:
      0  the report ran (warnings do not change the exit code)
      2  preflight checks failed - not Windows
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('report')]
    [string]$Action = 'report',

    [ValidateRange(0, 100)]
    [int]$MinFreePercent = 10
)

$ErrorActionPreference = 'Stop'
$script:Warnings = 0

function Write-Info { param([string]$Message) Write-Host "[info] $Message" -ForegroundColor Blue }
function Write-Ok   { param([string]$Message) Write-Host "[ ok ] $Message" -ForegroundColor Green }
function Write-Warn {
    param([string]$Message)
    $script:Warnings++
    Write-Host "[warn] $Message" -ForegroundColor Yellow
}
function Write-Err  { param([string]$Message) Write-Host "[err ] $Message" -ForegroundColor Red }
function Write-Section { param([string]$Name) Write-Host ''; Write-Host "== $Name ==" -ForegroundColor White }

# Byte-identical to the copies in windows/cleanup/clean_disk_c.ps1 and
# windows/wsl/wsl_manage.ps1 - see CONTRIBUTING.md for why this is duplicated.
function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

# --- preflight -------------------------------------------------------------
# Mirrors winget_bootstrap.ps1: wrong platform is 2. Windows PowerShell 5.1
# does not define $IsWindows at all, hence the edition test.
if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    Write-Err 'this script targets Windows'
    exit 2
}

Write-Host ''
Write-Host "workstation_doctor: $Action" -ForegroundColor White

$isAdmin = $false
try {
    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {
    Write-Info "could not determine elevation ($($_.Exception.Message))"
}
if ($isAdmin) {
    Write-Info 'running elevated'
} else {
    Write-Info 'not elevated - BitLocker and Defender may answer partially'
}

# --- security --------------------------------------------------------------
Write-Section 'security'
try {
    $volumes = @(Get-BitLockerVolume -ErrorAction Stop |
        Where-Object { $_.VolumeType -eq 'OperatingSystem' -or $_.MountPoint -eq 'C:' })
    if (-not $volumes) {
        Write-Info 'BitLocker: no operating-system volume reported'
    }
    foreach ($volume in $volumes) {
        $label = 'BitLocker {0}: {1}' -f $volume.MountPoint, $volume.VolumeStatus
        if ($volume.ProtectionStatus -eq 'On') {
            Write-Ok $label
        } else {
            Write-Warn ('{0} (protection {1})' -f $label, $volume.ProtectionStatus)
        }
    }
} catch {
    # Home editions have no BitLocker cmdlets at all, and an unelevated shell
    # gets an access error rather than an answer. Neither is a fault worth
    # warning about, so both land here as information.
    Write-Info "BitLocker: no status available ($($_.Exception.Message))"
}

try {
    $defender = Get-MpComputerStatus -ErrorAction Stop
    if ($defender.AntivirusEnabled) {
        Write-Ok 'Defender: antivirus enabled'
    } else {
        Write-Warn 'Defender: antivirus disabled'
    }
    if ($defender.RealTimeProtectionEnabled) {
        Write-Ok 'Defender: real-time protection on'
    } else {
        Write-Warn 'Defender: real-time protection off'
    }
    $age = [int]$defender.AntivirusSignatureAge
    if ($age -gt 7) {
        Write-Warn "Defender: signatures are $age day(s) old"
    } else {
        Write-Ok "Defender: signatures $age day(s) old"
    }
} catch {
    Write-Info "Defender: Get-MpComputerStatus unavailable ($($_.Exception.Message))"
}

# --- reboot ----------------------------------------------------------------
Write-Section 'reboot'
$rebootFlags = @(
    @{ Label = 'servicing (CBS)'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' },
    @{ Label = 'Windows Update'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' }
)
$pending = 0
foreach ($flag in $rebootFlags) {
    if (Test-Path $flag.Path) {
        Write-Warn ('reboot pending: {0}' -f $flag.Label)
        $pending++
    }
}

# PendingFileRenameOperations is a value under Session Manager, not a key of
# its own: an installer queued a file swap for the next boot.
$sessionManager = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
    -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
if ($sessionManager -and $sessionManager.PendingFileRenameOperations) {
    Write-Warn ('reboot pending: {0} queued file rename(s)' -f @($sessionManager.PendingFileRenameOperations).Count)
    $pending++
}

# A rename that has not been rebooted into shows up as the running name and the
# configured name disagreeing.
$active = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' `
        -Name 'ComputerName' -ErrorAction SilentlyContinue).ComputerName
$next = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' `
        -Name 'ComputerName' -ErrorAction SilentlyContinue).ComputerName
if ($active -and $next -and $active -ne $next) {
    Write-Warn ("reboot pending: rename from '{0}' to '{1}'" -f $active, $next)
    $pending++
}

if ($pending -eq 0) {
    Write-Ok 'no reboot pending'
}

# --- disk ------------------------------------------------------------------
Write-Section 'disk'
$drive = Get-PSDrive -Name C -ErrorAction SilentlyContinue
if (-not $drive) {
    Write-Info 'no C: drive reported'
} else {
    $total = $drive.Used + $drive.Free
    $percent = if ($total -gt 0) { [math]::Round(($drive.Free / $total) * 100, 1) } else { 0 }
    $line = 'C: {0} free of {1} ({2}%)' -f (Format-Size $drive.Free), (Format-Size $total), $percent
    # Ten percent remains the default because Windows updates, hibernation and
    # page-file growth become unreliable below it. Workstations with large
    # disks can choose a more conservative threshold explicitly.
    if ($percent -lt $MinFreePercent) {
        Write-Warn "$line - see ..\cleanup\clean_disk_c.ps1"
    } else {
        Write-Ok $line
    }
}

# --- wsl -------------------------------------------------------------------
Write-Section 'wsl'
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    Write-Info 'wsl.exe not found - WSL is not installed'
} else {
    wsl.exe --status *> $null
    $statusExit = $LASTEXITCODE
    if ($statusExit -ne 0) {
        Write-Info "wsl.exe is present but WSL is not operational ('wsl --status' exited $statusExit)"
    } else {
        Write-Ok 'WSL is installed'
        # wsl.exe prints UTF-16; force PowerShell to read it correctly or the
        # distro names come back as garbage (same dance as wsl_manage.ps1).
        $previousEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [Text.Encoding]::Unicode
        try {
            $listed = @((wsl.exe --list --verbose) -split "`n" |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ })
        } catch {
            $listed = @()
            Write-Info "could not list distros ($($_.Exception.Message))"
        } finally {
            [Console]::OutputEncoding = $previousEncoding
        }
        foreach ($line in $listed) {
            Write-Host "  $line" -ForegroundColor DarkGray
        }
        Write-Info 'disk usage and backups: ..\wsl\wsl_manage.ps1 list'
    }
}

# --- policy ----------------------------------------------------------------
Write-Section 'policy'
$effective = Get-ExecutionPolicy
if ($effective -in @('Restricted', 'AllSigned', 'Undefined')) {
    Write-Warn "execution policy is $effective - scripts in this repository will not run without -ExecutionPolicy Bypass"
} else {
    Write-Ok "execution policy: $effective"
}
foreach ($scope in Get-ExecutionPolicy -List) {
    Write-Host ('  {0,-16} {1}' -f $scope.Scope, $scope.ExecutionPolicy) -ForegroundColor DarkGray
}

# --- summary ---------------------------------------------------------------
$warnings = $script:Warnings
Write-Host ''
if ($warnings -gt 0) {
    Write-Warn ('{0} warning(s) above - none of them change the exit code' -f $warnings)
} else {
    Write-Ok 'nothing worth flagging'
}
exit 0
