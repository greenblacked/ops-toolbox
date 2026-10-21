<#
.SYNOPSIS
    Contract checks for windows/wsl/wsl_manage.ps1.

.DESCRIPTION
    contract.ps1 holds the checks every PowerShell script here shares: it
    parses, it has help, its documented flags exist, a dry run writes nothing.
    This file holds the ones that belong to wsl_manage.ps1 alone, in a file of
    its own so the two can change without editing each other. run.sh runs both
    and fails if either fails.

    contract.ps1 says the functions of clean_disk_c.ps1 "cannot be reached for
    unit testing". That is about dot-sourcing: the script's top level throws
    or exits off Windows, and dot-sourcing runs the top level. wsl_manage.ps1
    has the same shape, since it probes wsl.exe and exits 2 before any action.
    This file takes the other route. Import-ScriptFunction parses the script
    with the PowerShell parser, finds one function definition by name in the
    syntax tree, and defines only that function here. The script body never
    runs. That is what lets the pure functions be tested with fixture strings
    on a Linux runner, the way CONTRIBUTING.md asks of a parser: the logic
    takes its input as a string, and whatever shells out stays untested by
    design.

    The behavioural checks run the script as a child process with HOME,
    USERPROFILE and TEMP pointed at a scratch directory, as contract.ps1 does.
    The ones that need wsl.exe answer with a shim on PATH, which is only
    possible off Windows: on Windows a shim would have to be a real .exe, and
    the real wsl.exe would be one PATH entry away. They are skipped there and
    say so.

.EXAMPLE
    pwsh -File windows/tests/wsl_contract.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
$wslScript = Join-Path $repoRoot (Join-Path 'windows' (Join-Path 'wsl' 'wsl_manage.ps1'))
$failures = 0

function Test-Ok   { param([string]$Message) Write-Host "[ ok ] $Message" }
function Test-Fail {
    param([string]$Message)
    Write-Host "[fail] $Message" -ForegroundColor Red
    $script:failures++
}
function Test-Skip { param([string]$Message) Write-Host "[skip] $Message" -ForegroundColor DarkGray }
function Write-Section { param([string]$Name) Write-Host ''; Write-Host "--- $Name ---" }

# One assertion, with the output that explains a failure printed under it.
function Test-Case {
    param(
        [string]$Label,
        [bool]$Condition,
        [string]$Detail
    )
    if ($Condition) {
        Test-Ok $Label
        return
    }
    Test-Fail $Label
    if ($Detail) {
        foreach ($line in ($Detail -split "`n" | Select-Object -First 8)) {
            Write-Host "       $line" -ForegroundColor Red
        }
    }
}

if (-not (Test-Path -LiteralPath $wslScript -PathType Leaf)) {
    Write-Host "[fail] wsl_manage.ps1 not found at $wslScript" -ForegroundColor Red
    exit 1
}

$onWindows = $IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop'
$pwshExe = (Get-Process -Id $PID).Path

# Defines the named functions from $Path in this file's scope without running
# anything else in $Path. A name that is not found is a failure rather than a
# skip: a test that quietly stops importing is a test that quietly stops
# testing.
function Import-ScriptFunction {
    param(
        [string]$Path,
        [string[]]$Name
    )
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) {
        Test-Fail "$Path does not parse: $($parseErrors[0].Message)"
        return
    }
    foreach ($n in $Name) {
        $definition = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $n
            }, $true) | Select-Object -First 1
        if (-not $definition) {
            Test-Fail "function $n not found in $(Split-Path -Leaf $Path) - the tests that use it cannot run"
            continue
        }
        # Only the function's own text is evaluated, and that text is a
        # definition, so this runs nothing. The script: qualifier puts it in
        # this file's scope, where the test cases below can call it.
        $text = 'function script:{0} {1}' -f $n, $definition.Body.Extent.Text
        & ([scriptblock]::Create($text))
    }
}

# Name, size and mtime of everything under $Path, as contract.ps1 records it,
# so a rewritten file is caught as well as a new one.
function Get-TreeSnapshot {
    param([string[]]$Path)
    Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue |
        ForEach-Object { '{0}|{1}|{2}' -f $_.FullName, $_.Length, $_.LastWriteTimeUtc.Ticks } |
        Sort-Object
}

function Initialize-ScratchDirectory {
    param([string]$Prefix)
    $dir = Join-Path ([IO.Path]::GetTempPath()) ($Prefix + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

# Runs wsl_manage.ps1 as a child process with HOME, USERPROFILE and TEMP
# pointed at a throwaway directory, optionally with $PathPrefix ahead of PATH
# so a shim stands in for wsl.exe, and from $WorkingDirectory when given so a
# stray relative write would land somewhere this file looks. $Environment adds
# or overrides variables for this one run.
function Invoke-WslManage {
    param(
        [string[]]$Arguments = @(),
        [string]$PathPrefix,
        [string]$WorkingDirectory,
        [hashtable]$Environment = @{}
    )

    $box = Initialize-ScratchDirectory 'wslcontract_'
    $boxHome = Join-Path $box 'home'
    $boxTemp = Join-Path $box 'temp'
    New-Item -ItemType Directory -Path $boxHome, $boxTemp -Force | Out-Null

    $redirect = @{
        TEMP         = $boxTemp
        TMP          = $boxTemp
        TMPDIR       = $boxTemp
        HOME         = $boxHome
        USERPROFILE  = $boxHome
        LOCALAPPDATA = (Join-Path $boxHome 'AppData/Local')
        APPDATA      = (Join-Path $boxHome 'AppData/Roaming')
    }
    foreach ($key in $Environment.Keys) { $redirect[$key] = $Environment[$key] }
    $keep = @{}
    foreach ($key in $redirect.Keys) { $keep[$key] = [Environment]::GetEnvironmentVariable($key) }
    $keepPath = $env:PATH
    $moved = $false
    try {
        foreach ($key in $redirect.Keys) { [Environment]::SetEnvironmentVariable($key, $redirect[$key]) }
        if ($PathPrefix) { $env:PATH = $PathPrefix + [IO.Path]::PathSeparator + $keepPath }
        if ($WorkingDirectory) { Push-Location -LiteralPath $WorkingDirectory; $moved = $true }
        $text = & $pwshExe -NoProfile -File $wslScript @Arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally {
        if ($moved) { Pop-Location }
        foreach ($key in $keep.Keys) { [Environment]::SetEnvironmentVariable($key, $keep[$key]) }
        $env:PATH = $keepPath
    }
    Remove-Item -Path $box -Recurse -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ ExitCode = $code; Output = $text }
}

# A directory holding a wsl.exe that answers 'wsl --status' with $StatusExit
# and records every call in calls.log beside it. Off Windows only; see the
# header.
function Initialize-WslShim {
    param([int]$StatusExit = 0)
    $dir = Initialize-ScratchDirectory 'wslshim_'
    $log = Join-Path $dir 'calls.log'
    $shim = Join-Path $dir 'wsl.exe'
    $body = "#!/bin/sh`necho `"`$*`" >> '$log'`nif [ `"`$1`" = '--status' ]; then exit $StatusExit; fi`nexit 0`n"
    Set-Content -Path $shim -Value $body -NoNewline
    & chmod +x $shim
    return $dir
}

$wslCommand = Get-Command $wslScript
$wslParameters = @($wslCommand.Parameters.Keys)
$wslActions = @($wslCommand.Parameters['Action'].Attributes |
    Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
    ForEach-Object { $_.ValidValues })

# The surface a feature promises: its action is in the validated set and its
# parameters are declared. Same pattern as contract.ps1's 'feature surfaces'.
function Test-Surface {
    param(
        [string[]]$Action = @(),
        [string[]]$Parameter = @()
    )
    foreach ($a in $Action) {
        Test-Case "wsl_manage.ps1 exposes the '$a' action" ($wslActions -contains $a)
    }
    foreach ($p in $Parameter) {
        Test-Case "wsl_manage.ps1 declares -$p" ($wslParameters -contains $p)
    }
}

# --------------------------------------------------------------------------
Write-Section 'wsl_manage wslconfig'
Test-Surface -Action @('wslconfig') -Parameter @('ConfigFile', 'Template', 'Strict')

Import-ScriptFunction -Path $wslScript -Name @('ConvertFrom-WslConfig', 'ConvertTo-WslByteCount', 'Test-WslConfig')

function Get-WslConfigFinding {
    param(
        [string]$Text,
        $Memory = $null,
        $Processors = $null
    )
    $entries = @(ConvertFrom-WslConfig -Text $Text)
    return @(Test-WslConfig -Entries $entries -PhysicalMemoryBytes $Memory -LogicalProcessors $Processors)
}

function Format-Finding {
    param([object[]]$Finding)
    ($Finding | ForEach-Object { '{0} {1} {2}' -f $_.Level, $_.Check, $_.Message }) -join "`n"
}

$cleanConfig = "[wsl2]`nmemory=8GB`nprocessors=4`nswap=2GB`n`n[experimental]`nautoMemoryReclaim=gradual`nsparseVhd=true`n"
$found = Get-WslConfigFinding $cleanConfig -Memory 16GB -Processors 8
Test-Case 'a clean .wslconfig has no WARN' (@($found | Where-Object Level -eq 'warn').Count -eq 0) (Format-Finding $found)

$found = Get-WslConfigFinding "[wsl]`nmemory=8GB"
Test-Case '[wsl] is reported as a section WSL ignores' (
    @($found | Where-Object { $_.Level -eq 'warn' -and $_.Check -eq '[wsl] memory (line 2)' -and $_.Message -match 'ignored by WSL' }).Count -eq 1
) (Format-Finding $found)

$found = Get-WslConfigFinding "memory=8GB`n[wsl2]`nprocessors=2"
Test-Case 'a key before any section is reported' (
    @($found | Where-Object { $_.Level -eq 'warn' -and $_.Check -eq 'memory (line 1)' -and $_.Message -match 'before any' }).Count -eq 1
) (Format-Finding $found)

$found = Get-WslConfigFinding "[wsl2]`nmemry=8GB"
Test-Case 'a misspelt key is unrecognised, with its line number' (
    @($found | Where-Object { $_.Level -eq 'warn' -and $_.Check -eq '[wsl2] memry (line 2)' -and $_.Message -match 'unrecognised key' }).Count -eq 1
) (Format-Finding $found)
Test-Case 'and the cap it meant to set is reported missing' (
    @($found | Where-Object { $_.Level -eq 'warn' -and $_.Message -match 'no memory cap' }).Count -eq 1
) (Format-Finding $found)

$found = Get-WslConfigFinding "[wsl2]`nmemory=4GB`nautoMemoryReclaim=gradual"
Test-Case 'an [experimental] key under [wsl2] is reported as misplaced' (
    @($found | Where-Object { $_.Level -eq 'warn' -and $_.Check -like '*autoMemoryReclaim (line 3)' -and $_.Message -match 'belongs in \[experimental\]' }).Count -eq 1
) (Format-Finding $found)

$found = Get-WslConfigFinding "[wsl2]`nmemory=4GB`n[experimental]`nnetworkingMode=mirrored"
Test-Case 'a [wsl2] key under [experimental] is reported as misplaced' (
    @($found | Where-Object { $_.Level -eq 'warn' -and $_.Message -match 'belongs in \[wsl2\]' }).Count -eq 1
) (Format-Finding $found)

$found = Get-WslConfigFinding "[general]`ninstanceIdleTimeout=60000`ndistributionInstallPath=D:/WSL`n[wsl2]`nmemory=8GB"
Test-Case '[general] and its documented keys are read, not reported as ignored' (
    @($found | Where-Object { $_.Level -eq 'warn' }).Count -eq 0
) (Format-Finding $found)
$found = Get-WslConfigFinding "[general]`ninstanceIdleTimout=60000`n[wsl2]`nmemory=8GB"
Test-Case 'an unknown key under [general] is unrecognised' (
    @($found | Where-Object { $_.Level -eq 'warn' -and $_.Check -eq '[general] instanceIdleTimout (line 2)' -and $_.Message -match 'unrecognised key' }).Count -eq 1
) (Format-Finding $found)
$found = Get-WslConfigFinding "[wsl2]`nmemory=8GB`ninstanceIdleTimeout=60000"
Test-Case 'a [general] key under [wsl2] is reported as misplaced' (
    @($found | Where-Object { $_.Level -eq 'warn' -and $_.Message -match 'belongs in \[general\]' }).Count -eq 1
) (Format-Finding $found)
$found = Get-WslConfigFinding "[bogus]`nmemory=8GB"
Test-Case 'the ignored-section message names all three sections WSL reads' (
    @($found | Where-Object { $_.Message -match '\[general\], \[wsl2\] and \[experimental\]' }).Count -eq 1
) (Format-Finding $found)

foreach ($mode in 'disabled', 'gradual', 'dropCache', 'DropCache') {
    $found = Get-WslConfigFinding "[wsl2]`nmemory=8GB`n[experimental]`nautoMemoryReclaim=$mode"
    Test-Case "autoMemoryReclaim=$mode is accepted" (
        @($found | Where-Object { $_.Level -eq 'warn' }).Count -eq 0 -and
        @($found | Where-Object { $_.Level -eq 'ok' -and $_.Check -like '*autoMemoryReclaim*' }).Count -eq 1
    ) (Format-Finding $found)
}
$found = Get-WslConfigFinding "[wsl2]`nmemory=8GB`n[experimental]`nautoMemoryReclaim=aggressive"
Test-Case 'an autoMemoryReclaim value WSL does not define is reported' (
    @($found | Where-Object { $_.Level -eq 'warn' -and $_.Check -eq '[experimental] autoMemoryReclaim (line 4)' -and $_.Message -match 'not disabled, gradual or dropCache' }).Count -eq 1 -and
    @($found | Where-Object { $_.Level -eq 'ok' -and $_.Check -like '*autoMemoryReclaim*' }).Count -eq 0
) (Format-Finding $found)

$found = Get-WslConfigFinding "[boot]`nsystemd=true"
Test-Case 'a /etc/wsl.conf section is pointed at /etc/wsl.conf' (
    @($found | Where-Object { $_.Level -eq 'warn' -and $_.Message -match '/etc/wsl.conf' }).Count -eq 1
) (Format-Finding $found)

$found = Get-WslConfigFinding "[wsl2]`nmemory=4GB`nkernel=C:\Users\x\k"
Test-Case 'single backslashes in kernel= are reported' (
    @($found | Where-Object { $_.Level -eq 'warn' -and $_.Message -match 'doubled' }).Count -eq 1
) (Format-Finding $found)
$found = Get-WslConfigFinding "[wsl2]`nmemory=4GB`nkernel=C:\\Users\\x\\k"
Test-Case 'doubled backslashes in kernel= are not' (
    @($found | Where-Object { $_.Message -match 'doubled' }).Count -eq 0
) (Format-Finding $found)

$found = Get-WslConfigFinding "[wsl2]`nmemory=64GB" -Memory 16GB -Processors 8
Test-Case 'memory above the installed RAM is reported' (
    @($found | Where-Object { $_.Level -eq 'warn' -and $_.Message -match 'more than this machine' }).Count -eq 1
) (Format-Finding $found)
$found = Get-WslConfigFinding "[wsl2]`nmemory=64GB"
Test-Case 'and is not compared when the machine size is unknown' (
    @($found | Where-Object { $_.Message -match 'more than this machine' }).Count -eq 0 -and
    @($found | Where-Object { $_.Level -eq 'info' -and $_.Check -eq 'machine size' }).Count -eq 1
) (Format-Finding $found)

$found = Get-WslConfigFinding "[wsl2]`nmemory=8 gigs`nprocessors=0"
Test-Case 'a memory value that is not a size, and processors=0, are reported' (
    @($found | Where-Object { $_.Level -eq 'warn' -and $_.Message -match 'is not a size' }).Count -eq 1 -and
    @($found | Where-Object { $_.Level -eq 'warn' -and $_.Message -match 'positive whole number' }).Count -eq 1
) (Format-Finding $found)

$found = Get-WslConfigFinding "[wsl2]`nmemory=8GB`nprocessors=32" -Memory 16GB -Processors 8
Test-Case 'processors above the logical processors are reported' (
    @($found | Where-Object { $_.Level -eq 'warn' -and $_.Message -match 'logical processors' }).Count -eq 1
) (Format-Finding $found)

$found = Get-WslConfigFinding "[wsl2]`nmemory=8GB`nfirewall=yes`n[experimental]`nsparseVhd=1"
Test-Case 'a boolean key that is not true or false is reported, sparseVhd included' (
    @($found | Where-Object { $_.Level -eq 'warn' -and $_.Check -eq '[experimental] sparseVhd (line 5)' -and $_.Message -match 'not true or false' }).Count -eq 1 -and
    @($found | Where-Object { $_.Level -eq 'warn' -and $_.Check -eq '[wsl2] firewall (line 3)' -and $_.Message -match 'not true or false' }).Count -eq 1 -and
    @($found | Where-Object { $_.Level -eq 'ok' -and $_.Check -like '*sparseVhd*' }).Count -eq 0
) (Format-Finding $found)
$found = Get-WslConfigFinding "[wsl2]`nmemory=8GB`nfirewall=FALSE`n[experimental]`nsparseVhd=True"
Test-Case 'true and false are accepted in any case' (
    @($found | Where-Object { $_.Message -match 'not true or false' }).Count -eq 0 -and
    @($found | Where-Object { $_.Level -eq 'ok' -and $_.Check -like '*sparseVhd*' }).Count -eq 1
) (Format-Finding $found)

$lfText = "[wsl2]`nmemory=8GB`n# a comment`n; another`nswap=0`n"
$crlfText = [string][char]0xFEFF + ($lfText -replace "`n", "`r`n")
$lfEntries = @(ConvertFrom-WslConfig -Text $lfText) | ConvertTo-Json -Compress
$crlfEntries = @(ConvertFrom-WslConfig -Text $crlfText) | ConvertTo-Json -Compress
Test-Case 'CRLF text with a UTF-8 BOM parses to the same entries as LF text' ($lfEntries -eq $crlfEntries) "LF:   $lfEntries`nCRLF: $crlfEntries"

Test-Case "ConvertTo-WslByteCount reads '1.5GB'" ((ConvertTo-WslByteCount '1.5GB') -eq [long](1.5 * 1GB))
Test-Case "ConvertTo-WslByteCount refuses '8 GB'" ($null -eq (ConvertTo-WslByteCount '8 GB'))
Test-Case "ConvertTo-WslByteCount reads a bare number as bytes ('0', '1024')" (
    (ConvertTo-WslByteCount '0') -eq 0 -and (ConvertTo-WslByteCount '1024') -eq 1024
)
$found = Get-WslConfigFinding "[wsl2]`nmemory=8GB`nswap=0`n"
Test-Case 'swap=0 (no unit, swap off) is a valid size, not a warning' (
    @($found | Where-Object { $_.Message -match 'is not a size' }).Count -eq 0 -and
    @($found | Where-Object { $_.Level -eq 'ok' -and $_.Check -eq '[wsl2] swap (line 3)' }).Count -eq 1
) (Format-Finding $found)

# Behavioural: the action needs no WSL, so these run on every runner.
$fixtures = Initialize-ScratchDirectory 'wslconfig_'
try {
    $badFile = Join-Path $fixtures 'bad.wslconfig'
    $cleanFile = Join-Path $fixtures 'clean.wslconfig'
    [IO.File]::WriteAllText($badFile, "[wsl2]`nmemry=8GB`n")
    [IO.File]::WriteAllText($cleanFile, $cleanConfig)
    $before = @(Get-TreeSnapshot $fixtures)

    $run = Invoke-WslManage -Arguments @('wslconfig', '-ConfigFile', $badFile)
    Test-Case 'wslconfig reports warnings and exits 0' ($run.ExitCode -eq 0 -and $run.Output -match 'WARN') "exit $($run.ExitCode)`n$($run.Output)"
    Test-Case 'wslconfig names the file it read' ($run.Output -match [regex]::Escape($badFile)) $run.Output

    $run = Invoke-WslManage -Arguments @('wslconfig', '-ConfigFile', $badFile, '-Strict')
    Test-Case 'wslconfig -Strict exits 1 on a warning' ($run.ExitCode -eq 1) "exit $($run.ExitCode)`n$($run.Output)"

    $run = Invoke-WslManage -Arguments @('wslconfig', '-ConfigFile', $cleanFile, '-Strict')
    Test-Case 'wslconfig -Strict exits 0 on a clean file' ($run.ExitCode -eq 0) "exit $($run.ExitCode)`n$($run.Output)"

    $run = Invoke-WslManage -Arguments @('wslconfig', '-ConfigFile', (Join-Path $fixtures 'missing.wslconfig'))
    Test-Case 'wslconfig -ConfigFile <missing> exits 3' ($run.ExitCode -eq 3) "exit $($run.ExitCode)`n$($run.Output)"

    $run = Invoke-WslManage -Arguments @('wslconfig', '-Strict')
    Test-Case 'wslconfig with no file at the default path is a finding, not an error' (
        $run.ExitCode -eq 0 -and $run.Output -match 'no \.wslconfig'
    ) "exit $($run.ExitCode)`n$($run.Output)"

    $run = Invoke-WslManage -Arguments @('wslconfig', '-Template') -WorkingDirectory $fixtures
    Test-Case 'wslconfig -Template prints a starter and exits 0' (
        $run.ExitCode -eq 0 -and $run.Output -match '\[wsl2\]' -and $run.Output -match 'memory='
    ) "exit $($run.ExitCode)`n$($run.Output)"

    $after = @(Get-TreeSnapshot $fixtures)
    $written = @(Compare-Object -ReferenceObject $before -DifferenceObject $after)
    Test-Case 'wslconfig wrote nothing, -Template included' ($written.Count -eq 0) (($written | ForEach-Object { '{0} {1}' -f $_.SideIndicator, $_.InputObject }) -join "`n")
} finally {
    Remove-Item -Path $fixtures -Recurse -Force -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------------------
Write-Section 'wsl_manage backup -All and previews'
Test-Surface -Action @('backup', 'compact', 'sparse', 'shutdown') -Parameter @('All', 'DryRun')

Import-ScriptFunction -Path $wslScript -Name @('Format-Size', 'Get-BackupPlan')

function Get-TestDistro {
    param([string]$Name, [long]$VhdxSize)
    [pscustomobject]@{ Name = $Name; VhdxSize = $VhdxSize }
}
# A scratch path under the temp root, which exists on any host (the path
# itself does not): a literal D:\ fails on a machine without that drive,
# and the plan only joins paths, it never writes them.
$dest = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
function Format-Plan {
    param([object[]]$Plan)
    ($Plan | ForEach-Object { '{0} {1} {2} {3}' -f $_.Verb, $_.Name, $_.Out, $_.Reason }) -join "`n"
}

$plan = @(Get-BackupPlan -Distros @((Get-TestDistro 'docker-desktop' 2GB), (Get-TestDistro 'docker-desktop-data' 20GB)) `
    -DestDir $dest -Stamp '2026-10-21_1830' -FreeBytes 100GB)
Test-Case "Docker Desktop's distros are skipped" (
    $plan.Count -eq 2 -and @($plan | Where-Object { $_.Verb -ne 'SKIP' }).Count -eq 0 -and
    @($plan | Where-Object { $_.Reason -match 'Docker Desktop' }).Count -eq 2
) (Format-Plan $plan)

$stamp = '2026-10-21_1830'
$plan = @(Get-BackupPlan -Distros @((Get-TestDistro 'Ubuntu' 10GB), (Get-TestDistro 'Debian' 5GB)) `
    -DestDir $dest -Stamp $stamp -FreeBytes 100GB)
Test-Case 'two distros plan two exports under one stamp, to two paths' (
    $plan.Count -eq 2 -and @($plan | Where-Object { $_.Verb -eq 'EXPORT' }).Count -eq 2 -and
    @($plan | Where-Object { $_.Out -like "*_$stamp.tar" }).Count -eq 2 -and
    $plan[0].Out -ne $plan[1].Out
) (Format-Plan $plan)

$plan = @(Get-BackupPlan -Distros @((Get-TestDistro 'Ubuntu' 60GB), (Get-TestDistro 'Debian' 5GB)) `
    -DestDir $dest -Stamp $stamp -FreeBytes 10GB -UsedByName @{ Ubuntu = 50GB })
Test-Case 'a measured distro bigger than the free space fails, and only that one' (
    @($plan | Where-Object { $_.Name -eq 'Ubuntu' -and $_.Verb -eq 'FAIL' -and $_.Reason -match 'needs' }).Count -eq 1 -and
    @($plan | Where-Object { $_.Name -eq 'Debian' -and $_.Verb -eq 'EXPORT' }).Count -eq 1
) (Format-Plan $plan)

$plan = @(Get-BackupPlan -Distros @((Get-TestDistro 'Ubuntu' 100GB)) -DestDir $dest -Stamp $stamp -FreeBytes 10GB)
Test-Case 'an unmeasured VHDX bigger than the free space is a warning, not a refusal' (
    $plan.Count -eq 1 -and $plan[0].Verb -eq 'WARN'
) (Format-Plan $plan)

$plan = @(Get-BackupPlan -Distros @((Get-TestDistro 'Ubuntu' 100GB)) -DestDir '\\server\share' -Stamp $stamp -FreeBytes $null -UsedByName @{ Ubuntu = 90GB })
Test-Case 'unknown free space (a UNC path) raises no space finding' (
    $plan.Count -eq 1 -and $plan[0].Verb -eq 'EXPORT'
) (Format-Plan $plan)

# Free space is shared by the whole set: each measured export that is let
# through takes its size off what the next distro can use.
$plan = @(Get-BackupPlan -Distros @((Get-TestDistro 'Ubuntu' 80GB), (Get-TestDistro 'Debian' 80GB), (Get-TestDistro 'Alpine' 5GB)) `
    -DestDir $dest -Stamp $stamp -FreeBytes 100GB -UsedByName @{ Ubuntu = 60GB; Debian = 60GB; Alpine = 30GB })
Test-Case 'a set that cannot fit together is refused up front, not distro by distro' (
    @($plan | Where-Object { $_.Name -eq 'Ubuntu' -and $_.Verb -eq 'EXPORT' }).Count -eq 1 -and
    @($plan | Where-Object { $_.Name -eq 'Debian' -and $_.Verb -eq 'FAIL' -and $_.Reason -match 'needs' }).Count -eq 1 -and
    @($plan | Where-Object { $_.Name -eq 'Alpine' -and $_.Verb -eq 'EXPORT' }).Count -eq 1
) (Format-Plan $plan)
$plan = @(Get-BackupPlan -Distros @((Get-TestDistro 'Ubuntu' 80GB), (Get-TestDistro 'Debian' 80GB)) `
    -DestDir $dest -Stamp $stamp -FreeBytes 100GB -UsedByName @{ Ubuntu = 40GB; Debian = 40GB })
Test-Case 'and a set that fits together is not refused' (
    @($plan | Where-Object { $_.Verb -eq 'EXPORT' }).Count -eq 2
) (Format-Plan $plan)

# A failed export must never delete a backup that was already there. Two
# runs in the same minute share one output path, so the second run's cleanup
# used to remove the first run's valid tar and leave its sidecar behind. A
# function named wsl.exe takes precedence over the program of that name, on
# Windows too, so no real export happens.
Import-ScriptFunction -Path $wslScript -Name @('Format-WslOutput', 'Invoke-DistroBackup')
$backupDir = Initialize-ScratchDirectory 'wslbackup-'
try {
    $backupOut = Join-Path $backupDir 'Ubuntu_2026-10-21_1830.tar'
    $earlierSide = 'earlier-hash  Ubuntu_2026-10-21_1830.tar'
    [IO.File]::WriteAllText($backupOut, 'earlier good export')
    [IO.File]::WriteAllText("$backupOut.sha256", $earlierSide)

    function wsl.exe {
        [IO.File]::WriteAllText([string]$args[2], 'half written')
        $global:LASTEXITCODE = 1
    }
    $backedUp = Invoke-DistroBackup -Name 'Ubuntu' -Out $backupOut 2>$null 6>$null
    $left = @(Get-ChildItem -LiteralPath $backupDir -Force | ForEach-Object { $_.Name } | Sort-Object)
    Test-Case 'a failed export reports failure' ($backedUp -eq $false)
    Test-Case 'and leaves the earlier tar and its sidecar of the same name as they were' (
        [IO.File]::ReadAllText($backupOut) -eq 'earlier good export' -and
        [IO.File]::ReadAllText("$backupOut.sha256") -eq $earlierSide
    ) ($left -join "`n")
    Test-Case 'and leaves no partial file behind' ($left.Count -eq 2) ($left -join "`n")

    function wsl.exe {
        [IO.File]::WriteAllText([string]$args[2], 'new export')
        $global:LASTEXITCODE = 0
    }
    $backedUp = Invoke-DistroBackup -Name 'Ubuntu' -Out $backupOut 6>$null
    $left = @(Get-ChildItem -LiteralPath $backupDir -Force | ForEach-Object { $_.Name } | Sort-Object)
    $newHash = (Get-FileHash -LiteralPath $backupOut -Algorithm SHA256).Hash.ToLowerInvariant()
    Test-Case 'a successful export replaces the tar and writes a sidecar that matches it' (
        $backedUp -eq $true -and [IO.File]::ReadAllText($backupOut) -eq 'new export' -and
        [IO.File]::ReadAllText("$backupOut.sha256") -eq "$newHash  Ubuntu_2026-10-21_1830.tar" -and
        $left.Count -eq 2
    ) ($left -join "`n")
} finally {
    Remove-Item -LiteralPath Function:\wsl.exe -ErrorAction SilentlyContinue
    Remove-Item -Path $backupDir -Recurse -Force -ErrorAction SilentlyContinue
}

# Each preview must be decided before the branch reaches anything that
# changes the machine. Read from the syntax tree of the switch, so moving a
# call above the -DryRun check fails here even though nothing runs it.
$parsed = [System.Management.Automation.Language.Parser]::ParseFile($wslScript, [ref]$null, [ref]$null)
$actionSwitch = $parsed.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.SwitchStatementAst] -and $node.Condition.Extent.Text -eq '$Action'
    }, $true) | Select-Object -First 1
$clauseText = @{}
if ($actionSwitch) {
    foreach ($clause in $actionSwitch.Clauses) {
        $clauseText[[string]$clause.Item1.Value] = $clause.Item2.Extent.Text
    }
}
Test-Case 'the switch over $Action was found' ($clauseText.Count -gt 0)
$changing = 'wsl\.exe\s+--(export|shutdown|manage|terminate|import)|diskpart|Invoke-DistroBackup'
foreach ($a in @('backup', 'compact', 'sparse', 'shutdown')) {
    $text = [string]$clauseText[$a]
    $dry = $text.IndexOf('$DryRun')
    $call = [regex]::Match($text, $changing)
    Test-Case "the $a branch checks -DryRun before its first call that changes anything" (
        $dry -ge 0 -and $call.Success -and $dry -lt $call.Index
    ) "first -DryRun at $dry, first call '$($call.Value)' at $($call.Index)"
}

if ($onWindows) {
    Test-Skip 'the wsl.exe shim checks run only off Windows (see the header)'
} else {
    $shimDir = Initialize-WslShim -StatusExit 0
    try {
        $run = Invoke-WslManage -Arguments @('backup', '-All', '-Distro', 'Ubuntu') -PathPrefix $shimDir
        Test-Case 'backup -All -Distro exits 3 and names both flags' (
            $run.ExitCode -eq 3 -and $run.Output -match '-All' -and $run.Output -match '-Distro'
        ) "exit $($run.ExitCode)`n$($run.Output)"

        $run = Invoke-WslManage -Arguments @('shutdown', '-DryRun') -PathPrefix $shimDir
        $calls = @(Get-Content -Path (Join-Path $shimDir 'calls.log') -ErrorAction SilentlyContinue)
        Test-Case 'shutdown -DryRun previews and exits 0' (
            $run.ExitCode -eq 0 -and $run.Output -match 'WOULD stop WSL'
        ) "exit $($run.ExitCode)`n$($run.Output)"
        Test-Case 'and never calls wsl --shutdown' (
            @($calls | Where-Object { $_ -match '--shutdown' }).Count -eq 0
        ) ($calls -join "`n")
    } finally {
        Remove-Item -Path $shimDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --------------------------------------------------------------------------
Write-Section 'wsl_manage backups'
Test-Surface -Action @('backups', 'verify-backup') -Parameter @('Verify', 'MaxAgeDays')

# Writes $Name with $Content into $Directory and, unless -NoSidecar, the
# sidecar exactly as the backup action writes it: lowercase hash, two spaces,
# the file name.
function Write-BackupFixture {
    param(
        [string]$Directory,
        [string]$Name,
        [string]$Content,
        [switch]$NoSidecar
    )
    $path = Join-Path $Directory $Name
    [IO.File]::WriteAllText($path, $Content)
    if (-not $NoSidecar) {
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        Set-Content -LiteralPath "$path.sha256" -Encoding ascii -Value "$hash  $Name"
    }
    return $path
}

$backupDir = Initialize-ScratchDirectory 'wslbackups_'
try {
    $newest = Write-BackupFixture $backupDir 'Ubuntu_2026-10-20_0900.tar' 'newest ubuntu export'
    $older = Write-BackupFixture $backupDir 'Ubuntu_2026-08-01_0900.tar' 'older ubuntu export'
    $debian = Write-BackupFixture $backupDir 'Debian_2026-10-19_0800.tar' 'debian export' -NoSidecar
    [IO.File]::WriteAllText((Join-Path $backupDir 'notes.tar'), 'not a backup')
    (Get-Item -LiteralPath $older).LastWriteTime = (Get-Date).AddDays(-80)

    $before = @(Get-TreeSnapshot $backupDir)
    $run = Invoke-WslManage -Arguments @('backups', '-DestDir', $backupDir)
    Test-Case 'backups lists the dated exports and exits 0' (
        $run.ExitCode -eq 0 -and $run.Output -match 'Ubuntu_2026-10-20_0900\.tar' -and $run.Output -match 'Ubuntu_2026-08-01_0900\.tar'
    ) "exit $($run.ExitCode)`n$($run.Output)"
    Test-Case 'and ignores a tar that backup did not name' ($run.Output -notmatch 'notes\.tar') $run.Output
    Test-Case 'and says which sidecars are missing without hashing' (
        $run.Output -match 'sha256:missing' -and $run.Output -notmatch 'Hashing'
    ) $run.Output
    $newestAt = $run.Output.IndexOf('Ubuntu_2026-10-20_0900.tar')
    $olderAt = $run.Output.IndexOf('Ubuntu_2026-08-01_0900.tar')
    Test-Case 'newest first within a distro' ($newestAt -ge 0 -and $newestAt -lt $olderAt) $run.Output

    $run = Invoke-WslManage -Arguments @('backups', '-DestDir', $backupDir, '-Verify')
    Test-Case 'backups -Verify exits 1 when a tar has no sidecar' (
        $run.ExitCode -eq 1 -and $run.Output -match 'MISS\s+Debian_2026-10-19_0800\.tar' -and $run.Output -match 'Hashing 3 file'
    ) "exit $($run.ExitCode)`n$($run.Output)"
    Test-Case 'and the Ubuntu exports verify' (
        @([regex]::Matches($run.Output, 'OK\s+Ubuntu_\S+\.tar.*verified')).Count -eq 2
    ) $run.Output

    $run = Invoke-WslManage -Arguments @('backups', '-DestDir', $backupDir, '-Verify', '-Distro', 'Ubuntu')
    Test-Case 'backups -Distro Ubuntu leaves Debian out, and verifies clean -> 0' (
        $run.ExitCode -eq 0 -and $run.Output -notmatch 'Debian'
    ) "exit $($run.ExitCode)`n$($run.Output)"
    $after = @(Get-TreeSnapshot $backupDir)
    $written = @(Compare-Object -ReferenceObject $before -DifferenceObject $after)
    Test-Case 'backups wrote, renamed and deleted nothing' ($written.Count -eq 0) (($written | ForEach-Object { '{0} {1}' -f $_.SideIndicator, $_.InputObject }) -join "`n")

    Remove-Item -LiteralPath $debian -Force
    $run = Invoke-WslManage -Arguments @('backups', '-DestDir', $backupDir, '-Verify')
    Test-Case 'with every sidecar present and matching, -Verify exits 0' ($run.ExitCode -eq 0) "exit $($run.ExitCode)`n$($run.Output)"

    $savedTime = (Get-Item -LiteralPath $newest).LastWriteTime
    (Get-Item -LiteralPath $newest).LastWriteTime = (Get-Date).AddDays(-10)
    $run = Invoke-WslManage -Arguments @('backups', '-DestDir', $backupDir, '-MaxAgeDays', '1')
    Test-Case 'a newest backup older than -MaxAgeDays is STALE -> 1' (
        $run.ExitCode -eq 1 -and $run.Output -match 'STALE Ubuntu newest backup is 10 day'
    ) "exit $($run.ExitCode)`n$($run.Output)"
    (Get-Item -LiteralPath $newest).LastWriteTime = $savedTime
    $run = Invoke-WslManage -Arguments @('backups', '-DestDir', $backupDir, '-MaxAgeDays', '1')
    Test-Case 'a recent newest backup is not stale -> 0' ($run.ExitCode -eq 0 -and $run.Output -notmatch 'STALE') "exit $($run.ExitCode)`n$($run.Output)"

    $run = Invoke-WslManage -Arguments @('verify-backup', '-Tar', $newest)
    Test-Case 'verify-backup still verifies a good tar -> 0' ($run.ExitCode -eq 0 -and $run.Output -match 'SHA-256 verified') "exit $($run.ExitCode)`n$($run.Output)"
    $run = Invoke-WslManage -Arguments @('verify-backup')
    Test-Case 'verify-backup with no -Tar still exits 3' ($run.ExitCode -eq 3) "exit $($run.ExitCode)`n$($run.Output)"
    $bare = Write-BackupFixture $backupDir 'Arch_2026-10-01_0700.tar' 'no sidecar here' -NoSidecar
    $run = Invoke-WslManage -Arguments @('verify-backup', '-Tar', $bare)
    Test-Case 'verify-backup with no sidecar still exits 1 and says so' ($run.ExitCode -eq 1 -and $run.Output -match 'No checksum sidecar') "exit $($run.ExitCode)`n$($run.Output)"
    Remove-Item -LiteralPath $bare -Force

    [IO.File]::WriteAllText($newest, 'truncated')
    $run = Invoke-WslManage -Arguments @('backups', '-DestDir', $backupDir, '-Verify')
    Test-Case 'a tar changed after hashing is BAD -> 1' (
        $run.ExitCode -eq 1 -and $run.Output -match 'BAD\s+Ubuntu_2026-10-20_0900\.tar' -and $run.Output -match 'expected'
    ) "exit $($run.ExitCode)`n$($run.Output)"
    $run = Invoke-WslManage -Arguments @('verify-backup', '-Tar', $newest)
    Test-Case 'verify-backup still exits 1 on a mismatch' ($run.ExitCode -eq 1 -and $run.Output -match 'mismatch') "exit $($run.ExitCode)`n$($run.Output)"

    Set-Content -LiteralPath "$older.sha256" -Value 'not a hash'
    $run = Invoke-WslManage -Arguments @('backups', '-DestDir', $backupDir, '-Verify', '-Distro', 'Ubuntu')
    Test-Case 'a malformed sidecar is BAD' ($run.Output -match 'BAD\s+Ubuntu_2026-08-01_0900\.tar.*malformed') $run.Output
} finally {
    Remove-Item -Path $backupDir -Recurse -Force -ErrorAction SilentlyContinue
}

$emptyDir = Initialize-ScratchDirectory 'wslbackups_empty_'
try {
    $run = Invoke-WslManage -Arguments @('backups', '-DestDir', $emptyDir)
    Test-Case 'an empty backup folder is not an error -> 0' (
        $run.ExitCode -eq 0 -and $run.Output -match 'No dated \.tar exports'
    ) "exit $($run.ExitCode)`n$($run.Output)"
    $run = Invoke-WslManage -Arguments @('backups', '-DestDir', $emptyDir, '-MaxAgeDays', '3')
    Test-Case 'but with -MaxAgeDays there is no recent backup -> 1' ($run.ExitCode -eq 1) "exit $($run.ExitCode)`n$($run.Output)"
} finally {
    Remove-Item -Path $emptyDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------------------
Write-Section 'wsl_manage doctor'
Test-Surface -Action @('doctor') -Parameter @('ProbeHost')
# $Host is PowerShell's own automatic variable; a parameter of that name
# would shadow it inside the script.
Test-Case 'wsl_manage.ps1 does not declare -Host' ($wslParameters -notcontains 'Host')

Import-ScriptFunction -Path $wslScript -Name @('ConvertFrom-DistroList', 'Test-DistroFact')

function Get-HealthyFact {
    $windowsPath = (1..3 | ForEach-Object { "/mnt/c/dir$_" }) -join ':'
    @{
        Name              = 'Ubuntu'
        Version           = 2
        User              = 'alice'
        Pid1              = 'systemd'
        DiskPercent       = 40
        ClockDeltaSeconds = 1
        DnsOk             = $true
        ProbeHost         = 'github.com'
        Path              = "/usr/local/bin:/usr/bin:/bin:$windowsPath"
    }
}
function Get-DoctorFinding {
    param([hashtable]$Change = @{})
    $facts = Get-HealthyFact
    foreach ($key in $Change.Keys) { $facts[$key] = $Change[$key] }
    return @(Test-DistroFact -Facts $facts)
}
function Get-LevelCount {
    param([object[]]$Finding, [string]$Level, [string]$Check)
    @($Finding | Where-Object { $_.Level -eq $Level -and (-not $Check -or $_.Check -eq $Check) }).Count
}

$found = Get-DoctorFinding
Test-Case 'a healthy distro has only OK findings' (
    $found.Count -gt 0 -and @($found | Where-Object { $_.Level -ne 'ok' }).Count -eq 0
) (Format-Finding $found)

$found = Get-DoctorFinding @{ User = 'root' }
Test-Case 'a root default user is exactly one warning, pointing at restore' (
    (Get-LevelCount $found 'warn') -eq 1 -and @($found | Where-Object { $_.Level -eq 'warn' -and $_.Message -match 'restore' }).Count -eq 1
) (Format-Finding $found)

$found = Get-DoctorFinding @{ Version = 1 }
Test-Case 'WSL1 is a failure' ((Get-LevelCount $found 'fail' 'version') -eq 1) (Format-Finding $found)

$found = Get-DoctorFinding @{ DiskPercent = 90 }
Test-Case 'a root filesystem at 90% is a warning' ((Get-LevelCount $found 'warn' 'root filesystem') -eq 1) (Format-Finding $found)
$found = Get-DoctorFinding @{ DiskPercent = 96 }
Test-Case 'a root filesystem at 96% is a failure' ((Get-LevelCount $found 'fail' 'root filesystem') -eq 1) (Format-Finding $found)

$found = Get-DoctorFinding @{ ClockDeltaSeconds = 7 }
Test-Case 'a clock 7 s off is a warning' ((Get-LevelCount $found 'warn' 'clock') -eq 1) (Format-Finding $found)
$found = Get-DoctorFinding @{ ClockDeltaSeconds = 400 }
Test-Case 'a clock 400 s ahead is a failure' ((Get-LevelCount $found 'fail' 'clock') -eq 1) (Format-Finding $found)
$found = Get-DoctorFinding @{ ClockDeltaSeconds = -400 }
Test-Case 'a clock 400 s behind is a failure too' ((Get-LevelCount $found 'fail' 'clock') -eq 1) (Format-Finding $found)

$found = Get-DoctorFinding @{ DnsOk = $false }
Test-Case 'a probe host that does not resolve is a warning' ((Get-LevelCount $found 'warn' 'dns') -eq 1) (Format-Finding $found)

$found = Get-DoctorFinding @{ Pid1 = 'init' }
Test-Case 'no systemd is information, not a warning' (
    (Get-LevelCount $found 'info' 'init') -eq 1 -and (Get-LevelCount $found 'warn') -eq 0
) (Format-Finding $found)

$found = Get-DoctorFinding @{ Path = ((1..12 | ForEach-Object { "/mnt/c/dir$_" }) -join ':') }
Test-Case 'twelve /mnt/c PATH entries are information' ((Get-LevelCount $found 'info' 'PATH') -eq 1) (Format-Finding $found)

$found = Get-DoctorFinding @{ DiskPercent = $null }
Test-Case 'an unmeasured disk is reported as not measured, not as a pass' ((Get-LevelCount $found 'info' 'root filesystem') -eq 1) (Format-Finding $found)

$transcript = "  NAME                   STATE           VERSION`r`n" +
    "* Ubuntu-22.04           Running         2`r`n" +
    "  docker-desktop         Stopped         2`r`n" +
    "  Legacy                 Stopped         1`r`n"
$rows = @(ConvertFrom-DistroList -Text $transcript)
$shape = ($rows | ForEach-Object { '{0}/{1}/{2}/{3}' -f $_.Name, $_.State, $_.Version, $_.Default }) -join ' '
Test-Case "ConvertFrom-DistroList reads names, states, versions and the default marker" (
    $shape -eq 'Ubuntu-22.04/Running/2/True docker-desktop/Stopped/2/False Legacy/Stopped/1/False'
) $shape
Test-Case 'ConvertFrom-DistroList of nothing is nothing' (@(ConvertFrom-DistroList -Text '').Count -eq 0)

if ($onWindows) {
    Test-Skip 'the wsl.exe shim checks run only off Windows (see the header)'
} else {
    $shimDir = Initialize-WslShim -StatusExit 1
    try {
        $run = Invoke-WslManage -Arguments @('doctor') -PathPrefix $shimDir
        Test-Case 'doctor exits 2 where wsl --status fails, like every other action' ($run.ExitCode -eq 2) "exit $($run.ExitCode)`n$($run.Output)"
    } finally {
        Remove-Item -Path $shimDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --------------------------------------------------------------------------
Write-Section 'wsl_manage clone and restore -DefaultUser'
Test-Surface -Action @('clone', 'restore') -Parameter @('NewName', 'DefaultUser', 'KeepTar')

Import-ScriptFunction -Path $wslScript -Name @('Test-WslUserName', 'Get-WslConfUserPlan', 'ConvertFrom-PasswdLine',
    'Get-CloneStagingName', 'Get-BackupFile')

foreach ($name in @('alice', 'dev_01', 'a-b', '_svc')) {
    Test-Case "Test-WslUserName accepts '$name'" (Test-WslUserName $name)
}
foreach ($name in @('', 'Root;rm', 'a b', "o'brien", 'a$(x)', 'Alice', '1abc', ('a' * 33))) {
    Test-Case "Test-WslUserName refuses '$name'" (-not (Test-WslUserName $name))
}

$planCases = @(
    @{ Text = '';                                      Expect = 'append';  Label = 'no /etc/wsl.conf' }
    @{ Text = "[boot]`nsystemd=true`n";                Expect = 'append';  Label = 'a [boot] section only' }
    @{ Text = "[user]`ndefault=bob`n";                 Expect = 'present'; Label = 'a default user already set' }
    @{ Text = "[user]`n# nothing`n";                   Expect = 'manual';  Label = 'a [user] section with no default=' }
    @{ Text = "[boot]`r`nsystemd=true`r`n[user]`r`ndefault=bob`r`n"; Expect = 'present'; Label = 'CRLF text with a default user' }
    @{ Text = "[user]`ndefault=bob`n[boot]`n";         Expect = 'present'; Label = '[user] before another section' }
    @{ Text = "[boot]`ndefault=bob`n";                 Expect = 'append';  Label = 'default= under the wrong section' }
)
foreach ($case in $planCases) {
    $got = Get-WslConfUserPlan -Existing $case.Text
    Test-Case "Get-WslConfUserPlan: $($case.Label) -> $($case.Expect)" ($got -eq $case.Expect) "got '$got'"
}

Test-Case 'ConvertFrom-PasswdLine reads the user name' (
    (ConvertFrom-PasswdLine 'alice:x:1000:1000:Alice,,,:/home/alice:/bin/bash') -eq 'alice'
)
Test-Case 'ConvertFrom-PasswdLine of an empty line is $null' ($null -eq (ConvertFrom-PasswdLine ''))
Test-Case 'ConvertFrom-PasswdLine of a malformed line is $null' ($null -eq (ConvertFrom-PasswdLine 'not a passwd line'))

# The staging tar must never be taken for a backup by prune-backups or the
# inventory: run the real Get-BackupFile over a folder holding one.
$stagingDir = Initialize-ScratchDirectory 'wslclone_'
try {
    $stagingName = Get-CloneStagingName -NewName 'Ubuntu-test' -ProcessId 4242
    [IO.File]::WriteAllText((Join-Path $stagingDir $stagingName), 'staging')
    [IO.File]::WriteAllText((Join-Path $stagingDir 'Ubuntu_2026-10-21_1830.tar'), 'backup')
    $seen = @(Get-BackupFile -Directory $stagingDir | ForEach-Object { $_.File.Name })
    Test-Case "the staging tar '$stagingName' is not a backup to Get-BackupFile" (
        $seen.Count -eq 1 -and $seen[0] -eq 'Ubuntu_2026-10-21_1830.tar'
    ) ($seen -join ', ')
} finally {
    Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
}

$cloneClause = [string]$clauseText['clone']
$tries = @()
if ($actionSwitch) {
    $cloneAst = @($actionSwitch.Clauses | Where-Object { [string]$_.Item1.Value -eq 'clone' }) | Select-Object -First 1
    if ($cloneAst) {
        $tries = @($cloneAst.Item2.FindAll({
                    param($node) $node -is [System.Management.Automation.Language.TryStatementAst]
                }, $true))
    }
}
Test-Case 'the clone branch removes the staging tar in a finally block' (
    @($tries | Where-Object { $_.Finally -and $_.Finally.Extent.Text -match 'Remove-Item\s+-LiteralPath\s+\$staging' }).Count -ge 1
) $cloneClause.Substring(0, [math]::Min(400, $cloneClause.Length))
Test-Case 'the clone branch never unregisters anything' ($cloneClause -notmatch 'wsl\.exe\s+--unregister') $cloneClause.Substring(0, [math]::Min(200, $cloneClause.Length))

if ($onWindows) {
    Test-Skip 'the wsl.exe shim checks run only off Windows (see the header)'
} else {
    $shimDir = Initialize-WslShim -StatusExit 0
    $tarDir = Initialize-ScratchDirectory 'wslrestore_'
    try {
        $run = Invoke-WslManage -Arguments @('clone', '-NewName', 'Ubuntu-test') -PathPrefix $shimDir
        Test-Case 'clone with no -Distro exits 3' ($run.ExitCode -eq 3 -and $run.Output -match '-Distro') "exit $($run.ExitCode)`n$($run.Output)"
        $run = Invoke-WslManage -Arguments @('clone', '-Distro', 'Ubuntu') -PathPrefix $shimDir
        Test-Case 'clone with no -NewName exits 3' ($run.ExitCode -eq 3 -and $run.Output -match '-NewName') "exit $($run.ExitCode)`n$($run.Output)"

        # A real tar and sidecar, so the only thing wrong is the user name:
        # the refusal has to come before the tar is read, the distro list is
        # consulted or anything is imported.
        $tar = Write-BackupFixture $tarDir 'Ubuntu_2026-10-21_1830.tar' 'an export'
        $run = Invoke-WslManage -Arguments @('restore', '-Distro', 'Ubuntu-restored', '-Tar', $tar, '-DefaultUser', 'bad name') -PathPrefix $shimDir
        Test-Case 'restore -DefaultUser with an invalid name exits 3 before anything else' (
            $run.ExitCode -eq 3 -and $run.Output -match '-DefaultUser' -and $run.Output -notmatch 'SHA-256'
        ) "exit $($run.ExitCode)`n$($run.Output)"
        $calls = @(Get-Content -Path (Join-Path $shimDir 'calls.log') -ErrorAction SilentlyContinue)
        Test-Case 'and nothing but wsl --status was called' (
            @($calls | Where-Object { $_ -notmatch '^--status' }).Count -eq 0
        ) ($calls -join "`n")
    } finally {
        Remove-Item -Path $shimDir, $tarDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --------------------------------------------------------------------------
Write-Host ''
if ($failures -gt 0) {
    Write-Host "$failures wsl_manage contract check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host '=== all wsl_manage contract checks passed ==='
exit 0
