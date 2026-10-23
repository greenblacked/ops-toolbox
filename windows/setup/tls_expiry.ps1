<#
.SYNOPSIS
    Read-only certificate expiry check for files, TLS endpoints and the personal stores.

.DESCRIPTION
    The Windows counterpart of linux/tls_expiry.sh: "will something expire on
    me next month", with an exit code a scheduled task or CI job can act on.
    Three sources, any combination:

      -File      PEM, CRT, CER or DER files - the first certificate of a
                 bundle, which is the leaf in every bundle a server is given
      -HostName  TLS endpoints, host or host:port (443 by default); the leaf
                 the server presents is read from the handshake
      -Store     the Personal ("My") stores of the current user and of the
                 machine, where Windows keeps client-authentication,
                 code-signing, RDP and WinRM HTTPS certificates

    Trust-anchor stores (Root, CA, TrustedPublisher) are never scanned. Their
    contents are not yours to renew, and paging on a vendor root that expires
    next year is noise - the same reason linux/tls_expiry.sh does not scan
    /etc/ssl/certs.

    For -HostName the handshake has to complete even when the certificate is
    expired or does not match, or there is nothing to read. So each
    connection gets its own validation callback that records what was wrong
    and accepts the certificate; the process-wide callback is never touched.
    No application data is sent: the connection is closed as soon as the
    certificate has been read. A name mismatch or an untrusted chain is
    reported as its own [warn], separately from the expiry verdict.

    No private key is read or copied; for a store certificate only the
    HasPrivateKey flag is shown. A file that cannot be parsed and a host that
    cannot be reached are [FAIL], not skipped: failing to prove a certificate
    is valid is not a pass.

    Argument checks run before the Windows preflight. There is no -DryRun
    because there is nothing to preview; -Action takes one value, 'report',
    which is the read-only default the contract checks look for.

.PARAMETER File
    Certificate files to check. A comma-separated list works too.

.PARAMETER HostName
    Endpoints to check, as host or host:port; an IPv6 address goes in
    brackets. A comma-separated list works too. (Not -Host: that name belongs
    to PowerShell's own $Host.)

.PARAMETER Store
    Also check CurrentUser\My and LocalMachine\My.

.PARAMETER Days
    Warn when a certificate expires within this many days, 1 to 3650.
    Default 30.

.PARAMETER FailOn
    'fail' (default) exits 1 on an expired, unreadable or unreachable
    certificate; 'warn' also on one expiring within -Days; 'never' always
    exits 0. linux/tls_expiry.sh spells the first value 'expired'.

.EXAMPLE
    .\tls_expiry.ps1 -File C:\certs\api.pem
    .\tls_expiry.ps1 -HostName git.internal,registry.internal:5000 -Days 14
    .\tls_expiry.ps1 -Store -FailOn warn
    .\tls_expiry.ps1 -File .\leaf.crt -HostName example.com -Store -Quiet

.NOTES
    Exit codes, matching linux/tls_expiry.sh:
      0  nothing at or above -FailOn
      1  one or more findings at or above -FailOn
      2  not Windows
      3  bad arguments: nothing to check, a -File that does not exist, a
         malformed -HostName, -Days out of range, a bad -FailOn
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('report')]
    [string]$Action = 'report',

    [string[]]$File = @(),

    [string[]]$HostName = @(),

    [switch]$Store,

    # Range-checked by hand below, like -FailOn: a binding failure under
    # 'pwsh -File' exits 1, and a bad value here is a usage error (3).
    [int]$Days = 30,

    [string]$FailOn = 'fail',

    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$script:QuietMode = [bool]$Quiet
$script:PassCount = 0
$script:WarnCount = 0
$script:FailCount = 0
$script:SkipCount = 0

# The grammar of linux/tls_expiry.sh: two-space indent, a six-wide verdict,
# detail on dimmed lines nine spaces in.
function Write-Verdict {
    param([string]$Level, [string]$Message, [string[]]$Detail = @())
    switch ($Level) {
        'pass' { $script:PassCount++; $tag = '[pass]'; $colour = 'Green' }
        'warn' { $script:WarnCount++; $tag = '[warn]'; $colour = 'Yellow' }
        'skip' { $script:SkipCount++; $tag = '[skip]'; $colour = 'DarkGray' }
        default { $script:FailCount++; $tag = '[FAIL]'; $colour = 'Red' }
    }
    if ($script:QuietMode -and ($Level -eq 'pass' -or $Level -eq 'skip')) { return }
    Write-Host "  $tag $Message" -ForegroundColor $colour
    foreach ($line in $Detail) { Write-Host "         $line" -ForegroundColor DarkGray }
}
function Write-Err  { param([string]$Message) Write-Host "[err ] $Message" -ForegroundColor Red }
function Write-Group { param([string]$Name) Write-Host ''; Write-Host "== $Name ==" -ForegroundColor White }

# --- pure helpers -----------------------------------------------------------
# Plain data in, plain data out, so windows/tests/contract.ps1 can lift each
# one out of this file and test it with fixtures.

# expired when NotAfter has passed (or is now), warn when the whole days left
# are within -Days, else pass. DaysLeft is negative once expired.
function Get-CertExpiryVerdict {
    param(
        [datetime]$NotAfter,
        [datetime]$Now,
        [int]$Days
    )
    $daysLeft = [int][math]::Floor(($NotAfter - $Now).TotalDays)
    $level = 'pass'
    if ($NotAfter -le $Now) {
        $level = 'expired'
    } elseif ($daysLeft -le $Days) {
        $level = 'warn'
    }
    return [pscustomobject]@{ Level = $level; DaysLeft = $daysLeft }
}

# The DER bytes of the FIRST certificate in a file's bytes. PEM armour is
# found anywhere in the text, so comments or a key before it do not matter;
# bytes with no armour at all are taken to be DER already and returned as
# they are. Armour without a CERTIFICATE block (a lone private key) is $null.
# Done by hand rather than with the PEM loaders of newer .NET, which Windows
# PowerShell 5.1 does not have.
function ConvertFrom-PemText {
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -eq 0) { return $null }
    $text = [Text.Encoding]::ASCII.GetString($Bytes)
    $m = [regex]::Match($text, '-----BEGIN CERTIFICATE-----(?<body>[A-Za-z0-9+/=\s]+?)-----END CERTIFICATE-----')
    if ($m.Success) {
        $body = $m.Groups['body'].Value -replace '\s', ''
        # The comma keeps the byte array whole instead of letting the
        # pipeline unroll it one byte at a time.
        return , [Convert]::FromBase64String($body)
    }
    if ($text.Contains('-----BEGIN ')) { return $null }
    return , $Bytes
}

# 'host', 'host:port' or '[v6]:port' to { Host, Port }, or $null when it is
# not one of those.
function ConvertFrom-EndpointText {
    param([string]$Text)
    $m = [regex]::Match($Text, '^(?<host>[A-Za-z0-9._-]{1,253}|\[[0-9A-Fa-f:.]+\])(:(?<port>\d{1,5}))?$')
    if (-not $m.Success) { return $null }
    $port = 443
    if ($m.Groups['port'].Success) { $port = [int]$m.Groups['port'].Value }
    if ($port -lt 1 -or $port -gt 65535) { return $null }
    return [pscustomobject]@{ Host = $m.Groups['host'].Value.Trim('[', ']'); Port = $port }
}

# --- probes -----------------------------------------------------------------

function Get-CertDetail {
    param($Certificate)
    $thumb = [string]$Certificate.Thumbprint
    if ($thumb.Length -gt 8) { $thumb = $thumb.Substring(0, 8) }
    return @(
        ('subject {0}' -f $Certificate.Subject),
        ('issuer  {0}' -f $Certificate.Issuer),
        ('expires {0:yyyy-MM-dd HH:mm} UTC, thumbprint {1}...' -f $Certificate.NotAfter.ToUniversalTime(), $thumb))
}

function Write-CertVerdict {
    param([string]$Label, $Certificate, [string[]]$Extra = @())
    $verdict = Get-CertExpiryVerdict -NotAfter $Certificate.NotAfter -Now (Get-Date) -Days $Days
    $detail = @(Get-CertDetail -Certificate $Certificate) + $Extra
    switch ($verdict.Level) {
        'expired' { Write-Verdict -Level 'fail' -Message ('{0}: expired {1} day(s) ago' -f $Label, -$verdict.DaysLeft) -Detail $detail }
        'warn' { Write-Verdict -Level 'warn' -Message ('{0}: expires in {1} day(s), within {2}' -f $Label, $verdict.DaysLeft, $Days) -Detail $detail }
        default { Write-Verdict -Level 'pass' -Message ('{0}: expires in {1} days' -f $Label, $verdict.DaysLeft) -Detail $detail }
    }
}

function Test-CertificateFile {
    param([string]$Path)
    $der = $null
    try {
        $der = ConvertFrom-PemText -Bytes ([IO.File]::ReadAllBytes($Path))
    } catch {
        Write-Verdict -Level 'fail' -Message "${Path}: not readable ($($_.Exception.Message))"
        return
    }
    if ($null -eq $der) {
        Write-Verdict -Level 'fail' -Message "${Path}: not a certificate (no CERTIFICATE block)"
        return
    }
    try {
        $certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (, $der)
    } catch {
        Write-Verdict -Level 'fail' -Message "${Path}: not a certificate ($($_.Exception.GetBaseException().Message))"
        return
    }
    Write-CertVerdict -Label $Path -Certificate $certificate
}

function Test-CertificateEndpoint {
    param($Endpoint)
    $label = '{0}:{1}' -f $Endpoint.Host, $Endpoint.Port
    $tcp = $null
    $tls = $null
    # A list, so the callback below can record into it: it runs inside the
    # handshake and has no other way to hand anything back. It is scoped to
    # this one SslStream. Its fourth argument is the SslPolicyErrors value;
    # the other three (sender, certificate, chain) are not needed here.
    $policyErrors = New-Object System.Collections.ArrayList
    $callback = {
        [void]$policyErrors.Add($args[3])
        return $true
    }.GetNewClosure()
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        if (-not $tcp.ConnectAsync($Endpoint.Host, $Endpoint.Port).Wait(5000)) {
            Write-Verdict -Level 'fail' -Message "${label}: no answer within 5 s"
            return
        }
        $tcp.ReceiveTimeout = 5000
        $tcp.SendTimeout = 5000
        $tls = New-Object System.Net.Security.SslStream -ArgumentList $tcp.GetStream(), $false, ([System.Net.Security.RemoteCertificateValidationCallback]$callback)
        # PowerShell 7 lets the OS pick the protocol. Windows PowerShell 5.1
        # can default to protocols servers no longer accept, so it is told.
        $protocols = [System.Security.Authentication.SslProtocols]::None
        if ($PSVersionTable.PSEdition -ne 'Core') {
            $protocols = [System.Security.Authentication.SslProtocols]'Tls12, Tls11, Tls'
        }
        $tls.AuthenticateAsClient($Endpoint.Host, $null, $protocols, $false)
        if ($null -eq $tls.RemoteCertificate) {
            Write-Verdict -Level 'fail' -Message "${label}: the server presented no certificate"
            return
        }
        $certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $tls.RemoteCertificate
        Write-CertVerdict -Label $label -Certificate $certificate
        foreach ($errors in $policyErrors) {
            if ($errors -band [System.Net.Security.SslPolicyErrors]::RemoteCertificateNameMismatch) {
                Write-Verdict -Level 'warn' -Message "${label}: the certificate does not name $($Endpoint.Host) (name mismatch)"
            }
            if ($errors -band [System.Net.Security.SslPolicyErrors]::RemoteCertificateChainErrors) {
                Write-Verdict -Level 'warn' -Message "${label}: the chain is not trusted by this machine"
            }
        }
    } catch {
        Write-Verdict -Level 'fail' -Message ('{0}: {1}' -f $label, $_.Exception.GetBaseException().Message)
    } finally {
        if ($tls) { $tls.Dispose() }
        if ($tcp) { $tcp.Close() }
    }
}

function Test-CertificateStore {
    param([string]$Location)
    $storeLabel = '{0}\My' -f $Location
    $x509 = $null
    try {
        $x509 = New-Object System.Security.Cryptography.X509Certificates.X509Store -ArgumentList 'My', $Location
        # OpenExistingOnly: never create a store just to look in it.
        $x509.Open([System.Security.Cryptography.X509Certificates.OpenFlags]'ReadOnly, OpenExistingOnly')
        $certificates = @($x509.Certificates)
        if ($certificates.Count -eq 0) {
            Write-Verdict -Level 'skip' -Message "${storeLabel}: empty"
            return
        }
        foreach ($certificate in ($certificates | Sort-Object -Property NotAfter)) {
            $keyNote = 'no private key'
            if ($certificate.HasPrivateKey) { $keyNote = 'has a private key' }
            Write-CertVerdict -Label ('{0} {1}' -f $storeLabel, $certificate.Subject) -Certificate $certificate -Extra @($keyNote)
        }
    } catch {
        Write-Verdict -Level 'skip' -Message ('{0}: not readable ({1})' -f $storeLabel, $_.Exception.GetBaseException().Message)
    } finally {
        if ($x509) { $x509.Close() }
    }
}

# --- arguments --------------------------------------------------------------
# Ahead of the preflight, as in every script here. Both lists are split on
# commas, for the reason stay_fresh.ps1 gives: 'pwsh -File' hands
# '-File a.pem,b.pem' over as one string.
$files = @($File | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$hostTexts = @($HostName | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

if ($files.Count -eq 0 -and $hostTexts.Count -eq 0 -and -not $Store) {
    Write-Err 'nothing to check: give -File, -HostName or -Store (Get-Help .\tls_expiry.ps1 shows the usage)'
    exit 3
}
if ($FailOn -notin @('fail', 'warn', 'never')) {
    Write-Err "-FailOn must be fail, warn or never, got: $FailOn"
    exit 3
}
if ($Days -lt 1 -or $Days -gt 3650) {
    Write-Err "-Days must be between 1 and 3650; got: $Days"
    exit 3
}
foreach ($path in $files) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Err "-File not found: $path"
        exit 3
    }
}
$endpoints = @()
foreach ($text in $hostTexts) {
    $endpoint = ConvertFrom-EndpointText -Text $text
    if ($null -eq $endpoint) {
        Write-Err "-HostName takes host or host:port (letters, digits, '.', '_', '-', or [IPv6]); got: $text"
        exit 3
    }
    $endpoints += $endpoint
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
    Write-Host ("tls_expiry: $Action, warning within $Days day(s)") -ForegroundColor White
}

if ($files.Count -gt 0) {
    Write-Group 'files'
    foreach ($path in $files) { Test-CertificateFile -Path $path }
}
if ($endpoints.Count -gt 0) {
    Write-Group 'hosts'
    foreach ($endpoint in $endpoints) { Test-CertificateEndpoint -Endpoint $endpoint }
}
if ($Store) {
    Write-Group 'stores'
    foreach ($location in @('CurrentUser', 'LocalMachine')) { Test-CertificateStore -Location $location }
}

Write-Host ''
Write-Host '== summary ==' -ForegroundColor White
Write-Host ('  {0} pass  {1} warn  {2} fail  {3} skip' -f $script:PassCount, $script:WarnCount, $script:FailCount, $script:SkipCount)

switch ($FailOn.ToLowerInvariant()) {
    'never' { exit 0 }
    'warn' { if (($script:WarnCount + $script:FailCount) -gt 0) { exit 1 } }
    default { if ($script:FailCount -gt 0) { exit 1 } }
}
exit 0
