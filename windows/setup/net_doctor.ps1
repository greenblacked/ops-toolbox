<#
.SYNOPSIS
    Read-only network report for a Windows machine.

.DESCRIPTION
    The Windows counterpart of linux/net_doctor.sh: the first thing to run when
    "I cannot reach X". It looks, it never touches. Sections, in order:

      interfaces  adapters that are up, their link speed, global addresses, and
                  what kind each is (physical, Hyper-V, WSL, Docker, VPN)
      routes      default gateways, and a warning when more than one adapter
                  carries one - Wi-Fi plus a VPN is the usual pair
      dns         DNS servers and suffix per adapter
      proxy       the WinINET proxy (browsers, most of Windows), the *_PROXY
                  environment variables (curl, git, pip, docker) and git's
                  http.proxy, and where they disagree
      hosts       the entries in the hosts file
      listen      listening TCP ports and the process that owns each one
      probe       only with -Probe: resolve the host, ask every configured DNS
                  server separately, then make one TCP connection

    The Windows-only failures are the reason this exists rather than
    "ipconfig /all": a WinINET proxy that disagrees with HTTP_PROXY, so the
    browser works and git does not; a stale hosts entry; two default gateways;
    one dead DNS server out of two, which shows up as every other lookup being
    slow; and a port somebody else is already listening on.

    Nothing is written and nothing is sent unless -Probe is given, and then
    only a DNS lookup and one TCP connect with no payload. Proxy credentials
    are masked before they are printed. Every probe is best-effort: a cmdlet
    that does not exist on this edition is a [skip], never an abort.

    -ListSections and the argument checks answer before the Windows preflight,
    so they work on Linux pwsh. There is no -DryRun because there is nothing to
    preview; -Action takes one value, 'report', which is the read-only default
    the contract checks look for.

.PARAMETER Only
    Comma-separated section ids (see -ListSections). Unknown ids exit 3; a
    list that selects nothing exits 4.

.PARAMETER Probe
    A host name or address to resolve and connect to. Letters, digits, '.',
    '_' and '-' only, or an IPv6 address in brackets.

.PARAMETER Port
    The TCP port -Probe connects to. Default 443.

.PARAMETER HostsFile
    The hosts file to read. Defaults to the one under the system directory;
    the contract tests point it at a fixture.

.EXAMPLE
    .\net_doctor.ps1
    .\net_doctor.ps1 -ListSections
    .\net_doctor.ps1 -Only proxy,dns
    .\net_doctor.ps1 -Probe github.com
    .\net_doctor.ps1 -Probe registry.internal -Port 5000 -SkipListen
    .\net_doctor.ps1 -Quiet

.NOTES
    Exit codes, matching linux/net_doctor.sh plus the -Only codes of status.ps1:
      0  the report ran (warnings do not change the exit code)
      2  not Windows
      3  invalid arguments: unknown -Only section, bad -Probe host or -Port
      4  -Only selected nothing
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('report')]
    [string]$Action = 'report',

    # A list, split on commas in the body, for the reason stay_fresh.ps1 gives:
    # 'pwsh -File' hands '-Only proxy,dns' over as the single string 'proxy,dns'.
    [string[]]$Only = @(),

    [switch]$ListSections,

    [string]$Probe = '',

    # Validated by hand below rather than with ValidateRange: a binding failure
    # under 'pwsh -File' exits 1, and a bad argument here is a usage error (3).
    [int]$Port = 443,

    [switch]$SkipListen,

    [switch]$Quiet,

    [string]$HostsFile = ''
)

$ErrorActionPreference = 'Stop'
$script:Warnings = 0
$script:QuietMode = [bool]$Quiet

$SectionOrder = @('interfaces', 'routes', 'dns', 'proxy', 'hosts', 'listen', 'probe')

function Write-Info {
    param([string]$Message)
    if (-not $script:QuietMode) { Write-Host "[info] $Message" -ForegroundColor Blue }
}
function Write-Ok {
    param([string]$Message)
    if (-not $script:QuietMode) { Write-Host "[ ok ] $Message" -ForegroundColor Green }
}
function Write-Warn {
    param([string]$Message)
    $script:Warnings++
    Write-Host "[warn] $Message" -ForegroundColor Yellow
}
function Write-Skip {
    param([string]$Message)
    if (-not $script:QuietMode) { Write-Host "[skip] $Message" -ForegroundColor DarkGray }
}
function Write-Err  { param([string]$Message) Write-Host "[err ] $Message" -ForegroundColor Red }
function Write-Section {
    param([string]$Name)
    if (-not $script:QuietMode) { Write-Host ''; Write-Host "== $Name ==" -ForegroundColor White }
}
# Indented detail under the line above it. A hint under a [warn] is printed
# even with -Quiet, because a warning without its fix is half a warning.
function Write-Detail {
    param([string]$Message, [switch]$Always)
    if ($Always -or -not $script:QuietMode) { Write-Host "  $Message" -ForegroundColor DarkGray }
}

# --- pure helpers -----------------------------------------------------------
# These take plain data and return plain data, so windows/tests/contract.ps1
# can lift them out of this file and test them with fixtures. Keep them free of
# script-scope variables and of calls to the other helpers.

# scheme://user:secret@host -> scheme://user:***@host. The secret may itself
# contain '@' or ':' (people paste them unencoded), so the user part ends at the
# first ':' and the host starts after the LAST '@'. A URL with no password is
# returned unchanged, and so is one this cannot read: the failure mode of a
# masking function has to be "printed something odd", never "printed a secret".
function Hide-UrlCredential {
    param([string]$Url)
    if ([string]::IsNullOrEmpty($Url)) { return '' }

    $scheme = ''
    $rest = $Url
    $schemeEnd = $Url.IndexOf('://')
    if ($schemeEnd -gt 0) {
        $scheme = $Url.Substring(0, $schemeEnd + 3)
        $rest = $Url.Substring($schemeEnd + 3)
    }

    $at = $rest.LastIndexOf('@')
    if ($at -lt 0) { return $Url }
    $userInfo = $rest.Substring(0, $at)
    $colon = $userInfo.IndexOf(':')
    if ($colon -lt 0) { return $Url }

    return '{0}{1}:***@{2}' -f $scheme, $userInfo.Substring(0, $colon), $rest.Substring($at + 1)
}

# One object per mapping line: { Address, Names[] }. Comments run from '#' to
# the end of the line, fields are separated by any run of spaces or tabs, and a
# line with an address but no name is not a mapping.
function Get-HostsEntry {
    param([string[]]$Lines)
    foreach ($raw in $Lines) {
        if ($null -eq $raw) { continue }
        $line = $raw
        $hash = $line.IndexOf('#')
        if ($hash -ge 0) { $line = $line.Substring(0, $hash) }
        $fields = @($line.Trim() -split '\s+' | Where-Object { $_ -ne '' })
        if ($fields.Count -lt 2) { continue }
        [pscustomobject]@{
            Address = $fields[0]
            Names   = @($fields[1..($fields.Count - 1)])
        }
    }
}

# The WSL test comes first: its adapter is a Hyper-V adapter by description,
# and "Hyper-V" would tell you nothing about why it is there.
function Get-AdapterKind {
    param([string]$Name, [string]$Description)
    $text = '{0} {1}' -f $Name, $Description
    if ($text -match 'vEthernet \(WSL') { return 'wsl' }
    if ($text -match 'Docker') { return 'docker' }
    if ($text -match 'Hyper-V') { return 'hyper-v' }
    if ($text -match 'TAP-Windows|WireGuard|Tailscale|Wintun|VPN') { return 'vpn' }
    if ($text -match 'Bluetooth') { return 'bluetooth' }
    return 'physical'
}

# Findings about the proxy configuration, from a hashtable of what was read:
#   WinInetEnabled (bool), WinInetServer, AutoConfigUrl,
#   HttpProxy, HttpsProxy, AllProxy, NoProxy, GitProxy
# Returns { Id, Level (info|warn), Message }. Comparison ignores the scheme,
# credentials, a trailing slash and case, so 'http://Proxy:8080/' and the
# WinINET form 'proxy:8080' are the same proxy.
function Get-ProxyFinding {
    param([hashtable]$Observed)

    $normalise = {
        param([string]$Value)
        if (-not $Value) { return '' }
        $v = $Value.Trim()
        $i = $v.IndexOf('://')
        if ($i -ge 0) { $v = $v.Substring($i + 3) }
        $a = $v.LastIndexOf('@')
        if ($a -ge 0) { $v = $v.Substring($a + 1) }
        return $v.TrimEnd('/').ToLowerInvariant()
    }

    # WinINET stores either one 'host:port' for every protocol, or a list such
    # as 'http=host:port;https=host:port'. Keep the two protocols apart: a
    # single value applies to both.
    $inet = [string]$Observed['WinInetServer']
    $inetHttp = $inet
    $inetHttps = $inet
    $inetList = $false
    if ($inet -match '=') {
        $inetList = $true
        $inetHttp = ''
        $inetHttps = ''
        foreach ($part in ($inet -split ';')) {
            $kv = $part -split '=', 2
            if ($kv.Count -ne 2) { continue }
            $name = $kv[0].Trim().ToLowerInvariant()
            if ($name -eq 'http') { $inetHttp = $kv[1] }
            elseif ($name -eq 'https') { $inetHttps = $kv[1] }
        }
    }
    $inetOn = [bool]$Observed['WinInetEnabled'] -and ($inetHttp -or $inetHttps)

    # HTTP_PROXY pairs with the http entry, HTTPS_PROXY with the https one;
    # ALL_PROXY stands in for whichever of the two is unset.
    $envHttp = [string]$Observed['HttpProxy']
    if (-not $envHttp) { $envHttp = [string]$Observed['AllProxy'] }
    $envHttps = [string]$Observed['HttpsProxy']
    if (-not $envHttps) { $envHttps = [string]$Observed['AllProxy'] }
    $envProxy = [bool]($envHttp -or $envHttps)
    # git has one http.proxy for both protocols: compare it with the proxy
    # the environment names, in git's order: HTTPS_PROXY, HTTP_PROXY, then
    # ALL_PROXY (read straight from the observed values, not the folded ones).
    $envForGit = [string]$Observed['HttpsProxy']
    if (-not $envForGit) { $envForGit = [string]$Observed['HttpProxy'] }
    if (-not $envForGit) { $envForGit = [string]$Observed['AllProxy'] }

    $mismatch = $false
    if ($inetOn) {
        if ($envHttp -and $inetHttp -and ((& $normalise $envHttp) -ne (& $normalise $inetHttp))) { $mismatch = $true }
        if ($envHttps -and $inetHttps -and ((& $normalise $envHttps) -ne (& $normalise $inetHttps))) { $mismatch = $true }
        # An explicit per-protocol WinINET list that names a protocol the
        # environment leaves out (or the other way round) routes that
        # protocol differently. A single WinINET value is not compared this
        # way: it covers both protocols, and one variable is the usual setup.
        if ($inetList) {
            if ([bool]$envHttp -ne [bool]$inetHttp) { $mismatch = $true }
            if ([bool]$envHttps -ne [bool]$inetHttps) { $mismatch = $true }
        }
    }

    $findings = @()
    if ($envProxy -and -not $inetOn -and $Observed['AutoConfigUrl']) {
        # A PAC script is enough to proxy browsers with ProxyEnable off, and
        # this script does not evaluate it: it cannot say they connect
        # directly. The URL is shown without any user:password part.
        $pacShown = [string]$Observed['AutoConfigUrl']
        $pacSchemeEnd = $pacShown.IndexOf('://')
        $pacAt = $pacShown.LastIndexOf('@')
        if ($pacAt -ge 0) {
            $pacHead = ''
            if ($pacSchemeEnd -ge 0 -and $pacSchemeEnd -lt $pacAt) { $pacHead = $pacShown.Substring(0, $pacSchemeEnd + 3) }
            $pacShown = $pacHead + $pacShown.Substring($pacAt + 1)
        }
        $findings += [pscustomobject]@{
            Id = 'env-with-pac'; Level = 'info'
            Message = "HTTP(S)_PROXY is set, the WinINET proxy is off and a PAC script ($pacShown) is configured: whether browsers use a proxy depends on the PAC script, which is not evaluated here"
        }
    } elseif ($envProxy -and -not $inetOn) {
        $findings += [pscustomobject]@{
            Id = 'env-without-wininet'; Level = 'warn'
            Message = 'HTTP(S)_PROXY is set but the WinINET proxy is off: curl, git and pip use the proxy, browsers and Windows itself do not'
        }
    } elseif ($envProxy -and $mismatch) {
        $findings += [pscustomobject]@{
            Id = 'proxy-mismatch'; Level = 'warn'
            Message = 'HTTP(S)_PROXY and the WinINET proxy point at different proxies: command-line tools and browsers take different routes'
        }
    } elseif ($inetOn -and -not $envProxy) {
        $findings += [pscustomobject]@{
            Id = 'wininet-without-env'; Level = 'info'
            Message = 'the WinINET proxy is on but HTTP(S)_PROXY is not set: curl, git, pip and docker will try to connect directly'
        }
    }

    if ($envProxy -and -not $Observed['NoProxy']) {
        $findings += [pscustomobject]@{
            Id = 'no-proxy-empty'; Level = 'warn'
            Message = 'a proxy is set in the environment and NO_PROXY is empty: localhost and internal names go through the proxy too'
        }
    }
    if ($Observed['AutoConfigUrl']) {
        $findings += [pscustomobject]@{
            Id = 'pac'; Level = 'info'
            Message = 'a PAC script picks the proxy per URL; command-line tools do not read it'
        }
    }
    if ($Observed['GitProxy'] -and $envForGit -and ((& $normalise $Observed['GitProxy']) -ne (& $normalise $envForGit))) {
        $findings += [pscustomobject]@{
            Id = 'git-proxy-differs'; Level = 'info'
            Message = "git's http.proxy differs from HTTP(S)_PROXY; git uses http.proxy"
        }
    }
    return $findings
}

# Bits per second as a person reads a link speed.
function Format-LinkSpeed {
    param([long]$BitsPerSecond)
    if ($BitsPerSecond -le 0) { return 'speed unknown' }
    if ($BitsPerSecond -ge 1000000000) { return '{0:N1} Gbps' -f ($BitsPerSecond / 1000000000) }
    if ($BitsPerSecond -ge 1000000) { return '{0:N0} Mbps' -f ($BitsPerSecond / 1000000) }
    return '{0:N0} kbps' -f ($BitsPerSecond / 1000)
}

# --- probes -----------------------------------------------------------------
# Thin wrappers. Every read is behind try/catch and answers $null or an empty
# list, so a property that throws on one platform cannot end the report.

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

# Upper case is the convention on Windows; lower case is what Linux tools and
# a good many Windows ports of them read first.
function Get-ProxyVariable {
    param([string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if (-not $value) { $value = [Environment]::GetEnvironmentVariable($Name.ToLowerInvariant()) }
    return [string]$value
}

function Get-GitConfigValue {
    param([string]$Key)
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $null }
    # 'Continue' here so a git that writes to stderr cannot turn into a
    # terminating error under Windows PowerShell 5.1.
    $ErrorActionPreference = 'Continue'
    try {
        $value = & git config --global --get $Key 2>$null
        if ($LASTEXITCODE -eq 0 -and $value) { return ([string]$value).Trim() }
    } catch {
        Write-Verbose ("git config {0}: {1}" -f $Key, $_.Exception.Message)
    }
    return $null
}

# One plain object per adapter that is up and is not loopback.
function Get-NicFact {
    param($Nic)
    $fact = [ordered]@{
        Name        = [string]$Nic.Name
        Description = [string]$Nic.Description
        Kind        = Get-AdapterKind -Name $Nic.Name -Description $Nic.Description
        Speed       = -1L
        Addresses   = @()
        Gateways    = @()
        DnsServers  = @()
        DnsSuffix   = ''
    }
    try { $fact.Speed = [long]$Nic.Speed } catch { Write-Verbose $_.Exception.Message }

    $props = $null
    try { $props = $Nic.GetIPProperties() } catch { Write-Verbose $_.Exception.Message }
    if ($null -eq $props) { return [pscustomobject]$fact }

    try {
        $fact.Addresses = @($props.UnicastAddresses |
            ForEach-Object { $_.Address } |
            Where-Object { -not $_.IsIPv6LinkLocal } |
            ForEach-Object { $_.ToString() })
    } catch { Write-Verbose $_.Exception.Message }
    try {
        $fact.Gateways = @($props.GatewayAddresses |
            ForEach-Object { $_.Address.ToString() } |
            Where-Object { $_ -ne '0.0.0.0' -and $_ -ne '::' })
    } catch { Write-Verbose $_.Exception.Message }
    try {
        $fact.DnsServers = @($props.DnsAddresses | ForEach-Object { $_.ToString() })
    } catch { Write-Verbose $_.Exception.Message }
    try { $fact.DnsSuffix = [string]$props.DnsSuffix } catch { Write-Verbose $_.Exception.Message }

    return [pscustomobject]$fact
}

function Get-InterfaceMetric {
    param([string]$Alias)
    if (-not (Get-Command Get-NetIPInterface -ErrorAction SilentlyContinue)) { return $null }
    try {
        $row = Get-NetIPInterface -InterfaceAlias $Alias -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1
        if ($row) { return $row.InterfaceMetric }
    } catch {
        Write-Verbose ("metric {0}: {1}" -f $Alias, $_.Exception.Message)
    }
    return $null
}

# --- arguments --------------------------------------------------------------
# Ahead of the preflight: a bad argument is a bad argument on every platform,
# and CONTRIBUTING.md puts usage errors before any preflight check.
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
$onlyGiven = $PSBoundParameters.ContainsKey('Only')

function Test-Want {
    param([string]$Id)
    return ($selected -contains $Id)
}

if ($Probe -and $Probe -notmatch '^([A-Za-z0-9._-]{1,253}|\[[0-9A-Fa-f:.]+\])$') {
    Write-Err "-Probe takes a host name or address (letters, digits, '.', '_', '-', or [IPv6]); got: $Probe"
    exit 3
}
if ($Port -lt 1 -or $Port -gt 65535) {
    Write-Err "-Port must be between 1 and 65535; got: $Port"
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
    Write-Host "net_doctor: $Action" -ForegroundColor White
}

# Read once and shared by interfaces, routes, dns and probe.
$facts = @()
try {
    $facts = @([System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object {
            $_.OperationalStatus -eq [System.Net.NetworkInformation.OperationalStatus]::Up -and
            $_.NetworkInterfaceType -ne [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback
        } |
        ForEach-Object { Get-NicFact -Nic $_ })
} catch {
    Write-Info "could not enumerate network adapters ($($_.Exception.Message))"
}

# --- interfaces --------------------------------------------------------------
if (Test-Want 'interfaces') {
    Write-Section 'interfaces'
    if ($facts.Count -eq 0) {
        Write-Warn 'no network adapter is up'
        Write-Detail -Always 'check the cable, Wi-Fi or airplane mode; ncpa.cpl lists disabled adapters'
    }
    foreach ($fact in $facts) {
        Write-Info ('{0} [{1}] {2}, {3}' -f $fact.Name, $fact.Kind, $fact.Description, (Format-LinkSpeed -BitsPerSecond $fact.Speed))
        if ($fact.Addresses.Count -eq 0) {
            Write-Detail 'no global address'
        }
        foreach ($address in $fact.Addresses) {
            Write-Detail $address
        }
        # 169.254/16 is what Windows assigns itself when DHCP never answered.
        $leased = @($fact.Addresses | Where-Object { $_ -notlike '169.254.*' -and $_ -match '^\d+\.' })
        $selfAssigned = @($fact.Addresses | Where-Object { $_ -like '169.254.*' })
        if ($fact.Kind -eq 'physical' -and $selfAssigned.Count -gt 0 -and $leased.Count -eq 0) {
            Write-Warn ('{0} has only a self-assigned 169.254 address: DHCP did not answer' -f $fact.Name)
            Write-Detail -Always 'ipconfig /renew, or check the network it is plugged into'
        }
    }
}

# --- routes -----------------------------------------------------------------
if (Test-Want 'routes') {
    Write-Section 'routes'
    $withGateway = @($facts | Where-Object { $_.Gateways.Count -gt 0 })
    if ($withGateway.Count -eq 0) {
        Write-Warn 'no default gateway'
        Write-Detail -Always 'nothing beyond the local subnet is reachable; route print shows the table'
    } elseif ($withGateway.Count -eq 1) {
        Write-Ok ('default gateway {0} via {1}' -f ($withGateway[0].Gateways -join ', '), $withGateway[0].Name)
    } else {
        Write-Warn ('{0} adapters carry a default gateway; the one with the lowest metric wins' -f $withGateway.Count)
        foreach ($fact in $withGateway) {
            $metric = Get-InterfaceMetric -Alias $fact.Name
            $metricText = ''
            if ($null -ne $metric) { $metricText = " (InterfaceMetric $metric)" }
            Write-Detail -Always ('{0} [{1}] via {2}{3}' -f $fact.Name, $fact.Kind, ($fact.Gateways -join ', '), $metricText)
        }
        Write-Detail -Always 'a VPN that should carry everything needs the lowest metric; Get-NetIPInterface shows them all'
    }
}

# --- dns --------------------------------------------------------------------
if (Test-Want 'dns') {
    Write-Section 'dns'
    foreach ($fact in $facts) {
        $suffix = ''
        if ($fact.DnsSuffix) { $suffix = " (suffix $($fact.DnsSuffix))" }
        if ($fact.DnsServers.Count -eq 0) {
            if ($fact.Kind -eq 'physical') {
                Write-Warn ('{0} has no DNS server' -f $fact.Name)
                Write-Detail -Always 'names will not resolve through this adapter; check DHCP or the adapter IPv4 settings'
            } else {
                Write-Info ('{0}: no DNS server{1}' -f $fact.Name, $suffix)
            }
            continue
        }
        Write-Info ('{0}: {1}{2}' -f $fact.Name, ($fact.DnsServers -join ', '), $suffix)
    }
    if ($facts.Count -gt 0 -and -not $Probe) {
        Write-Detail 'no lookups made; -Probe HOST asks every server above separately'
    }
}

# --- proxy ------------------------------------------------------------------
if (Test-Want 'proxy') {
    Write-Section 'proxy'
    $inetKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $observed = @{
        WinInetEnabled = ((Get-RegistryValueSafe -Path $inetKey -Name 'ProxyEnable') -eq 1)
        WinInetServer  = [string](Get-RegistryValueSafe -Path $inetKey -Name 'ProxyServer')
        AutoConfigUrl  = [string](Get-RegistryValueSafe -Path $inetKey -Name 'AutoConfigURL')
        HttpProxy      = Get-ProxyVariable -Name 'HTTP_PROXY'
        HttpsProxy     = Get-ProxyVariable -Name 'HTTPS_PROXY'
        AllProxy       = Get-ProxyVariable -Name 'ALL_PROXY'
        NoProxy        = Get-ProxyVariable -Name 'NO_PROXY'
        GitProxy       = [string](Get-GitConfigValue -Key 'http.proxy')
    }
    $override = [string](Get-RegistryValueSafe -Path $inetKey -Name 'ProxyOverride')

    if ($observed.WinInetEnabled) {
        Write-Info ('WinINET proxy: on, {0}' -f (Hide-UrlCredential -Url $observed.WinInetServer))
        if ($override) { Write-Detail "bypass: $override" }
    } else {
        Write-Info 'WinINET proxy: off'
    }
    if ($observed.AutoConfigUrl) {
        Write-Info ('PAC script: {0}' -f (Hide-UrlCredential -Url $observed.AutoConfigUrl))
    }
    # Only the proxy variables are printed, and only after masking. No other
    # environment value ever reaches the output.
    foreach ($pair in @(
            @('HTTP_PROXY', $observed.HttpProxy), @('HTTPS_PROXY', $observed.HttpsProxy),
            @('ALL_PROXY', $observed.AllProxy), @('NO_PROXY', $observed.NoProxy))) {
        if ($pair[1]) { Write-Detail ('{0}={1}' -f $pair[0], (Hide-UrlCredential -Url $pair[1])) }
    }
    if ($observed.GitProxy) {
        Write-Detail ('git http.proxy={0}' -f (Hide-UrlCredential -Url $observed.GitProxy))
    }

    $proxyFindings = @(Get-ProxyFinding -Observed $observed)
    foreach ($finding in $proxyFindings) {
        if ($finding.Level -eq 'warn') { Write-Warn $finding.Message } else { Write-Info $finding.Message }
    }
    if (@($proxyFindings | Where-Object { $_.Level -eq 'warn' }).Count -eq 0) {
        Write-Ok 'proxy settings agree'
    }
}

# --- hosts ------------------------------------------------------------------
if (Test-Want 'hosts') {
    Write-Section 'hosts'
    if (-not $HostsFile) {
        # String concatenation, not Join-Path: on a machine with no system
        # directory Join-Path refuses the empty string and the report would
        # stop here instead of saying the file is not readable.
        $HostsFile = [Environment]::GetFolderPath('System') + '\drivers\etc\hosts'
    }
    $hostLines = $null
    try {
        $hostLines = [IO.File]::ReadAllLines($HostsFile)
    } catch {
        Write-Warn "cannot read $HostsFile ($($_.Exception.Message))"
    }
    if ($null -ne $hostLines) {
        $entries = @(Get-HostsEntry -Lines $hostLines)
        if ($entries.Count -eq 0) {
            Write-Ok "$HostsFile has no entries"
        } else {
            Write-Info ('{0} entr{1} in {2}' -f $entries.Count, $(if ($entries.Count -eq 1) { 'y' } else { 'ies' }), $HostsFile)
            foreach ($entry in ($entries | Select-Object -First 20)) {
                Write-Detail ('{0,-16} {1}' -f $entry.Address, ($entry.Names -join ' '))
            }
            if ($entries.Count -gt 20) { Write-Detail ('({0} more)' -f ($entries.Count - 20)) }
            Write-Detail 'an entry here wins over DNS; a stale one sends the name to an old address'
        }
    }
}

# --- listen -----------------------------------------------------------------
if (Test-Want 'listen') {
    Write-Section 'listen'
    if ($SkipListen) {
        Write-Skip 'skipped (-SkipListen)'
    } elseif (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
        Write-Skip 'Get-NetTCPConnection is not available here; netstat -ano lists the same'
    } else {
        $listeners = @()
        try {
            $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop |
                Sort-Object -Property LocalPort, LocalAddress)
        } catch {
            Write-Info "could not list listening ports ($($_.Exception.Message))"
        }
        # One Get-Process per owning process, not per socket.
        $processNames = @{}
        $shown = 0
        foreach ($connection in $listeners) {
            if ($shown -ge 50) { break }
            $owningId = [int]$connection.OwningProcess
            if (-not $processNames.ContainsKey($owningId)) {
                $processName = '?'
                try {
                    $processName = (Get-Process -Id $owningId -ErrorAction Stop).ProcessName
                } catch {
                    Write-Verbose $_.Exception.Message
                }
                $processNames[$owningId] = $processName
            }
            $address = [string]$connection.LocalAddress
            $endpoint = '{0}:{1}' -f $address, $connection.LocalPort
            if ($address -match ':') { $endpoint = '[{0}]:{1}' -f $address, $connection.LocalPort }
            $scope = ''
            if ($address -eq '0.0.0.0' -or $address -eq '::') { $scope = '  all interfaces' }
            elseif ($address -like '127.*' -or $address -eq '::1') { $scope = '  loopback' }
            Write-Detail ('tcp {0,-28} pid {1,-6} {2}{3}' -f $endpoint, $owningId, $processNames[$owningId], $scope)
            $shown++
        }
        if ($listeners.Count -gt 50) { Write-Detail ('({0} more)' -f ($listeners.Count - 50)) }
        if ($listeners.Count -gt 0) {
            Write-Info ('{0} listening TCP socket(s); "all interfaces" ones are reachable from the network unless the firewall says no' -f $listeners.Count)
        }
    }
}

# --- probe ------------------------------------------------------------------
if ((Test-Want 'probe') -and ($Probe -or $onlyGiven)) {
    Write-Section 'probe'
    if (-not $Probe) {
        Write-Info 'pass -Probe HOST to resolve and connect to a host'
    } else {
        $target = $Probe.Trim('[', ']')
        $addresses = @()
        try {
            $addresses = @([System.Net.Dns]::GetHostAddresses($target))
            Write-Ok ('{0} resolves to {1}' -f $target, (($addresses | ForEach-Object { $_.ToString() }) -join ', '))
        } catch {
            Write-Warn "$target does not resolve ($($_.Exception.Message))"
        }

        # Ask each configured server on its own: with two servers and one of
        # them dead, the system resolver still answers - slowly, every other
        # time - and nothing says which one is the problem.
        $literal = $null
        $isLiteral = [System.Net.IPAddress]::TryParse($target, [ref]$literal)
        $servers = @($facts | ForEach-Object { $_.DnsServers } | Select-Object -Unique)
        if ($isLiteral) {
            Write-Detail 'an address, not a name: no DNS servers to ask'
        } elseif (-not (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)) {
            Write-Skip 'Resolve-DnsName is not available here; per-server lookups skipped'
        } else {
            foreach ($server in $servers) {
                try {
                    $null = Resolve-DnsName -Name $target -Server $server -DnsOnly -QuickTimeout -ErrorAction Stop
                    Write-Ok "DNS server $server answers for $target"
                } catch {
                    Write-Warn "DNS server $server did not answer for $target ($($_.Exception.Message))"
                }
            }
        }

        if ($addresses.Count -gt 0) {
            $remote = $addresses[0]
            $client = $null
            $timer = [Diagnostics.Stopwatch]::StartNew()
            try {
                $client = New-Object System.Net.Sockets.TcpClient -ArgumentList $remote.AddressFamily
                $connected = $client.ConnectAsync($remote, $Port).Wait(3000)
                $timer.Stop()
                if ($connected -and $client.Connected) {
                    Write-Ok ('TCP {0}:{1} connected in {2} ms (nothing sent)' -f $remote, $Port, $timer.ElapsedMilliseconds)
                } else {
                    Write-Warn ('TCP {0}:{1} did not answer within 3 s' -f $remote, $Port)
                    Write-Detail -Always 'a firewall that drops rather than refuses looks like this; so does a proxy-only network'
                }
            } catch {
                $timer.Stop()
                # Wait() wraps the socket error twice (a method-invocation error
                # around an AggregateException); the innermost one says why.
                $reason = $_.Exception.GetBaseException().Message
                Write-Warn ('TCP {0}:{1} failed after {2} ms ({3})' -f $remote, $Port, $timer.ElapsedMilliseconds, $reason)
            } finally {
                if ($client) { $client.Close() }
            }
        }
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
