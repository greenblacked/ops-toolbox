# A Linux host cannot reach the network or resolve names

<!-- markdownlint-disable MD033 -->

**When to use:** a Linux host cannot reach anything, cannot resolve names, or
cannot be reached, and you need to find out whether the cause is the link,
routing, DNS or a firewall before you change anything.

## Symptoms

- The package manager, `curl` or `git` cannot reach any server.
- Names do not resolve, while connecting to an IP address may still work.
- `sudo` takes several seconds before it prompts: the machine's own hostname
  does not resolve.
- A service on the host is not reachable from outside.

## Before you start

- A shell on the host. The report needs no `sudo`.
- Linux. `net_doctor.sh` is exit `2` anywhere else.
- The script. Work from a clone of the repository, or copy
  `linux/net_doctor.sh` onto the host; it works on its own. A host with no
  network cannot clone, so copy it over a console, a USB stick or whatever
  path you still have. See [Installation and usage](../getting-started/usage.md).
- More on the Linux scripts and their caveats is on the
  [Linux page](../platforms/linux.md).

## Report

<span class="stage stage-report">read-only</span>

!!! report "Nothing changes in this step"
    `net_doctor.sh` only reads state. With `--probe` it also looks the host
    up and opens at most two TCP connections to it, on 443 and then 80;
    nothing else leaves the machine.

Start with the local picture, then add a probe to a host that should
answer:

```{ .bash .rpt-report title="Report" }
./linux/net_doctor.sh
./linux/net_doctor.sh --probe example.com
```

| Option | Meaning |
| --- | --- |
| `--probe HOST` | Resolve `HOST`, then try a TCP connection to its address on 443, falling back to 80, five seconds each. Default: no probe. |
| `--skip-listen` | Do not list listening TCP and UDP sockets. |
| `--quiet` | Hide the `[ ok ]`, `[info]` and `[skip]` lines. See the note in Verify about what still prints. |

The report has five sections, always in this order. Read them top down: a
problem higher up explains the ones below it.

| Section | What it shows | Warnings it can print |
| --- | --- | --- |
| interfaces | Every non-loopback interface, its state, IPv4 addresses and MAC. An interface that is up (or `unknown`) is `[ ok ]`; one that is down is an `[info]` line, not a warning. | None. |
| routes | The default IPv4 route, then the default IPv6 route (reported, never graded). | `no default IPv4 route`, with the hint `ip route · or this is a container with no uplink`. |
| dns | The `nameserver` and `search` lines of `/etc/resolv.conf`, then whether this machine's hostname resolves. `nameserver 127.0.0.53` is reported as the systemd-resolved stub, with a hint to run `resolvectl status` for the real upstream resolvers when `resolvectl` is installed. | `no nameserver in /etc/resolv.conf`. `hostname NAME does not resolve`, with the note that `sudo` delays follow and an `/etc/hosts` line that would fix it. |
| listen | How many TCP and UDP sockets are listening, and the `ss -tuln` table. | None. |
| probe | Only with `--probe`. Whether the host resolves (`getent ahostsv4`, then `getent hosts`), then whether a TCP connection opens. | `could not resolve HOST`, with the hint `getent ahostsv4 HOST`. `no TCP path to ADDRESS on 443 or 80`, noting that this may be expected in a container with no uplink. |

The run ends with a summary line of `ok`, `warn` and `skip` counts and a
pointer to `hardening_audit.sh --only network` for the firewall.

!!! warning "Exit 0 is not a health verdict"
    `net_doctor.sh` exits `0` whenever the report printed, with or without
    warnings. Exit `2` means not Linux and `3` bad arguments. Read the
    `[warn]` lines and the summary count, not the exit code.

### Decide

| What the report shows | Where the problem is |
| --- | --- |
| The interface is down, or `no default IPv4 route` | The link or the gateway: cable, Wi-Fi, DHCP, a VM or container network with no uplink. Fix that first; nothing below can work without it. |
| A route is there, but `could not resolve HOST` or `no nameserver` | DNS. Check the nameservers the dns section lists; behind `127.0.0.53`, check `resolvectl status`. |
| The host resolves, but `no TCP path to ADDRESS on 443 or 80` | Something between this host and that address drops the connection: a local firewall, a proxy you have to use, or an upstream filter. |
| `hostname NAME does not resolve` | Only the local name. This is the slow `sudo`; it does not affect reaching other hosts. |
| Everything here is clean, but outside clients cannot reach a service | Check the listen section: a service bound only to `127.0.0.1` is not reachable from outside. Then the firewall. |

For the local firewall, the next read-only report is:

```{ .bash .rpt-report title="Firewall posture" }
./linux/hardening_audit.sh --only network
```

Its network group lists sockets listening on all interfaces and says which
host firewall is active (`ufw`, `firewalld`, `nftables` or `iptables`).
Reading the rules needs root, so without `sudo` it may report that it cannot
tell. It reports; it does not change the firewall, and it does not say
whether a rule blocks the connection you are debugging. Its other groups are
`ssh`, `accounts`, `files`, `updates` and `kernel`.

## Preview

<span class="stage stage-preview">dry run</span>

!!! preview "Nothing to preview: this runbook has no scripted change"
    `net_doctor.sh` and `hardening_audit.sh` have no mode that changes
    anything, so neither has a dry run. The report above is the whole of
    what the toolbox does here.

## Apply

<span class="stage stage-apply">changes things</span>

!!! apply "Not scripted by this repository"
    The fixes are yours to run. Under some warnings the script prints a
    one-line suggestion; read it, decide whether it fits this host, and keep
    a copy of any file before you edit it.

The suggestions it prints are:

- For `no nameserver`: appending a `nameserver` line to `/etc/resolv.conf`.
- For a hostname that does not resolve: appending a `127.0.1.1 NAME` line to
  `/etc/hosts`.

General Linux behaviour, not a script feature: on many hosts
`/etc/resolv.conf` is written by a resolver or network service
(systemd-resolved, NetworkManager, a DHCP client), and a line you append by
hand is overwritten the next time that service rewrites the file. On such a
host, change the DNS setting in the service that owns the file.

## Verify

<span class="stage stage-report">read-only</span>

Run the same probe again, quiet:

```{ .bash .rpt-report title="Verify" }
./linux/net_doctor.sh --probe example.com --quiet --skip-listen
```

With `--quiet` the section headings and the summary line still print, and so
does the listening-socket table unless you add `--skip-listen`. Success is
no `[warn]` line and `0 warn` in the summary. Then run the real command that
failed (`curl`, the package manager, `git`).

## Roll back

`net_doctor.sh` and `hardening_audit.sh` changed nothing, so they have
nothing to roll back. Undo your own edits from the copies you kept, for
example by putting back the saved `/etc/resolv.conf` or `/etc/hosts`.

## Related

- [Linux platform page](../platforms/linux.md)
- [A TLS certificate is expired or about to expire](tls-certificate-expiring.md):
  once the network answers, `tls_expiry.sh` checks the certificate the
  server presents.
- [`linux/` folder README](https://github.com/greenblacked/ops-toolbox/blob/master/linux/README.md)
- [Scripts overview](../scripts/index.md)

<!-- markdownlint-enable MD033 -->
