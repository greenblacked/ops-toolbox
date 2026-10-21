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

$lfText = "[wsl2]`nmemory=8GB`n# a comment`n; another`nswap=0`n"
$crlfText = [string][char]0xFEFF + ($lfText -replace "`n", "`r`n")
$lfEntries = @(ConvertFrom-WslConfig -Text $lfText) | ConvertTo-Json -Compress
$crlfEntries = @(ConvertFrom-WslConfig -Text $crlfText) | ConvertTo-Json -Compress
Test-Case 'CRLF text with a UTF-8 BOM parses to the same entries as LF text' ($lfEntries -eq $crlfEntries) "LF:   $lfEntries`nCRLF: $crlfEntries"

Test-Case "ConvertTo-WslByteCount reads '1.5GB'" ((ConvertTo-WslByteCount '1.5GB') -eq [long](1.5 * 1GB))
Test-Case "ConvertTo-WslByteCount refuses '8 GB'" ($null -eq (ConvertTo-WslByteCount '8 GB'))

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
function Format-Plan {
    param([object[]]$Plan)
    ($Plan | ForEach-Object { '{0} {1} {2} {3}' -f $_.Verb, $_.Name, $_.Out, $_.Reason }) -join "`n"
}

$plan = @(Get-BackupPlan -Distros @((Get-TestDistro 'docker-desktop' 2GB), (Get-TestDistro 'docker-desktop-data' 20GB)) `
    -DestDir 'D:\Backups' -Stamp '2026-10-21_1830' -FreeBytes 100GB)
Test-Case "Docker Desktop's distros are skipped" (
    $plan.Count -eq 2 -and @($plan | Where-Object { $_.Verb -ne 'SKIP' }).Count -eq 0 -and
    @($plan | Where-Object { $_.Reason -match 'Docker Desktop' }).Count -eq 2
) (Format-Plan $plan)

$stamp = '2026-10-21_1830'
$plan = @(Get-BackupPlan -Distros @((Get-TestDistro 'Ubuntu' 10GB), (Get-TestDistro 'Debian' 5GB)) `
    -DestDir 'D:\Backups' -Stamp $stamp -FreeBytes 100GB)
Test-Case 'two distros plan two exports under one stamp, to two paths' (
    $plan.Count -eq 2 -and @($plan | Where-Object { $_.Verb -eq 'EXPORT' }).Count -eq 2 -and
    @($plan | Where-Object { $_.Out -like "*_$stamp.tar" }).Count -eq 2 -and
    $plan[0].Out -ne $plan[1].Out
) (Format-Plan $plan)

$plan = @(Get-BackupPlan -Distros @((Get-TestDistro 'Ubuntu' 60GB), (Get-TestDistro 'Debian' 5GB)) `
    -DestDir 'D:\Backups' -Stamp $stamp -FreeBytes 10GB -UsedByName @{ Ubuntu = 50GB })
Test-Case 'a measured distro bigger than the free space fails, and only that one' (
    @($plan | Where-Object { $_.Name -eq 'Ubuntu' -and $_.Verb -eq 'FAIL' -and $_.Reason -match 'needs' }).Count -eq 1 -and
    @($plan | Where-Object { $_.Name -eq 'Debian' -and $_.Verb -eq 'EXPORT' }).Count -eq 1
) (Format-Plan $plan)

$plan = @(Get-BackupPlan -Distros @((Get-TestDistro 'Ubuntu' 100GB)) -DestDir 'D:\Backups' -Stamp $stamp -FreeBytes 10GB)
Test-Case 'an unmeasured VHDX bigger than the free space is a warning, not a refusal' (
    $plan.Count -eq 1 -and $plan[0].Verb -eq 'WARN'
) (Format-Plan $plan)

$plan = @(Get-BackupPlan -Distros @((Get-TestDistro 'Ubuntu' 100GB)) -DestDir '\\server\share' -Stamp $stamp -FreeBytes $null -UsedByName @{ Ubuntu = 90GB })
Test-Case 'unknown free space (a UNC path) raises no space finding' (
    $plan.Count -eq 1 -and $plan[0].Verb -eq 'EXPORT'
) (Format-Plan $plan)

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
Write-Host ''
if ($failures -gt 0) {
    Write-Host "$failures wsl_manage contract check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host '=== all wsl_manage contract checks passed ==='
exit 0
