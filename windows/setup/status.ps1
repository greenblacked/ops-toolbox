<#
.SYNOPSIS
    One-screen verdict for a Windows workstation.

.DESCRIPTION
    The Windows counterpart of linux/status.sh and macos-initial-setup/status.sh.
    Read-only: no log, no elevation, no writes. The long report is still
    workstation_doctor.ps1.

    Sections: os, disk, winget, wsl, reboot, git.

    -ListSections and comment-based help answer before the Windows preflight,
    so they work on Linux pwsh. There is no -DryRun because there is nothing
    to preview. -Action takes one value, 'report', which is the read-only
    default the contract checks look for.

.PARAMETER ListSections
    Print stable section ids and exit 0.

.PARAMETER Only
    Comma-separated section ids. Unknown ids exit 3. An empty selection
    after parsing exits 4.

.PARAMETER Action
    The only accepted value is 'report'. Present so a read-only script
    satisfies the preview-before-changing contract.

.EXAMPLE
    .\status.ps1
    .\status.ps1 -ListSections
    .\status.ps1 -Only disk,git
    .\status.ps1 -Action report

.NOTES
    Exit codes:
      0  every selected section is ok
      1  at least one section warned
      2  not Windows
      3  invalid arguments
      4  -Only selected nothing
#>
[CmdletBinding()]
param(
    [switch]$ListSections,

    [string]$Only = '',

    [Parameter(Position = 0)]
    [ValidateSet('report')]
    [string]$Action = 'report'
)

$ErrorActionPreference = 'Stop'
$script:Warned = 0

$SectionOrder = @('os', 'disk', 'winget', 'wsl', 'reboot', 'git')

function Write-Ok   { param([string]$Message) Write-Host "[ ok ] $Message" -ForegroundColor Green }
function Write-Warn {
    param([string]$Message)
    $script:Warned++
    Write-Host "[warn] $Message" -ForegroundColor Yellow
}
function Write-Info { param([string]$Message) Write-Host "[info] $Message" -ForegroundColor Blue }
function Write-Err  { param([string]$Message) Write-Host "[err ] $Message" -ForegroundColor Red }

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

if ($ListSections) {
    $SectionOrder | ForEach-Object { Write-Output $_ }
    exit 0
}

$selected = @()
if ($Only) {
    foreach ($raw in ($Only -split ',')) {
        $id = $raw.Trim()
        if (-not $id) { continue }
        if ($SectionOrder -notcontains $id) {
            Write-Err "unknown section in -Only: $id (see -ListSections)"
            exit 3
        }
        $selected += $id
    }
    if ($selected.Count -eq 0) {
        Write-Err '-Only selected nothing'
        exit 4
    }
} else {
    $selected = @($SectionOrder)
}

function Test-Want {
    param([string]$Id)
    return ($selected -contains $Id)
}

if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    Write-Err 'this script targets Windows'
    exit 2
}

Write-Host "=== status ($Action) ==="

if (Test-Want os) {
    $caption = 'Windows'
    try {
        $caption = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).Caption
    } catch {
        $caption = $PSVersionTable.OS
    }
    $arch = $env:PROCESSOR_ARCHITECTURE
    Write-Ok ("os        {0} ({1})" -f $caption, $arch)
}

if (Test-Want disk) {
    try {
        $drive = Get-PSDrive -Name C -ErrorAction Stop
        $free = [int64]$drive.Free
        if ($free -lt 20GB) {
            Write-Warn ("disk      {0} free on C: - under 20 GB" -f (Format-Size $free))
        } else {
            Write-Ok ("disk      {0} free on C:" -f (Format-Size $free))
        }
    } catch {
        Write-Warn "disk      could not read free space on C:"
    }
}

if (Test-Want winget) {
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd) {
        Write-Ok "winget    $($cmd.Source)"
    } else {
        Write-Warn 'winget    not on PATH - run .\winget_configure.ps1 show'
    }
}

if (Test-Want wsl) {
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($wsl) {
        Write-Ok 'wsl       wsl.exe is on PATH'
    } else {
        Write-Info 'wsl       wsl.exe not on PATH'
    }
}

if (Test-Want reboot) {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    $pending = $false
    foreach ($path in $paths) {
        if (Test-Path $path) { $pending = $true }
    }
    if ($pending) {
        Write-Warn 'reboot    a reboot is pending'
    } else {
        Write-Ok 'reboot    no pending-reboot flags'
    }
}

if (Test-Want git) {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) {
        Write-Warn 'git       git is not on PATH'
    } else {
        $name = git config --global --get user.name 2>$null
        $email = git config --global --get user.email 2>$null
        if (-not $name -or -not $email) {
            Write-Warn 'git       global user.name / user.email is incomplete'
        } else {
            Write-Ok ("git       {0} <{1}>" -f $name, $email)
        }
    }
}

if ($script:Warned -eq 0) {
    Write-Info 'next      .\stay_fresh.ps1 -DryRun'
    exit 0
}
Write-Info 'next      .\workstation_doctor.ps1'
exit 1
