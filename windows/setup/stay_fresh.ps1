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

.EXAMPLE
    .\stay_fresh.ps1 -DryRun
    .\stay_fresh.ps1
    .\stay_fresh.ps1 -SkipWsl

.NOTES
    Exit codes, matching linux/stay_fresh.sh:
      0  success
      1  one or more steps failed
      2  preflight checks failed
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
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

# --- winget ----------------------------------------------------------------
if ($SkipWinget) {
    Write-Info 'skipped: winget (-SkipWinget)'
} else {
    Write-Section 'winget'
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
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
if ($SkipWsl) {
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

# --- report ----------------------------------------------------------------
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
