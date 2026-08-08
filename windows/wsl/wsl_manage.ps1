<#
.SYNOPSIS
    Everyday WSL2 maintenance: list distros with disk usage, back up, restore,
    shrink, and prune old backups.

.DESCRIPTION
    Actions:
      list      Distros with state, WSL version, VHDX path and size on disk.
      df        Allocated (the VHDX file) against used (df inside the distro),
                so the space a compact would reclaim is a number rather than a
                guess. Read-only.
      backup    Export a distro to a dated .tar (wsl --export). Safe to run
                while the distro is running.
      restore   Import a .tar back as a NEW distro (wsl --import). It never
                overwrites an existing registration - see the notes below,
                because restore has two surprises worth knowing in advance.
      prune-backups
                Delete old .tar exports under -DestDir by age and count.
                Preview it with -DryRun; without -DryRun it asks first.
      compact   Shrink a distro's VHDX after deleting files inside it (WSL2
                virtual disks grow but never shrink on their own). Shuts WSL
                down first, then compacts via diskpart. Needs elevation.
      sparse    Newer alternative to compact: mark the VHDX sparse so it
                returns space to Windows automatically from then on
                (wsl --manage <distro> --set-sparse true).
      terminate Stop ONE distro (wsl --terminate). The other distros and the
                utility VM keep running.
      shutdown  Stop all WSL distros and the VM (frees the RAM WSL holds).

.EXAMPLE
    .\wsl_manage.ps1 list
    .\wsl_manage.ps1 df
    .\wsl_manage.ps1 backup -Distro Ubuntu -DestDir D:\Backups
    .\wsl_manage.ps1 restore -Distro Ubuntu-restored -Tar D:\Backups\Ubuntu_2026-08-08_0930.tar
    .\wsl_manage.ps1 prune-backups -DestDir D:\Backups -KeepDays 30 -KeepLast 2 -DryRun
    .\wsl_manage.ps1 compact -Distro Ubuntu
    .\wsl_manage.ps1 sparse -Distro Ubuntu
    .\wsl_manage.ps1 terminate -Distro Ubuntu
    .\wsl_manage.ps1 shutdown

.NOTES
    Exit codes:
      0  success
      1  the underlying wsl/diskpart command failed
      2  WSL is not installed or not operational
      3  bad arguments (no -Distro, no such distro, missing or unusable -Tar)
      4  needs an elevated shell (compact only)

    restore, in detail. 'wsl --import' registers a new distro from a tar; it
    cannot replace one in place, so:

      * -Distro is the name the restored copy gets, and it must not already be
        registered. To take over an existing name, unregister it first with
        'wsl --unregister <name>' - which deletes that distro's disk, so take a
        backup first.
      * -InstallDir is where the new ext4.vhdx is written. It defaults to
        %LOCALAPPDATA%\WSL\<Distro> and must be empty or absent; the tar is
        read, not moved, so keep it somewhere with room for a second copy.
      * The restored distro boots as root. WSL records the default user inside
        the distro and --import does not carry it over, so add a [user]
        section naming it to /etc/wsl.conf and terminate the distro once. The
        successful restore prints those steps.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('list', 'df', 'backup', 'restore', 'prune-backups', 'compact', 'sparse', 'terminate', 'shutdown')]
    [string]$Action = 'list',
    [string]$Distro,
    [string]$DestDir = "$env:USERPROFILE\wsl-backups",
    [string]$Tar,                                  # restore: the .tar to import
    [string]$InstallDir,                           # restore: where the new VHDX goes
    [ValidateRange(0, 3650)]
    [int]$KeepDays = 30,                           # prune-backups: keep anything newer
    [ValidateRange(0, 1000)]
    [int]$KeepLast = 2,                            # prune-backups: keep this many per distro
    [switch]$Force,   # df: start stopped distros to measure them
                      # prune-backups: delete without asking
    [switch]$DryRun,  # restore, prune-backups, terminate: report, change nothing
    [switch]$Off      # sparse only: pass to set sparse=false instead of true
)

$ErrorActionPreference = 'Stop'

# PowerShell 7.3 and later turn a non-zero exit from a native command into a
# terminating error while $ErrorActionPreference is 'Stop'. Every wsl.exe call
# here is followed by its own $LASTEXITCODE check with a specific message and
# exit code, and none of them would ever be reached. Older hosts (Windows
# PowerShell 5.1) simply do not have this variable and ignore the assignment.
$PSNativeCommandUseErrorActionPreference = $false

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    # -ErrorAction Continue, or $ErrorActionPreference = 'Stop' turns this into
    # a terminating error and the exit code below is never reached: the script
    # ends up reporting 1 (something failed) where it means 2 (wrong machine).
    Write-Error 'wsl.exe not found - is WSL installed? (wsl --install)' -ErrorAction Continue
    exit 2
}
# wsl.exe exists as a stub even when WSL itself was never installed - probe
# for a working install before doing anything (its own error output is
# UTF-16 and prints as garbage in most consoles, so use our own message).
wsl.exe --status *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Error "WSL is not installed or not operational ('wsl --status' exited $LASTEXITCODE). Install with: wsl --install" -ErrorAction Continue
    exit 2
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

# Registered distros with their install locations, from the registry (the
# only reliable place the VHDX paths live).
function Get-DistroInfo {
    $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    Get-ChildItem $lxss -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath
        if (-not $p.DistributionName) { return }
        $vhdx = Join-Path $p.BasePath 'ext4.vhdx'
        [PSCustomObject]@{
            Name     = $p.DistributionName
            Version  = $p.Version
            BasePath = $p.BasePath
            Vhdx     = $vhdx
            VhdxSize = if (Test-Path $vhdx) { (Get-Item $vhdx).Length } else { 0 }
        }
    }
}

# Running/Stopped per distro, from 'wsl -l -v'. The registry does not know it.
# wsl.exe prints UTF-16; force PowerShell to read it correctly.
function Get-DistroState {
    $prev = [Console]::OutputEncoding
    [Console]::OutputEncoding = [Text.Encoding]::Unicode
    $states = @{}
    try {
        (wsl.exe --list --verbose) -split "`n" | Select-Object -Skip 1 | ForEach-Object {
            $line = $_.Trim() -replace '^\*\s*', ''
            if ($line -match '^(\S+)\s+(\S+)\s+(\d+)') {
                $states[$Matches[1]] = $Matches[2]
            }
        }
    } finally {
        [Console]::OutputEncoding = $prev
    }
    $states
}

function Resolve-Distro {
    param([string]$Name)
    if (-not $Name) {
        Write-Error "This action needs -Distro <name>. Registered: $((Get-DistroInfo).Name -join ', ')" -ErrorAction Continue
        exit 3
    }
    $info = Get-DistroInfo | Where-Object Name -eq $Name
    if (-not $info) {
        Write-Error "No registered distro named '$Name'. Registered: $((Get-DistroInfo).Name -join ', ')" -ErrorAction Continue
        exit 3
    }
    $info
}

# Bytes used on / inside a distro, or $null when it cannot be measured.
# 'df -Pk /' is the POSIX form: it prints one line per filesystem in 1K blocks
# and does not wrap long device names, which -h does. Output of a command run
# in a distro is passed through as the distro wrote it, so no UTF-16 dance here.
function Get-DistroUsage {
    param([string]$Name)
    $out = wsl.exe -d $Name --exec df -Pk / 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
    foreach ($line in ($out -split "`n")) {
        if ($line -match '^\S+\s+(\d+)\s+(\d+)\s+(\d+)\s+') {
            return [long]$Matches[2] * 1KB
        }
    }
    return $null
}

# The .tar files under $Directory that this script's backup action wrote:
# <distro>_<yyyy-MM-dd>_<HHmm>.tar. Anything else in the folder is somebody
# else's file and is never a candidate for deletion.
function Get-BackupFile {
    param([string]$Directory, [string]$Name)
    Get-ChildItem -Path $Directory -Filter '*.tar' -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            if ($_.Name -match '^(?<distro>.+)_\d{4}-\d{2}-\d{2}_\d{4}\.tar$') {
                [PSCustomObject]@{
                    Distro = $Matches['distro']
                    File   = $_
                }
            }
        } | Where-Object { -not $Name -or $_.Distro -eq $Name }
}

switch ($Action) {
    'list' {
        # wsl -l -v knows running state; the registry knows sizes. Join them.
        $states = Get-DistroState

        Get-DistroInfo | ForEach-Object {
            [PSCustomObject]@{
                Name    = $_.Name
                State   = if ($states.ContainsKey($_.Name)) { $states[$_.Name] } else { 'Unknown' }
                Disk    = Format-Size $_.VhdxSize
                Vhdx    = $_.Vhdx
            }
        } | Format-Table -AutoSize
    }

    'df' {
        # "Allocated" is the VHDX file on the Windows side; "used" is what the
        # filesystem inside it reports. The gap between the two is what a
        # compact (or sparse mode) would give back, and it is routinely tens of
        # gigabytes on a machine that has built anything large.
        $targets = if ($Distro) { @(Resolve-Distro $Distro) } else { @(Get-DistroInfo) }
        if (-not $targets) {
            Write-Host 'No registered distros.'
            break
        }
        $states = Get-DistroState
        $skipped = 0

        $rows = foreach ($d in $targets) {
            $state = if ($states.ContainsKey($d.Name)) { $states[$d.Name] } else { 'Unknown' }
            $used = $null
            # Measuring means running a command in the distro, and running a
            # command in a stopped distro starts it. That is a side effect a
            # read-only report should not have by default, so it is opt-in.
            if ($state -eq 'Running' -or $Force) {
                $used = Get-DistroUsage $d.Name
            } else {
                $skipped++
            }

            [PSCustomObject]@{
                Name        = $d.Name
                State       = $state
                Allocated   = Format-Size $d.VhdxSize
                Used        = if ($null -ne $used) { Format-Size $used } else { '-' }
                Reclaimable = if ($null -ne $used -and $d.VhdxSize -gt $used) {
                    Format-Size ($d.VhdxSize - $used)
                } else { '-' }
            }
        }
        $rows | Format-Table -AutoSize

        if ($skipped -gt 0) {
            Write-Host "$skipped stopped distro(s) were not measured; starting one to read df is a side effect. Add -Force to measure them anyway." -ForegroundColor DarkGray
        }
        Write-Host "Reclaimable is allocated minus used: run 'compact' (or 'sparse' once) to get it back." -ForegroundColor DarkGray
    }

    'backup' {
        $info = Resolve-Distro $Distro
        if (-not (Test-Path $DestDir)) {
            New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
        }
        $stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
        $out = Join-Path $DestDir "$($info.Name)_$stamp.tar"
        Write-Host "Exporting '$($info.Name)' -> $out (this can take a while)..."
        wsl.exe --export $info.Name $out
        if ($LASTEXITCODE -ne 0) {
            Write-Error "wsl --export failed (exit $LASTEXITCODE)" -ErrorAction Continue
            exit 1
        }
        Write-Host ("Done: {0} ({1})" -f $out, (Format-Size (Get-Item $out).Length)) -ForegroundColor Green
        Write-Host "Restore it with: .\wsl_manage.ps1 restore -Distro $($info.Name)-restored -Tar `"$out`""
    }

    'restore' {
        if (-not $Distro) {
            Write-Error 'restore needs -Distro <name> - the name the restored copy will be registered under.' -ErrorAction Continue
            exit 3
        }
        if (-not $Tar) {
            Write-Error 'restore needs -Tar <path to .tar> - the export to import.' -ErrorAction Continue
            exit 3
        }
        if (-not (Test-Path -LiteralPath $Tar -PathType Leaf)) {
            Write-Error "No such file: $Tar" -ErrorAction Continue
            exit 3
        }
        $tarPath = (Resolve-Path -LiteralPath $Tar).Path

        # --import registers a new distro. Pointed at a name that already
        # exists it fails, and the failure is easy to misread as "the tar is
        # bad", so say plainly what is in the way and what removing it costs.
        if (Get-DistroInfo | Where-Object Name -eq $Distro) {
            Write-Error ("'$Distro' is already registered. Import cannot replace a distro in place: " +
                "choose another name, or remove it first with 'wsl --unregister $Distro' - " +
                'which deletes that distro and its disk.') -ErrorAction Continue
            exit 3
        }

        $target = if ($InstallDir) { $InstallDir } else { Join-Path $env:LOCALAPPDATA "WSL\$Distro" }
        if ((Test-Path $target) -and (Get-ChildItem -Path $target -Force -ErrorAction SilentlyContinue)) {
            Write-Error "Install directory is not empty: $target. Pass -InstallDir <empty or new dir>." -ErrorAction Continue
            exit 3
        }

        $size = (Get-Item -LiteralPath $tarPath).Length
        if ($DryRun) {
            Write-Host ('WOULD create install dir   {0}' -f $target) -ForegroundColor Cyan
            Write-Host ('WOULD import as            {0} ({1} from {2})' -f $Distro, (Format-Size $size), $tarPath) -ForegroundColor Cyan
            Write-Host 'Dry run complete; nothing was registered and no disk was written.' -ForegroundColor Yellow
            break
        }

        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Write-Host "Importing $tarPath ($(Format-Size $size)) as '$Distro' in $target (this can take a while)..."
        wsl.exe --import $Distro $target $tarPath --version 2
        if ($LASTEXITCODE -ne 0) {
            Write-Error "wsl --import failed (exit $LASTEXITCODE)" -ErrorAction Continue
            exit 1
        }
        Write-Host "Imported '$Distro'." -ForegroundColor Green
        Write-Host 'It boots as root: --import does not carry the default user over. To set one:'
        Write-Host "  wsl -d $Distro -u root      then append to /etc/wsl.conf:"
        Write-Host '      [user]'
        Write-Host '      default=YOURNAME'
        Write-Host "  .\wsl_manage.ps1 terminate -Distro $Distro   (the file is read at next start)"
    }

    'prune-backups' {
        if (-not (Test-Path $DestDir)) {
            Write-Host "No backup directory at $DestDir - nothing to prune."
            break
        }

        $all = @(Get-BackupFile -Directory $DestDir -Name $Distro)
        if (-not $all) {
            Write-Host "No dated .tar exports under $DestDir - nothing to prune."
            break
        }

        # A file survives if EITHER rule wants to keep it: it is one of the
        # newest -KeepLast for its distro, or it is younger than -KeepDays.
        # Both rules have to agree before anything is deleted, which is the
        # conservative reading and the one that cannot surprise anybody.
        $cutoff = (Get-Date).AddDays(-$KeepDays)
        $keep = @()
        $prune = @()
        foreach ($group in ($all | Group-Object Distro)) {
            $ordered = $group.Group | Sort-Object { $_.File.LastWriteTime } -Descending
            for ($i = 0; $i -lt $ordered.Count; $i++) {
                $entry = $ordered[$i]
                if ($i -lt $KeepLast -or $entry.File.LastWriteTime -gt $cutoff) {
                    $keep += $entry
                } else {
                    $prune += $entry
                }
            }
        }

        Write-Host ''
        Write-Host ("Retention: keep the newest $KeepLast per distro, and anything newer than $KeepDays day(s).")
        Write-Host ("Directory: $DestDir")
        Write-Host ''
        foreach ($entry in ($keep | Sort-Object { $_.File.Name })) {
            Write-Host ('KEEP  {0,-44} {1,10}' -f $entry.File.Name, (Format-Size $entry.File.Length)) -ForegroundColor DarkGray
        }
        $verb = if ($DryRun) { 'WOULD' } else { 'PRUNE' }
        $colour = if ($DryRun) { 'Cyan' } else { 'Yellow' }
        foreach ($entry in ($prune | Sort-Object { $_.File.Name })) {
            Write-Host ("$verb {0,-44} {1,10}" -f $entry.File.Name, (Format-Size $entry.File.Length)) -ForegroundColor $colour
        }

        # Summed through ForEach-Object rather than -Property { ... }: a script
        # block property is a PowerShell 7 feature and these scripts also run
        # under the Windows PowerShell 5.1 that ships with Windows.
        $freed = ($prune | ForEach-Object { $_.File.Length } | Measure-Object -Sum).Sum
        if (-not $freed) { $freed = 0L }

        Write-Host ''
        if (-not $prune) {
            Write-Host 'Nothing is old enough to prune.' -ForegroundColor Green
            break
        }
        if ($DryRun) {
            Write-Host ("Dry run complete; {0} file(s) totalling {1} would be deleted." -f $prune.Count, (Format-Size $freed)) -ForegroundColor Yellow
            break
        }

        # These are the only copy of a filesystem somebody chose to keep, so a
        # real run confirms unless -Force says not to bother (scheduled runs).
        if (-not $Force) {
            $answer = Read-Host ("Delete {0} file(s), {1}? [y/N]" -f $prune.Count, (Format-Size $freed))
            if ($answer -notmatch '^(y|yes)$') {
                Write-Host 'Nothing deleted.'
                break
            }
        }
        foreach ($entry in $prune) {
            Remove-Item -LiteralPath $entry.File.FullName -Force
        }
        Write-Host ("Deleted {0} file(s), freed {1}." -f $prune.Count, (Format-Size $freed)) -ForegroundColor Green
    }

    'compact' {
        $isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) {
            Write-Error 'compact needs an elevated (Administrator) PowerShell - diskpart requirement.' -ErrorAction Continue
            exit 4
        }
        $info = Resolve-Distro $Distro
        $before = (Get-Item $info.Vhdx).Length

        Write-Host 'Shutting down WSL (all distros)...'
        wsl.exe --shutdown

        # diskpart has no CLI args - it reads a script file.
        $dpScript = Join-Path $env:TEMP "wsl_compact_$PID.txt"
        @(
            "select vdisk file=`"$($info.Vhdx)`""
            'attach vdisk readonly'
            'compact vdisk'
            'detach vdisk'
        ) | Set-Content -Path $dpScript -Encoding ascii
        try {
            diskpart /s $dpScript
        } finally {
            Remove-Item $dpScript -Force -ErrorAction SilentlyContinue
        }

        $after = (Get-Item $info.Vhdx).Length
        Write-Host ("VHDX: {0} -> {1} (reclaimed {2})" -f `
            (Format-Size $before), (Format-Size $after), (Format-Size ($before - $after))) -ForegroundColor Green
        Write-Host "Tip: run '.\wsl_manage.ps1 sparse -Distro $($info.Name)' once and future space is returned automatically."
    }

    'sparse' {
        $info = Resolve-Distro $Distro
        $value = if ($Off) { 'false' } else { 'true' }
        wsl.exe --manage $info.Name --set-sparse $value
        if ($LASTEXITCODE -ne 0) {
            Write-Error "wsl --manage --set-sparse failed (exit $LASTEXITCODE) - needs a recent WSL (wsl --update)." -ErrorAction Continue
            exit 1
        }
        Write-Host "Sparse mode for '$($info.Name)' set to $value." -ForegroundColor Green
    }

    'terminate' {
        $info = Resolve-Distro $Distro
        if ($DryRun) {
            Write-Host ("WOULD terminate '{0}' (its running processes would be killed)" -f $info.Name) -ForegroundColor Cyan
            break
        }
        wsl.exe --terminate $info.Name
        if ($LASTEXITCODE -ne 0) {
            Write-Error "wsl --terminate failed (exit $LASTEXITCODE)" -ErrorAction Continue
            exit 1
        }
        Write-Host "Terminated '$($info.Name)'. Other distros and the utility VM are untouched." -ForegroundColor Green
    }

    'shutdown' {
        wsl.exe --shutdown
        Write-Host 'WSL stopped (all distros + utility VM). RAM released.' -ForegroundColor Green
    }
}
