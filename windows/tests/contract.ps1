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
    'clean_disk_c.ps1'      = @('Scope')
    'stay_fresh.ps1'        = @('Only')
    'status.ps1'            = @('ListSections', 'Only')
    'workstation_doctor.ps1'= @('MinFreePercent')
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
foreach ($name in @('stay_fresh.ps1', 'clean_disk_c.ps1')) {
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
Write-Host ''
if ($failures -gt 0) {
    Write-Host "$failures contract check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host "=== all windows contract checks passed ($(@($scripts).Count) scripts) ==="
exit 0
