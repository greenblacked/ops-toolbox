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

# An uncaught error in this file would otherwise end it with PowerShell's own
# message and no [fail] line. Count it, say where, and fail the run.
trap {
    Test-Fail ("the contract script stopped on an error at line {0}: {1}" -f $_.InvocationInfo.ScriptLineNumber, $_.Exception.Message)
    Write-Host ''
    Write-Host "$failures wsl_manage contract check(s) failed" -ForegroundColor Red
    exit 1
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

foreach ($mode in 'nat', 'mirrored', 'consomme', 'virtioproxy', 'none', 'Mirrored', 'Consomme') {
    $found = Get-WslConfigFinding "[wsl2]`nmemory=8GB`nnetworkingMode=$mode"
    Test-Case "networkingMode=$mode is accepted" (
        @($found | Where-Object { $_.Level -eq 'warn' }).Count -eq 0
    ) (Format-Finding $found)
}
$found = Get-WslConfigFinding "[wsl2]`nmemory=8GB`nnetworkingMode=bridged"
Test-Case 'the deprecated networkingMode=bridged is info, not a warning' (
    @($found | Where-Object { $_.Level -eq 'warn' }).Count -eq 0 -and
    @($found | Where-Object { $_.Level -eq 'info' -and $_.Check -eq '[wsl2] networkingMode (line 3)' -and $_.Message -match 'deprecated' -and $_.Message -notmatch 'falls back' }).Count -eq 1
) (Format-Finding $found)
$found = Get-WslConfigFinding "[wsl2]`nmemory=8GB`nnetworkingMode=mirroed"
Test-Case 'a networkingMode WSL does not define is reported, with the NAT fallback' (
    @($found | Where-Object { $_.Level -eq 'warn' -and $_.Check -eq '[wsl2] networkingMode (line 3)' -and $_.Message -cmatch 'not nat, mirrored, consomme, virtioproxy or none.*falls back to NAT' }).Count -eq 1
) (Format-Finding $found)

# [wsl2] keys added to the table later: recognised, so never reported as
# unrecognised or misplaced, and typed only where the name settles it.
foreach ($newKey in @(@('virtiofs', 'true'), @('kernelDebugPort', '5005'), @('gpuSupport', 'true'),
        @('systemDistro', 'C:/wsl/system.vhdx'), @('telemetry', 'false'), @('kernelBootTimeout', '30000'))) {
    $key, $val = $newKey
    $found = Get-WslConfigFinding "[wsl2]`nmemory=8GB`n$key=$val"
    Test-Case "[wsl2] $key is a recognised key" (
        @($found | Where-Object { $_.Level -eq 'warn' }).Count -eq 0 -and
        @($found | Where-Object { $_.Message -match 'unrecognised|belongs in' }).Count -eq 0
    ) (Format-Finding $found)
}
$found = Get-WslConfigFinding "[wsl2]`nmemory=8GB`nvirtiofs=whatever`ntelemetry=maybe"
Test-Case 'virtiofs and telemetry are recognised without a value check' (
    @($found | Where-Object { $_.Level -eq 'warn' }).Count -eq 0
) (Format-Finding $found)
$found = Get-WslConfigFinding "[wsl2]`nmemory=8GB`ngpuSupport=yes"
Test-Case 'gpuSupport that is not true or false is reported' (
    @($found | Where-Object { $_.Level -eq 'warn' -and $_.Check -eq '[wsl2] gpuSupport (line 3)' -and $_.Message -match 'not true or false' }).Count -eq 1
) (Format-Finding $found)
foreach ($case in @(@('kernelDebugPort', 'abc'), @('kernelDebugPort', '-1'), @('kernelBootTimeout', 'soon'), @('kernelBootTimeout', '-5'))) {
    $key, $val = $case
    $found = Get-WslConfigFinding "[wsl2]`nmemory=8GB`n$key=$val"
    Test-Case "[wsl2] $key=$val is reported as not a whole number" (
        @($found | Where-Object { $_.Level -eq 'warn' -and $_.Check -eq "[wsl2] $key (line 3)" -and $_.Message -match 'not a whole number' }).Count -eq 1
    ) (Format-Finding $found)
}
$found = Get-WslConfigFinding "[wsl2]`nmemory=4GB`nsystemDistro=C:\\Users\\x\\s.vhdx"
Test-Case 'doubled backslashes in systemDistro= are not reported' (
    @($found | Where-Object { $_.Message -match 'doubled' }).Count -eq 0
) (Format-Finding $found)
$found = Get-WslConfigFinding "[wsl2]`nmemory=4GB`nsystemDistro=C:\Users\x\s.vhdx"
Test-Case 'single backslashes in systemDistro= are reported' (
    @($found | Where-Object { $_.Level -eq 'warn' -and $_.Check -like '*systemDistro*' -and $_.Message -match 'doubled' }).Count -eq 1
) (Format-Finding $found)

# Each key goes under the section the audit expects it in (general for
# instanceIdleTimeout, experimental for initialAutoProxyTimeout), otherwise
# the 'belongs in [...]' finding hides the whole-number check.
$numericSection = @{ instanceIdleTimeout = 'general'; initialAutoProxyTimeout = 'experimental' }
foreach ($case in @(
        @('vmIdleTimeout', '60000', 0), @('vmIdleTimeout', '0', 0), @('vmIdleTimeout', '-1', 0), @('vmIdleTimeout', '-2', 1), @('vmIdleTimeout', '1m', 1),
        @('instanceIdleTimeout', '-1', 0), @('instanceIdleTimeout', '-2', 1), @('initialAutoProxyTimeout', '-1', 1),
        @('vmIdleTimeout', '1.5', 1), @('vmIdleTimeout', '', 1),
        @('maxCrashDumpCount', '10', 0), @('maxCrashDumpCount', '-1', 0), @('maxCrashDumpCount', '-2', 1), @('maxCrashDumpCount', 'many', 1))) {
    $key, $val, $bad = $case
    $section = if ($numericSection.ContainsKey($key)) { $numericSection[$key] } else { 'wsl2' }
    $found = Get-WslConfigFinding "[$section]`n$key=$val"
    Test-Case "[$section] $key=$val is $(if ($bad) { 'reported as not a whole number' } else { 'accepted' })" (
        @($found | Where-Object { $_.Level -eq 'warn' -and $_.Check -eq "[$section] $key (line 2)" -and $_.Message -match 'not a whole number' }).Count -eq $bad -and
        @($found | Where-Object { $_.Message -match 'belongs in' }).Count -eq 0
    ) (Format-Finding $found)
}
$found = Get-WslConfigFinding "[general]`ninstanceIdleTimeout=soon`n[wsl2]`nmemory=8GB`n[experimental]`ninitialAutoProxyTimeout=1s"
Test-Case 'the other numeric keys are checked too' (
    @($found | Where-Object { $_.Level -eq 'warn' -and $_.Message -match 'not a whole number' }).Count -eq 2
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
$found = Get-WslConfigFinding "[wsl2]`nmemory=4GB`nkernelModules=C:\Users\x\m.vhdx"
Test-Case 'single backslashes in kernelModules= are reported' (
    @($found | Where-Object { $_.Level -eq 'warn' -and $_.Check -like '*kernelModules*' -and $_.Message -match 'doubled' }).Count -eq 1
) (Format-Finding $found)
$found = Get-WslConfigFinding "[wsl2]`nmemory=4GB`nkernelModules=C:\\Users\\x\\m.vhdx"
Test-Case 'doubled backslashes in kernelModules= are not' (
    @($found | Where-Object { $_.Message -match 'doubled' }).Count -eq 0
) (Format-Finding $found)
$found = Get-WslConfigFinding "[general]`ndistributionInstallPath=C:\Users\x\wsl`n[wsl2]`nmemory=4GB"
Test-Case 'single backslashes in distributionInstallPath= are reported' (
    @($found | Where-Object { $_.Level -eq 'warn' -and $_.Check -like '*distributionInstallPath*' -and $_.Message -match 'doubled' }).Count -eq 1
) (Format-Finding $found)
$found = Get-WslConfigFinding "[general]`ndistributionInstallPath=C:\\Users\\x\\wsl`n[wsl2]`nmemory=4GB"
Test-Case 'doubled backslashes in distributionInstallPath= are not' (
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
Test-Case 'ConvertTo-WslByteCount returns $null past Int64 instead of throwing' (
    $null -eq (ConvertTo-WslByteCount '999999999999999999999TB') -and
    $null -eq (ConvertTo-WslByteCount '9223372036854775808') -and
    $null -eq (ConvertTo-WslByteCount ('9' * 400)) -and
    $null -eq (ConvertTo-WslByteCount '9000000TB')
)
$found = Get-WslConfigFinding "[wsl2]`nmemory=999999999999999999999TB`n"
Test-Case 'a memory size beyond Int64 is reported as not a size, and the audit goes on' (
    @($found | Where-Object { $_.Level -eq 'warn' -and $_.Check -eq '[wsl2] memory (line 2)' -and $_.Message -match 'is not a size' }).Count -eq 1
) (Format-Finding $found)
$found = Get-WslConfigFinding "[wsl2]`nmemory=8GB`nswap=0`n"
Test-Case 'swap=0 (no unit, swap off) is a valid size, not a warning' (
    @($found | Where-Object { $_.Message -match 'is not a size' }).Count -eq 0 -and
    @($found | Where-Object { $_.Level -eq 'ok' -and $_.Check -eq '[wsl2] swap (line 3)' }).Count -eq 1
) (Format-Finding $found)
$found = Get-WslConfigFinding "[wsl2]`nmemory=8GB`ndefaultVhdSize=1TB`n"
Test-Case 'defaultVhdSize with a size is a pass' (
    @($found | Where-Object { $_.Level -eq 'ok' -and $_.Check -eq '[wsl2] defaultVhdSize (line 3)' }).Count -eq 1
) (Format-Finding $found)
$found = Get-WslConfigFinding "[wsl2]`nmemory=8GB`ndefaultVhdSize=big`n"
Test-Case 'defaultVhdSize that is not a size is reported' (
    @($found | Where-Object { $_.Level -eq 'warn' -and $_.Check -eq '[wsl2] defaultVhdSize (line 3)' -and $_.Message -match 'is not a size' }).Count -eq 1
) (Format-Finding $found)

# Behavioural: the action needs no WSL, so these run on every runner.
$fixtures = Initialize-ScratchDirectory 'wslconfig_'
try {
    $badFile = Join-Path $fixtures 'bad.wslconfig'
    $cleanFile = Join-Path $fixtures 'clean.wslconfig'
    [IO.File]::WriteAllText($badFile, "[wsl2]`nmemry=8GB`n")
    [IO.File]::WriteAllText($cleanFile, $cleanConfig)
    foreach ($mode in 'consomme', 'virtioproxy', 'Consomme', 'consome') {
        # Case-sensitive: 'consomme' and 'Consomme' must not share a file name on NTFS.
        $name = switch -CaseSensitive ($mode) { 'consome' { 'unknown' } 'Consomme' { 'consomme_upper' } default { $mode } }
        [IO.File]::WriteAllText((Join-Path $fixtures "mode_$name.wslconfig"), "[wsl2]`nmemory=8GB`nnetworkingMode=$mode`n[experimental]`nautoMemoryReclaim=gradual`nsparseVhd=true`n")
    }
    $before = @(Get-TreeSnapshot $fixtures)

    $run = Invoke-WslManage -Arguments @('wslconfig', '-ConfigFile', $badFile)
    Test-Case 'wslconfig reports warnings and exits 0' ($run.ExitCode -eq 0 -and $run.Output -match 'WARN') "exit $($run.ExitCode)`n$($run.Output)"
    Test-Case 'wslconfig names the file it read' ($run.Output -match [regex]::Escape($badFile)) $run.Output

    $run = Invoke-WslManage -Arguments @('wslconfig', '-ConfigFile', $badFile, '-Strict')
    Test-Case 'wslconfig -Strict exits 1 on a warning' ($run.ExitCode -eq 1) "exit $($run.ExitCode)`n$($run.Output)"

    $run = Invoke-WslManage -Arguments @('wslconfig', '-ConfigFile', $cleanFile, '-Strict')
    Test-Case 'wslconfig -Strict exits 0 on a clean file' ($run.ExitCode -eq 0) "exit $($run.ExitCode)`n$($run.Output)"

    foreach ($mode in 'consomme', 'virtioproxy', 'Consomme') {
        $name = switch -CaseSensitive ($mode) { 'Consomme' { 'consomme_upper' } default { $mode } }
        $run = Invoke-WslManage -Arguments @('wslconfig', '-ConfigFile', (Join-Path $fixtures "mode_$name.wslconfig"), '-Strict')
        Test-Case "wslconfig -Strict exits 0 with networkingMode=$mode" ($run.ExitCode -eq 0) "exit $($run.ExitCode)`n$($run.Output)"
    }
    $run = Invoke-WslManage -Arguments @('wslconfig', '-ConfigFile', (Join-Path $fixtures 'mode_unknown.wslconfig'), '-Strict')
    Test-Case 'wslconfig -Strict exits 1 with an unknown networkingMode' ($run.ExitCode -eq 1) "exit $($run.ExitCode)`n$($run.Output)"

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

Import-ScriptFunction -Path $wslScript -Name @('Format-Size', 'ConvertTo-DriveRootPath', 'Get-BackupOutPath', 'Get-UniqueBackupOutPath', 'Get-BackupPlan')

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

foreach ($bare in @('D:', 'd:')) {
    $plan = @(Get-BackupPlan -Distros @((Get-TestDistro 'Ubuntu' 1GB)) -DestDir $bare -Stamp $stamp -FreeBytes $null)
    Test-Case "a bare drive -DestDir '$bare' means the drive root, not the drive's current directory" (
        $plan.Count -eq 1 -and $plan[0].Out.StartsWith($bare + '\') -and $plan[0].Out.EndsWith('Ubuntu_' + $stamp + '.tar')
    ) (Format-Plan $plan)
}
$single = Get-BackupOutPath -Dir 'D:' -Name 'Ubuntu' -Stamp $stamp
$multi = @(Get-BackupPlan -Distros @((Get-TestDistro 'Ubuntu' 1GB)) -DestDir 'D:' -Stamp $stamp -FreeBytes $null)[0].Out
Test-Case 'the single-distro and -All backups build the same output path' ($single -eq $multi) "$single vs $multi"

foreach ($case in @(@('D:', 'D:\'), @('d:', 'd:\'), @('D:\', 'D:\'), @('D:\Backups', 'D:\Backups'), @('D:Backups', 'D:Backups'), @('\\server\share', '\\server\share'))) {
    $got = ConvertTo-DriveRootPath $case[0]
    Test-Case "ConvertTo-DriveRootPath '$($case[0])' is '$($case[1])'" ($got -ceq $case[1]) $got
}

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
Import-ScriptFunction -Path $wslScript -Name @('Format-WslOutput', 'Get-BackupRollbackLead', 'Invoke-DistroBackup')
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
        [IO.File]::ReadAllText("$backupOut.sha256").TrimEnd("`r", "`n") -eq "$newHash  Ubuntu_2026-10-21_1830.tar" -and
        $left.Count -eq 2
    ) ($left -join "`n")

    # The new sidecar failing to land must not cost the earlier pair. The
    # stand-in export leaves a directory where the new sidecar is about to be
    # written, so that step fails the way a locked or read-only path does,
    # through the real cmdlets and with no built-in shadowed.
    $pairTar = 'earlier good export 2'
    $pairSide = 'earlier-hash-2  Ubuntu_2026-10-21_1830.tar'
    [IO.File]::WriteAllText($backupOut, $pairTar)
    [IO.File]::WriteAllText("$backupOut.sha256", $pairSide)
    function wsl.exe {
        [IO.File]::WriteAllText([string]$args[2], 'unfinished export')
        New-Item -ItemType Directory -Path ('{0}.sha256' -f $args[2]) | Out-Null
        $global:LASTEXITCODE = 0
    }
    $backedUp = Invoke-DistroBackup -Name 'Ubuntu' -Out $backupOut 2>$null 6>$null
    function wsl.exe {
        [IO.File]::WriteAllText([string]$args[2], 'new export')
        $global:LASTEXITCODE = 0
    }
    $left = @(Get-ChildItem -LiteralPath $backupDir -Force | ForEach-Object { $_.Name } | Sort-Object)
    Test-Case 'a sidecar that cannot be put in place makes the backup return false' ($backedUp -eq $false)
    Test-Case 'and leaves the earlier tar and sidecar pair as it was, with nothing else' (
        [IO.File]::ReadAllText($backupOut) -eq $pairTar -and
        [IO.File]::ReadAllText("$backupOut.sha256") -eq $pairSide -and
        $left.Count -eq 2
    ) ($left -join "`n")

    # A failure after the earlier pair has been set aside must put it back.
    # The stand-in export keeps its output open for reading without delete
    # sharing, which Get-FileHash can still read. The earlier tar and sidecar
    # have both been set aside by the time the export is moved onto the tar's
    # name, and Windows refuses to rename a file that is open that way, so the
    # rollback has both files to put back. Only Windows enforces that, so the
    # case is skipped elsewhere and says so.
    if ($onWindows) {
        [IO.File]::WriteAllText($backupOut, $pairTar)
        [IO.File]::WriteAllText("$backupOut.sha256", $pairSide)
        $script:heldExport = $null
        function wsl.exe {
            [IO.File]::WriteAllText([string]$args[2], 'unfinished export')
            $script:heldExport = [IO.File]::Open([string]$args[2], [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            $global:LASTEXITCODE = 0
        }
        try {
            # Invoke-DistroBackup is a simple function, so -ErrorVariable does
            # not bind; read its error stream through the pipeline instead.
            $all = @(Invoke-DistroBackup -Name 'Ubuntu' -Out $backupOut 2>&1 6>$null)
            $rollbackErrors = @($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
            $backedUp = @($all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) | Select-Object -Last 1
            $leftover = @(Get-ChildItem -LiteralPath $backupDir -Force | ForEach-Object { $_.Name } | Sort-Object)
        } finally {
            if ($null -ne $script:heldExport) { $script:heldExport.Dispose(); $script:heldExport = $null }
        }
        function wsl.exe {
            [IO.File]::WriteAllText([string]$args[2], 'new export')
            $global:LASTEXITCODE = 0
        }
        Test-Case 'a failure after the earlier pair was set aside returns false' ($backedUp -eq $false)
        # The earlier pair went back, so nothing earlier is stuck and the
        # error must not lead with the earlier backup (if it reports at all).
        Test-Case 'and reports the failed backup (proves the error was captured)' (
            @($rollbackErrors | Where-Object { "$_" -like '*Could not finish the backup*' }).Count -ge 1
        ) (@($rollbackErrors | ForEach-Object { "$_" }) -join "`n")
        Test-Case 'and does not claim the earlier backup could not be put back' (
            @($rollbackErrors | Where-Object { "$_" -like 'The earlier backup could not be fully put back*' }).Count -eq 0
        ) (@($rollbackErrors | ForEach-Object { "$_" }) -join "`n")
        Test-Case 'and puts the earlier tar and sidecar back with their content' (
            [IO.File]::ReadAllText($backupOut) -eq $pairTar -and
            [IO.File]::ReadAllText("$backupOut.sha256") -eq $pairSide
        ) ($leftover -join "`n")
        # The held export cannot be deleted while it is open, so it is the
        # one file allowed to remain at that point; nothing else may.
        $strays = @($leftover | Where-Object { $_ -ne 'Ubuntu_2026-10-21_1830.tar' -and $_ -ne 'Ubuntu_2026-10-21_1830.tar.sha256' })
        Test-Case 'and leaves no set-aside copy or temporary sidecar' (
            @($strays | Where-Object { $_ -match '\.old' -or $_ -match '\.sha256$' }).Count -eq 0 -and
            @($strays | Where-Object { $_ -match '\.partial$' }).Count -le 1
        ) ($leftover -join "`n")
        Get-ChildItem -LiteralPath $backupDir -Force | Where-Object { $_.Name -match '\.partial' } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
        [IO.File]::WriteAllText($backupOut, $pairTar)
        [IO.File]::WriteAllText("$backupOut.sha256", $pairSide)
    } else {
        Test-Skip 'the rollback after the swap starts needs a file open without delete sharing, which only Windows enforces'
    }

    # The lead of the rollback error, chosen from whether an earlier file is
    # still out of place. A failure to clean up only a new file cannot be
    # forced on the real filesystem without a mock, so the choice is tested
    # on its own.
    Test-Case 'the rollback error leads with the earlier backup when an earlier file is stuck' (
        (Get-BackupRollbackLead -EarlierStuck $true) -eq 'The earlier backup could not be fully put back: '
    )
    Test-Case 'and leads with the new backup when only new files could not be cleaned up' (
        (Get-BackupRollbackLead -EarlierStuck $false) -eq 'The new backup could not be cleaned up: '
    )

    # A read-only earlier sidecar: whether the platform lets it be replaced
    # or not, the tar and its sidecar must agree afterwards and the call
    # must return normally.
    Set-ItemProperty -LiteralPath "$backupOut.sha256" -Name IsReadOnly -Value $true
    $backedUp = Invoke-DistroBackup -Name 'Ubuntu' -Out $backupOut 2>$null 6>$null
    $left = @(Get-ChildItem -LiteralPath $backupDir -Force | ForEach-Object { $_.Name } | Sort-Object)
    $tarNow = [IO.File]::ReadAllText($backupOut)
    $sideNow = [IO.File]::ReadAllText("$backupOut.sha256").TrimEnd("`r", "`n")
    $hashNow = (Get-FileHash -LiteralPath $backupOut -Algorithm SHA256).Hash.ToLowerInvariant()
    Test-Case 'with a read-only earlier sidecar the tar and sidecar still agree' (
        $backedUp -is [bool] -and $left.Count -eq 2 -and
        (($backedUp -and $tarNow -eq 'new export' -and $sideNow -eq "$hashNow  Ubuntu_2026-10-21_1830.tar") -or
        (-not $backedUp -and $tarNow -eq $pairTar -and $sideNow -eq $pairSide))
    ) ($left -join "`n")
} finally {
    Remove-Item -LiteralPath Function:\wsl.exe -ErrorAction SilentlyContinue
    Remove-Item -Path $backupDir -Recurse -Force -ErrorAction SilentlyContinue
}

# backup -All carries on past a distro whose backup returns $false, reports
# it and exits 1 at the end. The script body cannot run here (its distro list
# comes from the registry), so the statements of the -All branch that run the
# backups are cut out of the syntax tree and run in a child process with a
# stand-in Invoke-DistroBackup that fails for one distro by name.
$allParsed = [System.Management.Automation.Language.Parser]::ParseFile($wslScript, [ref]$null, [ref]$null)
$exportedInit = $allParsed.Find({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$exported' -and $node.Right.Extent.Text -eq '0'
    }, $true)
$allStatements = @()
if ($exportedInit) {
    $inBlock = $false
    foreach ($statement in $exportedInit.Parent.Statements) {
        if ($statement -eq $exportedInit) { $inBlock = $true }
        if (-not $inBlock) { continue }
        $allStatements += $statement.Extent.Text
        if ($statement -is [System.Management.Automation.Language.IfStatementAst] -and
            $statement.Clauses[0].Item1.Extent.Text -match '\$failed\s+-gt\s+0') { break }
    }
}
Test-Case 'the backup -All loop and its exit status were found in the script' (
    $allStatements.Count -gt 0 -and $allStatements[-1] -match 'exit 1'
) ($allStatements -join "`n")
if ($allStatements.Count -gt 0) {
    $allDir = Initialize-ScratchDirectory 'wslall-'
    try {
        $sizeText = $allParsed.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Format-Size'
            }, $true).Extent.Text
        $trace = Join-Path $allDir 'trace.log'
        $template = @'
@@SIZE@@
function Invoke-DistroBackup {
    param([string]$Name, [string]$Out)
    Add-Content -LiteralPath '@@TRACE@@' -Value $Name
    if ($Name -eq 'Broken') { return $false }
    [IO.File]::WriteAllText($Out, 'exported')
    return $true
}
$plan = @(
    [pscustomobject]@{ Name = 'Broken'; Out = '@@BROKEN@@'; Verb = 'EXPORT'; Reason = '' }
    [pscustomobject]@{ Name = 'Healthy'; Out = '@@HEALTHY@@'; Verb = 'EXPORT'; Reason = '' }
)
@@LOOP@@
'@
        $driver = $template.Replace('@@SIZE@@', $sizeText).Replace('@@TRACE@@', $trace.Replace("'", "''")).
            Replace('@@BROKEN@@', (Join-Path $allDir 'Broken.tar').Replace("'", "''")).
            Replace('@@HEALTHY@@', (Join-Path $allDir 'Healthy.tar').Replace("'", "''")).
            Replace('@@LOOP@@', ($allStatements -join "`n"))
        $driverPath = Join-Path $allDir 'driver.ps1'
        [IO.File]::WriteAllText($driverPath, $driver, [Text.Encoding]::ASCII)
        $allText = & $pwshExe -NoProfile -File $driverPath 2>&1 | Out-String
        $allExit = $LASTEXITCODE
        $order = @(Get-Content -LiteralPath $trace -ErrorAction SilentlyContinue)
        Test-Case 'a distro whose backup returns false does not stop the next one' (
            ($order -join ',') -eq 'Broken,Healthy' -and (Test-Path -LiteralPath (Join-Path $allDir 'Healthy.tar'))
        ) ("{0}`n{1}" -f ($order -join ','), $allText)
        Test-Case 'and the failure is reported, the other distro counted, and the exit status is 1' (
            $allExit -eq 1 -and $allText -cmatch 'FAIL\s+Broken' -and $allText -cmatch 'DONE\s+.*Healthy\.tar' -and
            $allText -match 'Exported 1, skipped 0, failed 1'
        ) "exit $allExit`n$allText"
    } finally {
        Remove-Item -Path $allDir -Recurse -Force -ErrorAction SilentlyContinue
    }
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
# A script-level variable named like a parameter IS that parameter, so
# $all = @(...) in a branch tried to turn a list into the [switch]$All and
# stopped the action on Windows. Read from the syntax tree, outside functions.
$paramNames = @($parsed.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
$clobbered = @($parsed.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [System.Management.Automation.Language.VariableExpressionAst]
        }, $true) | Where-Object {
        $inFunction = $false
        for ($p = $_.Parent; $p; $p = $p.Parent) {
            if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $inFunction = $true; break }
        }
        -not $inFunction -and ($paramNames -contains $_.Left.VariablePath.UserPath)
    } | ForEach-Object { '{0} (line {1})' -f $_.Left.Extent.Text, $_.Extent.StartLineNumber })
Test-Case 'no script-level code assigns to a variable that is also a parameter' (
    $paramNames.Count -gt 10 -and $clobbered.Count -eq 0
) ($clobbered -join "`n")
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
        $run.ExitCode -eq 1 -and $run.Output -cmatch 'MISS\s+Debian_2026-10-19_0800\.tar' -and $run.Output -match 'Hashing 3 file'
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
        $run.ExitCode -eq 1 -and $run.Output -cmatch 'STALE Ubuntu newest backup is 10 day'
    ) "exit $($run.ExitCode)`n$($run.Output)"
    (Get-Item -LiteralPath $newest).LastWriteTime = $savedTime
    $run = Invoke-WslManage -Arguments @('backups', '-DestDir', $backupDir, '-MaxAgeDays', '1')
    Test-Case 'a recent newest backup is not stale -> 0' ($run.ExitCode -eq 0 -and $run.Output -cnotmatch 'STALE ') "exit $($run.ExitCode)`n$($run.Output)"

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
        $run.ExitCode -eq 1 -and $run.Output -cmatch 'BAD\s+Ubuntu_2026-10-20_0900\.tar' -and $run.Output -match 'expected'
    ) "exit $($run.ExitCode)`n$($run.Output)"
    $run = Invoke-WslManage -Arguments @('verify-backup', '-Tar', $newest)
    Test-Case 'verify-backup still exits 1 on a mismatch' ($run.ExitCode -eq 1 -and $run.Output -match 'mismatch') "exit $($run.ExitCode)`n$($run.Output)"

    Set-Content -LiteralPath "$older.sha256" -Value 'not a hash'
    $run = Invoke-WslManage -Arguments @('backups', '-DestDir', $backupDir, '-Verify', '-Distro', 'Ubuntu')
    Test-Case 'a malformed sidecar is BAD' ($run.Output -cmatch 'BAD\s+Ubuntu_2026-08-01_0900\.tar.*malformed') $run.Output
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

# -DestDir D: is read as D:\ once, before the action switch, and no action
# builds a path under it with Join-Path (which leaves a bare drive relative).
$bareRun = Invoke-WslManage -Arguments @('backups', '-DestDir', 'D:')
Test-Case "backups -DestDir D: reports the drive root D:\, not the drive-relative D:" (
    $bareRun.ExitCode -eq 0 -and $bareRun.Output -match 'D:\\'
) "exit $($bareRun.ExitCode)`n$($bareRun.Output)"
$wslText = [IO.File]::ReadAllText($wslScript)
$normAt = $wslText.IndexOf('$destRoot = ConvertTo-DriveRootPath $DestDir')
$switchAt = $wslText.IndexOf('switch ($Action) {')
Test-Case '-DestDir is normalised once, before the action switch' ($normAt -ge 0 -and $switchAt -gt $normAt)
foreach ($a in @('backups', 'prune-backups', 'clone')) {
    Test-Case "the $a branch builds no path under -DestDir with Join-Path" ([string]$clauseText[$a] -notmatch 'Join-Path\s+\$(DestDir|destRoot)') ([string]$clauseText[$a]).Substring(0, [math]::Min(200, ([string]$clauseText[$a]).Length))
}
Test-Case 'the clone branch builds its paths under -DestDir with Path.Combine or Get-BackupOutPath' (
    [string]$clauseText['clone'] -match 'Combine\(\$destRoot' -and [string]$clauseText['clone'] -match 'Get-(Unique)?BackupOutPath\s+-Dir\s+\$destRoot'
)

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

Import-ScriptFunction -Path $wslScript -Name @('Test-WslUserName', 'Get-WslConfUserPlan', 'Get-WslConfDefaultUser',
    'Invoke-DefaultUserStep', 'Format-WslOutput', 'ConvertFrom-PasswdLine', 'Get-CloneStagingName', 'Get-BackupFile')

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

# With the wanted user, a [user] default= is satisfied only by an exact match.
$userPlanCases = @(
    @{ Text = "[user]`ndefault=alice`n";  User = 'alice'; Expect = 'present'; Label = 'the same default user' }
    @{ Text = "[user]`ndefault=alice`n";  User = 'bob';   Expect = 'update';  Label = 'another default user' }
    @{ Text = "[user]`ndefault=Alice`n";  User = 'alice'; Expect = 'update';  Label = 'a default user that differs only in case' }
    @{ Text = "[boot]`nsystemd=true`n[user]`r`ndefault = alice`r`n"; User = 'bob'; Expect = 'update'; Label = 'CRLF text and spaces around =' }
    @{ Text = "[user]`n# nothing`n";      User = 'bob';   Expect = 'manual';  Label = 'a [user] section with no default=' }
    @{ Text = '';                         User = 'bob';   Expect = 'append';  Label = 'no /etc/wsl.conf' }
)
foreach ($case in $userPlanCases) {
    $got = Get-WslConfUserPlan -Existing $case.Text -User $case.User
    Test-Case "Get-WslConfUserPlan -User $($case.User): $($case.Label) -> $($case.Expect)" ($got -eq $case.Expect) "got '$got'"
}
Test-Case 'Get-WslConfDefaultUser reads the [user] default' ((Get-WslConfDefaultUser "[boot]`ndefault=x`n[user]`ndefault=alice`n") -ceq 'alice')
Test-Case 'Get-WslConfDefaultUser of no default is $null' ($null -eq (Get-WslConfDefaultUser "[user]`n"))

# Invoke-DefaultUserStep against a stand-in wsl.exe that records what it is
# asked to do. A tar that already names another default user must end with the
# requested one, and a failed rewrite must be reported as a failure.
function Invoke-DefaultUserScenario {
    param([string]$Conf, [string]$User, [int]$SedExit = 0, [string]$Who = $User)
    $script:duCalls = [System.Collections.Generic.List[string]]::new()
    $script:duConf = $Conf
    $script:duSedExit = $SedExit
    $script:duWho = $Who
    function script:wsl.exe {
        $script:duCalls.Add(($args -join ' '))
        $global:LASTEXITCODE = 0
        if ($args[-1] -like 'cat /etc/wsl.conf*') { return $script:duConf -split "`n" }
        if ($args[-1] -like 'sed -i*' -or $args[-1] -like 'printf*') { $global:LASTEXITCODE = $script:duSedExit; return }
        if ($args -contains 'id') { return $script:duWho }
    }
    $rc = Invoke-DefaultUserStep -Name 'Ubuntu-restored' -User $User 2>$null 6>$null
    return $rc
}
try {
    $rc = Invoke-DefaultUserScenario -Conf "[user]`ndefault=alice`n" -User 'alice'
    Test-Case 'DefaultUser step: existing default equals the request -> success, nothing written' (
        $rc -eq $true -and @($script:duCalls | Where-Object { $_ -match 'sed -i|printf|--terminate' }).Count -eq 0
    ) ($script:duCalls -join "`n")

    $rc = Invoke-DefaultUserScenario -Conf "[user]`ndefault=alice`n" -User 'bob'
    $sedCalls = @($script:duCalls | Where-Object { $_ -match 'sed -i' })
    Test-Case 'DefaultUser step: existing default differs -> rewritten to the request, terminated, success' (
        $rc -eq $true -and $sedCalls.Count -eq 1 -and $sedCalls[0] -match 'default=bob' -and $sedCalls[0] -notmatch 'printf' -and
        @($script:duCalls | Where-Object { $_ -match '--terminate' }).Count -eq 1
    ) ($script:duCalls -join "`n")

    $rc = Invoke-DefaultUserScenario -Conf "[user]`ndefault=alice`n" -User 'bob' -SedExit 1
    Test-Case 'DefaultUser step: a failed rewrite returns failure and does not terminate' (
        $rc -eq $false -and @($script:duCalls | Where-Object { $_ -match '--terminate' }).Count -eq 0
    ) ($script:duCalls -join "`n")

    $rc = Invoke-DefaultUserScenario -Conf "[user]`ndefault=alice`n" -User 'bob' -Who 'alice'
    Test-Case 'DefaultUser step: still booting as another user after the rewrite returns failure' ($rc -eq $false)

    $rc = Invoke-DefaultUserScenario -Conf '' -User 'bob'
    Test-Case 'DefaultUser step: no wsl.conf -> appended as before, success' (
        $rc -eq $true -and @($script:duCalls | Where-Object { $_ -match 'printf' }).Count -eq 1 -and
        @($script:duCalls | Where-Object { $_ -match 'sed -i' }).Count -eq 0
    ) ($script:duCalls -join "`n")
} finally {
    Remove-Item -LiteralPath Function:\wsl.exe -ErrorAction SilentlyContinue
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

# -KeepTar must never lose the requested backup to a name that is taken:
# the next free -N name is used, sidecars count as taken, and the parser
# behind prune-backups and backups still reads the result.
$uniqueDir = Initialize-ScratchDirectory 'wslunique_'
try {
    $uStamp = '2026-10-21_1830'
    $first = Get-UniqueBackupOutPath -Dir $uniqueDir -Name 'Ubuntu' -Stamp $uStamp
    Test-Case 'Get-UniqueBackupOutPath keeps the plain name while it is free' ((Split-Path -Leaf $first) -ceq 'Ubuntu_2026-10-21_1830.tar') $first
    [IO.File]::WriteAllText($first, 'one')
    $second = Get-UniqueBackupOutPath -Dir $uniqueDir -Name 'Ubuntu' -Stamp $uStamp
    Test-Case 'Get-UniqueBackupOutPath appends -1 when the stamp is taken' ((Split-Path -Leaf $second) -ceq 'Ubuntu_2026-10-21_1830-1.tar') $second
    [IO.File]::WriteAllText("$second.sha256", 'orphan sidecar')
    $third = Get-UniqueBackupOutPath -Dir $uniqueDir -Name 'Ubuntu' -Stamp $uStamp
    Test-Case 'Get-UniqueBackupOutPath counts a lone sidecar as taken (-2)' ((Split-Path -Leaf $third) -ceq 'Ubuntu_2026-10-21_1830-2.tar') $third
    [IO.File]::WriteAllText($third, 'three')
    $seen = @(Get-BackupFile -Directory $uniqueDir -Name 'Ubuntu' | ForEach-Object { $_.File.Name } | Sort-Object)
    Test-Case 'Get-BackupFile reads the -N names as backups of the same distro' (
        $seen.Count -eq 2 -and $seen[0] -ceq 'Ubuntu_2026-10-21_1830-2.tar' -and $seen[1] -ceq 'Ubuntu_2026-10-21_1830.tar'
    ) ($seen -join ', ')
    Test-Case 'the original tar was not touched' ([IO.File]::ReadAllText($first) -ceq 'one')
} finally {
    Remove-Item -Path $uniqueDir -Recurse -Force -ErrorAction SilentlyContinue
}

$cloneClause = [string]$clauseText['clone']
Test-Case 'the clone branch picks a free name for -KeepTar and never skips the keep' (
    $cloneClause -cmatch 'Get-UniqueBackupOutPath\s+-Dir\s+\$destRoot' -and $cloneClause -cnotmatch 'Not keeping the export'
) $cloneClause.Substring(0, [math]::Min(200, $cloneClause.Length))
Test-Case 'the clone branch fails and keeps the staging tar when -KeepTar cannot move it' (
    $cloneClause -cmatch 'Move-Item\s+-LiteralPath\s+\$staging[^\r\n]*-ErrorAction\s+Stop' -and
    $cloneClause -cmatch '(?s)\$kept\s*=\s*\$true.*?-not\s+\$dated.*?\$rc\s*=\s*1.*?catch\s*\{.*?\$rc\s*=\s*1'
) $cloneClause.Substring(0, [math]::Min(200, $cloneClause.Length))
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
        $run = Invoke-WslManage -Arguments @('prune-backups', '-DestDir', 'D:', '-DryRun') -PathPrefix $shimDir
        Test-Case "prune-backups -DestDir D: reports the drive root D:\, not the drive-relative D:" (
            $run.ExitCode -eq 0 -and $run.Output -match 'D:\\'
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
