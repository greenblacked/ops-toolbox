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
      hardware   physical disk health, free space on the other fixed volumes,
                 the TPM and Secure Boot
      uptime     days since the last boot - Fast Startup means "Shut down"
                 does not reset it, only "Restart" does
      updates    the age of the newest installed update, and whether the
                 Windows Update service has been disabled
      memory     free physical memory and commit headroom

    -Only runs a comma-separated subset; the default is every section, in the
    order above, which is the order they have always run in.

    Every probe is best-effort by design. Get-BitLockerVolume does not exist on
    Home editions, Get-MpComputerStatus is absent where Defender has been
    replaced by another product, and both answer more fully when elevated. A
    probe that cannot answer says so and the report carries on - a diagnostic
    tool that dies on the first missing cmdlet is worse than no diagnostic tool,
    because it stops before the part you needed.

    There is no -DryRun because there is nothing to preview. -Action takes one
    value, 'report', which is the read-only default the contract checks look
    for; wsl_manage.ps1 takes the same route with its 'list' default.
    -ListSections and -Only answer before the Windows preflight, as in
    status.ps1.

.PARAMETER Only
    Comma-separated section ids (see -ListSections). Unknown ids exit 3; a
    list that selects nothing exits 4.

.PARAMETER MaxUptimeDays
    Warn when the machine has been up longer than this. 0 turns the warning
    off. Default 30.

.PARAMETER MaxPatchAgeDays
    Warn when the newest installed update is older than this. Default 45.

.EXAMPLE
    .\workstation_doctor.ps1
    .\workstation_doctor.ps1 -Action report
    .\workstation_doctor.ps1 -MinFreePercent 20
    .\workstation_doctor.ps1 -ListSections
    .\workstation_doctor.ps1 -Only hardware,uptime
    .\workstation_doctor.ps1 -MaxUptimeDays 14 -MaxPatchAgeDays 30

.NOTES
    Exit codes:
      0  the report ran (warnings do not change the exit code)
      2  preflight checks failed - not Windows
      3  an -Only section nobody has heard of
      4  -Only selected nothing
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('report')]
    [string]$Action = 'report',

    [ValidateRange(0, 100)]
    [int]$MinFreePercent = 10,

    # A list, split on commas below: 'pwsh -File' hands '-Only disk,wsl' over
    # as the single string 'disk,wsl', and PowerShell itself as two elements.
    # stay_fresh.ps1 explains why a ValidateSet cannot take both.
    [string[]]$Only = @(),

    [switch]$ListSections,

    [ValidateRange(0, 3650)]
    [int]$MaxUptimeDays = 30,

    [ValidateRange(1, 3650)]
    [int]$MaxPatchAgeDays = 45
)

$ErrorActionPreference = 'Stop'
$script:Warnings = 0

# The first five are the sections this report has always had, in the order it
# has always run them; the new ones only append.
$SectionOrder = @('security', 'reboot', 'disk', 'wsl', 'policy', 'hardware', 'uptime', 'updates', 'memory')

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

# --- pure helpers -----------------------------------------------------------
# Plain data in, plain data out, so windows/tests/contract.ps1 can lift each
# one out of this file and test it with fixtures and a fixed clock.

# Uptime against -MaxUptimeDays. Returns { Level (ok|warn), Days, Message,
# Hint }. MaxDays 0 disables the warning. With Fast Startup on, "Shut down"
# hibernates the kernel instead of ending it, so only "Restart" resets the
# count - which is exactly what a machine that "gets shut down every night"
# and still has 40 days of uptime needs to be told.
function Get-UptimeFinding {
    param(
        [datetime]$LastBoot,
        [datetime]$Now,
        [int]$MaxDays,
        [bool]$FastStartup
    )
    $days = [int][math]::Floor(($Now - $LastBoot).TotalDays)
    if ($MaxDays -gt 0 -and $days -gt $MaxDays) {
        $hint = 'restart to apply pending updates and release leaked memory and handles'
        if ($FastStartup) {
            $hint = 'restart (not Shut down): Fast Startup keeps the kernel session across a shutdown, so only a restart resets it'
        }
        return [pscustomobject]@{ Level = 'warn'; Days = $days; Message = "up $days day(s), more than $MaxDays"; Hint = $hint }
    }
    return [pscustomobject]@{ Level = 'ok'; Days = $days; Message = "up $days day(s)"; Hint = '' }
}

# Age of the newest installed update against -MaxPatchAgeDays. Returns
# { Level (ok|warn|info), Days, Message }. No date at all is information, not
# a warning: Get-HotFix leaves InstalledOn empty for some updates, and an
# unreadable history is not proof of an unpatched machine.
function Get-PatchAgeFinding {
    param(
        $InstalledOn,
        [datetime]$Now,
        [int]$MaxDays
    )
    if ($null -eq $InstalledOn) {
        return [pscustomobject]@{ Level = 'info'; Days = $null; Message = 'no installed-update date readable' }
    }
    $days = [int][math]::Floor(($Now - [datetime]$InstalledOn).TotalDays)
    if ($days -gt $MaxDays) {
        return [pscustomobject]@{ Level = 'warn'; Days = $days; Message = "newest installed update is $days day(s) old, more than $MaxDays" }
    }
    return [pscustomobject]@{ Level = 'ok'; Days = $days; Message = "newest installed update is $days day(s) old" }
}

# --- -Only ------------------------------------------------------------------
# Ahead of the preflight, as in status.ps1: a bad argument is a bad argument on
# every platform.
if ($ListSections) {
    $SectionOrder | ForEach-Object { Write-Output $_ }
    exit 0
}

$selected = @()
if ($PSBoundParameters.ContainsKey('Only')) {
    foreach ($raw in @($Only | ForEach-Object { $_ -split ',' })) {
        $id = $raw.Trim()
        if (-not $id) { continue }
        if ($SectionOrder -notcontains $id) {
            Write-Err "unknown section in -Only: $id (see -ListSections)"
            exit 3
        }
        $selected += $id
    }
    if ($selected.Count -eq 0) {
        Write-Err '-Only selected nothing'
        exit 4
    }
} else {
    $selected = @($SectionOrder)
}

function Test-Want {
    param([string]$Id)
    return ($selected -contains $Id)
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
if (Test-Want 'security') {
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
}

# --- reboot ----------------------------------------------------------------
if (Test-Want 'reboot') {
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
}

# --- disk ------------------------------------------------------------------
if (Test-Want 'disk') {
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
}

# --- wsl -------------------------------------------------------------------
$wslOperational = $false
if (Test-Want 'wsl') {
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
            $wslOperational = $true
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
}

# --- policy ----------------------------------------------------------------
if (Test-Want 'policy') {
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
}

# --- hardware --------------------------------------------------------------
if (Test-Want 'hardware') {
    Write-Section 'hardware'
    try {
        $physical = @(Get-PhysicalDisk -ErrorAction Stop)
        if ($physical.Count -eq 0) {
            Write-Info 'no physical disk reported'
        }
        foreach ($disk in $physical) {
            $state = '{0}/{1}' -f $disk.HealthStatus, ($disk.OperationalStatus -join ',')
            $label = 'Disk {0}: {1}' -f $disk.FriendlyName, $state
            if ([string]$disk.HealthStatus -eq 'Healthy' -and ($disk.OperationalStatus -join ',') -eq 'OK') {
                Write-Ok $label
            } else {
                Write-Warn $label
                Write-Host '  Get-PhysicalDisk | Get-StorageReliabilityCounter shows its wear and error counters; back it up first' -ForegroundColor DarkGray
            }
        }
    } catch {
        Write-Info "physical disks: no status available ($($_.Exception.Message))"
    }

    # C: is the disk section's; these are the others, a dev drive on D: being
    # the one that fills up unnoticed. Same threshold as C:.
    try {
        $others = @(Get-Volume -ErrorAction Stop |
            Where-Object { [string]$_.DriveType -eq 'Fixed' -and $_.DriveLetter -and [string]$_.DriveLetter -ne 'C' } |
            Sort-Object -Property DriveLetter)
        foreach ($volume in $others) {
            if ($volume.Size -le 0) { continue }
            $freePercent = [math]::Round(($volume.SizeRemaining / $volume.Size) * 100, 1)
            $line = '{0}: {1} free of {2} ({3}%)' -f $volume.DriveLetter, (Format-Size $volume.SizeRemaining), (Format-Size $volume.Size), $freePercent
            if ($freePercent -lt $MinFreePercent) {
                Write-Warn $line
            } else {
                Write-Ok $line
            }
        }
    } catch {
        Write-Info "other volumes: no status available ($($_.Exception.Message))"
    }

    try {
        $tpm = Get-Tpm -ErrorAction Stop
        if ($tpm.TpmPresent -and $tpm.TpmReady) {
            Write-Ok 'TPM present and ready'
        } elseif ($tpm.TpmPresent) {
            Write-Warn 'TPM present but not ready (tpm.msc shows what it needs)'
        } else {
            Write-Warn 'no TPM: BitLocker and Windows Hello have no hardware root of trust'
        }
    } catch {
        Write-Info "TPM: no status available ($($_.Exception.Message))"
    }
    try {
        if (Confirm-SecureBootUEFI -ErrorAction Stop) {
            Write-Ok 'Secure Boot on'
        } else {
            Write-Warn 'Secure Boot off'
        }
    } catch {
        Write-Info 'Secure Boot: legacy BIOS or not readable (needs elevation)'
    }
}

# --- uptime -----------------------------------------------------------------
if (Test-Want 'uptime') {
    Write-Section 'uptime'
    try {
        $lastBoot = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
        $hiberboot = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
            -Name 'HiberbootEnabled' -ErrorAction SilentlyContinue
        $fastStartup = [bool]($hiberboot -and $hiberboot.HiberbootEnabled -eq 1)
        $uptime = Get-UptimeFinding -LastBoot $lastBoot -Now (Get-Date) -MaxDays $MaxUptimeDays -FastStartup $fastStartup
        if ($uptime.Level -eq 'warn') {
            Write-Warn $uptime.Message
            Write-Host "  $($uptime.Hint)" -ForegroundColor DarkGray
        } else {
            Write-Ok $uptime.Message
        }
        if ($fastStartup) {
            Write-Info 'Fast Startup is on: Shut down does not reset uptime, Restart does'
        }
    } catch {
        Write-Info "uptime: not readable ($($_.Exception.Message))"
    }
}

# --- updates ----------------------------------------------------------------
if (Test-Want 'updates') {
    Write-Section 'updates'
    $newest = $null
    try {
        $newest = @(Get-HotFix -ErrorAction Stop | ForEach-Object { $_.InstalledOn } | Where-Object { $_ } |
            Sort-Object -Descending) | Select-Object -First 1
    } catch {
        Write-Info "Get-HotFix: not available ($($_.Exception.Message))"
    }
    if ($null -eq $newest) {
        Write-Info 'no hotfix history readable'
    } else {
        $patch = Get-PatchAgeFinding -InstalledOn $newest -Now (Get-Date) -MaxDays $MaxPatchAgeDays
        if ($patch.Level -eq 'warn') {
            Write-Warn $patch.Message
            Write-Host '  Settings > Windows Update > Check for updates' -ForegroundColor DarkGray
        } else {
            Write-Ok $patch.Message
        }
    }
    try {
        $updateService = Get-Service -Name 'wuauserv' -ErrorAction Stop
        if ([string]$updateService.StartType -eq 'Disabled') {
            Write-Warn 'the Windows Update service is disabled: no updates will arrive'
        } else {
            Write-Ok "Windows Update service start type: $($updateService.StartType)"
        }
    } catch {
        Write-Info "Windows Update service: not readable ($($_.Exception.Message))"
    }
}

# --- memory -----------------------------------------------------------------
if (Test-Want 'memory') {
    Write-Section 'memory'
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        # The CIM figures are in KB.
        $totalRam = [long]$os.TotalVisibleMemorySize * 1KB
        $freeRam = [long]$os.FreePhysicalMemory * 1KB
        $totalCommit = [long]$os.TotalVirtualMemorySize * 1KB
        $freeCommit = [long]$os.FreeVirtualMemory * 1KB
        if ($totalRam -gt 0) {
            $freePercent = [math]::Round(($freeRam / $totalRam) * 100, 1)
            $line = 'RAM: {0} free of {1} ({2}%)' -f (Format-Size $freeRam), (Format-Size $totalRam), $freePercent
            if ($freePercent -lt 10) {
                Write-Warn "only $freePercent% of RAM free - $line"
            } else {
                Write-Ok $line
            }
        }
        if ($totalCommit -gt 0) {
            Write-Info ('commit: {0} free of {1} (RAM plus page file)' -f (Format-Size $freeCommit), (Format-Size $totalCommit))
        }
    } catch {
        Write-Info "memory: not readable ($($_.Exception.Message))"
    }
    if ($wslOperational) {
        Write-Info '.wslconfig [wsl2] memory= caps what WSL can take'
    }
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
