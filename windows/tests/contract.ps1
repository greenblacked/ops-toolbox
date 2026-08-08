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

    The exception is the last section, which runs each -DryRun capable script
    against a scratch HOME and TEMP and fails if the filesystem changed. Read
    what that proves where: on Windows it is the real thing, the whole dry-run
    path executed and checked against the disk. On Linux the scripts that can
    be run at all stop at their platform check, so it only proves they write
    nothing before deciding they are on the wrong machine - which is still the
    place a stray log file or scratch directory would appear. The template is
    the one subject that runs its dry run to completion anywhere.

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
    return @('-DryRun')
}

# Written by the PowerShell host itself when it starts under a redirected home
# - a telemetry id, a startup profile, an empty Modules directory, the module
# analysis cache on Windows - not by the script under test storing anything.
# Excluded for the same reason check_conventions.sh excludes Go's telemetry
# counters, and reported when it fires, because a silent exclusion is how
# coverage rots.
$hostArtifact = '(?i)[\\/](\.cache|\.local|\.dotnet)([\\/]|$)|ModuleAnalysisCache|[\\/]Microsoft[\\/]Windows[\\/]PowerShell([\\/]|$)'

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
    if ($written) {
        Test-Fail "$rel $($arguments -join ' ') changed the filesystem:"
        foreach ($line in $written) {
            Write-Host ('       {0} {1}' -f $line.SideIndicator, $line.InputObject) -ForegroundColor Red
        }
    } elseif ($rc -notin 0, 2, 3, 4) {
        # 1 is "the work ran and some of it did not succeed", which a preview
        # has no business reporting. Catching it here is how the wsl_manage.ps1
        # preflight was found returning 1 where it documents 2.
        Test-Fail "$rel $($arguments -join ' ') wrote nothing but exited $rc; a dry run should not report a generic failure"
        foreach ($line in ($output -split "`n" | Select-Object -First 5)) {
            Write-Host "       $line" -ForegroundColor Red
        }
    } else {
        Test-Ok "$rel $($arguments -join ' ') wrote nothing (exit $rc)"
    }

    Remove-Item -Path $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

if ($dryChecked -eq 0) {
    Test-Fail 'no -DryRun script could be executed here - this check has stopped checking'
}

# --------------------------------------------------------------------------
Write-Host ''
if ($failures -gt 0) {
    Write-Host "$failures contract check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host "=== all windows contract checks passed ($(@($scripts).Count) scripts) ==="
exit 0
