# Windows setup

[Ops Toolbox](../../README.md) / **Windows setup**

Capture what a Windows machine has installed, keep it under version control,
reproduce it elsewhere — and then keep it healthy.

| File | Purpose |
| --- | --- |
| [`winget_bootstrap.ps1`](winget_bootstrap.ps1) | `export` / `list` / `check` / `import` / `diff` over the winget package list |
| [`winget_configure.ps1`](winget_configure.ps1) | `validate` / `show` / `test` / `apply` over [`configuration.winget`](configuration.winget), the curated machine definition |
| [`status.ps1`](status.ps1) | One-screen verdict (`-Only` / `-ListSections`). |
| [`stay_fresh.ps1`](stay_fresh.ps1) | Recurring maintenance: winget upgrades, `wsl --update`, pending-reboot report |
| [`workstation_doctor.ps1`](workstation_doctor.ps1) | Read-only health report: BitLocker, Defender, pending reboot, disk, WSL, execution policy, disk health, uptime, patch age, memory (`-Only` / `-ListSections`) |
| [`net_doctor.ps1`](net_doctor.ps1) | Read-only network report: adapters, default routes, DNS, proxy, hosts file, listening ports, opt-in probe |
| [`tls_expiry.ps1`](tls_expiry.ps1) | Read-only certificate expiry check with exit codes: PEM/CER files, TLS endpoints, the personal certificate stores |
| [`hardening_audit.ps1`](hardening_audit.ps1) | Read-only security audit with exit codes: firewall, SMBv1, RDP/NLA, UAC, autologon, Secure Boot/TPM, LSA protection, Defender, logging, patch age; prints each fix |
| [`path_doctor.ps1`](path_doctor.ps1) | PATH report (duplicates, dead and relative entries, REG_SZ values, length, shadowed commands) and a backed-up `clean` of the user PATH |
| [`dev_env_doctor.ps1`](dev_env_doctor.ps1) | Read-only toolchain check: long paths, git line endings and symlinks, virtualization, clock skew, HOME, docker context |
| [`ssh_client_doctor.ps1`](ssh_client_doctor.ps1) | Read-only OpenSSH client check: key access lists, the ssh-agent service, Git's bundled ssh, IdentityFile paths |
| [`choco_bootstrap.ps1`](choco_bootstrap.ps1) | The same five verbs over a Chocolatey `packages.config` |
| [`configuration.winget`](configuration.winget) | The curated list itself: what a workstation should have, in six commentable groups |
| [`winget-packages.example.json`](winget-packages.example.json) | A worked example of the export format, for reading before you have one |
| [`choco-packages.example.config`](choco-packages.example.config) | The same, in Chocolatey's own `packages.config` format |
| `winget-packages.json` | Written by `export`; commit it |

The scripts split the same way their Unix counterparts do: one builds the
machine, one captures and restores it, one keeps it current, one only looks.
`status.ps1` is the one-screen verdict; `workstation_doctor.ps1` is the long
report. Nothing in either changes anything, which is why they are the safe
first things to run on a machine you have just been handed.

The distinction between the first two is the one worth reading twice.
`configuration.winget` is the *intent*: a short curated list, reviewed like
code, that says what a workstation should have. `winget-packages.json` is the
*fact*: everything one particular box happens to have, exported from it. Use
`winget_configure.ps1` to build a machine and `winget_bootstrap.ps1` to record
one. Neither replaces the other.

## Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [winget_bootstrap.ps1](#winget_bootstrapps1)
- [stay_fresh.ps1](#stay_freshps1)
- [workstation_doctor.ps1](#workstation_doctorps1)
- [net_doctor.ps1](#net_doctorps1)
- [ssh_client_doctor.ps1](#ssh_client_doctorps1)
- [dev_env_doctor.ps1](#dev_env_doctorps1)
- [path_doctor.ps1](#path_doctorps1)
- [hardening_audit.ps1](#hardening_auditps1)
- [tls_expiry.ps1](#tls_expiryps1)
- [Testing](#testing)
- [winget_configure.ps1](#winget_configureps1)
- [choco_bootstrap.ps1](#choco_bootstrapps1)

## Requirements

| Requirement | Notes |
| --- | --- |
| **Windows 10 or 11** | Every script here exits `2` on anything else. |
| **Windows PowerShell 5.1 or PowerShell 7** | Either edition; the platform guard tests the edition too, because Windows PowerShell does not define `$IsWindows`. |
| **winget, from the Microsoft Store "App Installer"** | Needed by the two winget scripts, which exit `2` without it. `winget_configure.ps1` also needs **WinGet 1.6 or newer** — see its own [Requirements](#requirements-1) — and checks both at the point it invokes winget, so previewing a configuration still works on a machine that has neither. |
| **Chocolatey** | Only for `choco_bootstrap.ps1`, which exits `2` when `choco.exe` is not on `PATH`. It is an alternative to the winget pair, not a companion to them. |
| **An elevated shell** | Optional. `workstation_doctor.ps1` runs unelevated and says so, but BitLocker, Defender, the TPM and Secure Boot answer more fully with elevation; so do the checks in `hardening_audit.ps1` that say they need it. |

## Quick start

The read-only one first. Nothing in it changes anything, which is what makes it
the safe thing to run on a machine you have just been handed:

```powershell
.\workstation_doctor.ps1
```

It reports BitLocker, Defender, pending reboot, disk headroom, WSL, execution
policy, physical disk health, uptime, patch age and memory in one pass.

Then the two halves of package management, both in their non-destructive form.
The first compares this machine against the curated list in
[`configuration.winget`](configuration.winget) — the *intent*. The second
captures what this particular box actually has — the *fact*:

```powershell
.\winget_configure.ps1 test
.\winget_bootstrap.ps1 diff
```

`test` exits `1` when the machine has drifted from the file, and `diff` needs
an existing `winget-packages.json` to compare against — run
`.\winget_bootstrap.ps1 export` once to create it, then commit it.

## winget_bootstrap.ps1

The Windows counterpart of
[`macos-initial-setup/brewfile.sh`](../../macos-initial-setup/brewfile.sh) — same
same command and exit-code conventions, same idea. A curated install list is the *intent*;
this file is the *fact*.

### Usage

```powershell
# What has changed on this machine since the file was written?
.\winget_bootstrap.ps1 diff

# Stable package ids for inventory scripts and pipes (writes no profile file)
.\winget_bootstrap.ps1 list

# Accept those changes
.\winget_bootstrap.ps1 export -Force

# On a new machine: preview, then install what is missing
.\winget_bootstrap.ps1 import -DryRun
.\winget_bootstrap.ps1 import

# Is everything in the file present? (read-only, exits 1 if not)
.\winget_bootstrap.ps1 check
```

`-File PATH` points any verb at a different file, so you can keep more than one
profile (a work machine and a personal one, say).

The import preview lists every package the file asks winget to ensure. It does
not launch winget: even `winget export` populates source caches, which would
make a supposedly no-write dry run mutate the machine. The real import retains
winget's normal missing-package detection.

### Exit codes

Matching `brewfile.sh`, so either can be driven from the same automation:

| Code | Meaning |
| --- | --- |
| `0` | Success. For `check`: everything is installed. |
| `1` | The command failed. For `check`: something is missing. |
| `2` | Preflight failed — not Windows, or `winget` is not on `PATH`. |
| `3` | Bad arguments, or no verb given. |

### Things worth knowing

- **`export` refuses to overwrite** an existing file without `-Force`. Run
  `diff` first; that is the whole reason `diff` exists.
- **`import` uses `--no-upgrade`**, matching `brew bundle install --no-upgrade`:
  it adds what is missing and leaves what is already installed alone. It will
  not silently upgrade a pinned version.
- **Packages winget cannot identify are skipped.** Anything installed outside a
  winget source is recorded as `"unknown"` in the export and cannot be
  reinstalled from it. `export` prints how many fell into that bucket rather
  than letting you discover it on a rebuild.
- **`diff` compares sorted package ids, not raw JSON.** winget does not
  guarantee ordering between runs, so a raw file diff produces noise that is not
  really a change.

### `winget-packages.example.json`

An example of what `export` writes, committed so the format is readable without
a Windows machine to hand — the same role `Brewfile.example` plays next to
`brewfile.sh`. It lists five ids most machines want anyway (`Git.Git`,
`Microsoft.VisualStudioCode`, `Microsoft.WindowsTerminal`,
`Microsoft.PowerShell`, `7zip.7zip`), and it is a valid import file:

```powershell
.\winget_bootstrap.ps1 import -DryRun -File .\winget-packages.example.json
```

It is an example, not this repository's package list. On a real machine, run
`export` and commit what comes out; the `CreationDate` and `WinGetVersion` in
here are placeholders and mean nothing.

## stay_fresh.ps1

Recurring maintenance, and the Windows sibling of
[`linux/stay_fresh.sh`](../../linux/stay_fresh.sh) and
[`macos-initial-setup/stay_fresh.sh`](../../macos-initial-setup/stay_fresh.sh):
same shape, same exit codes, same rule that a missing tool is a note rather than
a failure.

```powershell
# See the whole run first - it changes nothing:
.\stay_fresh.ps1 -DryRun

# The usual run: everything except the upgrades, which wait for -Yes
.\stay_fresh.ps1

# The usual run, upgrades included
.\stay_fresh.ps1 -Yes

# Packages only, on a machine with no WSL worth touching
.\stay_fresh.ps1 -Yes -SkipWsl

# Run one section, or a comma-separated list of them
.\stay_fresh.ps1 -DryRun -Only Winget
.\stay_fresh.ps1 -Only Report
.\stay_fresh.ps1 -Yes -Only Winget,Wsl
```

| Step | What it runs | Needs | Skip with |
| --- | --- | --- | --- |
| winget | `source update`, then `upgrade --all --include-unknown` | `-Yes` | `-SkipWinget` |
| wsl | `wsl --update` | — | `-SkipWsl` |
| store | Nothing — prints how to update Store apps by hand | — | — |
| report | Pending-reboot registry flags, free space on `C:` | — | — |

`-Only` takes one step or a comma-separated list of them —
`-Only Winget`, `-Only Report`, `-Only Winget,Wsl` — and selects those
sections without a long inverse list of skip flags, the way
[`linux/stay_fresh.sh`](../../linux/stay_fresh.sh) `--only` does. `All` is the
unchanged default; the existing `-SkipWinget` and `-SkipWsl` still take
precedence when their section is selected. A step nobody has heard of is
rejected by name with exit `3`, rather than being quietly ignored.

Worth knowing:

- **The upgrades wait for `-Yes`.** Without it the run prints
  `skipping upgrades: pass -Yes to run them unattended, or -DryRun to see
  them` and carries on with the rest, so a bare `.\stay_fresh.ps1` is still a
  useful report — it just does not rewrite the machine.
  [`linux/stay_fresh.sh`](../../linux/stay_fresh.sh) has skipped package
  upgrades without `--yes` from the start and this had no equivalent, which
  mattered because the two are documented as counterparts: the habit learned
  on one ("just run it, it will tell me what it wants") upgraded every package
  on the box the first time it was used on the other. `-DryRun` previews the
  upgrades without `-Yes`, because a preview changes nothing.
- **`--include-unknown` is passed deliberately.** Without it, winget silently
  leaves behind every package whose installed version it cannot read, which is
  the usual reason a machine reports itself up to date and is not.
- **Microsoft Store apps are not touched.** They update on their own schedule,
  and winget's `msstore` source wants each package's agreements accepted
  interactively — an unattended run cannot honestly claim to have updated them.
  The script prints the `UpdateScanMethod` incantation instead and leaves the
  choice to a person.
- **`wsl --update` updates WSL, not what is inside it.** For the distro's own
  packages, run [`linux/stay_fresh.sh`](../../linux/stay_fresh.sh) in the distro.
- **It never reboots and never deletes.** Disk space is
  [`../cleanup/clean_disk_c.ps1`](../cleanup/clean_disk_c.ps1)'s job, which has
  its own dry run and its own opt-in flags.
- **A step that exits non-zero counts.** The run keeps going and the script
  exits `1` at the end, the same way the Linux version does. Note that winget
  exits non-zero when even one package could not be upgraded.

Exit codes: `0` success, `1` one or more steps failed, `2` not Windows,
`3` bad CLI arguments.

## workstation_doctor.ps1

A read-only report, mirroring
[`macos-initial-setup/workstation_doctor.sh`](../../macos-initial-setup/workstation_doctor.sh).
It looks at BitLocker, Defender, the pending-reboot flags, free space on `C:`,
whether WSL is installed and what distros it holds, and the effective execution
policy. It changes nothing, so there is nothing to preview:

```powershell
.\workstation_doctor.ps1
.\workstation_doctor.ps1 -MinFreePercent 20
.\workstation_doctor.ps1 -ListSections
.\workstation_doctor.ps1 -Only hardware,uptime
.\workstation_doctor.ps1 -MaxUptimeDays 14 -MaxPatchAgeDays 30
```

| Section | What it reports |
| --- | --- |
| `security` | BitLocker protection on `C:`, Defender antivirus, real-time protection and signature age. |
| `reboot` | The registry flags Windows sets when a restart is pending, queued file renames, a pending computer rename. |
| `disk` | Free space on `C:` against `-MinFreePercent`. |
| `wsl` | Whether WSL is installed and operational, and its distros. |
| `policy` | The effective execution policy and the scope that set it. |
| `hardware` | Physical disk health (a disk that is not Healthy/OK is a warning, with the reliability-counter command to look closer), free space on the other fixed volumes against the same threshold, the TPM and Secure Boot. |
| `uptime` | Days since the last boot against `-MaxUptimeDays`. With Fast Startup on, "Shut down" does not reset uptime - only "Restart" does - and the warning says so. |
| `updates` | The age of the newest installed update against `-MaxPatchAgeDays`, and a warning when the Windows Update service is disabled. |
| `memory` | Free physical memory (a warning under 10%) and commit headroom, with a pointer to `.wslconfig` when WSL is running. |

The first five are the sections this report has always had, and they still
run first and in the same order; the four after them only append. `-Only`
picks a comma-separated subset, the way it does for `status.ps1`.

| Option | Meaning |
| --- | --- |
| `-MinFreePercent N` | Warn below this much free space, `0`-`100`, on `C:` and on the other fixed volumes. Default `10`. |
| `-Only LIST` | Comma-separated section ids. An unknown id exits `3`; a list that selects nothing exits `4`. |
| `-ListSections` | Print the section ids and exit `0`. Works on any OS. |
| `-MaxUptimeDays N` | Warn past this many days of uptime, `0`-`3650`; `0` turns the warning off. Default `30`. |
| `-MaxPatchAgeDays N` | Warn when the newest installed update is older than this, `1`-`3650`. Default `45`. |

`-Action report` is the only action, and the default. That is not decoration:
the contract checks in [`../tests/`](../tests/) require every script to offer
either `-DryRun` or a validated `-Action` with a read-only default, and a
diagnostic tool has no use for the first. `wsl_manage.ps1` satisfies the same
rule with its `list` default.

Disk warnings default to less than 10% free on `C:`. `-MinFreePercent` raises
or lowers that threshold without changing the report-only exit contract; this
is useful on large disks where 10% may still be too little operational headroom.

Every probe is best-effort. `Get-BitLockerVolume` does not exist on Home
editions, `Get-MpComputerStatus` is absent where Defender has been replaced,
`Get-Tpm` and `Confirm-SecureBootUEFI` need elevation, and all of them answer
more fully from an elevated prompt — anything that cannot answer says so and
the report carries on. Warnings are printed and counted, but the exit code
stays `0`. Only the wrong platform (`2`), an unknown `-Only` section (`3`) and
an `-Only` list that selects nothing (`4`) change it.

## net_doctor.ps1

The Windows counterpart of [`linux/net_doctor.sh`](../../linux/net_doctor.sh),
and the first thing to run when "I cannot reach X". It describes; it changes
nothing, and it sends nothing over the network unless you ask it to:

```powershell
.\net_doctor.ps1
.\net_doctor.ps1 -ListSections
.\net_doctor.ps1 -Only proxy,dns
.\net_doctor.ps1 -Probe github.com
.\net_doctor.ps1 -Probe registry.internal -Port 5000 -SkipListen
.\net_doctor.ps1 -Quiet
```

| Section | What it reports |
| --- | --- |
| `interfaces` | Adapters that are up, link speed, global addresses, and the kind of each: physical, Hyper-V, WSL, Docker, VPN, Bluetooth. A physical adapter holding only a `169.254` address is a warning: DHCP never answered. |
| `routes` | The default gateway. No gateway is a warning, and so are two or more - Wi-Fi plus a VPN is the usual pair - listed with their `InterfaceMetric`, because the lowest metric wins. |
| `dns` | DNS servers and suffix per adapter. A physical adapter with no server is a warning. No lookups are made here. |
| `proxy` | The WinINET proxy (`ProxyEnable`, `ProxyServer`, the PAC `AutoConfigURL`, the bypass list), the `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY` and `NO_PROXY` variables, and git's `http.proxy`. Warns when the environment sets a proxy WinINET does not, when the two name different proxies, and when a proxy is set with an empty `NO_PROXY`. |
| `hosts` | The entries in the hosts file, up to twenty of them. An entry there wins over DNS, which is how a stale one sends a name to an old address. |
| `listen` | Listening TCP ports with the owning process, sorted by port, marking the ones bound to every interface. Needs `Get-NetTCPConnection`; without it the section is a `[skip]`. |
| `probe` | Only with `-Probe`: resolves the host, asks every configured DNS server for it separately - the way to find the one dead resolver out of two - and makes one TCP connection to `-Port`. |

| Option | Meaning |
| --- | --- |
| `-Only LIST` | Comma-separated section ids. An unknown id exits `3`; a list that selects nothing exits `4`. |
| `-ListSections` | Print the section ids and exit `0`. Works on any OS. |
| `-Probe HOST` | Resolve and connect to `HOST`: letters, digits, `.`, `_` and `-`, or an IPv6 address in brackets. |
| `-Port N` | The port `-Probe` connects to, `1`-`65535`. Default `443`. |
| `-SkipListen` | Leave out the listening-port list. |
| `-Quiet` | Print only warnings, each with its hint. |
| `-HostsFile PATH` | Read another hosts file instead of the system one. |

Exit codes: `0` the report ran (warnings do not change it, as with
`workstation_doctor.ps1`), `2` not Windows, `3` bad arguments (an unknown
section, a host with characters a host name cannot have, a port out of
range), `4` `-Only` selected nothing.

Worth knowing:

- **Proxy passwords are masked.** Every proxy URL is printed as
  `scheme://user:***@host`, including when the password itself holds an `@`
  or a `:`. No other environment variable is printed at all.
- **`-Probe` is the only network traffic**, and it is a DNS lookup per
  configured server plus one TCP connect that sends no data. Without it the
  report reads local state only.
- **The adapter sections work everywhere.** They read
  `System.Net.NetworkInformation`, which answers on Windows PowerShell 5.1,
  PowerShell 7 and Linux alike; the metric, listening-port and per-server DNS
  probes need the Windows networking cmdlets and degrade to `[info]` or
  `[skip]` without them.

## ssh_client_doctor.ps1

The Windows counterpart of
[`linux/ssh_client_doctor.sh`](../../linux/ssh_client_doctor.sh), with the same
verdicts, the same `-FailOn` and the same exit codes, so one piece of
automation can drive both. It reads; it never fixes. Every `[warn]` and
`[FAIL]` is followed by the command that would fix it, printed for you to run.

```powershell
.\ssh_client_doctor.ps1
.\ssh_client_doctor.ps1 -FailOn warn
.\ssh_client_doctor.ps1 -SshDir D:\keys\.ssh -Quiet
```

The failures it looks for are the Windows ones, which are not the Unix ones:

| Group | What it checks |
| --- | --- |
| `directory` | The `.ssh` directory exists. Missing is a `[skip]`, not a failure: the account has never used ssh. |
| `agent` | The `ssh-agent` service. It ships Disabled, which is why `ssh-add` answers "Error connecting to agent"; the hint is the elevated `Set-Service -StartupType Manual` and `Start-Service` pair. When it runs, `ssh-add -l` is asked how many keys it holds - only the count is used. |
| `clients` | Which `ssh.exe` wins on `PATH`, and whether git will use another one. Git for Windows bundles its own ssh, which cannot see the Windows agent, so `ssh -T` works while `git fetch` asks for a passphrase. A warning when both exist, the agent runs and nothing pins git, with `git config --global core.sshCommand` as the fix. |
| `keys` | Every private key, found by its first line (`-----BEGIN ... PRIVATE KEY-----`), and the `config` file: Windows OpenSSH refuses a key when anyone but you, SYSTEM and Administrators has access ("UNPROTECTED PRIVATE KEY FILE"); `config` fails only when someone else can write to it, since reading is allowed. The hint is the `icacls` lines that strip inheritance and the extra grants. Accounts are compared by SID first, so a localised Windows is graded correctly. |
| `config` | `IdentityFile` lines in `config` that point at a file that does not exist. A line with a `%h`-style token or a `${VAR}` is reported as something only ssh can expand. |

| Option | Meaning |
| --- | --- |
| `-SshDir DIR` | The directory to inspect. Default: `.ssh` in the user profile. |
| `-FailOn LEVEL` | Exit `1` on `fail` (default), or on `warn` and above. Any other value exits `3`. |
| `-Quiet` | Print only warnings and failures, with their hints. |

Exit codes: `0` nothing at or above `-FailOn`, `1` something at or above it,
`2` not Windows, `3` bad arguments.

What it reads, and what it does not:

- **Only the first line of a key.** That is enough to tell a private key from
  anything else; the body is never read, and no key material, fingerprint or
  comment is printed.
- **No `ssh -G`, no `Include`.** It reads `IdentityFile` lines as written. For
  the effective configuration of one host, use
  [`git/git_ssh_doctor.py`](../../git/git_ssh_doctor.py), which asks OpenSSH.
- **Nothing is changed.** The `icacls`, `Set-Service` and `git config` lines
  are advice; no access list, service or file is touched.

## dev_env_doctor.ps1

`workstation_doctor.ps1` answers "is this machine healthy". This one answers
"will my toolchain work here": the Windows configuration that breaks git,
containers and cloud command-line tools while the machine itself looks fine.
It reads registry values, CIM classes, service states and global git settings,
and changes none of them.

```powershell
.\dev_env_doctor.ps1
.\dev_env_doctor.ps1 -ListSections
.\dev_env_doctor.ps1 -Only git,paths
.\dev_env_doctor.ps1 -CheckTime -MaxSkewSeconds 2
```

| Section | What it checks | Why it matters |
| --- | --- | --- |
| `paths` | `LongPathsEnabled`, and git's `core.longpaths` beside it | Paths over 260 characters break git checkouts and deep `node_modules`. Turning on the Windows flag is not enough while git's own setting is off. |
| `git` | `core.autocrlf`, `core.symlinks` against Developer Mode, `credential.helper`, `core.eol`, `user.name` | `autocrlf=true` puts CRLF into shell scripts and YAML, which then fail inside Linux containers with `\r: command not found`. Global and system values are read; a repository's own settings are not. |
| `virtualization` | A running hypervisor, firmware virtualization, the WSL and Virtual Machine Platform features, Developer Mode | WSL2 and Docker Desktop do not start without virtualization. Reading optional features needs elevation and is an `[info]` without it. For distro detail it points at `..\wsl\wsl_manage.ps1 list`. |
| `time` | The Windows Time service; with `-CheckTime`, the clock offset | Kerberos, AWS SigV4 and JWT validation fail on a clock a few seconds off. `-CheckTime` takes one NTP sample from `time.windows.com`; nothing is resynced. |
| `shell` | The running edition, `pwsh` on `PATH`, `HOME` against `USERPROFILE`, PSReadLine | When `HOME` is set and differs, Git Bash, ssh and git read different home folders, and keys and config seem to vanish. |
| `containers` | The docker CLI and its current context, `DOCKER_HOST`, the Docker Desktop service | `docker context show` reads the CLI's own config and never contacts the daemon, so the check cannot hang while Docker Desktop is starting. |

| Option | Meaning |
| --- | --- |
| `-Only LIST` | Comma-separated section ids. An unknown id exits `3`; a list that selects nothing exits `4`. |
| `-ListSections` | Print the section ids and exit `0`. Works on any OS. |
| `-CheckTime` | Measure the clock offset: one `w32tm /stripchart` sample. The only network traffic this script makes. |
| `-MaxSkewSeconds N` | The offset `-CheckTime` warns above, `1`-`3600`. Default `5`. |
| `-Quiet` | Print only warnings, each with its hint. |

Exit codes: `0` the report ran (warnings do not change it), `2` not Windows,
`3` bad arguments, `4` `-Only` selected nothing.

Every `[warn]` is followed by the command that fixes it - the
`New-ItemProperty` for long paths, the `git config --global` line,
`w32tm /resync` - printed for you to run from the right prompt. The script
runs none of them.

## path_doctor.ps1

A PATH report, and a cleanup of the user PATH that is hard to regret. It reads
both values raw from the registry, with `%VARIABLES%` left unexpanded and the
registry kind beside them, because that is the only way to see why
`%USERPROFILE%\bin` "is on PATH" and still does not work.

```powershell
# Report (the default, read-only):
.\path_doctor.ps1
.\path_doctor.ps1 report -Scope User
.\path_doctor.ps1 report -Command python,node,kubectl

# Clean the user PATH: preview, then do it.
.\path_doctor.ps1 clean -DryRun
.\path_doctor.ps1 clean -Yes
```

`report` lists every entry of both PATH values and then what is wrong with
them:

| Finding | Meaning |
| --- | --- |
| `duplicate` | The same folder twice, ignoring case, quotes and a trailing slash, after expansion. Names the entry it repeats. |
| `missing-dir` | An absolute folder that does not exist: an uninstalled tool's leftover. |
| `relative-entry` | Resolved against whatever folder a program starts in. |
| `quoted-entry` | Quotes in PATH are not honoured everywhere; a folder with spaces needs none. |
| `unexpanded-var` | A `%VARIABLE%` in a value stored as `REG_SZ`, so Windows uses it literally. This is what `setx` leaves behind. |
| `too-long` | Over 1024 characters (`setx PATH` would truncate it), over 2048 (older installers truncate it), or over 32767 (Windows cannot hold it at all). |
| `empty-entry`, `cross-scope-duplicate` | Information only. |

The `shadowing` section asks which copy of each command wins
(`Get-Command -All`) and flags the two known traps: the Microsoft Store
`python.exe` alias answering ahead of a real Python, and Git's `usr\bin`
putting the MSYS `find`, `sort`, `curl`, `ssh` or `tar` ahead of the Windows
ones. Everything else that resolves more than once is listed, first copy
first.

`clean` changes the **user** PATH, and only by removing three kinds of entry:
empty ones, repeats of an earlier entry, and absolute folders that no longer
exist on a drive that does. It keeps everything it cannot judge - an entry
with a `%VARIABLE%`, a relative or quoted entry, a folder on a drive that is
not there right now - and keeps the order and the original text of the rest.

| Option | Meaning |
| --- | --- |
| `-DryRun` | With `clean`: print each entry it would remove and why, and the length before and after. Writes nothing, creates nothing. |
| `-Yes` | With `clean`: actually write. Without `-Yes` or `-DryRun`, `clean` refuses and exits `3`. |
| `-Scope All\|User\|Machine` | Which values `report` reads. Default `All`. `clean` works on `User` only, and refuses `Machine` or `All`. |
| `-Command LIST` | Commands to check for shadowing. Default: git, python, python3, pip, node, npm, docker, kubectl, terraform, az, aws, gcloud, ssh, curl, find, sort. |
| `-BackupDir DIR` | Where `clean` writes its backup. Default: `path-backups` in the user profile. |
| `-Quiet` | Leave out the entry list and the `[info]` lines. |

Exit codes: `0` report printed or clean finished (also when there was nothing
to clean), `1` clean could not read, back up, write or verify the user PATH,
`2` not Windows, `3` bad arguments or clean refused.

What `clean -Yes` does, in order:

1. Writes a backup of both PATH values and their registry kinds to
   `-BackupDir`, as `path-<date>-<time>.txt`. If that fails, it stops and
   writes nothing.
2. Writes the cleaned user PATH back **with the registry kind it already
   had**. `[Environment]::SetEnvironmentVariable` would quietly turn a
   `REG_EXPAND_SZ` into `REG_SZ` and break every `%VARIABLE%` entry; this
   does not use it.
3. Reads the value back and exits `1` if it is not what was written.
4. Says so. Shells that are already open keep the old PATH; sign out and in,
   or restart Explorer, for new ones to see it.

Running it again finds nothing to do and writes nothing, including no new
backup. The machine PATH is never written: edit it in System Properties >
Environment Variables.

### Roll back

Every `clean -Yes` names its backup file. To put the user PATH back exactly as
it was, kind included:

```powershell
$backup = "$env:USERPROFILE\path-backups\path-20261021-101500.txt"
$lines = Get-Content -LiteralPath $backup
$value = ($lines | Where-Object { $_ -like 'User.Path=*' }).Substring(10)
$kind = ($lines | Where-Object { $_ -like 'User.Kind=*' }).Substring(10)
$key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
$key.SetValue('Path', $value, $kind)
$key.Close()
```

The backup also records the machine PATH as it was, for reference; restoring
that one is a System Properties job.

## hardening_audit.ps1

The Windows counterpart of
[`linux/hardening_audit.sh`](../../linux/hardening_audit.sh) and
[`macos-initial-setup/hardening_audit.sh`](../../macos-initial-setup/hardening_audit.sh):
the same `[pass]` / `[warn]` / `[FAIL]` / `[skip]` verdicts, the same `-FailOn`
and the same exit codes, so a scheduled task or a CI job can gate on any of
the three. It is to `workstation_doctor.ps1` what `hardening_audit.sh` is to
`linux/system_doctor.sh`: the doctor describes the machine, the audit grades
it and prints, under every `[warn]` and `[FAIL]`, the elevated PowerShell
command that would fix it.

```powershell
.\hardening_audit.ps1
.\hardening_audit.ps1 -ListGroups
.\hardening_audit.ps1 -Only network,remote
.\hardening_audit.ps1 -FailOn warn -Quiet
```

| Group | Check ids | What fails or warns |
| --- | --- | --- |
| `network` | `fw-domain`, `fw-private`, `fw-public`, `smb1`, `llmnr` | A firewall profile that is off or allows inbound by default; the SMBv1 server enabled; LLMNR not turned off by policy. |
| `remote` | `rdp-enabled`, `rdp-nla`, `winrm-trustedhosts`, `sshd-password`, `sshd-empty-password` | Remote Desktop on (a warning: right on a jump box) and on without Network Level Authentication (a failure); WinRM `TrustedHosts` set to `*`; an OpenSSH server that takes passwords, or empty ones. |
| `accounts` | `uac-lua`, `uac-prompt`, `autologon`, `autologon-password`, `guest-enabled`, `local-admins-broad` | UAC off or elevating without asking; automatic logon; a `DefaultPassword` value under Winlogon; the Guest account enabled; Everyone, Authenticated Users or Users inside the local Administrators group. |
| `boot` | `secureboot`, `tpm`, `lsa-ppl`, `vbs` | Secure Boot off; no TPM or one not ready; LSA not running as a protected process; virtualization-based security not running. |
| `defender` | `defender-rtp`, `defender-tamper`, `defender-sigs`, `defender-pua`, `defender-netprot` | Real-time protection off; tamper protection off; signatures over 7 days old; PUA blocking or network protection off. All five are skips where another antivirus product replaced Defender. |
| `logging` | `ps-scriptblock` | PowerShell script block logging off. |
| `updates` | `hotfix-age`, `reboot-pending` | The newest installed update over 60 days old (warn) or over 120 (fail); a restart pending. |

| Option | Meaning |
| --- | --- |
| `-Only LIST` | Comma-separated groups. An unknown group exits `3`; a list that selects nothing exits `4`. |
| `-ListGroups` | Print the group ids and exit `0`. Works on any OS. |
| `-FailOn LEVEL` | Exit `1` on `fail` (default), or on `warn` and above. Any other value exits `3`. |
| `-Quiet` | Print only warnings and failures, with their fixes. |

Exit codes: `0` nothing at or above `-FailOn`, `1` something at or above it,
`2` not Windows, `3` bad arguments, `4` `-Only` selected nothing.

Worth knowing:

- **It never fixes anything.** The "insecure" answer is the correct one on
  some hosts - RDP on a bastion, autologon on a kiosk or a build agent - and a
  script that hardened by itself would be wrong often enough to be dangerous.
  The fix lines are for a person to read and run.
- **Run it elevated for the full picture.** Secure Boot, the TPM, the SMB
  server and the local accounts need elevation to read. Unelevated, those
  checks are `[skip]` with the reason, never a failure, and the banner says
  which mode it ran in.
- **No secret is read.** For autologon it checks whether a `DefaultPassword`
  value exists and never reads it. Accounts are only named when a broad
  principal is in the Administrators group, which is found by its SID so a
  localised Windows reads correctly.

## tls_expiry.ps1

The Windows counterpart of [`linux/tls_expiry.sh`](../../linux/tls_expiry.sh):
"will a certificate expire on me next month", answered with an exit code a
scheduled task or a CI job can act on. It reads certificates; it never
renews, imports or changes one.

```powershell
.\tls_expiry.ps1 -File C:\certs\api.pem
.\tls_expiry.ps1 -HostName git.internal,registry.internal:5000 -Days 14
.\tls_expiry.ps1 -Store -FailOn warn
.\tls_expiry.ps1 -File .\leaf.crt -HostName example.com -Store -Quiet
```

| Source | What is read |
| --- | --- |
| `-File` | A PEM, CRT, CER or DER file. For a bundle, the first certificate - the leaf, in every bundle a server is handed. A file that is not a certificate is a `[FAIL]`. |
| `-HostName` | The leaf a TLS endpoint presents, from a handshake with SNI. An expired or mismatched certificate is still read, and a name mismatch or an untrusted chain is a separate `[warn]`. An endpoint that cannot be reached is a `[FAIL]`. |
| `-Store` | Every certificate in the Personal stores of the current user and of the machine (`CurrentUser\My`, `LocalMachine\My`), where Windows keeps client-authentication, code-signing, RDP and WinRM HTTPS certificates, with whether each has a private key. |

The trust-anchor stores (Root, CA, TrustedPublisher) are never scanned: their
contents are not yours to renew, and paging on a vendor root that expires next
year is noise - the reason `linux/tls_expiry.sh` gives for leaving
`/etc/ssl/certs` alone.

| Option | Meaning |
| --- | --- |
| `-File PATH` | Files to check; repeat it or give a comma-separated list. A path that does not exist exits `3`. |
| `-HostName HOST[:PORT]` | Endpoints to check, port 443 by default; an IPv6 address goes in brackets. Not `-Host`, which is PowerShell's own `$Host`. |
| `-Store` | Also check the two Personal stores. |
| `-Days N` | Warn within this many days, `1`-`3650`. Default `30`. |
| `-FailOn LEVEL` | `fail` (default) exits `1` on an expired, unreadable or unreachable certificate; `warn` also on one expiring within `-Days`; `never` always exits `0`. The Bash sibling spells the first one `expired`. |
| `-Quiet` | Print only warnings and failures. |

Exit codes: `0` nothing at or above `-FailOn`, `1` something at or above it,
`2` not Windows, `3` bad arguments (nothing to check, a missing file, a
malformed host, a value out of range).

How the endpoint check stays harmless: the connection gets its own
certificate-validation callback, which records what was wrong and lets the
handshake finish so the leaf can be read. The process-wide callback is never
touched, no application data is sent, and the connection is closed as soon as
the certificate is in hand. No private key is read or copied anywhere; for a
store certificate only the "has a private key" flag is shown.

## Testing

`winget.exe`, BitLocker and WSL do not exist on Linux, so the CI suite cannot
exercise the behaviour of these scripts — only that they parse, that
PSScriptAnalyzer is happy with them, that their comment-based help is complete,
that each one offers `-DryRun` or a validated `-Action`, and that every flag
documented above actually exists in a `param()` block. See
[`../tests/`](../tests/).

`configuration.winget` is checked by two different things, because they catch
different failures. yamllint covers its syntax (it is discovered as YAML via
`yaml-files` in `.yamllint.yml`). The static suite additionally checks its
*shape* - that it declares resources, that ids are unique, and that no
directive key exists which nobody wrote - when `python3` and PyYAML are both
available, and prints a `warn` and skips the check when they are not. That second check is the one that
matters: an unquoted description containing a comma ends its value inside an
inline map and turns the rest into a stray key, producing a file that is
perfectly valid YAML and the wrong document. yamllint passes it without a word.

The read-only reports keep their grading logic - proxy agreement, hosts-file
parsing, credential masking - in small pure functions, which the contract
suite lifts out through the PowerShell parser and runs against fixtures, on
Linux as well as Windows. It also checks that a script with neither `-DryRun`
nor `-Yes` calls no state-changing cmdlet at all.

Behaviour has to be checked on a real Windows machine. `workstation_doctor.ps1`,
`winget_bootstrap.ps1 diff` / `check`, and `stay_fresh.ps1 -DryRun` are all
read-only, so they are safe places to start.

## winget_configure.ps1

`winget_bootstrap.ps1` captures a machine. This one applies one, from
[`configuration.winget`](configuration.winget).

```powershell
# Does the file parse and do its resources resolve? (read-only)
.\winget_configure.ps1 validate

# What is in it? (read-only)
.\winget_configure.ps1 show

# Does this machine already match it? (read-only, exits 1 if it has drifted)
.\winget_configure.ps1 test

# Preview, then build
.\winget_configure.ps1 apply -DryRun
.\winget_configure.ps1 apply
```

`-File PATH` points any verb at a different configuration, the same way
`winget_bootstrap.ps1` takes one.

`test` is the verb worth putting on a schedule. It answers "has this machine
drifted from the list we agreed on" with an exit code rather than with prose -
the same shape as `winget_bootstrap.ps1 check` and `brewfile.sh check`, so all
three drive the same automation.

The `apply -DryRun` preview reads the configuration and lists what it would
ensure. It does not call winget, for the reason the import preview does not:
even winget's read-only paths populate source caches under `LOCALAPPDATA`,
which would make a supposedly no-write dry run mutate the machine.

### The configuration file

Six groups - core, work, communication, media, utilities, plus one OS-version
assertion - so a machine can be provisioned partially by commenting a block
out rather than by editing a flat list.

The assertion floor is **Windows 11 21H2** (build `10.0.22000`). Note that
`10.0.22000` is Windows 11's first build, not Windows 10 21H2, which is
`10.0.19044` - the two are easy to confuse and the file says which it means.
The floor is deliberate: Windows 10 left support in October 2025, so a machine
below it is not one to be installing a fresh workstation onto. Lower it to
`10.0.19044` if you must target Windows 10, and change the description with
it.

What is deliberately *not* in it is as much of the point as what is:

- **Linux tooling** (`kubectl`, `helm`, `k9s`, `jq`, `yq`, Terraform, Go,
  `awscli`, `azure-cli`) belongs inside WSL, where [`linux/`](../../linux/)
  already installs and tests it. A second native copy on the Windows side only
  drifts from the one you actually use.
- **VS Code extensions** are not applications. VS Code's own settings sync is
  the right mechanism; a package manager is not.
- **Chocolatey's own tooling** is meaningless without Chocolatey.

The schema is `0.2`, not v3, and that is a decision rather than an oversight.
The v3 schema needs WinGet 1.11 or newer with the `dscv3` processor - a much
narrower floor than this repository targets - and a machine below it fails with
a DSC error rather than a clear one. Moving to v3 is a one-file change once
1.11+ is a safe assumption.

### Requirements

WinGet 1.6 or newer: `winget configure` does not exist before it. The preflight
checks `winget --version` and exits 2 with the reason, rather than letting
winget fail with an unrecognised-argument error that reads like a bug in this
script. A version string it cannot parse is treated as unknown and allowed
through - refusing to run because a future winget changed its banner format
would be the worse failure.

Both the presence and version checks run at the point winget is invoked, not at
startup, so `apply -DryRun` works on a machine that does not have App Installer
yet. Previewing what a configuration would do is the first thing worth running
on a fresh box, and it reads the file rather than asking winget anything.

### Exit codes

Matching `winget_bootstrap.ps1`:

| Code | Meaning |
| --- | --- |
| 0 | Success; for `test`, the machine matches the file |
| 1 | Command failed; for `test`, the machine has drifted |
| 2 | Preflight failed (not Windows, no winget, winget too old) |
| 3 | Bad arguments |

`test` collapses winget's several non-zero HRESULTs into 1 and prints the raw
code alongside it. "Not in desired state" and "could not tell" mean the same
thing to a caller - do not trust this machine to match the file - and the
distinction is preserved in the output rather than in the exit status.

## choco_bootstrap.ps1

The Chocolatey counterpart of `winget_bootstrap.ps1`. Five verbs, the same set
with `install` in place of `import`, so it mostly does not matter which package
manager a given machine uses.

Two exit codes do differ, and the divergence is real rather than documented
intent: refusing to overwrite an existing file on `export` exits `3` from
`choco_bootstrap.ps1` and `1` from `winget_bootstrap.ps1`, and a missing
package file exits `3` from `Get-WantedPackage` in the first against `1` from
the second. Under the table above that reads as "bad arguments" from one
script and "command failed" from the other for the same situation. Branch on
the message, not the code, until one of the two is changed.

winget is the primary one here: it ships with Windows, needs no bootstrap, and
`winget configure` gives a declarative machine definition Chocolatey has no
equivalent for. Chocolatey stays because it genuinely covers packages winget
does not, and because machines already managed with it should not have to be
rebuilt to be usable with this repository.

```powershell
.\choco_bootstrap.ps1 list            # installed ids, read-only
.\choco_bootstrap.ps1 check           # is everything in the file installed?
.\choco_bootstrap.ps1 diff            # what export would change
.\choco_bootstrap.ps1 install -DryRun # what the file asks for
.\choco_bootstrap.ps1 install
.\choco_bootstrap.ps1 export -Force
```

The `install -DryRun` preview reads the file and stops there; it does not ask
Chocolatey what is already installed. Even `choco list` creates
`%TEMP%\chocolatey` and touches `%APPDATA%`, so a preview that diffed against
the machine would make the script's own no-write claim false - and did, until
the native Windows runner caught it. `check` answers the "what is missing"
question and is allowed to talk to Chocolatey.

The file it reads and writes is `packages.config`, Chocolatey's own format, so
it is also usable without this script:

```powershell
choco install choco-packages.config -y
```

Copy [`choco-packages.example.config`](choco-packages.example.config) to
`choco-packages.config` and edit. The example is a ported version of an older
work-environment list; the comment at the top of it records the four entries
that had to change, and why -- classic Teams was retired, Sublime Text moved to
4, three JVMs collapse to one current LTS, and a decade-old Pester pin went.

`install` does not bootstrap Chocolatey itself. That means running a remote
script from an elevated shell, which is a decision worth making deliberately
rather than as a side effect of asking what is installed, so the script reports
the official command and stops when `choco` is missing.

Useful alongside it:

```powershell
choco upgrade all -y                    # upgrade everything
choco uninstall <package-name>          # remove one
```

Note `choco list --local-only` from older guides: v2 removed that flag and made
local listing the default, so it now errors. `choco list` is the current
spelling, and `choco list -r` is the machine-readable one this script parses.
