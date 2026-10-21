<#
.SYNOPSIS
    Read-only Windows security audit that prints the fix for each finding.

.DESCRIPTION
    The Windows counterpart of linux/hardening_audit.sh and
    macos-initial-setup/hardening_audit.sh: the same verdicts, the same
    -FailOn and the same exit codes, so one piece of automation can run all
    three. Where workstation_doctor.ps1 describes the machine, this grades it,
    and prints under every [warn] and [FAIL] the PowerShell command a person
    would run, elevated, to fix it.

    It never runs those commands. The "insecure" answer is the right one on
    some hosts - RDP on a jump box, autologon on a kiosk or a build agent - and
    a script that hardened by itself would be wrong often enough to be
    dangerous. That is the rule the Bash audits state, and this keeps it.

    Groups and their check ids, in order:

      network   fw-domain fw-private fw-public smb1 llmnr
      remote    rdp-enabled rdp-nla winrm-trustedhosts sshd-password
                sshd-empty-password
      accounts  uac-lua uac-prompt autologon autologon-password
                guest-enabled local-admins-broad
      boot      secureboot tpm lsa-ppl vbs
      defender  defender-rtp defender-tamper defender-sigs defender-pua
                defender-netprot
      logging   ps-scriptblock
      updates   hotfix-age reboot-pending

    Secrets are not read. For autologon it checks whether a DefaultPassword
    value EXISTS under Winlogon and never reads its data. It reads no
    credential store, no LSA secret, no Wi-Fi key. Accounts are named only
    when a broad principal (Everyone, Authenticated Users, Users) sits in the
    local Administrators group, which is found by its SID so a localised
    Windows is read correctly.

    Several probes need elevation. Unelevated, those checks are a [skip]
    saying so, never a failure, and the banner says which mode it ran in.

    -ListGroups, -Only and -FailOn are checked before the Windows preflight.
    There is no -DryRun because there is nothing to preview; -Action takes one
    value, 'report', which is the read-only default the contract checks look
    for.

.PARAMETER Only
    Comma-separated group ids (see -ListGroups). Unknown ids exit 3; a list
    that selects nothing exits 4.

.PARAMETER FailOn
    'fail' (default) exits 1 on any [FAIL]; 'warn' exits 1 on any [warn] or
    [FAIL].

.EXAMPLE
    .\hardening_audit.ps1
    .\hardening_audit.ps1 -ListGroups
    .\hardening_audit.ps1 -Only network,remote
    .\hardening_audit.ps1 -FailOn warn -Quiet

.NOTES
    Exit codes, matching linux/hardening_audit.sh:
      0  no findings at or above -FailOn
      1  one or more findings at or above -FailOn
      2  not Windows
      3  bad arguments
      4  -Only selected nothing
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('report')]
    [string]$Action = 'report',

    # A list, split on commas in the body, for the reason stay_fresh.ps1 gives.
    [string[]]$Only = @(),

    [switch]$ListGroups,

    # Validated by hand below: a binding failure under 'pwsh -File' exits 1,
    # and a bad value here is a usage error (3).
    [string]$FailOn = 'fail',

    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$script:QuietMode = [bool]$Quiet
$script:Counts = @{ pass = 0; warn = 0; fail = 0; skip = 0 }

$GroupOrder = @('network', 'remote', 'accounts', 'boot', 'defender', 'logging', 'updates')

function Write-Err  { param([string]$Message) Write-Host "[err ] $Message" -ForegroundColor Red }
function Write-Info {
    param([string]$Message)
    if (-not $script:QuietMode) { Write-Host "[info] $Message" -ForegroundColor Blue }
}

# --- pure helpers -----------------------------------------------------------
# The seam that ETC_SSH gives linux/hardening_audit.sh: every probe result is
# collected once into a hashtable of plain values by Get-AuditFact, and these
# functions turn that hashtable into findings and an exit code. Nothing in
# them touches the machine, so windows/tests/contract.ps1 lifts them out and
# grades fixtures - including one bad fixture per check id.

# Every check id with its group, in report order.
function Get-AuditCheckId {
    $table = @(
        @('network', 'fw-domain'), @('network', 'fw-private'), @('network', 'fw-public'),
        @('network', 'smb1'), @('network', 'llmnr'),
        @('remote', 'rdp-enabled'), @('remote', 'rdp-nla'), @('remote', 'winrm-trustedhosts'),
        @('remote', 'sshd-password'), @('remote', 'sshd-empty-password'),
        @('accounts', 'uac-lua'), @('accounts', 'uac-prompt'), @('accounts', 'autologon'),
        @('accounts', 'autologon-password'), @('accounts', 'guest-enabled'), @('accounts', 'local-admins-broad'),
        @('boot', 'secureboot'), @('boot', 'tpm'), @('boot', 'lsa-ppl'), @('boot', 'vbs'),
        @('defender', 'defender-rtp'), @('defender', 'defender-tamper'), @('defender', 'defender-sigs'),
        @('defender', 'defender-pua'), @('defender', 'defender-netprot'),
        @('logging', 'ps-scriptblock'),
        @('updates', 'hotfix-age'), @('updates', 'reboot-pending')
    )
    foreach ($row in $table) { [pscustomobject]@{ Group = $row[0]; Id = $row[1] } }
}

# sshd_config keywords, lower-cased, to their value. The first occurrence
# wins, as it does for sshd, and reading stops at the first Match block,
# because what follows applies only to some connections.
function Get-SshdSetting {
    param([string[]]$Lines)
    $settings = @{}
    foreach ($raw in $Lines) {
        if ($null -eq $raw) { continue }
        $text = $raw.Trim()
        if (-not $text -or $text.StartsWith('#')) { continue }
        $m = [regex]::Match($text, '^(?<key>[A-Za-z]+)(\s*=\s*|\s+)(?<value>.*)$')
        if (-not $m.Success) { continue }
        $key = $m.Groups['key'].Value.ToLowerInvariant()
        if ($key -eq 'match') { break }
        if (-not $settings.ContainsKey($key)) { $settings[$key] = $m.Groups['value'].Value.Trim() }
    }
    return $settings
}

# The verdict for every check, from the facts. A fact is $null when it could
# not be read, and the check is then a skip - "needs elevation" when the run
# was not elevated - never a pass. Registry facts may also be the string
# 'absent': the machine was read and the value is not there, which is an
# answer, often the insecure default. Returns { Group, Id, Level, Message, Fix }
# for every id Get-AuditCheckId lists.
function Test-AuditFact {
    param([hashtable]$Facts)

    $findings = New-Object 'System.Collections.Generic.List[object]'
    $new = {
        param($Group, $Id, $Level, $Message, $Fix)
        [pscustomobject]@{ Group = $Group; Id = $Id; Level = $Level; Message = $Message; Fix = [string]$Fix }
    }
    $isAbsent = { param($Value) ($Value -is [string]) -and $Value -eq 'absent' }
    $unreadable = 'not readable'
    if (-not $Facts['Elevated']) { $unreadable = 'needs elevation' }

    # --- network ------------------------------------------------------------
    foreach ($profileName in @('Domain', 'Private', 'Public')) {
        $id = 'fw-' + $profileName.ToLowerInvariant()
        $profiles = $Facts['FirewallProfiles']
        if ($null -eq $profiles -or $null -eq $profiles[$profileName]) {
            $findings.Add((& $new 'network' $id 'skip' "firewall $profileName profile: $unreadable" ''))
            continue
        }
        $p = $profiles[$profileName]
        $fix = "Set-NetFirewallProfile -Profile $profileName -Enabled True -DefaultInboundAction Block"
        if (-not $p.Enabled) {
            $findings.Add((& $new 'network' $id 'fail' "firewall $profileName profile is off" $fix))
        } elseif ([string]$p.Inbound -eq 'Allow') {
            $findings.Add((& $new 'network' $id 'fail' "firewall $profileName profile allows inbound by default" $fix))
        } else {
            $findings.Add((& $new 'network' $id 'pass' "firewall $profileName profile is on and blocks inbound by default" ''))
        }
    }

    $smb1 = $Facts['Smb1Enabled']
    if ($null -eq $smb1) {
        $findings.Add((& $new 'network' 'smb1' 'skip' "SMBv1 server state: $unreadable" ''))
    } elseif ($smb1) {
        $findings.Add((& $new 'network' 'smb1' 'fail' 'the SMBv1 server is enabled (the WannaCry protocol)' 'Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force; Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol'))
    } else {
        $findings.Add((& $new 'network' 'smb1' 'pass' 'the SMBv1 server is disabled' ''))
    }

    $llmnr = $Facts['LlmnrMulticast']
    if ($null -eq $llmnr) {
        $findings.Add((& $new 'network' 'llmnr' 'skip' "LLMNR policy: $unreadable" ''))
    } elseif (-not (& $isAbsent $llmnr) -and [int]$llmnr -eq 0) {
        $findings.Add((& $new 'network' 'llmnr' 'pass' 'LLMNR is turned off by policy' ''))
    } else {
        $findings.Add((& $new 'network' 'llmnr' 'warn' 'LLMNR is on: any host on the subnet can answer a name lookup and collect NTLM hashes' "New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Force | Out-Null; Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Name EnableMulticast -Value 0 -Type DWord"))
    }

    # --- remote -------------------------------------------------------------
    $rdpDeny = $Facts['RdpDeny']
    $rdpOn = $null
    if ($null -ne $rdpDeny) { $rdpOn = (-not (& $isAbsent $rdpDeny)) -and [int]$rdpDeny -eq 0 }
    if ($null -eq $rdpOn) {
        $findings.Add((& $new 'remote' 'rdp-enabled' 'skip' "Remote Desktop state: $unreadable" ''))
    } elseif ($rdpOn) {
        $findings.Add((& $new 'remote' 'rdp-enabled' 'warn' 'Remote Desktop is enabled; fine on a jump box, worth knowing on a laptop' "Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 1"))
    } else {
        $findings.Add((& $new 'remote' 'rdp-enabled' 'pass' 'Remote Desktop is disabled' ''))
    }

    $nla = $Facts['RdpNla']
    if ($rdpOn -eq $false) {
        $findings.Add((& $new 'remote' 'rdp-nla' 'pass' 'Remote Desktop is off, so Network Level Authentication does not apply' ''))
    } elseif ($null -eq $rdpOn -or $null -eq $nla) {
        $findings.Add((& $new 'remote' 'rdp-nla' 'skip' "Network Level Authentication: $unreadable" ''))
    } elseif (-not (& $isAbsent $nla) -and [int]$nla -eq 1) {
        $findings.Add((& $new 'remote' 'rdp-nla' 'pass' 'Remote Desktop requires Network Level Authentication' ''))
    } else {
        $findings.Add((& $new 'remote' 'rdp-nla' 'fail' 'Remote Desktop accepts connections without Network Level Authentication: the logon screen is exposed before anyone authenticates' "Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value 1"))
    }

    $trusted = $Facts['TrustedHosts']
    if ($null -eq $trusted) {
        $findings.Add((& $new 'remote' 'winrm-trustedhosts' 'skip' "WinRM TrustedHosts: $unreadable (and the WinRM service has to be running)" ''))
    } elseif (@(([string]$trusted) -split ',' | ForEach-Object { $_.Trim() }) -contains '*') {
        $findings.Add((& $new 'remote' 'winrm-trustedhosts' 'fail' 'WinRM TrustedHosts contains *: this machine sends credentials to any host it is pointed at' "Set-Item WSMan:\localhost\Client\TrustedHosts -Value 'host1,host2' -Force"))
    } else {
        $findings.Add((& $new 'remote' 'winrm-trustedhosts' 'pass' 'WinRM TrustedHosts is not a wildcard' ''))
    }

    $sshd = $Facts['SshdConfig']
    if ($null -eq $sshd) {
        $findings.Add((& $new 'remote' 'sshd-password' 'skip' "sshd_config: $unreadable" ''))
        $findings.Add((& $new 'remote' 'sshd-empty-password' 'skip' "sshd_config: $unreadable" ''))
    } elseif (& $isAbsent $sshd) {
        $findings.Add((& $new 'remote' 'sshd-password' 'skip' 'OpenSSH server is not installed' ''))
        $findings.Add((& $new 'remote' 'sshd-empty-password' 'skip' 'OpenSSH server is not installed' ''))
    } else {
        # Windows OpenSSH allows passwords unless told otherwise.
        $passwords = [string]$sshd['passwordauthentication']
        if ($passwords -eq 'no') {
            $findings.Add((& $new 'remote' 'sshd-password' 'pass' 'sshd accepts keys only (PasswordAuthentication no)' ''))
        } else {
            $findings.Add((& $new 'remote' 'sshd-password' 'warn' 'sshd accepts passwords, which invites guessing' 'set PasswordAuthentication no in $env:ProgramData\ssh\sshd_config, then Restart-Service sshd'))
        }
        if ([string]$sshd['permitemptypasswords'] -eq 'yes') {
            $findings.Add((& $new 'remote' 'sshd-empty-password' 'fail' 'sshd accepts accounts with an empty password' 'set PermitEmptyPasswords no in $env:ProgramData\ssh\sshd_config, then Restart-Service sshd'))
        } else {
            $findings.Add((& $new 'remote' 'sshd-empty-password' 'pass' 'sshd refuses empty passwords' ''))
        }
    }

    # --- accounts -----------------------------------------------------------
    $policyKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $lua = $Facts['EnableLua']
    if ($null -eq $lua) {
        $findings.Add((& $new 'accounts' 'uac-lua' 'skip' "UAC: $unreadable" ''))
    } elseif (-not (& $isAbsent $lua) -and [int]$lua -eq 0) {
        $findings.Add((& $new 'accounts' 'uac-lua' 'fail' 'UAC is off (EnableLUA=0): every administrator process runs with full rights' "Set-ItemProperty -Path '$policyKey' -Name EnableLUA -Value 1, then restart"))
    } else {
        $findings.Add((& $new 'accounts' 'uac-lua' 'pass' 'UAC is on' ''))
    }

    $prompt = $Facts['ConsentPromptAdmin']
    if ($null -eq $prompt) {
        $findings.Add((& $new 'accounts' 'uac-prompt' 'skip' "UAC prompt behaviour: $unreadable" ''))
    } elseif (-not (& $isAbsent $prompt) -and [int]$prompt -eq 0) {
        $findings.Add((& $new 'accounts' 'uac-prompt' 'fail' 'UAC elevates administrators without asking (ConsentPromptBehaviorAdmin=0)' "Set-ItemProperty -Path '$policyKey' -Name ConsentPromptBehaviorAdmin -Value 5"))
    } else {
        $findings.Add((& $new 'accounts' 'uac-prompt' 'pass' 'UAC asks before elevating' ''))
    }

    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $autologon = $Facts['AutoAdminLogon']
    if ($null -eq $autologon) {
        $findings.Add((& $new 'accounts' 'autologon' 'skip' "autologon: $unreadable" ''))
    } elseif ([string]$autologon -eq '1') {
        $findings.Add((& $new 'accounts' 'autologon' 'fail' 'automatic logon is on: anyone at the keyboard gets the session' "Set-ItemProperty -Path '$winlogon' -Name AutoAdminLogon -Value 0"))
    } else {
        $findings.Add((& $new 'accounts' 'autologon' 'pass' 'automatic logon is off' ''))
    }

    $storedPassword = $Facts['DefaultPasswordPresent']
    if ($null -eq $storedPassword) {
        $findings.Add((& $new 'accounts' 'autologon-password' 'skip' "Winlogon DefaultPassword: $unreadable" ''))
    } elseif ($storedPassword) {
        $findings.Add((& $new 'accounts' 'autologon-password' 'fail' 'a DefaultPassword value exists under Winlogon: a logon password stored in clear text in the registry (its value was not read)' "Remove-ItemProperty -Path '$winlogon' -Name DefaultPassword"))
    } else {
        $findings.Add((& $new 'accounts' 'autologon-password' 'pass' 'no clear-text DefaultPassword under Winlogon' ''))
    }

    $guest = $Facts['GuestEnabled']
    if ($null -eq $guest) {
        $findings.Add((& $new 'accounts' 'guest-enabled' 'skip' "Guest account: $unreadable" ''))
    } elseif ((& $isAbsent $guest) -or -not $guest) {
        $findings.Add((& $new 'accounts' 'guest-enabled' 'pass' 'the Guest account is disabled' ''))
    } else {
        $findings.Add((& $new 'accounts' 'guest-enabled' 'fail' 'the Guest account is enabled' "Get-LocalUser | Where-Object { `$_.SID -like '*-501' } | Disable-LocalUser"))
    }

    $admins = $Facts['LocalAdmins']
    if ($null -eq $admins) {
        $findings.Add((& $new 'accounts' 'local-admins-broad' 'skip' "local Administrators members: $unreadable" ''))
    } else {
        $broadSids = @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545')
        $broad = @()
        foreach ($member in @($admins)) {
            if ($broadSids -contains [string]$member.Sid) { $broad += [string]$member.Name }
        }
        if ($broad.Count -gt 0) {
            $findings.Add((& $new 'accounts' 'local-admins-broad' 'fail' ('the local Administrators group contains {0}: every user is an administrator' -f ($broad -join ', ')) ("Remove-LocalGroupMember -SID S-1-5-32-544 -Member '{0}'" -f $broad[0])))
        } else {
            $findings.Add((& $new 'accounts' 'local-admins-broad' 'pass' 'no broad principal in the local Administrators group' ''))
        }
    }

    # --- boot ---------------------------------------------------------------
    $secureBoot = $Facts['SecureBoot']
    if ($null -eq $secureBoot) {
        $findings.Add((& $new 'boot' 'secureboot' 'skip' "Secure Boot: $unreadable" ''))
    } elseif (& $isAbsent $secureBoot) {
        $findings.Add((& $new 'boot' 'secureboot' 'skip' 'Secure Boot: legacy BIOS, or the firmware does not report it' ''))
    } elseif ($secureBoot) {
        $findings.Add((& $new 'boot' 'secureboot' 'pass' 'Secure Boot is on' ''))
    } else {
        $findings.Add((& $new 'boot' 'secureboot' 'warn' 'Secure Boot is off: a bootkit can load before Windows' 'enable Secure Boot in the UEFI setup (Confirm-SecureBootUEFI should then say True)'))
    }

    $tpm = $Facts['Tpm']
    if ($null -eq $tpm) {
        $findings.Add((& $new 'boot' 'tpm' 'skip' "TPM: $unreadable" ''))
    } elseif (-not $tpm.Present) {
        $findings.Add((& $new 'boot' 'tpm' 'warn' 'no TPM: BitLocker and Windows Hello have no hardware root of trust' 'enable the TPM (fTPM / PTT) in the UEFI setup'))
    } elseif (-not $tpm.Ready) {
        $findings.Add((& $new 'boot' 'tpm' 'warn' 'the TPM is present but not ready for use' 'tpm.msc shows what it needs; Initialize-Tpm prepares it'))
    } else {
        $findings.Add((& $new 'boot' 'tpm' 'pass' 'the TPM is present and ready' ''))
    }

    $ppl = $Facts['RunAsPpl']
    if ($null -eq $ppl) {
        $findings.Add((& $new 'boot' 'lsa-ppl' 'skip' "LSA protection: $unreadable" ''))
    } elseif (-not (& $isAbsent $ppl) -and ([int]$ppl -eq 1 -or [int]$ppl -eq 2)) {
        $findings.Add((& $new 'boot' 'lsa-ppl' 'pass' 'LSA runs as a protected process' ''))
    } else {
        $findings.Add((& $new 'boot' 'lsa-ppl' 'warn' 'LSA protection is off: credential dumping tools can read LSASS memory' "Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name RunAsPPL -Value 1 -Type DWord, then restart"))
    }

    $vbs = $Facts['VbsStatus']
    if ($null -eq $vbs) {
        $findings.Add((& $new 'boot' 'vbs' 'skip' "virtualization-based security: $unreadable" ''))
    } elseif ([int]$vbs -eq 2) {
        $findings.Add((& $new 'boot' 'vbs' 'pass' 'virtualization-based security is running' ''))
    } else {
        $findings.Add((& $new 'boot' 'vbs' 'warn' 'virtualization-based security is not running (Credential Guard and memory integrity depend on it)' 'Windows Security > Device security > Core isolation > Memory integrity'))
    }

    # --- defender -----------------------------------------------------------
    $defender = $Facts['Defender']
    $defenderIds = @('defender-rtp', 'defender-tamper', 'defender-sigs', 'defender-pua', 'defender-netprot')
    if ($null -eq $defender) {
        foreach ($id in $defenderIds) {
            $findings.Add((& $new 'defender' $id 'skip' 'Microsoft Defender status unavailable (another antivirus product, or not readable)' ''))
        }
    } else {
        if ($defender.Rtp) {
            $findings.Add((& $new 'defender' 'defender-rtp' 'pass' 'real-time protection is on' ''))
        } else {
            $findings.Add((& $new 'defender' 'defender-rtp' 'fail' 'real-time protection is off' 'Set-MpPreference -DisableRealtimeMonitoring $false'))
        }
        if ($null -eq $defender.Tamper) {
            $findings.Add((& $new 'defender' 'defender-tamper' 'skip' 'tamper protection state not reported' ''))
        } elseif ($defender.Tamper) {
            $findings.Add((& $new 'defender' 'defender-tamper' 'pass' 'tamper protection is on' ''))
        } else {
            $findings.Add((& $new 'defender' 'defender-tamper' 'warn' 'tamper protection is off: malware with admin rights can switch Defender off' 'Windows Security > Virus & threat protection settings > Tamper Protection'))
        }
        if ($null -eq $defender.SignatureAge) {
            $findings.Add((& $new 'defender' 'defender-sigs' 'skip' 'signature age not reported' ''))
        } elseif ([int]$defender.SignatureAge -gt 7) {
            $findings.Add((& $new 'defender' 'defender-sigs' 'warn' ('signatures are {0} days old' -f [int]$defender.SignatureAge) 'Update-MpSignature'))
        } else {
            $findings.Add((& $new 'defender' 'defender-sigs' 'pass' ('signatures are {0} day(s) old' -f [int]$defender.SignatureAge) ''))
        }
        if ($null -eq $defender.Pua) {
            $findings.Add((& $new 'defender' 'defender-pua' 'skip' "PUA protection: $unreadable" ''))
        } elseif ([int]$defender.Pua -eq 1) {
            $findings.Add((& $new 'defender' 'defender-pua' 'pass' 'potentially unwanted apps are blocked' ''))
        } else {
            $findings.Add((& $new 'defender' 'defender-pua' 'warn' 'potentially unwanted apps are not blocked' 'Set-MpPreference -PUAProtection Enabled'))
        }
        if ($null -eq $defender.NetworkProtection) {
            $findings.Add((& $new 'defender' 'defender-netprot' 'skip' "network protection: $unreadable" ''))
        } elseif ([int]$defender.NetworkProtection -eq 1) {
            $findings.Add((& $new 'defender' 'defender-netprot' 'pass' 'network protection blocks known-bad hosts' ''))
        } else {
            $findings.Add((& $new 'defender' 'defender-netprot' 'warn' 'network protection is off or audit-only' 'Set-MpPreference -EnableNetworkProtection Enabled'))
        }
    }

    # --- logging ------------------------------------------------------------
    $scriptBlock = $Facts['ScriptBlockLogging']
    if ($null -eq $scriptBlock) {
        $findings.Add((& $new 'logging' 'ps-scriptblock' 'skip' "PowerShell script block logging: $unreadable" ''))
    } elseif (-not (& $isAbsent $scriptBlock) -and [int]$scriptBlock -eq 1) {
        $findings.Add((& $new 'logging' 'ps-scriptblock' 'pass' 'PowerShell script block logging is on' ''))
    } else {
        $findings.Add((& $new 'logging' 'ps-scriptblock' 'warn' 'PowerShell script block logging is off: there is no record of what ran' "New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' -Force | Out-Null; Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' -Name EnableScriptBlockLogging -Value 1 -Type DWord"))
    }

    # --- updates ------------------------------------------------------------
    $newest = $Facts['NewestHotfix']
    $now = $Facts['Now']
    if ($null -eq $newest -or $null -eq $now) {
        $findings.Add((& $new 'updates' 'hotfix-age' 'skip' 'no installed-update date readable' ''))
    } else {
        $age = [int][math]::Floor(([datetime]$now - [datetime]$newest).TotalDays)
        if ($age -gt 120) {
            $findings.Add((& $new 'updates' 'hotfix-age' 'fail' "the newest installed update is $age days old" 'Settings > Windows Update > Check for updates'))
        } elseif ($age -gt 60) {
            $findings.Add((& $new 'updates' 'hotfix-age' 'warn' "the newest installed update is $age days old" 'Settings > Windows Update > Check for updates'))
        } else {
            $findings.Add((& $new 'updates' 'hotfix-age' 'pass' "the newest installed update is $age day(s) old" ''))
        }
    }

    $reboot = $Facts['RebootPending']
    if ($null -eq $reboot) {
        $findings.Add((& $new 'updates' 'reboot-pending' 'skip' "pending reboot: $unreadable" ''))
    } elseif ($reboot) {
        $findings.Add((& $new 'updates' 'reboot-pending' 'warn' 'a restart is pending: installed updates are not in effect yet' 'Restart-Computer, when it suits you'))
    } else {
        $findings.Add((& $new 'updates' 'reboot-pending' 'pass' 'no restart pending' ''))
    }

    return $findings
}

# 1 when anything is at or above the threshold, else 0. Skips never count.
function Get-AuditExitCode {
    param(
        [object[]]$Findings,
        [string]$FailOn
    )
    $fails = 0
    $warns = 0
    foreach ($finding in $Findings) {
        if ($finding.Level -eq 'fail') { $fails++ }
        if ($finding.Level -eq 'warn') { $warns++ }
    }
    if ($fails -gt 0) { return 1 }
    if ($FailOn -eq 'warn' -and $warns -gt 0) { return 1 }
    return 0
}

# --- probes -----------------------------------------------------------------
# Every probe is collected here, once, behind its own try/catch, so a cmdlet
# that does not exist on this edition is a $null fact (a skip), never an
# abort. Only the groups asked for are probed.

function Get-RegistryFact {
    param([string]$Path, [string]$Name)
    try {
        if (-not (Test-Path -Path $Path)) { return 'absent' }
        $item = Get-ItemProperty -Path $Path -ErrorAction Stop
        if ($item.PSObject.Properties.Name -notcontains $Name) { return 'absent' }
        return $item.$Name
    } catch {
        Write-Verbose ("registry {0}\{1}: {2}" -f $Path, $Name, $_.Exception.Message)
        return $null
    }
}

function Get-AuditFact {
    param(
        [string[]]$Groups,
        [bool]$Elevated
    )
    $facts = @{ Elevated = $Elevated; Now = (Get-Date) }

    # The registry is either there (Windows) or not (anywhere else); asked
    # once, so that every registry fact off Windows is $null rather than
    # 'absent', which would read as an answer.
    $registry = $false
    try { $registry = [bool](Test-Path -Path 'HKLM:\SOFTWARE' -ErrorAction Stop) } catch { Write-Verbose $_.Exception.Message }
    $reg = {
        param($Path, $Name)
        if (-not $registry) { return $null }
        return Get-RegistryFact -Path $Path -Name $Name
    }

    if ($Groups -contains 'network') {
        try {
            $profiles = @{}
            foreach ($p in @(Get-NetFirewallProfile -ErrorAction Stop)) {
                $profiles[[string]$p.Name] = @{ Enabled = ([string]$p.Enabled -eq 'True'); Inbound = [string]$p.DefaultInboundAction }
            }
            $facts['FirewallProfiles'] = $profiles
        } catch { Write-Verbose $_.Exception.Message }
        try { $facts['Smb1Enabled'] = [bool](Get-SmbServerConfiguration -ErrorAction Stop).EnableSMB1Protocol } catch { Write-Verbose $_.Exception.Message }
        $facts['LlmnrMulticast'] = & $reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' 'EnableMulticast'
    }

    if ($Groups -contains 'remote') {
        $facts['RdpDeny'] = & $reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections'
        $facts['RdpNla'] = & $reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' 'UserAuthentication'
        # The WSMan: drive answers only while the WinRM service runs; the
        # client settings it shows are also kept in the registry, which is
        # the fallback.
        try {
            $facts['TrustedHosts'] = [string](Get-Item -Path 'WSMan:\localhost\Client\TrustedHosts' -ErrorAction Stop).Value
        } catch {
            Write-Verbose $_.Exception.Message
            $stored = & $reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WSMAN\Client' 'trusted_hosts'
            if ($null -ne $stored -and -not (($stored -is [string]) -and $stored -eq 'absent')) { $facts['TrustedHosts'] = [string]$stored }
        }
        if ($registry -and $env:ProgramData) {
            $sshdConfig = Join-Path $env:ProgramData 'ssh\sshd_config'
            if (Test-Path -LiteralPath $sshdConfig) {
                try { $facts['SshdConfig'] = Get-SshdSetting -Lines ([IO.File]::ReadAllLines($sshdConfig)) } catch { Write-Verbose $_.Exception.Message }
            } else {
                $facts['SshdConfig'] = 'absent'
            }
        }
    }

    if ($Groups -contains 'accounts') {
        $policy = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        $facts['EnableLua'] = & $reg $policy 'EnableLUA'
        $facts['ConsentPromptAdmin'] = & $reg $policy 'ConsentPromptBehaviorAdmin'
        $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        $facts['AutoAdminLogon'] = & $reg $winlogon 'AutoAdminLogon'
        # Whether the value EXISTS, from the key's list of value names. Its
        # data is never read.
        if ($registry) {
            try { $facts['DefaultPasswordPresent'] = [bool]((Get-Item -Path $winlogon -ErrorAction Stop).Property -contains 'DefaultPassword') } catch { Write-Verbose $_.Exception.Message }
        }
        try {
            $guest = @(Get-LocalUser -ErrorAction Stop | Where-Object { [string]$_.SID -match '-501$' })
            if ($guest.Count -eq 0) { $facts['GuestEnabled'] = 'absent' } else { $facts['GuestEnabled'] = [bool]$guest[0].Enabled }
        } catch { Write-Verbose $_.Exception.Message }
        try {
            $facts['LocalAdmins'] = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop |
                ForEach-Object { @{ Sid = [string]$_.SID; Name = [string]$_.Name } })
        } catch { Write-Verbose $_.Exception.Message }
    }

    if ($Groups -contains 'boot') {
        if ($Elevated) {
            try { $facts['SecureBoot'] = [bool](Confirm-SecureBootUEFI -ErrorAction Stop) } catch { $facts['SecureBoot'] = 'absent' }
            try {
                $tpm = Get-Tpm -ErrorAction Stop
                $facts['Tpm'] = @{ Present = [bool]$tpm.TpmPresent; Ready = [bool]$tpm.TpmReady }
            } catch { Write-Verbose $_.Exception.Message }
        }
        $facts['RunAsPpl'] = & $reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'RunAsPPL'
        try {
            $guard = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
            $facts['VbsStatus'] = [int]$guard.VirtualizationBasedSecurityStatus
        } catch { Write-Verbose $_.Exception.Message }
    }

    if ($Groups -contains 'defender') {
        try {
            $status = Get-MpComputerStatus -ErrorAction Stop
            $defender = @{
                Rtp = [bool]$status.RealTimeProtectionEnabled
                Tamper = $status.IsTamperProtected
                SignatureAge = $status.AntivirusSignatureAge
                Pua = $null
                NetworkProtection = $null
            }
            try {
                $preference = Get-MpPreference -ErrorAction Stop
                $defender.Pua = $preference.PUAProtection
                $defender.NetworkProtection = $preference.EnableNetworkProtection
            } catch { Write-Verbose $_.Exception.Message }
            $facts['Defender'] = $defender
        } catch { Write-Verbose $_.Exception.Message }
    }

    if ($Groups -contains 'logging') {
        $facts['ScriptBlockLogging'] = & $reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' 'EnableScriptBlockLogging'
    }

    if ($Groups -contains 'updates') {
        try {
            $dates = @(Get-HotFix -ErrorAction Stop | ForEach-Object { $_.InstalledOn } | Where-Object { $_ })
            if ($dates.Count -gt 0) { $facts['NewestHotfix'] = ($dates | Sort-Object -Descending | Select-Object -First 1) }
        } catch { Write-Verbose $_.Exception.Message }
        if ($registry) {
            $facts['RebootPending'] = (Test-Path -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                (Test-Path -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
        }
    }
    return $facts
}

# --- arguments --------------------------------------------------------------
# Ahead of the preflight, as in every script here.
if ($ListGroups) {
    $GroupOrder | ForEach-Object { Write-Output $_ }
    exit 0
}

$selected = @()
if ($PSBoundParameters.ContainsKey('Only')) {
    foreach ($raw in @($Only | ForEach-Object { $_ -split ',' })) {
        $id = $raw.Trim()
        if (-not $id) { continue }
        if ($GroupOrder -notcontains $id) {
            Write-Err "unknown group in -Only: $id (see -ListGroups)"
            exit 3
        }
        $selected += $id
    }
    if ($selected.Count -eq 0) {
        Write-Err '-Only selected nothing'
        exit 4
    }
} else {
    $selected = @($GroupOrder)
}

if ($FailOn -notin @('fail', 'warn')) {
    Write-Err "-FailOn must be warn or fail, got: $FailOn"
    exit 3
}

# --- preflight -------------------------------------------------------------
# Mirrors status.ps1: wrong platform is 2. Windows PowerShell 5.1 does not
# define $IsWindows at all, hence the edition test.
if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    Write-Err 'this script targets Windows'
    exit 2
}

$isAdmin = $false
try {
    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {
    Write-Verbose $_.Exception.Message
}

Write-Host ''
Write-Host "hardening_audit: $Action" -ForegroundColor White
if ($isAdmin) {
    Write-Info 'running elevated'
} else {
    Write-Info 'not elevated - checks that need it are skipped, not failed; run from an elevated prompt for the full picture'
}

$facts = Get-AuditFact -Groups $selected -Elevated $isAdmin
$findings = @(Test-AuditFact -Facts $facts | Where-Object { $selected -contains $_.Group })

foreach ($group in $GroupOrder) {
    if ($selected -notcontains $group) { continue }
    Write-Host ''
    Write-Host "== $group ==" -ForegroundColor White
    foreach ($finding in @($findings | Where-Object { $_.Group -eq $group })) {
        $script:Counts[$finding.Level]++
        switch ($finding.Level) {
            'pass' {
                if (-not $script:QuietMode) { Write-Host "  [pass] $($finding.Message)" -ForegroundColor Green }
            }
            'skip' {
                if (-not $script:QuietMode) { Write-Host "  [skip] $($finding.Message)" -ForegroundColor DarkGray }
            }
            'warn' {
                Write-Host "  [warn] $($finding.Message)" -ForegroundColor Yellow
                if ($finding.Fix) { Write-Host "         $($finding.Fix)" -ForegroundColor DarkGray }
            }
            default {
                Write-Host "  [FAIL] $($finding.Message)" -ForegroundColor Red
                if ($finding.Fix) { Write-Host "         $($finding.Fix)" -ForegroundColor DarkGray }
            }
        }
    }
}

Write-Host ''
Write-Host '== summary ==' -ForegroundColor White
Write-Host ('  {0} pass  {1} warn  {2} fail  {3} skip' -f $script:Counts['pass'], $script:Counts['warn'], $script:Counts['fail'], $script:Counts['skip'])
if ($script:Counts['skip'] -gt 0 -and -not $isAdmin) {
    Write-Info 'some checks need elevation; rerun from an elevated prompt for the full picture'
}
exit (Get-AuditExitCode -Findings $findings -FailOn $FailOn)
