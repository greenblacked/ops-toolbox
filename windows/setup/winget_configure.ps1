<#
.SYNOPSIS
    Apply the curated Windows workstation described by configuration.winget.

.DESCRIPTION
    winget_bootstrap.ps1 captures a machine. This applies one.

    The two are complements, not alternatives. configuration.winget is the
    intent - a short, curated, reviewed list of what a workstation should have.
    winget-packages.json is the fact - everything a particular box happens to
    have installed, exported from it. Use this to build a machine, use the
    other to record one.

      validate  Check the configuration file parses and its resources resolve
      show      Print what the file would apply, without touching the machine
      test      Report whether the machine already matches the file
      apply     Bring the machine into the state the file describes

    validate, show and test are read-only. Only apply changes anything, and it
    takes -DryRun.

    'test' is the verb worth wiring into a scheduled check: it answers "has
    this machine drifted from the list we agreed on" with an exit code rather
    than with prose, which is the same shape check uses in winget_bootstrap.ps1
    and brewfile.sh.

    Requires WinGet 1.6 or newer; 'winget configure' does not exist before it.
    The preflight says so and exits 2 rather than letting winget fail with an
    unrecognised-argument error that reads like a bug in this script.

.EXAMPLE
    .\winget_configure.ps1 validate
    .\winget_configure.ps1 show
    .\winget_configure.ps1 test
    .\winget_configure.ps1 apply -DryRun
    .\winget_configure.ps1 apply -File .\configuration.winget

.NOTES
    Exit codes, matching winget_bootstrap.ps1 and brewfile.sh:
      0  success (for test: the machine matches the file)
      1  command failed (for test: the machine has drifted)
      2  preflight checks failed
      3  bad arguments
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('validate', 'show', 'test', 'apply')]
    [string]$Action,

    [string]$File,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# The lowest WinGet that ships the 'configure' command at all.
$MinimumWinGetVersion = [version]'1.6.0'

if (-not $Action) {
    Get-Help -Full $PSCommandPath | Out-String | Write-Host
    exit 3
}

if (-not $File) {
    $File = Join-Path $PSScriptRoot 'configuration.winget'
}

function Write-Info { param([string]$Message) Write-Host "[info] $Message" -ForegroundColor Blue }
function Write-Ok   { param([string]$Message) Write-Host "[ ok ] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[warn] $Message" -ForegroundColor Yellow }
function Write-Err  { param([string]$Message) Write-Host "[err ] $Message" -ForegroundColor Red }

# --- preflight -------------------------------------------------------------
# Mirrors winget_bootstrap.ps1: wrong platform is 2, missing tool is 2, and a
# tool that is present but too old is 2 as well - it is a machine problem, not
# a failure of the work this script was asked to do.
if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    Write-Err 'this script targets Windows'
    exit 2
}
if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
    Write-Err 'winget is not installed or not on PATH - install "App Installer" from the Microsoft Store'
    exit 2
}

# winget prints its version as "v1.8.1911". Anything that does not look like a
# version is treated as unknown rather than as too old: refusing to run because
# a future winget changed its banner format would be worse than trying.
function Get-WinGetVersion {
    $raw = (& winget.exe --version 2>&1 | Out-String).Trim()
    $m = [regex]::Match($raw, 'v?(?<version>\d+\.\d+(\.\d+)?)')
    if (-not $m.Success) { return $null }
    return [version]$m.Groups['version'].Value
}

$wingetVersion = Get-WinGetVersion
if ($null -eq $wingetVersion) {
    Write-Warn "could not read a version from 'winget --version'; continuing"
} elseif ($wingetVersion -lt $MinimumWinGetVersion) {
    Write-Err "winget $wingetVersion is too old - 'winget configure' needs $MinimumWinGetVersion or newer"
    Write-Info 'update "App Installer" from the Microsoft Store, then re-run'
    exit 2
}

if (-not (Test-Path $File)) {
    Write-Err "$File does not exist"
    exit 1
}

# Every configure verb wants these; keeping them in one place stops one verb
# from prompting on a machine where the others do not.
$commonArguments = @(
    '--file', $File,
    '--accept-configuration-agreements',
    '--disable-interactivity'
)

# Runs winget and hands back its exit code instead of throwing. winget reports
# drift and hard failure through the same non-zero channel, so the caller
# decides what a given code means for its verb.
function Invoke-WinGetConfigure {
    param([string[]]$Arguments)

    & winget.exe configure @Arguments
    return $LASTEXITCODE
}

switch ($Action) {

    'validate' {
        $rc = Invoke-WinGetConfigure -Arguments (@('validate') + $commonArguments)
        if ($rc -ne 0) {
            Write-Err "configuration is not valid (winget exited $rc)"
            exit 1
        }
        Write-Ok "$File is valid"
    }

    'show' {
        $rc = Invoke-WinGetConfigure -Arguments (@('show') + $commonArguments)
        if ($rc -ne 0) {
            Write-Err "winget configure show exited $rc"
            exit 1
        }
    }

    'test' {
        $rc = Invoke-WinGetConfigure -Arguments (@('test') + $commonArguments)
        if ($rc -eq 0) {
            Write-Ok "this machine matches $File"
            exit 0
        }
        # winget distinguishes "not in desired state" from "could not tell" by
        # HRESULT, but both mean the same thing to a caller: do not trust this
        # machine to match the file. Print the code so the difference is not
        # lost, and exit 1 either way - the same contract as
        # winget_bootstrap.ps1 check.
        Write-Warn "this machine does not match $File (winget exited $rc)"
        Write-Info "run 'apply' to bring it into line"
        exit 1
    }

    'apply' {
        if ($DryRun) {
            # Deliberately not 'winget configure test' here. test contacts the
            # winget sources and populates caches under LOCALAPPDATA, which
            # would make this script's "no changes written" contract false. A
            # preview reads the file and says what it would do.
            # Both YAML styles the file uses: a description on its own line
            # under directives:, and one inside an inline { } map. Anything
            # before the first '- resource:' is header commentary, and
            # assertions are labelled rather than listed as work.
            $entries = @()
            $current = $null
            $section = ''
            foreach ($line in (Get-Content -Path $File)) {
                if ($line -match '^\s*assertions\s*:') { $section = 'assertion' }
                if ($line -match '^\s*resources\s*:') { $section = 'resource' }
                if ($line -match '^\s*-\s*resource\s*:\s*(?<name>\S+)') {
                    $current = [pscustomobject]@{
                        Kind        = $section
                        Resource    = $Matches['name']
                        Description = ''
                    }
                    $entries += $current
                    continue
                }
                if ($null -eq $current) { continue }
                # Quoted first: an unquoted value stops at a comma, which is
                # correct inside an inline map and wrong inside a quoted string.
                $m = [regex]::Match($line,
                    'description\s*:\s*(?:''(?<value>[^'']*)''|"(?<value>[^"]*)"|(?<value>[^,}]+))')
                if ($m.Success -and -not $current.Description) {
                    $current.Description = $m.Groups['value'].Value.Trim()
                }
            }

            Write-Info "(dry-run) would apply $File"
            foreach ($e in $entries) {
                $label = if ($e.Description) { $e.Description } else { $e.Resource }
                if ($e.Kind -eq 'assertion') {
                    Write-Host "ASSERT   $label" -ForegroundColor DarkGray
                } else {
                    Write-Host "WOULD    $label" -ForegroundColor Cyan
                }
            }
            Write-Info 'dry run complete; no changes written'
            exit 0
        }

        $rc = Invoke-WinGetConfigure -Arguments $commonArguments
        if ($rc -ne 0) {
            Write-Err "winget configure exited $rc"
            exit 1
        }
        Write-Ok "applied $File"
    }
}
