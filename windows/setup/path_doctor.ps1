<#
.SYNOPSIS
    PATH hygiene report for Windows, and a cleanup of the user PATH.

.DESCRIPTION
    A bloated or broken PATH is a daily Windows tax, and most of it is
    invisible from a prompt: duplicate and dead entries left by uninstalled
    tools, a value 'setx' silently cut at 1024 characters, a user PATH stored
    as REG_SZ so that %USERPROFILE%\bin is never expanded, the Microsoft Store
    python.exe alias answering ahead of the real Python, and Git's usr\bin
    putting the MSYS find.exe and sort.exe ahead of the Windows ones.

    Two actions:

      report  (default, read-only) both PATH values as stored in the
              registry, what is wrong with each entry, and which copy of
              each common command wins
      clean   removes, from the USER PATH only, empty entries, repeated
              entries and absolute folders that no longer exist. Nothing else.

    'clean' is the one thing in this script that writes, and it is built to be
    hard to regret:

      - it needs -Yes, and refuses (exit 3) with neither -Yes nor -DryRun,
        before anything is read
      - -DryRun prints every entry it would remove, and why, and creates
        nothing - not even the backup folder
      - it never touches the machine PATH; edit that in System Properties
      - it never removes an entry holding a %VARIABLE% or a relative entry,
        because it cannot judge them, nor a folder on a drive that is not
        there right now (an unplugged disk is not a dead entry)
      - it writes a backup of both PATH values first, and stops if it cannot
      - it writes the value back with its original registry kind -
        [Environment]::SetEnvironmentVariable would quietly turn a
        REG_EXPAND_SZ into REG_SZ - and reads it back to verify
      - running it twice changes nothing the second time

    The values are read raw from the registry, with %VARIABLES% left
    unexpanded, which is the only way to see the REG_SZ problem at all.

    The usage checks and the -Yes gate answer before the Windows preflight.

.PARAMETER Scope
    Which PATH 'report' reads: All (default), User or Machine. 'clean' only
    ever works on User; asking it for Machine or All is refused.

.PARAMETER Command
    Commands to check for shadowing. Default: a list of common developer
    tools plus find and sort.

.PARAMETER BackupDir
    Where 'clean' writes its backup. Default: path-backups under the user
    profile.

.EXAMPLE
    .\path_doctor.ps1
    .\path_doctor.ps1 report -Scope User
    .\path_doctor.ps1 report -Command python,node,kubectl
    .\path_doctor.ps1 clean -DryRun
    .\path_doctor.ps1 clean -Yes

.NOTES
    Exit codes:
      0  report printed, or clean finished (including nothing to clean)
      1  clean could not read, back up, write or verify the user PATH
      2  not Windows
      3  bad arguments, or clean refused: neither -DryRun nor -Yes, or a
         -Scope other than User
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('report', 'clean')]
    [string]$Action = 'report',

    [switch]$DryRun,

    # The consent gate, spelled the way clean_disk_c.ps1 and stay_fresh.ps1
    # spell it. Deliberately not SupportsShouldProcess; see CONTRIBUTING.md.
    [switch]$Yes,

    # Checked by hand below rather than with ValidateSet: a binding failure
    # under 'pwsh -File' exits 1, and a bad value here is a usage error (3).
    [string]$Scope = 'All',

    # Split on commas in the body, for the reason stay_fresh.ps1 gives.
    [string[]]$Command = @(),

    [string]$BackupDir = '',

    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$script:Warnings = 0
$script:QuietMode = [bool]$Quiet

function Write-Info {
    param([string]$Message)
    if (-not $script:QuietMode) { Write-Host "[info] $Message" -ForegroundColor Blue }
}
function Write-Ok {
    param([string]$Message)
    if (-not $script:QuietMode) { Write-Host "[ ok ] $Message" -ForegroundColor Green }
}
function Write-Warn {
    param([string]$Message, [string[]]$Hint = @())
    $script:Warnings++
    Write-Host "[warn] $Message" -ForegroundColor Yellow
    foreach ($line in $Hint) { Write-Host "  $line" -ForegroundColor DarkGray }
}
function Write-Err  { param([string]$Message) Write-Host "[err ] $Message" -ForegroundColor Red }
function Write-Section {
    param([string]$Name)
    if (-not $script:QuietMode) { Write-Host ''; Write-Host "== $Name ==" -ForegroundColor White }
}

# --- pure helpers -----------------------------------------------------------
# Plain data in, plain data out, so windows/tests/contract.ps1 can lift each
# one out of this file and test it with fixtures. The disk and the
# environment come in as scriptblocks (-Exists, -Expand) for the same reason.

# Findings for one scope's PATH. Entries is the raw value split on ';',
# OtherEntries the other scope's, Kind the registry kind ('String' or
# 'ExpandString'), Length the raw value's length. Returns
# { Level (info|warn|fail), Code, Entry, Message }.
function Get-PathFinding {
    param(
        [string[]]$Entries,
        [string]$Scope,
        [string]$Kind,
        [scriptblock]$Exists,
        [scriptblock]$Expand,
        [int]$Length,
        [string[]]$OtherEntries = @()
    )
    # Case, surrounding quotes and a trailing slash do not make two entries
    # different folders.
    $normalise = { param([string]$Text) $Text.Trim().Trim('"').TrimEnd('\', '/').ToLowerInvariant() }
    $findings = @()
    $seen = [ordered]@{}
    $dupSeen = @{}
    $position = 0
    foreach ($raw in $Entries) {
        $entry = [string]$raw
        $position++
        if ($entry.Trim() -eq '') {
            $findings += [pscustomobject]@{ Level = 'info'; Code = 'empty-entry'; Entry = $entry
                Message = "$Scope PATH has an empty entry at position $position" }
            continue
        }

        # A REG_SZ value is used as written: Windows does not expand it, so
        # neither does this.
        $effective = $entry
        if ($Kind -ne 'String') { $effective = [string](& $Expand $entry) }
        if ($Kind -eq 'String' -and $entry -match '%[^%;]+%') {
            $findings += [pscustomobject]@{ Level = 'warn'; Code = 'unexpanded-var'; Entry = $entry
                Message = "$Scope PATH is stored as REG_SZ, so $entry is used literally and never expanded (the setx pitfall); rewrite the value as REG_EXPAND_SZ" }
        }
        if ($entry.Contains('"')) {
            $findings += [pscustomobject]@{ Level = 'warn'; Code = 'quoted-entry'; Entry = $entry
                Message = "$Scope PATH entry $entry is quoted; quotes in PATH are not honoured everywhere, and a folder with spaces needs none" }
        }

        $key = & $normalise $effective
        # The same rule as Get-CleanedPath: only an entry clean can judge (an
        # absolute drive path with no %VARIABLE%, not quoted) is a first copy
        # or a duplicate. One it cannot judge may not work as written, so it
        # never makes a later judgeable equivalent a duplicate.
        $judgeable = ($entry -notmatch '%') -and ($entry.Trim() -match '^[A-Za-z]:\\')
        if ($judgeable) {
            if ($dupSeen.Contains($key)) {
                $findings += [pscustomobject]@{ Level = 'warn'; Code = 'duplicate'; Entry = $entry
                    Message = "$Scope PATH entry $position ($entry) repeats entry $($dupSeen[$key])" }
                continue
            }
            $dupSeen[$key] = $position
        }
        if (-not $seen.Contains($key)) { $seen[$key] = $position }

        $bare = $effective.Trim().Trim('"')
        if ($bare -match '%') { continue }
        if ($bare -notmatch '^([A-Za-z]:[\\/]|\\\\)') {
            $findings += [pscustomobject]@{ Level = 'warn'; Code = 'relative-entry'; Entry = $entry
                Message = "$Scope PATH entry $entry is relative: it resolves against whatever folder a program starts in" }
            continue
        }
        if (-not (& $Exists $bare)) {
            $findings += [pscustomobject]@{ Level = 'warn'; Code = 'missing-dir'; Entry = $entry
                Message = "$Scope PATH entry $entry does not exist" }
        }
    }

    $other = @{}
    foreach ($raw in $OtherEntries) {
        $text = [string]$raw
        if ($text.Trim() -eq '') { continue }
        $other[(& $normalise ([string](& $Expand $text)))] = $true
    }
    foreach ($key in $seen.Keys) {
        if ($other.Contains($key)) {
            $findings += [pscustomobject]@{ Level = 'info'; Code = 'cross-scope-duplicate'; Entry = $key
                Message = "$key is in both the user and the machine PATH; the machine copy is searched first" }
        }
    }

    if ($Length -gt 32767) {
        $findings += [pscustomobject]@{ Level = 'fail'; Code = 'too-long'; Entry = ''
            Message = "$Scope PATH is $Length characters, over the 32767 Windows can hold in one variable" }
    } elseif ($Length -gt 2048) {
        $findings += [pscustomobject]@{ Level = 'warn'; Code = 'too-long'; Entry = ''
            Message = "$Scope PATH is $Length characters: older installers and some cmd.exe tools truncate anything over 2048" }
    } elseif ($Length -gt 1024) {
        $findings += [pscustomobject]@{ Level = 'warn'; Code = 'too-long'; Entry = ''
            Message = "$Scope PATH is $Length characters: 'setx PATH' would truncate it at 1024, so never edit it that way" }
    }
    return $findings
}

# What 'clean' would leave. Removes only empty entries, repeats of an earlier
# entry, and absolute folders that do not exist on a drive that does. Keeps
# everything it cannot judge: an entry with a %VARIABLE%, a relative or
# quoted entry, a UNC path. Order and the original text are preserved.
# Kind is the registry kind; for 'String' nothing is expanded.
# Returns { Value, Removed = { Entry, Reason }[] }.
function Get-CleanedPath {
    param(
        [string[]]$Entries,
        [scriptblock]$Exists,
        [scriptblock]$Expand,
        [string]$Kind = 'ExpandString'
    )
    $normalise = { param([string]$Text) $Text.Trim().Trim('"').TrimEnd('\', '/').ToLowerInvariant() }
    $kept = @()
    $removed = @()
    $seen = @{}
    foreach ($raw in $Entries) {
        $entry = [string]$raw
        if ($entry.Trim() -eq '') {
            $removed += [pscustomobject]@{ Entry = $entry; Reason = 'empty' }
            continue
        }
        $judgeable = ($entry -notmatch '%') -and ($entry.Trim() -match '^[A-Za-z]:\\')
        # Only an entry clean can judge counts as the first copy. An entry it
        # cannot judge (quoted, a %VARIABLE%, relative) may not work as
        # written, e.g. a REG_SZ %VAR% is never expanded by Windows, so it
        # must not make a later usable copy of the same folder a duplicate.
        $effective = $entry
        if ($Kind -ne 'String') { $effective = [string](& $Expand $entry) }
        $key = & $normalise $effective
        if ($judgeable) {
            if ($seen.Contains($key)) {
                $removed += [pscustomobject]@{ Entry = $entry; Reason = 'duplicate' }
                continue
            }
            $seen[$key] = $true
        }
        if ($judgeable) {
            $folder = $entry.Trim()
            if ((& $Exists $folder.Substring(0, 3)) -and -not (& $Exists $folder)) {
                $removed += [pscustomobject]@{ Entry = $entry; Reason = 'missing' }
                continue
            }
        }
        $kept += $entry
    }
    return [pscustomobject]@{ Value = ($kept -join ';'); Removed = $removed }
}

# Which copy of a command wins, and whether that is a known trap. Resolved
# maps a command name to every full path it resolves to, in PATH order.
# Returns { Level (info|warn), Code, Name, Message }.
function Get-ShadowFinding {
    param([hashtable]$Resolved)
    $findings = @()
    $msysTools = @('find', 'sort', 'curl', 'ssh', 'tar')
    foreach ($name in @($Resolved.Keys | Sort-Object)) {
        $paths = @($Resolved[$name])
        if ($paths.Count -lt 2) { continue }

        if ($name -match '^python3?$' -and $paths[0] -match '\\WindowsApps\\') {
            $real = @($paths | Where-Object { $_ -notmatch '\\WindowsApps\\' })
            if ($real.Count -gt 0) {
                $findings += [pscustomobject]@{ Level = 'warn'; Code = 'store-alias'; Name = $name
                    Message = "$name resolves to the Microsoft Store alias $($paths[0]) ahead of $($real[0]); turn it off in Settings > Apps > Advanced app settings > App execution aliases" }
                continue
            }
        }

        if ($msysTools -contains $name) {
            $gitAt = -1
            $systemAt = -1
            for ($i = 0; $i -lt $paths.Count; $i++) {
                if ($gitAt -lt 0 -and $paths[$i] -match '\\Git\\usr\\bin\\') { $gitAt = $i }
                if ($systemAt -lt 0 -and $paths[$i] -match '\\System32\\') { $systemAt = $i }
            }
            if ($gitAt -ge 0 -and $systemAt -ge 0 -and $gitAt -lt $systemAt) {
                $findings += [pscustomobject]@{ Level = 'warn'; Code = 'msys-shadow'; Name = $name
                    Message = "$name resolves to Git's MSYS copy $($paths[$gitAt]) ahead of $($paths[$systemAt]); batch files calling $name get the Unix tool. Move Git\usr\bin after System32, or let the Git installer add only Git\cmd" }
                continue
            }
        }

        $findings += [pscustomobject]@{ Level = 'info'; Code = 'first-wins'; Name = $name
            Message = "$name - first wins: $($paths -join ' > ')" }
    }
    return $findings
}

# --- probes -----------------------------------------------------------------

# The PATH value exactly as stored, %VARIABLES% unexpanded, with its registry
# kind. [Environment]::GetEnvironmentVariable would expand it and lose the
# kind, which is the very thing worth seeing. $null when it cannot be read,
# which is always the case off Windows.
function Get-RawPath {
    param([string]$Scope)
    try {
        if ($Scope -eq 'Machine') {
            $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment')
        } else {
            $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
        }
        if ($null -eq $key) { return $null }
        try {
            if ($key.GetValueNames() -notcontains 'Path') {
                return [pscustomobject]@{ Value = ''; Kind = 'None' }
            }
            $value = $key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            return [pscustomobject]@{ Value = [string]$value; Kind = [string]$key.GetValueKind('Path') }
        } finally {
            $key.Close()
        }
    } catch {
        Write-Verbose ("{0} PATH: {1}" -f $Scope, $_.Exception.Message)
        return $null
    }
}

# --- arguments --------------------------------------------------------------
# All of these answer before the preflight, and the consent gate before any
# registry access: refusing is the one answer that needs nothing else to be
# true, the same reasoning clean_disk_c.ps1 gives for its own gate.
if ($Scope -notin @('All', 'User', 'Machine')) {
    Write-Err "-Scope must be All, User or Machine; got: $Scope"
    exit 3
}
if ($Action -eq 'clean') {
    if ($PSBoundParameters.ContainsKey('Scope') -and $Scope -ne 'User') {
        Write-Err 'clean works on the user PATH only; the machine PATH is edited in System Properties, not here'
        exit 3
    }
    if (-not $DryRun -and -not $Yes) {
        Write-Err 'refusing to change PATH without -Yes; preview with -DryRun'
        exit 3
    }
}

$commandNames = @($Command | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($commandNames.Count -eq 0) {
    $commandNames = @('git', 'python', 'python3', 'pip', 'node', 'npm', 'docker', 'kubectl', 'terraform',
        'az', 'aws', 'gcloud', 'ssh', 'curl', 'find', 'sort')
}

# --- preflight -------------------------------------------------------------
# Mirrors status.ps1: wrong platform is 2. Windows PowerShell 5.1 does not
# define $IsWindows at all, hence the edition test.
if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    Write-Err 'this script targets Windows'
    exit 2
}

$exists = { param([string]$Folder) Test-Path -LiteralPath $Folder -PathType Container }
$expand = { param([string]$Text) [Environment]::ExpandEnvironmentVariables($Text) }

Write-Host ''
Write-Host "path_doctor: $Action" -ForegroundColor White

# --- clean ------------------------------------------------------------------
if ($Action -eq 'clean') {
    if ($DryRun) { Write-Host '--- DRY RUN: nothing will be written ---' -ForegroundColor Cyan }
    $userPath = Get-RawPath -Scope 'User'
    if ($null -eq $userPath) {
        Write-Err 'could not read the user PATH from the registry'
        exit 1
    }
    if ($userPath.Kind -eq 'None' -or -not $userPath.Value) {
        Write-Ok 'there is no user PATH; nothing to clean'
        exit 0
    }

    $result = Get-CleanedPath -Entries ($userPath.Value -split ';') -Exists $exists -Expand $expand -Kind $userPath.Kind
    $removals = @($result.Removed)
    if ($removals.Count -eq 0) {
        Write-Ok 'nothing to clean'
        exit 0
    }

    foreach ($removal in $removals) {
        $shownEntry = $removal.Entry
        if (-not $shownEntry) { $shownEntry = '(empty entry)' }
        if ($DryRun) {
            Write-Host ('WOULD remove {0} ({1})' -f $shownEntry, $removal.Reason) -ForegroundColor Cyan
        } else {
            Write-Host ('CLEAN remove {0} ({1})' -f $shownEntry, $removal.Reason) -ForegroundColor Green
        }
    }
    Write-Host ('user PATH: {0} characters before, {1} after' -f $userPath.Value.Length, $result.Value.Length)

    if ($DryRun) {
        Write-Host 'Dry run complete; no changes written.' -ForegroundColor Cyan
        exit 0
    }

    # 1. The backup, before anything is written. Both values and both kinds,
    #    so the machine PATH as it was is on record too.
    if (-not $BackupDir) {
        $profileDir = $env:USERPROFILE
        if (-not $profileDir) { $profileDir = $HOME }
        $BackupDir = Join-Path $profileDir 'path-backups'
    }
    $machinePath = Get-RawPath -Scope 'Machine'
    $backupFile = Join-Path $BackupDir ('path-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    try {
        if (-not (Test-Path -LiteralPath $BackupDir)) {
            New-Item -ItemType Directory -Path $BackupDir -Force -ErrorAction Stop | Out-Null
        }
        $lines = @(
            "# path_doctor.ps1 backup, $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
            "User.Kind=$($userPath.Kind)",
            "User.Path=$($userPath.Value)")
        if ($machinePath) {
            $lines += "Machine.Kind=$($machinePath.Kind)"
            $lines += "Machine.Path=$($machinePath.Value)"
        }
        [IO.File]::WriteAllText($backupFile, (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding -ArgumentList $false))
    } catch {
        Write-Host ('FAIL  backup to {0}: {1}' -f $backupFile, $_.Exception.Message) -ForegroundColor Red
        Write-Err 'nothing was written; the user PATH is unchanged'
        exit 1
    }
    Write-Info "backup written: $backupFile"

    # 2. The write, in the kind the value already had. A REG_EXPAND_SZ stays
    #    one, so %USERPROFILE%\bin keeps working.
    $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
    if ($userPath.Kind -eq 'String') { $kind = [Microsoft.Win32.RegistryValueKind]::String }
    try {
        $writable = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
        try {
            $writable.SetValue('Path', $result.Value, $kind)
        } finally {
            $writable.Close()
        }
    } catch {
        Write-Host ('FAIL  write the user PATH: {0}' -f $_.Exception.Message) -ForegroundColor Red
        Write-Err "the backup is $backupFile"
        exit 1
    }

    # 3. Read back. A write that did not land is a failure, not a success.
    $after = Get-RawPath -Scope 'User'
    if ($null -eq $after -or $after.Value -cne $result.Value) {
        Write-Host 'FAIL  the user PATH read back differs from what was written' -ForegroundColor Red
        Write-Err "restore it from $backupFile (see 'Roll back' in windows/setup/README.md)"
        exit 1
    }
    Write-Ok ('user PATH cleaned: {0} entr{1} removed, kind {2} kept' -f $removals.Count, $(if ($removals.Count -eq 1) { 'y' } else { 'ies' }), $after.Kind)
    Write-Info 'sign out and in, or restart Explorer, for new shells to see it; open shells keep the old value'
    Write-Info "to undo: see 'Roll back' in windows/setup/README.md, with $backupFile"
    exit 0
}

# --- report -----------------------------------------------------------------
$scopes = @('User', 'Machine')
if ($Scope -ne 'All') { $scopes = @($Scope) }
$values = @{}
foreach ($name in @('User', 'Machine')) { $values[$name] = Get-RawPath -Scope $name }

Write-Section 'entries'
foreach ($name in $scopes) {
    $value = $values[$name]
    if ($null -eq $value) {
        Write-Info "$name PATH: not readable"
        continue
    }
    if ($value.Kind -eq 'None') {
        Write-Info "$name PATH: not set"
        continue
    }
    $entries = @($value.Value -split ';')
    $expandedLength = ([Environment]::ExpandEnvironmentVariables($value.Value)).Length
    Write-Info ('{0} PATH ({1}): {2} entries, {3} characters stored, {4} expanded' -f $name, $value.Kind, $entries.Count, $value.Value.Length, $expandedLength)
    if (-not $script:QuietMode) {
        for ($i = 0; $i -lt $entries.Count; $i++) {
            Write-Host ('  {0,3}  {1}' -f ($i + 1), $entries[$i]) -ForegroundColor DarkGray
        }
    }
}

Write-Section 'findings'
$pathFindings = @()
foreach ($name in $scopes) {
    $value = $values[$name]
    if ($null -eq $value -or $value.Kind -eq 'None') { continue }
    $otherName = 'Machine'
    if ($name -eq 'Machine') { $otherName = 'User' }
    $otherEntries = @()
    # The cross-scope note is said once, from the user side.
    if ($name -eq 'User' -and $values[$otherName] -and $values[$otherName].Kind -ne 'None') {
        $otherEntries = @($values[$otherName].Value -split ';')
    }
    $pathFindings += @(Get-PathFinding -Entries @($value.Value -split ';') -Scope $name -Kind $value.Kind `
            -Exists $exists -Expand $expand -Length $value.Value.Length -OtherEntries $otherEntries)
}
foreach ($finding in $pathFindings) {
    switch ($finding.Level) {
        'fail' { $script:Warnings++; Write-Host "[FAIL] $($finding.Message)" -ForegroundColor Red }
        'warn' { Write-Warn $finding.Message }
        default { Write-Info $finding.Message }
    }
}
$cleanable = @($pathFindings | Where-Object { $_.Code -in 'empty-entry', 'duplicate', 'missing-dir' -and $_.Message -like 'User *' })
if ($cleanable.Count -gt 0) {
    Write-Info 'preview what clean would remove from the user PATH: .\path_doctor.ps1 clean -DryRun'
}
if (@($pathFindings | Where-Object { $_.Level -ne 'info' }).Count -eq 0) {
    Write-Ok 'no problems in the stored PATH values'
}

Write-Section 'shadowing'
$resolved = @{}
foreach ($name in $commandNames) {
    $hits = @(Get-Command $name -All -CommandType Application -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Source } | Select-Object -Unique)
    if ($hits.Count -gt 0) { $resolved[$name] = $hits }
}
$shadowFindings = @(Get-ShadowFinding -Resolved $resolved)
foreach ($finding in $shadowFindings) {
    if ($finding.Level -eq 'warn') { Write-Warn $finding.Message } else { Write-Info $finding.Message }
}
if (@($shadowFindings | Where-Object { $_.Level -eq 'warn' }).Count -eq 0) {
    Write-Ok ('no known trap among {0} command(s) checked' -f $commandNames.Count)
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
