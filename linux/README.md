# Linux scripts

[Ops Toolbox](../README.md) / **Linux scripts**

Bootstrap and maintenance for a Linux machine — the counterpart of
[`macos-initial-setup/`](../macos-initial-setup/), for servers and workstations
rather than a Mac.

**Targets:** Debian/Ubuntu (`apt`), Fedora/RHEL (`dnf`) and Arch (`pacman`).
The three scripts that install packages — `stay_fresh.sh`,
`install_devtools.sh`, `packages.sh` — exit `2` on anything else and say what
they detected, the same way the macOS scripts exit `2` off macOS. The two that
read rather than install carry on: `disk_cleanup.sh` warns and skips package
caches, `system_doctor.sh` prints a `skip` line and reports everything else.
Every script exits `2` off Linux.

Scripts here use `set -u` plus `set -o pipefail` on separate lines and no `-e`,
because a long maintenance run records a missing tool and skips it rather than
dying on it, and they must stay Bash 3.2-clean like the macOS package.
[`CONTRIBUTING.md`](../CONTRIBUTING.md) has the full set.

## Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Lifecycle: when to run what](#lifecycle-when-to-run-what)
- [Kali VM bootstrap](#kali-vm-bootstrap)
- [Two decisions worth knowing](#two-decisions-worth-knowing)
- [Distro detection](#distro-detection)
- [What `stay_fresh.sh` does](#what-stay_freshsh-does)
- [The two overlapping reports](#the-two-overlapping-reports)
- [`status.sh`](#statussh)
- [`system_doctor.sh`](#system_doctorsh)
- [`systemd/stay_fresh_timer.sh`](#systemdstay_fresh_timersh)
- [`install_aliases.sh`](#install_aliasessh)
- [`schedule_report.sh`](#schedule_reportsh)
- [`disk_cleanup.sh`](#disk_cleanupsh)
- [`net_doctor.sh`](#net_doctorsh)
- [`listen_audit.sh`](#listen_auditsh)
- [`sysctl_defaults.sh`](#sysctl_defaultssh)
- [`tls_expiry.sh`](#tls_expirysh)
- [`log_triage.sh`](#log_triagesh)
- [`container_doctor.sh`](#container_doctorsh)
- [`config_backup.sh`](#config_backupsh)
- [`ssh_client_doctor.sh`](#ssh_client_doctorsh)
- [Scoped runs and kernel checks](#scoped-runs-and-kernel-checks)
- [Exit codes](#exit-codes)
- [Tests](#tests)

| File | Purpose |
| --- | --- |
| [`install_devtools.sh`](install_devtools.sh) | Install Python, Go, Terraform, Helm and the DevOps CLIs |
| [`stay_fresh.sh`](stay_fresh.sh) | Recurring maintenance: upgrades, journal, caches, containers |
| [`disk_cleanup.sh`](disk_cleanup.sh) | Free space now: age-filtered temp, opt-in trash/journal/caches/coredumps; never volumes |
| [`status.sh`](status.sh) | One-screen verdict. Selectable sections via `--only` / `--list-sections`. |
| [`system_doctor.sh`](system_doctor.sh) | Read-only health report: disk, memory, clock, reboot, services, firewall, containers, load, taint |
| [`net_doctor.sh`](net_doctor.sh) | Read-only network report: interfaces, default IPv4/IPv6 route, link errors and negotiation, DNS, listening sockets |
| [`listen_audit.sh`](listen_audit.sh) | Read-only listening-port owners and scope; `--print` a baseline, `--baseline` to catch drift |
| [`hardening_audit.sh`](hardening_audit.sh) | Read-only security audit: sshd settings and algorithms, accounts, network, file modes, host keys, updates, kernel controls |
| [`ssh_client_doctor.sh`](ssh_client_doctor.sh) | Read-only `~/.ssh` modes, IdentityFile paths, key strength, known_hosts, authorized_keys, risky config, agent; not `ssh -G` |
| [`tls_expiry.sh`](tls_expiry.sh) | Read-only leaf certificate expiry for named PEMs and hostnames; `--deep` name, chain and key checks |
| [`container_doctor.sh`](container_doctor.sh) | Read-only Docker/Podman grading: restart loops, OOM kills, socket mounts, uncapped logs |
| [`log_triage.sh`](log_triage.sh) | Read-only log summary since `--since`: kernel distress, noisiest identifiers, failed logins, repeats |
| [`sysctl_defaults.sh`](sysctl_defaults.sh) | Report/apply/revert a short sysctl list (inotify watches, swappiness) |
| [`packages.sh`](packages.sh) | Capture and restore the explicitly-installed package set |
| [`config_backup.sh`](config_backup.sh) | Dated tar of selected paths (default `/etc`); never a restore |
| [`schedule_report.sh`](schedule_report.sh) | Read-only inventory of systemd timers and cron jobs |
| [`cloud-init/kali-vm-init.yaml`](cloud-init/kali-vm-init.yaml) | First-boot configuration for a Kali red/blue lab VM; see the [runbook](cloud-init/README.md) |
| [`bash_aliases.sh`](bash_aliases.sh) | Guarded aliases and helpers, sourced from `~/.bashrc` |
| [`install_aliases.sh`](install_aliases.sh) | Install or remove the `bash_aliases.sh` source block in `~/.bashrc` |
| [`systemd/stay_fresh_timer.sh`](systemd/stay_fresh_timer.sh) | Install a user timer so `stay_fresh.sh` runs on a schedule |
| [`tests/`](tests/) | Docker checks that **run** the scripts, across all three distros |

## Requirements

| Requirement | Notes |
| --- | --- |
| **Linux** | Every script here exits `2` on anything else. |
| **One of `apt`, `dnf` or `pacman`** | Only the five scripts that read `/etc/os-release` care — see [Distro detection](#distro-detection). Three of them (`stay_fresh.sh`, `install_devtools.sh`, `packages.sh`) exit `2` on a distribution they do not know; `disk_cleanup.sh` warns and skips package caches, and `system_doctor.sh` prints a `skip` line. The rest never ask. |
| **Bash 3.2 or newer** | These scripts are held to the same Bash 3.2 floor as the macOS package, so they also run on a box with an old `/bin/bash`. |
| **`sudo`, or root** | Optional. Steps that need root are skipped with a warning when `sudo` is missing, and `--no-sudo` skips them deliberately. Running as root needs neither. |
| **A systemd user manager** | Only for [`systemd/stay_fresh_timer.sh`](systemd/stay_fresh_timer.sh), which exits `2` without one. `install --print-only` still prints the units anywhere. |
| **`openssl`** | Only for [`tls_expiry.sh`](tls_expiry.sh), which exits `2` without it. |
| **Docker** | Only to run the suite in [`tests/`](tests/), which runs the scripts inside real Debian, Fedora and Arch containers. |

Optional tools are handled the same way throughout: a missing one is recorded
and skipped, not fatal. That is why these scripts use `set -u` and
`set -o pipefail` without `-e` — a long maintenance run should report what it
could not do and carry on.

## Quick start

Everything that changes the machine previews first:

```bash
./stay_fresh.sh --dry-run
./install_devtools.sh --dry-run
./disk_cleanup.sh --dry-run
./config_backup.sh --dry-run

./stay_fresh.sh --yes
./install_devtools.sh --yes --setup-shell
./disk_cleanup.sh --yes
./config_backup.sh --yes

# Run just the named groups:
./stay_fresh.sh --dry-run --only caches,containers
./install_devtools.sh --dry-run --only clis,python
```

Capture what a machine has, commit it, rebuild elsewhere:

```bash
./packages.sh dump          # writes packages.<manager>.txt
./packages.sh list          # stable inventory on stdout; writes nothing
./packages.sh diff          # what has drifted since
./packages.sh install --dry-run
./packages.sh install --yes
```

Read the machine without touching it:

```bash
./status.sh                 # one-screen verdict
./system_doctor.sh          # is this machine well?
./net_doctor.sh             # is this machine reachable?
./listen_audit.sh           # who owns each listening port?
./hardening_audit.sh        # is this machine safe?
./ssh_client_doctor.sh      # is ~/.ssh something ssh will actually use?
./tls_expiry.sh --file /etc/ssl/private/example.pem
./log_triage.sh             # what has been going wrong lately?
./container_doctor.sh       # which container is misbehaving or filling the disk?
./sysctl_defaults.sh        # current vs desired sysctl values
./schedule_report.sh        # what is scheduled to run?
```

Aliases:

```bash
./install_aliases.sh --dry-run
./install_aliases.sh
./install_aliases.sh --status
```

## Lifecycle: when to run what

The folder is organized around the life of a machine. Each script fills a
distinct slot — understanding which slot matters more than memorizing flags.

| Phase | Script | Typical cadence | What it touches |
| --- | --- | --- | --- |
| **Bootstrap** | `install_devtools.sh` | Once per machine (+ version bumps) | language toolchains, DevOps CLIs; optionally the shell rc |
| **Bootstrap** | `install_aliases.sh` | Once per machine | a marked block in `~/.bashrc` |
| **Ambient** | `bash_aliases.sh` | Sourced on every interactive shell | your shell only — no disk writes |
| **Recurring** | `stay_fresh.sh` | Weekly / on demand | packages, journal, caches, containers (never volumes) |
| **Recurring** | `systemd/stay_fresh_timer.sh` | Install once, then it fires | user systemd units that run `stay_fresh.sh --yes --no-sudo` |
| **Space** | `disk_cleanup.sh` | When `/` is full | age-filtered temp; opt-in trash/journal/caches/coredumps; never volumes |
| **Copy** | `config_backup.sh` | Before editing `/etc` or upgrading | a dated tar under `--dest`; never writes back |
| **Copy** | `packages.sh` | After a machine looks the way you want | a package list you can commit and restore |
| **Configure** | `sysctl_defaults.sh` | Once, then after a new IDE exhausts inotify | `/etc/sysctl.d/99-ops-toolbox.conf`; read-only unless `--apply`/`--revert` |
| **Diagnose** | `status.sh` | After bootstrap, or when something feels wrong | nothing — it only reads |
| **Diagnose** | `system_doctor.sh` | After bootstrap, or when something feels wrong | nothing — it only reads |
| **Diagnose** | `net_doctor.sh` | When "the network is wrong" | nothing — it only reads |
| **Diagnose** | `listen_audit.sh` | From cron against a committed baseline, or after an install | nothing — it only reads |
| **Diagnose** | `schedule_report.sh` | When something ran at 3am | nothing — it only reads |
| **Diagnose** | `hardening_audit.sh` | Before trusting a machine with anything | nothing — it only reads |
| **Diagnose** | `ssh_client_doctor.sh` | When `Permission denied (publickey)` and the key is on disk | nothing — it only reads |
| **Diagnose** | `tls_expiry.sh` | Monthly, or from cron | nothing — it only reads |
| **Diagnose** | `container_doctor.sh` | When a container host pages, or `/var/lib/docker` fills | nothing — it only reads |
| **Diagnose** | `log_triage.sh` | After an incident, or on a box you have just been handed | nothing — it only reads |

`stay_fresh.sh` assumes a supported package manager but degrades if optional
tools (docker, snap, journalctl) are missing. The diagnose scripts never
change the machine; `hardening_audit.sh` is the one whose exit code can gate
a pipeline.

## Kali VM bootstrap

The setup file is [`cloud-init/kali-vm-init.yaml`](cloud-init/kali-vm-init.yaml).
The complete setup, OrbStack workaround, monitoring, verification, recovery,
and sizing instructions are in the
[`cloud-init` runbook](cloud-init/README.md).
Use the entire file as user-data for a Kali image that already includes
cloud-init. Validate it inside such an image with:

```bash
cloud-init schema \
  --config-file linux/cloud-init/kali-vm-init.yaml \
  --annotate
```

After cloud-init hands off to a first-boot systemd service, it upgrades Kali,
sets `Europe/Kyiv`, installs baseline network utilities and Kali's red/blue
team metapackages, configures key-only OpenSSH, and prepares UFW without enabling it.
OrbStack supplies its own guest integration, so hypervisor packages are not
installed. Verify the result with:

```bash
orbctl run --machine kali-lab --user root \
  test -f /var/lib/ops-toolbox/kali-vm-init.complete
orbctl run --machine kali-lab --user root kali-lab-status
orbctl run --machine kali-lab --user root systemctl is-active ssh
orbctl run --machine kali-lab --user root \
  sh -c 'command -v ping nmap tcpdump msfconsole sentrypeer clamscan autopsy'
```

The combined red/blue profile currently resolves to more than 1,400 packages.
Use at least a 64 GB disk and expect the first initialization to take much
longer than the minimal base setup.

The configuration never resets or enables UFW, never replaces SSH host keys,
and never enables password authentication or disables the desktop lock.

### OrbStack limitation

OrbStack supports cloud-config through `orbctl create --user-data`, but its
`kali:current` image did **not** include the `cloud-init` package when verified
with OrbStack 2.2.3 on 2026-08-12. As a result, this otherwise-correct command
times out and OrbStack removes the incomplete machine:

```bash
orbctl create --arch arm64 --cpus 2 --memory 4G --disk 64G \
  --user kali --user-data linux/cloud-init/kali-vm-init.yaml \
  kali:current kali-lab
```

Use a Kali cloud image with cloud-init preinstalled, or prepare and clone a
reusable OrbStack Kali base that already contains cloud-init. Do not treat a
successful YAML parse as proof that the stock OrbStack Kali image consumed it.
The tested NoCloud procedure is copy-ready in the
[`cloud-init` runbook](cloud-init/README.md). It was validated in a fresh
OrbStack Kali VM through installation, reboot, and representative red/blue tool
smoke checks.

## Two decisions worth knowing

**`install_devtools.sh` defaults to `mise`, where the macOS script defaults to
Homebrew.** That is not an arbitrary difference. On macOS, "native" means
Homebrew — a package manager already on the machine. Linux has no equivalent for
Terraform, Helm and current Go/Python: the upstream instructions are
`curl https://.../install.sh | bash`, a posture this repository takes nowhere
else. `mise` is one binary that manages all four. `--manager distro` uses your
distribution's own packages instead, which are older but distro-signed; it will
tell you when a tool simply is not in the default repositories rather than
quietly adding a third-party repo on your behalf.

**There is no `install_apps.sh` counterpart.** The macOS script installs GUI
applications through Homebrew Cask, which has no Linux equivalent worth
mirroring — the same app may be a distro package, a flatpak, a snap or a
tarball, and the right answer depends on your desktop. A curated list here
would be three namespaces of churn for little benefit, so the CLI and toolchain
half lives in `install_devtools.sh` and GUI apps are left to you.

## Distro detection

The five scripts that need a package manager — `disk_cleanup.sh`,
`install_devtools.sh`, `packages.sh`, `stay_fresh.sh`, `system_doctor.sh` —
read `/etc/os-release` and map `ID`/`ID_LIKE` onto one. The rest never
ask. The lookup is duplicated in each script rather than shared, for the
reason in [`CONTRIBUTING.md`](../CONTRIBUTING.md): a script has to work when
copied on its own onto a box.

It honours an `OS_RELEASE` override, which exists purely so the failure path is
testable — a container cannot pretend to be Gentoo, so without that seam the
"unsupported distro" branch could never be exercised:

```bash
printf 'ID=gentoo\n' > /tmp/fake
OS_RELEASE=/tmp/fake ./stay_fresh.sh --dry-run   # exits 2
```

## What `stay_fresh.sh` does

Package upgrade and autoremove, `journalctl --vacuum-time=14d`, user caches
(pip, npm, yarn, go, `~/.cache`), trash (both `files/` and the matching
`info/` records, so the desktop is not left showing entries that no longer
exist), `docker`/`podman` prune, flatpak and snap, then a report of whether a
reboot is pending, whether processes are still running old libraries
(`needs-restarting` / `needrestart`, when installed), and how full `/` is.

It refuses to run when `HOME` is unset, empty or not a directory (exit `2`):
every path it removes is built from `HOME`, and an empty one turns
`~/.cache/pip` into `/.cache/pip`. `--help` and `--list-steps` work without
one.

Two things it deliberately does not do:

- **Volumes are never pruned.** `docker system prune -f` without `--volumes` is
  the whole point: this script must not be the reason a database disappears.
- **Held packages stay held.** `apt-get upgrade` respects holds where
  `dist-upgrade` would fight them.

A missing tool is a note, not a failure. `journalctl` is absent in a container
and `snap` on most servers; neither should turn a maintenance run red. A step
that runs and *fails* does count, and the script exits `1`.

## The two overlapping reports

`system_doctor.sh` and `hardening_audit.sh` both change nothing and both look at
some of the same subsystems, so it is worth being clear about which one you
want:

| | `system_doctor.sh` | `hardening_audit.sh` |
| --- | --- | --- |
| Question | Is this machine **well**? | Is this machine **safe**? |
| Output | A narrative report | Graded findings, each with its fix |
| Firewall | Says which one is in charge | Grades "none" as a finding |
| sshd | Says whether it is installed and running | Grades `PermitRootLogin`, password auth, empty passwords, auth tries, forwarding, timeouts and weak algorithms |
| Exit code | Never `1` — findings are to be read. Still `2` off Linux and `3` on bad usage | `1` at or above `--fail-on`, so it can gate a pipeline |

The counterpart on the other side of the repository is
[`macos-initial-setup/workstation_doctor.sh`](../macos-initial-setup/workstation_doctor.sh)
and [`macos-initial-setup/hardening_audit.sh`](../macos-initial-setup/hardening_audit.sh),
which split the same way.

## `status.sh`

One-screen verdict. Read-only: no log, no sudo, no writes. The long
reports stay `system_doctor.sh` and `hardening_audit.sh`.

```bash
./status.sh
./status.sh --list-sections
./status.sh --only disk,git
```

`install_aliases.sh` exposes this as `linux-status`.

---

## `system_doctor.sh`

The first thing to run on a box someone has just handed you, and the thing to
run after `install_devtools.sh` to confirm the bootstrap took. It reads and
prints; there is no `--apply`.

```bash
./system_doctor.sh                       # the whole report
./system_doctor.sh --quiet               # only the warnings
./system_doctor.sh --min-free 25         # warn below 25% free on /
./system_doctor.sh --min-memory 20       # warn below 20% available RAM
./system_doctor.sh --max-psi 25          # warn when tasks stall over 25% of a minute
./system_doctor.sh --skip-containers     # don't wait on a wedged daemon
./system_doctor.sh --skip-units          # don't run 'systemctl --failed'
./system_doctor.sh --skip-remote-mounts  # don't probe NFS/CIFS/sshfs mounts
./system_doctor.sh --skip-smart          # don't ask smartctl for disk health
sudo ./system_doctor.sh                  # firewall rules need root to read
```

These sections: **system** (distribution, kernel, uptime, virtualisation, and
whether the kernel is tainted),
**sessions** (who is logged in),
**time** (timezone and NTP synchronisation),
**packages** (which manager owns the box, how old its index is, and how many
upgrades are pending — from the local index, no network),
**disk** (free space and *inodes* on `/`, other block-device mounts below the
threshold, and coredump file counts), **storage** (filesystems the kernel
remounted read-only, fstab mounts that are not mounted, degraded md arrays,
SMART health as root, and network mounts that no longer answer within five
seconds), **updates** (reboot pending), **services** (sshd,
`systemctl --failed`, and processes still running old libraries), **journal**
(error-level lines since boot, capped), **network** (which host
firewall is active, global IPv4 and IPv6 addresses), **containers** (docker/podman counts,
plus `system df` when the daemon answers — listed, never pruned), **load**
(one-minute average per core), **pressure** (CPU, memory and I/O stall time
from `/proc/pressure`, file handles, the connection tracking table, thread and
PID headroom, and zombie or uninterruptible processes), and **memory**
(available RAM, swap pressure, and OOM kills this boot).

Five of those exist because the ordinary tools hide them:

- **Inodes.** A filesystem out of inodes looks completely healthy in `df -h`,
  and "no space left on device" with gigabytes free is a confusing hour the
  first time.
- **Package index age.** Answered from the local index, so it needs no network.
  A machine whose index is months old reports itself up to date and is not.
- **A container engine that is installed but unreachable.** A stopped daemon
  and a user who is not in the `docker` group both look exactly like "no
  Docker here" until you try to use it.
- **A read-only remount, a missing mount, a degraded array.** After an I/O
  error the kernel remounts the filesystem read-only and everything keeps
  working until the next write; an fstab mount that failed at boot leaves its
  data on the root filesystem; an md array runs on one disk without a word.
  None of that shows in `df`. A mount that fstab declares `ro`, a bind mounted
  `:ro` and the ostree `/sysroot` are read-only on purpose and are not
  flagged. The evidence is fstab saying read-write while the live mount is
  read-only; the `errors=remount-ro` option is a policy, not an error, so a
  read-only mount with no fstab entry is not flagged. A hung NFS or CIFS
  mount blocks `df` itself, so each one is probed with a five-second `stat`
  that `--skip-remote-mounts` turns off. `PROC_DIR` and `FSTAB` point the
  section at other files; the tests use them.
- **Stalls, not load.** Load average counts tasks waiting on disk as busy and
  never sees a memory stall, so it is high on an idle box with a slow disk and
  low on one that is thrashing. Pressure stall information (Linux 4.20+) is the
  kernel's direct answer: the share of the last minute in which tasks waited
  for CPU, memory or I/O. It warns at `--max-psi` (10%) of the minute, or half
  that when every task stalled. Exhausted file handles, a full conntrack table
  (packets dropped without a word), thread or PID exhaustion and a pile of
  processes in D state are the other "everything is slow, errors are random"
  causes, and each is one line here.

Warnings do not change the exit code — it is `0` unless the machine is not
Linux (`2`) or you mistyped a flag (`3`). Something that fails a pipeline is
`hardening_audit.sh --fail-on warn`, which is why this script does not
duplicate it.

## `systemd/stay_fresh_timer.sh`

Maintenance that depends on remembering to run it does not happen. This writes a
`ops-toolbox-stay-fresh` service and timer into
`~/.config/systemd/user/` and enables them, the counterpart of
[`launchd/stay_fresh_agent.sh`](../macos-initial-setup/launchd/stay_fresh_agent.sh)
on macOS:

```bash
./systemd/stay_fresh_timer.sh install                      # Mondays, 10:30
./systemd/stay_fresh_timer.sh install --weekday daily --hour 3
./systemd/stay_fresh_timer.sh install --dry-run            # preview the install, write nothing
./systemd/stay_fresh_timer.sh install --print-only         # show the units, write nothing
./systemd/stay_fresh_timer.sh status
./systemd/stay_fresh_timer.sh run-now
./systemd/stay_fresh_timer.sh logs --lines 200
./systemd/stay_fresh_timer.sh uninstall
```

`--dry-run` previews the install — the units, the `daemon-reload` and the
`enable` — and writes nothing; `--print-only` prints the two unit bodies alone,
which is what CI parses. Neither reaches `stay_fresh.sh`: a scheduled run is
always `--yes --no-sudo`. Options belong to the command they follow, so
`uninstall --hour 3` is a usage error (exit 3) rather than a silent no-op, and
`uninstall` has no preview to ask for.

**A user timer cannot use `sudo`, and that is not a limitation to work around.**
It runs with no terminal attached, so a password prompt has nothing to prompt
and would fail or hang. The unit therefore always runs `--yes --no-sudo`, which
means these steps are **skipped** on every scheduled run:

- the package upgrade, autoremove and clean
- `journalctl --vacuum-time=14d`

Everything else — user caches, trash, `docker`/`podman` prune, flatpak and
snap — runs normally. Run `stay_fresh.sh` by hand when you want the root-owned
steps, or leave package updates to `unattended-upgrades` / `dnf-automatic.timer`,
which [`hardening_audit.sh`](hardening_audit.sh) already checks for.

Three details worth knowing:

- The units are checked with `systemd-analyze verify` **before** anything is
  written, so a malformed schedule never lands in `~/.config/systemd/user/`
  where systemd would complain about it on every reload.
- `Persistent=true` catches a run missed because the machine was off — once,
  not once per missed interval. `TimeoutStartSec=1h` overrides the 90-second
  default for a `oneshot` service, which would otherwise kill a real
  maintenance run part-way through. `Nice=10` with idle CPU and IO scheduling
  keeps it away from interactive work.
- A user timer only runs while you have a session, so `install` says so and
  prints the `loginctl enable-linger` command when lingering is off. On a
  headless box that step is the difference between a timer that fires and one
  that never does.

Output goes to the journal: `journalctl --user -u ops-toolbox-stay-fresh.service`.
`stay_fresh.sh` writes its own log under `$TMPDIR` during the run; a clean run
discards it, and a run with a failed step keeps it and prunes to the ten
newest.

## `install_aliases.sh`

The README one-liner that appends `. $PWD/bash_aliases.sh` to `~/.bashrc`
appends a second copy on every rerun and has no uninstall. This writes a
marked block once, replaces it if the path changes (with `--force`), and
takes the block back out on `--uninstall`. `~/.bashrc` is otherwise left
alone.

```bash
./install_aliases.sh --dry-run
./install_aliases.sh
./install_aliases.sh --status
./install_aliases.sh --uninstall --dry-run
```

Copied on its own into `~/bin`, the script has no aliases next to it and
says so: pass `--source FILE`. `--home DIR` points the install at a
directory other than `$HOME`, which is also how the tests exercise it.

Once sourced, `bash_aliases.sh` also defines hyphenated aliases for every
script in this folder that is sitting next to it (`stay-fresh`,
`linux-status`, `system-doctor`, `disk-cleanup`, …) and a `toolbox-help`
function that lists only the ones that are actually executable, the same
pattern as
[`macos-initial-setup/zsh_aliases.zsh`](../macos-initial-setup/zsh_aliases.zsh).

## `schedule_report.sh`

The question you ask when something ran at 3am and you do not know whose
job it was. Read-only: systemd user and system timers, whether lingering
is on (user timers otherwise only fire while you are logged in), the user
crontab, and the distro `cron.d` / `cron.{hourly,daily,weekly,monthly}`
drop-ins. A missing scheduler is a skip, not a failure — a container has
none of these.

```bash
./schedule_report.sh
./schedule_report.sh --quiet
```

Warnings do not change the exit code. For the stay_fresh timer itself,
use [`systemd/stay_fresh_timer.sh`](systemd/stay_fresh_timer.sh) `status`.

## `disk_cleanup.sh`

`stay_fresh.sh` is weekly maintenance and will upgrade packages. This is
"I need space now". It never upgrades, never prunes container volumes, and
never touches documents or downloads. Default targets are user-owned temp
files older than `--days` (7) plus thumbnail caches. Everything else is
behind an `--include-*` flag:

```bash
./disk_cleanup.sh --dry-run
./disk_cleanup.sh --yes
./disk_cleanup.sh --dry-run --include-trash --include-dev-caches
./disk_cleanup.sh --yes --include-journal --include-pkg-cache --no-sudo
./disk_cleanup.sh --dry-run --include-coredumps
```

A real run requires `--yes`, the same gate `install_devtools.sh` uses.
`--tmp DIR` replaces the default temp list (`/tmp` and `$TMPDIR`) so a
machine whose `/tmp` is not disposable can point at one directory.
`--include-coredumps` age-filters `/var/lib/systemd/coredump` and
`/var/crash`; `--coredump-dir DIR` replaces that list (and `/` is refused).
`--include-trash` empties `~/.local/share/Trash` whole — a trashed directory
goes with its `.trashinfo` record rather than being hollowed out, and a trash
relocated to another disk, with `files/` a symlink, is emptied where it
actually lives while the symlink survives. The two directories themselves stay,
as the FreeDesktop spec expects. `--include-docker` prunes dangling images,
stopped containers and build cache — never volumes, for the reason
`stay_fresh.sh` gives. `--home DIR` points the
user-owned targets at a home directory other than the caller's, and an
`XDG_CACHE_HOME` inherited from the environment is ignored while it is in
effect: that variable describes the caller's cache, and honouring both at once
deleted files outside the directory `--home` named.

## `net_doctor.sh`

`system_doctor.sh` already says which host firewall is in charge and lists
global addresses. This is the rest of the question you ask when "the
network is wrong": interfaces and operstate, the default IPv4 route, the
default IPv6 route (reported, not graded — v4-only is common), DNS
from `resolv.conf`, whether the local hostname resolves (the usual cause
of a multi-second `sudo` delay), listening sockets, and an optional
connectivity probe.

```bash
./net_doctor.sh
./net_doctor.sh --quiet
./net_doctor.sh --probe example.com
./net_doctor.sh --skip-listen
./net_doctor.sh --skip-links
```

The **links** section is what makes "the network is slow or flaky" concrete,
read from sysfs with no extra tool or privilege. For each physical NIC (one
with a device behind it; veth, bridges, tunnels and WireGuard are counted and
left alone) it warns when errors and drops exceed 0.1% of the packets since
boot and number at least 100, so a quiet link's handful never fires; on a
link that is up it warns on half duplex and on a speed of 100 Mb/s or less,
and it warns on ten or more carrier changes. It also reports a bond with a
slave down or no active slave, the uplink's MTU when it is below 1500, and the
default gateway's neighbour entry, warning when ARP or ND to it has failed.
`ethtool` appears only in the hints. `SYS_CLASS_NET` and `PROC_NET_BONDING`
point it at other directories; the tests use them.

It changes nothing, and warnings do not change the exit code — a missing
default route is something to read, not a gate. `--probe` is off by
default so a container with no uplink does not hang the report. Use
`hardening_audit.sh --only network` when you want findings, and
`listen_audit.sh` when you want to know which process owns each port.

## `listen_audit.sh`

`net_doctor.sh` prints the raw `ss -tuln` table and `hardening_audit.sh` counts
the sockets bound to every interface. This answers the questions after that:
which process owns each port, whether it answers on loopback or to the
network, and whether the set has changed since you last looked.

```bash
./listen_audit.sh                              # the table
./listen_audit.sh --public-only
sudo ./listen_audit.sh                         # process names of other users' sockets need root
sudo ./listen_audit.sh --print > /etc/listeners.baseline
sudo ./listen_audit.sh --baseline /etc/listeners.baseline
./listen_audit.sh --allow 22,80,443            # no file: these ports, any process
./listen_audit.sh --baseline FILE --fail-on any
```

The table has one row per listener: protocol, port, scope (`loopback`,
`wildcard`, or `other` for a specific address), the owning process and the
addresses it is bound to. IPv4 and IPv6 twins of the same socket are folded
into one row. Without root a process ss cannot see is shown as `?`.

`--print` writes the public listeners (all of them with `--all`) as a
baseline, one `proto/port/process` per line, sorted, with no pids, addresses
or date, so the same machine prints the same bytes and a diff means a change.
It goes to stdout; the script never writes the file. A baseline line may use
a port range (`tcp/8000-8100/*`), `*` as the process to match any, and `#`
comments.

`--baseline FILE` and `--allow PORTS` compare the live public listeners
(every listener with `--all`) with what is expected. A listener nothing
covers is a `NEW listener` FAIL; a single-port baseline entry that nothing
answers is an `expected listener ... is not listening` warning. Loopback
listeners satisfy neither side without `--all`, so a service rebound from
`0.0.0.0` to `127.0.0.1` reads as gone. When a process
name is hidden, that row is matched on protocol and port only. Both options
together apply both.

`--fail-on new` (the default once a baseline or allow-list is given) exits `1`
on a new listener, `any` also on a gone one, `never` not at all. Without
either option the script is a report and exits `0`. Exit codes: `0` no drift
at or above `--fail-on`, `1` drift, `2` not Linux or `ss` missing (usage errors
are answered first), `3` usage, an unreadable `--baseline`, a bad line in it,
or a bad `--allow` port.

The only command it runs is `ss -tulnp`. The baseline file is read line by
line and never evaluated, and process names are stripped of control
characters before they are printed.

## `sysctl_defaults.sh`

The counterpart of
[`macos-initial-setup/macos_defaults.sh`](../macos-initial-setup/macos_defaults.sh).
Read-only by default. `--apply` writes `/etc/sysctl.d/99-ops-toolbox.conf`
and applies the values live; `--revert` restores the backup from the last
apply and removes the drop-in.

The list is short on purpose: inotify watcher/instance/queue ceilings that
IDEs exhaust, and `vm.swappiness=10` for a workstation that should prefer
RAM. Kernel networking tweaks and container-host `max_map_count` stay out.

```bash
./sysctl_defaults.sh
./sysctl_defaults.sh --only inotify
./sysctl_defaults.sh --apply --dry-run
sudo ./sysctl_defaults.sh --apply
sudo ./sysctl_defaults.sh --revert
sudo ./sysctl_defaults.sh --apply --backup-file /root/sysctl.before
sudo ./sysctl_defaults.sh --revert-from /root/sysctl.before
```

`--backup-file PATH` puts the pre-apply backup somewhere other than the default,
and `--revert-from PATH` restores from a named one instead of the last apply's.
Both exist so a revert can be run from a machine image or a runbook that keeps
the backup alongside its own state.

`SYSCTL_D` and `PROC_SYS` are honoured so the apply path is testable
without writing into `/etc`. `--apply` without root exits `2`; preview
with `--dry-run` instead.

## `tls_expiry.sh`

The Linux counterpart of
[`mikrotik/features/cert_expiry_watch.lua`](../mikrotik/features/cert_expiry_watch.lua).
Read-only. It reports when a **leaf** certificate has expired or will expire
within `--days` (30). It never walks `/etc/ssl/certs`: that directory is a CA
trust store, and a distro root expiring next month is not your outage.

Name every PEM or hostname you actually serve:

```bash
./tls_expiry.sh --file /etc/letsencrypt/live/example/fullchain.pem
./tls_expiry.sh --file '/etc/letsencrypt/live/*/fullchain.pem'
./tls_expiry.sh --host example.com --host example.com:8443
./tls_expiry.sh --file ./leaf.pem --days 14 --fail-on warn
./tls_expiry.sh --hosts-file /etc/tls-endpoints.txt --deep
./tls_expiry.sh --file ./leaf.pem --check-host www.example.com
```

`--fail-on expired` (the default) exits `1` only when a cert is already dead;
`--fail-on warn` also fails inside the window, so a cron job can page before
clients do. Missing `openssl` is exit `2`; `--help` and a missing `--file`
still work without it.

Expiry is half of a certificate outage; the other half is a certificate that
is valid and wrong. `--check-host NAME` fails when the certificate does not
cover `NAME` (`-checkhost`, or `-checkip` for an address). `--deep` adds the
rest: the name check for every `--host` target (its own name unless
`--check-host` overrides it), the chain as the handshake verified it against
the system trust store (a self-signed one warns; an expired one is the expiry
check's finding and is not counted twice). When no issuer is found, the chain
fails as incomplete ("serve fullchain.pem") only when that is provable: the
server sent no CA certificate at all and the issuer of the last certificate it
sent is not in the trust store. Otherwise, for example when the intermediate
was sent and the private root is simply not on this machine, it warns "issuer
not trusted locally: private CA or missing intermediate"; `--cafile FILE`
supplies that root and replaces system trust: both the handshake
(`openssl s_client`) and the missing-intermediate probe (`openssl verify`)
are given `-no-CApath` and `-no-CAstore` when the local openssl lists them
(`-no-CAstore` is OpenSSL 3.0+). When this openssl cannot drop its default
trust sources, the output says system trust sources may still apply.
The checks also cover a self-signed issuer on a `--file` target, the
key size against `--min-key-bits` (2048), the EC curve, and MD5 or SHA-1
signatures.
The chain comes from the same single handshake the expiry check makes.
`--hosts-file FILE` reads one `HOST[:PORT]` per line, with `#` comments; an
unreadable file is exit `3` before anything else runs. An IPv6 address is
written in brackets, `[2001:db8::1]` or `[2001:db8::1]:8443` (port 443 when
omitted); an unbracketed one is refused as ambiguous.

With the default `--fail-on expired`, a FAIL from these checks (wrong name,
provably missing intermediate, short key, weak signature) exits `1` too, and a
warning (self-signed, issuer not trusted locally, unusual curve) exits `1`
only with `--fail-on warn`.

## `container_doctor.sh`

`system_doctor.sh` counts containers and prints `system df`. The things that
page somebody are not in that count: a container in a restart loop, one the
kernel OOM-killed, an unhealthy healthcheck, a `json-file` log with no size cap
filling `/var/lib/docker`, a privileged container, or one with the engine
socket mounted, which is root on the host by another name. This grades them,
one `inspect` per container, and prints the command to look closer or the
change to make.

```bash
./container_doctor.sh                       # docker, or podman if docker does not answer
./container_doctor.sh --engine podman
./container_doctor.sh --only state,logs
./container_doctor.sh --restart-threshold 5 --log-warn-mb 1024
sudo ./container_doctor.sh                  # log files under /var/lib/docker need root to size
./container_doctor.sh --fail-on fail        # exit 1 on any FAIL, for cron or CI
```

| Group | Graded |
| --- | --- |
| `state` | restarting, or at least `--restart-threshold` restarts (warn); OOM-killed (FAIL); unhealthy healthcheck (FAIL); exited non-zero with no restart policy, or under `on-failure:N` with its N restarts used up (warn) |
| `security` | privileged (warn); `docker.sock` or `podman.sock` mounted (FAIL); host network and containers with no `USER` (info) |
| `resources` | running containers with no memory limit (info, up to five named) |
| `logs` | `json-file` with no `max-size` in the container or the daemon default (warn); a log at or above `--log-warn-mb` MiB (FAIL) |
| `images` | dangling images and the `system df` image row (info); containers on `latest` or an untagged image (info) |

It changes nothing. The engine verbs it runs are `info`, `version`, `ps`,
`inspect`, `images` and `system df`, each under `timeout 10` when timeout(1)
exists, so a wedged daemon cannot hang it. Fixes such as the `daemon.json`
`log-opts` block are printed, never written; the daemon file is only read
(`DOCKER_DAEMON_JSON` points the check at another file). Container names and
image strings have control characters stripped before they are printed.
Neither engine installed is a `skip`; installed but not answering is a `warn`
with the two usual causes. Cleaning up is a separate, previewed step:
`disk_cleanup.sh --dry-run --include-docker`.

`--fail-on` defaults to `never`, so like `system_doctor.sh` it reads rather
than gates. Exit codes: `0` report printed, `1` findings at or above
`--fail-on`, `2` not Linux, `3` usage, `4` `--only` selected nothing.

## `log_triage.sh`

`system_doctor.sh` says whether the machine is well now, and shows at most
twenty raw error lines since boot. This is the history question that comes
next: what has been breaking, who is knocking, and what the kernel complained
about, grouped over a window instead of dumped.

```bash
./log_triage.sh                          # the last 24 hours
./log_triage.sh --since "2 days ago" --top 10
./log_triage.sh --only kernel,auth
./log_triage.sh --list-sections
sudo ./log_triage.sh                     # the system journal needs root or the adm/systemd-journal group
./log_triage.sh --fail-on warn           # exit 1 when anything warned
```

Four sections, each selectable with `--only`:

- **kernel** counts the kernel's own distress signals by class (OOM kills,
  segfaults and protection faults, storage I/O errors, filesystem errors and
  read-only remounts, hung tasks and soft lockups, machine-check and EDAC
  hardware errors, link drops), shows the first line of each and prints the
  `journalctl -k -g` that lists the rest. Without a readable journal it falls
  back to `dmesg`, which covers everything since boot.
- **units** ranks the syslog identifiers that logged the most error-level
  lines, and warns on any with fifty or more.
- **auth** counts failed SSH logins, groups them by source address, names the
  first three invalid user names tried, counts accepted logins and failed
  `sudo`, and warns at twenty failures or ten from one address. It reads the
  journal (`ssh` and `sshd` units, the `sudo` identifier) and falls back to
  `/var/log/auth.log` or `/var/log/secure` when the journal holds none, since
  rsyslog copies the same lines into both. `AUTH_LOG` names a file to read as
  well.
- **repeats** lists the most repeated warning-level messages, with hex and
  digit runs folded so a message with a changing counter counts as one.

It writes nothing and runs nothing but `journalctl`, `dmesg` and text tools.
Every section prints a bounded number of lines whatever the log holds, log
text has its control characters stripped before it is printed, and
authentication lines are reduced to counts, addresses and names: a password
never reaches the report. `--since` takes what `journalctl --since` reads,
held to letters, digits, spaces and `: . + -` and refused when it starts with
a dash, so it can never become a journalctl option.

Exit codes: `0` report printed (warnings do not change it), `1` warnings with
`--fail-on warn`, `2` not Linux, `3` usage, `4` `--only` selected nothing.

## `config_backup.sh`

A dated tar of selected paths so an upgrade or an edit has something to roll
back to. Default source is `/etc`. Home directories, databases and container
volumes stay out — those are backups with a different blast radius. This is a
copy, not a restore: it never writes back into the paths it archives.

```bash
./config_backup.sh --dry-run
./config_backup.sh --yes
./config_backup.sh --list
./config_backup.sh --yes --paths /etc/ssh,/etc/nginx --dest ~/ops-toolbox-backups --keep 5
./config_backup.sh --yes --prefix nginx-pre-upgrade
```

`--prefix NAME` replaces `config` in the archive name, which is what `--keep`
counts within — two prefixes retain independently.

A real run requires `--yes`. `--list` shows the newest archive (or a named
file) and writes nothing. `--keep 0` disables rotation. Archives land in
`~/ops-toolbox-backups` unless `--dest` says otherwise. `--paths` must be
absolute; `/` is refused.

The archive is created mode `0600`, whatever umask the caller had. The default
source is `/etc`, and a run that can read all of it is a run with `shadow`, the
sshd host keys and `sudoers` in the tarball. `--dest` keeps the mode it already
has: the secret is the file, not the directory holding it.

Each run creates a private staging directory in `--dest`, validates the gzip
stream and a nonempty tar member listing, and publishes a unique timestamped
name with an atomic hard link. An occupied filename or symlink is never overwritten or followed.
Concurrent publication and rotation use `flock` from util-linux; the destination
filesystem must support hard links and advisory locking. The destination and
its parent directories must not be writable by untrusted users. Staging is
removed on normal exit and handled signals. A forced kill may leave a hidden
staging directory, which is excluded from listing and retention.

Tar exit `0` with every requested source present produces a complete archive.
Tar exit `1` with a valid archive, or a skipped missing requested path, produces
a `*.partial.tar.gz` archive and exits `1` with a warning. Fatal tar errors,
invalid archives, and staging or publication failures publish nothing and leave
previous generations intact. Rotation starts only after successful publication.
`--keep N` retains up to N complete archives and N partial archives separately;
a partial run rotates only partial archives, preserving every complete copy.
`--keep 0` retains all generations. `--list` includes both kinds, with the
filename identifying a partial backup.

## `ssh_client_doctor.sh`

`hardening_audit.sh` grades **sshd**.
[`git/git_ssh_doctor.py`](../git/git_ssh_doctor.py) asks `ssh -G` why a git
remote will not accept a key. Neither looks at `~/.ssh` itself: a directory
that is group-readable, a private key at `644`, or an `IdentityFile` that
points at a path that does not exist. Those are the three reasons ssh refuses
a key with a message that names none of them. Past whether ssh will use a key
is whether it should, and the later groups grade that too.

```bash
./ssh_client_doctor.sh
./ssh_client_doctor.sh --quiet
./ssh_client_doctor.sh --fail-on warn
./ssh_client_doctor.sh --only keys,risks
./ssh_client_doctor.sh --max-key-age 365
./ssh_client_doctor.sh --list-groups
```

| Group | Graded |
| --- | --- |
| `directory`, `files`, `config` | the modes and missing `IdentityFile` paths above |
| `keys` | a private key with no passphrase (warn), DSA (FAIL), RSA under 3072 bits (warn) or under 2048 (FAIL), ECDSA (info), keys older than `--max-key-age` days (730; `0` turns it off), the same key in two files (info) |
| `known_hosts` | unhashed entries (info, with `ssh-keygen -H`), `ssh-dss` host keys (FAIL), one host with two different keys of the same type (warn), `@revoked` lines (info) |
| `authorized_keys` | duplicate keys (warn), `ssh-dss` keys (FAIL), keys with no `from=`, `command=` or `restrict` (info) |
| `risks` | `StrictHostKeyChecking no` for every host (FAIL); `UserKnownHostsFile /dev/null`, `ForwardAgent`, `ForwardX11` or `PasswordAuthentication yes` for every host (warn); `Protocol 1` and CBC or arcfour ciphers (warn); several global `IdentityFile` lines without `IdentitiesOnly yes` (info). `Match all` and `Match host *` count as every host. A setting under a narrower `Host` or `Match` (including `Host *` with a `!pattern`, or a `Host *` value for a keyword an earlier block already sets, since OpenSSH keeps the first value) is noted, not graded, and each finding names its config line |
| `agent` | whether `SSH_AUTH_SOCK` reaches a live agent (a dead one warns) and how many keys it offers (more than five warns) |

The passphrase check runs `ssh-keygen -y -P ''` with stdin closed, which
derives the public key to `/dev/null` and fails on an encrypted key, so it
can never prompt; type and size come from `ssh-keygen -l` on the private
file (the `.pub` beside it is the fallback; both failing is a `skip`), and `ssh-add -l` only lists the agent. Key material is never
printed. Without `ssh-keygen` the `keys` group is one `skip`.

`--ssh-dir DIR` is the seam the tests use, and the way to inspect an
alternate config directory. This script does not reimplement `ssh_config`
parsing; Include globs and host-specific key selection stay in
`git_ssh_doctor.py`.

## Scoped runs and kernel checks

`stay_fresh.sh --only` accepts `packages`, `journal`, `caches`, `containers`,
`flatpak`, and `snap`; `install_devtools.sh --only` accepts `clis`, `python`,
`go`, `terraform`, and `helm`. Use `--list-steps` or `--list-groups` to print
the accepted values. `--only` cannot be mixed with the existing `--skip-*`
flags, keeping a targeted run unambiguous.

The hardening audit now includes a `kernel` group. It reads procfs only and
grades ASLR, kernel-pointer and kernel-log exposure, protected hard/symbolic
links, unprivileged BPF, and whether AppArmor or SELinux is actually
enforcing (presence in the LSM list is not enough). The `files` group also
grades SSH host private key modes, and `updates` warns when unattended
upgrades are configured but the stamp is missing or older than 14 days:

```bash
./hardening_audit.sh --only kernel
./hardening_audit.sh --only ssh,kernel --fail-on warn
./hardening_audit.sh --only files,updates
```

The `ssh` group grades the settings an sshd audit asks about beyond root
login and passwords: `MaxAuthTries` (above 4 warns), `X11Forwarding`,
`AllowAgentForwarding` and `AllowTcpForwarding` (warn when on, which is
intentional on a bastion), `LoginGraceTime` (`0` fails, above 60 seconds
warns), `ClientAliveInterval` times `ClientAliveCountMax` as a
connection-liveness check (count 3 when unset; it drops a client that
stops answering probes, not an idle user; a window over 900 seconds, an
interval of `0` or a count of `0` warns), `ChannelTimeout` for the idle
bound (OpenSSH 9.2+; an `info` line when none is set, none covers
`session`, or `session=0` turns it off; a pass for e.g.
`ChannelTimeout session=30m`), `PermitUserEnvironment yes`,
`HostbasedAuthentication yes` and `IgnoreRhosts no` (each a FAIL),
`PubkeyAuthentication no` and a `PermitTunnel` other than `no` (warn). A
setting that is not set is graded by the OpenSSH default, and none of the
FAIL-level ones is at its default on OpenSSH 8 or 9. Weak ciphers, MACs
and key exchange (CBC and arcfour ciphers, MD5 and SHA-1 MACs, SHA-1
Diffie-Hellman) warn and `ssh-dss` host keys fail, graded only from
`sshd -T`, so they need root; without it they are one `skip`. Each hint
prints the line to add, with the `-name` removal syntax for algorithm
lists (OpenSSH 7.5+). `sshd -T` is read without `-C`, so `Match` blocks
are not evaluated: a setting overridden for one user or address is graded
by its global value.

These remain findings rather than automatic fixes: a container or deliberately
permissive development host can validly differ from a server baseline.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success |
| `1` | One or more steps failed, or a graded report (`hardening_audit.sh`, `tls_expiry.sh`, `ssh_client_doctor.sh`) found something at or above `--fail-on` |
| `2` | Preflight failed — unsupported distribution, not Linux, or no systemd user manager for the timer |
| `3` | Invalid usage, or an install was requested without `--yes` |
| `4` | `install_aliases.sh --status` found the block missing or drifted, or `--uninstall` found no block to remove |

`system_doctor.sh` never returns `1`: it reports, and what it finds is for you
to read rather than for a pipeline to act on.

## Tests

```bash
./tests/run.sh                     # debian only, the default
LINUX_DISTROS=all ./tests/run.sh   # debian + fedora + arch
./run-tests.sh linux               # from the repository root
```

This is the only package whose tests **run** the scripts rather than only
parsing them, because the container is the target OS. They assert that
detection picks the right package manager, that an unsupported distro exits 2,
that `--dry-run` leaves the package count byte-identical, that `packages.sh`
round-trips through a real package database and is stable across runs, that
requesting an install without `--yes` refuses, that a missing optional tool
degrades to a warning instead of a failure, that `install_aliases.sh` is
idempotent and that its dry run writes nothing, that `disk_cleanup.sh`
honours `--days` against real files (and `--include-coredumps` against
`--coredump-dir`), that `sysctl_defaults.sh` can apply
and revert against a fake procfs without touching `/etc`, that
`config_backup.sh` writes a tar of `--paths` into `--dest` and honours
`--keep`, that `ssh_client_doctor.sh` grades modes under `--ssh-dir`, and
that `tls_expiry.sh` treats a committed expired PEM as a failure when
`openssl` is present (and as exit `2` when it is not), and that
`log_triage.sh` parses a stub journal and auth log without ever passing
journalctl anything but reads, that `container_doctor.sh` grades a stub
engine's containers while running only read-only engine verbs, and that
`listen_audit.sh` folds a stub `ss` table into owners and reports baseline
drift with the documented exit codes.

Discovery is by `find`, two levels deep, so `systemd/` is covered as well.
A container has no user manager, so the timer can only be exercised through
`--print-only` — which is precisely why that flag exists: on the images that
ship `systemd-analyze`, printing the units also verifies them.

Image tags are pinned. Arch is rolling and Fedora moves quickly; an unpinned
base would let an upstream change redden an unrelated pull request.
