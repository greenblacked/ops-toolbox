<#
.SYNOPSIS
    Frees disk space on C: by removing safe-to-delete caches and temp data.

.DESCRIPTION
    Cleans, by default (safe, no data loss):
      - User temp folder            ($env:TEMP)          - files older than -Days
      - Windows temp                (C:\Windows\Temp)    - files older than -Days (admin)
      - Windows Error Reporting queue                    (admin)
      - Delivery Optimization cache                      (admin)
      - Explorer thumbnail cache

    Opt-in only (still safe, but with side effects worth knowing about):
      - -IncludeRecycleBin    empties the Recycle Bin (files become unrecoverable)
      - -IncludeWindowsUpdate clears the Windows Update download cache
                              (already-downloaded pending updates re-download)
      - -IncludeDevCaches     npm / pip / NuGet caches (next builds re-download)
      - -IncludeDocker        docker system prune -f (dangling images/stopped
                              containers/unused networks; volumes are NOT touched)

    Run with -DryRun first: it reports what would be deleted and how much
    space each target would free, without deleting anything.

.EXAMPLE
    .\clean_disk_c.ps1 -DryRun
    .\clean_disk_c.ps1 -DryRun -Scope User
    .\clean_disk_c.ps1
    .\clean_disk_c.ps1 -Days 3 -IncludeRecycleBin -IncludeDevCaches
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [ValidateSet('All', 'User', 'System')]
    [string]$Scope = 'All',
    [ValidateRange(0, 3650)]
    [int]$Days = 7,
    [switch]$IncludeRecycleBin,
    [switch]$IncludeWindowsUpdate,
    [switch]$IncludeDevCaches,
    [switch]$IncludeDocker
)

$ErrorActionPreference = 'Continue'
$script:TotalFreed = 0L

$IsAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Get-FreeSpace {
    (Get-PSDrive -Name C).Free
}

# Measures then deletes (or just reports under -DryRun) files in $Path older
# than $OlderThanDays. Locked/in-use files are skipped silently - normal for
# temp folders, some files always belong to running processes.
function Clear-Target {
    param(
        [string]$Label,
        [string]$Path,
        [int]$OlderThanDays = 0,
        [switch]$NeedsAdmin
    )

    if ($NeedsAdmin -and -not $IsAdmin) {
        Write-Host ('SKIP  {0,-38} (needs elevation - run as Administrator)' -f $Label) -ForegroundColor Yellow
        return
    }
    if (-not (Test-Path $Path)) {
        Write-Host ('SKIP  {0,-38} (not found)' -f $Label) -ForegroundColor DarkGray
        return
    }

    $cutoff = (Get-Date).AddDays(-$OlderThanDays)
    $files = Get-ChildItem -Path $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $OlderThanDays -eq 0 -or $_.LastWriteTime -lt $cutoff }

    $size = ($files | Measure-Object -Property Length -Sum).Sum
    if (-not $size) { $size = 0L }

    if ($DryRun) {
        Write-Host ('WOULD {0,-38} {1,10}  ({2} files)' -f $Label, (Format-Size $size), $files.Count)
        $script:TotalFreed += $size
        return
    }

    $files | Remove-Item -Force -ErrorAction SilentlyContinue
    # Sweep now-empty directories (deepest first so parents empty out too).
    Get-ChildItem -Path $Path -Recurse -Directory -Force -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending |
        Where-Object { -not (Get-ChildItem $_.FullName -Force -ErrorAction SilentlyContinue) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Write-Host ('CLEAN {0,-38} {1,10}' -f $Label, (Format-Size $size)) -ForegroundColor Green
    $script:TotalFreed += $size
}

$freeBefore = Get-FreeSpace
Write-Host ''
Write-Host ("Free space on C: before: {0}" -f (Format-Size $freeBefore))
if ($DryRun) { Write-Host '--- DRY RUN: nothing will be deleted ---' -ForegroundColor Cyan }
$needsElevation = $Scope -in @('All', 'System') -or $IncludeWindowsUpdate
if (-not $IsAdmin -and $needsElevation) {
    Write-Host 'Not elevated: selected system-wide targets will be skipped.' -ForegroundColor Yellow
}
Write-Host ''

# --- Default targets (no data loss) --------------------------------------
if ($Scope -in @('All', 'User')) {
    Clear-Target -Label "User temp (>$Days days)" -Path $env:TEMP -OlderThanDays $Days
    Clear-Target -Label 'Explorer thumbnail cache' -Path "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" -OlderThanDays 1
}

if ($Scope -in @('All', 'System')) {
    Clear-Target -Label "Windows temp (>$Days days)" -Path 'C:\Windows\Temp' -OlderThanDays $Days -NeedsAdmin
    Clear-Target -Label 'Windows Error Reporting' -Path "$env:ProgramData\Microsoft\Windows\WER\ReportQueue" -NeedsAdmin

    if ($IsAdmin) {
        if ($DryRun) {
            Write-Host ('WOULD {0,-38} {1,10}' -f 'Delivery Optimization cache', '(size n/a)')
        } else {
            try {
                Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
                Write-Host ('CLEAN {0,-38}' -f 'Delivery Optimization cache') -ForegroundColor Green
            } catch {
                Write-Host ('SKIP  {0,-38} ({1})' -f 'Delivery Optimization cache', $_.Exception.Message) -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host ('SKIP  {0,-38} (needs elevation)' -f 'Delivery Optimization cache') -ForegroundColor Yellow
    }
}

# --- Opt-in targets -------------------------------------------------------
if ($IncludeWindowsUpdate) {
    if ($IsAdmin -and -not $DryRun) {
        # The cache can't be cleared while the update service holds it open.
        Stop-Service -Name wuauserv, bits -Force -ErrorAction SilentlyContinue
    }
    Clear-Target -Label 'Windows Update download cache' -Path 'C:\Windows\SoftwareDistribution\Download' -NeedsAdmin
    if ($IsAdmin -and -not $DryRun) {
        Start-Service -Name bits, wuauserv -ErrorAction SilentlyContinue
    }
}

if ($IncludeRecycleBin) {
    if ($DryRun) {
        Write-Host ('WOULD {0,-38} {1,10}' -f 'Recycle Bin', '(size n/a)')
    } else {
        Clear-RecycleBin -DriveLetter C -Force -ErrorAction SilentlyContinue
        Write-Host ('CLEAN {0,-38}' -f 'Recycle Bin') -ForegroundColor Green
    }
}

if ($IncludeDevCaches) {
    Clear-Target -Label 'pip cache'   -Path "$env:LOCALAPPDATA\pip\cache"
    Clear-Target -Label 'NuGet cache' -Path "$env:USERPROFILE\.nuget\packages"
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        if ($DryRun) {
            Write-Host ('WOULD {0,-38} {1,10}' -f 'npm cache', '(via npm cache clean)')
        } else {
            npm cache clean --force 2>$null
            Write-Host ('CLEAN {0,-38}' -f 'npm cache') -ForegroundColor Green
        }
    }
}

if ($IncludeDocker) {
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        if ($DryRun) {
            Write-Host 'WOULD docker system prune -f; current usage:'
            docker system df 2>$null
        } else {
            docker system prune -f
            Write-Host ('CLEAN {0,-38}' -f 'Docker (dangling/unused, not volumes)') -ForegroundColor Green
        }
    } else {
        Write-Host ('SKIP  {0,-38} (docker not found)' -f 'Docker') -ForegroundColor DarkGray
    }
}

# --- Summary ---------------------------------------------------------------
Write-Host ''
if ($DryRun) {
    Write-Host ("Would free at least: {0}" -f (Format-Size $script:TotalFreed)) -ForegroundColor Cyan
    Write-Host '(Recycle Bin / Delivery Optimization / npm / docker sizes not included in the estimate.)'
} else {
    $freeAfter = Get-FreeSpace
    Write-Host ("Freed (measured per target): {0}" -f (Format-Size $script:TotalFreed)) -ForegroundColor Green
    Write-Host ("Free space on C: now: {0} (was {1})" -f (Format-Size $freeAfter), (Format-Size $freeBefore))
}
