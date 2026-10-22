<#
.SYNOPSIS
    Read-only report of what is filling C:, with the tool that gives each item back.

.DESCRIPTION
    The report step that comes before clean_disk_c.ps1. That script frees
    what is safe to delete and deliberately leaves alone the things that fill
    a developer laptop: hiberfil.sys and pagefile.sys, Windows.old, the
    component store, Docker data and WSL disks. This one measures them, and
    says next to each which tool actually gives the space back -
    clean_disk_c.ps1 and the flag that reaches it, wsl_manage.ps1 for a WSL
    disk, Windows' own Storage settings, or nothing at all.

    Two actions, both read-only:

      hotspots  (default) a fixed list of known space users, each with its
                pointer, sorted by size
      tree      the largest children of -Path, to -Depth levels

    It never deletes, never follows a junction or symbolic link (so a WSL or
    Docker mount is not counted twice and a link loop cannot hang it), never
    reads file contents and never contacts the network. -IncludeDocker asks
    the local Docker daemon for 'docker system df', the same read-only call
    clean_disk_c.ps1 -DryRun makes. Folders it cannot read are skipped and
    the size is marked as a lower bound; run elevated for exact numbers.

    There is no -DryRun because there is nothing to preview. -Action has a
    validated set of two read-only values, which is what the contract checks
    look for.

.PARAMETER Path
    The folder 'tree' measures. Default: the system drive root.

.PARAMETER Depth
    How many levels 'tree' shows, 1 to 4. Default 1.

.PARAMETER Top
    How many rows each list shows, 1 to 100. Default 15.

.PARAMETER MinSizeMB
    Rows smaller than this are not shown. Default 100; 0 shows everything.

.EXAMPLE
    .\disk_usage.ps1
    .\disk_usage.ps1 hotspots -MinSizeMB 500 -IncludeDocker
    .\disk_usage.ps1 tree
    .\disk_usage.ps1 tree -Path $env:USERPROFILE -Depth 2 -Top 10

.NOTES
    Exit codes:
      0  the report ran
      2  not Windows
      3  bad arguments: -Path is not a folder, or -Depth, -Top or -MinSizeMB
         is out of range
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('hotspots', 'tree')]
    [string]$Action = 'hotspots',

    [string]$Path = '',

    # The three numbers are range-checked by hand, below, rather than with
    # ValidateRange: a binding failure under 'pwsh -File' exits 1, and a value
    # out of range is a usage error (3).
    [int]$Depth = 1,

    [int]$Top = 15,

    [long]$MinSizeMB = 100,

    [switch]$IncludeDocker,

    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$script:QuietMode = [bool]$Quiet

function Write-Info {
    param([string]$Message)
    if (-not $script:QuietMode) { Write-Host "[info] $Message" -ForegroundColor Blue }
}
function Write-Err  { param([string]$Message) Write-Host "[err ] $Message" -ForegroundColor Red }

# Byte-identical to the copies in windows/cleanup/clean_disk_c.ps1 and
# windows/wsl/wsl_manage.ps1 - see CONTRIBUTING.md for why this is duplicated.
function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

# --- measurement --------------------------------------------------------------
# The space a file takes on disk. FileInfo.Length is the logical size, which
# for a sparse or NTFS-compressed file (a WSL VHDX is the usual one) counts
# ranges that were never allocated. GetCompressedFileSizeW gives the
# allocated size. It is asked only for those two kinds of file, and for any
# other reparse-point file (a OneDrive or other Cloud Files placeholder:
# Length is the size in the cloud, the allocation is what this disk holds),
# through a
# P/Invoke that is compiled on first use and only on Windows; any failure
# (not Windows, no compiler, a path the call refuses) returns Length, so the
# worst case is the old, over-counting answer. $File needs Length, Attributes
# and FullName, which a FileInfo has.
$script:AllocatedSizeReady = $null
function Get-FileDiskSize {
    param([object]$File)
    $length = [long]$File.Length
    $kinds = [System.IO.FileAttributes]::SparseFile -bor [System.IO.FileAttributes]::Compressed -bor [System.IO.FileAttributes]::ReparsePoint
    if (([int]$File.Attributes -band [int]$kinds) -eq 0) { return $length }
    try {
        if ($null -eq $script:AllocatedSizeReady) {
            $script:AllocatedSizeReady = $false
            if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
                if (-not ('DiskUsageNative.Size' -as [type])) {
                    Add-Type -Namespace DiskUsageNative -Name Size -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern uint GetCompressedFileSizeW(string lpFileName, out uint lpFileSizeHigh);
'@
                }
                $script:AllocatedSizeReady = $true
            }
        }
        if (-not $script:AllocatedSizeReady) { return $length }
        $path = [string]$File.FullName
        if ($path.Length -ge 240 -and $path -match '^[A-Za-z]:\\') { $path = '\\?\' + $path }
        $high = [uint32]0
        $low = [DiskUsageNative.Size]::GetCompressedFileSizeW($path, [ref]$high)
        if ($low -eq [uint32]::MaxValue -and [System.Runtime.InteropServices.Marshal]::GetLastWin32Error() -ne 0) {
            return $length
        }
        return ([long]$high * 4294967296L) + [long]$low
    } catch {
        Write-Verbose ("allocated size of {0}: {1}" -f $File.FullName, $_.Exception.Message)
        return $length
    }
}

# The two lookups the size walks depend on, kept as small functions so a
# test can answer them from a table (a Cloud Files placeholder and a
# OneDrive-style reparse folder cannot be made outside Windows).
function Get-ReparseLinkInfo {
    param([string]$Path)
    return (Get-Item -LiteralPath $Path -Force -ErrorAction Stop)
}

function ConvertTo-DirectoryInfo {
    param([string]$Path)
    return (New-Object System.IO.DirectoryInfo -ArgumentList $Path)
}

# True for a reparse point that is a link to somewhere else: a symbolic link
# or junction, which Get-Item reports through LinkType or Target. Any other
# reparse point (a OneDrive / Cloud Files placeholder, a dedup stub) is data
# held on this volume. When the item cannot be examined it counts as a link,
# which is the old, safe answer: skipped.
function Test-NameSurrogateLink {
    param([object]$Item)
    try {
        $got = Get-ReparseLinkInfo -Path ([string]$Item.FullName)
    } catch {
        Write-Verbose ("{0}: {1}" -f $Item.FullName, $_.Exception.Message)
        return $true
    }
    if ($null -eq $got) { return $true }
    if ($got.LinkType) { return $true }
    if (@($got.Target) | Where-Object { $_ }) { return $true }
    return $false
}

# True for a file or folder the size walks must not enter or count: one with
# the ReparsePoint attribute that is a link (Test-NameSurrogateLink). Any other
# reparse point, such as a OneDrive Files On-Demand folder or placeholder file,
# holds data on this volume and is walked and counted.
function Test-SkippedReparse {
    param([object]$Item)
    if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) { return $false }
    return [bool](Test-NameSurrogateLink -Item $Item)
}

# An explicit stack and a try/catch per directory, rather than
# Get-ChildItem -Recurse or EnumerateFiles(AllDirectories): those stop at the
# first folder that refuses access, and .NET Framework has no option to carry
# on. A refusal here costs that one folder and is counted, so the caller can
# say the total is a lower bound.
#
# A folder or file with the ReparsePoint attribute is skipped only when it is
# a link (Test-SkippedReparse): a junction or symbolic link would count its
# target twice, and a link to an ancestor would never finish. A OneDrive or
# other Cloud Files folder or placeholder is data on this volume and is
# walked and counted. Each file counts at the space it occupies
# (Get-FileDiskSize), not its logical length. A hard-linked file counts once
# per link: sizes are apparent, and the report says so.
function Get-DirectorySize {
    param([string]$Path)
    $bytes = 0L
    $inaccessible = 0
    $stack = New-Object 'System.Collections.Generic.Stack[object]'
    $stack.Push((ConvertTo-DirectoryInfo -Path $Path))
    while ($stack.Count -gt 0) {
        $directory = $stack.Pop()
        try {
            foreach ($file in $directory.GetFiles()) {
                if (Test-SkippedReparse -Item $file) { continue }
                $bytes += Get-FileDiskSize -File $file
            }
        } catch {
            $inaccessible++
        }
        try {
            foreach ($child in $directory.GetDirectories()) {
                if (Test-SkippedReparse -Item $child) { continue }
                $stack.Push($child)
            }
        } catch {
            $inaccessible++
        }
    }
    return [pscustomobject]@{ Bytes = $bytes; Inaccessible = $inaccessible }
}

# The known space users, each with the pointer to whatever gives it back.
# The environment arrives as parameters so the list is the same function of
# its inputs everywhere, including in the contract tests. WslDisk is the list
# Find-WslDisk returns: { Name, Path }.
#
# A Hint that names 'clean_disk_c.ps1 -Flag' or 'wsl_manage.ps1 verb' is a
# claim about another script; windows/tests/contract.ps1 checks each one
# against that script's parameters, so a renamed flag fails the suite instead
# of sending somebody to a command that does not exist.
function Get-HotspotTarget {
    param(
        [string]$UserProfile,
        [string]$LocalAppData,
        [string]$ProgramData,
        [string]$SystemDrive,
        [object[]]$WslDisk = @()
    )
    $windowsDir = $SystemDrive + '\Windows'
    $storage = 'Settings > System > Storage > Temporary files; clean_disk_c.ps1 leaves it alone'
    $rows = @(
        @('file', 'Hibernation file (hiberfil.sys)', ($SystemDrive + '\hiberfil.sys'), 'powercfg /h /type reduced, or /h off; system managed, see windows/cleanup/README.md'),
        @('file', 'Page file (pagefile.sys)', ($SystemDrive + '\pagefile.sys'), 'system managed: System Properties > Advanced > Performance > Virtual memory'),
        @('file', 'Swap file (swapfile.sys)', ($SystemDrive + '\swapfile.sys'), 'system managed, used by Store apps; leave it'),
        @('dir', 'Previous Windows (Windows.old)', ($SystemDrive + '\Windows.old'), $storage),
        @('dir', 'Upgrade staging ($WINDOWS.~BT)', ($SystemDrive + '\$WINDOWS.~BT'), $storage),
        @('dir', 'Recovery agent staging ($WinREAgent)', ($SystemDrive + '\$WinREAgent'), $storage),
        @('dir', 'Recycle Bin', ($SystemDrive + '\$Recycle.Bin'), 'clean_disk_c.ps1 -IncludeRecycleBin'),
        @('dir', 'Windows Update downloads', ($windowsDir + '\SoftwareDistribution\Download'), 'clean_disk_c.ps1 -IncludeWindowsUpdate'),
        @('dir', 'Windows temp', ($windowsDir + '\Temp'), 'clean_disk_c.ps1 (a default target)'),
        @('dir', 'User temp', ($LocalAppData + '\Temp'), 'clean_disk_c.ps1 (a default target)'),
        @('dir', 'Installer cache (Windows\Installer)', ($windowsDir + '\Installer'), 'never delete: uninstall and repair need it'),
        @('dir', 'Component store (WinSxS)', ($windowsDir + '\WinSxS'), 'Dism.exe /Online /Cleanup-Image /AnalyzeComponentStore says what a cleanup would free (the folder size over-counts: most of it is hard links); the cleanup is the -IncludeComponentStore opt-in of clean_disk_c.ps1'),
        @('dir', 'Servicing logs (Logs\CBS)', ($windowsDir + '\Logs\CBS'), 'clean_disk_c.ps1 -IncludeLogs (logs older than -Days)'),
        @('dir', 'DISM logs (Logs\DISM)', ($windowsDir + '\Logs\DISM'), 'clean_disk_c.ps1 -IncludeLogs (logs older than -Days)'),
        @('file', 'Memory dump (MEMORY.DMP)', ($windowsDir + '\MEMORY.DMP'), 'clean_disk_c.ps1 -IncludeCrashDumps; copy it away first if the crash still needs analysing'),
        @('dir', 'Minidumps', ($windowsDir + '\Minidump'), 'clean_disk_c.ps1 -IncludeCrashDumps'),
        @('dir', 'Live kernel reports', ($windowsDir + '\LiveKernelReports'), 'clean_disk_c.ps1 -IncludeCrashDumps'),
        @('dir', 'User crash dumps', ($LocalAppData + '\CrashDumps'), 'clean_disk_c.ps1 -IncludeCrashDumps'),
        @('dir', 'Installer packages (Package Cache)', ($ProgramData + '\Package Cache'), 'leave it: installers need it to repair and uninstall'),
        @('dir', 'Docker (ProgramData\Docker)', ($ProgramData + '\Docker'), 'docker system prune via clean_disk_c.ps1 -IncludeDocker (no volumes, VHDX stays), or Docker Desktop > Troubleshoot > Clean / Purge data'),
        @('dir', 'Docker Desktop (ProgramData)', ($ProgramData + '\DockerDesktop'), 'Docker Desktop > Troubleshoot > Clean / Purge data'),
        @('dir', 'Docker Desktop (LocalAppData\Docker)', ($LocalAppData + '\Docker'), 'docker system prune via clean_disk_c.ps1 -IncludeDocker (no volumes, VHDX stays), or Docker Desktop > Troubleshoot > Clean / Purge data'),
        @('dir', 'NuGet packages', ($UserProfile + '\.nuget\packages'), 'clean_disk_c.ps1 -IncludeDevCaches'),
        @('dir', 'pip cache', ($LocalAppData + '\pip\cache'), 'clean_disk_c.ps1 -IncludeDevCaches'),
        @('dir', 'npm cache', ($LocalAppData + '\npm-cache'), 'clean_disk_c.ps1 -IncludeDevCaches'),
        @('dir', 'Gradle', ($UserProfile + '\.gradle'), 'manual: gradle --stop, then delete .gradle\caches'),
        @('dir', 'Maven repository', ($UserProfile + '\.m2\repository'), 'manual: re-downloaded on the next build'),
        @('dir', 'Cargo registry', ($UserProfile + '\.cargo\registry'), 'manual: re-downloaded on the next build'),
        @('dir', 'Rust toolchains (.rustup)', ($UserProfile + '\.rustup'), 'rustup toolchain list, then rustup toolchain uninstall'),
        @('dir', 'Go module cache', ($UserProfile + '\go\pkg\mod'), 'go clean -modcache'),
        @('dir', 'minikube', ($UserProfile + '\.minikube'), 'minikube delete --all'),
        @('dir', 'kubectl cache', ($UserProfile + '\.kube\cache'), 'manual: safe to delete, kubectl rebuilds it'),
        @('dir', 'Vagrant boxes', ($UserProfile + '\.vagrant.d'), 'vagrant box prune'),
        @('dir', 'Miniconda', ($UserProfile + '\miniconda3'), 'conda clean --all'),
        @('dir', 'Anaconda', ($UserProfile + '\anaconda3'), 'conda clean --all'),
        @('dir', 'Downloads', ($UserProfile + '\Downloads'), 'yours to sort'),
        @('dir', 'Android SDK', ($LocalAppData + '\Android\Sdk'), 'sdkmanager --uninstall for old platforms and system images'),
        @('dir', 'Android emulators (.android\avd)', ($UserProfile + '\.android\avd'), 'avdmanager delete avd -n NAME'),
        @('dir', 'VirtualBox VMs', ($UserProfile + '\VirtualBox VMs'), 'VBoxManage unregistervm NAME --delete, for VMs you no longer need')
    )
    foreach ($row in $rows) {
        [pscustomobject]@{ Kind = $row[0]; Label = $row[1]; Path = $row[2]; Hint = $row[3] }
    }
    foreach ($disk in $WslDisk) {
        [pscustomobject]@{
            Kind  = 'file'
            Label = 'WSL disk: {0}' -f $disk.Name
            Path  = $disk.Path
            Hint  = 'wsl_manage.ps1 df shows what a compact would give back, then wsl_manage.ps1 compact'
        }
    }
}

# Every WSL distro's disk, from the registry rather than from 'wsl --list':
# the registry also knows the distros 'wsl --import' and wsl_manage.ps1
# restore put somewhere other than the default, and reading it does not start
# WSL. Absent on Linux and on machines without WSL, which is an empty list.
function Find-WslDisk {
    $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    $disks = @()
    try {
        foreach ($key in @(Get-ChildItem -Path $lxss -ErrorAction Stop)) {
            $props = Get-ItemProperty -Path $key.PSPath -ErrorAction Stop
            if (-not $props.BasePath) { continue }
            $base = [string]$props.BasePath
            if ($base.StartsWith('\\?\')) { $base = $base.Substring(4) }
            $name = [string]$props.DistributionName
            if (-not $name) { $name = $key.PSChildName }
            $disks += [pscustomobject]@{ Name = $name; Path = (Join-Path $base 'ext4.vhdx') }
        }
    } catch {
        Write-Verbose ("WSL registry: {0}" -f $_.Exception.Message)
    }
    return $disks
}

# One tree node: the folder's own size and, above -MaxLevel, its children.
# Each file is read once however deep the tree is drawn: below the last level
# the subtree is summed by Get-DirectorySize, above it the node adds up its
# files and its children's totals.
function Get-TreeNode {
    param(
        [string]$Path,
        [string]$Name,
        [int]$Level,
        [int]$MaxLevel
    )
    if ($Level -ge $MaxLevel) {
        $size = Get-DirectorySize -Path $Path
        return [pscustomobject]@{ Name = $Name; Bytes = $size.Bytes; Inaccessible = $size.Inaccessible; Children = @() }
    }
    $directory = ConvertTo-DirectoryInfo -Path $Path
    $bytes = 0L
    $inaccessible = 0
    $children = @()
    try {
        foreach ($file in $directory.GetFiles()) {
            if (Test-SkippedReparse -Item $file) { continue }
            $fileBytes = Get-FileDiskSize -File $file
            $bytes += $fileBytes
            $children += [pscustomobject]@{ Name = $file.Name; Bytes = $fileBytes; Inaccessible = 0; Children = @() }
        }
    } catch {
        $inaccessible++
    }
    try {
        foreach ($child in $directory.GetDirectories()) {
            if (Test-SkippedReparse -Item $child) { continue }
            $node = Get-TreeNode -Path $child.FullName -Name $child.Name -Level ($Level + 1) -MaxLevel $MaxLevel
            $bytes += $node.Bytes
            $inaccessible += $node.Inaccessible
            $children += $node
        }
    } catch {
        $inaccessible++
    }
    return [pscustomobject]@{ Name = $Name; Bytes = $bytes; Inaccessible = $inaccessible; Children = $children }
}

function Write-TreeLevel {
    param(
        [object[]]$Nodes,
        [int]$Indent,
        [int]$Limit,
        [long]$MinBytes
    )
    $shown = @($Nodes | Where-Object { $_.Bytes -ge $MinBytes } | Sort-Object -Property Bytes -Descending | Select-Object -First $Limit)
    foreach ($node in $shown) {
        $mark = ''
        if ($node.Inaccessible -gt 0) { $mark = '  (lower bound: run elevated for the exact size)' }
        Write-Host ('{0,10}  {1}{2}{3}' -f (Format-Size $node.Bytes), ('  ' * $Indent), $node.Name, $mark)
        if ($node.Children.Count -gt 0) {
            Write-TreeLevel -Nodes $node.Children -Indent ($Indent + 1) -Limit $Limit -MinBytes $MinBytes
        }
    }
}

function Show-DockerUsage {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Host ('SKIP  {0,-44} (docker not found)' -f 'Docker') -ForegroundColor DarkGray
        return
    }
    Write-Host ''
    Write-Host 'docker system df (local daemon; read-only):'
    # 'Continue' so a daemon that is not running prints its error and the
    # report goes on, under Windows PowerShell 5.1 as well.
    $ErrorActionPreference = 'Continue'
    try {
        & docker system df 2>&1 | ForEach-Object { Write-Host "  $_" }
    } catch {
        Write-Host "  docker system df failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# --- arguments --------------------------------------------------------------
# Ahead of the preflight, as in every script here.
if ($Depth -lt 1 -or $Depth -gt 4) {
    Write-Err "-Depth must be between 1 and 4; got: $Depth"
    exit 3
}
if ($Top -lt 1 -or $Top -gt 100) {
    Write-Err "-Top must be between 1 and 100; got: $Top"
    exit 3
}
if ($MinSizeMB -lt 0 -or $MinSizeMB -gt 1048576) {
    Write-Err "-MinSizeMB must be between 0 and 1048576; got: $MinSizeMB"
    exit 3
}
if ($Path -and -not (Test-Path -LiteralPath $Path -PathType Container)) {
    Write-Err "-Path is not a folder: $Path"
    exit 3
}

# --- preflight -------------------------------------------------------------
# Mirrors status.ps1: wrong platform is 2. Windows PowerShell 5.1 does not
# define $IsWindows at all, hence the edition test.
if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    Write-Err 'this script targets Windows'
    exit 2
}

$systemDrive = $env:SystemDrive
if (-not $systemDrive) { $systemDrive = 'C:' }
$minBytes = $MinSizeMB * 1MB

Write-Host ''
Write-Host "disk_usage: $Action" -ForegroundColor White
try {
    $drive = Get-PSDrive -Name $systemDrive.TrimEnd(':') -ErrorAction Stop
    $total = $drive.Used + $drive.Free
    Write-Info ('{0} {1} free of {2}' -f $systemDrive, (Format-Size $drive.Free), (Format-Size $total))
} catch {
    Write-Info "no free-space figure for $systemDrive ($($_.Exception.Message))"
}
$isAdmin = $false
try {
    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {
    Write-Verbose $_.Exception.Message
}
if (-not $isAdmin) {
    Write-Info 'not elevated: folders under Windows and other profiles may be partly unreadable, so their sizes are lower bounds'
}

# Telling NTFS hard links apart needs a handle on every file, which a walk of
# WinSxS or a profile cannot afford, so a file with several links counts once
# per link. Said up front rather than left to look like an exact figure.
Write-Info 'sizes are apparent: a file with several hard links (WinSxS) counts once per link, so totals can exceed the space really used'

if ($Action -eq 'tree') {
    if (-not $Path) { $Path = $systemDrive + '\' }
    Write-Info "measuring $Path to depth $Depth; this can take minutes on ${systemDrive}\"
    $root = Get-TreeNode -Path $Path -Name $Path -Level 0 -MaxLevel $Depth
    Write-Host ''
    Write-Host ('{0,10}  {1}' -f (Format-Size $root.Bytes), $Path) -ForegroundColor White
    Write-TreeLevel -Nodes $root.Children -Indent 1 -Limit $Top -MinBytes $minBytes
    if ($root.Inaccessible -gt 0) {
        Write-Info ('{0} folder(s) could not be read; totals are lower bounds' -f $root.Inaccessible)
    }
} else {
    $targets = @(Get-HotspotTarget -UserProfile $env:USERPROFILE -LocalAppData $env:LOCALAPPDATA `
            -ProgramData $env:ProgramData -SystemDrive $systemDrive -WslDisk (Find-WslDisk))
    # Said before measuring: a profile with a large Downloads or SDK folder
    # takes a while, and a silent prompt reads as a hang.
    Write-Info ('measuring {0} locations; a large profile can take a minute' -f $targets.Count)
    Write-Host ''

    $found = @()
    $missing = @()
    foreach ($target in $targets) {
        if ($target.Kind -eq 'file') {
            $item = $null
            try { $item = Get-Item -LiteralPath $target.Path -Force -ErrorAction Stop } catch { Write-Verbose $_.Exception.Message }
            if ($null -eq $item) { $missing += $target; continue }
            $found += [pscustomobject]@{ Label = $target.Label; Bytes = (Get-FileDiskSize -File $item); Hint = $target.Hint; Partial = $false }
        } else {
            if (-not (Test-Path -LiteralPath $target.Path -PathType Container)) { $missing += $target; continue }
            $size = Get-DirectorySize -Path $target.Path
            $found += [pscustomobject]@{ Label = $target.Label; Bytes = $size.Bytes; Hint = $target.Hint; Partial = ($size.Inaccessible -gt 0) }
        }
    }

    $sorted = @($found | Sort-Object -Property Bytes -Descending)
    $shown = @($sorted | Where-Object { $_.Bytes -ge $minBytes } | Select-Object -First $Top)
    foreach ($row in $shown) {
        $hint = $row.Hint
        if ($row.Partial) { $hint += ' (lower bound: run elevated for the exact size)' }
        Write-Host ('FOUND {0,-44} {1,10}  {2}' -f $row.Label, (Format-Size $row.Bytes), $hint) -ForegroundColor Cyan
    }
    if (-not $script:QuietMode) {
        foreach ($target in $missing) {
            Write-Host ('SKIP  {0,-44} (not found)' -f $target.Label) -ForegroundColor DarkGray
        }
    }
    $hidden = $sorted.Count - $shown.Count
    if ($hidden -gt 0) {
        Write-Info ('{0} more location(s) not shown: under {1} MB or past the first {2}' -f $hidden, $MinSizeMB, $Top)
    }

    # The rows clean_disk_c.ps1 can reach, totalled, and the command line that
    # reaches them - preview first, the order this repository uses everywhere.
    # Only a hint that STARTS with the script counts: the component store
    # names it too, but its folder size is mostly hard links and would turn
    # the total into fiction.
    $reachable = @($found | Where-Object { $_.Hint -match '^clean_disk_c\.ps1' })
    if ($reachable.Count -gt 0) {
        $reachableBytes = ($reachable | Measure-Object -Property Bytes -Sum).Sum
        $flags = @($reachable |
            ForEach-Object { [regex]::Matches($_.Hint, 'clean_disk_c\.ps1 (-Include\w+)') } |
            ForEach-Object { $_.Groups[1].Value } |
            Select-Object -Unique)
        Write-Host ''
        Write-Host ('Reachable with clean_disk_c.ps1: up to {0} (it keeps temp files newer than -Days)' -f (Format-Size $reachableBytes)) -ForegroundColor Cyan
        $flagText = ''
        if ($flags.Count -gt 0) { $flagText = ' ' + ($flags -join ' ') }
        Write-Host ('  .\clean_disk_c.ps1 -DryRun{0}' -f $flagText)
        Write-Host ('  .\clean_disk_c.ps1 -Yes{0}' -f $flagText)
    }

    if ($IncludeDocker) {
        Show-DockerUsage
    }
}
exit 0
