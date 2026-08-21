<#
.SYNOPSIS
    Capture and restore the winget side of a Windows machine.

.DESCRIPTION
    The Windows counterpart of macos-initial-setup/brewfile.sh, with the same
    command and exit-code conventions, so the two machines are managed the
    same way:

      export   Write the currently installed packages to a versioned JSON file
      list     Print stable installed package ids to stdout (read-only)
      check    Report whether everything in the file is installed (read-only)
      import   Install everything the file lists that is missing
      diff     Show what export would change, without writing

    The distinction brewfile.sh draws applies here too: a curated install list
    is the intent, this file is the fact. Keep it committed and you can rebuild
    a machine from it.

    Only packages winget can identify by id are exported. winget records
    anything it cannot map as an "unknown" entry, which import silently skips -
    export reports that count so it is visible rather than surprising.

.EXAMPLE
    .\winget_bootstrap.ps1 diff
    .\winget_bootstrap.ps1 list
    .\winget_bootstrap.ps1 export -Force
    .\winget_bootstrap.ps1 import -DryRun
    .\winget_bootstrap.ps1 check

.NOTES
    Exit codes, matching brewfile.sh:
      0  success (for check: everything present)
      1  command failed (for check: something is missing)
      2  preflight checks failed
      3  bad arguments
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('export', 'list', 'check', 'import', 'diff')]
    [string]$Action,

    [string]$File,
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

if (-not $Action) {
    Get-Help -Full $PSCommandPath | Out-String | Write-Host
    exit 3
}

if (-not $File) {
    $File = Join-Path $PSScriptRoot 'winget-packages.json'
}

function Write-Info { param([string]$Message) Write-Host "[info] $Message" -ForegroundColor Blue }
function Write-Ok   { param([string]$Message) Write-Host "[ ok ] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[warn] $Message" -ForegroundColor Yellow }
function Write-Err  { param([string]$Message) Write-Host "[err ] $Message" -ForegroundColor Red }

# --- preflight -------------------------------------------------------------
# Mirrors brewfile.sh: wrong platform is 2, missing tool is 2.
if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    Write-Err 'this script targets Windows'
    exit 2
}
if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
    Write-Err 'winget is not installed or not on PATH - install "App Installer" from the Microsoft Store'
    exit 2
}

# Writes winget's export JSON to $Path. Kept in one place because export and
# diff both need a fresh snapshot and must produce byte-identical output for
# the comparison to mean anything.
function Export-Snapshot {
    param([string]$Path)

    winget export --output $Path --accept-source-agreements --disable-interactivity 2>&1 |
        Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "winget export exited $LASTEXITCODE"
        return $false
    }
    return $true
}

# The export format nests packages under Sources[].Packages[]. Pull them out as
# a flat, sorted id list so diffs are stable and reviewable rather than being
# reordered by whatever winget felt like emitting.
function Get-PackageIdentifier {
    param([string]$Path)

    $doc = Get-Content -Path $Path -Raw | ConvertFrom-Json
    $ids = @()
    foreach ($source in @($doc.Sources)) {
        foreach ($pkg in @($source.Packages)) {
            if ($pkg.PackageIdentifier) { $ids += $pkg.PackageIdentifier }
        }
    }
    return ($ids | Sort-Object -Unique)
}

switch ($Action) {

    'list' {
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            if (-not (Export-Snapshot -Path $tmp)) { exit 1 }
            foreach ($id in (Get-PackageIdentifier -Path $tmp)) {
                Write-Output $id
            }
        } finally {
            if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        }
    }

    'export' {
        if ((Test-Path $File) -and -not $Force) {
            Write-Err "$File exists - review changes with 'diff', then pass -Force"
            exit 1
        }
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            if (-not (Export-Snapshot -Path $tmp)) { exit 1 }
            Move-Item -Path $tmp -Destination $File -Force
        } finally {
            if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        }

        $ids = Get-PackageIdentifier -Path $File
        Write-Ok "wrote $File"
        Write-Host ('  {0} packages' -f $ids.Count) -ForegroundColor DarkGray

        # winget writes these for anything it could not resolve to a source id.
        # import skips them without comment, so say so now.
        $raw = Get-Content -Path $File -Raw
        $unknown = ([regex]::Matches($raw, '"unknown"')).Count
        if ($unknown -gt 0) {
            Write-Warn "$unknown package(s) had no winget id and will be skipped on import"
        }
    }

    'diff' {
        if (-not (Test-Path -LiteralPath $File -PathType Leaf)) {
            Write-Err "$File does not exist - run 'export' first"
            exit 1
        }
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            if (-not (Export-Snapshot -Path $tmp)) { exit 1 }
            $committed = Get-PackageIdentifier -Path $File
            $current = Get-PackageIdentifier -Path $tmp
        } finally {
            if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        }

        $added = $current | Where-Object { $_ -notin $committed }
        $removed = $committed | Where-Object { $_ -notin $current }

        if (-not $added -and -not $removed) {
            Write-Ok "$File matches this machine"
            exit 0
        }
        Write-Host "--- $File (committed)" -ForegroundColor White
        Write-Host '+++ this machine' -ForegroundColor White
        foreach ($id in $removed) { Write-Host "- $id" -ForegroundColor Red }
        foreach ($id in $added)   { Write-Host "+ $id" -ForegroundColor Green }
        Write-Info "run 'export -Force' to accept these"
    }

    'check' {
        if (-not (Test-Path -LiteralPath $File -PathType Leaf)) {
            Write-Err "$File does not exist"
            exit 1
        }
        $wanted = Get-PackageIdentifier -Path $File
        if (-not $wanted) {
            Write-Err "$File lists no packages"
            exit 1
        }

        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            if (-not (Export-Snapshot -Path $tmp)) { exit 1 }
            $installed = Get-PackageIdentifier -Path $tmp
        } finally {
            if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        }

        $missing = $wanted | Where-Object { $_ -notin $installed }
        if (-not $missing) {
            Write-Ok "everything in $File is installed ($($wanted.Count) packages)"
            exit 0
        }
        foreach ($id in $missing) { Write-Host "MISSING  $id" -ForegroundColor Yellow }
        Write-Warn "$($missing.Count) missing - 'import' will add them"
        exit 1
    }

    'import' {
        if (-not (Test-Path -LiteralPath $File -PathType Leaf)) {
            Write-Err "$File does not exist"
            exit 1
        }

        if ($DryRun) {
            $wanted = Get-PackageIdentifier -Path $File
            # Do not call winget in preview mode. Even its read-only export
            # populates source caches under LOCALAPPDATA and TEMP, which makes
            # the script's "no changes written" contract false on Windows.
            Write-Info "(dry-run) would ensure $($wanted.Count) package(s) from $File are installed"
            foreach ($id in $wanted) { Write-Host "WOULD    $id" -ForegroundColor Cyan }
            Write-Info 'dry run complete; no changes written'
            exit 0
        }

        # --no-upgrade matches brewfile.sh's `brew bundle install --no-upgrade`:
        # add what is missing, leave what is already there alone.
        winget import --import-file $File --accept-package-agreements `
            --accept-source-agreements --no-upgrade --disable-interactivity
        if ($LASTEXITCODE -ne 0) {
            Write-Err "winget import exited $LASTEXITCODE"
            exit 1
        }
        Write-Ok 'package list applied'
    }
}
