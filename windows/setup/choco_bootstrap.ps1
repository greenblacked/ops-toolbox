<#
.SYNOPSIS
    Capture and restore the Chocolatey side of a Windows machine.

.DESCRIPTION
    The Chocolatey counterpart of winget_bootstrap.ps1, with the same commands
    and exit codes, so a machine managed by either package manager is managed
    the same way:

      export   Write the currently installed packages to a packages.config
      list     Print installed package ids to stdout (read-only)
      check    Report whether everything in the file is installed (read-only)
      install  Install everything the file lists that is missing
      diff     Show what export would change, without writing

    packages.config is Chocolatey's own format, so the file this writes can be
    fed straight to `choco install packages.config -y` on a machine that does
    not have this script.

    Chocolatey itself is not installed here. Bootstrapping it means running a
    remote script as Administrator, which is a decision to make deliberately
    rather than a side effect of asking what is installed - `install` reports
    the official command and stops if choco is missing.

.EXAMPLE
    .\choco_bootstrap.ps1 list
    .\choco_bootstrap.ps1 check
    .\choco_bootstrap.ps1 install -DryRun
    .\choco_bootstrap.ps1 install
    .\choco_bootstrap.ps1 export -Force

.NOTES
    Exit codes, matching winget_bootstrap.ps1:
      0  success (for check: everything present)
      1  command failed (for check: something is missing)
      2  preflight checks failed
      3  bad arguments
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('export', 'list', 'check', 'install', 'diff')]
    [string]$Action,

    [string]$File,
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
# choco.exe reports failures through its exit code. Under 'Stop' on PS 7.3+ a
# non-zero native exit becomes a terminating error, which would skip every
# $LASTEXITCODE check below and lose the distinction between "not installed"
# and "the command broke".
$PSNativeCommandUseErrorActionPreference = $false

if (-not $Action) {
    Get-Help -Full $PSCommandPath | Out-String | Write-Host
    exit 3
}

if (-not $File) {
    $File = Join-Path $PSScriptRoot 'choco-packages.config'
}

function Write-Info { param([string]$Message) Write-Host "[info] $Message" -ForegroundColor Blue }
function Write-Ok   { param([string]$Message) Write-Host "[ ok ] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[warn] $Message" -ForegroundColor Yellow }
function Write-Err  { param([string]$Message) Write-Host "[err ] $Message" -ForegroundColor Red }

# --- preflight -------------------------------------------------------------
# Mirrors winget_bootstrap.ps1: wrong platform is 2, missing tool is 2.
if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    Write-Err 'this script targets Windows'
    exit 2
}
if (-not (Get-Command choco.exe -ErrorAction SilentlyContinue)) {
    Write-Err 'Chocolatey is not installed or not on PATH'
    Write-Info 'install it from an elevated shell, per https://chocolatey.org/install'
    exit 2
}

# Package ids currently installed, one per line, sorted and lowercased so two
# snapshots of the same machine compare equal.
#
# `choco list` changed meaning in Chocolatey v2: it lists local packages, and
# the v1 spelling `--local-only` was removed rather than deprecated, so passing
# it is an error on a current install. `choco list -r` is the stable machine
# readable form on both.
function Get-InstalledPackage {
    $raw = & choco.exe list -r 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Err "choco list failed with exit code $LASTEXITCODE"
        $raw | ForEach-Object { Write-Host "       $_" }
        exit 1
    }
    $raw |
        Where-Object { $_ -match '\|' } |
        ForEach-Object { ($_ -split '\|')[0].Trim().ToLowerInvariant() } |
        Where-Object { $_ } |
        Sort-Object -Unique
}

# Package ids named by a packages.config. Chocolatey's own format, so this
# parses the XML rather than guessing at line shapes.
function Get-WantedPackage {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Err "no such file: $Path"
        Write-Info 'copy choco-packages.example.config next to this script and edit it'
        exit 3
    }
    try {
        [xml]$doc = Get-Content -LiteralPath $Path -Raw
    } catch {
        Write-Err "could not parse $Path as packages.config XML: $($_.Exception.Message)"
        exit 3
    }
    $ids = @($doc.packages.package | ForEach-Object { $_.id } |
        Where-Object { $_ } |
        ForEach-Object { $_.Trim().ToLowerInvariant() })
    if (-not $ids) {
        Write-Err "$Path lists no packages"
        exit 3
    }
    $ids | Sort-Object -Unique
}

function Write-PackageConfig {
    param([string[]]$Ids, [string]$Path)
    $lines = @('<?xml version="1.0" encoding="utf-8"?>', '<packages>')
    foreach ($id in $Ids) { $lines += ('  <package id="{0}" />' -f $id) }
    $lines += '</packages>'
    Set-Content -LiteralPath $Path -Value $lines -Encoding utf8
}

switch ($Action) {

    'list' {
        Get-InstalledPackage | ForEach-Object { Write-Output $_ }
        exit 0
    }

    'check' {
        $wanted = Get-WantedPackage -Path $File
        $have = @(Get-InstalledPackage)
        $missing = @($wanted | Where-Object { $_ -notin $have })
        if ($missing) {
            foreach ($m in $missing) { Write-Warn "missing: $m" }
            Write-Err ('{0} of {1} package(s) from {2} are not installed' -f $missing.Count, @($wanted).Count, $File)
            exit 1
        }
        Write-Ok ('all {0} package(s) from {1} are installed' -f @($wanted).Count, $File)
        exit 0
    }

    'diff' {
        $wanted = @(Get-WantedPackage -Path $File)
        $have = @(Get-InstalledPackage)
        $added = @($have | Where-Object { $_ -notin $wanted })
        $gone = @($wanted | Where-Object { $_ -notin $have })
        foreach ($a in $added) { Write-Host "+ $a" -ForegroundColor Green }
        foreach ($g in $gone) { Write-Host "- $g" -ForegroundColor Red }
        if (-not $added -and -not $gone) { Write-Ok "$File already matches this machine" }
        exit 0
    }

    'export' {
        if ((Test-Path -LiteralPath $File) -and -not $Force) {
            Write-Err "$File exists - review with 'diff', then pass -Force"
            exit 3
        }
        $have = @(Get-InstalledPackage)
        if ($DryRun) {
            Write-Host ('WOULD write {0} package(s) to {1}' -f $have.Count, $File) -ForegroundColor Cyan
            Write-Host 'Dry run complete; no changes written.' -ForegroundColor Yellow
            exit 0
        }
        Write-PackageConfig -Ids $have -Path $File
        Write-Ok ('wrote {0} package(s) to {1}' -f $have.Count, $File)
        exit 0
    }

    'install' {
        if ($DryRun) {
            # Deliberately does not call choco, which is why this branch reads
            # the file and stops rather than diffing against the machine.
            # Even `choco list` creates %TEMP%\chocolatey and touches %APPDATA%,
            # so a preview that asked "what is missing" would make this
            # script's own "no changes written" claim false - and did, on the
            # native Windows runner, where the contract suite caught it.
            # 'check' answers the missing-package question; it talks to
            # Chocolatey and is not held to this contract.
            $wanted = @(Get-WantedPackage -Path $File)
            Write-Info "(dry-run) would ensure $($wanted.Count) package(s) from $File are installed"
            foreach ($id in $wanted) { Write-Host "WOULD    $id" -ForegroundColor Cyan }
            Write-Info 'dry run complete; no changes written'
            exit 0
        }

        $wanted = @(Get-WantedPackage -Path $File)
        $have = @(Get-InstalledPackage)
        $missing = @($wanted | Where-Object { $_ -notin $have })

        if (-not $missing) {
            Write-Ok ('nothing to do; all {0} package(s) are installed' -f $wanted.Count)
            exit 0
        }

        # One invocation rather than a loop: choco resolves the set together,
        # and a per-package loop turns one dependency resolution into dozens.
        & choco.exe install @missing -y
        $rc = $LASTEXITCODE
        # 1641 and 3010 are Windows installer "success, reboot required" codes;
        # choco passes them through and they are not failures.
        if ($rc -notin 0, 1641, 3010) {
            Write-Err "choco install failed with exit code $rc"
            exit 1
        }
        if ($rc -in 1641, 3010) { Write-Warn 'a package requested a reboot' }
        Write-Ok ('installed {0} package(s)' -f $missing.Count)
        exit 0
    }
}
