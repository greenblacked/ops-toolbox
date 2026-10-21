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
      restore   Import a .tar back as a NEW distro (wsl --import). It never
                overwrites an existing registration - see the notes below,
                because restore has two surprises worth knowing in advance.
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
    .\wsl_manage.ps1 restore -Distro Ubuntu-restored -Tar D:\Backups\Ubuntu_2026-08-08_0930.tar
    .\wsl_manage.ps1 prune-backups -DestDir D:\Backups -KeepDays 30 -KeepLast 2 -DryRun
    .\wsl_manage.ps1 compact -Distro Ubuntu -DryRun
    .\wsl_manage.ps1 compact -Distro Ubuntu
    .\wsl_manage.ps1 sparse -Distro Ubuntu
    .\wsl_manage.ps1 terminate -Distro Ubuntu
    .\wsl_manage.ps1 shutdown
    .\wsl_manage.ps1 wslconfig
    .\wsl_manage.ps1 wslconfig -ConfigFile D:\profiles\.wslconfig -Strict
    .\wsl_manage.ps1 wslconfig -Template > $env:USERPROFILE\.wslconfig.new

.NOTES
    Exit codes:
      0  success (wslconfig: the report ran; warnings alone do not change it)
      1  the underlying wsl/diskpart command failed
         (backup -All: one or more exports failed; the rest still ran)
         (wslconfig -Strict: one or more WARN findings)
      2  WSL is not installed or not operational
      3  bad arguments (no -Distro, no such distro, missing or unusable -Tar,
         a -ConfigFile that does not exist or cannot be read)
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
    [ValidateSet('list', 'df', 'backup', 'verify-backup', 'restore', 'prune-backups', 'compact', 'sparse', 'terminate', 'shutdown', 'wslconfig')]
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
    [switch]$DryRun,  # backup, restore, prune-backups, compact, sparse,
                      # terminate, shutdown: report, change nothing
    [switch]$All,     # backup only: export every registered distro
    [switch]$Off,     # sparse only: pass to set sparse=false instead of true
    [switch]$AllowUnverified, # restore only: import a tar with no .sha256 sidecar
    [string]$ConfigFile,      # wslconfig: audit this file instead of %USERPROFILE%\.wslconfig
    [switch]$Template,        # wslconfig: print a commented starter file, write nothing
    [switch]$Strict           # wslconfig: exit 1 when any finding is a WARN
)

$ErrorActionPreference = 'Stop'

# PowerShell 7.3 and later turn a non-zero exit from a native command into a
# terminating error while $ErrorActionPreference is 'Stop'. Every wsl.exe call
# here is followed by its own $LASTEXITCODE check with a specific message and
# exit code, and none of them would ever be reached. Older hosts (Windows
# PowerShell 5.1) simply do not have this variable and ignore the assignment.
$PSNativeCommandUseErrorActionPreference = $false

# Actions that only read files on the Windows side. They need no WSL at all,
# so they also run on a machine that only holds the backups or the config
# file, and on the Linux runner that tests them.
$offlineActions = @('verify-backup', 'wslconfig')

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

# What 'backup -All' would do, one row {Name, Out, Bytes, Verb, Reason} per
# distro. Pure: the distros, the measured sizes and the free space are
# parameters, so the contract tests can feed it any machine.
#   SKIP   Docker Desktop's own distros. Docker manages and recreates them,
#          and exporting its data distro is a multi-gigabyte copy of images.
#   FAIL   the distro's measured use is more than the free space: the export
#          cannot fit, so it is refused up front instead of failing half way.
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
    foreach ($d in $Distros) {
        $out = Join-Path $DestDir ('{0}_{1}.tar' -f $d.Name, $Stamp)
        $used = $null
        if ($UsedByName.ContainsKey($d.Name)) { $used = $UsedByName[$d.Name] }
        $bytes = if ($null -ne $used) { [long]$used } else { [long]$d.VhdxSize }
        $verb = 'EXPORT'
        $reason = if ($null -ne $used) { 'measured' } else { 'VHDX size, an upper bound' }

        if ($d.Name -match '^docker-desktop(-data)?$') {
            $verb = 'SKIP'
            $reason = 'managed by Docker Desktop'
        } elseif ($null -ne $FreeBytes -and $null -ne $used -and $used -gt $FreeBytes) {
            $verb = 'FAIL'
            $reason = 'needs ~{0}, {1} free' -f (Format-Size $used), (Format-Size $FreeBytes)
        } elseif ($null -ne $FreeBytes -and $null -eq $used -and $d.VhdxSize -gt $FreeBytes) {
            $verb = 'WARN'
            $reason = 'VHDX is {0}, {1} free; the export is usually smaller' -f (Format-Size $d.VhdxSize), (Format-Size $FreeBytes)
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
function Invoke-DistroBackup {
    param(
        [string]$Name,
        [string]$Out
    )
    Write-Host "Exporting '$Name' -> $Out (this can take a while)..."
    $said = Format-WslOutput (wsl.exe --export $Name $Out)
    if ($said) { Write-Host $said }
    if ($LASTEXITCODE -ne 0) {
        Write-Error "wsl --export failed (exit $LASTEXITCODE)" -ErrorAction Continue
        return $false
    }
    $hash = (Get-FileHash -LiteralPath $Out -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$Out.sha256" -Encoding ascii -Value "$hash  $([IO.Path]::GetFileName($Out))"
    return $true
}

# Distros that are Running now, for the preview lines of the actions that
# would stop them.
function Get-RunningDistroText {
    $states = Get-DistroState
    $running = @($states.Keys | Where-Object { $states[$_] -eq 'Running' } | Sort-Object)
    if ($running) { return $running -join ', ' }
    return 'none'
}

# Verify the sidecar emitted by `backup`. The filename on the sidecar line is
# informational; the hash is always calculated over the explicit -Tar path, so
# moving a tar and its sidecar together remains valid.
function Test-BackupHash {
    param(
        [string]$Path,
        [switch]$RequireSidecar
    )

    $sidecar = "$Path.sha256"
    if (-not (Test-Path -LiteralPath $sidecar -PathType Leaf)) {
        if ($RequireSidecar) {
            Write-Error "No checksum sidecar: $sidecar" -ErrorAction Continue
            return $false
        }
        Write-Host "No checksum sidecar at $sidecar; restore will continue for this older backup." -ForegroundColor Yellow
        return $true
    }

    $line = (Get-Content -LiteralPath $sidecar -TotalCount 1).Trim()
    if ($line -notmatch '^(?<hash>[A-Fa-f0-9]{64})(?:\s+.*)?$') {
        Write-Error "Malformed checksum sidecar: $sidecar" -ErrorAction Continue
        return $false
    }
    $expected = $Matches['hash'].ToUpperInvariant()
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actual -ne $expected) {
        Write-Error "SHA-256 mismatch for $Path (expected $expected, got $actual)" -ErrorAction Continue
        return $false
    }
    Write-Host "SHA-256 verified: $Path" -ForegroundColor Green
    return $true
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

# '8GB' -> bytes, or $null when the text is not a size WSL accepts.
function ConvertTo-WslByteCount {
    param([string]$Text)
    if ($Text -notmatch '^(?<n>\d+(\.\d+)?)(?<unit>KB|MB|GB|TB|B)$') { return $null }
    $scale = switch ($Matches['unit'].ToUpperInvariant()) {
        'B'  { 1 }
        'KB' { 1KB }
        'MB' { 1MB }
        'GB' { 1GB }
        'TB' { 1TB }
    }
    return [long]([double]$Matches['n'] * $scale)
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
                "ignored by WSL: .wslconfig reads only [wsl2] and [experimental]"
            }
            $findings += [PSCustomObject]@{ Level = 'warn'; Check = $label; Message = $why }
            continue
        }

        $other = if ($section -eq 'wsl2') { 'experimental' } else { 'wsl2' }
        $canonical = $known[$section] | Where-Object { $_ -eq $e.Key } | Select-Object -First 1
        if (-not $canonical) {
            $elsewhere = $known[$other] | Where-Object { $_ -eq $e.Key } | Select-Object -First 1
            if ($elsewhere) {
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

    foreach ($sizeKey in @('memory', 'swap')) {
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

    # WSL reads these as INI strings, so a single backslash is an escape and
    # 'C:\Users\me\bzImage' arrives mangled. Doubled, or forward slashes, work.
    foreach ($pathKey in @('kernel', 'swapFile')) {
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
        $findings += [PSCustomObject]@{ Level = 'ok'; Check = (Get-Label $values['autoMemoryReclaim']); Message = $values['autoMemoryReclaim'].Value }
    } else {
        $findings += [PSCustomObject]@{ Level = 'info'; Check = '[experimental] autoMemoryReclaim'; Message = 'consider autoMemoryReclaim=gradual: freed memory goes back to Windows' }
    }
    if ($values.ContainsKey('sparseVhd')) {
        $findings += [PSCustomObject]@{ Level = 'ok'; Check = (Get-Label $values['sparseVhd']); Message = $values['sparseVhd'].Value }
    } else {
        $findings += [PSCustomObject]@{ Level = 'info'; Check = '[experimental] sparseVhd'; Message = 'consider sparseVhd=true (or wsl_manage.ps1 sparse for an existing distro)' }
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
            $plan = @(Get-BackupPlan -Distros $targets -DestDir $DestDir -Stamp $stamp `
                -FreeBytes (Get-FreeSpace $DestDir) -UsedByName $usedByName)

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

            if (-not (Test-Path $DestDir)) {
                New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
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
                    # The half-written tar carries this run's stamp and no
                    # sidecar; leaving it would look like a backup to prune.
                    Remove-Item -LiteralPath $row.Out -Force -ErrorAction SilentlyContinue
                    Write-Host ('FAIL  {0,-44} {1}' -f $row.Name, 'wsl --export failed') -ForegroundColor Red
                    $failed++
                }
            }
            Write-Host ("Exported {0}, skipped {1}, failed {2}" -f $exported, $skipped, $failed)
            if ($failed -gt 0) { exit 1 }
            break
        }

        $info = Resolve-Distro $Distro
        if (-not (Test-Path $DestDir)) {
            New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
        }
        $out = Join-Path $DestDir "$($info.Name)_$stamp.tar"
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
