<#
.SYNOPSIS
    Everyday WSL2 maintenance: list distros with disk usage, back up, shrink.

.DESCRIPTION
    Actions:
      list      Distros with state, WSL version, VHDX path and size on disk.
      backup    Export a distro to a dated .tar (wsl --export). Safe to run
                while the distro is running.
      compact   Shrink a distro's VHDX after deleting files inside it (WSL2
                virtual disks grow but never shrink on their own). Shuts WSL
                down first, then compacts via diskpart. Needs elevation.
      sparse    Newer alternative to compact: mark the VHDX sparse so it
                returns space to Windows automatically from then on
                (wsl --manage <distro> --set-sparse true).
      shutdown  Stop all WSL distros and the VM (frees the RAM WSL holds).

.EXAMPLE
    .\wsl_manage.ps1 list
    .\wsl_manage.ps1 backup -Distro Ubuntu -DestDir D:\Backups
    .\wsl_manage.ps1 compact -Distro Ubuntu
    .\wsl_manage.ps1 sparse -Distro Ubuntu
    .\wsl_manage.ps1 shutdown
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('list', 'backup', 'compact', 'sparse', 'shutdown')]
    [string]$Action = 'list',
    [string]$Distro,
    [string]$DestDir = "$env:USERPROFILE\wsl-backups",
    [switch]$Off   # sparse only: pass to set sparse=false instead of true
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    Write-Error 'wsl.exe not found - is WSL installed? (wsl --install)'
    exit 2
}
# wsl.exe exists as a stub even when WSL itself was never installed - probe
# for a working install before doing anything (its own error output is
# UTF-16 and prints as garbage in most consoles, so use our own message).
wsl.exe --status *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Error "WSL is not installed or not operational ('wsl --status' exited $LASTEXITCODE). Install with: wsl --install" -ErrorAction Continue
    exit 2
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

# Registered distros with their install locations, from the registry (the
# only reliable place the VHDX paths live).
function Get-DistroInfo {
    $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    Get-ChildItem $lxss -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath
        if (-not $p.DistributionName) { return }
        $vhdx = Join-Path $p.BasePath 'ext4.vhdx'
        [PSCustomObject]@{
            Name     = $p.DistributionName
            Version  = $p.Version
            BasePath = $p.BasePath
            Vhdx     = $vhdx
            VhdxSize = if (Test-Path $vhdx) { (Get-Item $vhdx).Length } else { 0 }
        }
    }
}

function Resolve-Distro {
    param([string]$Name)
    if (-not $Name) {
        Write-Error "This action needs -Distro <name>. Registered: $((Get-DistroInfo).Name -join ', ')"
        exit 3
    }
    $info = Get-DistroInfo | Where-Object Name -eq $Name
    if (-not $info) {
        Write-Error "No registered distro named '$Name'. Registered: $((Get-DistroInfo).Name -join ', ')"
        exit 3
    }
    $info
}

switch ($Action) {
    'list' {
        # wsl -l -v knows running state; the registry knows sizes. Join them.
        # wsl.exe prints UTF-16; force PowerShell to read it correctly.
        $prev = [Console]::OutputEncoding
        [Console]::OutputEncoding = [Text.Encoding]::Unicode
        $states = @{}
        try {
            (wsl.exe --list --verbose) -split "`n" | Select-Object -Skip 1 | ForEach-Object {
                $line = $_.Trim() -replace '^\*\s*', ''
                if ($line -match '^(\S+)\s+(\S+)\s+(\d+)') {
                    $states[$Matches[1]] = $Matches[2]
                }
            }
        } finally {
            [Console]::OutputEncoding = $prev
        }

        Get-DistroInfo | ForEach-Object {
            [PSCustomObject]@{
                Name    = $_.Name
                State   = if ($states.ContainsKey($_.Name)) { $states[$_.Name] } else { 'Unknown' }
                Disk    = Format-Size $_.VhdxSize
                Vhdx    = $_.Vhdx
            }
        } | Format-Table -AutoSize
    }

    'backup' {
        $info = Resolve-Distro $Distro
        if (-not (Test-Path $DestDir)) {
            New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
        }
        $stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
        $out = Join-Path $DestDir "$($info.Name)_$stamp.tar"
        Write-Host "Exporting '$($info.Name)' -> $out (this can take a while)..."
        wsl.exe --export $info.Name $out
        if ($LASTEXITCODE -ne 0) {
            Write-Error "wsl --export failed (exit $LASTEXITCODE)"
            exit 1
        }
        Write-Host ("Done: {0} ({1})" -f $out, (Format-Size (Get-Item $out).Length)) -ForegroundColor Green
        Write-Host "Restore with: wsl --import $($info.Name)-restored <install-dir> `"$out`""
    }

    'compact' {
        $isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) {
            Write-Error 'compact needs an elevated (Administrator) PowerShell - diskpart requirement.'
            exit 4
        }
        $info = Resolve-Distro $Distro
        $before = (Get-Item $info.Vhdx).Length

        Write-Host 'Shutting down WSL (all distros)...'
        wsl.exe --shutdown

        # diskpart has no CLI args - it reads a script file.
        $dpScript = Join-Path $env:TEMP "wsl_compact_$PID.txt"
        @(
            "select vdisk file=`"$($info.Vhdx)`""
            'attach vdisk readonly'
            'compact vdisk'
            'detach vdisk'
        ) | Set-Content -Path $dpScript -Encoding ascii
        try {
            diskpart /s $dpScript
        } finally {
            Remove-Item $dpScript -Force -ErrorAction SilentlyContinue
        }

        $after = (Get-Item $info.Vhdx).Length
        Write-Host ("VHDX: {0} -> {1} (reclaimed {2})" -f `
            (Format-Size $before), (Format-Size $after), (Format-Size ($before - $after))) -ForegroundColor Green
        Write-Host "Tip: run '.\wsl_manage.ps1 sparse -Distro $($info.Name)' once and future space is returned automatically."
    }

    'sparse' {
        $info = Resolve-Distro $Distro
        $value = if ($Off) { 'false' } else { 'true' }
        wsl.exe --manage $info.Name --set-sparse $value
        if ($LASTEXITCODE -ne 0) {
            Write-Error "wsl --manage --set-sparse failed (exit $LASTEXITCODE) - needs a recent WSL (wsl --update)."
            exit 1
        }
        Write-Host "Sparse mode for '$($info.Name)' set to $value." -ForegroundColor Green
    }

    'shutdown' {
        wsl.exe --shutdown
        Write-Host 'WSL stopped (all distros + utility VM). RAM released.' -ForegroundColor Green
    }
}
