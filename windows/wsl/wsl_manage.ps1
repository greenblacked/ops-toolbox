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
                while the distro is running. Writes a SHA-256 sidecar.
                -All exports every registered distro under one timestamp,
                skipping Docker Desktop's internal distros, and carries on
                past a failed export. -DryRun prints the plan with sizes and
                writes nothing, not even -DestDir.
      verify-backup
                Verify a -Tar against the .sha256 sidecar written by backup.
      backups   Inventory of the dated exports under -DestDir, newest first
                per distro, with size, age and whether a sidecar is there.
                -Verify hashes every tar against its sidecar; -MaxAgeDays N
                flags a distro whose newest backup is older than N days.
                Read-only, needs no WSL.
      restore   Import a .tar back as a NEW distro (wsl --import). It never
                overwrites an existing registration - see the notes below,
                because restore has two surprises worth knowing in advance.
      clone     Copy a distro under a new name (-NewName): export to a
                staging tar, import it, set its default user, and delete the
                staging tar (-KeepTar keeps it as a dated, verified backup).
                The source is never touched. -DryRun prints every step.
      prune-backups
                Delete old .tar exports under -DestDir by age and count.
                Preview it with -DryRun; without -DryRun it asks first.
      compact   Shrink a distro's VHDX after deleting files inside it (WSL2
                virtual disks grow but never shrink on their own). Shuts WSL
                down first, then compacts via diskpart. Needs elevation.
                -DryRun names the distros the shutdown would stop and the
                disk it would compact, elevated or not.
      sparse    Newer alternative to compact: mark the VHDX sparse so it
                returns space to Windows automatically from then on
                (wsl --manage <distro> --set-sparse true).
      terminate Stop ONE distro (wsl --terminate). The other distros and the
                utility VM keep running.
      shutdown  Stop all WSL distros and the VM (frees the RAM WSL holds).
                -DryRun names the distros it would stop.
      doctor    Per-distro health: WSL1 where docker cannot run, a default
                user of root, no systemd, a nearly full root filesystem,
                clock drift after sleep, DNS that does not resolve, and a
                PATH full of /mnt/c entries. Checks running distros only;
                -Force starts a stopped one to measure it. Read-only: it
                runs id, cat, df, date, getent and echo inside the distro
                and prints the fix; -DryRun is accepted and ignored.
      wslconfig Audit %USERPROFILE%\.wslconfig: no memory cap, keys WSL
                silently ignores (wrong section, typo, single backslashes in
                a path), values that do not parse. Read-only and offline: it
                reads one file, never calls wsl.exe, and runs on a machine
                where WSL is absent. -Template prints a commented starter
                file to stdout and writes nothing. There is no dry run
                because there is nothing to preview; -DryRun is accepted and
                ignored.

.EXAMPLE
    .\wsl_manage.ps1 list
    .\wsl_manage.ps1 df
    .\wsl_manage.ps1 backup -Distro Ubuntu -DestDir D:\Backups
    .\wsl_manage.ps1 backup -All -DestDir D:\Backups -DryRun
    .\wsl_manage.ps1 verify-backup -Tar D:\Backups\Ubuntu_2026-08-08_0930.tar
    .\wsl_manage.ps1 backups -DestDir D:\Backups -Verify -MaxAgeDays 7
    .\wsl_manage.ps1 restore -Distro Ubuntu-restored -Tar D:\Backups\Ubuntu_2026-08-08_0930.tar -DefaultUser me
    .\wsl_manage.ps1 clone -Distro Ubuntu -NewName Ubuntu-test -DryRun
    .\wsl_manage.ps1 prune-backups -DestDir D:\Backups -KeepDays 30 -KeepLast 2 -DryRun
    .\wsl_manage.ps1 compact -Distro Ubuntu -DryRun
    .\wsl_manage.ps1 compact -Distro Ubuntu
    .\wsl_manage.ps1 sparse -Distro Ubuntu
    .\wsl_manage.ps1 terminate -Distro Ubuntu
    .\wsl_manage.ps1 shutdown
    .\wsl_manage.ps1 doctor
    .\wsl_manage.ps1 doctor -Distro Ubuntu -ProbeHost registry.example.com
    .\wsl_manage.ps1 wslconfig
    .\wsl_manage.ps1 wslconfig -ConfigFile D:\profiles\.wslconfig -Strict
    .\wsl_manage.ps1 wslconfig -Template > $env:USERPROFILE\.wslconfig.new

.NOTES
    Exit codes:
      0  success (wslconfig: the report ran; warnings alone do not change it)
      1  the underlying wsl/diskpart command failed
         (backup -All: one or more exports failed; the rest still ran)
         (backups: a BAD or MISS tar under -Verify, or a STALE distro)
         (doctor: one or more FAIL findings)
         (wslconfig -Strict: one or more WARN findings)
      2  WSL is not installed or not operational
      3  bad arguments (no -Distro, no such distro, missing or unusable -Tar,
         a -ConfigFile that does not exist or cannot be read, a -DefaultUser
         that is not a valid Linux user name, a -NewName already taken)
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
        the distro and --import does not carry it over. -DefaultUser NAME
        appends a [user] section naming it to /etc/wsl.conf and terminates the
        distro once so it is read; without it, the successful restore prints
        those steps for you to do by hand.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('list', 'df', 'backup', 'verify-backup', 'backups', 'restore', 'prune-backups', 'clone', 'compact', 'sparse', 'terminate', 'shutdown', 'doctor', 'wslconfig')]
    [string]$Action = 'list',
    [string]$Distro,
    [string]$DestDir = "$env:USERPROFILE\wsl-backups",
    [string]$Tar,                                  # restore: the .tar to import
    [string]$InstallDir,                           # restore, clone: where the new VHDX goes
    [string]$NewName,                              # clone: the name the copy is registered under
    [string]$DefaultUser,                          # restore, clone: default user to set in /etc/wsl.conf
    [switch]$KeepTar,                              # clone: keep the export as a dated, verified backup
    [ValidateRange(0, 3650)]
    [int]$KeepDays = 30,                           # prune-backups: keep anything newer
    [ValidateRange(0, 1000)]
    [int]$KeepLast = 2,                            # prune-backups: keep this many per distro
    [switch]$Force,   # df, doctor: start stopped distros to measure them
                      # prune-backups: delete without asking
    [switch]$DryRun,  # backup, restore, prune-backups, clone, compact,
                      # sparse, terminate, shutdown: report, change nothing
    [switch]$All,     # backup only: export every registered distro
    [switch]$Verify,  # backups: hash every tar against its sidecar
    [ValidateRange(0, 3650)]
    [int]$MaxAgeDays = 0,                          # backups: newest older than this is STALE (0: off)
    [switch]$Off,     # sparse only: pass to set sparse=false instead of true
    [switch]$AllowUnverified, # restore only: import a tar with no .sha256 sidecar
    [string]$ProbeHost = 'github.com',  # doctor: the name each distro must resolve
    [string]$ConfigFile,      # wslconfig: audit this file instead of %USERPROFILE%\.wslconfig
    [switch]$Template,        # wslconfig: print a commented starter file, write nothing
    [switch]$Strict           # wslconfig: exit 1 when any finding is a WARN
)

$ErrorActionPreference = 'Stop'

# A bare drive such as 'D:' is the drive-relative "current directory on D" to
# every .NET and cmdlet path call; for -DestDir it can only mean the drive
# root. Pure.
function ConvertTo-DriveRootPath {
    param([string]$Path)
    if ($Path -match '^[A-Za-z]:$') { return $Path + '\' }
    $Path
}

# Read the bare drive as its root once, so backup, backups, prune-backups and
# clone all see the same -DestDir (in $destRoot).
$destRoot = ConvertTo-DriveRootPath $DestDir

# PowerShell 7.3 and later turn a non-zero exit from a native command into a
# terminating error while $ErrorActionPreference is 'Stop'. Every wsl.exe call
# here is followed by its own $LASTEXITCODE check with a specific message and
# exit code, and none of them would ever be reached. Older hosts (Windows
# PowerShell 5.1) simply do not have this variable and ignore the assignment.
$PSNativeCommandUseErrorActionPreference = $false

# Actions that only read files on the Windows side. They need no WSL at all,
# so they also run on a machine that only holds the backups or the config
# file, and on the Linux runner that tests them.
$offlineActions = @('verify-backup', 'backups', 'wslconfig')

if ($Action -notin $offlineActions -and -not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    # -ErrorAction Continue, or $ErrorActionPreference = 'Stop' turns this into
    # a terminating error and the exit code below is never reached: the script
    # ends up reporting 1 (something failed) where it means 2 (wrong machine).
    Write-Error 'wsl.exe not found - is WSL installed? (wsl --install)' -ErrorAction Continue
    exit 2
}
# wsl.exe exists as a stub even when WSL itself was never installed - probe
# for a working install before doing anything (its own error output is
# UTF-16 and prints as garbage in most consoles, so use our own message).
if ($Action -notin $offlineActions) {
    wsl.exe --status *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "WSL is not installed or not operational ('wsl --status' exited $LASTEXITCODE). Install with: wsl --install" -ErrorAction Continue
        exit 2
    }
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
            # The uid WSL starts the distro as; 0 (root) or absent after an
            # import that never had a default user set.
            DefaultUid = $p.DefaultUid
        }
    }
}

# 'wsl -l -v' as rows {Name, State, Version, Default}. Pure, so the contract
# tests feed it a transcript. The header line, the '*' that marks the default
# distro, a trailing CR and stray NULs from a UTF-16 misread are all dropped.
function ConvertFrom-DistroList {
    param([string]$Text)
    $rows = @()
    if (-not $Text) { return $rows }
    foreach ($raw in ($Text -split "`n")) {
        $line = ($raw -replace "`0", '').Trim()
        $isDefault = $line.StartsWith('*')
        $line = $line -replace '^\*\s*', ''
        if ($line -match '^NAME\s+STATE\s+VERSION') { continue }
        if ($line -match '^(?<name>\S+)\s+(?<state>\S+)\s+(?<version>\d+)') {
            $rows += [PSCustomObject]@{
                Name    = $Matches['name']
                State   = $Matches['state']
                Version = [int]$Matches['version']
                Default = $isDefault
            }
        }
    }
    return $rows
}

# Running/Stopped and the WSL version per distro, from 'wsl -l -v'. The
# registry does not know the state. wsl.exe prints UTF-16; force PowerShell
# to read it correctly.
function Get-DistroList {
    $prev = [Console]::OutputEncoding
    [Console]::OutputEncoding = [Text.Encoding]::Unicode
    try {
        $text = (wsl.exe --list --verbose) -join "`n"
    } finally {
        [Console]::OutputEncoding = $prev
    }
    ConvertFrom-DistroList -Text $text
}

# Name -> Running/Stopped.
function Get-DistroState {
    $states = @{}
    foreach ($row in @(Get-DistroList)) {
        $states[$row.Name] = $row.State
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
    $df = ConvertFrom-DfOutput -Text ($out -join "`n")
    if ($null -eq $df) { return $null }
    return $df.Used
}

# The first filesystem line of 'df -Pk' as {Total, Used, Available} in bytes,
# or $null. Pure.
function ConvertFrom-DfOutput {
    param([string]$Text)
    foreach ($line in ($Text -split "`n")) {
        if ($line -match '^\S+\s+(\d+)\s+(\d+)\s+(\d+)\s+') {
            return [PSCustomObject]@{
                Total     = [long]$Matches[1] * 1KB
                Used      = [long]$Matches[2] * 1KB
                Available = [long]$Matches[3] * 1KB
            }
        }
    }
    return $null
}

# One command inside a distro, with a time limit: {ExitCode, Output,
# TimedOut}. A wedged distro is common enough after sleep that a report which
# waits on it forever is worse than one that says it gave up. The output is
# read as UTF-8, the way the distro wrote it.
function Invoke-DistroCommand {
    param(
        [string]$Name,
        [string[]]$Command,
        [int]$TimeoutSeconds = 15
    )
    $argv = @('-d', $Name, '--exec') + $Command
    $quoted = foreach ($a in $argv) {
        if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a }
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'wsl.exe'
    $psi.Arguments = $quoted -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    try {
        $process = [System.Diagnostics.Process]::Start($psi)
    } catch {
        return [PSCustomObject]@{ ExitCode = $null; Output = $null; TimedOut = $false }
    }
    # Both streams are drained asynchronously, so a chatty stderr cannot fill
    # its pipe and stall the process this is waiting on.
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $null = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch { $null = $_ }
        return [PSCustomObject]@{ ExitCode = $null; Output = $null; TimedOut = $true }
    }
    $process.WaitForExit()
    return [PSCustomObject]@{ ExitCode = $process.ExitCode; Output = $stdout.Result; TimedOut = $false }
}

# What doctor measures in one distro, as a hashtable Test-DistroFact reads.
# A command that fails or times out leaves its key out, and the check that
# needs it says it was not measured. Nothing here writes anything.
function Get-DistroFact {
    param(
        [string]$Name,
        $Version,
        [string]$ProbeHost
    )
    $facts = @{ Name = $Name; Version = $Version; ProbeHost = $ProbeHost }

    $r = Invoke-DistroCommand -Name $Name -Command @('id', '-un')
    if ($r.ExitCode -eq 0) { $facts.User = $r.Output.Trim() }

    $r = Invoke-DistroCommand -Name $Name -Command @('cat', '/proc/1/comm')
    if ($r.ExitCode -eq 0) { $facts.Pid1 = $r.Output.Trim() }

    $r = Invoke-DistroCommand -Name $Name -Command @('df', '-Pk', '/')
    if ($r.ExitCode -eq 0) {
        $df = ConvertFrom-DfOutput -Text $r.Output
        if ($null -ne $df -and ($df.Used + $df.Available) -gt 0) {
            $facts.DiskPercent = [int][math]::Ceiling(100 * $df.Used / ($df.Used + $df.Available))
        }
    }

    $r = Invoke-DistroCommand -Name $Name -Command @('getent', 'hosts', $ProbeHost)
    if ($r.TimedOut -or $null -ne $r.ExitCode) { $facts.DnsOk = ($r.ExitCode -eq 0) }

    $r = Invoke-DistroCommand -Name $Name -Command @('sh', '-c', 'echo $PATH')
    if ($r.ExitCode -eq 0) { $facts.Path = $r.Output.Trim() }

    # Last, once the distro is warm, and against the midpoint of the host's
    # clock either side of the call, so start-up time is not read as drift.
    $before = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $r = Invoke-DistroCommand -Name $Name -Command @('date', '+%s')
    $after = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($r.ExitCode -eq 0 -and $r.Output.Trim() -match '^\d+$') {
        $facts.ClockDeltaSeconds = [long]$r.Output.Trim() - [long][math]::Round(($before + $after) / 2)
    }
    return $facts
}

# The verdicts for one distro: facts in, findings {Level (ok|info|warn|fail),
# Check, Message} out. Pure, so every threshold is tested with a hashtable.
# A fact that is missing was not measured and gets an info line, not a guess.
function Test-DistroFact {
    param([hashtable]$Facts)
    $findings = @()
    $name = $Facts['Name']

    if ($null -ne $Facts['Version']) {
        if ([int]$Facts['Version'] -eq 1) {
            $findings += [PSCustomObject]@{ Level = 'fail'; Check = 'version'; Message = "WSL1: no real kernel, docker/kind/k3s will not run; wsl --set-version $name 2" }
        } else {
            $findings += [PSCustomObject]@{ Level = 'ok'; Check = 'version'; Message = "WSL$($Facts['Version'])" }
        }
    }

    if ($Facts['User']) {
        if ($Facts['User'] -eq 'root') {
            $findings += [PSCustomObject]@{ Level = 'warn'; Check = 'default user'; Message = 'root (typical after wsl --import; restore -DefaultUser sets one at import time, README Restoring has the fix)' }
        } else {
            $findings += [PSCustomObject]@{ Level = 'ok'; Check = 'default user'; Message = $Facts['User'] }
        }
    } else {
        $findings += [PSCustomObject]@{ Level = 'info'; Check = 'default user'; Message = 'not measured' }
    }

    if ($Facts['Pid1']) {
        if ($Facts['Pid1'] -eq 'systemd') {
            $findings += [PSCustomObject]@{ Level = 'ok'; Check = 'init'; Message = 'systemd' }
        } else {
            $findings += [PSCustomObject]@{ Level = 'info'; Check = 'init'; Message = "no systemd (PID 1 is $($Facts['Pid1'])): set [boot] systemd=true in /etc/wsl.conf for docker/k3s services" }
        }
    }

    if ($null -ne $Facts['DiskPercent']) {
        $pct = [int]$Facts['DiskPercent']
        $remedy = "free space inside the distro, then 'compact' gives it back to Windows ('df' shows how much)"
        if ($pct -ge 95) {
            $findings += [PSCustomObject]@{ Level = 'fail'; Check = 'root filesystem'; Message = "$pct% used: $remedy" }
        } elseif ($pct -ge 85) {
            $findings += [PSCustomObject]@{ Level = 'warn'; Check = 'root filesystem'; Message = "$pct% used: $remedy" }
        } else {
            $findings += [PSCustomObject]@{ Level = 'ok'; Check = 'root filesystem'; Message = "$pct% used" }
        }
    } else {
        $findings += [PSCustomObject]@{ Level = 'info'; Check = 'root filesystem'; Message = 'not measured' }
    }

    if ($null -ne $Facts['ClockDeltaSeconds']) {
        $delta = [long]$Facts['ClockDeltaSeconds']
        $size = [math]::Abs($delta)
        $text = '{0} s {1} the host' -f $size, $(if ($delta -ge 0) { 'ahead of' } else { 'behind' })
        if ($size -gt 300) {
            $findings += [PSCustomObject]@{ Level = 'fail'; Check = 'clock'; Message = "$text (TLS and cloud API signatures fail): fix: wsl --shutdown, or sudo hwclock -s" }
        } elseif ($size -gt 5) {
            $findings += [PSCustomObject]@{ Level = 'warn'; Check = 'clock'; Message = "${text}: fix: wsl --shutdown, or sudo hwclock -s" }
        } else {
            $findings += [PSCustomObject]@{ Level = 'ok'; Check = 'clock'; Message = "$text" }
        }
    }

    if ($null -ne $Facts['DnsOk']) {
        if ($Facts['DnsOk']) {
            $findings += [PSCustomObject]@{ Level = 'ok'; Check = 'dns'; Message = "resolves $($Facts['ProbeHost'])" }
        } else {
            $findings += [PSCustomObject]@{ Level = 'warn'; Check = 'dns'; Message = "cannot resolve $($Facts['ProbeHost']). DNS broken? check the VPN, dnsTunneling in .wslconfig, /etc/resolv.conf" }
        }
    }

    if ($Facts['Path']) {
        $windowsDirs = @(($Facts['Path'] -split ':') | Where-Object { $_ -like '/mnt/c/*' }).Count
        if ($windowsDirs -gt 10) {
            $findings += [PSCustomObject]@{ Level = 'info'; Check = 'PATH'; Message = "$windowsDirs entries under /mnt/c: [interop] appendWindowsPath=false in /etc/wsl.conf would speed up completion" }
        }
    }
    return $findings
}

# The .tar files under $Directory that this script's backup action wrote:
# <distro>_<yyyy-MM-dd>_<HHmm>.tar, or with a -N before .tar when that minute
# was taken (see Get-UniqueBackupOutPath). Anything else in the folder is
# somebody else's file and is never a candidate for deletion.
function Get-BackupFile {
    param([string]$Directory, [string]$Name)
    Get-ChildItem -Path $Directory -Filter '*.tar' -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            if ($_.Name -match '^(?<distro>.+)_\d{4}-\d{2}-\d{2}_\d{4}(-\d+)?\.tar$') {
                [PSCustomObject]@{
                    Distro = $Matches['distro']
                    File   = $_
                }
            }
        } | Where-Object { -not $Name -or $_.Distro -eq $Name }
}

# Free bytes on the drive that holds $Path, or $null when that cannot be
# known: a UNC share, a drive that is not there, or any error at all. $null
# turns the free-space checks off rather than guessing.
function Get-FreeSpace {
    param([string]$Path)
    try {
        $full = [IO.Path]::GetFullPath($Path)
        if ($full.StartsWith('\\')) { return $null }
        $root = [IO.Path]::GetPathRoot($full)
        if (-not $root) { return $null }
        return [long]([IO.DriveInfo]::new($root).AvailableFreeSpace)
    } catch {
        return $null
    }
}

# The path of one dated export inside $Dir. A bare drive such as 'D:' is the
# drive-relative "current directory on D", which Combine would glue to the
# name as 'D:Ubuntu_...': treat it as the drive root 'D:\' instead. Pure.
function Get-BackupOutPath {
    param(
        [string]$Dir,
        [string]$Name,
        [string]$Stamp
    )
    [IO.Path]::Combine((ConvertTo-DriveRootPath $Dir), ('{0}_{1}.tar' -f $Name, $Stamp))
}

# Like Get-BackupOutPath, but never a path that is already taken, by the tar
# or by its .sha256 sidecar: when the minute stamp is in use, -1, -2 ... goes
# before .tar (Name_yyyy-MM-dd_HHmm-1.tar), which Get-BackupFile still reads.
# $null when 99 are taken. Nothing is created or overwritten.
function Get-UniqueBackupOutPath {
    param(
        [string]$Dir,
        [string]$Name,
        [string]$Stamp
    )
    for ($i = 0; $i -le 99; $i++) {
        $suffix = if ($i -eq 0) { $Stamp } else { '{0}-{1}' -f $Stamp, $i }
        $candidate = Get-BackupOutPath -Dir $Dir -Name $Name -Stamp $suffix
        if (-not (Test-Path -LiteralPath $candidate) -and -not (Test-Path -LiteralPath "$candidate.sha256")) {
            return $candidate
        }
    }
    return $null
}

# What 'backup -All' would do, one row {Name, Out, Bytes, Verb, Reason} per
# distro. Pure: the distros, the measured sizes and the free space are
# parameters, so the contract tests can feed it any machine.
#   SKIP   Docker Desktop's own distros. Docker manages and recreates them,
#          and exporting its data distro is a multi-gigabyte copy of images.
#   FAIL   the distro's measured use is more than the free space left: the
#          export cannot fit, so it is refused up front instead of failing
#          half way. Every measured export let through takes its size off
#          the space the next distro sees, because the tars share a drive.
#          An unmeasured one takes nothing off: its VHDX is only an upper
#          bound, and counting it would refuse sets that do fit.
#   WARN   not measured (stopped), and its VHDX is larger than the free space.
#          The VHDX is only an upper bound, so this exports anyway.
#   EXPORT everything else.
# One $Stamp for every row, so a set taken together is obvious from the names.
function Get-BackupPlan {
    param(
        [object[]]$Distros,
        [string]$DestDir,
        [string]$Stamp,
        [Nullable[long]]$FreeBytes,
        [hashtable]$UsedByName = @{}
    )
    $left = $FreeBytes
    foreach ($d in $Distros) {
        $out = Get-BackupOutPath -Dir $DestDir -Name $d.Name -Stamp $Stamp
        $used = $null
        if ($UsedByName.ContainsKey($d.Name)) { $used = $UsedByName[$d.Name] }
        $bytes = if ($null -ne $used) { [long]$used } else { [long]$d.VhdxSize }
        $verb = 'EXPORT'
        $reason = if ($null -ne $used) { 'measured' } else { 'VHDX size, an upper bound' }

        if ($d.Name -match '^docker-desktop(-data)?$') {
            $verb = 'SKIP'
            $reason = 'managed by Docker Desktop'
        } elseif ($null -ne $left -and $null -ne $used -and $used -gt $left) {
            $verb = 'FAIL'
            $reason = if ($left -lt $FreeBytes) {
                'needs ~{0}, {1} left after the earlier exports' -f (Format-Size $used), (Format-Size $left)
            } else {
                'needs ~{0}, {1} free' -f (Format-Size $used), (Format-Size $left)
            }
        } elseif ($null -ne $left -and $null -eq $used -and $d.VhdxSize -gt $left) {
            $verb = 'WARN'
            $reason = 'VHDX is {0}, {1} free; the export is usually smaller' -f (Format-Size $d.VhdxSize), (Format-Size $left)
        }
        if ($null -ne $left -and $null -ne $used -and $verb -eq 'EXPORT') {
            $left = [long]($left - $used)
        }

        [PSCustomObject]@{
            Name   = $d.Name
            Out    = $out
            Bytes  = $bytes
            Verb   = $verb
            Reason = $reason
        }
    }
}

# What wsl.exe printed, as text for Write-Host. Inside a function its output
# has to be captured, or it becomes part of the function's return value and
# a $false reads as true. wsl.exe writes UTF-16, which arrives here with a NUL
# after every character; dropping them leaves the message readable.
function Format-WslOutput {
    param([object[]]$Output)
    return ((@($Output) -join "`n") -replace "`0", '').Trim()
}

# One export and its .sha256 sidecar: the body of the single-distro backup,
# shared with -All. Returns $true or $false so -All can carry on past a
# failure; the single-distro path turns $false into exit 1 as it always did.
# The export goes to a path unique to this call and is moved onto $Out only
# once it has succeeded, so a failure removes nothing but its own partial
# file. A rerun in the same minute shares $Out with the earlier run, and
# that earlier tar and its sidecar must survive a failed second export.
function Invoke-DistroBackup {
    param(
        [string]$Name,
        [string]$Out
    )
    $token = [guid]::NewGuid().ToString('N')
    $part = '{0}.{1}.partial' -f $Out, $token
    $partSide = "$part.sha256"
    $keepTar = '{0}.{1}.old' -f $Out, $token
    $keepSide = "$keepTar.sha256"
    $side = "$Out.sha256"
    Write-Host "Exporting '$Name' -> $Out (this can take a while)..."
    try {
        $said = Format-WslOutput (wsl.exe --export $Name $part)
        if ($said) { Write-Host $said }
        if ($LASTEXITCODE -ne 0) {
            Write-Error "wsl --export failed (exit $LASTEXITCODE)" -ErrorAction Continue
            return $false
        }
        $hash = (Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash.ToLowerInvariant()
        # Both new files exist under temporary names before anything old is
        # touched. The old pair is then set aside, the new pair moved in, and
        # the old pair put back if any step fails, so a tar is never left
        # next to a checksum of a different file.
        $hadTar = Test-Path -LiteralPath $Out
        $hadSide = Test-Path -LiteralPath $side
        try {
            Set-Content -LiteralPath $partSide -Encoding ascii -Value "$hash  $([IO.Path]::GetFileName($Out))" -ErrorAction Stop
            if ($hadTar) { Move-Item -LiteralPath $Out -Destination $keepTar -Force -ErrorAction Stop }
            if ($hadSide) { Move-Item -LiteralPath $side -Destination $keepSide -Force -ErrorAction Stop }
            Move-Item -LiteralPath $part -Destination $Out -Force -ErrorAction Stop
            Move-Item -LiteralPath $partSide -Destination $side -Force -ErrorAction Stop
        } catch {
            Write-Error "Could not finish the backup of '$Name' ($($_.Exception.Message))" -ErrorAction Continue
            try {
                if ($hadTar -and (Test-Path -LiteralPath $keepTar)) {
                    Move-Item -LiteralPath $keepTar -Destination $Out -Force -ErrorAction Stop
                } elseif (-not $hadTar -and (Test-Path -LiteralPath $Out)) {
                    Remove-Item -LiteralPath $Out -Force -ErrorAction Stop
                }
                if ($hadSide -and (Test-Path -LiteralPath $keepSide)) {
                    Move-Item -LiteralPath $keepSide -Destination $side -Force -ErrorAction Stop
                } elseif (-not $hadSide -and (Test-Path -LiteralPath $side)) {
                    Remove-Item -LiteralPath $side -Force -ErrorAction Stop
                }
            } catch {
                Write-Error "The earlier backup could not be put back; it is kept as $keepTar" -ErrorAction Continue
            }
            return $false
        }
        Remove-Item -LiteralPath $keepTar, $keepSide -Force -ErrorAction SilentlyContinue
        return $true
    } finally {
        Remove-Item -LiteralPath $part, $partSide -Force -ErrorAction SilentlyContinue
    }
}

# Distros that are Running now, for the preview lines of the actions that
# would stop them.
function Get-RunningDistroText {
    $states = Get-DistroState
    $running = @($states.Keys | Where-Object { $states[$_] -eq 'Running' } | Sort-Object)
    if ($running) { return $running -join ', ' }
    return 'none'
}

# A Linux user name this script will write into /etc/wsl.conf: lowercase,
# starting with a letter or underscore, at most 32 characters. Strict on
# purpose: the name goes into a command line inside the distro, and passing
# this test is what makes quoting it unnecessary.
function Test-WslUserName {
    param([string]$Name)
    return ($Name -cmatch '^[a-z_][a-z0-9_-]{0,31}$')
}

# What to do with /etc/wsl.conf to set a default user, given its current text:
#   append   no [user] section yet: append one.
#   present  a [user] section already sets default=: leave it alone.
#   manual   a [user] section without default=: print the line to add rather
#            than guess at editing someone's INI file in place.
function Get-WslConfUserPlan {
    param([string]$Existing)
    $inUser = $false
    $hasUser = $false
    foreach ($raw in ($Existing -split "`n")) {
        $line = $raw.Trim()
        if ($line -match '^\[(?<name>[^\]]*)\]') {
            $inUser = ($Matches['name'].Trim() -eq 'user')
            if ($inUser) { $hasUser = $true }
            continue
        }
        if ($inUser -and $line -match '^default\s*=\s*\S') { return 'present' }
    }
    if ($hasUser) { return 'manual' }
    return 'append'
}

# The user name from one line of 'getent passwd', or $null.
function ConvertFrom-PasswdLine {
    param([string]$Line)
    $fields = $Line.Trim() -split ':'
    if ($fields.Count -lt 7 -or -not $fields[0]) { return $null }
    return $fields[0]
}

# The staging export clone writes. A leading dot and no date stamp, so the
# name can never match the pattern Get-BackupFile, prune-backups and backups
# use: a staging tar left behind is never mistaken for a backup.
function Get-CloneStagingName {
    param([string]$NewName, [int]$ProcessId)
    return '.clone-{0}-{1}.tar' -f $NewName, $ProcessId
}

# Make $User the default user of distro $Name through /etc/wsl.conf, then
# terminate it so the file is read at the next start, and confirm. Returns
# $false only when a step failed; a [user] section that needs a hand edit is
# printed and is not a failure.
function Invoke-DefaultUserStep {
    param(
        [string]$Name,
        [string]$User
    )
    # Absent on a fresh import: that is the append case, not an error. sh
    # swallows cat's complaint, because Windows PowerShell turns a native
    # command's stderr into a terminating error under 'Stop'. Every wsl.exe
    # call here is captured for the reason Format-WslOutput gives.
    $existing = wsl.exe -d $Name -u root --exec sh -c 'cat /etc/wsl.conf 2>/dev/null; true'
    $plan = Get-WslConfUserPlan -Existing ($existing -join "`n")
    if ($plan -eq 'present') {
        Write-Host "/etc/wsl.conf in '$Name' already names a default user; left as it is." -ForegroundColor Yellow
        return $true
    }
    if ($plan -eq 'manual') {
        Write-Host "/etc/wsl.conf in '$Name' has a [user] section without default=. Add this line to it:" -ForegroundColor Yellow
        Write-Host "  default=$User"
        Write-Host "then: .\wsl_manage.ps1 terminate -Distro $Name"
        return $true
    }
    # $User passed Test-WslUserName, so it needs no quoting inside sh -c.
    $said = Format-WslOutput (wsl.exe -d $Name -u root --exec sh -c "printf '\n[user]\ndefault=$User\n' >> /etc/wsl.conf")
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Could not append to /etc/wsl.conf in '$Name' (exit $LASTEXITCODE) $said" -ErrorAction Continue
        return $false
    }
    $said = Format-WslOutput (wsl.exe --terminate $Name)
    if ($LASTEXITCODE -ne 0) {
        Write-Error "wsl --terminate failed (exit $LASTEXITCODE) $said" -ErrorAction Continue
        return $false
    }
    $who = Format-WslOutput (wsl.exe -d $Name --exec id -un)
    if ($who -ne $User) {
        Write-Error "'$Name' starts as '$who', not $User. Does the user exist inside it? (wsl -d $Name -u root, then useradd)" -ErrorAction Continue
        return $false
    }
    Write-Host "'$Name' now starts as $User." -ForegroundColor Green
    return $true
}

# The state of one tar against the sidecar emitted by `backup`:
# {State (OK|MISSING|MALFORMED|MISMATCH), Sidecar, Expected, Actual}. Prints
# nothing, so verify-backup, restore and the backups inventory each say it
# their own way. The filename on the sidecar line is informational; the hash
# is always calculated over $Path, so moving a tar and its sidecar together
# remains valid.
function Get-BackupHashState {
    param([string]$Path)

    $result = [PSCustomObject]@{
        State    = 'OK'
        Sidecar  = "$Path.sha256"
        Expected = $null
        Actual   = $null
    }
    if (-not (Test-Path -LiteralPath $result.Sidecar -PathType Leaf)) {
        $result.State = 'MISSING'
        return $result
    }

    $line = [string](Get-Content -LiteralPath $result.Sidecar -TotalCount 1)
    if ($line.Trim() -notmatch '^(?<hash>[A-Fa-f0-9]{64})(?:\s+.*)?$') {
        $result.State = 'MALFORMED'
        return $result
    }
    $result.Expected = $Matches['hash'].ToUpperInvariant()
    $result.Actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($result.Actual -ne $result.Expected) {
        $result.State = 'MISMATCH'
    }
    return $result
}

# Verify one tar for verify-backup and restore, saying what was found.
function Test-BackupHash {
    param(
        [string]$Path,
        [switch]$RequireSidecar
    )

    $state = Get-BackupHashState -Path $Path
    switch ($state.State) {
        'MISSING' {
            if ($RequireSidecar) {
                Write-Error "No checksum sidecar: $($state.Sidecar)" -ErrorAction Continue
                return $false
            }
            Write-Host "No checksum sidecar at $($state.Sidecar); restore will continue for this older backup." -ForegroundColor Yellow
            return $true
        }
        'MALFORMED' {
            Write-Error "Malformed checksum sidecar: $($state.Sidecar)" -ErrorAction Continue
            return $false
        }
        'MISMATCH' {
            Write-Error "SHA-256 mismatch for $Path (expected $($state.Expected), got $($state.Actual))" -ErrorAction Continue
            return $false
        }
    }
    Write-Host "SHA-256 verified: $Path" -ForegroundColor Green
    return $true
}

# '3d' or '5h': the age column of the backups inventory.
function Format-Age {
    param([TimeSpan]$Age)
    if ($Age.TotalDays -ge 1) { return '{0}d' -f [int][math]::Floor($Age.TotalDays) }
    return '{0}h' -f [int][math]::Floor([math]::Max(0, $Age.TotalHours))
}

# .wslconfig as an ordered list of {Section, Key, Value, Line}. Pure: it takes
# the file's text, so the contract tests feed it fixture strings. INI as WSL
# reads it: ';' and '#' comment lines, [section] headers, key=value. A key
# before any header gets Section ''. A line that is neither is kept with a
# $null Value so the audit can say WSL ignores it, rather than this dropping
# it silently. The section name is kept exactly as written, spaces included,
# because '[wsl2 ]' is not '[wsl2]' to WSL either.
function ConvertFrom-WslConfig {
    param([string]$Text)
    $entries = @()
    if (-not $Text) { return $entries }
    $Text = $Text.TrimStart([char]0xFEFF)
    $section = ''
    $number = 0
    foreach ($raw in ($Text -split "`n")) {
        $number++
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#') -or $line.StartsWith(';')) { continue }
        if ($line -match '^\[(?<name>[^\]]*)\]\s*$') {
            $section = $Matches['name']
            continue
        }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) {
            $entries += [PSCustomObject]@{ Section = $section; Key = $line; Value = $null; Line = $number }
            continue
        }
        $entries += [PSCustomObject]@{
            Section = $section
            Key     = $line.Substring(0, $eq).Trim()
            Value   = $line.Substring($eq + 1).Trim()
            Line    = $number
        }
    }
    return $entries
}

# '8GB' -> bytes, or $null when the text is not a size WSL accepts. The unit
# is optional and a bare number is bytes (Microsoft's documented default), so
# 'swap=0', which turns swap off, is a valid size.
function ConvertTo-WslByteCount {
    param([string]$Text)
    if ($Text -notmatch '^(?<n>\d+(\.\d+)?)(?<unit>KB|MB|GB|TB|B)?$') { return $null }
    $unit = if ($Matches['unit']) { $Matches['unit'].ToUpperInvariant() } else { 'B' }
    $scale = switch ($unit) {
        'B'  { 1 }
        'KB' { 1KB }
        'MB' { 1MB }
        'GB' { 1GB }
        'TB' { 1TB }
    }
    # Past Int64 (or not a finite number at all) is not a size WSL can use:
    # report it as 'not a size' instead of letting the [long] cast throw.
    $number = 0.0
    if (-not [double]::TryParse($Matches['n'], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return $null }
    $scaled = $number * $scale
    if ([double]::IsNaN($scaled) -or [double]::IsInfinity($scaled) -or $scaled -ge 9.2233720368547758E+18) { return $null }
    return [long]$scaled
}

# The audit itself: entries from ConvertFrom-WslConfig in, findings
# {Level (ok|info|warn), Check, Message} out. Pure, like the parser. The two
# machine numbers are parameters, $null when unknown (always, off Windows), so
# the comparisons against the host are skipped with an info line instead of
# guessed. Nothing here is ever a failure on its own: WSL starts with a bad
# .wslconfig and ignores what it does not understand, which is the problem.
function Test-WslConfig {
    param(
        [object[]]$Entries,
        [Nullable[long]]$PhysicalMemoryBytes,
        [Nullable[int]]$LogicalProcessors
    )

    # Best effort, from Microsoft's 'Advanced settings configuration in WSL'
    # page. A key missing from here is reported as unrecognised, which is a
    # warning and never a failure: it may simply be newer than this table.
    $known = @{
        'general'      = @('instanceIdleTimeout', 'distributionInstallPath')
        'wsl2'         = @('kernel', 'kernelModules', 'memory', 'processors', 'swap', 'swapFile',
                           'localhostForwarding', 'kernelCommandLine', 'safeMode', 'nestedVirtualization',
                           'vmIdleTimeout', 'guiApplications', 'debugConsole', 'maxCrashDumpCount',
                           'networkingMode', 'firewall', 'dnsTunneling', 'autoProxy', 'defaultVhdSize',
                           'dnsProxy', 'pageReporting')
        'experimental' = @('autoMemoryReclaim', 'sparseVhd', 'bestEffortDnsParsing',
                           'initialAutoProxyTimeout', 'ignoredPorts', 'hostAddressLoopback',
                           'useWindowsDnsCache')
    }
    # Sections of /etc/wsl.conf inside a distro. Pasting one of them into
    # .wslconfig is the usual way a [boot] systemd=true goes nowhere.
    $distroSections = @('interop', 'automount', 'boot', 'user', 'network')

    $findings = @()
    $values = @{}
    foreach ($e in $Entries) {
        $label = if ($e.Section -eq '') { '{0} (line {1})' -f $e.Key, $e.Line } else { '[{0}] {1} (line {2})' -f $e.Section, $e.Key, $e.Line }

        if ($null -eq $e.Value) {
            $findings += [PSCustomObject]@{ Level = 'warn'; Check = $label; Message = 'not a key=value line; ignored by WSL' }
            continue
        }
        if ($e.Section -eq '') {
            $findings += [PSCustomObject]@{ Level = 'warn'; Check = $label; Message = 'before any [section]; ignored by WSL' }
            continue
        }

        $section = $e.Section.ToLowerInvariant()
        if (-not $known.ContainsKey($section)) {
            $why = if ($distroSections -contains $section) {
                "ignored by WSL: [$($e.Section)] belongs in /etc/wsl.conf inside the distro"
            } elseif ($section.Trim() -eq 'wsl2' -or $section -eq 'wsl') {
                'ignored by WSL: the section is [wsl2]'
            } else {
                "ignored by WSL: .wslconfig reads only [general], [wsl2] and [experimental]"
            }
            $findings += [PSCustomObject]@{ Level = 'warn'; Check = $label; Message = $why }
            continue
        }

        $canonical = $known[$section] | Where-Object { $_ -eq $e.Key } | Select-Object -First 1
        if (-not $canonical) {
            $other = @('general', 'wsl2', 'experimental') | Where-Object {
                $_ -ne $section -and ($known[$_] -contains $e.Key)
            } | Select-Object -First 1
            if ($other) {
                $findings += [PSCustomObject]@{ Level = 'warn'; Check = $label; Message = "belongs in [$other]; ignored here" }
            } else {
                $findings += [PSCustomObject]@{ Level = 'warn'; Check = $label; Message = 'unrecognised key (typo, or newer than this table)' }
            }
            continue
        }
        $values[$canonical] = $e
    }

    # Reported against the real line, so the label carries its line number.
    function Get-Label { param($Entry) '[{0}] {1} (line {2})' -f $Entry.Section, $Entry.Key, $Entry.Line }

    foreach ($sizeKey in @('memory', 'swap', 'defaultVhdSize')) {
        if (-not $values.ContainsKey($sizeKey)) { continue }
        $e = $values[$sizeKey]
        $bytes = ConvertTo-WslByteCount $e.Value
        if ($null -eq $bytes) {
            $findings += [PSCustomObject]@{ Level = 'warn'; Check = (Get-Label $e); Message = "'$($e.Value)' is not a size (use e.g. 8GB or 512MB)" }
            continue
        }
        if ($sizeKey -eq 'memory' -and $null -ne $PhysicalMemoryBytes -and $bytes -gt $PhysicalMemoryBytes) {
            $findings += [PSCustomObject]@{ Level = 'warn'; Check = (Get-Label $e); Message = ("{0} is more than this machine's {1:N1} GB of RAM" -f $e.Value, ($PhysicalMemoryBytes / 1GB)) }
            continue
        }
        $findings += [PSCustomObject]@{ Level = 'ok'; Check = (Get-Label $e); Message = $e.Value }
    }

    if ($values.ContainsKey('processors')) {
        $e = $values['processors']
        $count = 0
        if (-not [int]::TryParse($e.Value, [ref]$count) -or $count -lt 1) {
            $findings += [PSCustomObject]@{ Level = 'warn'; Check = (Get-Label $e); Message = "'$($e.Value)' is not a positive whole number" }
        } elseif ($null -ne $LogicalProcessors -and $count -gt $LogicalProcessors) {
            $findings += [PSCustomObject]@{ Level = 'warn'; Check = (Get-Label $e); Message = "$count is more than this machine's $LogicalProcessors logical processors" }
        } else {
            $findings += [PSCustomObject]@{ Level = 'ok'; Check = (Get-Label $e); Message = $e.Value }
        }
    }

    # Keys that take true or false. WSL does not say what it does with
    # anything else, so 'yes', '1' or 'ture' is reported rather than assumed
    # to work. Case does not matter; the check is -match, which ignores it.
    $booleanKeys = @('localhostForwarding', 'nestedVirtualization', 'guiApplications', 'debugConsole',
                     'safeMode', 'firewall', 'dnsTunneling', 'autoProxy', 'dnsProxy', 'pageReporting',
                     'sparseVhd', 'bestEffortDnsParsing', 'hostAddressLoopback', 'useWindowsDnsCache')
    $notBoolean = @{}
    foreach ($boolKey in $booleanKeys) {
        if (-not $values.ContainsKey($boolKey)) { continue }
        $e = $values[$boolKey]
        if ($e.Value -notmatch '^(true|false)$') {
            $notBoolean[$boolKey] = $true
            $findings += [PSCustomObject]@{ Level = 'warn'; Check = (Get-Label $e); Message = "'$($e.Value)' is not true or false" }
        }
    }

    # WSL reads these as INI strings, so a single backslash is an escape and
    # 'C:\Users\me\bzImage' arrives mangled. Doubled, or forward slashes, work.
    foreach ($pathKey in @('kernel', 'swapFile', 'kernelModules', 'distributionInstallPath')) {
        if (-not $values.ContainsKey($pathKey)) { continue }
        $e = $values[$pathKey]
        if ($e.Value -match '(?<!\\)\\(?!\\)') {
            $findings += [PSCustomObject]@{ Level = 'warn'; Check = (Get-Label $e); Message = 'backslashes in paths must be doubled (C:\\Users\\me\\...)' }
        }
    }

    if ($null -eq $PhysicalMemoryBytes -or $null -eq $LogicalProcessors) {
        $findings += [PSCustomObject]@{ Level = 'info'; Check = 'machine size'; Message = 'unknown here; memory and processors not compared with this machine' }
    }

    if (-not $values.ContainsKey('memory')) {
        $findings += [PSCustomObject]@{ Level = 'warn'; Check = '[wsl2] memory'; Message = 'no memory cap: the VM can grow to about half of RAM (set memory=8GB, say)' }
    }
    if ($values.ContainsKey('autoMemoryReclaim')) {
        $e = $values['autoMemoryReclaim']
        # -match ignores case, which is how WSL reads the value.
        if ($e.Value -match '^(disabled|gradual|dropCache)$') {
            $findings += [PSCustomObject]@{ Level = 'ok'; Check = (Get-Label $e); Message = $e.Value }
        } else {
            $findings += [PSCustomObject]@{ Level = 'warn'; Check = (Get-Label $e); Message = "'$($e.Value)' is not disabled, gradual or dropCache" }
        }
    } else {
        $findings += [PSCustomObject]@{ Level = 'info'; Check = '[experimental] autoMemoryReclaim'; Message = 'consider autoMemoryReclaim=gradual: freed memory goes back to Windows' }
    }
    if ($values.ContainsKey('sparseVhd')) {
        if (-not $notBoolean.ContainsKey('sparseVhd')) {
            $findings += [PSCustomObject]@{ Level = 'ok'; Check = (Get-Label $values['sparseVhd']); Message = $values['sparseVhd'].Value }
        }
    } else {
        $findings += [PSCustomObject]@{ Level = 'info'; Check = '[experimental] sparseVhd'; Message = 'consider sparseVhd=true (or wsl_manage.ps1 sparse for an existing distro)' }
    }
    # Whole-number settings other than processors (checked above). Digits are
    # matched as [0-9] so a non-ASCII digit does not pass. maxCrashDumpCount
    # allows -1 (keep every dump); the two idle timeouts allow -1 too (never
    # shut down); the other millisecond timeout does not go below 0.
    $integerKeys = @{
        'vmIdleTimeout' = -1; 'maxCrashDumpCount' = -1
        'instanceIdleTimeout' = -1; 'initialAutoProxyTimeout' = 0
    }
    foreach ($intKey in @($integerKeys.Keys | Sort-Object)) {
        if (-not $values.ContainsKey($intKey)) { continue }
        $e = $values[$intKey]
        $floor = $integerKeys[$intKey]
        $number = [long]0
        if ($e.Value -notmatch '^-?[0-9]{1,18}$' -or
            -not [long]::TryParse($e.Value, [System.Globalization.NumberStyles]::AllowLeadingSign, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or
            $number -lt $floor) {
            $findings += [PSCustomObject]@{ Level = 'warn'; Check = (Get-Label $e); Message = "'$($e.Value)' is not a whole number of $floor or more" }
        }
    }

    # Microsoft documents four current networking modes and the deprecated
    # bridged. An unknown value makes WSL fall back to NAT, so it is reported
    # rather than assumed to work. The checks are -match, which ignores case.
    if ($values.ContainsKey('networkingMode') -and $values['networkingMode'].Value -match '^bridged$') {
        $e = $values['networkingMode']
        $findings += [PSCustomObject]@{ Level = 'info'; Check = (Get-Label $e); Message = "'$($e.Value)' is deprecated; use nat, mirrored, virtioproxy or none" }
    } elseif ($values.ContainsKey('networkingMode') -and $values['networkingMode'].Value -notmatch '^(nat|mirrored|virtioproxy|none)$') {
        $e = $values['networkingMode']
        $findings += [PSCustomObject]@{ Level = 'warn'; Check = (Get-Label $e); Message = "'$($e.Value)' is not nat, mirrored, virtioproxy or none; WSL falls back to NAT" }
    }
    if ($values.ContainsKey('networkingMode') -and $values['networkingMode'].Value -eq 'mirrored' -and
        $values.ContainsKey('localhostForwarding')) {
        $findings += [PSCustomObject]@{ Level = 'info'; Check = (Get-Label $values['localhostForwarding']); Message = 'moot with networkingMode=mirrored, which shares localhost already' }
    }

    return $findings
}

# The starter file -Template prints. Printed, never written: the operator
# redirects it where they want it, so an existing .wslconfig cannot be lost.
function Get-WslConfigTemplate {
    @(
        '# .wslconfig - starter printed by wsl_manage.ps1 wslconfig -Template.'
        '# It lives in %USERPROFILE%. WSL reads it when the VM starts, so run'
        "# 'wsl --shutdown' after editing it."
        ''
        '[wsl2]'
        '# Cap the VM. Without a cap WSL2 can take about half of the RAM.'
        'memory=8GB'
        'processors=4'
        'swap=2GB'
        ''
        '[experimental]'
        '# Hand memory the VM no longer uses back to Windows, a little at a time.'
        'autoMemoryReclaim=gradual'
        '# New virtual disks give freed space back to Windows on their own.'
        'sparseVhd=true'
    )
}

# Installed RAM and logical processors for the comparisons in Test-WslConfig.
# Windows only and best effort: anything that does not answer is $null, and
# the audit says it skipped those two checks.
function Get-WslHostSize {
    $size = [PSCustomObject]@{ MemoryBytes = $null; Processors = $null }
    if (-not ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop')) { return $size }
    try {
        $size.MemoryBytes = [long](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
    } catch {
        $size.MemoryBytes = $null
    }
    try {
        $size.Processors = [Environment]::ProcessorCount
    } catch {
        $size.Processors = $null
    }
    return $size
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
        if ($All -and $Distro) {
            Write-Error '-All and -Distro are two ways of choosing what to back up; pass one of them.' -ErrorAction Continue
            exit 3
        }
        $stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'

        if ($All -or $DryRun) {
            $targets = if ($All) { @(Get-DistroInfo) } else { @(Resolve-Distro $Distro) }
            if (-not $targets) {
                Write-Host 'No registered distros.'
                break
            }
            # Measuring runs df inside the distro, so only distros that are
            # already running are measured; a stopped one is never started for
            # it, the rule df follows too.
            $states = Get-DistroState
            $usedByName = @{}
            foreach ($d in $targets) {
                if ($states[$d.Name] -eq 'Running' -and $d.Name -notmatch '^docker-desktop(-data)?$') {
                    $used = Get-DistroUsage $d.Name
                    if ($null -ne $used) { $usedByName[$d.Name] = $used }
                }
            }
            $plan = @(Get-BackupPlan -Distros $targets -DestDir $destRoot -Stamp $stamp `
                -FreeBytes (Get-FreeSpace $destRoot) -UsedByName $usedByName)

            if ($DryRun) {
                foreach ($row in $plan) {
                    $label = '{0} -> {1}' -f $row.Name, $row.Out
                    switch ($row.Verb) {
                        'SKIP' { Write-Host ('SKIP  {0,-44} {1}' -f $row.Name, $row.Reason) -ForegroundColor DarkGray }
                        'FAIL' { Write-Host ('FAIL  {0,-44} {1}' -f $label, $row.Reason) -ForegroundColor Red }
                        'WARN' {
                            Write-Host ('WOULD {0,-44} {1,10}' -f $label, (Format-Size $row.Bytes)) -ForegroundColor Cyan
                            Write-Host ('WARN  {0,-44} {1}' -f $row.Name, $row.Reason) -ForegroundColor Yellow
                        }
                        default { Write-Host ('WOULD {0,-44} {1,10}' -f $label, (Format-Size $row.Bytes)) -ForegroundColor Cyan }
                    }
                }
                $would = @($plan | Where-Object { $_.Verb -eq 'EXPORT' -or $_.Verb -eq 'WARN' }).Count
                Write-Host ("Dry run complete; {0} distro(s) would be exported, nothing was written." -f $would) -ForegroundColor Yellow
                break
            }

            if (-not (Test-Path $destRoot)) {
                New-Item -ItemType Directory -Path $destRoot -Force | Out-Null
            }
            $exported = 0
            $skipped = 0
            $failed = 0
            foreach ($row in $plan) {
                if ($row.Verb -eq 'SKIP') {
                    Write-Host ('SKIP  {0,-44} {1}' -f $row.Name, $row.Reason) -ForegroundColor DarkGray
                    $skipped++
                    continue
                }
                if ($row.Verb -eq 'FAIL') {
                    Write-Host ('FAIL  {0,-44} {1}' -f $row.Name, $row.Reason) -ForegroundColor Red
                    $failed++
                    continue
                }
                if ($row.Verb -eq 'WARN') {
                    Write-Host ('WARN  {0,-44} {1}' -f $row.Name, $row.Reason) -ForegroundColor Yellow
                }
                # One bad distro must not stop the rest.
                if (Invoke-DistroBackup -Name $row.Name -Out $row.Out) {
                    Write-Host ('DONE  {0,-44} {1,10}' -f $row.Out, (Format-Size (Get-Item -LiteralPath $row.Out).Length)) -ForegroundColor Green
                    $exported++
                } else {
                    # Invoke-DistroBackup removed its own partial file and
                    # never touched $row.Out, which may be an earlier backup.
                    Write-Host ('FAIL  {0,-44} {1}' -f $row.Name, 'wsl --export failed') -ForegroundColor Red
                    $failed++
                }
            }
            Write-Host ("Exported {0}, skipped {1}, failed {2}" -f $exported, $skipped, $failed)
            if ($failed -gt 0) { exit 1 }
            break
        }

        $info = Resolve-Distro $Distro
        if (-not (Test-Path $destRoot)) {
            New-Item -ItemType Directory -Path $destRoot -Force | Out-Null
        }
        $out = Get-BackupOutPath -Dir $destRoot -Name $info.Name -Stamp $stamp
        if (-not (Invoke-DistroBackup -Name $info.Name -Out $out)) { exit 1 }
        Write-Host ("Done: {0} ({1})" -f $out, (Format-Size (Get-Item $out).Length)) -ForegroundColor Green
        Write-Host "Checksum: $out.sha256"
        Write-Host "Restore it with: .\wsl_manage.ps1 restore -Distro $($info.Name)-restored -Tar `"$out`""
    }

    'verify-backup' {
        if (-not $Tar) {
            Write-Error 'verify-backup needs -Tar <path to .tar>.' -ErrorAction Continue
            exit 3
        }
        if (-not (Test-Path -LiteralPath $Tar -PathType Leaf)) {
            Write-Error "No such file: $Tar" -ErrorAction Continue
            exit 3
        }
        $tarPath = (Resolve-Path -LiteralPath $Tar).Path
        if (-not (Test-BackupHash -Path $tarPath -RequireSidecar)) { exit 1 }
    }

    'backups' {
        # Read-only: lists, hashes and reads sidecars; never deletes, renames
        # or rewrites one. Retention stays prune-backups' job.
        $backupFiles = @()
        if (Test-Path -LiteralPath $destRoot -PathType Container) {
            $backupFiles = @(Get-BackupFile -Directory $destRoot -Name $Distro)
        }
        if (-not $backupFiles) {
            Write-Host "No dated .tar exports under $destRoot"
            # Asked for a recent backup and there is none at all: that is the
            # stalest answer there is.
            if ($MaxAgeDays -gt 0) {
                Write-Host ('STALE no backup at all (limit {0} day(s))' -f $MaxAgeDays) -ForegroundColor Yellow
                exit 1
            }
            break
        }

        # Summed through ForEach-Object for Windows PowerShell 5.1, as in
        # prune-backups.
        $totalBytes = ($backupFiles | ForEach-Object { $_.File.Length } | Measure-Object -Sum).Sum
        if (-not $totalBytes) { $totalBytes = 0L }
        Write-Host "Directory: $destRoot"
        if ($Verify) {
            # Said before the work starts: hashing a multi-gigabyte tar takes
            # minutes, and silence reads as a hang.
            Write-Host ("Hashing {0} file(s), {1} total; this can take a while" -f $backupFiles.Count, (Format-Size $totalBytes))
        }
        Write-Host ''

        # LastWriteTime, the clock prune-backups uses as well.
        $now = Get-Date
        $verified = 0
        $bad = 0
        $missing = 0
        $stale = 0
        foreach ($group in ($backupFiles | Group-Object Distro | Sort-Object Name)) {
            $ordered = @($group.Group | Sort-Object { $_.File.LastWriteTime } -Descending)
            foreach ($entry in $ordered) {
                $file = $entry.File
                $label = '{0,-44} {1,10} {2,5}' -f $file.Name, (Format-Size $file.Length), (Format-Age ($now - $file.LastWriteTime))
                if (-not $Verify) {
                    $sidecar = if (Test-Path -LiteralPath "$($file.FullName).sha256" -PathType Leaf) { 'sha256:present' } else { 'sha256:missing' }
                    Write-Host ('OK    {0}   {1}' -f $label, $sidecar)
                    continue
                }
                $state = Get-BackupHashState -Path $file.FullName
                switch ($state.State) {
                    'OK' {
                        Write-Host ('OK    {0}   verified' -f $label) -ForegroundColor Green
                        $verified++
                    }
                    'MISSING' {
                        Write-Host ('MISS  {0}   no .sha256 sidecar' -f $label) -ForegroundColor Yellow
                        $missing++
                    }
                    'MALFORMED' {
                        Write-Host ('BAD   {0}   malformed sidecar' -f $label) -ForegroundColor Red
                        $bad++
                    }
                    'MISMATCH' {
                        Write-Host ('BAD   {0}   checksum mismatch' -f $label) -ForegroundColor Red
                        Write-Host ('      expected {0}' -f $state.Expected) -ForegroundColor Red
                        Write-Host ('      actual   {0}' -f $state.Actual) -ForegroundColor Red
                        $bad++
                    }
                }
            }
            if ($MaxAgeDays -gt 0) {
                $newestDays = ($now - $ordered[0].File.LastWriteTime).TotalDays
                if ($newestDays -gt $MaxAgeDays) {
                    Write-Host ('STALE {0} newest backup is {1} day(s) old (limit {2})' -f $group.Name, [int][math]::Floor($newestDays), $MaxAgeDays) -ForegroundColor Yellow
                    $stale++
                }
            }
        }

        Write-Host ''
        Write-Host ('{0} backup(s), {1} total, {2} verified, {3} bad, {4} missing sidecar, {5} stale distro(s)' -f
            $backupFiles.Count, (Format-Size $totalBytes), $verified, $bad, $missing, $stale)
        if ($bad -gt 0 -or $missing -gt 0 -or $stale -gt 0) { exit 1 }
    }

    'restore' {
        # First, before anything is read or imported: a typo here must not cost
        # a long import that then cannot set the user.
        if ($PSBoundParameters.ContainsKey('DefaultUser') -and -not (Test-WslUserName $DefaultUser)) {
            Write-Error "-DefaultUser '$DefaultUser' is not a valid Linux user name (lowercase letters, digits, _ and -, at most 32)." -ErrorAction Continue
            exit 3
        }
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
        # Restore imports a whole VM image, so it verifies by default. This
        # used to call Test-BackupHash without -RequireSidecar, which returns
        # $true when no .sha256 sits beside the tar: a backup whose sidecar was
        # deleted, or any tar dropped into the directory by something else,
        # imported while the operator was told nothing at all had gone wrong.
        # The refusal message below was unreachable in exactly the case it
        # described. Pre-sidecar backups are still importable, but now as a
        # stated choice rather than a silent default.
        $tarPath = (Resolve-Path -LiteralPath $Tar).Path
        if (-not (Test-BackupHash -Path $tarPath -RequireSidecar:(-not $AllowUnverified))) {
            Write-Error 'restore refused because backup integrity verification failed' -ErrorAction Continue
            if (-not $AllowUnverified) {
                Write-Error 'pass -AllowUnverified to import a backup that has no .sha256 sidecar' -ErrorAction Continue
            }
            exit 1
        }

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
            if ($DefaultUser) {
                Write-Host ('WOULD set default user     {0} in /etc/wsl.conf' -f $DefaultUser) -ForegroundColor Cyan
                Write-Host ('WOULD terminate            {0}' -f $Distro) -ForegroundColor Cyan
            }
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
        if ($DefaultUser) {
            if (-not (Invoke-DefaultUserStep -Name $Distro -User $DefaultUser)) {
                Write-Error "'$Distro' is imported, but its default user is not set; see above." -ErrorAction Continue
                exit 1
            }
            break
        }
        Write-Host 'It boots as root: --import does not carry the default user over. To set one:'
        Write-Host "  wsl -d $Distro -u root      then append to /etc/wsl.conf:"
        Write-Host '      [user]'
        Write-Host '      default=YOURNAME'
        Write-Host "  .\wsl_manage.ps1 terminate -Distro $Distro   (the file is read at next start)"
        Write-Host "  or next time: .\wsl_manage.ps1 restore ... -DefaultUser YOURNAME"
    }

    'clone' {
        # Every check that can refuse comes before the export, which is the
        # slow part.
        if ($PSBoundParameters.ContainsKey('DefaultUser') -and -not (Test-WslUserName $DefaultUser)) {
            Write-Error "-DefaultUser '$DefaultUser' is not a valid Linux user name (lowercase letters, digits, _ and -, at most 32)." -ErrorAction Continue
            exit 3
        }
        if (-not $NewName) {
            Write-Error 'clone needs -NewName <name> - the name the copy is registered under.' -ErrorAction Continue
            exit 3
        }
        if ($NewName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
            Write-Error "-NewName '$NewName' is not a usable distro name (letters, digits, '.', '_' and '-')." -ErrorAction Continue
            exit 3
        }
        $source = Resolve-Distro $Distro
        if ($NewName -eq $source.Name) {
            Write-Error '-NewName must differ from -Distro: a clone is a second registration.' -ErrorAction Continue
            exit 3
        }
        if (Get-DistroInfo | Where-Object Name -eq $NewName) {
            Write-Error "'$NewName' is already registered. clone never replaces a distro; choose another -NewName." -ErrorAction Continue
            exit 3
        }
        $target = if ($InstallDir) { $InstallDir } else { Join-Path $env:LOCALAPPDATA "WSL\$NewName" }
        if ((Test-Path $target) -and (Get-ChildItem -Path $target -Force -ErrorAction SilentlyContinue)) {
            Write-Error "Install directory is not empty: $target. Pass -InstallDir <empty or new dir>." -ErrorAction Continue
            exit 3
        }
        $staging = [IO.Path]::Combine($destRoot, (Get-CloneStagingName -NewName $NewName -ProcessId $PID))

        # Space for the staging tar. Only a running source is measured (df
        # inside it); a stopped one is never started for it, so its VHDX size
        # stands in as an upper bound and is not a reason to refuse.
        $states = Get-DistroState
        $used = $null
        if ($states[$source.Name] -eq 'Running') { $used = Get-DistroUsage $source.Name }
        $free = Get-FreeSpace $destRoot
        if ($null -ne $used -and $null -ne $free -and $used -gt $free) {
            Write-Error ("The staging export needs ~{0}, and {1} is free on the drive holding {2}. Pass -DestDir on a bigger drive." -f
                (Format-Size $used), (Format-Size $free), $destRoot) -ErrorAction Continue
            exit 1
        }
        $estimate = if ($null -ne $used) { '~{0}' -f (Format-Size $used) } else { 'up to {0}, the VHDX size' -f (Format-Size $source.VhdxSize) }

        $userText = $null
        if ($DefaultUser) {
            $userText = $DefaultUser
        } elseif ($source.DefaultUid) {
            $userText = "uid $($source.DefaultUid), the default user of '$($source.Name)'"
        }

        if ($DryRun) {
            Write-Host ('WOULD export             {0} -> {1} ({2})' -f $source.Name, $staging, $estimate) -ForegroundColor Cyan
            Write-Host ('WOULD create install dir {0}' -f $target) -ForegroundColor Cyan
            Write-Host ('WOULD import as          {0}' -f $NewName) -ForegroundColor Cyan
            if ($userText) {
                Write-Host ('WOULD set default user   {0} in /etc/wsl.conf' -f $userText) -ForegroundColor Cyan
            }
            Write-Host ('WOULD terminate          {0}' -f $NewName) -ForegroundColor Cyan
            if ($KeepTar) {
                Write-Host ('WOULD keep the export    as {0}_<date>.tar with a .sha256 sidecar in {1}' -f $source.Name, $destRoot) -ForegroundColor Cyan
            } else {
                Write-Host ('WOULD delete             {0}' -f $staging) -ForegroundColor Cyan
            }
            Write-Host 'Dry run complete; nothing was exported, registered or written.' -ForegroundColor Yellow
            break
        }

        if (-not (Test-Path $destRoot)) {
            New-Item -ItemType Directory -Path $destRoot -Force | Out-Null
        }
        $rc = 0
        $createdTarget = $false
        $imported = $false
        $kept = $false
        try {
            # Export is safe while the source runs, as backup already relies on.
            Write-Host "Exporting '$($source.Name)' to $staging ($estimate; this can take a while)..."
            wsl.exe --export $source.Name $staging
            if ($LASTEXITCODE -ne 0) {
                Write-Error "wsl --export failed (exit $LASTEXITCODE)" -ErrorAction Continue
                $rc = 1
            }

            if ($rc -eq 0) {
                if (-not (Test-Path $target)) {
                    New-Item -ItemType Directory -Path $target -Force | Out-Null
                    $createdTarget = $true
                }
                Write-Host "Importing as '$NewName' in $target (this can take a while)..."
                wsl.exe --import $NewName $target $staging --version 2
                if ($LASTEXITCODE -ne 0) {
                    Write-Error "wsl --import failed (exit $LASTEXITCODE)" -ErrorAction Continue
                    $rc = 1
                } else {
                    $imported = $true
                    Write-Host "Imported '$NewName'." -ForegroundColor Green
                }
            }

            if ($imported) {
                $user = $DefaultUser
                if (-not $user -and $source.DefaultUid) {
                    $line = wsl.exe -d $NewName -u root --exec getent passwd ([string]$source.DefaultUid) 2>$null | Select-Object -First 1
                    $user = ConvertFrom-PasswdLine ([string]$line)
                    if ($user -and -not (Test-WslUserName $user)) {
                        Write-Host "The source's default user '$user' is not a name this script writes; set it by hand." -ForegroundColor Yellow
                        $user = $null
                    }
                }
                if ($user) {
                    if (-not (Invoke-DefaultUserStep -Name $NewName -User $user)) { $rc = 1 }
                } else {
                    Write-Host "No default user to set; '$NewName' boots as root, like '$($source.Name)'."
                    wsl.exe --terminate $NewName
                }
            }

            if ($imported -and $KeepTar) {
                $dated = Get-UniqueBackupOutPath -Dir $destRoot -Name $source.Name -Stamp (Get-Date -Format 'yyyy-MM-dd_HHmm')
                # From here the staging tar is kept unless the move succeeds:
                # it is the only copy of the backup that was asked for.
                $kept = $true
                if (-not $dated) {
                    Write-Error "Could not pick a free backup name in $destRoot; the export is kept at $staging" -ErrorAction Continue
                    $rc = 1
                } else {
                    $moved = $false
                    try {
                        Move-Item -LiteralPath $staging -Destination $dated -ErrorAction Stop
                        $moved = $true
                        $hash = (Get-FileHash -LiteralPath $dated -Algorithm SHA256).Hash.ToLowerInvariant()
                        Set-Content -LiteralPath "$dated.sha256" -Encoding ascii -Value "$hash  $([IO.Path]::GetFileName($dated))"
                        Write-Host "Kept the export as a backup: $dated (with a .sha256 sidecar)."
                    } catch {
                        if ($moved) {
                            Write-Error "The export is at $dated but its .sha256 sidecar was not written ($($_.Exception.Message))" -ErrorAction Continue
                        } else {
                            Write-Error "Could not keep the export as $dated ($($_.Exception.Message)); any export left over is at $staging" -ErrorAction Continue
                        }
                        $rc = 1
                    }
                }
            }
        } finally {
            # Runs on success, failure and Ctrl+C alike: the staging tar is a
            # full copy of the distro and is never left behind by accident.
            if (-not $kept) {
                Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue
            }
            if (-not $imported -and $createdTarget) {
                Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        if ($rc -ne 0) { exit 1 }
        Write-Host "Cloned '$($source.Name)' as '$NewName'. Remove it when done with: wsl --unregister $NewName" -ForegroundColor Green
    }

    'prune-backups' {
        if (-not (Test-Path $destRoot)) {
            Write-Host "No backup directory at $destRoot - nothing to prune."
            break
        }

        $backupFiles = @(Get-BackupFile -Directory $destRoot -Name $Distro)
        if (-not $backupFiles) {
            Write-Host "No dated .tar exports under $destRoot - nothing to prune."
            break
        }

        # A file survives if EITHER rule wants to keep it: it is one of the
        # newest -KeepLast for its distro, or it is younger than -KeepDays.
        # Both rules have to agree before anything is deleted, which is the
        # conservative reading and the one that cannot surprise anybody.
        $cutoff = (Get-Date).AddDays(-$KeepDays)
        $keep = @()
        $prune = @()
        foreach ($group in ($backupFiles | Group-Object Distro)) {
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
        Write-Host ("Directory: $destRoot")
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
            $sidecar = "$($entry.File.FullName).sha256"
            if (Test-Path -LiteralPath $sidecar -PathType Leaf) {
                Remove-Item -LiteralPath $sidecar -Force
            }
        }
        Write-Host ("Deleted {0} file(s), freed {1}." -f $prune.Count, (Format-Size $freed)) -ForegroundColor Green
    }

    'compact' {
        try {
            $isAdmin = ([Security.Principal.WindowsPrincipal] `
                [Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        } catch {
            $isAdmin = $false
        }
        # The preview comes before the elevation check, so it answers in the
        # unelevated shell people actually try it from, and says what a real
        # run there would do.
        if ($DryRun) {
            $info = Resolve-Distro $Distro
            $states = Get-DistroState
            Write-Host ('WOULD stop WSL        (running: {0})' -f (Get-RunningDistroText)) -ForegroundColor Cyan
            Write-Host ('WOULD compact          {0} (now {1})' -f $info.Vhdx, (Format-Size $info.VhdxSize)) -ForegroundColor Cyan
            if ($states[$info.Name] -eq 'Running') {
                $used = Get-DistroUsage $info.Name
                if ($null -ne $used -and $info.VhdxSize -gt $used) {
                    Write-Host ('      about {0} reclaimable (allocated {1}, used {2})' -f
                        (Format-Size ($info.VhdxSize - $used)), (Format-Size $info.VhdxSize), (Format-Size $used)) -ForegroundColor Cyan
                }
            }
            if (-not $isAdmin) {
                Write-Host 'NOTE  this shell is not elevated; a real run would exit 4' -ForegroundColor Yellow
            }
            Write-Host 'Dry run complete; WSL was not stopped and no disk was touched.' -ForegroundColor Yellow
            break
        }
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
        if ($DryRun) {
            Write-Host ("WOULD set sparse={0} for '{1}'" -f $value, $info.Name) -ForegroundColor Cyan
            break
        }
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
        if ($DryRun) {
            Write-Host ('WOULD stop WSL        (running: {0})' -f (Get-RunningDistroText)) -ForegroundColor Cyan
            break
        }
        wsl.exe --shutdown
        Write-Host 'WSL stopped (all distros + utility VM). RAM released.' -ForegroundColor Green
    }

    'doctor' {
        # Read-only: the commands it runs inside a distro only read, and the
        # remedies are printed, never run. -DryRun changes nothing here.
        if ($ProbeHost -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]*$') {
            Write-Error "-ProbeHost must be a host name, got: $ProbeHost" -ErrorAction Continue
            exit 3
        }
        $list = @(Get-DistroList)
        if ($Distro) {
            $null = Resolve-Distro $Distro
            $targets = @($list | Where-Object { $_.Name -eq $Distro })
            if (-not $targets) { $targets = @([PSCustomObject]@{ Name = $Distro; State = 'Unknown'; Version = $null }) }
        } else {
            $targets = $list
        }
        if (-not $targets) {
            Write-Host 'No registered distros.'
            break
        }

        $warnCount = 0
        $failCount = 0
        foreach ($t in $targets) {
            if ($t.Name -match '^docker-desktop(-data)?$') {
                Write-Host ('SKIP  {0,-44} {1}' -f $t.Name, 'managed by Docker Desktop') -ForegroundColor DarkGray
                continue
            }
            # Measuring runs commands in the distro, and that starts a stopped
            # one: opt-in, the same rule df follows.
            if ($t.State -ne 'Running') {
                if (-not $Force) {
                    Write-Host ('SKIP  {0,-44} {1}' -f $t.Name, 'stopped (add -Force to start it and measure)') -ForegroundColor DarkGray
                    continue
                }
                Write-Host "Starting '$($t.Name)' to measure it (-Force)."
            }

            $facts = Get-DistroFact -Name $t.Name -Version $t.Version -ProbeHost $ProbeHost
            $version = if ($null -ne $t.Version) { "WSL$($t.Version)" } else { 'WSL?' }
            Write-Host ''
            Write-Host ('== {0} ({1}, {2}) ==' -f $t.Name, $t.State, $version)
            foreach ($f in @(Test-DistroFact -Facts $facts)) {
                switch ($f.Level) {
                    'ok'   { Write-Host ('OK    {0,-16} {1}' -f $f.Check, $f.Message) -ForegroundColor Green }
                    'info' { Write-Host ('INFO  {0,-16} {1}' -f $f.Check, $f.Message) -ForegroundColor DarkGray }
                    'warn' { Write-Host ('WARN  {0,-16} {1}' -f $f.Check, $f.Message) -ForegroundColor Yellow; $warnCount++ }
                    'fail' { Write-Host ('FAIL  {0,-16} {1}' -f $f.Check, $f.Message) -ForegroundColor Red; $failCount++ }
                }
            }
        }
        Write-Host ''
        Write-Host ('{0} warning(s), {1} failure(s)' -f $warnCount, $failCount)
        if ($failCount -gt 0) { exit 1 }
    }

    'wslconfig' {
        # Read-only by construction: one file read, nothing written, wsl.exe
        # never called. -DryRun is accepted and changes nothing.
        if ($Template) {
            # Write-Output, not Write-Host, so '> file' captures it.
            Get-WslConfigTemplate | Write-Output
            break
        }

        # An explicit path that is not there is a mistake worth exit 3. The
        # default path being absent is a finding, not an error: plenty of
        # machines have never had a .wslconfig.
        if ($ConfigFile) {
            $path = $ConfigFile
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                Write-Error "No such file: $path" -ErrorAction Continue
                exit 3
            }
        } else {
            $profileDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
            $path = Join-Path $profileDir '.wslconfig'
        }

        Write-Host "Checking $path"
        Write-Host ''
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Write-Host ('INFO  {0,-44} {1}' -f '.wslconfig', 'no .wslconfig: WSL2 sizes the VM itself and it can grow to about half of RAM') -ForegroundColor DarkGray
            Write-Host "Start one with: .\wsl_manage.ps1 wslconfig -Template > `"$path`""
            break
        }

        try {
            # ReadAllText honours a UTF-8 or UTF-16 BOM, which Notepad writes.
            $text = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $path).Path)
        } catch {
            Write-Error "Cannot read $path - $($_.Exception.Message)" -ErrorAction Continue
            exit 3
        }

        $hostSize = Get-WslHostSize
        $entries = @(ConvertFrom-WslConfig -Text $text)
        $findings = @(Test-WslConfig -Entries $entries -PhysicalMemoryBytes $hostSize.MemoryBytes -LogicalProcessors $hostSize.Processors)

        foreach ($f in $findings) {
            switch ($f.Level) {
                'ok'   { Write-Host ('OK    {0,-44} {1}' -f $f.Check, $f.Message) -ForegroundColor Green }
                'info' { Write-Host ('INFO  {0,-44} {1}' -f $f.Check, $f.Message) -ForegroundColor DarkGray }
                'warn' { Write-Host ('WARN  {0,-44} {1}' -f $f.Check, $f.Message) -ForegroundColor Yellow }
            }
        }

        $warnings = @($findings | Where-Object { $_.Level -eq 'warn' }).Count
        Write-Host ''
        Write-Host ("{0} warning(s). WSL reads this file when the VM starts: 'wsl --shutdown' after editing it." -f $warnings)
        if ($Strict -and $warnings -gt 0) { exit 1 }
    }
}
