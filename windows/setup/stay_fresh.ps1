<#
.SYNOPSIS
    Recurring maintenance for a Windows machine: winget upgrades and a WSL update.

.DESCRIPTION
    The Windows counterpart of linux/stay_fresh.sh and
    macos-initial-setup/stay_fresh.sh, and deliberately the same shape: every
    step can be skipped, a missing tool is a note rather than a failure, and
    -DryRun prints the whole run without touching anything.

    Steps, in order:

      winget   Refresh the sources, then 'upgrade --all'. --include-unknown is
               passed so packages whose installed version winget cannot read
               are offered too - without it they are silently left behind,
               which is the most common reason a machine looks up to date and
               is not.
      wsl      'wsl --update'. That updates the WSL kernel and userspace
               package, not the packages inside a distro - run
               linux/stay_fresh.sh in the distro for those.
      store    Notes only. Nothing here touches Microsoft Store apps; see
               below for why, and for the command that does.
      report   Pending-reboot flags and free space on C:.

    What it deliberately does not do: reboot the machine, and free disk space -
    that is windows/cleanup/clean_disk_c.ps1, which has the dry run and the
    opt-in flags for it.

    The winget upgrades need -Yes. linux/stay_fresh.sh has skipped package
    upgrades without --yes from the start, and this script had no equivalent:
    a bare .\stay_fresh.ps1 went straight to 'winget upgrade --all'. The root
    README presents the two as counterparts, which is exactly what made that
    dangerous - somebody who has learned the Bash habit ("just run it, it will
    tell me what it wants") upgraded every package on the box the first time
    they tried the Windows one. Every other step still runs without -Yes, so a
    bare run stays a useful report; only the step that rewrites the machine
    waits to be asked. -DryRun previews the upgrades without -Yes, because a
    preview changes nothing and there is nothing to consent to.

.EXAMPLE
    .\stay_fresh.ps1 -DryRun
    .\stay_fresh.ps1
    .\stay_fresh.ps1 -Yes
    .\stay_fresh.ps1 -SkipWsl
    .\stay_fresh.ps1 -DryRun -Only Winget
    .\stay_fresh.ps1 -Yes -Only Winget,Wsl

.NOTES
    Exit codes, matching linux/stay_fresh.sh:
      0  success
      1  one or more steps failed
      2  preflight checks failed
      3  bad CLI arguments (an -Only step nobody has heard of)
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    # The non-interactive consent gate, spelled the way linux/stay_fresh.sh
    # spells it. Deliberately not SupportsShouldProcess: CONTRIBUTING.md rules
    # out -WhatIf/-Confirm for these scripts so the Windows and Bash siblings
    # read the same, and -WhatIf would duplicate the hand-rolled -DryRun that
    # every other script here already has.
    [switch]$Yes,
    # A list, not one value: linux/stay_fresh.sh --only takes a comma-separated
    # subset and this took exactly one name, so '-Only Winget,Wsl' died in
    # parameter binding with a ValidateSet error that reads like the step names
    # are wrong rather than the type. The set is validated in the body instead
    # of by a ValidateSet attribute - see the parsing below for why.
    [string[]]$Only = @('All'),
    [switch]$SkipWinget,
    [switch]$SkipWsl
)

# 'Continue', not 'Stop'. This is the PowerShell side of the split
# CONTRIBUTING.md draws between short single-purpose scripts and long
# maintenance runs: a step that fails is recorded and reported at the end, it
# does not abandon the rest of the run.
$ErrorActionPreference = 'Continue'
$script:StepFailures = 0

function Write-Info { param([string]$Message) Write-Host "[info] $Message" -ForegroundColor Blue }
function Write-Ok   { param([string]$Message) Write-Host "[ ok ] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[warn] $Message" -ForegroundColor Yellow }
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

# --- -Only ------------------------------------------------------------------
# Ahead of the preflight, because a bad argument is a bad argument on every
# platform and CONTRIBUTING.md puts usage errors before any preflight check.
#
# Both spellings of the list have to land here. From PowerShell itself,
# '-Only Winget,Wsl' arrives as two elements; through 'pwsh -File' - the
# invocation windows/README.md gives for a machine whose execution policy says
# no - the very same line arrives as the single string 'Winget,Wsl', because
# -File hands arguments over literally. Splitting on the comma takes both, and
# is what linux/stay_fresh.sh does with IFS=','. A ValidateSet attribute
# cannot: it runs during parameter binding, before anything has had a chance to
# look at the comma, so the -File form would be rejected as an unknown step.
$knownSteps = @('All', 'Winget', 'Wsl', 'Report')
$onlySteps = @($Only |
    ForEach-Object { $_ -split ',' } |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -ne '' })
if (-not $onlySteps) { $onlySteps = @('All') }
foreach ($step in $onlySteps) {
    if ($knownSteps -notcontains $step) {
        Write-Err ("unknown -Only step: {0} (expected one or more of: {1})" -f $step, ($knownSteps -join ', '))
        exit 3
    }
}

# --- preflight -------------------------------------------------------------
# Mirrors winget_bootstrap.ps1: wrong platform is 2. Windows PowerShell 5.1
# does not define $IsWindows at all, hence the edition test.
if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    Write-Err 'this script targets Windows'
    exit 2
}

# Reports under -DryRun, runs otherwise. WOULD / RUN / SKIP so the two modes
# line up column-for-column and are easy to diff by eye.
function Invoke-Step {
    param(
        [string]$Label,
        [string]$Command,
        [string[]]$Arguments = @()
    )

    $shown = (@($Command) + $Arguments) -join ' '

    if ($DryRun) {
        Write-Host ('WOULD {0,-16} {1}' -f $Label, $shown) -ForegroundColor Cyan
        return
    }

    Write-Host ('RUN   {0,-16} {1}' -f $Label, $shown) -ForegroundColor DarkGray
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        Write-Err ('{0} exited {1}' -f $Label, $LASTEXITCODE)
        $script:StepFailures++
        return
    }
    Write-Ok $Label
}

Write-Host ''
if ($DryRun) {
    Write-Host 'Dry run - nothing will be changed.' -ForegroundColor Yellow
}

# -contains, not -in: $onlySteps holds the list now, so -in would ask whether
# the whole array is one of these names and always answer no.
$onlyShown = $onlySteps -join ','
$runWinget = ($onlySteps -contains 'All') -or ($onlySteps -contains 'Winget')
$runWsl = ($onlySteps -contains 'All') -or ($onlySteps -contains 'Wsl')
$runReport = ($onlySteps -contains 'All') -or ($onlySteps -contains 'Report')

# --- winget ----------------------------------------------------------------
if (-not $runWinget) {
    Write-Info "skipped: winget (-Only $onlyShown)"
} elseif ($SkipWinget) {
    Write-Info 'skipped: winget (-SkipWinget)'
} else {
    Write-Section 'winget'
    # The consent gate, and the same shape as the one in linux/stay_fresh.sh:
    # checked once the step has been entered, so the run says out loud that it
    # is not upgrading rather than leaving a silent hole in the output. A dry
    # run is exempt because it writes nothing; that also keeps the preview
    # path - the one windows/tests/contract.ps1 exercises - reachable.
    if (-not $DryRun -and -not $Yes) {
        Write-Warn 'skipping upgrades: pass -Yes to run them unattended, or -DryRun to see them'
    } elseif (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        # A missing tool is a note, not a failure - the same rule the Bash
        # counterparts follow, and the reason this does not exit 2.
        Write-Warn 'winget is not on PATH - install "App Installer" from the Microsoft Store'
    } else {
        Invoke-Step -Label 'source update' -Command 'winget.exe' -Arguments @(
            'source', 'update', '--disable-interactivity'
        )
        # winget exits non-zero when any single package could not be upgraded,
        # including the "no applicable upgrade found" case. That counts as a
        # failed step here on purpose: the run is worth looking at rather than
        # being quietly reported as clean.
        Invoke-Step -Label 'upgrade --all' -Command 'winget.exe' -Arguments @(
            'upgrade', '--all', '--include-unknown',
            '--accept-package-agreements', '--accept-source-agreements',
            '--disable-interactivity'
        )
    }
}

# --- wsl -------------------------------------------------------------------
if (-not $runWsl) {
    Write-Info "skipped: WSL (-Only $onlyShown)"
} elseif ($SkipWsl) {
    Write-Info 'skipped: WSL (-SkipWsl)'
} else {
    Write-Section 'wsl'
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        Write-Info 'wsl.exe not found - nothing to update'
    } else {
        # wsl.exe ships as a stub even on a machine where WSL was never
        # installed, so probe for a working install before updating it. Its own
        # error output is UTF-16 and prints as garbage in most consoles, hence
        # the discard and our own message (same guard as wsl_manage.ps1).
        wsl.exe --status *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Info "WSL is not installed or not operational ('wsl --status' exited $LASTEXITCODE) - skipping"
        } else {
            Invoke-Step -Label 'wsl --update' -Command 'wsl.exe' -Arguments @('--update')
            Write-Info 'that updates the WSL kernel and userspace, not the packages inside a distro'
        }
    }
}

# --- store -----------------------------------------------------------------
if ($onlySteps -contains 'All') {
    Write-Section 'store'
# Notes, not a step. Store apps update on their own schedule, and winget's
# msstore source needs each package's agreements accepted interactively, so an
# unattended maintenance run cannot honestly claim to have updated them. Say
# what would, and leave the choice to a person.
Write-Info 'Microsoft Store apps are not touched here - they update on their own schedule'
Write-Info 'nudge them by hand: Store > Library > Get updates'
Write-Info 'or unattended, from an elevated prompt:'
    Write-Host '  Get-CimInstance -Namespace root\cimv2\mdm\dmmap ' -NoNewline -ForegroundColor DarkGray
    Write-Host '-ClassName MDM_EnterpriseModernAppManagement_AppManagement01 | Invoke-CimMethod -MethodName UpdateScanMethod' -ForegroundColor DarkGray
}

# --- report ----------------------------------------------------------------
if ($runReport) {
    Write-Section 'report'
# The registry flags Windows sets when a component or an update is waiting on a
# restart. Read-only, so this runs identically under -DryRun.
    $rebootFlags = @(
    @{ Label = 'servicing (CBS)'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' },
    @{ Label = 'Windows Update'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' }
)
    $pending = 0
    foreach ($flag in $rebootFlags) {
        if (Test-Path $flag.Path) {
            Write-Warn ('a reboot is pending: {0}' -f $flag.Label)
            $pending++
        }
    }
    if ($pending -eq 0) {
        Write-Ok 'no reboot pending'
    }

    $drive = Get-PSDrive -Name C -ErrorAction SilentlyContinue
    if ($drive) {
        Write-Info ('free space on C: {0}' -f (Format-Size $drive.Free))
    }
}

Write-Host ''
if ($DryRun) {
    Write-Host 'Dry run complete; no changes written.' -ForegroundColor Yellow
    exit 0
}
if ($script:StepFailures -gt 0) {
    Write-Err ('{0} step(s) failed' -f $script:StepFailures)
    exit 1
}
Write-Ok 'done'
exit 0
