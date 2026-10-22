<#
.SYNOPSIS
    Read-only check of the OpenSSH client setup for this Windows account.

.DESCRIPTION
    The Windows counterpart of linux/ssh_client_doctor.sh. The failures are
    different on Windows, and more confusing:

      - Windows OpenSSH refuses a private key unless only its owner, SYSTEM
        and Administrators hold access to it, and says only
        "UNPROTECTED PRIVATE KEY FILE". A key copied from another machine, or
        created under a folder that grants BUILTIN\Users read, trips it.
      - The ssh-agent service ships Disabled, so ssh-add answers
        "Error connecting to agent" until somebody enables it.
      - Git for Windows bundles its own ssh.exe next to the one in
        C:\Windows\System32\OpenSSH. Keys loaded into the Windows agent are
        invisible to Git's ssh, so 'ssh -T git@host' works and 'git fetch'
        asks for a passphrase or fails.

    Groups, in order: directory, agent, clients, keys, config. Each finding is
    [pass], [warn], [FAIL], [skip] or [info]; every [warn] and [FAIL] is
    followed by the command that fixes it. Those commands are printed, never
    run.

    What it reads: the directory listing of -SshDir, the FIRST line of each
    file there (enough to tell a private key from anything else - the key
    body is never read and nothing from a key is ever printed), each key's
    access list, the config file's IdentityFile lines, the ssh-agent
    service's state, and 'ssh-add -l', of which only the line count is used.

    What it does not do: parse 'ssh -G' or follow Include lines. For the
    effective configuration of one host, use git/git_ssh_doctor.py, which asks
    OpenSSH itself.

    -FailOn is checked before the Windows preflight, so a bad value is a usage
    error on any OS. There is no -DryRun because there is nothing to preview;
    -Action takes one value, 'report', which is the read-only default the
    contract checks look for.

.PARAMETER SshDir
    The directory to inspect. Default: .ssh under the user profile.

.PARAMETER FailOn
    'fail' (default) exits 1 on any [FAIL]; 'warn' exits 1 on any [warn] or
    [FAIL].

.EXAMPLE
    .\ssh_client_doctor.ps1
    .\ssh_client_doctor.ps1 -FailOn warn
    .\ssh_client_doctor.ps1 -SshDir D:\keys\.ssh -Quiet

.NOTES
    Exit codes, matching linux/ssh_client_doctor.sh:
      0  no findings at or above -FailOn
      1  one or more findings at or above -FailOn
      2  not Windows, or -SshDir is not a directory
      3  bad arguments
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('report')]
    [string]$Action = 'report',

    [string]$SshDir = '',

    # Validated by hand below rather than with ValidateSet: a binding failure
    # under 'pwsh -File' exits 1, and a bad value here is a usage error (3).
    [string]$FailOn = 'fail',

    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$script:QuietMode = [bool]$Quiet
$script:PassCount = 0
$script:WarnCount = 0
$script:FailCount = 0
$script:SkipCount = 0

# The grammar of linux/ssh_client_doctor.sh: two-space indent, a six-wide
# verdict, and the fix on a dimmed line under it, nine spaces in.
function Write-Pass {
    param([string]$Message)
    $script:PassCount++
    if (-not $script:QuietMode) { Write-Host "  [pass] $Message" -ForegroundColor Green }
}
function Write-Warn {
    param([string]$Message, [string[]]$Hint = @())
    $script:WarnCount++
    Write-Host "  [warn] $Message" -ForegroundColor Yellow
    foreach ($line in $Hint) { Write-Host "         $line" -ForegroundColor DarkGray }
}
function Write-Fail {
    param([string]$Message, [string[]]$Hint = @())
    $script:FailCount++
    Write-Host "  [FAIL] $Message" -ForegroundColor Red
    foreach ($line in $Hint) { Write-Host "         $line" -ForegroundColor DarkGray }
}
function Write-Skip {
    param([string]$Message)
    $script:SkipCount++
    if (-not $script:QuietMode) { Write-Host "  [skip] $Message" -ForegroundColor DarkGray }
}
function Write-Info {
    param([string]$Message)
    if (-not $script:QuietMode) { Write-Host "  [info] $Message" -ForegroundColor Blue }
}
function Write-Err  { param([string]$Message) Write-Host "[err ] $Message" -ForegroundColor Red }
function Write-Group { param([string]$Name) Write-Host ''; Write-Host "== $Name ==" -ForegroundColor White }

# --- pure helpers -----------------------------------------------------------
# Plain data in, plain data out, so windows/tests/contract.ps1 can lift each
# one out of this file and test it with fixtures. No script-scope variables,
# no calls to the other helpers.

# Grades one access list the way Windows OpenSSH does. Entries are
# { Identity, Sid, Type, Rights }; Sid may be empty when it could not be
# resolved. An Allow entry for anyone but the current user, SYSTEM and
# Administrators is an offender. Deny entries take access away and are
# ignored. SIDs are compared when present because the names are localised
# ('VORDEFINIERT\Administratoren'); names are the fallback.
#
# With -WriteOnly (the config file) only an Allow entry carrying write,
# modify, delete, permission or ownership rights counts: others may read it.
#
# -Owner is { Identity, Sid } of the file's owner. Win32-OpenSSH refuses a
# file ("Bad owner or permissions") whose owner is not the current user,
# SYSTEM or Administrators, whatever its access list says, so such an owner
# grades 'fail' and is returned as WrongOwner. Without -Owner (it could not be
# read) the owner is not judged.
#
# An empty list grades as 'skip': there is nothing to read, which on Windows
# means the ACL could not be read, and a verdict without evidence is not one.
function Test-KeyAcl {
    param(
        [object[]]$Entries,
        [string]$CurrentUser,
        [string]$CurrentUserSid = '',
        [switch]$WriteOnly,
        [object]$Owner = $null
    )
    if (-not $Entries -or @($Entries).Count -eq 0) {
        return [pscustomobject]@{ Level = 'skip'; Offenders = @(); WrongOwner = '' }
    }

    $trustedSids = @('S-1-5-18', 'S-1-5-32-544')
    if ($CurrentUserSid) { $trustedSids += $CurrentUserSid }
    $trustedNames = @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')
    $userLeaf = ($CurrentUser -split '\\')[-1]

    # The current user, written either way round: 'DOMAIN\alice' against
    # 'alice' matches on the user part. Two qualified names must agree in
    # full, because LAPTOP\alice and CORP\alice are different accounts.
    $isCurrentUser = {
        param([string]$Name)
        if ($Name -match '\\' -and $CurrentUser -match '\\') { return ($Name -eq $CurrentUser) }
        return (($Name -split '\\')[-1] -eq $userLeaf)
    }

    $wrongOwner = ''
    if ($null -ne $Owner -and [string]$Owner.Identity) {
        $ownerName = [string]$Owner.Identity
        $ownerSid = [string]$Owner.Sid
        $ownerOk = $false
        if ($ownerSid -and $trustedSids -contains $ownerSid) { $ownerOk = $true }
        elseif ($trustedNames -contains $ownerName) { $ownerOk = $true }
        elseif (& $isCurrentUser $ownerName) { $ownerOk = $true }
        if (-not $ownerOk) { $wrongOwner = $ownerName }
    }

    $offenders = @()
    foreach ($entry in $Entries) {
        if ([string]$entry.Type -ne 'Allow') { continue }
        $identity = [string]$entry.Identity
        $sid = [string]$entry.Sid
        if ($sid -and $trustedSids -contains $sid) { continue }
        # -WriteOnly is the config file: Win32-OpenSSH lets others read it and
        # refuses it only when someone else can change it.
        if ($WriteOnly) {
            $writeTokens = @('FullControl', 'Modify', 'Write', 'WriteData', 'AppendData',
                'CreateFiles', 'CreateDirectories', 'WriteAttributes', 'WriteExtendedAttributes',
                'Delete', 'DeleteSubdirectoriesAndFiles', 'ChangePermissions', 'TakeOwnership')
            $rightTokens = @(([string]$entry.Rights) -split '\s*,\s*')
            if (-not ($rightTokens | Where-Object { $writeTokens -contains $_ })) { continue }
        }
        if ($trustedNames -contains $identity) { continue }

        if (& $isCurrentUser $identity) { continue }

        if ($offenders -notcontains $identity) { $offenders += $identity }
    }

    $level = 'pass'
    if ($offenders.Count -gt 0 -or $wrongOwner) { $level = 'fail' }
    return [pscustomobject]@{ Level = $level; Offenders = $offenders; WrongOwner = $wrongOwner }
}

# IdentityFile lines from an ssh_config, as two lists:
#   Resolvable   { Line, Raw, Path } - Path is the file ssh would open
#   Unresolvable { Line, Raw }       - a token or variable only ssh can expand
# Matches 'IdentityFile x' and 'IdentityFile=x' in any case, skips comments,
# strips quotes (a path with spaces), expands '~' and '%d' to -HomeDir, and
# ignores 'none'. A relative path is unresolvable too: it depends on where ssh
# is started from.
function Get-IdentityFileReference {
    param(
        [string[]]$Lines,
        [string]$HomeDir
    )
    $resolvable = @()
    $unresolvable = @()
    $number = 0
    foreach ($raw in $Lines) {
        $number++
        if ($null -eq $raw) { continue }
        $text = $raw.Trim()
        if (-not $text -or $text.StartsWith('#')) { continue }
        $m = [regex]::Match($text, '^(?i)IdentityFile(\s*=\s*|\s+)(?<value>.+)$')
        if (-not $m.Success) { continue }
        $value = $m.Groups['value'].Value.Trim()
        if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        if ($value -eq 'none') { continue }

        $expanded = $value -replace '%d', $HomeDir.Replace('$', '$$')
        if ($expanded -eq '~') {
            $expanded = $HomeDir
        } elseif ($expanded.StartsWith('~/') -or $expanded.StartsWith('~\')) {
            $expanded = $HomeDir.TrimEnd('\', '/') + $expanded.Substring(1)
        }

        $rooted = $expanded -match '^([A-Za-z]:[\\/]|[\\/])'
        if ($expanded -match '%' -or $expanded -match '\$\{' -or -not $rooted) {
            $unresolvable += [pscustomobject]@{ Line = $number; Raw = $raw.Trim() }
            continue
        }
        $resolvable += [pscustomobject]@{ Line = $number; Raw = $raw.Trim(); Path = $expanded }
    }
    return [pscustomobject]@{ Resolvable = $resolvable; Unresolvable = $unresolvable }
}

# Which ssh clients exist and whether git will use the one the Windows agent
# serves. Clients is a list of ssh.exe paths in PATH order (git's bundled one
# appended when git is installed). Returns { Id, Level, Message, Fix }.
function Get-SshClientFinding {
    param(
        [string[]]$Clients,
        [bool]$AgentRunning,
        [string]$GitSshCommand,
        [string]$GitSshEnv,
        [string]$GitSshCommandEnv
    )
    $findings = @()
    $kinds = @()
    foreach ($path in $Clients) {
        $kind = 'other'
        if ($path -match '\\Git\\') { $kind = 'git-for-windows' }
        elseif ($path -match '\\System32\\OpenSSH\\') { $kind = 'windows-openssh' }
        $kinds += $kind
    }
    if ($kinds.Count -eq 0) {
        return @([pscustomobject]@{ Id = 'no-client'; Level = 'skip'; Message = 'no ssh.exe found'; Fix = '' })
    }

    $findings += [pscustomobject]@{
        Id = 'first-client'; Level = 'info'
        Message = ('ssh resolves to {0} ({1})' -f $Clients[0], $kinds[0]); Fix = ''
    }
    # What git runs, by git's own precedence: GIT_SSH_COMMAND, then
    # core.sshCommand, then GIT_SSH (read only when neither of the others is
    # set). Only the winning one counts.
    $source = ''
    $chosen = ''
    $pinned = ''
    if ($GitSshCommandEnv) { $source = 'GIT_SSH_COMMAND'; $chosen = $GitSshCommandEnv }
    elseif ($GitSshCommand) { $source = 'core.sshCommand'; $chosen = $GitSshCommand }
    elseif ($GitSshEnv) { $source = 'GIT_SSH'; $chosen = $GitSshEnv }

    if ($source) {
        if ($source -eq 'core.sshCommand') {
            $findings += [pscustomobject]@{
                Id = 'git-ssh-command'; Level = 'info'
                Message = "git uses core.sshCommand: $chosen"; Fix = ''
            }
        } else {
            $findings += [pscustomobject]@{
                Id = 'git-ssh-env'; Level = 'info'
                Message = "git uses ${source}: $chosen"; Fix = ''
            }
        }
        # Name the client it points at: its first word, quotes and forward
        # slashes allowed. Only Git's bundled ssh and the Windows OpenSSH
        # client are known; anything else (a wrapper, plink) is left alone.
        $pinned = ($chosen.Trim() -replace '/', '\')
        if ($pinned -match '^"([^"]*)"') { $pinned = $Matches[1] }
        elseif ($pinned -match '^(.*?\\ssh(\.exe)?)(\s|$)') { $pinned = $Matches[1] }
        if ($AgentRunning -and $pinned -match '\\(portable)?git\\(.+\\)?(usr\\bin|mingw(32|64)\\bin)\\ssh(\.exe)?$') {
            # GIT_SSH_COMMAND outranks core.sshCommand, which outranks
            # GIT_SSH, so setting the config changes nothing while a
            # higher one stays.
            $pinFix = 'git config --global core.sshCommand "C:/Windows/System32/OpenSSH/ssh.exe"'
            if ($source -ne 'core.sshCommand') {
                $pinFix = "point $source at C:/Windows/System32/OpenSSH/ssh.exe, or remove it"
            }
            $findings += [pscustomobject]@{
                Id = 'git-ssh-pinned-git'; Level = 'warn'
                Message = "$source pins git to Git's own ssh ($pinned), which cannot see the keys in the running Windows ssh-agent"
                Fix = $pinFix
            }
        }
    } elseif ($AgentRunning -and $kinds -contains 'git-for-windows' -and $kinds -contains 'windows-openssh') {
        $findings += [pscustomobject]@{
            Id = 'two-clients'; Level = 'warn'
            Message = "git will use its own ssh, which cannot see the keys in the Windows ssh-agent"
            Fix = 'git config --global core.sshCommand "C:/Windows/System32/OpenSSH/ssh.exe"'
        }
    }

    # "Git and ssh agree" is a claim about the Windows agent, so it is made
    # only when the client git will run is positively Windows OpenSSH: the
    # pinned one, or, with nothing pinned, the only client there is. Anything
    # else (plink, a wrapper script, a bare 'ssh' with options, Git's own ssh
    # with no pin) is not verified, and says so instead of passing.
    if ($AgentRunning -and @($findings | Where-Object { $_.Level -eq 'warn' }).Count -eq 0) {
        $windowsSsh = '\\System32\\OpenSSH\\ssh(\.exe)?$'
        $client = ''
        $verified = $false
        if ($source) {
            $client = $pinned
            $verified = ($pinned -match $windowsSsh)
        } else {
            $client = $Clients[0]
            $verified = (@($kinds | Where-Object { $_ -ne 'windows-openssh' }).Count -eq 0)
        }
        if ($verified) {
            $findings += [pscustomobject]@{
                Id = 'agent-client'; Level = 'pass'
                Message = 'git and ssh agree on which client the agent serves'; Fix = ''
            }
        } else {
            $findings += [pscustomobject]@{
                Id = 'agent-client-unverified'; Level = 'info'
                Message = "agent use not verified for $client"; Fix = ''
            }
        }
    }
    return $findings
}

# --- probes -----------------------------------------------------------------

# Line 1 only. A private key's armour says what it is; nothing past it is
# needed, so nothing past it is read.
function Read-FirstLine {
    param([string]$Path)
    $reader = $null
    try {
        $reader = [IO.File]::OpenText($Path)
        return $reader.ReadLine()
    } catch {
        Write-Verbose ("{0}: {1}" -f $Path, $_.Exception.Message)
        return $null
    } finally {
        if ($reader) { $reader.Dispose() }
    }
}

# Get-Acl turned into plain { Identity, Sid, Type, Rights } objects, or $null
# with the reason when it cannot be read (Get-Acl does not exist off Windows).
function Get-AclEntry {
    param([string]$Path)
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $rows = @()
    foreach ($rule in @($acl.Access)) {
        if ($null -eq $rule) { continue }
        $sid = ''
        try {
            $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
        } catch {
            Write-Verbose $_.Exception.Message
        }
        $rows += [pscustomobject]@{
            Identity = [string]$rule.IdentityReference.Value
            Sid      = $sid
            Type     = [string]$rule.AccessControlType
            Rights   = [string]$rule.FileSystemRights
        }
    }
    return $rows
}

# The owner of a file as { Identity, Sid }, or $null when it cannot be read.
function Get-AclOwner {
    param([string]$Path)
    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $name = [string]$acl.Owner
        if (-not $name) { return $null }
        $sid = ''
        try {
            $sid = (New-Object System.Security.Principal.NTAccount -ArgumentList $name).Translate([System.Security.Principal.SecurityIdentifier]).Value
        } catch {
            Write-Verbose $_.Exception.Message
        }
        return [pscustomobject]@{ Identity = $name; Sid = $sid }
    } catch {
        Write-Verbose ("{0}: {1}" -f $Path, $_.Exception.Message)
        return $null
    }
}

# The global value, else the system one (where the Git for Windows installer
# writes its choices), so a system-wide pin is graded too.
function Get-GitConfigValue {
    param([string]$Key)
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return '' }
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

# --- arguments --------------------------------------------------------------
# Ahead of the preflight, as in every script here.
if ($FailOn -notin @('fail', 'warn')) {
    Write-Err "-FailOn must be warn or fail, got: $FailOn"
    exit 3
}
$failOnLevel = $FailOn.ToLowerInvariant()

# --- preflight -------------------------------------------------------------
# Mirrors status.ps1: wrong platform is 2. Windows PowerShell 5.1 does not
# define $IsWindows at all, hence the edition test.
if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    Write-Err 'this script targets Windows'
    exit 2
}

$homeDir = $env:USERPROFILE
if (-not $homeDir) { $homeDir = $HOME }
if (-not $SshDir) { $SshDir = Join-Path $homeDir '.ssh' }

if (-not $script:QuietMode) {
    Write-Host ''
    Write-Host "ssh_client_doctor: $Action $SshDir" -ForegroundColor White
}

function Write-Summary {
    Write-Host ''
    Write-Host '== summary ==' -ForegroundColor White
    Write-Host ('  {0} pass  {1} warn  {2} fail  {3} skip' -f $script:PassCount, $script:WarnCount, $script:FailCount, $script:SkipCount)
}

# --- directory --------------------------------------------------------------
Write-Group 'directory'
if (-not (Test-Path -LiteralPath $SshDir)) {
    # No ~/.ssh is an account that has never used ssh, not a fault.
    Write-Skip "$SshDir does not exist (no client keys on this account)"
    Write-Summary
    exit 0
}
if (-not (Test-Path -LiteralPath $SshDir -PathType Container)) {
    Write-Err "$SshDir is not a directory"
    exit 2
}
Write-Pass "$SshDir exists"

# --- agent ------------------------------------------------------------------
Write-Group 'agent'
$agentRunning = $false
$service = $null
try {
    $service = Get-Service -Name 'ssh-agent' -ErrorAction Stop
} catch {
    Write-Skip "ssh-agent service not found - is the OpenSSH client feature installed? ($($_.Exception.Message))"
}
if ($service) {
    $startType = [string]$service.StartType
    if ([string]$service.Status -eq 'Running') {
        $agentRunning = $true
        Write-Pass "ssh-agent is running (start type $startType)"
    } elseif ($startType -eq 'Disabled') {
        Write-Warn -Message 'ssh-agent is disabled: ssh-add says "Error connecting to agent" and nothing stays loaded' -Hint @(
            'from an elevated prompt: Get-Service ssh-agent | Set-Service -StartupType Manual; Start-Service ssh-agent')
    } else {
        Write-Warn -Message "ssh-agent is not running (start type $startType)" -Hint @('Start-Service ssh-agent')
    }
}

if ($agentRunning) {
    $sshAdd = $null
    if ($env:WINDIR) {
        $candidate = Join-Path $env:WINDIR 'System32\OpenSSH\ssh-add.exe'
        if (Test-Path -LiteralPath $candidate) { $sshAdd = $candidate }
    }
    if (-not $sshAdd) {
        $onPath = Get-Command ssh-add -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($onPath) { $sshAdd = $onPath.Source }
    }
    if (-not $sshAdd) {
        Write-Skip 'ssh-add not found; cannot ask the agent what it holds'
    } else {
        # Only the number of lines is used. The listing holds fingerprints and
        # comments, and none of it is printed.
        $listing = $null
        $addExit = -1
        $ErrorActionPreference = 'Continue'
        try {
            $listing = & $sshAdd -l 2>$null
            $addExit = $LASTEXITCODE
        } catch {
            Write-Verbose $_.Exception.Message
        } finally {
            $ErrorActionPreference = 'Stop'
        }
        if ($addExit -eq 0) {
            Write-Pass ('the agent holds {0} key(s)' -f @($listing | Where-Object { $_ }).Count)
        } elseif ($addExit -eq 1) {
            Write-Info 'the agent holds no keys; ssh-add <key> loads one'
        } elseif ($addExit -eq 2) {
            Write-Warn -Message 'ssh-add cannot reach the agent' -Hint @('a stale SSH_AUTH_SOCK from Git Bash points ssh-add at a socket that is gone; unset it in this shell')
        } else {
            Write-Info "ssh-add -l exited $addExit"
        }
    }
}

# --- clients ----------------------------------------------------------------
Write-Group 'clients'
$clientPaths = @(Get-Command ssh -All -CommandType Application -ErrorAction SilentlyContinue |
    ForEach-Object { $_.Source } | Select-Object -Unique)
# Git's own ssh is usually NOT on PATH (only Git\cmd is), and it is still the
# one git uses. Find it from git.exe so the comparison sees it.
$gitCommand = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($gitCommand -and $gitCommand.Source -match '\\Git\\') {
    $gitRoot = Split-Path -Parent (Split-Path -Parent $gitCommand.Source)
    $bundled = Join-Path $gitRoot 'usr\bin\ssh.exe'
    if ((Test-Path -LiteralPath $bundled) -and $clientPaths -notcontains $bundled) { $clientPaths += $bundled }
}
$gitSshEnv = [Environment]::GetEnvironmentVariable('GIT_SSH')
$gitSshCommandEnv = [Environment]::GetEnvironmentVariable('GIT_SSH_COMMAND')
$clientFindings = @(Get-SshClientFinding -Clients $clientPaths -AgentRunning $agentRunning `
        -GitSshCommand (Get-GitConfigValue -Key 'core.sshCommand') -GitSshEnv ([string]$gitSshEnv) `
        -GitSshCommandEnv ([string]$gitSshCommandEnv))
foreach ($finding in $clientFindings) {
    switch ($finding.Level) {
        'warn' { Write-Warn -Message $finding.Message -Hint @($finding.Fix) }
        'skip' { Write-Skip $finding.Message }
        'pass' { Write-Pass $finding.Message }
        default { Write-Info $finding.Message }
    }
}

# --- keys -------------------------------------------------------------------
Write-Group 'keys'
$currentUser = $env:USERNAME
if ($env:USERDOMAIN -and $currentUser) { $currentUser = '{0}\{1}' -f $env:USERDOMAIN, $currentUser }
$currentSid = ''
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $currentUser = $identity.Name
    $currentSid = $identity.User.Value
} catch {
    Write-Verbose $_.Exception.Message
}
if (-not $currentUser) { $currentUser = [Environment]::UserName }

# Private keys by their armour, plus the config file, which Windows OpenSSH
# checks too ("Bad owner or permissions") but lets others read.
$aclSubjects = @()
foreach ($file in @(Get-ChildItem -LiteralPath $SshDir -File -Force -ErrorAction SilentlyContinue)) {
    if ($file.Name -eq 'config') { $aclSubjects += $file; continue }
    if ($file.Extension -eq '.pub' -or $file.Length -gt 64KB -or $file.Length -eq 0) { continue }
    $first = Read-FirstLine -Path $file.FullName
    if ($first -and $first.StartsWith('-----BEGIN ') -and $first.TrimEnd().EndsWith('PRIVATE KEY-----')) {
        $aclSubjects += $file
    }
}
if (@($aclSubjects | Where-Object { $_.Name -ne 'config' }).Count -eq 0) {
    Write-Info "no private key found in $SshDir"
}
foreach ($file in $aclSubjects) {
    $entries = $null
    try {
        $entries = @(Get-AclEntry -Path $file.FullName)
    } catch {
        Write-Skip ('{0}: access list not readable ({1})' -f $file.Name, $_.Exception.Message)
        continue
    }
    $isConfig = ($file.Name -eq 'config')
    $owner = Get-AclOwner -Path $file.FullName
    $verdict = Test-KeyAcl -Entries $entries -CurrentUser $currentUser -CurrentUserSid $currentSid -WriteOnly:$isConfig -Owner $owner
    switch ($verdict.Level) {
        'pass' {
            if ($isConfig) { Write-Pass ('{0}: nobody but you, SYSTEM and Administrators can change it' -f $file.Name) }
            else { Write-Pass ('{0}: only you, SYSTEM and Administrators have access' -f $file.Name) }
        }
        'skip' { Write-Skip ('{0}: no access entries readable' -f $file.Name) }
        default {
            $hint = @()
            if ($verdict.WrongOwner) {
                $hint += ('icacls "{0}" /setowner "{1}"' -f $file.FullName, $currentUser)
            }
            $hint += @(
                ('icacls "{0}" /inheritance:r' -f $file.FullName),
                ('icacls "{0}" /grant:r "{1}:(F)"' -f $file.FullName, $currentUser))
            foreach ($offender in $verdict.Offenders) {
                $hint += ('icacls "{0}" /remove "{1}"' -f $file.FullName, $offender)
            }
            if (@($verdict.Offenders).Count -eq 0) {
                Write-Fail -Message ('{0}: owned by {1}, not you, SYSTEM or Administrators; Windows OpenSSH refuses it (bad owner)' -f $file.Name, $verdict.WrongOwner) -Hint $hint
            } elseif ($verdict.WrongOwner) {
                Write-Fail -Message ('{0}: owned by {1} (not you, SYSTEM or Administrators) and also accessible by {2}; Windows OpenSSH refuses it' -f $file.Name, $verdict.WrongOwner, ($verdict.Offenders -join ', ')) -Hint $hint
            } elseif ($isConfig) {
                Write-Fail -Message ('{0}: also writable by {1}; Windows OpenSSH refuses it (bad permissions)' -f $file.Name, ($verdict.Offenders -join ', ')) -Hint $hint
            } else {
                Write-Fail -Message ('{0}: also readable by {1}; Windows OpenSSH refuses it as UNPROTECTED' -f $file.Name, ($verdict.Offenders -join ', ')) -Hint $hint
            }
        }
    }
}

# --- config -----------------------------------------------------------------
Write-Group 'config'
$configPath = Join-Path $SshDir 'config'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    Write-Skip 'no config file'
} else {
    $configLines = @()
    try {
        $configLines = [IO.File]::ReadAllLines($configPath)
    } catch {
        Write-Skip "config not readable ($($_.Exception.Message))"
    }
    $references = Get-IdentityFileReference -Lines $configLines -HomeDir $homeDir
    foreach ($ref in $references.Resolvable) {
        if (Test-Path -LiteralPath $ref.Path -PathType Leaf) {
            Write-Pass ('IdentityFile {0} (line {1})' -f $ref.Path, $ref.Line)
        } else {
            Write-Warn -Message ('IdentityFile points at a missing file: {0} (config line {1})' -f $ref.Path, $ref.Line) -Hint @(
                'ssh skips a missing key with no useful error; fix the path or remove the line')
        }
    }
    foreach ($ref in $references.Unresolvable) {
        Write-Info ('config line {0}: {1} - only ssh can expand this; ssh -G <host> shows the result' -f $ref.Line, $ref.Raw)
    }
    if (@($references.Resolvable).Count + @($references.Unresolvable).Count -eq 0) {
        Write-Info 'config names no IdentityFile; ssh offers its default key names and whatever the agent holds'
    }
}

Write-Summary

if ($failOnLevel -eq 'warn' -and ($script:WarnCount + $script:FailCount) -gt 0) { exit 1 }
if ($script:FailCount -gt 0) { exit 1 }
exit 0
