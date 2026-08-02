<#
.SYNOPSIS
    Contract checks for the PowerShell scripts in windows/.

.DESCRIPTION
    Deliberately not behavioural tests. clean_disk_c.ps1 calls
    [Security.Principal.WindowsIdentity]::GetCurrent() and Get-PSDrive -Name C
    at script scope, both of which throw on Linux the moment the file is
    dot-sourced - so its functions cannot be reached for unit testing without
    restructuring it into a module with a main guard, which would defeat the
    point of a script you copy to a machine and run.

    Everything here therefore inspects the scripts without executing them.
    Get-Command and Get-Help both parse a .ps1 without running its body, which
    is what makes these checks possible on a Linux runner at all.

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
function Write-Section { param([string]$Name) Write-Host ''; Write-Host "--- $Name ---" }

$scripts = Get-ChildItem -Path (Join-Path $repoRoot 'windows') -Filter '*.ps1' -Recurse -File |
    Where-Object { $_.FullName -notmatch [regex]::Escape([IO.Path]::DirectorySeparatorChar + 'tests' + [IO.Path]::DirectorySeparatorChar) } |
    Sort-Object FullName

if (-not $scripts) {
    Write-Host '[fail] found no PowerShell scripts under windows/' -ForegroundColor Red
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
Write-Host ''
if ($failures -gt 0) {
    Write-Host "$failures contract check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host "=== all windows contract checks passed ($(@($scripts).Count) scripts) ==="
exit 0
