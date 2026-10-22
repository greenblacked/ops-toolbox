<#
.SYNOPSIS
    Contract checks for the PowerShell scripts in windows/.

.DESCRIPTION
    Almost entirely static, and for a reason. clean_disk_c.ps1 calls
    [Security.Principal.WindowsIdentity]::GetCurrent() and Get-PSDrive -Name C
    at script scope, both of which throw on Linux the moment the file is
    dot-sourced - so its functions cannot be reached for unit testing without
    restructuring it into a module with a main guard, which would defeat the
    point of a script you copy to a machine and run.

    Most checks here therefore inspect the scripts without executing them.
    Get-Command and Get-Help both parse a .ps1 without running its body, which
    is what makes these checks possible on a Linux runner at all.

    The exceptions are the sections from 'a dry run writes nothing' onwards,
    which run scripts as child processes against a scratch HOME and TEMP. The
    first of them fails if the filesystem changed. Read what that proves where:
    on Windows it is the real thing, the whole dry-run path executed and checked
    against the disk. On Linux the scripts that can be run at all stop at their
    platform check, so it only proves they write nothing before deciding they
    are on the wrong machine - which is still the place a stray log file or
    scratch directory would appear. The template is the one subject that runs
    its dry run to completion anywhere.

    The consent and -Only sections at the end go further and strip the platform
    guard from a copy, so the body is reached on this OS too. The -Only checks
    run everywhere, because they run under -DryRun. The behavioural half of the
    consent checks runs only off Windows, and the comment there says why: it
    works by invoking these scripts WITHOUT -Yes, which on Windows would mean a
    regressed gate upgrading or emptying the machine running the suite.

    The sections after those reach the logic of the read-only reports
    without running them: Get-ScriptFunctionSource lifts one pure function out
    of a script through the parser, and the section calls it with fixtures. A
    script's body never runs that way, so the WindowsIdentity problem above
    does not arise.

    Linting is PSScriptAnalyzer's job and runs separately in CI. What is checked
    here is the contract PSScriptAnalyzer has no opinion about: that the
    comment-based help exists, that the parameter surface is what the docs
    claim, and that anything which changes a machine offers a way to preview it.

.EXAMPLE
    pwsh -File windows/tests/contract.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
$failures = 0

function Test-Ok   { param([string]$Message) Write-Host "[ ok ] $Message" }
function Test-Fail {
    param([string]$Message)
    Write-Host "[fail] $Message" -ForegroundColor Red
    $script:failures++
}
function Test-Skip { param([string]$Message) Write-Host "[skip] $Message" -ForegroundColor DarkGray }
function Write-Section { param([string]$Name) Write-Host ''; Write-Host "--- $Name ---" }

# templates/ is in scope as well as windows/. The templates exist so the
# conventions cannot drift away from them, which only works if the same checks
# run against them - new_script.ps1 was covered by repository-wide
# PSScriptAnalyzer in CI and by nothing that reads its help or its dry run.
$searchRoots = @('windows', 'templates')
$scripts = $searchRoots |
    ForEach-Object { Join-Path $repoRoot $_ } |
    Where-Object { Test-Path $_ } |
    ForEach-Object { Get-ChildItem -Path $_ -Filter '*.ps1' -Recurse -File } |
    Where-Object { $_.FullName -notmatch [regex]::Escape([IO.Path]::DirectorySeparatorChar + 'tests' + [IO.Path]::DirectorySeparatorChar) } |
    Sort-Object FullName

if (-not $scripts) {
    Write-Host "[fail] found no PowerShell scripts under $($searchRoots -join ', ')" -ForegroundColor Red
    exit 1
}

function Get-RelativePath {
    param([string]$Path)
    return $Path.Substring($repoRoot.Length + 1) -replace '\\', '/'
}

# --------------------------------------------------------------------------
Write-Section 'parses'
# The bash suites run `bash -n` over every script. Nothing did the equivalent
# for PowerShell before this.
foreach ($s in $scripts) {
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($s.FullName, [ref]$null, [ref]$parseErrors) | Out-Null
    if ($parseErrors) {
        Test-Fail ('{0}: {1}' -f (Get-RelativePath $s.FullName), ($parseErrors[0].Message))
    } else {
        Test-Ok (Get-RelativePath $s.FullName)
    }
}

# --------------------------------------------------------------------------
Write-Section 'comment-based help'
# The PowerShell equivalent of the --help contract the bash scripts are held to.
foreach ($s in $scripts) {
    $rel = Get-RelativePath $s.FullName
    try {
        $h = Get-Help $s.FullName -ErrorAction Stop
    } catch {
        Test-Fail "$rel : Get-Help failed - $($_.Exception.Message)"
        continue
    }

    if ([string]::IsNullOrWhiteSpace($h.Synopsis)) {
        Test-Fail "$rel : no .SYNOPSIS"
        continue
    }
    $description = ($h.Description | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($description)) {
        Test-Fail "$rel : no .DESCRIPTION"
        continue
    }
    if (@($h.Examples.Example).Count -lt 1) {
        Test-Fail "$rel : no .EXAMPLE"
        continue
    }
    Test-Ok "$rel help (synopsis, description, $(@($h.Examples.Example).Count) example block)"
}

# --------------------------------------------------------------------------
Write-Section 'preview before changing a machine'
# Every script that can change the machine must offer a way to see what it
# would do first: either an explicit -DryRun switch, or a default action that
# is read-only. wsl_manage.ps1 takes the second route - it defaults to 'list'.
foreach ($s in $scripts) {
    $rel = Get-RelativePath $s.FullName
    $cmd = Get-Command $s.FullName
    $names = @($cmd.Parameters.Keys)

    if ($names -contains 'DryRun') {
        Test-Ok "$rel has -DryRun"
        continue
    }

    $action = $cmd.Parameters['Action']
    if ($action) {
        $default = ($action.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] })
        if ($default) {
            Test-Ok "$rel has no -DryRun but takes an -Action with a validated set (read-only default)"
            continue
        }
    }
    Test-Fail "$rel has neither -DryRun nor a validated -Action; it cannot be previewed"
}

# --------------------------------------------------------------------------
Write-Section 'documented flags exist'
# This repository has already shipped documentation describing a workflow that
# did not exist. Flags are the cheapest form of that mistake to catch: pull
# every -Flag out of the fenced examples in the READMEs and require the script
# to actually declare it.
$paramCache = @{}
foreach ($s in $scripts) {
    $paramCache[$s.Name.ToLowerInvariant()] = @(Get-Command $s.FullName).Parameters.Keys
}

$readmes = Get-ChildItem -Path $repoRoot -Filter 'README.md' -Recurse -File |
    Where-Object { $_.FullName -notmatch '(\\|/)\.git(\\|/)' }

$checkedFlags = 0
foreach ($readme in $readmes) {
    foreach ($line in (Get-Content -Path $readme.FullName)) {
        # Only lines that actually invoke one of our scripts.
        $m = [regex]::Match($line, '([A-Za-z0-9_]+\.ps1)(?<rest>.*)$')
        if (-not $m.Success) { continue }

        $scriptName = $m.Groups[1].Value.ToLowerInvariant()
        if (-not $paramCache.ContainsKey($scriptName)) { continue }

        # Single-dash tokens only. Native tools invoked in the same examples
        # (wsl --export, winget --import-file) use double dashes and are not
        # ours to validate.
        foreach ($flag in [regex]::Matches($m.Groups['rest'].Value, '(?<![-\w])-([A-Za-z][A-Za-z0-9]+)')) {
            $name = $flag.Groups[1].Value
            $checkedFlags++
            if ($paramCache[$scriptName] -notcontains $name) {
                Test-Fail ('{0} documents -{1} for {2}, which does not declare it' -f (Get-RelativePath $readme.FullName), $name, $scriptName)
            }
        }
    }
}
Test-Ok "checked $checkedFlags documented flag(s) against their parameter blocks"

# --------------------------------------------------------------------------
Write-Section 'feature surfaces'
$expectedParameters = @{
    'clean_disk_c.ps1'      = @('Scope', 'IncludeCrashDumps', 'IncludeLogs', 'IncludeComponentStore')
    'stay_fresh.ps1'        = @('Only')
    'status.ps1'            = @('ListSections', 'Only')
    'workstation_doctor.ps1'= @('MinFreePercent', 'Only', 'ListSections', 'MaxUptimeDays', 'MaxPatchAgeDays')
    'net_doctor.ps1'        = @('Probe', 'Port', 'Only', 'ListSections', 'SkipListen', 'Quiet', 'HostsFile')
    'ssh_client_doctor.ps1' = @('SshDir', 'FailOn', 'Quiet')
    'disk_usage.ps1'        = @('Path', 'Depth', 'Top', 'MinSizeMB', 'IncludeDocker', 'Quiet')
    'dev_env_doctor.ps1'    = @('Only', 'ListSections', 'CheckTime', 'MaxSkewSeconds', 'Quiet')
    'path_doctor.ps1'       = @('DryRun', 'Yes', 'Scope', 'Command', 'BackupDir', 'Quiet')
    'hardening_audit.ps1'   = @('Only', 'ListGroups', 'FailOn', 'Quiet')
    'tls_expiry.ps1'        = @('File', 'HostName', 'Store', 'Days', 'FailOn', 'Quiet')
    'new_script.ps1'        = @('PassThru')
}
foreach ($name in $expectedParameters.Keys) {
    foreach ($parameter in $expectedParameters[$name]) {
        if ($paramCache[$name] -contains $parameter) {
            Test-Ok "$name declares -$parameter"
        } else {
            Test-Fail "$name is missing -$parameter"
        }
    }
}

$templateText = Get-Content -Raw (Join-Path $repoRoot 'templates/new_script.ps1')
if ($templateText -match 'Remove-Item[^\r\n]+-ErrorAction Stop' -and
    $templateText -match "'Failed'" -and
    $templateText -match 'FailureCount') {
    Test-Ok 'new_script.ps1 does not suppress deletion failures in structured output'
} else {
    Test-Fail 'new_script.ps1 must surface deletion failures and return Failed status'
}

$wingetAction = (Get-Command (Join-Path $repoRoot 'windows/setup/winget_bootstrap.ps1')).Parameters['Action']
$wingetValues = @($wingetAction.Attributes |
    Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
    ForEach-Object { $_.ValidValues })
if ($wingetValues -contains 'list') {
    Test-Ok 'winget_bootstrap.ps1 exposes read-only list'
} else {
    Test-Fail 'winget_bootstrap.ps1 is missing list action'
}

$wslAction = (Get-Command (Join-Path $repoRoot 'windows/wsl/wsl_manage.ps1')).Parameters['Action']
$wslValues = @($wslAction.Attributes |
    Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
    ForEach-Object { $_.ValidValues })
if ($wslValues -contains 'verify-backup') {
    Test-Ok 'wsl_manage.ps1 exposes verify-backup'
} else {
    Test-Fail 'wsl_manage.ps1 is missing verify-backup action'
}

# --------------------------------------------------------------------------
Write-Section 'duplicated blocks keep their contract'
# Format-Size is copied rather than shared, for the reason CONTRIBUTING.md
# gives. Assert the copies agree on the thresholds that matter.
$withFormatSize = $scripts | Where-Object { (Get-Content -Path $_.FullName -Raw) -match 'function Format-Size' }
if (@($withFormatSize).Count -lt 2) {
    Test-Ok 'fewer than two copies of Format-Size; nothing to compare'
} else {
    $drift = 0
    foreach ($s in $withFormatSize) {
        $body = (Get-Content -Path $s.FullName -Raw)
        foreach ($unit in @('1GB', '1MB')) {
            if ($body -notmatch [regex]::Escape("-ge $unit")) {
                Test-Fail ('{0}: Format-Size does not handle {1}' -f (Get-RelativePath $s.FullName), $unit)
                $drift++
            }
        }
    }
    if ($drift -eq 0) {
        Test-Ok "Format-Size consistent across $(@($withFormatSize).Count) copies"
    }
}

# --------------------------------------------------------------------------
Write-Section 'a dry run writes nothing'
# The Bash side asserts this against the filesystem in
# test-env/static/check_conventions.sh, and the reasoning there applies here
# word for word: a suite that greps a script's own output for "nothing will be
# changed" is reading the claim rather than checking it. Five Bash scripts
# passed that way for months while writing a log file on every preview.
#
# Each script runs as a child process with HOME and TEMP pointed at fresh
# scratch directories, which are compared before and after. Anything created,
# removed or rewritten is a failure.
$onWindows = $IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop'

# Scripts that cannot be executed on the current OS at all, with the reason.
# Named individually rather than skipped by a rule, so a script that acquires a
# platform guard tomorrow starts being checked without anyone editing this.
function Get-SkipReason {
    param([IO.FileInfo]$Script)
    if (-not $onWindows -and $Script.Name -eq 'clean_disk_c.ps1') {
        return 'reads WindowsIdentity and Get-PSDrive C at script scope, which throw on this OS before -DryRun is looked at'
    }
    return $null
}

# Scripts needing more than -DryRun to reach the path that would write.
function Get-DryRunArgument {
    param([IO.FileInfo]$Script)
    if ($Script.Name -eq 'winget_bootstrap.ps1') {
        # The action is mandatory, and import is the verb that installs.
        # Pointed at the committed example so it has a real file to read
        # instead of exiting 1 for a missing one.
        return @('import', '-DryRun', '-File',
            (Join-Path $repoRoot (Join-Path 'windows' (Join-Path 'setup' 'winget-packages.example.json'))))
    }
    if ($Script.Name -eq 'choco_bootstrap.ps1') {
        # Same shape as winget_bootstrap.ps1: the action is mandatory, install
        # is the verb that writes, and it needs a real packages.config to read.
        # Without this the script exits 3 at the help-on-no-action branch, and
        # "wrote nothing" would be true of a run that never reached the code
        # that could write.
        return @('install', '-DryRun', '-File',
            (Join-Path $repoRoot (Join-Path 'windows' (Join-Path 'setup' 'choco-packages.example.config'))))
    }
    if ($Script.Name -eq 'winget_configure.ps1') {
        # apply is the only verb that writes, and the file it reads has to
        # exist or the script exits 1 before reaching the preview path.
        return @('apply', '-DryRun', '-File',
            (Join-Path $repoRoot (Join-Path 'windows' (Join-Path 'setup' 'configuration.winget'))))
    }
    if ($Script.Name -eq 'clean_disk_c.ps1') {
        # The three opt-ins whose previews must not start DISM or delete a
        # dump. Skipped off Windows by Get-SkipReason, so this only matters on
        # windows-2025, where it runs the whole preview against the real disk.
        return @('-DryRun', '-IncludeCrashDumps', '-IncludeLogs', '-IncludeComponentStore')
    }
    if ($Script.Name -eq 'path_doctor.ps1') {
        # The default action is the read-only report; clean is the verb that
        # writes, and its preview is the path this check has to reach. On
        # Windows that reads the real user PATH and must leave no backup
        # folder behind in the scratch profile.
        return @('clean', '-DryRun')
    }
    return @('-DryRun')
}

# Written by the PowerShell host itself when it starts under a redirected home
# - a telemetry id, a startup profile, an empty Modules directory, the module
# analysis cache on Windows - not by the script under test storing anything.
# Excluded for the same reason check_conventions.sh excludes Go's telemetry
# counters, and reported when it fires, because a silent exclusion is how
# coverage rots.
$hostArtifact = '(?i)[\\/](\.cache|\.local|\.dotnet)([\\/]|$)' +
    '|ModuleAnalysisCache|[\\/]Microsoft[\\/](Windows[\\/])?PowerShell([\\/]|$)' +
    '|[\\/]AppData([\\/]Local([\\/]Microsoft)?)?$'

function Get-TreeSnapshot {
    param([string[]]$Path)
    # Name, size and mtime, so a rewritten file is caught as well as a new one.
    Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue |
        ForEach-Object { '{0}|{1}|{2}' -f $_.FullName, $_.Length, $_.LastWriteTimeUtc.Ticks } |
        Sort-Object
}

function Test-HostArtifact {
    param([string]$Entry)
    # Match the path, not the size and mtime appended after it.
    return ($Entry -split '\|')[0] -match $hostArtifact
}

# The verdict for one dry run, lifted out of the loop below into a function so
# that it can be exercised directly. This file's own verdict was otherwise the
# one piece of logic in here that nothing checked, and it is the piece that
# decides whether anything else gets reported at all.
#
# Exit 3 is a failure, not a pass. It is this repository's usage error, so a
# run that ends in it was rejected during argument parsing and stopped before
# the code that could write was ever reached: "wrote nothing" is true and
# meaningless. It was accepted here for a while, which meant Get-DryRunArgument
# going stale - renaming the 'import', 'install' or 'apply' verb it hardcodes
# would do it - silently retired the dry-run check for that script while the
# suite kept printing '[ ok ] ... wrote nothing (exit 3)'.
# test-env/static/check_conventions.sh has always called exit 3 a gap in its
# argument table rather than a pass; this is the same rule, said the same way.
#
# A write outranks the exit code: a preview that wrote is a failure whatever it
# exited with, including 3.
function Get-DryRunVerdict {
    param(
        [int]$ExitCode,
        [bool]$WroteToDisk
    )

    if ($WroteToDisk) { return 'wrote' }
    if ($ExitCode -eq 3) { return 'usage' }
    # 1 is "the work ran and some of it did not succeed", which a preview has
    # no business reporting. Catching it here is how the wsl_manage.ps1
    # preflight was found returning 1 where it documents 2.
    if ($ExitCode -notin 0, 2, 4) { return 'failed' }
    return 'ok'
}

# The host running this suite, so the children are the same PowerShell.
$pwshExe = (Get-Process -Id $PID).Path
$dryRunScripts = @($scripts | Where-Object {
    @((Get-Command $_.FullName).Parameters.Keys) -contains 'DryRun'
})
$dryChecked = 0

foreach ($s in $dryRunScripts) {
    $rel = Get-RelativePath $s.FullName

    $skip = Get-SkipReason $s
    if ($skip) {
        Test-Skip "$rel : $skip"
        continue
    }

    $scratch = Join-Path ([IO.Path]::GetTempPath()) ('wincontract_' + [Guid]::NewGuid().ToString('N'))
    $scratchHome = Join-Path $scratch 'home'
    $scratchTemp = Join-Path $scratch 'temp'
    New-Item -ItemType Directory -Path $scratchHome, $scratchTemp -Force | Out-Null

    $redirected = @{
        TEMP         = $scratchTemp
        TMP          = $scratchTemp
        TMPDIR       = $scratchTemp
        HOME         = $scratchHome
        USERPROFILE  = $scratchHome
        LOCALAPPDATA = (Join-Path $scratchHome 'AppData/Local')
        APPDATA      = (Join-Path $scratchHome 'AppData/Roaming')
    }
    $saved = @{}
    foreach ($name in $redirected.Keys) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name)
    }

    # Re-wrapped: a function returning a one-element array hands back the bare
    # element, and splatting a bare string passes it a character at a time.
    $arguments = @(Get-DryRunArgument $s)
    $before = @(Get-TreeSnapshot @($scratchHome, $scratchTemp))
    try {
        foreach ($name in $redirected.Keys) {
            [Environment]::SetEnvironmentVariable($name, $redirected[$name])
        }
        $output = & $pwshExe -NoProfile -File $s.FullName @arguments 2>&1 | Out-String
        $rc = $LASTEXITCODE
    } finally {
        foreach ($name in $saved.Keys) {
            [Environment]::SetEnvironmentVariable($name, $saved[$name])
        }
    }
    $after = @(Get-TreeSnapshot @($scratchHome, $scratchTemp))

    $ignored = @($after | Where-Object { Test-HostArtifact $_ }).Count
    $before = @($before | Where-Object { -not (Test-HostArtifact $_) })
    $after = @($after | Where-Object { -not (Test-HostArtifact $_) })
    if ($ignored -gt 0) {
        Write-Host ("       (ignored $ignored PowerShell host path(s) under $rel)") -ForegroundColor DarkGray
    }

    $dryChecked++
    $written = @(Compare-Object -ReferenceObject $before -DifferenceObject $after)
    switch (Get-DryRunVerdict -ExitCode $rc -WroteToDisk ($written.Count -gt 0)) {
        'wrote' {
            Test-Fail "$rel $($arguments -join ' ') changed the filesystem:"
            foreach ($line in $written) {
                Write-Host ('       {0} {1}' -f $line.SideIndicator, $line.InputObject) -ForegroundColor Red
            }
        }
        'usage' {
            Test-Fail "$rel exited 3 (usage) under '$($arguments -join ' ')' - its dry run was never exercised"
            Write-Host '       add an entry to Get-DryRunArgument so this script reaches its main path' -ForegroundColor Red
            foreach ($line in ($output -split "`n" | Select-Object -First 5)) {
                Write-Host "       $line" -ForegroundColor Red
            }
        }
        'failed' {
            Test-Fail "$rel $($arguments -join ' ') wrote nothing but exited $rc; a dry run should not report a generic failure"
            foreach ($line in ($output -split "`n" | Select-Object -First 5)) {
                Write-Host "       $line" -ForegroundColor Red
            }
        }
        default {
            Test-Ok "$rel $($arguments -join ' ') wrote nothing (exit $rc)"
        }
    }

    Remove-Item -Path $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

if ($dryChecked -eq 0) {
    Test-Fail 'no -DryRun script could be executed here - this check has stopped checking'
}

# --------------------------------------------------------------------------
Write-Section 'the dry-run verdict itself'
# Testing the suite's own verdict is the one check here that could easily be
# written as a tautology - grep this file for the number 3 and declare victory.
# It is not written that way. Get-DryRunVerdict above is the single place the
# loop gets its answer from, so these cases exercise the same code that judged
# every script a moment ago; the only link left unasserted is the one line that
# calls it, which is visible from the table below.
#
# What cannot be faked here is a real script that exits 3: manufacturing one
# would mean shipping a broken Get-DryRunArgument entry, and a check that has
# to break the thing it checks is worse than the gap it closes. The honest
# version is this: the verdict is a function, the function is tested, the loop
# has no second opinion.
$verdictCases = @(
    @{ ExitCode = 3; Wrote = $false; Expect = 'usage'
       Why = 'exit 3 is a usage error: the run stopped at argument parsing and never reached the code that writes' }
    @{ ExitCode = 0; Wrote = $false; Expect = 'ok'
       Why = 'a clean preview' }
    @{ ExitCode = 2; Wrote = $false; Expect = 'ok'
       Why = 'a preflight that declined to run is allowed to answer a preview' }
    @{ ExitCode = 4; Wrote = $false; Expect = 'ok'
       Why = '4 is the documented "found something to report" code' }
    @{ ExitCode = 1; Wrote = $false; Expect = 'failed'
       Why = 'a preview has no business reporting a generic failure' }
    @{ ExitCode = 0; Wrote = $true;  Expect = 'wrote'
       Why = 'a preview that wrote is a failure however it exited' }
    @{ ExitCode = 3; Wrote = $true;  Expect = 'wrote'
       Why = 'a write outranks the usage error, so the report names the writing' }
)
foreach ($case in $verdictCases) {
    $got = Get-DryRunVerdict -ExitCode $case.ExitCode -WroteToDisk $case.Wrote
    $label = 'exit {0}, wrote {1} -> {2}' -f $case.ExitCode, $case.Wrote, $case.Expect
    if ($got -eq $case.Expect) {
        Test-Ok "verdict: $label ($($case.Why))"
    } else {
        Test-Fail "verdict: $label but Get-DryRunVerdict said '$got' - $($case.Why)"
    }
}
if (@($verdictCases | Where-Object { $_.Expect -eq 'usage' }).Count -eq 0) {
    # The floor, in the shape the rest of this file uses it: a table that has
    # lost its exit-3 case is a table that has stopped asserting the thing this
    # section exists for.
    Test-Fail 'no exit-3 case is left in the verdict table - this check has stopped checking'
}

# --------------------------------------------------------------------------
Write-Section 'ASCII source, no BOM'
# PSScriptAnalyzer catches this as PSUseBOMForUnicodeEncodedFile, but it runs
# only in CI's Lint job, which run-tests.sh does not invoke. A single em dash
# pasted into wsl_manage.ps1 turned master red that way. The check costs
# milliseconds and belongs where the author will actually see it.
foreach ($s in $scripts) {
    $rel = Get-RelativePath $s.FullName
    $bytes = [IO.File]::ReadAllBytes($s.FullName)

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        Test-Fail "$rel starts with a UTF-8 BOM; .gitattributes pins these files to LF without one"
        continue
    }

    # Report the first offender with its line and character, so the fix does
    # not start with a hunt through the file.
    $bad = $null
    $line = 1
    foreach ($b in $bytes) {
        if ($b -eq 0x0A) { $line++; continue }
        if ($b -gt 0x7F) { $bad = $line; break }
    }
    if ($bad) {
        Test-Fail "$rel has a non-ASCII byte on line $bad (an em dash or smart quote, usually)"
    } else {
        Test-Ok "$rel is ASCII with no BOM"
    }
}

# --------------------------------------------------------------------------
Write-Section 'a preview does not invoke its packaging tool'
# The section above proves a dry run writes nothing. On Windows that is the
# real thing. On Linux every one of these scripts exits at its $IsWindows
# guard first, so "wrote nothing" is true of a run that never reached the
# preview - and choco_bootstrap.ps1 install -DryRun passed here for a whole
# commit while calling `choco list` on Windows, which creates %TEMP%\chocolatey
# and touches %APPDATA%.
#
# This closes that gap without a Windows machine. The platform guard is removed
# from a copy, the packaging tools are replaced on PATH by shims that record
# being called, and the preview is required not to call them. It says nothing
# about what the tools would do; it says the preview does not reach them, which
# is the property that was actually broken.
# Hoisted out of the section below because the consent checks at the end of
# this file strip the same guard from the same scripts; two copies of it would
# be two things to update when the preflight is reworded, and the second one
# would be found by someone reading a confusing failure.
$platformGuard = @'
if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    Write-Err 'this script targets Windows'
    exit 2
}
'@ -replace "`r`n", "`n"

# Writes a copy of $Script with the platform guard removed, so its body can be
# reached on a machine the guard would turn away, and returns the copy's path.
# $null when the guard is not in the file verbatim: every caller reports that
# loudly rather than carrying on, because a harness that quietly stops
# transforming is a harness that quietly stops checking.
function Copy-UnguardedScript {
    param(
        [IO.FileInfo]$Script,
        [string]$Directory
    )

    $body = (Get-Content -Path $Script.FullName -Raw) -replace "`r`n", "`n"
    if ($body -notmatch [regex]::Escape($platformGuard)) { return $null }

    $copy = Join-Path $Directory $Script.Name
    Set-Content -Path $copy -Value ($body -replace [regex]::Escape($platformGuard), '# platform guard removed by contract.ps1') -NoNewline
    return $copy
}

# Runs one script as a child process with HOME and TEMP pointed at a throwaway
# directory, optionally with $PathPrefix ahead of PATH so a shim stands in for
# a tool, and hands back what it printed and what it exited with. The sections
# below that run a script rather than read it all need the same isolation: the
# whole point of running these is that the property under test might be broken,
# and a broken one must not be able to reach the real home directory.
function Invoke-InScratch {
    param(
        [string]$Path,
        [string[]]$Arguments = @(),
        [string]$PathPrefix
    )

    $box = Join-Path ([IO.Path]::GetTempPath()) ('winscratch_' + [Guid]::NewGuid().ToString('N'))
    $boxHome = Join-Path $box 'home'
    $boxTemp = Join-Path $box 'temp'
    New-Item -ItemType Directory -Path $boxHome, $boxTemp -Force | Out-Null

    $redirect = @{
        TEMP         = $boxTemp
        TMP          = $boxTemp
        TMPDIR       = $boxTemp
        HOME         = $boxHome
        USERPROFILE  = $boxHome
        LOCALAPPDATA = (Join-Path $boxHome 'AppData/Local')
        APPDATA      = (Join-Path $boxHome 'AppData/Roaming')
    }
    $keep = @{}
    foreach ($key in $redirect.Keys) { $keep[$key] = [Environment]::GetEnvironmentVariable($key) }
    $keepPath = $env:PATH
    try {
        foreach ($key in $redirect.Keys) { [Environment]::SetEnvironmentVariable($key, $redirect[$key]) }
        if ($PathPrefix) { $env:PATH = $PathPrefix + [IO.Path]::PathSeparator + $keepPath }
        $text = & $pwshExe -NoProfile -File $Path @Arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally {
        foreach ($key in $keep.Keys) { [Environment]::SetEnvironmentVariable($key, $keep[$key]) }
        $env:PATH = $keepPath
    }
    Remove-Item -Path $box -Recurse -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ ExitCode = $code; Output = $text }
}

if ($onWindows) {
    Test-Skip 'the filesystem check above covers this natively on Windows'
} else {
    # Only scripts that shell out to a packaging tool are in scope.
    $tools = @{
        'winget_bootstrap.ps1' = 'winget'
        'winget_configure.ps1' = 'winget'
        'choco_bootstrap.ps1'  = 'choco'
        'stay_fresh.ps1'       = 'winget'
    }

    $previewChecked = 0
    foreach ($s in $dryRunScripts) {
        if (-not $tools.ContainsKey($s.Name)) { continue }
        $rel = Get-RelativePath $s.FullName

        $sandbox = Join-Path ([IO.Path]::GetTempPath()) ('winpreview_' + [Guid]::NewGuid().ToString('N'))
        $binDir = Join-Path $sandbox 'bin'
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
        $marker = Join-Path $sandbox 'invoked.log'
        $copy = Copy-UnguardedScript -Script $s -Directory $sandbox
        if (-not $copy) {
            # Loud, not silent. A harness that quietly stops transforming is a
            # harness that quietly stops checking - which is how the first
            # version of this idea "passed" a file that still had the bug.
            Test-Fail "$rel : platform guard not found verbatim, so this check could not run; update the guard text in contract.ps1"
            Remove-Item -Path $sandbox -Recurse -Force -ErrorAction SilentlyContinue
            continue
        }

        foreach ($tool in @('winget.exe', 'choco.exe')) {
            $shim = Join-Path $binDir $tool
            Set-Content -Path $shim -Value "#!/bin/sh`necho `"`$0 `$*`" >> '$marker'`nexit 0`n" -NoNewline
            & chmod +x $shim
        }

        $savedPath = $env:PATH
        try {
            $env:PATH = $binDir + [IO.Path]::PathSeparator + $savedPath
            & $pwshExe -NoProfile -File $copy @(Get-DryRunArgument $s) *> $null
        } finally {
            $env:PATH = $savedPath
        }

        $previewChecked++
        if (Test-Path $marker) {
            Test-Fail "$rel : its preview invoked $($tools[$s.Name]); even read-only calls create state under TEMP and LOCALAPPDATA"
            foreach ($call in (Get-Content $marker | Select-Object -First 3)) {
                Write-Host "       $call" -ForegroundColor Red
            }
        } else {
            Test-Ok "$rel preview never invoked $($tools[$s.Name])"
        }
        Remove-Item -Path $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($previewChecked -eq 0) {
        Test-Fail 'no packaging-tool preview was checked - this check has stopped checking'
    }
}

# --------------------------------------------------------------------------
Write-Section 'changing the machine needs consent'
# linux/disk_cleanup.sh refuses to delete without --yes, and its header calls
# that "the same gate install_devtools.sh uses for anything that changes the
# machine". linux/stay_fresh.sh skips package upgrades without it. The Windows
# counterparts had neither: a bare .\stay_fresh.ps1 went straight to
# 'winget upgrade --all --include-unknown --accept-package-agreements
# --disable-interactivity', and a bare .\clean_disk_c.ps1 deleted.
#
# The root README presents the two families as counterparts, which is what made
# that asymmetry dangerous rather than merely inconsistent: the habit learned on
# the Bash side is "just run it, it will tell me what it wants", and on Windows
# that habit upgraded or deleted for real, the first time, with no preview.
# These checks exist so the gate cannot quietly go away again - a parameter
# nothing asserts is a parameter somebody eventually removes as unused.
foreach ($name in @('stay_fresh.ps1', 'clean_disk_c.ps1', 'path_doctor.ps1')) {
    if ($paramCache[$name] -contains 'Yes') {
        Test-Ok "$name declares -Yes"
    } else {
        Test-Fail "$name is missing -Yes; its Bash counterpart will not change a machine without --yes and this one would"
    }
}

if ($onWindows) {
    Test-Skip 'the behavioural half of this check runs only off Windows: it proves the gate by invoking these scripts WITHOUT -Yes, and on Windows a gate that had regressed would upgrade or empty the machine running the suite'
} else {
    # Safe to run here for a reason worth stating. clean_disk_c.ps1 without a
    # gate reaches WindowsIdentity and Get-PSDrive C, which throw on this OS
    # before anything is deleted; stay_fresh.ps1 only reaches winget through a
    # shim on a PATH this block controls. Neither can touch the real machine
    # even when the property under test is broken, which is the only reason
    # testing a consent gate by withholding consent is defensible at all.
    $consentChecked = 0

    # --- clean_disk_c.ps1: refuse outright, the way disk_cleanup.sh does -----
    $cleanScript = $scripts | Where-Object { $_.Name -eq 'clean_disk_c.ps1' } | Select-Object -First 1
    if (-not $cleanScript) {
        Test-Fail 'clean_disk_c.ps1 was not found among the scripts - this check has stopped checking'
    } else {
        $bare = Invoke-InScratch -Path $cleanScript.FullName
        $consentChecked++
        if ($bare.ExitCode -eq 3 -and $bare.Output -match '-Yes' -and $bare.Output -match '-DryRun') {
            Test-Ok 'clean_disk_c.ps1 with no arguments refuses to delete and exits 3, naming -Yes and -DryRun'
        } else {
            Test-Fail "clean_disk_c.ps1 with no arguments must refuse, exit 3 and name -Yes and -DryRun; it exited $($bare.ExitCode)"
            foreach ($line in ($bare.Output -split "`n" | Select-Object -First 5)) {
                Write-Host "       $line" -ForegroundColor Red
            }
        }
    }

    # --- stay_fresh.ps1: skip the upgrades, the way stay_fresh.sh does -------
    # Two runs, because one proves nothing on its own. Without -Yes the shim
    # must not be called; with -Yes it must be. Drop the second and the check
    # passes just as happily against a script that stopped calling winget at
    # all - which is a regression, not a fix, and exactly the sort of thing a
    # one-sided assertion waves through.
    $freshScript = $scripts | Where-Object { $_.Name -eq 'stay_fresh.ps1' } | Select-Object -First 1
    if (-not $freshScript) {
        Test-Fail 'stay_fresh.ps1 was not found among the scripts - this check has stopped checking'
    } else {
        $sandbox = Join-Path ([IO.Path]::GetTempPath()) ('winconsent_' + [Guid]::NewGuid().ToString('N'))
        $binDir = Join-Path $sandbox 'bin'
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
        $copy = Copy-UnguardedScript -Script $freshScript -Directory $sandbox

        if (-not $copy) {
            Test-Fail 'stay_fresh.ps1 : platform guard not found verbatim, so the consent check could not run; update the guard text in contract.ps1'
        } else {
            foreach ($pass in @(
                @{ Arguments = @();        Expect = $false; Label = 'with no arguments does not upgrade' }
                @{ Arguments = @('-Yes'); Expect = $true;  Label = 'with -Yes does upgrade' }
            )) {
                $marker = Join-Path $sandbox 'invoked.log'
                Remove-Item -Path $marker -Force -ErrorAction SilentlyContinue
                $shim = Join-Path $binDir 'winget.exe'
                Set-Content -Path $shim -Value "#!/bin/sh`necho `"`$0 `$*`" >> '$marker'`nexit 0`n" -NoNewline
                & chmod +x $shim

                $run = Invoke-InScratch -Path $copy -Arguments $pass.Arguments -PathPrefix $binDir
                $invoked = Test-Path $marker
                $consentChecked++

                if ($invoked -eq $pass.Expect) {
                    Test-Ok "stay_fresh.ps1 $($pass.Label)"
                } elseif ($pass.Expect) {
                    Test-Fail "stay_fresh.ps1 $($pass.Label): -Yes was given and winget was still never invoked, so the gate above is not what stops the upgrade"
                    foreach ($line in ($run.Output -split "`n" | Select-Object -First 5)) {
                        Write-Host "       $line" -ForegroundColor Red
                    }
                } else {
                    Test-Fail 'stay_fresh.ps1 with no arguments invoked winget; upgrades must wait for -Yes, as linux/stay_fresh.sh waits for --yes'
                    foreach ($call in (Get-Content $marker | Select-Object -First 3)) {
                        Write-Host "       $call" -ForegroundColor Red
                    }
                }

                # The refusal has to say so. A gate that silently drops the
                # step reads, from the output, exactly like a machine that had
                # nothing to upgrade.
                if (-not $pass.Expect) {
                    if ($run.Output -match '-Yes') {
                        Test-Ok 'stay_fresh.ps1 says why it skipped the upgrades, and names -Yes'
                    } else {
                        Test-Fail 'stay_fresh.ps1 skipped the upgrades without naming -Yes; a silent skip reads like a machine with nothing to do'
                    }
                    $consentChecked++
                }
            }
        }
        Remove-Item -Path $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($consentChecked -eq 0) {
        Test-Fail 'no consent gate was exercised - this check has stopped checking'
    }
}

# --------------------------------------------------------------------------
Write-Section '-Only takes a list of steps'
# linux/stay_fresh.sh --only takes a comma-separated subset. This took exactly
# one name, as a [string] behind a ValidateSet, so '-Only Winget,Wsl' - the
# obvious thing to type, and the thing the Bash sibling accepts - died during
# parameter binding with a message about the set of valid steps, which reads as
# though the step names were wrong rather than the type.
#
# Runs under -DryRun, so it is safe on Windows as well, and with the platform
# guard stripped so the sections are actually reached off Windows. What is
# asserted is which sections ran, not that binding succeeded: binding succeeds
# just as well for a script that quietly ignores every name after the first.
$onlyScript = $scripts | Where-Object { $_.Name -eq 'stay_fresh.ps1' } | Select-Object -First 1
if (-not $onlyScript) {
    Test-Fail 'stay_fresh.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $onlyBox = Join-Path ([IO.Path]::GetTempPath()) ('winonly_' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $onlyBox -Force | Out-Null
    $onlyCopy = Copy-UnguardedScript -Script $onlyScript -Directory $onlyBox

    if (-not $onlyCopy) {
        Test-Fail 'stay_fresh.ps1 : platform guard not found verbatim, so the -Only check could not run; update the guard text in contract.ps1'
    } else {
        $onlyCases = @(
            @{ Arguments = @('-DryRun', '-Only', 'Winget,Wsl'); Code = 0
               Ran = @('== winget ==', '== wsl =='); Skipped = @('== store ==', '== report ==')
               Label = "-Only Winget,Wsl runs both named steps and nothing else" }
            @{ Arguments = @('-DryRun', '-Only', 'Report'); Code = 0
               Ran = @('== report =='); Skipped = @('== winget ==', '== wsl ==')
               Label = '-Only Report still selects a single step' }
            @{ Arguments = @('-DryRun'); Code = 0
               Ran = @('== winget ==', '== wsl ==', '== store ==', '== report ==')
               Skipped = @()
               Label = 'the default is still every step' }
        )
        foreach ($case in $onlyCases) {
            $run = Invoke-InScratch -Path $onlyCopy -Arguments $case.Arguments
            $missing = @($case.Ran | Where-Object { $run.Output -notlike "*$_*" })
            $extra = @($case.Skipped | Where-Object { $run.Output -like "*$_*" })

            if ($run.ExitCode -eq $case.Code -and -not $missing -and -not $extra) {
                Test-Ok "stay_fresh.ps1 $($case.Label)"
            } else {
                Test-Fail ("stay_fresh.ps1 {0}: exited {1}, missing [{2}], unexpected [{3}]" -f
                    $case.Label, $run.ExitCode, ($missing -join ' '), ($extra -join ' '))
                foreach ($line in ($run.Output -split "`n" | Select-Object -First 5)) {
                    Write-Host "       $line" -ForegroundColor Red
                }
            }
        }

        # An unknown step is still rejected, and with the usage code, so making
        # the parameter a list did not turn a typo into a silently ignored one.
        $bogus = Invoke-InScratch -Path $onlyCopy -Arguments @('-DryRun', '-Only', 'Winget,Bogus')
        if ($bogus.ExitCode -eq 3 -and $bogus.Output -match 'Bogus') {
            Test-Ok 'stay_fresh.ps1 -Only rejects an unknown step by name, with exit 3'
        } else {
            Test-Fail "stay_fresh.ps1 -Only Winget,Bogus must exit 3 and name the step it did not recognise; it exited $($bogus.ExitCode)"
            foreach ($line in ($bogus.Output -split "`n" | Select-Object -First 5)) {
                Write-Host "       $line" -ForegroundColor Red
            }
        }
    }
    Remove-Item -Path $onlyBox -Recurse -Force -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------------------
# Shared by the sections below. The header of this file says the functions in
# these scripts cannot be reached, because dot-sourcing a script runs its body.
# This is the way round that which leaves the scripts alone: parse the file,
# find one function definition in the AST, and hand back its source text. A
# section turns that into a definition with [scriptblock]::Create and
# dot-sources it at script scope - inside a function the definition would be
# local to that function and gone by the next line - then calls it with
# fixtures. Only a pure function can be lifted out like this: one that uses no
# script-scope variable and calls no helper that is not lifted with it. The
# newer read-only scripts keep their grading logic in such functions for
# exactly this reason.
function Get-ScriptFunctionSource {
    param(
        [IO.FileInfo]$Script,
        [string]$Name
    )
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Script.FullName, [ref]$null, [ref]$null)
    $definitions = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true)
    foreach ($definition in $definitions) {
        if ($definition.Name -eq $Name) { return $definition.Extent.Text }
    }
    return $null
}

# The script object for one file name, or $null.
function Find-ContractScript {
    param([string]$Name)
    foreach ($candidate in $scripts) {
        if ($candidate.Name -eq $Name) { return $candidate }
    }
    return $null
}

# --------------------------------------------------------------------------
Write-Section 'report-only scripts call no state-changing cmdlet'
# A script with neither -DryRun nor -Yes has promised to be read-only: the
# preview contract above accepts it because its -Action has a read-only
# default, and nothing else would notice the day one of them grew a
# Set-ItemProperty. So the promise is read off the AST: no command whose verb
# changes state. Fix hints such as 'icacls ...' or 'Set-Service ...' are
# strings the script prints, not CommandAst nodes, so advice stays legal.
#
# The subjects are found by role, from the parameter blocks, not listed.
$stateChangingVerb = '^(Set|New|Remove|Clear|Add|Enable|Disable|Start|Stop|Restart|Install|Uninstall|Register|Unregister|Out|Export|Copy|Move|Rename)-'
$harmlessCommands = @('New-Object', 'New-TimeSpan', 'Start-Sleep', 'Add-Type', 'Set-StrictMode')
$readOnlySubjects = 0
foreach ($s in $scripts) {
    $keys = $paramCache[$s.Name.ToLowerInvariant()]
    if ($keys -contains 'DryRun' -or $keys -contains 'Yes') { continue }
    $readOnlySubjects++
    $rel = Get-RelativePath $s.FullName
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($s.FullName, [ref]$null, [ref]$null)
    $commands = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        }, $true)
    $offenders = 0
    foreach ($command in $commands) {
        $commandName = $command.GetCommandName()
        if (-not $commandName) { continue }
        if ($commandName -notmatch $stateChangingVerb) { continue }
        if ($harmlessCommands -contains $commandName) { continue }
        Test-Fail ('{0} line {1}: calls {2}, but declares neither -DryRun nor -Yes' -f $rel, $command.Extent.StartLineNumber, $commandName)
        $offenders++
    }
    if ($offenders -eq 0) {
        Test-Ok "$rel calls no state-changing cmdlet"
    }
}
if ($readOnlySubjects -eq 0) {
    Test-Fail 'no script without -DryRun and -Yes was found - this check has stopped checking'
}

# --------------------------------------------------------------------------
Write-Section 'net_doctor redacts proxy credentials'
# Every proxy URL the report prints goes through Hide-UrlCredential, so this is
# the function standing between a corporate proxy password and a pasted log.
$netDoctor = Find-ContractScript 'net_doctor.ps1'
if (-not $netDoctor) {
    Test-Fail 'net_doctor.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $src = Get-ScriptFunctionSource -Script $netDoctor -Name 'Hide-UrlCredential'
    if (-not $src) {
        Test-Fail 'net_doctor.ps1 : Hide-UrlCredential not found - this check has stopped checking'
    } else {
        . ([scriptblock]::Create($src))
        $redactCases = @(
            @{ In = 'http://u:p@h:8080'; Expect = 'http://u:***@h:8080' }
            @{ In = 'https://h:3128'; Expect = 'https://h:3128' }
            @{ In = 'h:3128'; Expect = 'h:3128' }
            @{ In = 'user@h'; Expect = 'user@h' }
            @{ In = 'http://alice:p@ss:w0rd@proxy.corp:8080'; Expect = 'http://alice:***@proxy.corp:8080' }
            @{ In = 'bob:hunter2@proxy:3128'; Expect = 'bob:***@proxy:3128' }
            @{ In = ''; Expect = '' }
        )
        foreach ($case in $redactCases) {
            $got = Hide-UrlCredential -Url $case.In
            if ($got -ceq $case.Expect) {
                Test-Ok ("Hide-UrlCredential '{0}' -> '{1}'" -f $case.In, $got)
            } else {
                Test-Fail ("Hide-UrlCredential '{0}' gave '{1}', expected '{2}'" -f $case.In, $got, $case.Expect)
            }
        }
        if ((Hide-UrlCredential -Url 'http://alice:p@ss:w0rd@proxy.corp:8080') -match 'w0rd') {
            Test-Fail 'Hide-UrlCredential printed part of a password containing @ and :'
        }
    }
}

# --------------------------------------------------------------------------
Write-Section 'net_doctor reads a hosts file'
if (-not $netDoctor) {
    Test-Fail 'net_doctor.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $src = Get-ScriptFunctionSource -Script $netDoctor -Name 'Get-HostsEntry'
    if (-not $src) {
        Test-Fail 'net_doctor.ps1 : Get-HostsEntry not found - this check has stopped checking'
    } else {
        . ([scriptblock]::Create($src))
        $hostsFixture = @"
# Copyright (c) Microsoft Corp.
#
127.0.0.1       localhost
::1             localhost  # IPv6 loopback

10.0.0.5`tbuild.internal`tbuild  ci-runner
# 10.0.0.6 commented.out
192.168.1.10 nas.local # inline comment
"@ -split "`r?`n"
        $entries = @(Get-HostsEntry -Lines $hostsFixture)
        if ($entries.Count -eq 4) {
            Test-Ok 'Get-HostsEntry found the 4 mappings and skipped comments and blank lines'
        } else {
            Test-Fail "Get-HostsEntry found $($entries.Count) mapping(s), expected 4"
        }
        $build = @($entries | Where-Object { $_.Address -eq '10.0.0.5' })
        if ($build.Count -eq 1 -and ($build[0].Names -join ',') -eq 'build.internal,build,ci-runner') {
            Test-Ok 'one address with three names, split on tabs and runs of spaces'
        } else {
            Test-Fail "the 10.0.0.5 line did not yield build.internal,build,ci-runner: $(@($build | ForEach-Object { $_.Names -join ',' }) -join ';')"
        }
        $loopback6 = @($entries | Where-Object { $_.Address -eq '::1' })
        if ($loopback6.Count -eq 1 -and ($loopback6[0].Names -join ',') -eq 'localhost') {
            Test-Ok 'an IPv6 address with an inline comment keeps only its name'
        } else {
            Test-Fail 'the ::1 line was not read as one mapping to localhost'
        }
        if (@($entries | Where-Object { $_.Names -contains 'commented.out' }).Count -eq 0) {
            Test-Ok 'a commented-out mapping is not an entry'
        } else {
            Test-Fail 'Get-HostsEntry returned a commented-out mapping'
        }
    }
}

# --------------------------------------------------------------------------
Write-Section 'net_doctor grades proxy settings'
if (-not $netDoctor) {
    Test-Fail 'net_doctor.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $src = Get-ScriptFunctionSource -Script $netDoctor -Name 'Get-ProxyFinding'
    if (-not $src) {
        Test-Fail 'net_doctor.ps1 : Get-ProxyFinding not found - this check has stopped checking'
    } else {
        . ([scriptblock]::Create($src))
        $proxyCases = @(
            @{ Label = 'an environment proxy with WinINET off'
               Observed = @{ WinInetEnabled = $false; HttpsProxy = 'http://proxy:8080'; NoProxy = 'localhost' }
               Expect = @('env-without-wininet:warn') }
            @{ Label = 'the same proxy in both places'
               Observed = @{ WinInetEnabled = $true; WinInetServer = 'proxy:8080'; HttpsProxy = 'http://PROXY:8080/'; NoProxy = 'localhost' }
               Expect = @() }
            @{ Label = 'two different proxies'
               Observed = @{ WinInetEnabled = $true; WinInetServer = 'http=a:1;https=other:3128'; HttpsProxy = 'http://proxy:8080'; NoProxy = 'localhost' }
               Expect = @('proxy-mismatch:warn') }
            @{ Label = 'HTTP_PROXY differs from the WinINET http entry while HTTPS matches'
               Observed = @{ WinInetEnabled = $true; WinInetServer = 'http=a:1;https=b:2'; HttpProxy = 'http://other:9'; HttpsProxy = 'http://b:2'; NoProxy = 'localhost' }
               Expect = @('proxy-mismatch:warn') }
            @{ Label = 'HTTP_PROXY and HTTPS_PROXY each match their own WinINET entry'
               Observed = @{ WinInetEnabled = $true; WinInetServer = 'http=a:1;https=b:2'; HttpProxy = 'http://a:1'; HttpsProxy = 'http://b:2'; NoProxy = 'localhost' }
               Expect = @() }
            @{ Label = 'HTTP_PROXY set first, HTTPS_PROXY differs from the WinINET https entry'
               Observed = @{ WinInetEnabled = $true; WinInetServer = 'http=a:1;https=b:2'; HttpProxy = 'http://a:1'; HttpsProxy = 'http://c:3'; NoProxy = 'localhost' }
               Expect = @('proxy-mismatch:warn') }
            @{ Label = 'a single WinINET value applies to both protocols'
               Observed = @{ WinInetEnabled = $true; WinInetServer = 'a:1'; HttpProxy = 'http://a:1'; HttpsProxy = 'http://z:9'; NoProxy = 'localhost' }
               Expect = @('proxy-mismatch:warn') }
            @{ Label = 'WinINET names only https while HTTP_PROXY and HTTPS_PROXY are both set'
               Observed = @{ WinInetEnabled = $true; WinInetServer = 'https=proxy:8080'; HttpProxy = 'http://proxy:8080'; HttpsProxy = 'http://proxy:8080'; NoProxy = 'localhost' }
               Expect = @('proxy-mismatch:warn') }
            @{ Label = 'WinINET names only http while only HTTPS_PROXY is set'
               Observed = @{ WinInetEnabled = $true; WinInetServer = 'http=proxy:8080'; HttpsProxy = 'http://proxy:8080'; NoProxy = 'localhost' }
               Expect = @('proxy-mismatch:warn') }
            @{ Label = 'WinINET names only https and only HTTPS_PROXY is set to the same proxy'
               Observed = @{ WinInetEnabled = $true; WinInetServer = 'https=proxy:8080'; HttpsProxy = 'http://proxy:8080'; NoProxy = 'localhost' }
               Expect = @() }
            @{ Label = 'a proxy with an empty NO_PROXY'
               Observed = @{ WinInetEnabled = $true; WinInetServer = 'proxy:8080'; HttpProxy = 'http://proxy:8080' }
               Expect = @('no-proxy-empty:warn') }
            @{ Label = 'git http.proxy equals the environment proxy'
               Observed = @{ WinInetEnabled = $true; WinInetServer = 'proxy:8080'; HttpsProxy = 'http://proxy:8080'; GitProxy = 'http://PROXY:8080/'; NoProxy = 'localhost' }
               Expect = @() }
            @{ Label = 'git http.proxy differs from the environment proxy'
               Observed = @{ WinInetEnabled = $true; WinInetServer = 'proxy:8080'; HttpsProxy = 'http://proxy:8080'; GitProxy = 'http://git-proxy:3128'; NoProxy = 'localhost' }
               Expect = @('git-proxy-differs:info') }
            @{ Label = 'git http.proxy equals HTTP_PROXY when HTTPS_PROXY is unset'
               Observed = @{ WinInetEnabled = $true; WinInetServer = 'proxy:8080'; HttpProxy = 'http://proxy:8080'; GitProxy = 'http://proxy:8080'; NoProxy = 'localhost' }
               Expect = @() }
            @{ Label = 'git http.proxy equals HTTP_PROXY when ALL_PROXY is also set'
               Observed = @{ WinInetEnabled = $true; WinInetServer = 'http=proxy:8080;https=all:3128'; HttpProxy = 'http://proxy:8080'; AllProxy = 'http://all:3128'; GitProxy = 'http://proxy:8080'; NoProxy = 'localhost' }
               Expect = @() }
            @{ Label = 'git http.proxy equals only ALL_PROXY when HTTP_PROXY is also set'
               Observed = @{ WinInetEnabled = $true; WinInetServer = 'http=proxy:8080;https=all:3128'; HttpProxy = 'http://proxy:8080'; AllProxy = 'http://all:3128'; GitProxy = 'http://all:3128'; NoProxy = 'localhost' }
               Expect = @('git-proxy-differs:info') }
            @{ Label = 'a PAC script only'
               Observed = @{ WinInetEnabled = $false; AutoConfigUrl = 'http://wpad/proxy.pac' }
               Expect = @('pac:info') }
            @{ Label = 'nothing configured'
               Observed = @{ WinInetEnabled = $false }
               Expect = @() }
        )
        foreach ($case in $proxyCases) {
            $got = @(Get-ProxyFinding -Observed $case.Observed | ForEach-Object { '{0}:{1}' -f $_.Id, $_.Level } | Sort-Object)
            $want = @($case.Expect | Sort-Object)
            if (($got -join ' ') -eq ($want -join ' ')) {
                Test-Ok ("{0} -> [{1}]" -f $case.Label, ($got -join ' '))
            } else {
                Test-Fail ("{0}: got [{1}], expected [{2}]" -f $case.Label, ($got -join ' '), ($want -join ' '))
            }
        }
    }
}

# --------------------------------------------------------------------------
Write-Section 'net_doctor classifies adapters'
if (-not $netDoctor) {
    Test-Fail 'net_doctor.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $src = Get-ScriptFunctionSource -Script $netDoctor -Name 'Get-AdapterKind'
    if (-not $src) {
        Test-Fail 'net_doctor.ps1 : Get-AdapterKind not found - this check has stopped checking'
    } else {
        . ([scriptblock]::Create($src))
        $adapterCases = @(
            @{ Name = 'Ethernet 3'; Description = 'Hyper-V Virtual Ethernet Adapter'; Expect = 'hyper-v' }
            @{ Name = 'vEthernet (WSL)'; Description = 'Hyper-V Virtual Ethernet Adapter'; Expect = 'wsl' }
            @{ Name = 'vEthernet (DockerNAT)'; Description = 'Hyper-V Virtual Ethernet Adapter #2'; Expect = 'docker' }
            @{ Name = 'Local Area Connection'; Description = 'TAP-Windows Adapter V9'; Expect = 'vpn' }
            @{ Name = 'Ethernet'; Description = 'Intel(R) Ethernet Connection I219-V'; Expect = 'physical' }
        )
        foreach ($case in $adapterCases) {
            $got = Get-AdapterKind -Name $case.Name -Description $case.Description
            if ($got -eq $case.Expect) {
                Test-Ok ("'{0}' / '{1}' -> {2}" -f $case.Name, $case.Description, $got)
            } else {
                Test-Fail ("'{0}' / '{1}' gave {2}, expected {3}" -f $case.Name, $case.Description, $got, $case.Expect)
            }
        }
    }
}

# --------------------------------------------------------------------------
Write-Section 'net_doctor usage errors answer before the platform guard'
# Run against the real file, not a guard-stripped copy: every one of these has
# to answer before the guard, which is what makes them true on Linux as well.
if (-not $netDoctor) {
    Test-Fail 'net_doctor.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $listed = Invoke-InScratch -Path $netDoctor.FullName -Arguments @('-ListSections')
    $missingIds = @(@('interfaces', 'routes', 'dns', 'proxy', 'hosts', 'listen', 'probe') |
        Where-Object { $listed.Output -notmatch "(?m)^$_\s*$" })
    if ($listed.ExitCode -eq 0 -and $missingIds.Count -eq 0) {
        Test-Ok 'net_doctor.ps1 -ListSections prints the seven section ids and exits 0'
    } else {
        Test-Fail "net_doctor.ps1 -ListSections exited $($listed.ExitCode), missing [$($missingIds -join ' ')]"
    }
    foreach ($case in @(
            @{ Arguments = @('-Only', 'bogus'); Code = 3; Mention = 'bogus'; Label = '-Only bogus is a usage error naming the id' }
            @{ Arguments = @('-Only', ','); Code = 4; Mention = ''; Label = "-Only ',' selects nothing" }
            @{ Arguments = @('-Probe', 'bad host!'); Code = 3; Mention = 'Probe'; Label = '-Probe with a space is a usage error' }
            @{ Arguments = @('-Port', '0'); Code = 3; Mention = 'Port'; Label = '-Port 0 is a usage error' }
        )) {
        $run = Invoke-InScratch -Path $netDoctor.FullName -Arguments $case.Arguments
        if ($run.ExitCode -eq $case.Code -and (-not $case.Mention -or $run.Output -match $case.Mention)) {
            Test-Ok "net_doctor.ps1 $($case.Label) (exit $($run.ExitCode))"
        } else {
            Test-Fail "net_doctor.ps1 $($case.Label): exited $($run.ExitCode), expected $($case.Code)"
            foreach ($line in ($run.Output -split "`n" | Select-Object -First 5)) {
                Write-Host "       $line" -ForegroundColor Red
            }
        }
    }
}

# --------------------------------------------------------------------------
Write-Section 'net_doctor runs end to end'
# The adapter sections read System.Net.NetworkInformation, which answers on
# Linux as well as on Windows, and -HostsFile points the hosts section at a
# fixture, so this is a real run on both runners. It does not assert the
# absence of warnings: a CI runner may have no DNS server or no gateway.
if (-not $netDoctor) {
    Test-Fail 'net_doctor.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $netBox = Join-Path ([IO.Path]::GetTempPath()) ('winnet_' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $netBox -Force | Out-Null
    $netCopy = Copy-UnguardedScript -Script $netDoctor -Directory $netBox
    if (-not $netCopy) {
        Test-Fail 'net_doctor.ps1 : platform guard not found verbatim, so the end-to-end check could not run; update the guard text in contract.ps1'
    } else {
        $hostsPath = Join-Path $netBox 'hosts'
        Set-Content -Path $hostsPath -Value "127.0.0.1 localhost`n10.9.8.7`tcontract-fixture.example # planted by contract.ps1`n"
        $run = Invoke-InScratch -Path $netCopy -Arguments @('-SkipListen', '-HostsFile', $hostsPath, '-Only', 'interfaces,routes,dns,hosts')
        $missing = @(@('== interfaces ==', '== hosts ==', 'contract-fixture.example') | Where-Object { $run.Output -notlike "*$_*" })
        $extra = @(@('== proxy ==', '== listen ==') | Where-Object { $run.Output -like "*$_*" })
        if ($run.ExitCode -eq 0 -and $missing.Count -eq 0 -and $extra.Count -eq 0) {
            Test-Ok 'net_doctor.ps1 -Only interfaces,routes,dns,hosts ran, read the fixture hosts file and nothing else'
        } else {
            Test-Fail ("net_doctor.ps1 end to end: exited {0}, missing [{1}], unexpected [{2}]" -f $run.ExitCode, ($missing -join ' '), ($extra -join ' '))
            foreach ($line in ($run.Output -split "`n" | Select-Object -First 8)) {
                Write-Host "       $line" -ForegroundColor Red
            }
        }
    }
    Remove-Item -Path $netBox -Recurse -Force -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------------------
Write-Section 'ssh_client_doctor grades key ACLs'
# Windows OpenSSH refuses a key that anyone but its owner, SYSTEM and
# Administrators can read. This is the function that has to agree with it,
# including on a German Windows where Administrators is 'Administratoren' -
# which is why the SID is compared first.
$sshDoctor = Find-ContractScript 'ssh_client_doctor.ps1'
if (-not $sshDoctor) {
    Test-Fail 'ssh_client_doctor.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $src = Get-ScriptFunctionSource -Script $sshDoctor -Name 'Test-KeyAcl'
    if (-not $src) {
        Test-Fail 'ssh_client_doctor.ps1 : Test-KeyAcl not found - this check has stopped checking'
    } else {
        . ([scriptblock]::Create($src))
        $owner = [pscustomobject]@{ Identity = 'LAPTOP\alice'; Sid = 'S-1-5-21-1-2-3-1001'; Type = 'Allow'; Rights = 'FullControl' }
        $system = [pscustomobject]@{ Identity = 'NT AUTHORITY\SYSTEM'; Sid = 'S-1-5-18'; Type = 'Allow'; Rights = 'FullControl' }
        $admins = [pscustomobject]@{ Identity = 'BUILTIN\Administrators'; Sid = 'S-1-5-32-544'; Type = 'Allow'; Rights = 'FullControl' }
        $users = [pscustomobject]@{ Identity = 'BUILTIN\Users'; Sid = 'S-1-5-32-545'; Type = 'Allow'; Rights = 'ReadAndExecute, Synchronize' }
        $everyone = [pscustomobject]@{ Identity = 'Everyone'; Sid = 'S-1-1-0'; Type = 'Allow'; Rights = 'FullControl' }
        $denyUsers = [pscustomobject]@{ Identity = 'BUILTIN\Users'; Sid = 'S-1-5-32-545'; Type = 'Deny'; Rights = 'Read' }
        $german = [pscustomobject]@{ Identity = 'VORDEFINIERT\Administratoren'; Sid = 'S-1-5-32-544'; Type = 'Allow'; Rights = 'FullControl' }
        $aclCases = @(
            @{ Label = 'owner only'; Entries = @($owner); User = 'LAPTOP\alice'; Sid = 'S-1-5-21-1-2-3-1001'; Level = 'pass'; Offender = '' }
            @{ Label = 'owner, SYSTEM and Administrators'; Entries = @($owner, $system, $admins); User = 'LAPTOP\alice'; Sid = 'S-1-5-21-1-2-3-1001'; Level = 'pass'; Offender = '' }
            @{ Label = 'BUILTIN\Users can read'; Entries = @($owner, $users); User = 'LAPTOP\alice'; Sid = 'S-1-5-21-1-2-3-1001'; Level = 'fail'; Offender = 'BUILTIN\Users' }
            @{ Label = 'Everyone has full control'; Entries = @($owner, $everyone); User = 'LAPTOP\alice'; Sid = 'S-1-5-21-1-2-3-1001'; Level = 'fail'; Offender = 'Everyone' }
            @{ Label = 'a Deny entry is not an offender'; Entries = @($owner, $denyUsers); User = 'LAPTOP\alice'; Sid = 'S-1-5-21-1-2-3-1001'; Level = 'pass'; Offender = '' }
            @{ Label = 'a localised Administrators name matches by SID'; Entries = @($owner, $german); User = 'LAPTOP\alice'; Sid = 'S-1-5-21-1-2-3-1001'; Level = 'pass'; Offender = '' }
            @{ Label = 'DOMAIN\alice against a bare alice'
               Entries = @([pscustomobject]@{ Identity = 'CORP\alice'; Sid = ''; Type = 'Allow'; Rights = 'FullControl' })
               User = 'alice'; Sid = ''; Level = 'pass'; Offender = '' }
            @{ Label = 'the same account in another case'
               Entries = @([pscustomobject]@{ Identity = 'laptop\ALICE'; Sid = ''; Type = 'Allow'; Rights = 'FullControl' })
               User = 'LAPTOP\alice'; Sid = ''; Level = 'pass'; Offender = '' }
            @{ Label = 'the same name in another domain'
               Entries = @([pscustomobject]@{ Identity = 'CORP\alice'; Sid = ''; Type = 'Allow'; Rights = 'FullControl' })
               User = 'LAPTOP\alice'; Sid = ''; Level = 'fail'; Offender = 'CORP\alice' }
            @{ Label = 'no entries at all (nothing readable)'; Entries = @(); User = 'LAPTOP\alice'; Sid = ''; Level = 'skip'; Offender = '' }
        )
        $usersModify = [pscustomobject]@{ Identity = 'BUILTIN\Users'; Sid = 'S-1-5-32-545'; Type = 'Allow'; Rights = 'Modify, Synchronize' }
        $aclCases += @(
            @{ Label = 'config: BUILTIN\Users can read'; WriteOnly = $true; Entries = @($owner, $users); User = 'LAPTOP\alice'; Sid = 'S-1-5-21-1-2-3-1001'; Level = 'pass'; Offender = '' }
            @{ Label = 'config: BUILTIN\Users can modify'; WriteOnly = $true; Entries = @($owner, $usersModify); User = 'LAPTOP\alice'; Sid = 'S-1-5-21-1-2-3-1001'; Level = 'fail'; Offender = 'BUILTIN\Users' }
            @{ Label = 'config: Everyone has full control'; WriteOnly = $true; Entries = @($owner, $everyone); User = 'LAPTOP\alice'; Sid = 'S-1-5-21-1-2-3-1001'; Level = 'fail'; Offender = 'Everyone' }
        )
        # The owner counts as well as the access list: Win32-OpenSSH refuses a
        # file owned by anyone but the current user, SYSTEM or Administrators.
        $ownedBy = {
            param([string]$Name, [string]$Sid)
            [pscustomobject]@{ Identity = $Name; Sid = $Sid }
        }
        $aclCases += @(
            @{ Label = 'owned by the current user'; Entries = @($owner); Owner = (& $ownedBy 'LAPTOP\alice' 'S-1-5-21-1-2-3-1001'); User = 'LAPTOP\alice'; Sid = 'S-1-5-21-1-2-3-1001'; Level = 'pass'; WrongOwner = '' }
            @{ Label = 'owned by Administrators (localised name, by SID)'; Entries = @($owner); Owner = (& $ownedBy 'VORDEFINIERT\Administratoren' 'S-1-5-32-544'); User = 'LAPTOP\alice'; Sid = 'S-1-5-21-1-2-3-1001'; Level = 'pass'; WrongOwner = '' }
            @{ Label = 'owned by SYSTEM'; Entries = @($owner); Owner = (& $ownedBy 'NT AUTHORITY\SYSTEM' 'S-1-5-18'); User = 'LAPTOP\alice'; Sid = 'S-1-5-21-1-2-3-1001'; Level = 'pass'; WrongOwner = '' }
            @{ Label = 'owned by another user, access list clean'; Entries = @($owner); Owner = (& $ownedBy 'LAPTOP\bob' 'S-1-5-21-1-2-3-1002'); User = 'LAPTOP\alice'; Sid = 'S-1-5-21-1-2-3-1001'; Level = 'fail'; WrongOwner = 'LAPTOP\bob' }
            @{ Label = 'owned by the same name in another domain'; Entries = @($owner); Owner = (& $ownedBy 'CORP\alice' ''); User = 'LAPTOP\alice'; Sid = ''; Level = 'fail'; WrongOwner = 'CORP\alice' }
            @{ Label = 'config owned by another user'; WriteOnly = $true; Entries = @($owner); Owner = (& $ownedBy 'LAPTOP\bob' 'S-1-5-21-1-2-3-1002'); User = 'LAPTOP\alice'; Sid = 'S-1-5-21-1-2-3-1001'; Level = 'fail'; WrongOwner = 'LAPTOP\bob' }
            @{ Label = 'owner unreadable is not judged'; Entries = @($owner); Owner = $null; User = 'LAPTOP\alice'; Sid = 'S-1-5-21-1-2-3-1001'; Level = 'pass'; WrongOwner = '' }
        )
        $aclRan = 0
        foreach ($case in $aclCases) {
            $verdict = Test-KeyAcl -Entries $case.Entries -CurrentUser $case.User -CurrentUserSid $case.Sid -WriteOnly:([bool]$case.WriteOnly) -Owner $case.Owner
            $aclRan++
            $offenderOk = (-not $case.Offender) -or (@($verdict.Offenders) -contains $case.Offender)
            $ownerVerdictOk = (-not $case.ContainsKey('WrongOwner')) -or ($verdict.WrongOwner -eq $case.WrongOwner)
            $offenderOk = $offenderOk -and $ownerVerdictOk
            if ($verdict.Level -eq $case.Level -and $offenderOk) {
                Test-Ok ("Test-KeyAcl {0} -> {1}" -f $case.Label, $verdict.Level)
            } else {
                Test-Fail ("Test-KeyAcl {0}: got {1} [{2}], expected {3} [{4}]" -f $case.Label, $verdict.Level, (@($verdict.Offenders) -join ', '), $case.Level, $case.Offender)
            }
        }
        if ($aclRan -lt 17) {
            Test-Fail "only $aclRan ACL case(s) ran - this check has stopped checking"
        }
    }
}

# --------------------------------------------------------------------------
Write-Section 'ssh_client_doctor reads IdentityFile lines'
if (-not $sshDoctor) {
    Test-Fail 'ssh_client_doctor.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $src = Get-ScriptFunctionSource -Script $sshDoctor -Name 'Get-IdentityFileReference'
    if (-not $src) {
        Test-Fail 'ssh_client_doctor.ps1 : Get-IdentityFileReference not found - this check has stopped checking'
    } else {
        . ([scriptblock]::Create($src))
        $configFixture = @'
# IdentityFile ~/.ssh/commented
Host github.com
    identityfile ~/.ssh/id_ed25519
IdentityFile=%d/.ssh/key
IdentityFile "C:/Users/a b/.ssh/spaced key"
IdentityFile none
IdentityFile ~/.ssh/%h_key
IdentityFile ${HOME}/.ssh/env_key
'@ -split "`r?`n"
        $refs = Get-IdentityFileReference -Lines $configFixture -HomeDir 'C:\Users\alice'
        $gotResolved = @($refs.Resolvable | ForEach-Object { '{0}={1}' -f $_.Line, $_.Path }) -join ' | '
        $wantResolved = '3=C:\Users\alice/.ssh/id_ed25519 | 4=C:\Users\alice/.ssh/key | 5=C:/Users/a b/.ssh/spaced key'
        if ($gotResolved -eq $wantResolved) {
            Test-Ok 'lower-case keyword, the = form, %d, ~ and a quoted path with spaces resolve, with their line numbers'
        } else {
            Test-Fail "resolvable IdentityFile lines: got [$gotResolved], expected [$wantResolved]"
        }
        $gotUnresolved = @($refs.Unresolvable | ForEach-Object { $_.Line }) -join ','
        if ($gotUnresolved -eq '7,8') {
            Test-Ok 'a %h token and a ${VAR} are reported as unresolvable rather than guessed at'
        } else {
            Test-Fail "unresolvable IdentityFile lines: got [$gotUnresolved], expected [7,8]"
        }
        $everything = @($refs.Resolvable) + @($refs.Unresolvable)
        if (@($everything | Where-Object { $_.Raw -match 'commented|none' }).Count -eq 0) {
            Test-Ok 'a commented line and IdentityFile none are ignored'
        } else {
            Test-Fail 'a commented IdentityFile or IdentityFile none was returned'
        }
    }
}

# --------------------------------------------------------------------------
Write-Section 'ssh_client_doctor classifies ssh clients'
if (-not $sshDoctor) {
    Test-Fail 'ssh_client_doctor.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $src = Get-ScriptFunctionSource -Script $sshDoctor -Name 'Get-SshClientFinding'
    if (-not $src) {
        Test-Fail 'ssh_client_doctor.ps1 : Get-SshClientFinding not found - this check has stopped checking'
    } else {
        . ([scriptblock]::Create($src))
        $gitSsh = 'C:\Program Files\Git\usr\bin\ssh.exe'
        $winSsh = 'C:\Windows\System32\OpenSSH\ssh.exe'
        $clientCases = @(
            @{ Label = 'Git for Windows only'; Clients = @($gitSsh); Agent = $true; Command = ''; Env = ''; EnvCommand = ''; Expect = 'first-client' }
            @{ Label = 'Windows OpenSSH only'; Clients = @($winSsh); Agent = $true; Command = ''; Env = ''; EnvCommand = ''; Expect = 'first-client' }
            @{ Label = 'both, agent running, nothing pins git'; Clients = @($winSsh, $gitSsh); Agent = $true; Command = ''; Env = ''; EnvCommand = ''; Expect = 'first-client two-clients' }
            @{ Label = 'both, core.sshCommand set'; Clients = @($winSsh, $gitSsh); Agent = $true; Command = 'C:/Windows/System32/OpenSSH/ssh.exe'; Env = ''; EnvCommand = ''; Expect = 'first-client git-ssh-command' }
            @{ Label = 'core.sshCommand pinned to Git ssh, agent running'; Clients = @($winSsh, $gitSsh); Agent = $true; Command = 'C:/Program Files/Git/usr/bin/ssh.exe'; Env = ''; EnvCommand = ''; Expect = 'first-client git-ssh-command git-ssh-pinned-git' }
            @{ Label = 'core.sshCommand quoted Git ssh with options, agent running'; Clients = @($winSsh, $gitSsh); Agent = $true; Command = '"C:\Program Files\Git\usr\bin\ssh.exe" -o BatchMode=yes'; Env = ''; EnvCommand = ''; Expect = 'first-client git-ssh-command git-ssh-pinned-git' }
            @{ Label = 'core.sshCommand pinned to Scoop Git ssh, agent running'; Clients = @($winSsh, $gitSsh); Agent = $true; Command = 'C:/Users/me/scoop/apps/git/current/usr/bin/ssh.exe'; Env = ''; EnvCommand = ''; Expect = 'first-client git-ssh-command git-ssh-pinned-git' }
            @{ Label = 'core.sshCommand pinned to lower-case Git ssh, agent running'; Clients = @($winSsh, $gitSsh); Agent = $true; Command = 'd:\tools\git\usr\bin\ssh.exe'; Env = ''; EnvCommand = ''; Expect = 'first-client git-ssh-command git-ssh-pinned-git' }
            @{ Label = 'core.sshCommand pinned to a non-Git usr\bin ssh, agent running'; Clients = @($winSsh, $gitSsh); Agent = $true; Command = 'C:/msys64/usr/bin/ssh.exe'; Env = ''; EnvCommand = ''; Expect = 'first-client git-ssh-command' }
            @{ Label = 'core.sshCommand pinned to Git ssh, agent not running'; Clients = @($winSsh, $gitSsh); Agent = $false; Command = 'C:/Program Files/Git/usr/bin/ssh.exe'; Env = ''; EnvCommand = ''; Expect = 'first-client git-ssh-command' }
            @{ Label = 'core.sshCommand pinned to Windows OpenSSH, agent running'; Clients = @($winSsh, $gitSsh); Agent = $true; Command = 'C:\Windows\System32\OpenSSH\ssh.exe'; Env = ''; EnvCommand = ''; Expect = 'first-client git-ssh-command' }
            @{ Label = 'core.sshCommand is an unknown wrapper'; Clients = @($winSsh, $gitSsh); Agent = $true; Command = 'C:/tools/plink.exe -batch'; Env = ''; EnvCommand = ''; Expect = 'first-client git-ssh-command' }
            @{ Label = 'both, GIT_SSH_COMMAND set to a wrapper'; Clients = @($winSsh, $gitSsh); Agent = $true; Command = ''; Env = ''; EnvCommand = 'ssh -i key'; Expect = 'first-client git-ssh-env' }
            @{ Label = 'GIT_SSH_COMMAND names Git ssh, agent running'; Clients = @($winSsh, $gitSsh); Agent = $true; Command = ''; Env = ''; EnvCommand = '"C:\Program Files\Git\usr\bin\ssh.exe" -i key'; Expect = 'first-client git-ssh-env git-ssh-pinned-git' }
            @{ Label = 'GIT_SSH_COMMAND names Git ssh, agent not running'; Clients = @($winSsh, $gitSsh); Agent = $false; Command = ''; Env = ''; EnvCommand = '"C:\Program Files\Git\usr\bin\ssh.exe" -i key'; Expect = 'first-client git-ssh-env' }
            @{ Label = 'GIT_SSH names Git ssh (unquoted, spaces), agent running'; Clients = @($winSsh, $gitSsh); Agent = $true; Command = ''; Env = 'C:\Program Files\Git\usr\bin\ssh.exe'; EnvCommand = ''; Expect = 'first-client git-ssh-env git-ssh-pinned-git' }
            @{ Label = 'GIT_SSH names Windows OpenSSH, agent running'; Clients = @($winSsh, $gitSsh); Agent = $true; Command = ''; Env = 'C:\Windows\System32\OpenSSH\ssh.exe'; EnvCommand = ''; Expect = 'first-client git-ssh-env' }
            @{ Label = 'GIT_SSH_COMMAND (Windows ssh) outranks core.sshCommand and GIT_SSH (Git ssh)'; Clients = @($winSsh, $gitSsh); Agent = $true; Command = 'C:/Program Files/Git/usr/bin/ssh.exe'; Env = 'C:\Program Files\Git\usr\bin\ssh.exe'; EnvCommand = 'C:\Windows\System32\OpenSSH\ssh.exe'; Expect = 'first-client git-ssh-env' }
            @{ Label = 'core.sshCommand (Windows ssh) outranks GIT_SSH (Git ssh)'; Clients = @($winSsh, $gitSsh); Agent = $true; Command = 'C:/Windows/System32/OpenSSH/ssh.exe'; Env = 'C:\Program Files\Git\usr\bin\ssh.exe'; EnvCommand = ''; Expect = 'first-client git-ssh-command' }
            @{ Label = 'core.sshCommand (Git ssh) outranks GIT_SSH (Windows ssh)'; Clients = @($winSsh, $gitSsh); Agent = $true; Command = 'C:/Program Files/Git/usr/bin/ssh.exe'; Env = 'C:\Windows\System32\OpenSSH\ssh.exe'; EnvCommand = ''; Expect = 'first-client git-ssh-command git-ssh-pinned-git' }
            @{ Label = 'GIT_SSH_COMMAND (Git ssh) outranks core.sshCommand (Windows ssh)'; Clients = @($winSsh, $gitSsh); Agent = $true; Command = 'C:\Windows\System32\OpenSSH\ssh.exe'; Env = ''; EnvCommand = 'C:\Program Files\Git\usr\bin\ssh.exe'; Expect = 'first-client git-ssh-env git-ssh-pinned-git' }
            @{ Label = 'both, agent not running'; Clients = @($winSsh, $gitSsh); Agent = $false; Command = ''; Env = ''; EnvCommand = ''; Expect = 'first-client' }
            @{ Label = 'no client at all'; Clients = @(); Agent = $false; Command = ''; Env = ''; EnvCommand = ''; Expect = 'no-client' }
        )
        foreach ($case in $clientCases) {
            $found = @(Get-SshClientFinding -Clients $case.Clients -AgentRunning $case.Agent -GitSshCommand $case.Command -GitSshEnv $case.Env -GitSshCommandEnv $case.EnvCommand)
            $ids = ($found | ForEach-Object { $_.Id }) -join ' '
            $warnFix = @($found | Where-Object { $_.Level -eq 'warn' -and -not $_.Fix }).Count
            if ($ids -eq $case.Expect -and $warnFix -eq 0) {
                Test-Ok ("{0} -> [{1}]" -f $case.Label, $ids)
            } else {
                Test-Fail ("{0}: got [{1}], expected [{2}] (warnings without a fix: {3})" -f $case.Label, $ids, $case.Expect, $warnFix)
            }
        }
    }
}

# --------------------------------------------------------------------------
Write-Section 'ssh_client_doctor usage'
if (-not $sshDoctor) {
    Test-Fail 'ssh_client_doctor.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $run = Invoke-InScratch -Path $sshDoctor.FullName -Arguments @('-FailOn', 'bogus')
    if ($run.ExitCode -eq 3 -and $run.Output -match 'bogus') {
        Test-Ok 'ssh_client_doctor.ps1 -FailOn bogus exits 3 and names the value, before the platform guard'
    } else {
        Test-Fail "ssh_client_doctor.ps1 -FailOn bogus must exit 3 naming the value; it exited $($run.ExitCode)"
    }
    # Accepted means "not a usage error": off Windows it then stops at the
    # guard (2), on Windows it reports on the scratch profile's missing .ssh.
    $run = Invoke-InScratch -Path $sshDoctor.FullName -Arguments @('-FailOn', 'warn')
    if ($run.ExitCode -ne 3) {
        Test-Ok "ssh_client_doctor.ps1 -FailOn warn is accepted (exit $($run.ExitCode))"
    } else {
        Test-Fail 'ssh_client_doctor.ps1 -FailOn warn was rejected as a usage error'
    }
}

# --------------------------------------------------------------------------
Write-Section 'ssh_client_doctor runs end to end on a scratch directory'
# The canary on line 2 is the point: the script decides what a file is from
# its first line, and nothing after that line may reach the output.
if (-not $sshDoctor) {
    Test-Fail 'ssh_client_doctor.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $sshBox = Join-Path ([IO.Path]::GetTempPath()) ('winssh_' + [Guid]::NewGuid().ToString('N'))
    $sshDirFixture = Join-Path $sshBox '.ssh'
    New-Item -ItemType Directory -Path $sshDirFixture -Force | Out-Null
    $sshCopy = Copy-UnguardedScript -Script $sshDoctor -Directory $sshBox
    if (-not $sshCopy) {
        Test-Fail 'ssh_client_doctor.ps1 : platform guard not found verbatim, so the end-to-end check could not run; update the guard text in contract.ps1'
    } else {
        $canary = 'CANARY-KEY-BODY-' + [Guid]::NewGuid().ToString('N')
        Set-Content -Path (Join-Path $sshDirFixture 'id_test') -Value "-----BEGIN OPENSSH PRIVATE KEY-----`n$canary`n-----END OPENSSH PRIVATE KEY-----`n"
        Set-Content -Path (Join-Path $sshDirFixture 'config') -Value "Host example`n    IdentityFile ~/.ssh/missing_key`n"
        $run = Invoke-InScratch -Path $sshCopy -Arguments @('-SshDir', $sshDirFixture)
        $problems = @()
        if ($run.ExitCode -notin 0, 1) { $problems += "exit $($run.ExitCode)" }
        if ($run.Output -notmatch 'missing') { $problems += 'no finding for the missing IdentityFile' }
        if ($run.Output -notmatch 'id_test') { $problems += 'the private key is not named' }
        if ($run.Output -match [regex]::Escape($canary)) { $problems += 'the key body reached the output' }
        if ($problems.Count -eq 0) {
            Test-Ok 'ssh_client_doctor.ps1 found the key by its first line, flagged the missing IdentityFile and printed no key material'
        } else {
            Test-Fail ('ssh_client_doctor.ps1 end to end: {0}' -f ($problems -join '; '))
            foreach ($line in ($run.Output -split "`n" | Select-Object -First 8)) {
                Write-Host "       $line" -ForegroundColor Red
            }
        }
    }
    Remove-Item -Path $sshBox -Recurse -Force -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------------------
Write-Section 'disk_usage measures a tree without following links'
# The size walk skips reparse points. A junction counted is a mount counted
# twice; a link back to an ancestor is a walk that never ends.
$diskUsage = Find-ContractScript 'disk_usage.ps1'
if (-not $diskUsage) {
    Test-Fail 'disk_usage.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $src = Get-ScriptFunctionSource -Script $diskUsage -Name 'Get-DirectorySize'
    if (-not $src) {
        Test-Fail 'disk_usage.ps1 : Get-DirectorySize not found - this check has stopped checking'
    } else {
        . ([scriptblock]::Create($src))
        $diskSizeSrc = Get-ScriptFunctionSource -Script $diskUsage -Name 'Get-FileDiskSize'
        if (-not $diskSizeSrc) {
            Test-Fail 'disk_usage.ps1 : Get-FileDiskSize not found - this check has stopped checking'
            $diskSizeSrc = 'function Get-FileDiskSize { param([object]$File) return [long]$File.Length }'
        }
        . ([scriptblock]::Create($diskSizeSrc))
        $linkSrc = Get-ScriptFunctionSource -Script $diskUsage -Name 'Test-NameSurrogateLink'
        if (-not $linkSrc) {
            Test-Fail 'disk_usage.ps1 : Test-NameSurrogateLink not found - this check has stopped checking'
            $linkSrc = 'function Test-NameSurrogateLink { param([object]$Item) return $true }'
        }
        . ([scriptblock]::Create($linkSrc))
        $skipSrc = Get-ScriptFunctionSource -Script $diskUsage -Name 'Test-SkippedReparse'
        if (-not $skipSrc) {
            Test-Fail 'disk_usage.ps1 : Test-SkippedReparse not found - this check has stopped checking'
            $skipSrc = 'function Test-SkippedReparse { param([object]$Item) return $true }'
        }
        . ([scriptblock]::Create($skipSrc))
        $treeSrc = Get-ScriptFunctionSource -Script $diskUsage -Name 'Get-TreeNode'
        if (-not $treeSrc) {
            Test-Fail 'disk_usage.ps1 : Get-TreeNode not found - this check has stopped checking'
            $treeSrc = 'function Get-TreeNode { param([string]$Path, [string]$Name, [int]$Level, [int]$MaxLevel) return [pscustomobject]@{ Bytes = -1L; Inaccessible = 0; Children = @() } }'
        }
        . ([scriptblock]::Create($treeSrc))
        $sizeBox = Join-Path ([IO.Path]::GetTempPath()) ('winsize_' + [Guid]::NewGuid().ToString('N'))
        $deep = Join-Path (Join-Path $sizeBox 'sub') 'deep'
        $emptyDir = Join-Path $sizeBox 'empty'
        New-Item -ItemType Directory -Path $deep, $emptyDir -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $sizeBox 'a.bin'), (New-Object byte[] 1000))
        [IO.File]::WriteAllBytes((Join-Path (Join-Path $sizeBox 'sub') 'b.bin'), (New-Object byte[] 2000))
        [IO.File]::WriteAllBytes((Join-Path $deep 'c.bin'), (New-Object byte[] 4000))
        $linked = $false
        try {
            New-Item -ItemType SymbolicLink -Path (Join-Path $sizeBox 'link-to-sub') -Target (Join-Path $sizeBox 'sub') -ErrorAction Stop | Out-Null
            $linked = $true
            New-Item -ItemType SymbolicLink -Path (Join-Path $sizeBox 'link-to-a') -Target (Join-Path $sizeBox 'a.bin') -ErrorAction Stop | Out-Null
        } catch {
            # Normal on Windows without Developer Mode or elevation.
            Test-Skip "could not create a symbolic link here ($($_.Exception.Message)); the link half of this check did not run"
        }
        $measured = Get-DirectorySize -Path $sizeBox
        if ($measured.Bytes -eq 7000) {
            Test-Ok 'Get-DirectorySize sums 1000 + 2000 + 4000 bytes across three levels'
        } else {
            Test-Fail "Get-DirectorySize returned $($measured.Bytes) bytes, expected 7000"
        }
        if ($linked) {
            if ($measured.Bytes -eq 7000) {
                Test-Ok 'the symbolic link to sub was not followed (sub was counted once)'
            } else {
                Test-Fail 'the symbolic link to sub was followed and its target counted twice'
            }
        }
        $emptySize = Get-DirectorySize -Path $emptyDir
        if ($emptySize.Bytes -eq 0 -and $emptySize.Inaccessible -eq 0) {
            Test-Ok 'an empty folder measures 0 bytes with nothing unreadable'
        } else {
            Test-Fail "an empty folder measured $($emptySize.Bytes) bytes, $($emptySize.Inaccessible) unreadable"
        }
        # A sparse or compressed file counts at its allocated size, not its
        # logical length. The allocated-size call is stubbed here (a sparse
        # file cannot be made portably); what is checked is that the walk
        # asks for it for every file and adds up what it answers.
        [IO.File]::WriteAllBytes((Join-Path $sizeBox 'sparse.bin'), (New-Object byte[] 1000))
        function Get-FileDiskSize {
            param([object]$File)
            if ($File.Name -eq 'sparse.bin') { return 100L }
            return [long]$File.Length
        }
        $allocated = Get-DirectorySize -Path $sizeBox
        if ($allocated.Bytes -eq 7100) {
            Test-Ok 'Get-DirectorySize adds the allocated size a sparse file reports, not its length'
        } else {
            Test-Fail "Get-DirectorySize returned $($allocated.Bytes) bytes with a stubbed 100-byte sparse file, expected 7100"
        }
        # The real function: an ordinary file is its Length; a sparse or
        # compressed file whose allocated size cannot be had (not Windows, or
        # a path the call refuses) falls back to Length instead of failing.
        . ([scriptblock]::Create($diskSizeSrc))
        $plain = [pscustomobject]@{ Name = 'p'; Length = 1234L; Attributes = [IO.FileAttributes]::Archive; FullName = (Join-Path $sizeBox 'does-not-exist-1') }
        $sparseGone = [pscustomobject]@{ Name = 's'; Length = 5678L; Attributes = ([IO.FileAttributes]::SparseFile -bor [IO.FileAttributes]::Archive); FullName = (Join-Path $sizeBox 'does-not-exist-2') }
        $packedGone = [pscustomobject]@{ Name = 'c'; Length = 9012L; Attributes = [IO.FileAttributes]::Compressed; FullName = (Join-Path $sizeBox 'does-not-exist-3') }
        if ((Get-FileDiskSize -File $plain) -eq 1234 -and (Get-FileDiskSize -File $sparseGone) -eq 5678 -and (Get-FileDiskSize -File $packedGone) -eq 9012) {
            Test-Ok 'Get-FileDiskSize returns Length for a plain file and falls back to it when the allocated size is unavailable'
        } else {
            Test-Fail 'Get-FileDiskSize did not return Length for a plain file or for a sparse/compressed file it could not size'
        }
        # A reparse-point file is skipped only when it is a link. A Cloud
        # Files placeholder (OneDrive) has the attribute but no LinkType and
        # no Target, and counts at its allocated size. Get-Item is shadowed
        # by a stub that answers from the item's name, since a placeholder
        # cannot be made here.
        function Get-Item {
            param([string]$LiteralPath, [switch]$Force)
            $leaf = Split-Path -Leaf $LiteralPath
            if ($leaf -eq 'symlink.bin') { return [pscustomobject]@{ LinkType = 'SymbolicLink'; Target = @('C:\elsewhere\x.bin') } }
            if ($leaf -eq 'junction-like.bin') { return [pscustomobject]@{ LinkType = $null; Target = @('C:\elsewhere') } }
            if ($leaf -eq 'unreadable.bin') { throw 'access denied' }
            if ($leaf -eq 'junction-dir') { return [pscustomobject]@{ LinkType = 'Junction'; Target = @('C:\elsewhere') } }
            return [pscustomobject]@{ LinkType = $null; Target = $null }
        }
        $reparse = [IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Archive
        $mk = { param($n) [pscustomobject]@{ Name = $n; FullName = (Join-Path $sizeBox $n); Length = 4096L; Attributes = $reparse } }
        $isLink = @{}
        foreach ($n in 'symlink.bin', 'junction-like.bin', 'unreadable.bin', 'placeholder.bin') {
            $isLink[$n] = [bool](Test-NameSurrogateLink -Item (& $mk $n))
        }
        if ($isLink['symlink.bin'] -and $isLink['junction-like.bin'] -and $isLink['unreadable.bin'] -and -not $isLink['placeholder.bin']) {
            Test-Ok 'Test-NameSurrogateLink skips links (LinkType or Target, or unreadable) and keeps a Cloud Files placeholder'
        } else {
            Test-Fail ("Test-NameSurrogateLink: symlink={0} target-only={1} unreadable={2} placeholder={3}, expected True True True False" -f $isLink['symlink.bin'], $isLink['junction-like.bin'], $isLink['unreadable.bin'], $isLink['placeholder.bin'])
        }
        # Get-FileDiskSize asks for the allocated size of a reparse-point
        # file too; with no way to ask here it falls back to Length.
        . ([scriptblock]::Create($diskSizeSrc))
        $cloudFile = [pscustomobject]@{ Name = 'placeholder.bin'; Length = 4096L; Attributes = $reparse; FullName = (Join-Path $sizeBox 'does-not-exist-4') }
        if ((Get-FileDiskSize -File $cloudFile) -ge 0 -and (Get-FileDiskSize -File $cloudFile) -le 4096) {
            Test-Ok 'Get-FileDiskSize sizes a reparse-point file without failing'
        } else {
            Test-Fail 'Get-FileDiskSize returned an impossible size for a reparse-point file'
        }
        # Both walks, over a fake tree (a placeholder file, a link file, a
        # OneDrive-style reparse folder holding 500 bytes, and a junction
        # holding 9999). Real reparse points cannot be made here, so
        # DirectoryInfo is answered from a table. The placeholder and the
        # cloud folder count at every depth; the link file and the junction
        # never do: 1000 + 4096 + 500 = 5596.
        $reparseAttr = [IO.FileAttributes]::ReparsePoint
        $plainAttr = [IO.FileAttributes]::Directory
        $fakeDirs = @{}
        $mkFile = { param($n, $len, $attr) [pscustomobject]@{ Name = $n; FullName = (Join-Path $sizeBox $n); Length = [long]$len; Attributes = $attr } }
        $mkDir = {
            param($path, $files, $dirs, $attr)
            $d = [pscustomobject]@{ Name = (Split-Path -Leaf $path); FullName = $path; Attributes = $attr; Files = @($files); Dirs = @($dirs) }
            $d | Add-Member -MemberType ScriptMethod -Name GetFiles -Value { $this.Files }
            $d | Add-Member -MemberType ScriptMethod -Name GetDirectories -Value { $this.Dirs }
            $fakeDirs[$path] = $d
            $d
        }
        $cloudDir = & $mkDir (Join-Path $sizeBox 'cloud-dir') @(& $mkFile 'cf.bin' 500 ([IO.FileAttributes]::Archive)) @() ($plainAttr -bor $reparseAttr)
        $juncDir = & $mkDir (Join-Path $sizeBox 'junction-dir') @(& $mkFile 'jf.bin' 9999 ([IO.FileAttributes]::Archive)) @() ($plainAttr -bor $reparseAttr)
        $fakeRoot = & $mkDir (Join-Path $sizeBox 'fake-root') @(
            (& $mkFile 'plain.bin' 1000 ([IO.FileAttributes]::Archive)),
            (& $mkFile 'placeholder.bin' 4096 ($reparseAttr -bor [IO.FileAttributes]::Archive)),
            (& $mkFile 'symlink.bin' 7777 ($reparseAttr -bor [IO.FileAttributes]::Archive))
        ) @($cloudDir, $juncDir) $plainAttr
        function New-Object {
            param([string]$TypeName, [object[]]$ArgumentList)
            if ($TypeName -eq 'System.IO.DirectoryInfo' -and $fakeDirs.ContainsKey([string]$ArgumentList[0])) { return $fakeDirs[[string]$ArgumentList[0]] }
            if ($ArgumentList) { return Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName -ArgumentList $ArgumentList }
            return Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName
        }
        function Get-FileDiskSize { param([object]$File) return [long]$File.Length }
        $fakeSize = Get-DirectorySize -Path $fakeRoot.FullName
        if ($fakeSize.Bytes -eq 5596) {
            Test-Ok 'Get-DirectorySize counts a placeholder file and a OneDrive-style reparse folder, and skips a link file and a junction'
        } else {
            Test-Fail "Get-DirectorySize returned $($fakeSize.Bytes) bytes for the fake tree, expected 5596 (placeholder file + non-link reparse folder counted, links skipped)"
        }
        foreach ($maxLevel in 1, 2, 3) {
            $node = Get-TreeNode -Path $fakeRoot.FullName -Name 'fake-root' -Level 0 -MaxLevel $maxLevel
            if ($node.Bytes -eq 5596) {
                Test-Ok "Get-TreeNode (MaxLevel $maxLevel) agrees with Get-DirectorySize on the placeholder, the reparse folder and the links"
            } else {
                Test-Fail "Get-TreeNode (MaxLevel $maxLevel) returned $($node.Bytes) bytes for the fake tree, expected 5596"
            }
        }
        Remove-Item Function:\New-Object -ErrorAction SilentlyContinue
        Remove-Item Function:\Get-FileDiskSize -ErrorAction SilentlyContinue
        Remove-Item Function:\Get-Item -ErrorAction SilentlyContinue
        Remove-Item -Path $sizeBox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --------------------------------------------------------------------------
Write-Section 'disk_usage hot-spot table is well formed'
# Each hint is a pointer to another tool, and two of those tools live in this
# repository. A pointer to a flag that was renamed is worse than none, so every
# 'clean_disk_c.ps1 -Flag' and 'wsl_manage.ps1 verb' in a hint is checked
# against the script it names.
if (-not $diskUsage) {
    Test-Fail 'disk_usage.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $src = Get-ScriptFunctionSource -Script $diskUsage -Name 'Get-HotspotTarget'
    if (-not $src) {
        Test-Fail 'disk_usage.ps1 : Get-HotspotTarget not found - this check has stopped checking'
    } else {
        . ([scriptblock]::Create($src))
        $hotspots = @(Get-HotspotTarget -UserProfile 'C:\Users\alice' -LocalAppData 'C:\Users\alice\AppData\Local' `
                -ProgramData 'C:\ProgramData' -SystemDrive 'C:' `
                -WslDisk @([pscustomobject]@{ Name = 'Ubuntu'; Path = 'D:\wsl\Ubuntu\ext4.vhdx' }))
        $malformed = @($hotspots | Where-Object { -not $_.Label -or -not $_.Path -or -not $_.Hint -or $_.Kind -notin 'file', 'dir' })
        if ($hotspots.Count -ge 10 -and $malformed.Count -eq 0) {
            Test-Ok "Get-HotspotTarget returned $($hotspots.Count) targets, each with a kind, label, path and hint"
        } else {
            Test-Fail "Get-HotspotTarget returned $($hotspots.Count) target(s), $($malformed.Count) malformed; expected at least 10, none malformed"
        }
        $duplicateLabels = @($hotspots | Group-Object -Property Label | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
        if ($duplicateLabels.Count -eq 0) {
            Test-Ok 'every label is unique'
        } else {
            Test-Fail "duplicate labels: $($duplicateLabels -join ', ')"
        }
        $tooWide = @($hotspots | Where-Object { $_.Label.Length -gt 44 } | ForEach-Object { $_.Label })
        if ($tooWide.Count -eq 0) {
            Test-Ok 'every label fits the 44-wide column'
        } else {
            Test-Fail "labels wider than the 44-character column: $($tooWide -join '; ')"
        }
        $unexpanded = @($hotspots | Where-Object { $_.Path -match '%' } | ForEach-Object { $_.Path })
        if ($unexpanded.Count -eq 0) {
            Test-Ok 'no path is left with an unexpanded %VARIABLE%'
        } else {
            Test-Fail "paths with an unexpanded variable: $($unexpanded -join '; ')"
        }

        $cleanReferences = 0
        $wslReferences = 0
        foreach ($target in $hotspots) {
            foreach ($m in [regex]::Matches($target.Hint, 'clean_disk_c\.ps1 -([A-Za-z]+)')) {
                $cleanReferences++
                $flag = $m.Groups[1].Value
                if ($paramCache['clean_disk_c.ps1'] -contains $flag) {
                    Test-Ok "'$($target.Label)' points at clean_disk_c.ps1 -$flag, which it declares"
                } else {
                    Test-Fail "'$($target.Label)' points at clean_disk_c.ps1 -$flag, which clean_disk_c.ps1 does not declare"
                }
            }
            foreach ($m in [regex]::Matches($target.Hint, 'wsl_manage\.ps1 ([a-z][a-z-]*)')) {
                $wslReferences++
                $verb = $m.Groups[1].Value
                if ($wslValues -contains $verb) {
                    Test-Ok "'$($target.Label)' points at wsl_manage.ps1 $verb, which it accepts"
                } else {
                    Test-Fail "'$($target.Label)' points at wsl_manage.ps1 $verb, which is not one of its actions"
                }
            }
        }
        if ($cleanReferences -eq 0) {
            Test-Fail 'no hint names a clean_disk_c.ps1 flag - this check has stopped checking'
        }
        if ($wslReferences -eq 0) {
            Test-Fail 'the WSL disk row names no wsl_manage.ps1 action - this check has stopped checking'
        }
    }
}

# --------------------------------------------------------------------------
Write-Section 'disk_usage usage errors'
if (-not $diskUsage) {
    Test-Fail 'disk_usage.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $nowhere = Join-Path ([IO.Path]::GetTempPath()) ('winnowhere_' + [Guid]::NewGuid().ToString('N'))
    foreach ($case in @(
            @{ Arguments = @('tree', '-Path', $nowhere); Mention = 'Path'; Label = 'tree -Path at a folder that does not exist' }
            @{ Arguments = @('tree', '-Depth', '9'); Mention = 'Depth'; Label = '-Depth 9' }
            @{ Arguments = @('-Top', '0'); Mention = 'Top'; Label = '-Top 0' }
            @{ Arguments = @('-MinSizeMB', '2000000'); Mention = 'MinSizeMB'; Label = '-MinSizeMB 2000000' }
        )) {
        $run = Invoke-InScratch -Path $diskUsage.FullName -Arguments $case.Arguments
        if ($run.ExitCode -eq 3 -and $run.Output -match $case.Mention) {
            Test-Ok "disk_usage.ps1 $($case.Label) is a usage error (exit 3), before the platform guard"
        } else {
            Test-Fail "disk_usage.ps1 $($case.Label) must exit 3 naming $($case.Mention); it exited $($run.ExitCode)"
            foreach ($line in ($run.Output -split "`n" | Select-Object -First 5)) {
                Write-Host "       $line" -ForegroundColor Red
            }
        }
    }
}

# --------------------------------------------------------------------------
Write-Section 'disk_usage runs end to end'
# On Linux the hot-spot paths are all absent, so this proves the report gets
# from the first line to the last without a stack trace. On windows-2025 the
# same call measures the real system drive.
if (-not $diskUsage) {
    Test-Fail 'disk_usage.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $usageBox = Join-Path ([IO.Path]::GetTempPath()) ('winusage_' + [Guid]::NewGuid().ToString('N'))
    $usageData = Join-Path $usageBox 'data'
    New-Item -ItemType Directory -Path (Join-Path $usageData 'big-child'), (Join-Path $usageData 'small-child') -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path (Join-Path $usageData 'big-child') 'f.bin'), (New-Object byte[] 5000))
    [IO.File]::WriteAllBytes((Join-Path (Join-Path $usageData 'small-child') 'f.bin'), (New-Object byte[] 100))
    $usageCopy = Copy-UnguardedScript -Script $diskUsage -Directory $usageBox
    if (-not $usageCopy) {
        Test-Fail 'disk_usage.ps1 : platform guard not found verbatim, so the end-to-end check could not run; update the guard text in contract.ps1'
    } else {
        $run = Invoke-InScratch -Path $usageCopy -Arguments @('tree', '-Path', $usageData, '-Depth', '1', '-MinSizeMB', '0')
        $bigAt = $run.Output.IndexOf('big-child')
        $smallAt = $run.Output.IndexOf('small-child')
        if ($run.ExitCode -eq 0 -and $bigAt -ge 0 -and $smallAt -ge 0 -and $bigAt -lt $smallAt) {
            Test-Ok 'disk_usage.ps1 tree lists both children, the larger first'
        } else {
            Test-Fail "disk_usage.ps1 tree: exited $($run.ExitCode), big-child at $bigAt, small-child at $smallAt (both expected, big first)"
            foreach ($line in ($run.Output -split "`n" | Select-Object -First 8)) {
                Write-Host "       $line" -ForegroundColor Red
            }
        }

        $run = Invoke-InScratch -Path $usageCopy -Arguments @('hotspots', '-MinSizeMB', '0')
        if ($run.ExitCode -eq 0 -and $run.Output -match '(?m)^(SKIP |FOUND) ') {
            Test-Ok 'disk_usage.ps1 hotspots ran to the end and printed its FOUND / SKIP rows'
        } else {
            Test-Fail "disk_usage.ps1 hotspots: exited $($run.ExitCode), or printed no FOUND / SKIP row"
            foreach ($line in ($run.Output -split "`n" | Select-Object -First 8)) {
                Write-Host "       $line" -ForegroundColor Red
            }
        }
    }
    Remove-Item -Path $usageBox -Recurse -Force -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------------------
Write-Section 'disk_usage cannot delete'
# The read-only AST check above already covers it by role; this says it in so
# many words, because "the report tool deleted something" is the one failure
# it must never have.
if (-not $diskUsage) {
    Test-Fail 'disk_usage.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $usageText = Get-Content -Raw -Path $diskUsage.FullName
    $deleters = @(@('Remove-Item', 'Clear-RecycleBin', 'Clear-Content', '.Delete(') | Where-Object { $usageText.Contains($_) })
    if ($deleters.Count -eq 0) {
        Test-Ok 'disk_usage.ps1 contains no deleting command, not even in a comment'
    } else {
        Test-Fail "disk_usage.ps1 contains $($deleters -join ', ')"
    }
}

# --------------------------------------------------------------------------
Write-Section 'dev_env_doctor parses clock skew'
$devDoctor = Find-ContractScript 'dev_env_doctor.ps1'
if (-not $devDoctor) {
    Test-Fail 'dev_env_doctor.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $src = Get-ScriptFunctionSource -Script $devDoctor -Name 'ConvertFrom-StripchartOffset'
    if (-not $src) {
        Test-Fail 'dev_env_doctor.ps1 : ConvertFrom-StripchartOffset not found - this check has stopped checking'
    } else {
        . ([scriptblock]::Create($src))
        $skewCases = @(
            @{ Line = '14:10:55, +00.0012345s'; Expect = 0.0012345 }
            @{ Line = '14:10:55, -12.5000000s'; Expect = -12.5 }
            @{ Line = '14:10:55, +00,2500000s'; Expect = 0.25 }
            @{ Line = '14:10:55, error: 0x80072746'; Expect = $null }
            @{ Line = 'Tracking time.windows.com [20.101.57.9:123].'; Expect = $null }
            @{ Line = ''; Expect = $null }
        )
        foreach ($case in $skewCases) {
            $got = ConvertFrom-StripchartOffset -Line $case.Line
            if ($null -eq $case.Expect) {
                $pass = ($null -eq $got)
            } else {
                $pass = ($null -ne $got) -and ([math]::Abs($got - $case.Expect) -lt 1e-9)
            }
            if ($pass) {
                Test-Ok ("'{0}' -> {1}" -f $case.Line, $(if ($null -eq $got) { '$null' } else { $got }))
            } else {
                Test-Fail ("'{0}' gave {1}, expected {2}" -f $case.Line, $got, $case.Expect)
            }
        }
    }
}

# --------------------------------------------------------------------------
Write-Section 'dev_env_doctor grades git config'
if (-not $devDoctor) {
    Test-Fail 'dev_env_doctor.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $src = Get-ScriptFunctionSource -Script $devDoctor -Name 'Get-GitFinding'
    if (-not $src) {
        Test-Fail 'dev_env_doctor.ps1 : Get-GitFinding not found - this check has stopped checking'
    } else {
        . ([scriptblock]::Create($src))
        $goodGit = @{
            'core.autocrlf' = 'input'; 'core.symlinks' = 'true'; 'core.longpaths' = 'true'
            'credential.helper' = 'manager'; 'core.eol' = ''; 'user.name' = 'Alice'
        }
        $gitCases = @(
            @{ Label = 'autocrlf=true'; Change = @{ 'core.autocrlf' = 'true' }; DevMode = $false; Warn = 'autocrlf' }
            @{ Label = 'autocrlf=input'; Change = @{ 'core.autocrlf' = 'input' }; DevMode = $false; Warn = '' }
            @{ Label = 'no credential helper'; Change = @{ 'credential.helper' = '' }; DevMode = $false; Warn = 'credential-helper' }
            @{ Label = 'symlinks off with Developer Mode on'; Change = @{ 'core.symlinks' = 'false' }; DevMode = $true; Warn = 'symlinks' }
            @{ Label = 'symlinks off with Developer Mode off'; Change = @{ 'core.symlinks' = 'false' }; DevMode = $false; Warn = '' }
            @{ Label = 'everything as recommended'; Change = @{}; DevMode = $true; Warn = '' }
        )
        $gitRan = 0
        foreach ($case in $gitCases) {
            $config = $goodGit.Clone()
            foreach ($key in $case.Change.Keys) { $config[$key] = $case.Change[$key] }
            $warned = @(Get-GitFinding -Config $config -DeveloperMode $case.DevMode |
                Where-Object { $_.Level -eq 'warn' } | ForEach-Object { $_.Id })
            $gitRan++
            $expected = @($case.Warn | Where-Object { $_ })
            if (($warned -join ' ') -eq ($expected -join ' ')) {
                Test-Ok ("{0} -> warnings [{1}]" -f $case.Label, ($warned -join ' '))
            } else {
                Test-Fail ("{0}: warnings [{1}], expected [{2}]" -f $case.Label, ($warned -join ' '), ($expected -join ' '))
            }
        }
        $fixless = @(Get-GitFinding -Config @{ 'core.autocrlf' = 'true'; 'credential.helper' = '' } -DeveloperMode $true |
            Where-Object { $_.Level -eq 'warn' -and -not $_.Fix })
        if ($fixless.Count -eq 0) {
            Test-Ok 'every git warning carries the command that fixes it'
        } else {
            Test-Fail "git warnings without a fix: $(@($fixless | ForEach-Object { $_.Id }) -join ', ')"
        }
        if ($gitRan -lt 5) {
            Test-Fail "only $gitRan git case(s) ran - this check has stopped checking"
        }
    }
}

# --------------------------------------------------------------------------
Write-Section 'dev_env_doctor section selection'
if (-not $devDoctor) {
    Test-Fail 'dev_env_doctor.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $listed = Invoke-InScratch -Path $devDoctor.FullName -Arguments @('-ListSections')
    $ids = @($listed.Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $wantIds = @('paths', 'git', 'virtualization', 'time', 'shell', 'containers')
    if ($listed.ExitCode -eq 0 -and ($ids -join ',') -eq ($wantIds -join ',')) {
        Test-Ok 'dev_env_doctor.ps1 -ListSections prints the six ids in order and exits 0'
    } else {
        Test-Fail "dev_env_doctor.ps1 -ListSections exited $($listed.ExitCode) and printed [$($ids -join ',')]"
    }
    foreach ($case in @(
            @{ Arguments = @('-Only', 'bogus'); Code = 3; Mention = 'bogus'; Label = '-Only bogus' }
            @{ Arguments = @('-Only', ','); Code = 4; Mention = ''; Label = "-Only ','" }
            @{ Arguments = @('-MaxSkewSeconds', '0'); Code = 3; Mention = 'MaxSkewSeconds'; Label = '-MaxSkewSeconds 0' }
        )) {
        $run = Invoke-InScratch -Path $devDoctor.FullName -Arguments $case.Arguments
        if ($run.ExitCode -eq $case.Code -and (-not $case.Mention -or $run.Output -match $case.Mention)) {
            Test-Ok "dev_env_doctor.ps1 $($case.Label) exits $($case.Code), before the platform guard"
        } else {
            Test-Fail "dev_env_doctor.ps1 $($case.Label): exited $($run.ExitCode), expected $($case.Code)"
        }
    }
}

# --------------------------------------------------------------------------
Write-Section 'dev_env_doctor runs end to end'
# git, shell and containers only: they read git, the environment and
# Get-Command, all of which answer on Linux. The registry and CIM sections are
# left out here because how Test-Path on HKLM: behaves under pwsh on Linux
# with ErrorActionPreference Stop has not been verified, and an unverified
# assumption is not something to build a passing check on. No assertion about
# warnings: a runner may lack docker or have autocrlf=true.
if (-not $devDoctor) {
    Test-Fail 'dev_env_doctor.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $devBox = Join-Path ([IO.Path]::GetTempPath()) ('windev_' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $devBox -Force | Out-Null
    $devCopy = Copy-UnguardedScript -Script $devDoctor -Directory $devBox
    if (-not $devCopy) {
        Test-Fail 'dev_env_doctor.ps1 : platform guard not found verbatim, so the end-to-end check could not run; update the guard text in contract.ps1'
    } else {
        $run = Invoke-InScratch -Path $devCopy -Arguments @('-Only', 'git,shell,containers')
        $missing = @(@('== git ==', '== shell ==', '== containers ==') | Where-Object { $run.Output -notlike "*$_*" })
        $extra = @(@('== paths ==', '== virtualization ==', '== time ==') | Where-Object { $run.Output -like "*$_*" })
        if ($run.ExitCode -eq 0 -and $missing.Count -eq 0 -and $extra.Count -eq 0) {
            Test-Ok 'dev_env_doctor.ps1 -Only git,shell,containers ran exactly those three sections'
        } else {
            Test-Fail ("dev_env_doctor.ps1 end to end: exited {0}, missing [{1}], unexpected [{2}]" -f $run.ExitCode, ($missing -join ' '), ($extra -join ' '))
            foreach ($line in ($run.Output -split "`n" | Select-Object -First 8)) {
                Write-Host "       $line" -ForegroundColor Red
            }
        }
    }
    Remove-Item -Path $devBox -Recurse -Force -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------------------
Write-Section 'path_doctor grades a PATH'
# The disk and the environment are injected, so these cases mean the same on
# every runner and touch neither the registry nor the filesystem.
$pathDoctor = Find-ContractScript 'path_doctor.ps1'
$fakeExists = { param([string]$Folder) $Folder -notmatch 'gone' -and $Folder -notmatch '^Q:' }
$fakeExpand = { param([string]$Text) $Text -replace '%USERPROFILE%', 'C:\Users\alice' }
if (-not $pathDoctor) {
    Test-Fail 'path_doctor.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $src = Get-ScriptFunctionSource -Script $pathDoctor -Name 'Get-PathFinding'
    if (-not $src) {
        Test-Fail 'path_doctor.ps1 : Get-PathFinding not found - this check has stopped checking'
    } else {
        . ([scriptblock]::Create($src))
        $fixtureEntries = @('C:\Tools', 'c:\tools\', '', 'C:\gone', 'bin', '"C:\Program Files\x"', '%USERPROFILE%\bin')
        $findingCases = @(
            @{ Label = 'a REG_SZ PATH with one of everything'; Entries = $fixtureEntries; Kind = 'String'; Length = 100; Other = @()
               Expect = @('duplicate', 'empty-entry', 'missing-dir', 'quoted-entry', 'relative-entry', 'unexpanded-var') }
            @{ Label = 'the same PATH as REG_EXPAND_SZ'; Entries = $fixtureEntries; Kind = 'ExpandString'; Length = 100; Other = @()
               Expect = @('duplicate', 'empty-entry', 'missing-dir', 'quoted-entry', 'relative-entry') }
            @{ Label = 'a clean PATH'; Entries = @('C:\Windows\System32', '%USERPROFILE%\bin'); Kind = 'ExpandString'; Length = 100; Other = @()
               Expect = @() }
            @{ Label = '1100 characters'; Entries = @('C:\Tools'); Kind = 'ExpandString'; Length = 1100; Other = @()
               Expect = @('too-long:warn') }
            @{ Label = '2100 characters'; Entries = @('C:\Tools'); Kind = 'ExpandString'; Length = 2100; Other = @()
               Expect = @('too-long:warn') }
            @{ Label = 'over the 32767 limit'; Entries = @('C:\Tools'); Kind = 'ExpandString'; Length = 40000; Other = @()
               Expect = @('too-long:fail') }
            @{ Label = 'one folder in both scopes'; Entries = @('C:\Shared'); Kind = 'ExpandString'; Length = 100; Other = @('c:\shared\')
               Expect = @('cross-scope-duplicate') }
        )
        $findingRan = 0
        foreach ($case in $findingCases) {
            $found = @(Get-PathFinding -Entries $case.Entries -Scope 'User' -Kind $case.Kind -Exists $fakeExists `
                    -Expand $fakeExpand -Length $case.Length -OtherEntries $case.Other)
            $findingRan++
            # A level is asserted only where the case names one.
            $got = @($found | ForEach-Object {
                    if ($_.Code -eq 'too-long') { '{0}:{1}' -f $_.Code, $_.Level } else { $_.Code }
                } | Sort-Object -Unique)
            $want = @($case.Expect | Sort-Object)
            if (($got -join ' ') -eq ($want -join ' ')) {
                Test-Ok ("{0} -> [{1}]" -f $case.Label, ($got -join ' '))
            } else {
                Test-Fail ("{0}: got [{1}], expected [{2}]" -f $case.Label, ($got -join ' '), ($want -join ' '))
            }
        }
        $dup = @(Get-PathFinding -Entries $fixtureEntries -Scope 'User' -Kind 'ExpandString' -Exists $fakeExists `
                -Expand $fakeExpand -Length 100 | Where-Object { $_.Code -eq 'duplicate' })
        if ($dup.Count -eq 1 -and $dup[0].Message -match 'repeats entry 1') {
            Test-Ok 'a duplicate names the entry it repeats'
        } else {
            Test-Fail 'the duplicate finding does not name the first occurrence'
        }
        # The report must follow clean's rule: an entry clean cannot judge never
        # makes a later judgeable equivalent a duplicate.
        $toolsExpand = { param([string]$Text) $Text -replace '%TOOLS%', 'C:\Tools' }
        $ruleCases = @(
            @{ Label = 'REG_SZ %TOOLS% then C:\Tools'; Entries = @('%TOOLS%', 'C:\Tools'); Kind = 'String'; Want = 0 }
            @{ Label = 'REG_EXPAND_SZ %TOOLS% then C:\Tools'; Entries = @('%TOOLS%', 'C:\Tools'); Kind = 'ExpandString'; Want = 0 }
            @{ Label = 'quoted then unquoted C:\Tools'; Entries = @('"C:\Tools"', 'C:\Tools'); Kind = 'ExpandString'; Want = 0 }
            @{ Label = 'quoted, unquoted, then a repeat of the unquoted'; Entries = @('"C:\Tools"', 'C:\Tools', 'c:\tools\'); Kind = 'ExpandString'; Want = 1 }
        )
        foreach ($rule in $ruleCases) {
            $ruleDup = @(Get-PathFinding -Entries $rule.Entries -Scope 'User' -Kind $rule.Kind -Exists $fakeExists `
                    -Expand $toolsExpand -Length 100 | Where-Object { $_.Code -eq 'duplicate' })
            if ($ruleDup.Count -eq $rule.Want) {
                Test-Ok "report matches clean: $($rule.Label) -> $($rule.Want) duplicate(s)"
            } else {
                Test-Fail "report differs from clean: $($rule.Label) gave $($ruleDup.Count) duplicate(s), expected $($rule.Want)"
            }
        }
        if ($findingRan -lt 7) {
            Test-Fail "only $findingRan PATH case(s) ran - this check has stopped checking"
        }
    }
}

# --------------------------------------------------------------------------
Write-Section 'path_doctor computes the cleaned value'
if (-not $pathDoctor) {
    Test-Fail 'path_doctor.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $src = Get-ScriptFunctionSource -Script $pathDoctor -Name 'Get-CleanedPath'
    if (-not $src) {
        Test-Fail 'path_doctor.ps1 : Get-CleanedPath not found - this check has stopped checking'
    } else {
        . ([scriptblock]::Create($src))
        $dirty = @('C:\Tools', '', 'C:\gone', 'c:\tools\', '%USERPROFILE%\gone', 'relative', 'Q:\unplugged\tools', 'D:\keep', 'relative')
        $cleaned = Get-CleanedPath -Entries $dirty -Exists $fakeExists -Expand $fakeExpand
        $wantValue = 'C:\Tools;%USERPROFILE%\gone;relative;Q:\unplugged\tools;D:\keep;relative'
        if ($cleaned.Value -ceq $wantValue) {
            Test-Ok 'empty, repeated and missing entries go; order and the original text stay'
        } else {
            Test-Fail "cleaned PATH was [$($cleaned.Value)], expected [$wantValue]"
        }
        $reasons = @($cleaned.Removed | ForEach-Object { '{0}={1}' -f $_.Entry, $_.Reason }) -join ' | '
        $wantReasons = '=empty | C:\gone=missing | c:\tools\=duplicate'
        if ($reasons -eq $wantReasons) {
            Test-Ok 'each removal carries its reason'
        } else {
            Test-Fail "removals were [$reasons], expected [$wantReasons]"
        }
        if ($cleaned.Value -match '%USERPROFILE%\\gone' -and $cleaned.Value -match 'Q:\\unplugged') {
            Test-Ok 'an entry with a %VARIABLE% and a folder on an absent drive are kept: neither can be judged'
        } else {
            Test-Fail 'an entry clean cannot judge was removed'
        }
        # REG_SZ: Windows never expands %VAR%, so the absolute entry that follows
        # it is a different, working folder and must survive.
        $szProbe = Get-CleanedPath -Entries @('%TOOLS%', 'C:\Tools') -Exists $fakeExists -Expand { param([string]$Text) $Text -replace '%TOOLS%', 'C:\Tools' } -Kind 'String'
        if ($szProbe.Value -ceq '%TOOLS%;C:\Tools' -and @($szProbe.Removed).Count -eq 0) {
            Test-Ok 'REG_SZ: an unexpanded %VAR% entry never makes the later absolute entry a duplicate'
        } else {
            Test-Fail "REG_SZ clean returned [$($szProbe.Value)], expected [%TOOLS%;C:\Tools]"
        }
        $expProbe = Get-CleanedPath -Entries @('%TOOLS%', 'C:\Tools') -Exists $fakeExists -Expand { param([string]$Text) $Text -replace '%TOOLS%', 'C:\Tools' } -Kind 'ExpandString'
        if ($expProbe.Value -ceq '%TOOLS%;C:\Tools' -and @($expProbe.Removed).Count -eq 0) {
            Test-Ok 'REG_EXPAND_SZ: an entry clean cannot judge never makes the later judgeable entry a duplicate'
        } else {
            Test-Fail "REG_EXPAND_SZ clean returned [$($expProbe.Value)], expected [%TOOLS%;C:\Tools]"
        }
        $quotedProbe = Get-CleanedPath -Entries @('"C:\Tools"', 'C:\Tools', 'c:\tools\') -Exists $fakeExists -Expand $fakeExpand
        if ($quotedProbe.Value -ceq '"C:\Tools";C:\Tools' -and @($quotedProbe.Removed).Count -eq 1 -and $quotedProbe.Removed[0].Entry -ceq 'c:\tools\') {
            Test-Ok 'a quoted entry never makes the later unquoted copy a duplicate; the unquoted copy is kept and repeats of it go'
        } else {
            Test-Fail "quoted-entry clean returned [$($quotedProbe.Value)], expected [`"C:\Tools`";C:\Tools]"
        }
        $again = Get-CleanedPath -Entries ($cleaned.Value -split ';') -Exists $fakeExists -Expand $fakeExpand
        if (@($again.Removed).Count -eq 0 -and $again.Value -ceq $cleaned.Value) {
            Test-Ok 'cleaning the cleaned value removes nothing (idempotent)'
        } else {
            Test-Fail "a second clean removed $(@($again.Removed).Count) more entr(ies)"
        }
    }
}

# --------------------------------------------------------------------------
Write-Section 'path_doctor spots shadowed commands'
if (-not $pathDoctor) {
    Test-Fail 'path_doctor.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $src = Get-ScriptFunctionSource -Script $pathDoctor -Name 'Get-ShadowFinding'
    if (-not $src) {
        Test-Fail 'path_doctor.ps1 : Get-ShadowFinding not found - this check has stopped checking'
    } else {
        . ([scriptblock]::Create($src))
        $shadow = @(Get-ShadowFinding -Resolved @{
                python = @('C:\Users\alice\AppData\Local\Microsoft\WindowsApps\python.exe', 'C:\Python312\python.exe')
                find   = @('C:\Program Files\Git\usr\bin\find.exe', 'C:\Windows\System32\find.exe')
                sort   = @('C:\Windows\System32\sort.exe', 'C:\Program Files\Git\usr\bin\sort.exe')
                git    = @('C:\Program Files\Git\cmd\git.exe')
                node   = @('C:\a\node.exe', 'C:\b\node.exe')
            })
        $byName = @{}
        foreach ($finding in $shadow) { $byName[$finding.Name] = $finding }
        $shadowChecks = @(
            @{ Name = 'python'; Code = 'store-alias'; Label = 'the Store alias ahead of a real Python is a warning' }
            @{ Name = 'find'; Code = 'msys-shadow'; Label = "Git's MSYS find ahead of System32 is a warning" }
            @{ Name = 'sort'; Code = 'first-wins'; Label = 'System32 sort ahead of the MSYS one is only information' }
            @{ Name = 'node'; Code = 'first-wins'; Label = 'two ordinary copies are listed, first wins' }
        )
        foreach ($check in $shadowChecks) {
            $finding = $byName[$check.Name]
            if ($finding -and $finding.Code -eq $check.Code) {
                Test-Ok $check.Label
            } else {
                Test-Fail ("{0}: got {1}" -f $check.Label, $(if ($finding) { $finding.Code } else { 'nothing' }))
            }
        }
        if (-not $byName.ContainsKey('git')) {
            Test-Ok 'a command that resolves once produces no finding'
        } else {
            Test-Fail 'a command with a single resolution produced a finding'
        }
        if ($byName['node'] -and $byName['node'].Message -match [regex]::Escape('C:\a\node.exe > C:\b\node.exe')) {
            Test-Ok 'the first-wins line keeps PATH order'
        } else {
            Test-Fail 'the first-wins line does not list the copies in PATH order'
        }
    }
}

# --------------------------------------------------------------------------
Write-Section 'path_doctor needs consent'
if ($onWindows) {
    Test-Skip 'the behavioural half of this check runs only off Windows: it proves the gate by invoking clean WITHOUT -Yes, and on Windows a gate that had regressed would rewrite the user PATH of the machine running the suite'
} elseif (-not $pathDoctor) {
    Test-Fail 'path_doctor.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $consentBox = Join-Path ([IO.Path]::GetTempPath()) ('winpath_' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $consentBox -Force | Out-Null
    $pathCopy = Copy-UnguardedScript -Script $pathDoctor -Directory $consentBox
    if (-not $pathCopy) {
        Test-Fail 'path_doctor.ps1 : platform guard not found verbatim, so the consent check could not run; update the guard text in contract.ps1'
    } else {
        $bare = Invoke-InScratch -Path $pathCopy -Arguments @('clean')
        if ($bare.ExitCode -eq 3 -and $bare.Output -match '-Yes' -and $bare.Output -match '-DryRun') {
            Test-Ok 'path_doctor.ps1 clean with neither -Yes nor -DryRun refuses, exits 3 and names both'
        } else {
            Test-Fail "path_doctor.ps1 clean with no consent must exit 3 naming -Yes and -DryRun; it exited $($bare.ExitCode)"
        }
        $machine = Invoke-InScratch -Path $pathCopy -Arguments @('clean', '-Scope', 'Machine', '-DryRun')
        if ($machine.ExitCode -eq 3) {
            Test-Ok 'path_doctor.ps1 clean -Scope Machine is refused (exit 3)'
        } else {
            Test-Fail "path_doctor.ps1 clean -Scope Machine must be refused with exit 3; it exited $($machine.ExitCode)"
        }
        # Past the gate the first thing clean does is read the registry, which
        # does not exist here: it has to say so and stop, not throw.
        $preview = Invoke-InScratch -Path $pathCopy -Arguments @('clean', '-DryRun')
        if ($preview.ExitCode -in 0, 1 -and $preview.Output -match 'could not read' -and $preview.Output -notmatch 'at <ScriptBlock>') {
            Test-Ok 'path_doctor.ps1 clean -DryRun reaches the registry read and reports it cleanly when it cannot'
        } else {
            Test-Fail "path_doctor.ps1 clean -DryRun off Windows: exited $($preview.ExitCode); expected 0 or 1 with 'could not read' and no stack trace"
            foreach ($line in ($preview.Output -split "`n" | Select-Object -First 5)) {
                Write-Host "       $line" -ForegroundColor Red
            }
        }
    }
    Remove-Item -Path $consentBox -Recurse -Force -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------------------
Write-Section 'hardening_audit grades facts'
# Every probe lands in one hashtable, so the grading can be driven entirely by
# fixtures: a good machine must pass everything, each check must fail or warn
# on its own bad value and say how to fix it, and a machine where nothing could
# be read must produce skips rather than verdicts. The check list comes from
# the script itself, so a check added without a bad fixture here fails.
$hardening = Find-ContractScript 'hardening_audit.ps1'

# A fresh good fact set each call, so one case's change cannot leak into the
# next through a shared nested hashtable.
function Get-GoodAuditFact {
    param([datetime]$Now)
    return @{
        Elevated               = $true
        Now                    = $Now
        FirewallProfiles       = @{
            Domain  = @{ Enabled = $true; Inbound = 'Block' }
            Private = @{ Enabled = $true; Inbound = 'NotConfigured' }
            Public  = @{ Enabled = $true; Inbound = 'Block' }
        }
        Smb1Enabled            = $false
        LlmnrMulticast         = 0
        RdpDeny                = 1
        RdpNla                 = 1
        TrustedHosts           = ''
        SshdConfig             = @{ passwordauthentication = 'no'; permitemptypasswords = 'no' }
        EnableLua              = 1
        ConsentPromptAdmin     = 5
        AutoAdminLogon         = '0'
        DefaultPasswordPresent = $false
        GuestEnabled           = $false
        LocalAdmins            = @(@{ Sid = 'S-1-5-21-1-2-3-500'; Name = 'PC\Administrator' })
        SecureBoot             = $true
        Tpm                    = @{ Present = $true; Ready = $true }
        RunAsPpl               = 1
        VbsStatus              = 2
        Defender               = @{ Rtp = $true; Tamper = $true; SignatureAge = 1; Pua = 1; NetworkProtection = 1 }
        ScriptBlockLogging     = 1
        NewestHotfix           = $Now.AddDays(-10)
        RebootPending          = $false
    }
}

if (-not $hardening) {
    Test-Fail 'hardening_audit.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $gradeSrc = Get-ScriptFunctionSource -Script $hardening -Name 'Test-AuditFact'
    $idSrc = Get-ScriptFunctionSource -Script $hardening -Name 'Get-AuditCheckId'
    if (-not $gradeSrc -or -not $idSrc) {
        Test-Fail 'hardening_audit.ps1 : Test-AuditFact or Get-AuditCheckId not found - this check has stopped checking'
    } else {
        . ([scriptblock]::Create($gradeSrc))
        . ([scriptblock]::Create($idSrc))
        $auditNow = [datetime]'2026-10-01T12:00:00'
        $checkIds = @(Get-AuditCheckId | ForEach-Object { $_.Id })

        $goodFindings = @(Test-AuditFact -Facts (Get-GoodAuditFact -Now $auditNow))
        $goodBad = @($goodFindings | Where-Object { $_.Level -in 'warn', 'fail' })
        if ($goodBad.Count -eq 0) {
            Test-Ok "a well-configured machine passes all $($goodFindings.Count) checks"
        } else {
            Test-Fail "a well-configured machine got: $(@($goodBad | ForEach-Object { '{0}={1}' -f $_.Id, $_.Level }) -join ', ')"
        }
        $gradedIds = @($goodFindings | ForEach-Object { $_.Id })
        if (($gradedIds -join ' ') -eq ($checkIds -join ' ')) {
            Test-Ok 'Test-AuditFact grades exactly the ids Get-AuditCheckId lists, once each, in order'
        } else {
            Test-Fail "Test-AuditFact graded [$($gradedIds -join ' ')] but Get-AuditCheckId lists [$($checkIds -join ' ')]"
        }

        # One bad value per check id.
        $badFacts = @{
            'fw-domain'           = { param($f) $f.FirewallProfiles.Domain.Enabled = $false }
            'fw-private'          = { param($f) $f.FirewallProfiles.Private.Inbound = 'Allow' }
            'fw-public'           = { param($f) $f.FirewallProfiles.Public.Enabled = $false }
            'smb1'                = { param($f) $f.Smb1Enabled = $true }
            'llmnr'               = { param($f) $f.LlmnrMulticast = 'absent' }
            'rdp-enabled'         = { param($f) $f.RdpDeny = 0 }
            'rdp-nla'             = { param($f) $f.RdpDeny = 0; $f.RdpNla = 0 }
            'winrm-trustedhosts'  = { param($f) $f.TrustedHosts = '*' }
            'sshd-password'       = { param($f) $f.SshdConfig = @{} }
            'sshd-empty-password' = { param($f) $f.SshdConfig = @{ passwordauthentication = 'no'; permitemptypasswords = 'yes' } }
            'uac-lua'             = { param($f) $f.EnableLua = 0 }
            'uac-prompt'          = { param($f) $f.ConsentPromptAdmin = 0 }
            'autologon'           = { param($f) $f.AutoAdminLogon = '1' }
            'autologon-password'  = { param($f) $f.DefaultPasswordPresent = $true }
            'guest-enabled'       = { param($f) $f.GuestEnabled = $true }
            'local-admins-broad'  = { param($f) $f.LocalAdmins = @($f.LocalAdmins) + @(@{ Sid = 'S-1-1-0'; Name = 'Everyone' }) }
            'secureboot'          = { param($f) $f.SecureBoot = $false }
            'tpm'                 = { param($f) $f.Tpm = @{ Present = $false; Ready = $false } }
            'lsa-ppl'             = { param($f) $f.RunAsPpl = 'absent' }
            'vbs'                 = { param($f) $f.VbsStatus = 0 }
            'defender-rtp'        = { param($f) $f.Defender.Rtp = $false }
            'defender-tamper'     = { param($f) $f.Defender.Tamper = $false }
            'defender-sigs'       = { param($f) $f.Defender.SignatureAge = 30 }
            'defender-pua'        = { param($f) $f.Defender.Pua = 0 }
            'defender-netprot'    = { param($f) $f.Defender.NetworkProtection = 2 }
            'ps-scriptblock'      = { param($f) $f.ScriptBlockLogging = 'absent' }
            'hotfix-age'          = { param($f) $f.NewestHotfix = $f.Now.AddDays(-200) }
            'reboot-pending'      = { param($f) $f.RebootPending = $true }
        }
        $uncovered = @($checkIds | Where-Object { -not $badFacts.ContainsKey($_) })
        if ($uncovered.Count -gt 0) {
            Test-Fail "check id(s) with no bad fixture here: $($uncovered -join ', ') - add one to `$badFacts"
        }
        foreach ($id in $checkIds) {
            if (-not $badFacts.ContainsKey($id)) { continue }
            $facts = Get-GoodAuditFact -Now $auditNow
            & $badFacts[$id] $facts
            $verdict = @(Test-AuditFact -Facts $facts | Where-Object { $_.Id -eq $id })
            if ($verdict.Count -eq 1 -and $verdict[0].Level -in 'warn', 'fail' -and $verdict[0].Fix) {
                Test-Ok ("{0}: {1}, with a fix" -f $id, $verdict[0].Level)
            } else {
                Test-Fail ("{0}: its bad fixture gave {1} with fix '{2}'; expected warn or fail with a fix" -f $id, (@($verdict | ForEach-Object { $_.Level }) -join ','), (@($verdict | ForEach-Object { $_.Fix }) -join ''))
            }
        }

        foreach ($list in @('host1,*', ' * ', 'host1, *, host2')) {
            $facts = Get-GoodAuditFact -Now $auditNow
            $facts.TrustedHosts = $list
            $v = @(Test-AuditFact -Facts $facts | Where-Object { $_.Id -eq 'winrm-trustedhosts' })
            if ($v.Count -eq 1 -and $v[0].Level -eq 'fail') {
                Test-Ok "TrustedHosts '$list' is a wildcard: fail"
            } else {
                Test-Fail "TrustedHosts '$list' gave $(@($v | ForEach-Object { $_.Level }) -join ','), expected fail"
            }
        }
        $facts = Get-GoodAuditFact -Now $auditNow
        $facts.TrustedHosts = 'host1,*.corp.example'
        $v = @(Test-AuditFact -Facts $facts | Where-Object { $_.Id -eq 'winrm-trustedhosts' })
        if ($v.Count -eq 1 -and $v[0].Level -eq 'pass') {
            Test-Ok 'TrustedHosts with a scoped pattern but no bare * passes'
        } else {
            Test-Fail "TrustedHosts 'host1,*.corp.example' gave $(@($v | ForEach-Object { $_.Level }) -join ','), expected pass"
        }

        try {
            $blind = @(Test-AuditFact -Facts @{ Elevated = $false })
            $notSkipped = @($blind | Where-Object { $_.Level -ne 'skip' })
            if ($blind.Count -eq $checkIds.Count -and $notSkipped.Count -eq 0 -and ($blind.Message -match 'needs elevation')) {
                Test-Ok 'a machine where nothing could be read gets a skip for every check, saying it needs elevation'
            } else {
                Test-Fail "with no facts, $($notSkipped.Count) check(s) gave a verdict: $(@($notSkipped | ForEach-Object { $_.Id }) -join ', ')"
            }
        } catch {
            Test-Fail "Test-AuditFact threw on an empty fact set: $($_.Exception.Message)"
        }
    }
}

# --------------------------------------------------------------------------
Write-Section 'hardening_audit exit code'
if (-not $hardening) {
    Test-Fail 'hardening_audit.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $src = Get-ScriptFunctionSource -Script $hardening -Name 'Get-AuditExitCode'
    if (-not $src) {
        Test-Fail 'hardening_audit.ps1 : Get-AuditExitCode not found - this check has stopped checking'
    } else {
        . ([scriptblock]::Create($src))
        $warnOnly = @([pscustomobject]@{ Level = 'pass' }, [pscustomobject]@{ Level = 'warn' })
        $oneFail = @([pscustomobject]@{ Level = 'fail' }, [pscustomobject]@{ Level = 'pass' })
        $skipsOnly = @([pscustomobject]@{ Level = 'skip' }, [pscustomobject]@{ Level = 'skip' })
        foreach ($case in @(
                @{ Findings = $warnOnly; FailOn = 'fail'; Expect = 0; Label = 'a warning with -FailOn fail' }
                @{ Findings = $warnOnly; FailOn = 'warn'; Expect = 1; Label = 'a warning with -FailOn warn' }
                @{ Findings = $oneFail; FailOn = 'fail'; Expect = 1; Label = 'one failure' }
                @{ Findings = $skipsOnly; FailOn = 'warn'; Expect = 0; Label = 'skips only, even with -FailOn warn' }
            )) {
            $got = Get-AuditExitCode -Findings $case.Findings -FailOn $case.FailOn
            if ($got -eq $case.Expect) {
                Test-Ok "$($case.Label) -> exit $got"
            } else {
                Test-Fail "$($case.Label) -> exit $got, expected $($case.Expect)"
            }
        }
    }
}

# --------------------------------------------------------------------------
Write-Section 'hardening_audit reads sshd_config'
if (-not $hardening) {
    Test-Fail 'hardening_audit.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $src = Get-ScriptFunctionSource -Script $hardening -Name 'Get-SshdSetting'
    if (-not $src) {
        Test-Fail 'hardening_audit.ps1 : Get-SshdSetting not found - this check has stopped checking'
    } else {
        . ([scriptblock]::Create($src))
        $sshdFixture = @'
# PasswordAuthentication no
passwordauthentication YES
PasswordAuthentication no
PermitEmptyPasswords=no

Match Group administrators
    PubkeyAuthentication no
    AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys
'@ -split "`r?`n"
        $settings = Get-SshdSetting -Lines $sshdFixture
        if ($settings['passwordauthentication'] -eq 'YES') {
            Test-Ok 'the first occurrence wins, the keyword is case-insensitive, and a comment is not a setting'
        } else {
            Test-Fail "passwordauthentication read as '$($settings['passwordauthentication'])', expected the first live line's YES"
        }
        if ($settings['permitemptypasswords'] -eq 'no') {
            Test-Ok 'the Keyword=value form is read'
        } else {
            Test-Fail "permitemptypasswords read as '$($settings['permitemptypasswords'])'"
        }
        if (-not $settings.ContainsKey('pubkeyauthentication') -and -not $settings.ContainsKey('authorizedkeysfile')) {
            Test-Ok 'nothing inside a Match block is read as a global setting'
        } else {
            Test-Fail 'a setting from inside a Match block was read as global'
        }

        # Include: followed in order, relative to the config folder, with
        # wildcards, nesting and the first value winning across files.
        $incBox = Join-Path ([IO.Path]::GetTempPath()) ('winsshd_' + [Guid]::NewGuid().ToString('N'))
        $incDir = Join-Path $incBox 'sshd_config.d'
        New-Item -ItemType Directory -Path $incDir -Force | Out-Null
        $writeInc = { param($Path, $Text) [IO.File]::WriteAllText($Path, $Text) }
        & $writeInc (Join-Path $incDir '10-first.conf') "PasswordAuthentication no`nInclude nested.conf`n"
        & $writeInc (Join-Path $incDir '20-second.conf') "PasswordAuthentication yes`nPermitEmptyPasswords yes`n"
        & $writeInc (Join-Path $incBox 'nested.conf') "PermitEmptyPasswords no`nPubkeyAuthentication yes`n"
        $main = @('Include sshd_config.d/*.conf', 'PasswordAuthentication yes', 'PermitEmptyPasswords yes', 'Port 22')
        $r = Get-SshdSetting -Lines $main -BaseDir $incBox
        if ($r['passwordauthentication'] -eq 'no') {
            Test-Ok 'an Include (relative, wildcard) is read where it stands, and its first value beats a later line'
        } else {
            Test-Fail "passwordauthentication read as '$($r['passwordauthentication'])' through an Include, expected no"
        }
        if ($r['permitemptypasswords'] -eq 'no' -and $r['pubkeyauthentication'] -eq 'yes' -and $r['port'] -eq '22') {
            Test-Ok 'a nested Include is followed in order, and settings after the Includes still count'
        } else {
            Test-Fail "nested Include read permitemptypasswords='$($r['permitemptypasswords'])' pubkeyauthentication='$($r['pubkeyauthentication'])' port='$($r['port'])'"
        }
        $r = Get-SshdSetting -Lines @('PasswordAuthentication no', 'Include sshd_config.d/*.conf') -BaseDir $incBox
        if ($r['passwordauthentication'] -eq 'no' -and $r['permitemptypasswords'] -eq 'no') {
            Test-Ok 'a value set before the Include is not overridden by it'
        } else {
            Test-Fail "a value before an Include was overridden: '$($r['passwordauthentication'])' / '$($r['permitemptypasswords'])'"
        }
        $r = Get-SshdSetting -Lines @('Include "sshd_config.d/10-first.conf" missing.conf nothere/*.conf', 'Port 22') -BaseDir $incBox
        if (-not $r.ContainsKey('#unreadable-include') -and $r['passwordauthentication'] -eq 'no' -and $r['port'] -eq '22') {
            Test-Ok 'a quoted pattern is read, and patterns that match nothing are skipped without an error'
        } else {
            Test-Fail 'a quoted Include or a pattern matching nothing was mishandled'
        }
        $r = Get-SshdSetting -Lines @('Include ' + (Join-Path $incDir '10-first.conf')) -BaseDir (Join-Path $incBox 'elsewhere')
        if ($r['passwordauthentication'] -eq 'no') {
            Test-Ok 'an absolute Include path ignores the config folder'
        } else {
            Test-Fail 'an absolute Include path was not read'
        }
        $r = Get-SshdSetting -Lines @('Include __PROGRAMDATA__/sshd_config.d/10-first.conf') -BaseDir (Join-Path $incBox 'elsewhere') -ProgramData $incBox
        if ($r['passwordauthentication'] -eq 'no') {
            Test-Ok '__PROGRAMDATA__ in an Include path is expanded'
        } else {
            Test-Fail '__PROGRAMDATA__ in an Include path was not expanded'
        }
        $r = Get-SshdSetting -Lines @('Include sshd_config.d')  -BaseDir $incBox
        if ($r.ContainsKey('#unreadable-include')) {
            Test-Ok 'an Include naming a folder cannot be read and is reported'
        } else {
            Test-Fail 'an Include naming a folder was not reported as unreadable'
        }
        $r = Get-SshdSetting -Lines @('Include rel.conf', 'PasswordAuthentication no')
        if ($r.ContainsKey('#unreadable-include') -and -not $r.ContainsKey('passwordauthentication')) {
            Test-Ok 'a relative Include with no config folder is unreadable, and reading stops there'
        } else {
            Test-Fail 'a relative Include with no base folder was not treated as unreadable'
        }
        # Depth: a file that includes itself loops until the limit of 16.
        & $writeInc (Join-Path $incBox 'loop.conf') "PermitEmptyPasswords no`nInclude loop.conf`n"
        $r = Get-SshdSetting -Lines @('Include loop.conf', 'PasswordAuthentication no') -BaseDir $incBox
        if ($r.ContainsKey('#unreadable-include') -and -not $r.ContainsKey('passwordauthentication') -and $r['permitemptypasswords'] -eq 'no') {
            Test-Ok 'an Include loop stops at the depth limit and is reported'
        } else {
            Test-Fail 'an Include loop was not stopped and reported at the depth limit'
        }
        $chainOk = $true
        for ($i = 1; $i -le 16; $i++) {
            $tail = "Include chain$($i + 1).conf`n"
            if ($i -eq 16) { $tail = "PermitEmptyPasswords no`n" }
            & $writeInc (Join-Path $incBox "chain$i.conf") $tail
        }
        $r = Get-SshdSetting -Lines @('Include chain1.conf') -BaseDir $incBox
        if (-not $r.ContainsKey('#unreadable-include') -and $r['permitemptypasswords'] -eq 'no') {
            Test-Ok 'sixteen nested Includes are still followed'
        } else {
            Test-Fail 'a chain of sixteen nested Includes was cut short'
        }
        & $writeInc (Join-Path $incBox 'chain16.conf') "Include chain17.conf`n"
        & $writeInc (Join-Path $incBox 'chain17.conf') "PermitEmptyPasswords no`n"
        $r = Get-SshdSetting -Lines @('Include chain1.conf') -BaseDir $incBox
        if ($r.ContainsKey('#unreadable-include')) {
            Test-Ok 'seventeen nested Includes are past the limit and reported'
        } else {
            Test-Fail 'a chain of seventeen nested Includes was followed past the limit'
        }

        # An unreadable Include must not become a pass.
        $auditSrc = Get-ScriptFunctionSource -Script $hardening -Name 'Test-AuditFact'
        if (-not $auditSrc) {
            Test-Fail 'hardening_audit.ps1 : Test-AuditFact not found - this check has stopped checking'
        } else {
            . ([scriptblock]::Create($auditSrc))
            $levelOf = {
                param($Config, $Id)
                $f = Get-GoodAuditFact -Now ([datetime]'2026-01-01')
                $f.SshdConfig = $Config
                (@(Test-AuditFact -Facts $f | Where-Object { $_.Id -eq $Id }) | ForEach-Object { $_.Level }) -join ','
            }
            $cut = '#unreadable-include'
            $cases = @(
                @{ Label = 'nothing set, an Include unreadable: password check'; Config = @{ $cut = @('x.conf') }; Id = 'sshd-password'; Expect = 'skip' }
                @{ Label = 'nothing set, an Include unreadable: empty-password check'; Config = @{ $cut = @('x.conf') }; Id = 'sshd-empty-password'; Expect = 'skip' }
                @{ Label = 'PasswordAuthentication no set before the unreadable Include'; Config = @{ passwordauthentication = 'no'; $cut = @('x.conf') }; Id = 'sshd-password'; Expect = 'pass' }
                @{ Label = 'PasswordAuthentication yes set before the unreadable Include'; Config = @{ passwordauthentication = 'yes'; $cut = @('x.conf') }; Id = 'sshd-password'; Expect = 'warn' }
                @{ Label = 'PermitEmptyPasswords no set before the unreadable Include'; Config = @{ permitemptypasswords = 'no'; $cut = @('x.conf') }; Id = 'sshd-empty-password'; Expect = 'pass' }
                @{ Label = 'PermitEmptyPasswords yes set before the unreadable Include'; Config = @{ permitemptypasswords = 'yes'; $cut = @('x.conf') }; Id = 'sshd-empty-password'; Expect = 'fail' }
                @{ Label = 'nothing set, every Include read: password check'; Config = @{}; Id = 'sshd-password'; Expect = 'warn' }
                @{ Label = 'nothing set, every Include read: empty-password check'; Config = @{}; Id = 'sshd-empty-password'; Expect = 'pass' }
            )
            foreach ($case in $cases) {
                $got = & $levelOf $case.Config $case.Id
                if ($got -ceq $case.Expect) {
                    Test-Ok ("{0} -> {1}" -f $case.Label, $got)
                } else {
                    Test-Fail ("{0} -> {1}, expected {2}" -f $case.Label, $got, $case.Expect)
                }
            }
        }
        Remove-Item -Path $incBox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --------------------------------------------------------------------------
Write-Section 'hardening_audit usage'
if (-not $hardening) {
    Test-Fail 'hardening_audit.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $listed = Invoke-InScratch -Path $hardening.FullName -Arguments @('-ListGroups')
    $groups = @($listed.Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $wantGroups = @('network', 'remote', 'accounts', 'boot', 'defender', 'logging', 'updates')
    if ($listed.ExitCode -eq 0 -and ($groups -join ',') -eq ($wantGroups -join ',')) {
        Test-Ok 'hardening_audit.ps1 -ListGroups prints the seven groups in order and exits 0'
    } else {
        Test-Fail "hardening_audit.ps1 -ListGroups exited $($listed.ExitCode) and printed [$($groups -join ',')]"
    }
    foreach ($case in @(
            @{ Arguments = @('-Only', 'bogus'); Mention = 'bogus'; Label = '-Only bogus' }
            @{ Arguments = @('-FailOn', 'bogus'); Mention = 'bogus'; Label = '-FailOn bogus' }
        )) {
        $run = Invoke-InScratch -Path $hardening.FullName -Arguments $case.Arguments
        if ($run.ExitCode -eq 3 -and $run.Output -match $case.Mention) {
            Test-Ok "hardening_audit.ps1 $($case.Label) exits 3, before the platform guard"
        } else {
            Test-Fail "hardening_audit.ps1 $($case.Label): exited $($run.ExitCode), expected 3"
        }
    }
}

# --------------------------------------------------------------------------
Write-Section 'hardening_audit runs end to end'
# logging and updates are the two groups whose probes are a registry read and
# Get-HotFix. Off Windows neither exists, so every check must come back a
# skip and the exit code 0: an unreadable machine is not a failing one. On
# windows-2025 the runner may genuinely fail a check, so 1 is accepted there.
if (-not $hardening) {
    Test-Fail 'hardening_audit.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $auditBox = Join-Path ([IO.Path]::GetTempPath()) ('winaudit_' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $auditBox -Force | Out-Null
    $auditCopy = Copy-UnguardedScript -Script $hardening -Directory $auditBox
    if (-not $auditCopy) {
        Test-Fail 'hardening_audit.ps1 : platform guard not found verbatim, so the end-to-end check could not run; update the guard text in contract.ps1'
    } else {
        $run = Invoke-InScratch -Path $auditCopy -Arguments @('-Only', 'logging,updates', '-FailOn', 'fail')
        $allowed = @(0, 1)
        if (-not $onWindows) { $allowed = @(0) }
        if ($run.ExitCode -in $allowed -and $run.Output -match '\[(skip|pass)\]' -and $run.Output -notmatch 'at <ScriptBlock>' -and
            $run.Output -match '== logging ==' -and $run.Output -notmatch '== network ==') {
            Test-Ok "hardening_audit.ps1 -Only logging,updates ran those groups only (exit $($run.ExitCode))"
        } else {
            Test-Fail "hardening_audit.ps1 end to end: exited $($run.ExitCode) (allowed: $($allowed -join ', ')), or the verdicts or headings are not what was asked for"
            foreach ($line in ($run.Output -split "`n" | Select-Object -First 8)) {
                Write-Host "       $line" -ForegroundColor Red
            }
        }
    }
    Remove-Item -Path $auditBox -Recurse -Force -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------------------
Write-Section 'tls_expiry grades expiry'
$tlsExpiry = Find-ContractScript 'tls_expiry.ps1'
if (-not $tlsExpiry) {
    Test-Fail 'tls_expiry.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $src = Get-ScriptFunctionSource -Script $tlsExpiry -Name 'Get-CertExpiryVerdict'
    if (-not $src) {
        Test-Fail 'tls_expiry.ps1 : Get-CertExpiryVerdict not found - this check has stopped checking'
    } else {
        . ([scriptblock]::Create($src))
        $fixedNow = [datetime]'2026-10-01T12:00:00'
        $verdictRan = 0
        foreach ($case in @(
                @{ NotAfter = $fixedNow.AddDays(-1); Level = 'expired'; DaysLeft = -1; Label = 'a day ago' }
                @{ NotAfter = $fixedNow; Level = 'expired'; DaysLeft = 0; Label = 'this very moment' }
                @{ NotAfter = $fixedNow.AddDays(30); Level = 'warn'; DaysLeft = 30; Label = 'exactly -Days away' }
                @{ NotAfter = $fixedNow.AddDays(31); Level = 'pass'; DaysLeft = 31; Label = 'one day past -Days' }
                @{ NotAfter = $fixedNow.AddDays(400); Level = 'pass'; DaysLeft = 400; Label = 'next year' }
            )) {
            $verdict = Get-CertExpiryVerdict -NotAfter $case.NotAfter -Now $fixedNow -Days 30
            $verdictRan++
            if ($verdict.Level -eq $case.Level -and $verdict.DaysLeft -eq $case.DaysLeft) {
                Test-Ok ("NotAfter {0} -> {1}, {2} day(s) left" -f $case.Label, $verdict.Level, $verdict.DaysLeft)
            } else {
                Test-Fail ("NotAfter {0}: got {1}/{2}, expected {3}/{4}" -f $case.Label, $verdict.Level, $verdict.DaysLeft, $case.Level, $case.DaysLeft)
            }
        }
        if ($verdictRan -lt 5) {
            Test-Fail "only $verdictRan expiry case(s) ran - this check has stopped checking"
        }
    }
}

# --------------------------------------------------------------------------
# Certificates for the sections below, made here and never committed. A
# checked-in fixture expires, and a test that starts failing on a date is a
# test somebody deletes. CertificateRequest is PowerShell 7 (.NET Core) only;
# without it these sections skip and say why.
$tlsFixtures = $null
$tlsBox = Join-Path ([IO.Path]::GetTempPath()) ('wintls_' + [Guid]::NewGuid().ToString('N'))
if ($tlsExpiry -and ('System.Security.Cryptography.X509Certificates.CertificateRequest' -as [type])) {
    New-Item -ItemType Directory -Path $tlsBox -Force | Out-Null
    $tlsFixtures = @{}
    $utcNow = [DateTimeOffset]::UtcNow
    foreach ($spec in @(
            @{ Name = 'expired'; From = $utcNow.AddDays(-60); To = $utcNow.AddDays(-1) }
            @{ Name = 'soon'; From = $utcNow.AddDays(-1); To = $utcNow.AddDays(10) }
            @{ Name = 'later'; From = $utcNow.AddDays(-1); To = $utcNow.AddDays(400) }
        )) {
        $key = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
        $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
            "CN=contract-$($spec.Name)", $key, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        $certificate = $request.CreateSelfSigned($spec.From, $spec.To)
        $base64 = [Convert]::ToBase64String($certificate.RawData)
        $wrapped = @()
        for ($i = 0; $i -lt $base64.Length; $i += 64) {
            $wrapped += $base64.Substring($i, [math]::Min(64, $base64.Length - $i))
        }
        $pem = "-----BEGIN CERTIFICATE-----`n" + ($wrapped -join "`n") + "`n-----END CERTIFICATE-----`n"
        $path = Join-Path $tlsBox "$($spec.Name).pem"
        Set-Content -Path $path -Value $pem -NoNewline
        $tlsFixtures[$spec.Name] = @{ Path = $path; Pem = $pem; Der = $certificate.RawData }
        $key.Dispose()
    }
    $tlsFixtures['garbage'] = @{ Path = (Join-Path $tlsBox 'garbage.pem') }
    Set-Content -Path $tlsFixtures['garbage'].Path -Value 'this is not a certificate'
}

# --------------------------------------------------------------------------
Write-Section 'tls_expiry decodes PEM'
if (-not $tlsExpiry) {
    Test-Fail 'tls_expiry.ps1 was not found among the scripts - this check has stopped checking'
} elseif (-not $tlsFixtures) {
    Test-Skip 'CertificateRequest is not available in this PowerShell, so no certificate could be generated'
} else {
    $src = Get-ScriptFunctionSource -Script $tlsExpiry -Name 'ConvertFrom-PemText'
    if (-not $src) {
        Test-Fail 'tls_expiry.ps1 : ConvertFrom-PemText not found - this check has stopped checking'
    } else {
        . ([scriptblock]::Create($src))
        $first = $tlsFixtures['soon']
        $second = $tlsFixtures['later']
        $ascii = [Text.Encoding]::ASCII
        foreach ($case in @(
                @{ Text = $first.Pem + $second.Pem; Label = 'a bundle of two gives the first' }
                @{ Text = ($first.Pem -replace "`n", "`r`n"); Label = 'CRLF armour' }
                @{ Text = "# issued by the contract suite`nsubject=CN=contract-soon`n" + $first.Pem; Label = 'text before the armour' }
            )) {
            $got = ConvertFrom-PemText -Bytes $ascii.GetBytes($case.Text)
            if ($got -is [byte[]] -and [Convert]::ToBase64String($got) -eq [Convert]::ToBase64String($first.Der)) {
                Test-Ok "ConvertFrom-PemText: $($case.Label)"
            } else {
                Test-Fail "ConvertFrom-PemText: $($case.Label) did not return the first certificate's DER bytes"
            }
        }
        $raw = ConvertFrom-PemText -Bytes $first.Der
        if ($raw -is [byte[]] -and [Convert]::ToBase64String($raw) -eq [Convert]::ToBase64String($first.Der)) {
            Test-Ok 'ConvertFrom-PemText: bytes with no armour are returned unchanged, as DER'
        } else {
            Test-Fail 'ConvertFrom-PemText: DER input was not returned unchanged'
        }
        $keyOnly = ConvertFrom-PemText -Bytes $ascii.GetBytes("-----BEGIN PRIVATE KEY-----`nAAAA`n-----END PRIVATE KEY-----`n")
        if ($null -eq $keyOnly) {
            Test-Ok 'ConvertFrom-PemText: armour with no CERTIFICATE block is not a certificate'
        } else {
            Test-Fail 'ConvertFrom-PemText: a lone private key block was returned as a certificate'
        }
    }
}

# --------------------------------------------------------------------------
Write-Section 'tls_expiry end to end on files'
$tlsCopy = $null
if ($tlsExpiry -and $tlsFixtures) {
    $tlsCopy = Copy-UnguardedScript -Script $tlsExpiry -Directory $tlsBox
}
if (-not $tlsExpiry) {
    Test-Fail 'tls_expiry.ps1 was not found among the scripts - this check has stopped checking'
} elseif (-not $tlsFixtures) {
    Test-Skip 'CertificateRequest is not available in this PowerShell, so no certificate could be generated'
} elseif (-not $tlsCopy) {
    Test-Fail 'tls_expiry.ps1 : platform guard not found verbatim, so the end-to-end check could not run; update the guard text in contract.ps1'
} else {
    $missingPath = Join-Path $tlsBox 'missing.pem'
    foreach ($case in @(
            @{ Arguments = @('-File', $tlsFixtures['expired'].Path); Code = 1; Token = '[FAIL]'; Label = 'an expired certificate fails' }
            @{ Arguments = @('-File', $tlsFixtures['soon'].Path, '-Days', '30'); Code = 0; Token = '[warn]'; Label = 'one expiring in 10 days warns and exits 0' }
            @{ Arguments = @('-File', $tlsFixtures['soon'].Path, '-Days', '30', '-FailOn', 'warn'); Code = 1; Token = '[warn]'; Label = 'the same with -FailOn warn exits 1' }
            @{ Arguments = @('-File', $tlsFixtures['later'].Path); Code = 0; Token = '[pass]'; Label = 'one with 400 days left passes' }
            @{ Arguments = @('-File', $tlsFixtures['expired'].Path, '-FailOn', 'never'); Code = 0; Token = '[FAIL]'; Label = '-FailOn never reports the failure and exits 0' }
            @{ Arguments = @('-File', $tlsFixtures['garbage'].Path); Code = 1; Token = '[FAIL]'; Label = 'a file that is not a certificate fails' }
            @{ Arguments = @('-File', $missingPath); Code = 3; Token = ''; Label = 'a file that does not exist is a usage error' }
        )) {
        $run = Invoke-InScratch -Path $tlsCopy -Arguments $case.Arguments
        if ($run.ExitCode -eq $case.Code -and (-not $case.Token -or $run.Output.Contains($case.Token))) {
            Test-Ok "tls_expiry.ps1: $($case.Label) (exit $($run.ExitCode))"
        } else {
            Test-Fail "tls_expiry.ps1: $($case.Label): exited $($run.ExitCode), expected $($case.Code) and '$($case.Token)'"
            foreach ($line in ($run.Output -split "`n" | Select-Object -First 6)) {
                Write-Host "       $line" -ForegroundColor Red
            }
        }
    }
}

# --------------------------------------------------------------------------
Write-Section 'tls_expiry usage'
if (-not $tlsExpiry) {
    Test-Fail 'tls_expiry.ps1 was not found among the scripts - this check has stopped checking'
} else {
    foreach ($case in @(
            @{ Arguments = @(); Label = 'nothing to check' }
            @{ Arguments = @('-Store', '-FailOn', 'bogus'); Label = '-FailOn bogus' }
            @{ Arguments = @('-HostName', 'bad host'); Label = "-HostName 'bad host'" }
            @{ Arguments = @('-Store', '-Days', '0'); Label = '-Days 0' }
        )) {
        $run = Invoke-InScratch -Path $tlsExpiry.FullName -Arguments $case.Arguments
        if ($run.ExitCode -eq 3) {
            Test-Ok "tls_expiry.ps1 $($case.Label) exits 3, before the platform guard"
        } else {
            Test-Fail "tls_expiry.ps1 $($case.Label): exited $($run.ExitCode), expected 3"
        }
    }
}

# --------------------------------------------------------------------------
Write-Section 'tls_expiry unreachable host is a failure'
# Port 1 on loopback has nothing listening, so the connection is refused at
# once on both runners. A refusal that read as "nothing to report" would make
# an outage look like a healthy certificate.
if (-not $tlsExpiry) {
    Test-Fail 'tls_expiry.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $unreachableBox = Join-Path ([IO.Path]::GetTempPath()) ('wintlshost_' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $unreachableBox -Force | Out-Null
    $hostCopy = Copy-UnguardedScript -Script $tlsExpiry -Directory $unreachableBox
    if (-not $hostCopy) {
        Test-Fail 'tls_expiry.ps1 : platform guard not found verbatim, so this check could not run; update the guard text in contract.ps1'
    } else {
        $run = Invoke-InScratch -Path $hostCopy -Arguments @('-HostName', '127.0.0.1:1')
        if ($run.ExitCode -eq 1 -and $run.Output.Contains('[FAIL]')) {
            Test-Ok 'tls_expiry.ps1 -HostName 127.0.0.1:1 is a [FAIL] and exits 1'
        } else {
            Test-Fail "tls_expiry.ps1 -HostName 127.0.0.1:1: exited $($run.ExitCode), expected 1 with a [FAIL]"
        }
        $run = Invoke-InScratch -Path $hostCopy -Arguments @('-Store')
        if ($run.ExitCode -in 0, 1 -and $run.Output -match '== stores ==' -and $run.Output -notmatch 'at <ScriptBlock>') {
            Test-Ok "tls_expiry.ps1 -Store reads or skips both personal stores without an exception (exit $($run.ExitCode))"
        } else {
            Test-Fail "tls_expiry.ps1 -Store: exited $($run.ExitCode), or did not report its stores"
        }
    }
    Remove-Item -Path $unreachableBox -Recurse -Force -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------------------
Write-Section 'tls_expiry keeps its hands off keys and global state'
# Static, because the failure it guards against would not show in any output:
# a process-wide "accept every certificate" callback, or a private key read.
if (-not $tlsExpiry) {
    Test-Fail 'tls_expiry.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $tlsText = Get-Content -Raw -Path $tlsExpiry.FullName
    foreach ($forbidden in @('ServerCertificateValidationCallback', '.PrivateKey', 'Export')) {
        if ($tlsText.Contains($forbidden)) {
            Test-Fail "tls_expiry.ps1 contains '$forbidden'"
        } else {
            Test-Ok "tls_expiry.ps1 never mentions '$forbidden'"
        }
    }
}
if (Test-Path -LiteralPath $tlsBox) {
    Remove-Item -Path $tlsBox -Recurse -Force -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------------------
Write-Section 'clean_disk_c opt-ins are gated'
# clean_disk_c.ps1 cannot run off Windows and its deleting path must never be
# run by this suite, so its opt-in contract is read off the AST instead: every
# -Include* switch is tested by some if, and every deletion of a crash dump,
# a servicing log or the component store sits inside the if for its own flag.
# A target that slipped out of its block would run on every plain -Yes.
$cleanDisk = Find-ContractScript 'clean_disk_c.ps1'
if (-not $cleanDisk) {
    Test-Fail 'clean_disk_c.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $cleanTokens = $null
    $cleanAst = [System.Management.Automation.Language.Parser]::ParseFile($cleanDisk.FullName, [ref]$cleanTokens, [ref]$null)
    $includeNames = @($cleanAst.ParamBlock.Parameters |
        ForEach-Object { $_.Name.VariablePath.UserPath } |
        Where-Object { $_ -like 'Include*' })
    $ifStatements = @($cleanAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.IfStatementAst]
            }, $true))
    foreach ($includeName in $includeNames) {
        $pattern = '\$' + $includeName + '\b'
        $testing = @($ifStatements | Where-Object { @($_.Clauses | Where-Object { $_.Item1.Extent.Text -match $pattern }).Count -gt 0 })
        if ($testing.Count -gt 0) {
            Test-Ok "clean_disk_c.ps1 -$includeName is tested by an if"
        } else {
            Test-Fail "clean_disk_c.ps1 declares -$includeName but no if tests it: a flag that does nothing"
        }
    }
    if ($includeNames.Count -lt 7) {
        Test-Fail "clean_disk_c.ps1 declares only $($includeNames.Count) -Include* switch(es); expected at least 7"
    }

    $markers = [ordered]@{
        'MEMORY.DMP'            = 'IncludeCrashDumps'
        'Minidump'              = 'IncludeCrashDumps'
        'LiveKernelReports'     = 'IncludeCrashDumps'
        'ReportArchive'         = 'IncludeCrashDumps'
        'CrashDumps'            = 'IncludeCrashDumps'
        'Logs\CBS'              = 'IncludeLogs'
        'Logs\DISM'             = 'IncludeLogs'
        'Panther'               = 'IncludeLogs'
        'StartComponentCleanup' = 'IncludeComponentStore'
    }
    $gatedCommands = 0
    $cleanCommands = $cleanAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        }, $true)
    foreach ($command in $cleanCommands) {
        if (@('Clear-Target', 'Dism.exe') -notcontains $command.GetCommandName()) { continue }
        foreach ($marker in $markers.Keys) {
            if (-not $command.Extent.Text.Contains($marker)) { continue }
            $flag = $markers[$marker]
            $gatedCommands++
            $gated = $false
            $node = $command.Parent
            while ($node) {
                if ($node -is [System.Management.Automation.Language.IfStatementAst]) {
                    foreach ($clause in $node.Clauses) {
                        if ($clause.Item1.Extent.Text -match ('\$' + $flag + '\b')) { $gated = $true }
                    }
                }
                $node = $node.Parent
            }
            if ($gated) {
                Test-Ok ("line {0}: the {1} target runs only under -{2}" -f $command.Extent.StartLineNumber, $marker, $flag)
            } else {
                Test-Fail ("line {0}: the {1} target is not inside an if testing -{2}" -f $command.Extent.StartLineNumber, $marker, $flag)
            }
        }
    }
    if ($gatedCommands -lt 9) {
        Test-Fail "found only $gatedCommands crash-dump, log and component-store command(s); expected 9 - this check has stopped checking"
    }

    # /ResetBase makes every installed update permanent. It may be named in a
    # comment explaining why it is not used, and nowhere else.
    $resetBase = @($cleanTokens | Where-Object {
            $_.Kind -ne [System.Management.Automation.Language.TokenKind]::Comment -and $_.Text -match 'ResetBase'
        })
    if ($resetBase.Count -eq 0) {
        Test-Ok 'clean_disk_c.ps1 never passes /ResetBase (it appears only in comments)'
    } else {
        Test-Fail "clean_disk_c.ps1 has ResetBase outside a comment on line $($resetBase[0].Extent.StartLineNumber)"
    }

    # The script cannot run here and Dism.exe cannot be stubbed from outside
    # it, so this is a static contract: a non-zero Dism exit is recorded where
    # the FAIL line is printed, and the script exits 1 after the summary.
    $cleanCode = (@(Get-Content -LiteralPath $cleanDisk.FullName | Where-Object { $_.TrimStart() -notlike '#*' }) -join "`n")
    $recordsFailure = $cleanCode -match '(?s)Dism exited \{1\}[^\n]*\n\s*\$componentStoreFailed = \$true'
    $exitsAfterSummary = $cleanCode -match '(?s)Free space on C: now.*\n\s*if \(\$componentStoreFailed\) \{ exit 1 \}\s*$'
    if ($recordsFailure -and $exitsAfterSummary) {
        Test-Ok 'clean_disk_c.ps1 records a failed Dism run and exits 1 after the summary'
    } else {
        Test-Fail "clean_disk_c.ps1 must set `$componentStoreFailed where Dism fails and 'exit 1' after the summary (recorded: $recordsFailure, exits: $exitsAfterSummary)"
    }
    $cleanHelp = Get-Content -LiteralPath $cleanDisk.FullName -Raw
    if ($cleanHelp -match '(?m)^\s+1\s+-IncludeComponentStore ran and Dism') {
        Test-Ok 'clean_disk_c.ps1 documents exit code 1'
    } else {
        Test-Fail 'clean_disk_c.ps1 .NOTES does not document exit code 1'
    }
}

# --------------------------------------------------------------------------
Write-Section 'clean_disk_c previews the new targets'
# Windows only: clean_disk_c.ps1 throws at script scope anywhere else. The
# generic dry-run section above already proves this preview writes nothing
# under the scratch profile; this one proves it names every new target and
# does not start DISM, whose banner would show in the output.
if (-not $onWindows) {
    Test-Skip 'clean_disk_c.ps1 reads WindowsIdentity and Get-PSDrive C at script scope, which throw on this OS before -DryRun is looked at'
} elseif (-not $cleanDisk) {
    Test-Fail 'clean_disk_c.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $memoryDump = 'C:\Windows\MEMORY.DMP'
    $hadDump = Test-Path -LiteralPath $memoryDump
    $run = Invoke-InScratch -Path $cleanDisk.FullName -Arguments @('-DryRun', '-IncludeCrashDumps', '-IncludeLogs', '-IncludeComponentStore')
    $labels = @('Memory dump (MEMORY.DMP)', 'Minidumps', 'Live kernel reports', 'WER report archive', 'User crash dumps',
        'CBS logs', 'DISM logs', 'Setup logs', 'Component store cleanup')
    $unnamed = @($labels | Where-Object { $run.Output -notmatch ('(?m)^(WOULD|SKIP ) ' + [regex]::Escape($_)) })
    if ($run.ExitCode -eq 0 -and $unnamed.Count -eq 0) {
        Test-Ok 'clean_disk_c.ps1 -DryRun with the three new flags previews (or skips, with the reason) every new target'
    } else {
        Test-Fail "clean_disk_c.ps1 -DryRun with the new flags: exited $($run.ExitCode), no WOULD or SKIP line for [$($unnamed -join '; ')]"
    }
    if ($run.Output -notmatch 'Deployment Image Servicing') {
        Test-Ok 'the preview did not start DISM'
    } else {
        Test-Fail 'the preview started DISM: its banner is in the output'
    }
    if ($hadDump) {
        if (Test-Path -LiteralPath $memoryDump) {
            Test-Ok "$memoryDump is still there after the preview"
        } else {
            Test-Fail "$memoryDump existed before the preview and is gone after it"
        }
    }
}

# --------------------------------------------------------------------------
Write-Section 'workstation_doctor section selection'
$doctor = Find-ContractScript 'workstation_doctor.ps1'
$doctorSections = @('security', 'reboot', 'disk', 'wsl', 'policy', 'hardware', 'uptime', 'updates', 'memory')
if (-not $doctor) {
    Test-Fail 'workstation_doctor.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $listed = Invoke-InScratch -Path $doctor.FullName -Arguments @('-ListSections')
    $ids = @($listed.Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($listed.ExitCode -eq 0 -and ($ids -join ',') -eq ($doctorSections -join ',')) {
        Test-Ok 'workstation_doctor.ps1 -ListSections prints the nine ids in order and exits 0'
    } else {
        Test-Fail "workstation_doctor.ps1 -ListSections exited $($listed.ExitCode) and printed [$($ids -join ',')]"
    }
    $run = Invoke-InScratch -Path $doctor.FullName -Arguments @('-Only', 'bogus')
    if ($run.ExitCode -eq 3 -and $run.Output -match 'bogus') {
        Test-Ok 'workstation_doctor.ps1 -Only bogus exits 3 and names the section, before the platform guard'
    } else {
        Test-Fail "workstation_doctor.ps1 -Only bogus must exit 3 naming it; it exited $($run.ExitCode)"
    }
    $run = Invoke-InScratch -Path $doctor.FullName -Arguments @('-Only', ',')
    if ($run.ExitCode -eq 4) {
        Test-Ok "workstation_doctor.ps1 -Only ',' selects nothing and exits 4"
    } else {
        Test-Fail "workstation_doctor.ps1 -Only ',' must exit 4; it exited $($run.ExitCode)"
    }
    # A ValidateRange failure, like -MinFreePercent's: under 'pwsh -File' that
    # is a binding error and exits 1, not this repository's 3. What matters
    # here is that an out-of-range value is refused rather than run with.
    $run = Invoke-InScratch -Path $doctor.FullName -Arguments @('-MaxUptimeDays', '5000')
    if ($run.ExitCode -ne 0) {
        Test-Ok "workstation_doctor.ps1 -MaxUptimeDays 5000 is refused (exit $($run.ExitCode))"
    } else {
        Test-Fail 'workstation_doctor.ps1 -MaxUptimeDays 5000 was accepted'
    }
}

# --------------------------------------------------------------------------
Write-Section 'workstation_doctor grades uptime'
if (-not $doctor) {
    Test-Fail 'workstation_doctor.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $src = Get-ScriptFunctionSource -Script $doctor -Name 'Get-UptimeFinding'
    if (-not $src) {
        Test-Fail 'workstation_doctor.ps1 : Get-UptimeFinding not found - this check has stopped checking'
    } else {
        . ([scriptblock]::Create($src))
        $clock = [datetime]'2026-10-01T09:00:00'
        foreach ($case in @(
                @{ Days = 5; Max = 30; Fast = $false; Level = 'ok'; Hint = ''; Label = '5 days, limit 30' }
                @{ Days = 45; Max = 30; Fast = $false; Level = 'warn'; Hint = 'restart'; Label = '45 days, limit 30' }
                @{ Days = 45; Max = 0; Fast = $false; Level = 'ok'; Hint = ''; Label = '45 days with the warning turned off' }
                @{ Days = 45; Max = 30; Fast = $true; Level = 'warn'; Hint = 'Fast Startup'; Label = '45 days with Fast Startup on' }
                @{ Days = 30; Max = 30; Fast = $false; Level = 'ok'; Hint = ''; Label = 'exactly at the limit' }
            )) {
            $finding = Get-UptimeFinding -LastBoot $clock.AddDays(-$case.Days) -Now $clock -MaxDays $case.Max -FastStartup $case.Fast
            $hintOk = (-not $case.Hint) -or ($finding.Hint -match $case.Hint)
            if ($finding.Level -eq $case.Level -and $finding.Days -eq $case.Days -and $hintOk) {
                Test-Ok ("{0} -> {1}" -f $case.Label, $finding.Level)
            } else {
                Test-Fail ("{0}: got {1} ({2} days, hint '{3}'), expected {4} with a hint mentioning '{5}'" -f $case.Label, $finding.Level, $finding.Days, $finding.Hint, $case.Level, $case.Hint)
            }
        }
    }
}

# --------------------------------------------------------------------------
Write-Section 'workstation_doctor grades patch age'
if (-not $doctor) {
    Test-Fail 'workstation_doctor.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $src = Get-ScriptFunctionSource -Script $doctor -Name 'Get-PatchAgeFinding'
    if (-not $src) {
        Test-Fail 'workstation_doctor.ps1 : Get-PatchAgeFinding not found - this check has stopped checking'
    } else {
        . ([scriptblock]::Create($src))
        $clock = [datetime]'2026-10-01T09:00:00'
        foreach ($case in @(
                @{ InstalledOn = $clock.AddDays(-10); Level = 'ok'; Label = 'patched 10 days ago' }
                @{ InstalledOn = $clock.AddDays(-60); Level = 'warn'; Label = 'patched 60 days ago, limit 45' }
                @{ InstalledOn = $null; Level = 'info'; Label = 'no date at all' }
            )) {
            $finding = Get-PatchAgeFinding -InstalledOn $case.InstalledOn -Now $clock -MaxDays 45
            if ($finding.Level -eq $case.Level) {
                Test-Ok ("{0} -> {1}" -f $case.Label, $finding.Level)
            } else {
                Test-Fail ("{0}: got {1}, expected {2}" -f $case.Label, $finding.Level, $case.Level)
            }
        }
    }
}

# --------------------------------------------------------------------------
Write-Section 'workstation_doctor runs the selected sections'
# disk, wsl, memory and hardware only: every probe in them is behind a
# try/catch or -ErrorAction SilentlyContinue, so they answer off Windows too.
# The registry sections are left out here, because Test-Path on HKLM: under
# pwsh on Linux with ErrorActionPreference Stop has not been verified, and the
# doctor had never run guard-stripped before. On Windows the full default run
# is checked as well, all nine headings in order.
if (-not $doctor) {
    Test-Fail 'workstation_doctor.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $doctorBox = Join-Path ([IO.Path]::GetTempPath()) ('windoctor_' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $doctorBox -Force | Out-Null
    $doctorCopy = Copy-UnguardedScript -Script $doctor -Directory $doctorBox
    if (-not $doctorCopy) {
        Test-Fail 'workstation_doctor.ps1 : platform guard not found verbatim, so this check could not run; update the guard text in contract.ps1'
    } else {
        $run = Invoke-InScratch -Path $doctorCopy -Arguments @('-Only', 'disk,wsl,memory,hardware')
        $missing = @(@('== disk ==', '== wsl ==', '== memory ==', '== hardware ==') | Where-Object { $run.Output -notlike "*$_*" })
        $extra = @(@('== security ==', '== reboot ==', '== policy ==', '== uptime ==', '== updates ==') | Where-Object { $run.Output -like "*$_*" })
        if ($run.ExitCode -eq 0 -and $missing.Count -eq 0 -and $extra.Count -eq 0 -and $run.Output -notmatch 'at <ScriptBlock>') {
            Test-Ok 'workstation_doctor.ps1 -Only disk,wsl,memory,hardware ran exactly those sections'
        } else {
            Test-Fail ("workstation_doctor.ps1 -Only: exited {0}, missing [{1}], unexpected [{2}]" -f $run.ExitCode, ($missing -join ' '), ($extra -join ' '))
            foreach ($line in ($run.Output -split "`n" | Select-Object -First 8)) {
                Write-Host "       $line" -ForegroundColor Red
            }
        }
        if ($onWindows) {
            $full = Invoke-InScratch -Path $doctorCopy
            $positions = @($doctorSections | ForEach-Object { $full.Output.IndexOf("== $_ ==") })
            $inOrder = ($positions -notcontains -1)
            for ($i = 1; $i -lt $positions.Count; $i++) {
                if ($positions[$i] -le $positions[$i - 1]) { $inOrder = $false }
            }
            if ($full.ExitCode -eq 0 -and $inOrder) {
                Test-Ok 'workstation_doctor.ps1 with no -Only runs all nine sections, in order'
            } else {
                Test-Fail "workstation_doctor.ps1 with no -Only: exited $($full.ExitCode), heading positions $($positions -join ',')"
            }
        }
    }
    Remove-Item -Path $doctorBox -Recurse -Force -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------------------
Write-Section 'workstation_doctor default order is unchanged'
# Static, so it holds on every runner: the five sections people already know
# keep their order, and the new four come after them. A refactor that
# reordered the report would pass every other check here.
if (-not $doctor) {
    Test-Fail 'workstation_doctor.ps1 was not found among the scripts - this check has stopped checking'
} else {
    $doctorText = Get-Content -Raw -Path $doctor.FullName
    $offsets = @($doctorSections | ForEach-Object { $doctorText.IndexOf("Write-Section '$_'") })
    $ordered = ($offsets -notcontains -1)
    for ($i = 1; $i -lt $offsets.Count; $i++) {
        if ($offsets[$i] -le $offsets[$i - 1]) { $ordered = $false }
    }
    if ($ordered) {
        Test-Ok "workstation_doctor.ps1 sections appear as $($doctorSections -join ', ')"
    } else {
        Test-Fail "workstation_doctor.ps1 sections are out of order or missing (offsets $($offsets -join ','))"
    }
}

# --------------------------------------------------------------------------
Write-Host ''
if ($failures -gt 0) {
    Write-Host "$failures contract check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host "=== all windows contract checks passed ($(@($scripts).Count) scripts) ==="
exit 0
