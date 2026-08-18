<#
.SYNOPSIS
    Starting point for a new PowerShell helper in this repository.

.DESCRIPTION
    Copy this file, rename it, and delete what you do not need. It is a working
    no-op as it stands, so the contract checks exercise it directly.

    Note the deliberate divergence from PowerShell convention: state changes go
    behind a hand-rolled [switch]$DryRun rather than SupportsShouldProcess, so
    these scripts read the same as the Bash ones and can report a running total
    of what a real run would do. CONTRIBUTING.md explains the trade-off.

.EXAMPLE
    .\new_script.ps1 -DryRun
    .\new_script.ps1 -Target Caches
    .\new_script.ps1 -DryRun -PassThru
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$PassThru,
    [ValidateSet('All', 'Caches', 'Logs')]
    [string]$Target = 'All'
)

$ErrorActionPreference = 'Stop'
$script:TotalFreed = 0L
$script:TotalSelected = 0L
$script:FailureCount = 0

# Byte-identical to the copies in windows/cleanup/clean_disk_c.ps1 and
# windows/wsl/wsl_manage.ps1 - see CONTRIBUTING.md for why this is duplicated.
# Keep PowerShell sources pure ASCII: PSUseBOMForUnicodeEncodedFile fires on a
# non-ASCII file with no BOM, and a BOM would fight the LF pinning in
# .gitattributes.
function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

# Reports under -DryRun, acts otherwise. Verbs are WOULD / CLEAN / SKIP so the
# two modes line up column-for-column and are easy to diff by eye.
function Invoke-Step {
    param(
        [string]$Label,
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        Write-Host ('SKIP  {0,-38} {1,10}' -f $Label, '(not found)') -ForegroundColor DarkGray
        return
    }

    $bytes = (Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if (-not $bytes) { $bytes = 0L }
    $script:TotalSelected += $bytes

    if ($DryRun) {
        Write-Host ('WOULD {0,-38} {1,10}' -f $Label, (Format-Size $bytes)) -ForegroundColor Cyan
        return
    }

    try {
        Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
        if (Test-Path $Path) {
            throw "target still exists after removal: $Path"
        }
        $script:TotalFreed += $bytes
        Write-Host ('CLEAN {0,-38} {1,10}' -f $Label, (Format-Size $bytes)) -ForegroundColor Green
    } catch {
        $script:FailureCount++
        Write-Host ('FAIL  {0,-38} {1}' -f $Label, $_.Exception.Message) -ForegroundColor Red
    }
}

Write-Host ''
Write-Host "Target: $Target" -ForegroundColor White
if ($DryRun) {
    Write-Host 'Dry run - nothing will be changed.' -ForegroundColor Yellow
}
Write-Host ''

# [IO.Path]::GetTempPath() rather than $env:TEMP: it resolves to the same
# directory on Windows and is defined on every platform, so the contract suite
# can run this template's dry run through to the end on its Linux runner.
Invoke-Step -Label 'example target' -Path (Join-Path ([IO.Path]::GetTempPath()) 'pretty-useful-example')

Write-Host ''
if ($DryRun) {
    Write-Host 'Dry run complete; no changes written.' -ForegroundColor Yellow
} elseif ($script:FailureCount -gt 0) {
    Write-Host ("Failed steps: {0}" -f $script:FailureCount) -ForegroundColor Red
} else {
    Write-Host ('Freed {0}' -f (Format-Size $script:TotalFreed)) -ForegroundColor Green
}

$status = if ($script:FailureCount -gt 0) { 'Failed' } elseif ($DryRun) { 'Preview' } else { 'Success' }
if ($PassThru) {
    # Human-readable progress stays on the host stream; this single structured
    # result is safe to pipe to ConvertTo-Json, Export-Csv, or a calling script.
    [PSCustomObject]@{
        Target        = $Target
        DryRun        = [bool]$DryRun
        SelectedBytes = $script:TotalSelected
        FreedBytes    = $script:TotalFreed
        Status        = $status
    }
}

if ($script:FailureCount -gt 0) { exit 1 }
exit 0
