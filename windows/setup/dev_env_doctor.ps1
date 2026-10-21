<#
.SYNOPSIS
    Read-only check of the Windows settings a developer toolchain trips over.

.DESCRIPTION
    workstation_doctor.ps1 and status.ps1 answer "is the machine healthy".
    This answers "will my toolchain work here": the configuration that breaks
    git, containers and cloud CLIs on Windows while the machine itself looks
    fine. Sections, in order:

      paths           LongPathsEnabled, and git's core.longpaths beside it:
                      paths over 260 characters break git checkouts and
                      node_modules
      git             core.autocrlf (CRLF in a shell script is
                      "\r: command not found" inside a Linux container),
                      core.symlinks against Developer Mode, the credential
                      helper, core.eol
      virtualization  a running hypervisor or firmware virtualization (WSL2 and
                      Docker Desktop cannot start without one), the WSL and
                      Virtual Machine Platform features, Developer Mode
      time            the Windows Time service; with -CheckTime, the clock
                      offset against time.windows.com, because Kerberos, AWS
                      SigV4 and JWTs fail on a skewed clock
      shell           pwsh and the running edition, HOME against USERPROFILE
                      (Git Bash, ssh and git read different home folders when
                      they differ), PSReadLine
      containers      the docker CLI, the current docker context, DOCKER_HOST,
                      and the Docker Desktop service

    It reads registry values, CIM classes, service states and global git
    settings. It changes nothing, restarts nothing, and resyncs nothing; every
    [warn] is followed by the command that fixes it, printed for a person to
    run. The only network traffic is the single NTP sample -CheckTime asks
    for. Probes that need elevation say so and carry on.

    -ListSections and the argument checks answer before the Windows
    preflight, so they work on Linux pwsh. There is no -DryRun because there
    is nothing to preview; -Action takes one value, 'report', which is the
    read-only default the contract checks look for.

.PARAMETER Only
    Comma-separated section ids (see -ListSections). Unknown ids exit 3; a
    list that selects nothing exits 4.

.PARAMETER CheckTime
    Measure the clock offset with one w32tm sample against time.windows.com.

.PARAMETER MaxSkewSeconds
    The offset, in seconds, that -CheckTime warns above. 1 to 3600, default 5.

.EXAMPLE
    .\dev_env_doctor.ps1
    .\dev_env_doctor.ps1 -ListSections
    .\dev_env_doctor.ps1 -Only git,paths
    .\dev_env_doctor.ps1 -CheckTime -MaxSkewSeconds 2

.NOTES
    Exit codes, matching workstation_doctor.ps1 plus the -Only codes of
    status.ps1:
      0  the report ran (warnings do not change the exit code)
      2  not Windows
      3  invalid arguments: unknown -Only section, -MaxSkewSeconds out of range
      4  -Only selected nothing
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('report')]
    [string]$Action = 'report',

    # A list, split on commas in the body, for the reason stay_fresh.ps1 gives.
    [string[]]$Only = @(),

    [switch]$ListSections,

    [switch]$CheckTime,

    # Range-checked by hand below: a ValidateRange failure under 'pwsh -File'
    # exits 1, and a value out of range is a usage error (3).
    [int]$MaxSkewSeconds = 5,

    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$script:Warnings = 0
$script:QuietMode = [bool]$Quiet

$SectionOrder = @('paths', 'git', 'virtualization', 'time', 'shell', 'containers')

function Write-Info {
    param([string]$Message)
    if (-not $script:QuietMode) { Write-Host "[info] $Message" -ForegroundColor Blue }
}
function Write-Ok {
    param([string]$Message)
    if (-not $script:QuietMode) { Write-Host "[ ok ] $Message" -ForegroundColor Green }
}
# The fix goes on the line under the warning, dimmed, and is only printed.
function Write-Warn {
    param([string]$Message, [string[]]$Hint = @())
    $script:Warnings++
    Write-Host "[warn] $Message" -ForegroundColor Yellow
    foreach ($line in $Hint) { Write-Host "  $line" -ForegroundColor DarkGray }
}
function Write-Err  { param([string]$Message) Write-Host "[err ] $Message" -ForegroundColor Red }
function Write-Section {
    param([string]$Name)
    if (-not $script:QuietMode) { Write-Host ''; Write-Host "== $Name ==" -ForegroundColor White }
}

# --- pure helpers -----------------------------------------------------------
# Plain data in, plain data out, so windows/tests/contract.ps1 can lift each
# one out of this file and test it with fixtures.

# The signed offset, in seconds, from one 'w32tm /stripchart /dataonly' line:
#   14:10:55, +00.0012345s
# A decimal comma is accepted, because w32tm formats with the current culture.
# Anything else - the 'error: 0x800705B4' line a failed sample prints, the
# banner lines, an empty string - is $null.
function ConvertFrom-StripchartOffset {
    param([string]$Line)
    if (-not $Line) { return $null }
    $m = [regex]::Match($Line, ',\s*(?<sign>[+-])(?<number>\d+(?:[.,]\d+)?)s\s*$')
    if (-not $m.Success) { return $null }
    $number = $m.Groups['number'].Value.Replace(',', '.')
    $seconds = [double]::Parse($number, [Globalization.CultureInfo]::InvariantCulture)
    if ($m.Groups['sign'].Value -eq '-') { $seconds = -$seconds }
    return $seconds
}

# Findings about global git settings. Config is a hashtable of setting name to
# value ('' or $null when unset): core.autocrlf, core.symlinks,
# core.longpaths, credential.helper, core.eol, user.name. Returns
# { Id, Level (info|warn), Message, Fix }.
function Get-GitFinding {
    param(
        [hashtable]$Config,
        [bool]$DeveloperMode
    )
    $findings = @()
    $autocrlf = [string]$Config['core.autocrlf']
    if ($autocrlf -eq 'true') {
        $findings += [pscustomobject]@{
            Id = 'autocrlf'; Level = 'warn'
            Message = 'core.autocrlf=true rewrites line endings in shell scripts and YAML on checkout, and they fail inside Linux containers ("\r: command not found"); this repository pins LF in .gitattributes'
            Fix = 'git config --global core.autocrlf input'
        }
    } elseif (-not $autocrlf) {
        $findings += [pscustomobject]@{
            Id = 'autocrlf-unset'; Level = 'info'
            Message = 'core.autocrlf is not set: git leaves line endings alone unless a repository says otherwise'
            Fix = ''
        }
    }

    if ([string]$Config['core.symlinks'] -ne 'true') {
        if ($DeveloperMode) {
            $findings += [pscustomobject]@{
                Id = 'symlinks'; Level = 'warn'
                Message = 'Developer Mode is on, so git could create real symbolic links, but core.symlinks is off: links in a repository check out as small text files'
                Fix = 'git config --global core.symlinks true (then re-clone, or git checkout the affected files)'
            }
        } else {
            $findings += [pscustomobject]@{
                Id = 'symlinks-off'; Level = 'info'
                Message = 'core.symlinks is off: links in a repository check out as small text files; real links need Developer Mode or elevation'
                Fix = ''
            }
        }
    }

    if (-not [string]$Config['credential.helper']) {
        $findings += [pscustomobject]@{
            Id = 'credential-helper'; Level = 'warn'
            Message = 'no credential.helper: git asks for a password or token on every HTTPS push and pull'
            Fix = 'git config --global credential.helper manager'
        }
    }

    if ([string]$Config['core.eol'] -eq 'crlf') {
        $findings += [pscustomobject]@{
            Id = 'eol-crlf'; Level = 'info'
            Message = 'core.eol=crlf: text files with no .gitattributes rule check out with CRLF'
            Fix = ''
        }
    }

    if (-not [string]$Config['user.name']) {
        $findings += [pscustomobject]@{
            Id = 'user-name'; Level = 'info'
            Message = 'user.name is not set; commits will be refused until it is'
            Fix = ''
        }
    }
    return $findings
}

# --- probes -----------------------------------------------------------------

function Get-RegistryValueSafe {
    param([string]$Path, [string]$Name)
    try {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        return $item.$Name
    } catch {
        Write-Verbose ("registry {0}\{1}: {2}" -f $Path, $Name, $_.Exception.Message)
        return $null
    }
}

function Test-RegistryKey {
    param([string]$Path)
    try {
        return [bool](Test-Path -Path $Path -ErrorAction Stop)
    } catch {
        Write-Verbose ("registry {0}: {1}" -f $Path, $_.Exception.Message)
        return $false
    }
}

# The global value, else the system one, which is where the Git for Windows
# installer writes its choices. Repository-local config is left out on
# purpose: this reports on the machine, not on whatever folder it ran in.
function Get-GitConfigValue {
    param([string]$Key)
    $ErrorActionPreference = 'Continue'
    foreach ($scope in @('--global', '--system')) {
        try {
            $value = & git config $scope --get $Key 2>$null
            if ($LASTEXITCODE -eq 0 -and $value) { return ([string]$value).Trim() }
        } catch {
            Write-Verbose ("git config {0} {1}: {2}" -f $scope, $Key, $_.Exception.Message)
        }
    }
    return ''
}

function Get-NativeLine {
    param([string]$Command, [string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    try {
        return @(& $Command @Arguments 2>$null | ForEach-Object { [string]$_ })
    } catch {
        Write-Verbose ("{0}: {1}" -f $Command, $_.Exception.Message)
        return @()
    }
}

# --- arguments --------------------------------------------------------------
# Ahead of the preflight, as in status.ps1.
if ($ListSections) {
    $SectionOrder | ForEach-Object { Write-Output $_ }
    exit 0
}

$selected = @()
if ($PSBoundParameters.ContainsKey('Only')) {
    foreach ($raw in @($Only | ForEach-Object { $_ -split ',' })) {
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

if ($MaxSkewSeconds -lt 1 -or $MaxSkewSeconds -gt 3600) {
    Write-Err "-MaxSkewSeconds must be between 1 and 3600; got: $MaxSkewSeconds"
    exit 3
}

# --- preflight -------------------------------------------------------------
# Mirrors status.ps1: wrong platform is 2. Windows PowerShell 5.1 does not
# define $IsWindows at all, hence the edition test.
if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    Write-Err 'this script targets Windows'
    exit 2
}

if (-not $script:QuietMode) {
    Write-Host ''
    Write-Host "dev_env_doctor: $Action" -ForegroundColor White
}

$haveGit = [bool](Get-Command git -ErrorAction SilentlyContinue)
$developerMode = ((Get-RegistryValueSafe -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' `
            -Name 'AllowDevelopmentWithoutDevLicense') -eq 1)

# --- paths ------------------------------------------------------------------
if (Test-Want 'paths') {
    Write-Section 'paths'
    $fileSystemKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
    $longPathsOn = $false
    if (-not (Test-RegistryKey -Path $fileSystemKey)) {
        Write-Info 'LongPathsEnabled is not readable here'
    } elseif ((Get-RegistryValueSafe -Path $fileSystemKey -Name 'LongPathsEnabled') -eq 1) {
        $longPathsOn = $true
        Write-Ok 'LongPathsEnabled: paths longer than 260 characters are allowed'
    } else {
        Write-Warn -Message 'LongPathsEnabled is off: paths over 260 characters fail, which deep node_modules and long git checkouts reach' -Hint @(
            'from an elevated prompt: New-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem -Name LongPathsEnabled -Value 1 -PropertyType DWord -Force',
            'Windows PowerShell 5.1 and Explorer honour it only partly; PowerShell 7, git and most toolchains do')
    }
    if ($haveGit) {
        $gitLongPaths = Get-GitConfigValue -Key 'core.longpaths'
        if ($gitLongPaths -eq 'true') {
            Write-Ok 'git core.longpaths=true'
        } elseif ($longPathsOn) {
            Write-Warn -Message 'Windows allows long paths but git does not: core.longpaths is off, so a checkout still fails at 260 characters' -Hint @(
                'git config --global core.longpaths true')
        } else {
            Write-Info 'git core.longpaths is off'
        }
    }
}

# --- git --------------------------------------------------------------------
if (Test-Want 'git') {
    Write-Section 'git'
    if (-not $haveGit) {
        Write-Info 'git is not on PATH'
    } else {
        $gitConfig = @{}
        foreach ($key in @('core.autocrlf', 'core.symlinks', 'core.longpaths', 'credential.helper', 'core.eol', 'user.name')) {
            $gitConfig[$key] = Get-GitConfigValue -Key $key
        }
        foreach ($key in @('core.autocrlf', 'core.symlinks', 'credential.helper', 'core.eol')) {
            $shown = $gitConfig[$key]
            if (-not $shown) { $shown = '(not set)' }
            Write-Host ('  {0,-18} {1}' -f $key, $shown) -ForegroundColor DarkGray
        }
        $gitFindings = @(Get-GitFinding -Config $gitConfig -DeveloperMode $developerMode)
        foreach ($finding in $gitFindings) {
            if ($finding.Level -eq 'warn') {
                Write-Warn -Message $finding.Message -Hint @($finding.Fix)
            } else {
                Write-Info $finding.Message
            }
        }
        if (@($gitFindings | Where-Object { $_.Level -eq 'warn' }).Count -eq 0) {
            Write-Ok 'git settings suit a Windows checkout of cross-platform code'
        }
    }
}

# --- virtualization ---------------------------------------------------------
if (Test-Want 'virtualization') {
    Write-Section 'virtualization'
    $hypervisor = $null
    $firmware = $null
    try {
        $hypervisor = [bool](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).HypervisorPresent
        $firmware = [bool](@(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)[0].VirtualizationFirmwareEnabled)
    } catch {
        Write-Info "virtualization state not readable ($($_.Exception.Message))"
    }
    # With a hypervisor running, Win32_Processor reports firmware
    # virtualization as False - the hypervisor has taken it - so the
    # hypervisor answer comes first.
    if ($hypervisor -eq $true) {
        Write-Ok 'a hypervisor is running: WSL2 and Docker Desktop can start'
    } elseif ($firmware -eq $true) {
        Write-Ok 'virtualization is enabled in firmware'
    } elseif ($hypervisor -eq $false -and $firmware -eq $false) {
        Write-Warn -Message 'no hypervisor and virtualization is off in firmware: WSL2 and Docker Desktop cannot start' -Hint @(
            'enable Intel VT-x or AMD SVM in the UEFI/BIOS setup, then restart')
    }

    foreach ($feature in @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')) {
        try {
            $state = (Get-WindowsOptionalFeature -Online -FeatureName $feature -ErrorAction Stop).State
            Write-Info ('{0}: {1}' -f $feature, $state)
        } catch {
            Write-Info "${feature}: needs elevation to read optional features"
        }
    }
    if ($developerMode) {
        Write-Info 'Developer Mode is on: symbolic links can be created without elevation'
    } else {
        Write-Info 'Developer Mode is off: creating symbolic links needs elevation'
    }
    Write-Info 'distros, disk usage and backups: ..\wsl\wsl_manage.ps1 list'
}

# --- time -------------------------------------------------------------------
if (Test-Want 'time') {
    Write-Section 'time'
    try {
        $timeService = Get-Service -Name 'w32time' -ErrorAction Stop
        $timeStart = [string]$timeService.StartType
        if ($timeStart -eq 'Disabled') {
            Write-Warn -Message 'the Windows Time service is disabled: the clock is never corrected' -Hint @(
                'from an elevated prompt: Get-Service w32time | Set-Service -StartupType Manual; Start-Service w32time')
        } elseif ([string]$timeService.Status -eq 'Running') {
            Write-Ok "Windows Time is running (start type $timeStart)"
        } else {
            # Manual with a trigger start is the default on a machine that is
            # not in a domain: stopped between syncs is normal.
            Write-Info "Windows Time is $($timeService.Status) (start type $timeStart); it starts on demand to sync"
        }
    } catch {
        Write-Info "Windows Time service not readable ($($_.Exception.Message))"
    }

    if (-not $CheckTime) {
        Write-Info 'clock offset not measured; -CheckTime takes one NTP sample from time.windows.com'
    } elseif (-not (Get-Command w32tm -ErrorAction SilentlyContinue)) {
        Write-Info 'w32tm is not available here; clock offset not measured'
    } else {
        $offset = $null
        foreach ($line in (Get-NativeLine -Command 'w32tm' -Arguments @('/stripchart', '/computer:time.windows.com', '/samples:1', '/dataonly'))) {
            $parsed = ConvertFrom-StripchartOffset -Line $line
            if ($null -ne $parsed) { $offset = $parsed }
        }
        if ($null -eq $offset) {
            Write-Info 'could not measure skew (no answer from time.windows.com)'
        } elseif ([math]::Abs($offset) -gt $MaxSkewSeconds) {
            Write-Warn -Message ('the clock is {0:N1} s off time.windows.com: Kerberos, AWS SigV4 and JWT validation start failing past a few seconds' -f $offset) -Hint @(
                'from an elevated prompt: w32tm /resync')
        } else {
            Write-Ok ('the clock is {0:N3} s off time.windows.com (limit {1} s)' -f $offset, $MaxSkewSeconds)
        }
    }
}

# --- shell ------------------------------------------------------------------
if (Test-Want 'shell') {
    Write-Section 'shell'
    Write-Info ('running PowerShell {0} ({1})' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
    $pwshCommand = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pwshCommand) {
        Write-Ok "pwsh is on PATH: $($pwshCommand.Source)"
    } else {
        Write-Info 'pwsh (PowerShell 7) is not on PATH; winget install Microsoft.PowerShell adds it'
    }

    $homeVar = $env:HOME
    $profileDir = $env:USERPROFILE
    if (-not $homeVar) {
        Write-Ok 'HOME is not set, so tools fall back to USERPROFILE'
    } elseif ($profileDir -and ($homeVar.TrimEnd('\', '/') -ne $profileDir.TrimEnd('\', '/'))) {
        Write-Warn -Message ('HOME ({0}) differs from USERPROFILE ({1}): Git Bash, ssh and git may each read a different home' -f $homeVar, $profileDir) -Hint @(
            'remove the HOME user variable unless something needs it: System Properties > Environment Variables')
    } else {
        Write-Ok 'HOME matches USERPROFILE'
    }

    if (Get-Module -ListAvailable -Name PSReadLine) {
        Write-Info 'PSReadLine is available'
    } else {
        Write-Info 'PSReadLine is not installed'
    }
}

# --- containers -------------------------------------------------------------
if (Test-Want 'containers') {
    Write-Section 'containers'
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Info 'docker is not on PATH'
    } else {
        # 'docker context show' reads the CLI's own config and never talks to
        # the daemon, so it cannot hang while Docker Desktop is starting the
        # way 'docker info' can.
        $context = @(Get-NativeLine -Command 'docker' -Arguments @('context', 'show')) | Select-Object -First 1
        if ($context) {
            Write-Ok "docker CLI, context: $context"
        } else {
            Write-Info 'docker CLI found; the current context could not be read'
        }
    }
    if ($env:DOCKER_HOST) {
        Write-Info "DOCKER_HOST is set ($env:DOCKER_HOST); it overrides the docker context"
    }
    try {
        $dockerService = Get-Service -Name 'com.docker.service' -ErrorAction Stop
        Write-Info "Docker Desktop service: $($dockerService.Status)"
    } catch {
        Write-Info 'Docker Desktop service not installed'
    }
}

# --- summary ---------------------------------------------------------------
$warnings = $script:Warnings
Write-Host ''
if ($warnings -gt 0) {
    Write-Warn ('{0} warning(s) above - none of them change the exit code' -f $warnings)
} else {
    Write-Ok 'nothing worth flagging'
}
exit 0
