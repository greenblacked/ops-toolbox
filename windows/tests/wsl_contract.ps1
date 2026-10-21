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

function New-ScratchDirectory {
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

    $box = New-ScratchDirectory 'wslcontract_'
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
function New-WslShim {
    param([int]$StatusExit = 0)
    $dir = New-ScratchDirectory 'wslshim_'
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
$fixtures = New-ScratchDirectory 'wslconfig_'
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
Write-Host ''
if ($failures -gt 0) {
    Write-Host "$failures wsl_manage contract check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host '=== all wsl_manage contract checks passed ==='
exit 0
