# Linux scripts

[Ops Toolbox](../README.md) / **Linux scripts**

Bootstrap and maintenance for a Linux machine — the counterpart of
[`macos-initial-setup/`](../macos-initial-setup/), for servers and workstations
rather than a Mac.

**Targets:** Debian/Ubuntu (`apt`), Fedora/RHEL (`dnf`) and Arch (`pacman`).
The four scripts that install or remove packages — `stay_fresh.sh`,
`install_devtools.sh`, `packages.sh`, `kernel_cleanup.sh` — exit `2` on
anything else and say what they detected, the same way the macOS scripts exit `2` off macOS. The two that
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
- [`kernel_cleanup.sh`](#kernel_cleanupsh)
- [`net_doctor.sh`](#net_doctorsh)
- [`sysctl_defaults.sh`](#sysctl_defaultssh)
- [`swap_setup.sh`](#swap_setupsh)
- [`tls_expiry.sh`](#tls_expirysh)
- [`config_backup.sh`](#config_backupsh)
- [`ssh_client_doctor.sh`](#ssh_client_doctorsh)
- [Scoped runs and kernel checks](#scoped-runs-and-kernel-checks)
- [Exit codes](#exit-codes)
- [Tests](#tests)

| File | Purpose |
| --- | --- |
| [`install_devtools.sh`](install_devtools.sh) | Install Python, Go, Terraform, Helm and the DevOps CLIs |
| [`stay_fresh.sh`](stay_fresh.sh) | Recurring maintenance: upgrades, journal, caches, containers |
| [`disk_cleanup.sh`](disk_cleanup.sh) | Free space now: age-filtered temp, opt-in trash/journal/caches/coredumps/rotated logs/unused images/old snaps; never volumes |
| [`kernel_cleanup.sh`](kernel_cleanup.sh) | Remove old kernel packages; keeps the running kernel plus the newest `--keep` |
| [`status.sh`](status.sh) | One-screen verdict. Selectable sections via `--only` / `--list-sections`. |
| [`system_doctor.sh`](system_doctor.sh) | Read-only health report: disk, memory, clock, reboot, services, firewall, containers, load, taint |
| [`net_doctor.sh`](net_doctor.sh) | Read-only network report: interfaces, default IPv4/IPv6 route, DNS, listening sockets |
| [`hardening_audit.sh`](hardening_audit.sh) | Read-only security audit: sshd, accounts, network, file modes, host keys, updates, kernel controls |
| [`ssh_client_doctor.sh`](ssh_client_doctor.sh) | Read-only `~/.ssh` modes and IdentityFile paths; not `ssh -G` |
| [`tls_expiry.sh`](tls_expiry.sh) | Read-only leaf certificate expiry for named PEMs and hostnames |
| [`sysctl_defaults.sh`](sysctl_defaults.sh) | Report/apply/revert a short sysctl list (inotify watches, swappiness) |
| [`swap_setup.sh`](swap_setup.sh) | Report swap; `--create` or `--remove` a swapfile and its fstab line |
| [`packages.sh`](packages.sh) | Capture and restore the explicitly-installed package set; list holds and autoremove orphans |
| [`config_backup.sh`](config_backup.sh) | Dated tar of selected paths (default `/etc`); never a restore |
| [`schedule_report.sh`](schedule_report.sh) | Read-only inventory of systemd timers and cron jobs; `--failed` finds the broken ones |
| [`cloud-init/kali-vm-init.yaml`](cloud-init/kali-vm-init.yaml) | First-boot configuration for a Kali red/blue lab VM; see the [runbook](cloud-init/README.md) |
| [`bash_aliases.sh`](bash_aliases.sh) | Guarded aliases and helpers, sourced from `~/.bashrc` |
| [`install_aliases.sh`](install_aliases.sh) | Install or remove the `bash_aliases.sh` source block in `~/.bashrc` |
| [`systemd/stay_fresh_timer.sh`](systemd/stay_fresh_timer.sh) | Install a user timer so `stay_fresh.sh` runs on a schedule |
| [`tests/`](tests/) | Docker checks that **run** the scripts, across all three distros |

## Requirements

| Requirement | Notes |
| --- | --- |
| **Linux** | Every script here exits `2` on anything else. |
| **One of `apt`, `dnf` or `pacman`** | Only the six scripts that read `/etc/os-release` care — see [Distro detection](#distro-detection). Four of them (`stay_fresh.sh`, `install_devtools.sh`, `packages.sh`, `kernel_cleanup.sh`) exit `2` on a distribution they do not know; `disk_cleanup.sh` warns and skips package caches, and `system_doctor.sh` prints a `skip` line. The other ten never ask. |
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
./kernel_cleanup.sh --dry-run
./config_backup.sh --dry-run

./stay_fresh.sh --yes
./install_devtools.sh --yes --setup-shell
./disk_cleanup.sh --yes
./kernel_cleanup.sh --yes
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
./packages.sh holds         # held, version-locked or ignored: what upgrades skip
./packages.sh orphans       # what autoremove would remove, before it does
./packages.sh install --dry-run
./packages.sh install --yes
```

Read the machine without touching it:

```bash
./status.sh                 # one-screen verdict
./system_doctor.sh          # is this machine well?
./net_doctor.sh             # is this machine reachable?
./hardening_audit.sh        # is this machine safe?
./ssh_client_doctor.sh      # is ~/.ssh something ssh will actually use?
./tls_expiry.sh --file /etc/ssl/private/example.pem
./sysctl_defaults.sh        # current vs desired sysctl values
./swap_setup.sh             # active swap, fstab entries, a suggested size
./schedule_report.sh        # what is scheduled to run?
```

`holds` and `orphans` answer the two questions before maintenance: why did the
upgrade skip nginx, and what will autoremove delete? Both are read-only, need
no `sudo`, and print bare package names, one per line and sorted, with nothing
else on stdout (a note, such as dnf's versionlock plugin being absent, goes to
stderr), so they pipe like `list`. Empty output means none. `holds` reads
`apt-mark showhold`, dnf's versionlock list plus `exclude=` in
`/etc/dnf/dnf.conf`, or `IgnorePkg` in `/etc/pacman.conf`. `orphans` reads
`apt-get -s autoremove` (a simulation), `dnf repoquery --unneeded` or
`pacman -Qdtq`, whose exit `1` with no output means none. A failing package
tool is exit `1`.

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
| **Space** | `disk_cleanup.sh` | When `/` is full | age-filtered temp; opt-in trash/journal/caches/coredumps/rotated logs; never volumes |
| **Space** | `kernel_cleanup.sh` | When `/boot` is full or an upgrade fails for space | old kernel packages; keeps the running one plus `--keep`; never autoremoves |
| **Copy** | `config_backup.sh` | Before editing `/etc` or upgrading | a dated tar under `--dest`; never writes back |
| **Copy** | `packages.sh` | After a machine looks the way you want | a package list you can commit and restore |
| **Configure** | `sysctl_defaults.sh` | Once, then after a new IDE exhausts inotify; `--check` from cron | `/etc/sysctl.d/99-ops-toolbox.conf`; read-only unless `--apply`/`--revert` |
| **Configure** | `swap_setup.sh` | Once on a box with no swap, before the first OOM kill | a swapfile and one marked `/etc/fstab` line; read-only unless `--create`/`--remove` |
| **Diagnose** | `status.sh` | After bootstrap, or when something feels wrong | nothing — it only reads |
| **Diagnose** | `system_doctor.sh` | After bootstrap, or when something feels wrong | nothing — it only reads |
| **Diagnose** | `net_doctor.sh` | When "the network is wrong" | nothing — it only reads |
| **Diagnose** | `schedule_report.sh` | When something ran at 3am, or `--failed` when something did not | nothing — it only reads |
| **Diagnose** | `hardening_audit.sh` | Before trusting a machine with anything | nothing — it only reads |
| **Diagnose** | `ssh_client_doctor.sh` | When `Permission denied (publickey)` and the key is on disk | nothing — it only reads |
| **Diagnose** | `tls_expiry.sh` | Monthly, or from cron | nothing — it only reads |

`stay_fresh.sh` assumes a supported package manager but degrades if optional
tools (docker, snap, journalctl) are missing. The diagnose scripts never
change the machine; `hardening_audit.sh` is the one whose exit code can gate
a pipeline by default, and `schedule_report.sh --strict` joins it on request.

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

The six scripts that need a package manager — `disk_cleanup.sh`,
`install_devtools.sh`, `kernel_cleanup.sh`, `packages.sh`, `stay_fresh.sh`,
`system_doctor.sh` — read `/etc/os-release` and map `ID`/`ID_LIKE` onto one.
The other ten never ask. The lookup is duplicated in each script rather than
shared, for the reason in [`CONTRIBUTING.md`](../CONTRIBUTING.md): a script
has to work when copied on its own onto a box.

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
| sshd | Says whether it is installed and running | Grades `PermitRootLogin`, password auth, empty passwords |
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
./system_doctor.sh --skip-containers     # don't wait on a wedged daemon
./system_doctor.sh --skip-units          # don't run 'systemctl --failed'
sudo ./system_doctor.sh                  # firewall rules need root to read
```

These sections: **system** (distribution, kernel, uptime, virtualisation, and
whether the kernel is tainted),
**sessions** (who is logged in),
**time** (timezone and NTP synchronisation),
**packages** (which manager owns the box, how old its index is, and how many
upgrades are pending — from the local index, no network),
**disk** (free space and *inodes* on `/`, other block-device mounts below the
threshold, and coredump file counts), **updates** (reboot pending), **services** (sshd,
`systemctl --failed`, and processes still running old libraries), **journal**
(error-level lines since boot, capped), **network** (which host
firewall is active, global IPv4 and IPv6 addresses), **containers** (docker/podman counts,
plus `system df` when the daemon answers — listed, never pruned), **load**
(one-minute average per core), and **memory** (available RAM, swap
pressure, and OOM kills this boot).

Three of those exist because the ordinary tools hide them:

- **Inodes.** A filesystem out of inodes looks completely healthy in `df -h`,
  and "no space left on device" with gigabytes free is a confusing hour the
  first time.
- **Package index age.** Answered from the local index, so it needs no network.
  A machine whose index is months old reports itself up to date and is not.
- **A container engine that is installed but unreachable.** A stopped daemon
  and a user who is not in the `docker` group both look exactly like "no
  Docker here" until you try to use it.

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
./schedule_report.sh --failed                 # which scheduled thing is broken?
./schedule_report.sh --failed --strict        # the same, as a gate: exit 1 on a warning
./schedule_report.sh --failed --cron-dir /srv/cron.d
```

Without `--strict`, warnings do not change the exit code, and with none of the
new flags the output is exactly what it was. For the stay_fresh timer itself,
use [`systemd/stay_fresh_timer.sh`](systemd/stay_fresh_timer.sh) `status`.

`--failed` adds a `failed` group after `cron.d`, for the 3am question: which
scheduled thing is broken? A timer whose service failed on its last run looks
perfectly normal in `list-timers`, so for the system and the user manager it
maps each timer to the unit it activates (`systemctl show -p Unit`) and warns
when that unit is in `systemctl list-units --state=failed`, with
`journalctl -u SERVICE -n 50 --no-pager` (`--user` for user units) as the fix.
A `systemctl` that cannot answer, as in a container, is a `skip`, never a
warning. For cron it reads the user crontab and every file in the cron
directory (skipping `.placeholder`, `*.dpkg-*` and `*.rpm*`), takes the first
word of each job's command (after five time fields or an `@keyword`, plus the
user field in `cron.d`), and warns when that is an absolute path that is not an
executable file: the job an upgrade quietly orphaned. Comments, blank lines
and `NAME=value` lines are not jobs, and a word without a slash is not judged,
since it may be a builtin or a `PATH` lookup. Nothing is run, sourced, started,
stopped or reset.

`--strict` exits `1` when any warning was printed, with or without `--failed`,
so lingering being off counts too. `--cron-dir DIR` replaces `/etc/cron.d` for
both the `cron.d` group and the check, which is also how the tests point it at
a fixture. Exit codes: `0` report printed, `1` `--strict` and at least one
warning, `2` not Linux, `3` bad usage.

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
./disk_cleanup.sh --dry-run --include-logs --days 14
./disk_cleanup.sh --dry-run --include-docker-images --days 30
sudo ./disk_cleanup.sh --yes --include-snap-revisions
sudo ./disk_cleanup.sh --yes --include-journal --journal-max-size 500M
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

`--include-logs` removes rotated logs older than `--days` under `/var/log`, the
usual space hog on a server that is not journald-only. A file qualifies only when
its name proves it was rotated: `*.gz`, `*.xz`, `*.bz2`, `*.zst`, a numeric
suffix (`*.1` to `*.99`), `*.old`, logrotate's `dateext` (`syslog-20260101`) or
`*.log-<digits>` (digits only, so `service.log-2-current` stays). An active
`*.log`, `syslog` or `messages` never matches, and neither do numbered active
logs such as `Xorg.0.log`. Login records (`wtmp`, `btmp`, `lastlog`, `faillog`,
`utmp` and their rotations) are never touched,
anything below a directory named `journal` or `private` is pruned from the
walk, symlinks are not followed and `-xdev` keeps it on one filesystem. Nothing
is truncated. `--days 0` drops the age filter but not the name filter.
`--log-dir DIR` replaces `/var/log` (repeatable, `/` refused in every spelling)
and needs `--include-logs`. Root-owned logs go through the same `sudo` retry as
coredumps; under `--no-sudo` a log in a directory this run cannot write is
counted as skipped, not failed. As a non-root user the walk runs under `sudo`
only if `sudo -n true` succeeds (checked once, never prompting, so `--dry-run`
stays silent); otherwise it walks unprivileged, warns that unreadable
subdirectories were skipped, and still reports every log it can read.

`--journal-max-size SZ` adds `journalctl --vacuum-size=SZ` after the age vacuum
of `--include-journal`, for when you think in "cap it at 500M" rather than in
days. `SZ` is a number with an optional `K`, `M`, `G` or `T`; anything else, or
the flag without `--include-journal`, is exit `3`. journald's own vacuum is the
only thing that deletes journal files.

`--include-docker-images` is for CI runners and build hosts, where the space
goes to tagged images created long ago and no longer used. `--include-docker`
removes only dangling images, stopped containers and build cache; this runs
`docker image prune -a -f --filter until=<days*24>h` when `docker info` answers,
and the same through `podman` when it is installed, so only images created
more than `--days` ago with no container referencing them go (the engine
refuses the rest). The `until` filter reads an image's creation time, not when
it was pulled or last used: an old image pulled today is still eligible, and
nothing here spares a fresh pull.
`--days 0` drops the `until` filter, with a warning. The dry run prints the
command and the read-only `docker system df` beneath it. Volumes are never
passed to any prune; re-pulling an image is a cost, not a loss, which is why
this is its own flag. Podman keeps separate rootless and rootful image stores,
and the run cleans only the store of the user running it, the same caveat the
low-disk runbook carries for `--include-docker`.

`--include-snap-revisions` removes the revisions snapd keeps marked `disabled`
in `snap list --all`, one `snap remove NAME --revision=REV` each through the same
root handling as the journal (skipped under `--no-sudo`, previewed by
`--dry-run`). The active revision is never named. Without `snap` it says so and
carries on; afterwards it suggests `snap set system refresh.retain=2` as text.

## `kernel_cleanup.sh`

A `/boot` full of old kernels is the classic reason an upgrade fails half-way
through, and `apt-get autoremove` is not a reliable pruner: a kernel installed
by hand, or marked manual by an installer, is never auto-removable. This names
the old kernels and removes them deliberately.

```bash
./kernel_cleanup.sh --list                 # running / keep / remove, read-only
./kernel_cleanup.sh --dry-run              # the exact removal, written nowhere
sudo ./kernel_cleanup.sh --yes
./kernel_cleanup.sh --dry-run --keep 1     # keep only one besides the running kernel
```

| Option | Meaning |
| --- | --- |
| `--list` | Table of installed kernels marked `running`, `keep` or `remove`, then `df -h /boot` when `/boot` is its own filesystem. Read-only; needs no `--yes`. |
| `--keep N` | Newest kernels to keep besides the running one, `1` to `20` (default `2`). `0` is refused. |
| `--dry-run` | Print the removal command and the space it would free; write nothing. |
| `--yes`, `-y` | Required for a run that removes anything. |
| `--no-sudo` | Skip the removal with a warning instead of escalating. |
| `--release VER` | Treat `VER` as the running kernel instead of `uname -r`. For a chroot, and the seam the tests use. |

The keep set is the running kernel, the newest `--keep` kernels besides it and
the newest installed one, and at least two kernels always stay installed: when
the running kernel is not an installed package and `--keep 1` leaves only the
newest, the next-newest is kept too, with a warning. Releases are ordered by
version (`sort -V`), so `6.1.0-9` sorts before `6.1.0-10`. Only versioned
packages are candidates; metapackages such as `linux-image-amd64`,
`linux-image-generic` or an unversioned `kernel` never match. When `uname -r`
names a kernel that is not installed — a container or a chroot — the script
says so and keeps the newest instead. It refuses (exit `2`) rather than
guesses when it cannot determine the running release at all.

On apt each old release expands to whichever of `linux-image-REL`,
`linux-image-unsigned-REL`, `linux-modules-REL`, `linux-modules-extra-REL` and
`linux-headers-REL` are installed, removed in one `apt-get purge --yes`. On dnf
the versioned `kernel`, `kernel-core`, `kernel-modules`, `kernel-modules-core`,
`kernel-modules-extra` and `kernel-devel` packages go in one `dnf remove -y`.
pacman keeps one copy of each kernel package, so the script says there is
nothing to prune and exits `0`. It never runs autoremove, never reboots and never
edits the bootloader: the package manager's own removal hooks update GRUB and
the initramfs. No log file is written.

Exit codes: `0` done or nothing to remove, `1` the removal failed, `2` not Linux,
an unsupported distribution, the package tool missing or the running kernel
unknown, `3` bad usage or a real run without `--yes`.

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
```

It changes nothing, and warnings do not change the exit code — a missing
default route is something to read, not a gate. `--probe` is off by
default so a container with no uplink does not hang the report. Use
`hardening_audit.sh --only network` when you want findings.

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
./sysctl_defaults.sh --check                       # exit 1 unless live and persisted match
./sysctl_defaults.sh --check --only inotify || echo drift
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

The report always exits `0`, so it cannot gate anything. `--check` can: it is
read-only, needs no root, honours `--only`, and gives each managed key one word,
the first that applies:

| Word | Meaning |
| --- | --- |
| `SKIP` | The live value is unreadable. Never a pass or a failure. |
| `DRIFT` | The live value is not the desired one. |
| `UNPERSISTED` | Live is right, but `99-ops-toolbox.conf` does not set the key and no other `sysctl.d` file or `/etc/sysctl.conf` sets it to the wanted value, so the next reboot returns it to the default (a `sysctl -w` by hand). A value another file persists counts as `OK`. |
| `STALE` | The drop-in sets a different value than this script wants. |
| `SHADOWED` | A `*.conf` read after ours (a name that sorts later, such as `99-zz.conf`, or `/etc/sysctl.conf`) sets the key to something else; the file is named. |
| `OK` | Live, persisted (by the drop-in or another file) and effective all match. |

`UNPERSISTED` and `STALE` print `sudo ./sysctl_defaults.sh --apply` as the fix,
as text. A summary line counts each word. `--check` exits `1` on any `DRIFT`,
`UNPERSISTED`, `STALE` or `SHADOWED`, and `0` otherwise, including when every
key was unreadable (it says so). It is a separate mode: with `--apply`,
`--revert`, `--backup-file` or `--revert-from` it is exit `3`, and `--dry-run`
is accepted and ignored as for the report. Against the real `/etc/sysctl.d` it
also reads the other systemd-sysctl directories (`/run`, `/usr/local/lib`,
`/usr/lib`, `/lib`) and `/etc/sysctl.conf`, with systemd's precedence: the
first directory holding a file name wins, and a symlink to `/dev/null` masks
that name below it. Under a `SYSCTL_D` override it reads only that directory,
so the tests stay hermetic, unless `SYSCTL_EXTRA_DIRS` (colon-separated, highest
precedence first) names more. Use it from cron or a CI image
build: `./sysctl_defaults.sh --check --only inotify || echo drift`.

## `swap_setup.sh`

Cloud droplets and fresh VMs often ship with no swap, and the first OOM kill
sends someone to a half-remembered `fallocate`, `mkswap`, `swapon` and fstab
recipe. `system_doctor.sh` says swap is missing and `sysctl_defaults.sh` tunes
`vm.swappiness`; this is the step between them.

```bash
./swap_setup.sh                                   # report only
./swap_setup.sh --create --dry-run                # every step, run nowhere
sudo ./swap_setup.sh --create --size 4G --yes     # /swapfile, enabled and in fstab
sudo ./swap_setup.sh --remove --yes
```

With no mode flag it is a read-only report: active swap, the swap lines in
fstab, `vm.swappiness`, total RAM and a suggested size (twice RAM up to 2G,
equal to RAM up to 8G, then 4G). No swap at all is reported, not failed.

| Option | Meaning |
| --- | --- |
| `--create` | `fallocate` (or `dd` where that fails), `chmod 600`, `mkswap`, `swapon`, then one fstab line |
| `--remove` | `swapoff`, drop the fstab line this script added, delete the file |
| `--size SIZE` | `128M` to `64G`, like `512M` or `4G` (default `2G`); `--create` only |
| `--path FILE` | Absolute swapfile path (default `/swapfile`); never `/`, `/proc`, `/sys` or `/dev`, and no whitespace, control characters or backslashes (exit 3), since the path is an fstab field |
| `--fstab FILE` | The fstab to read and edit (default `/etc/fstab`) |
| `--force` | `--create` even though swap is already active |
| `--dry-run` | Print every step; write nothing |
| `--yes`, `-y` | Required for `--create` or `--remove` to change anything |

`--create` refuses an existing file (it never reuses or overwrites one), a
machine that already has active swap unless `--force`, and a directory on
`tmpfs`, `ramfs`, NFS, CIFS or ZFS; on btrfs it points at
`btrfs filesystem mkswapfile`. It needs the size plus 10% free. The file is mode
`600` from the moment it exists, because swap holds memory pages, and if any step
before `swapon` fails the file it just created is removed. The fstab line is
`FILE none swap sw 0 0 # ops-toolbox swapfile`; it is written only when no line
already names the file, after a copy to `FSTAB.ops-toolbox.<timestamp>.bak`
(an existing backup is never overwritten), into a temporary file beside fstab
that is renamed over it, so a crash leaves the old fstab or the new one.

`--remove` accepts only a regular file that is active or in fstab, and removes
only the exact line `--create` wrote; a line somebody else wrote for the same
file is reported and left alone, with the file. It never enables swap on a device
or partition and never sets `vm.swappiness`.

Exit codes: `0` done or report printed, `1` a step failed or not enough space,
`2` not Linux, not root (preview with `--dry-run`), `mkswap`/`swapon` missing or
an unsupported filesystem, `3` bad usage or a change without `--yes`, `4`
nothing to do: the file exists, swap is already active, nothing to remove, or
the fstab line is not this script's.

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
```

`--fail-on expired` (the default) exits `1` only when a cert is already dead;
`--fail-on warn` also fails inside the window, so a cron job can page before
clients do. Missing `openssl` is exit `2`; `--help` and a missing `--file`
still work without it.

## `config_backup.sh`

A dated tar of selected paths so an upgrade or an edit has something to roll
back to. Default source is `/etc`. Home directories, databases and container
volumes stay out — those are backups with a different blast radius. This is a
copy, not a restore: it never writes back into the paths it archives.

```bash
./config_backup.sh --dry-run
./config_backup.sh --yes
./config_backup.sh --list
./config_backup.sh --diff                  # what changed under /etc since the newest archive
./config_backup.sh --yes --paths /etc/ssh,/etc/nginx --dest ~/ops-toolbox-backups --keep 5
./config_backup.sh --yes --prefix nginx-pre-upgrade
./config_backup.sh --yes --exclude-secrets --prefix shareable
./config_backup.sh --yes --paths /etc/nginx --exclude '*.key' --exclude 'etc/nginx/ssl'
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

`--exclude PATTERN` (repeatable) and `--exclude-secrets` leave members out, for
an archive you mean to attach to a ticket, hand to a colleague or keep on a
shared disk. Patterns are GNU tar exclusion globs matched against the member
name, which is relative to `/` because the script runs `tar -C /`:
`etc/ssl/private`, `etc/shadow*`, `*.key`. A `*` also matches `/`, and a
pattern can match from any `/` in the name, not only the start. Each pattern is
one `--exclude=` argument to tar, never a string handed to a shell. An empty
pattern, one with a newline and one with a leading `/` (it would silently match
nothing) are exit `3`. `--exclude-secrets` adds a fixed list:

| Pattern | Why |
| --- | --- |
| `etc/shadow*`, `etc/gshadow*` | password and group password hashes |
| `etc/security/opasswd` | previous password hashes |
| `etc/ssh/ssh_host_*_key` | SSH host private keys (the `.pub` files stay) |
| `etc/ssl/private` | TLS private keys |
| `etc/*-` | the distribution's `passwd-`, `shadow-`, `group-` backup copies |

It stays that short on purpose, so nobody believes it makes an archive safe to
publish: application secrets, `*.key` files elsewhere, `sudoers` and anything
under a name it does not list are still archived. Without it, a default run
still carries every secret in `/etc`. An excluded path is not a missing one, so
it never makes a `*.partial.tar.gz`, and an unreadable file that is excluded no
longer turns a non-root run into a partial one. If the patterns leave nothing
at all, the staged archive fails validation, nothing is published and the run
exits `1`. `--dry-run` prints each `would exclude:` line, and both flags are
refused with `--list` and `--diff`.

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

`--diff [FILE]` answers "what did I, a package or a configuration tool change
since the last backup?" It compares FILE, or the newest `PREFIX-*.tar.gz` in
`--dest`, with the live tree using GNU `tar --diff`, which extracts nothing, and
prints one line per finding:

```text
[info] comparing /root/ops-toolbox-backups/config-20261021-101500-AbC123.tar.gz with the live tree
  CHANGED /etc/ssh/sshd_config (Mod time differs, Size differs)
  GONE    /etc/foo.conf
  NEW     /etc/bar.conf
  SKIP    /etc/shadow (unreadable; rerun with sudo)
1 changed, 1 gone, 1 new, 1 skipped
[info] restore one file with: tar -xzf /root/ops-toolbox-backups/config-20261021-101500-AbC123.tar.gz -C / etc/ssh/sshd_config
```

`CHANGED` carries tar's reasons (size, contents, mode, owner, symlink target or
mtime), `GONE` is in the archive but not on disk, `NEW` is on disk under
`--paths` but not in the archive, and `SKIP` could not be read, or is a subtree
the new-file scan could not enter (so `NEW` may be incomplete). A `SKIP` makes
the run exit `1` and never counts as clean. A directory whose only change is its mtime is left out:
adding or deleting a file changes its parent's, which the `NEW` or `GONE` line
already says. `--paths` narrows the comparison (default `/etc`; `/` is refused),
and the newest archive is picked within `--prefix`, so an archive written under
another prefix needs `--prefix` too. The restore command is printed, never run,
which keeps this a copy and not a restore. `--diff` needs no `--yes`, never
creates `--dest`, staging, locks or logs, and refuses `--list`, `--yes` and
`--dry-run` alongside it (exit `3`). It exits `0` when nothing differs and `1`
when something does, or when a file could not be compared, so it also works as a
cron-able drift gate: `./config_backup.sh --diff || mail -s drift root`.

## `ssh_client_doctor.sh`

`hardening_audit.sh` grades **sshd**.
[`git/git_ssh_doctor.py`](../git/git_ssh_doctor.py) asks `ssh -G` why a git
remote will not accept a key. Neither looks at `~/.ssh` itself: a directory
that is group-readable, a private key at `644`, or an `IdentityFile` that
points at a path that does not exist. Those are the three reasons ssh refuses
a key with a message that names none of them.

```bash
./ssh_client_doctor.sh
./ssh_client_doctor.sh --quiet
./ssh_client_doctor.sh --fail-on warn
```

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

These remain findings rather than automatic fixes: a container or deliberately
permissive development host can validly differ from a server baseline.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success |
| `1` | One or more steps failed, or a graded report (`hardening_audit.sh`, `tls_expiry.sh`, `ssh_client_doctor.sh`) found something at or above `--fail-on`, or `config_backup.sh --diff` found a difference, or `sysctl_defaults.sh --check` found a key not in place, or `schedule_report.sh --strict` printed a warning |
| `2` | Preflight failed — unsupported distribution, not Linux, or no systemd user manager for the timer |
| `3` | Invalid usage, or an install or removal was requested without `--yes` |
| `4` | `install_aliases.sh --status` found the block missing or drifted, or `--uninstall` found no block to remove; `swap_setup.sh` had nothing to do |

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
`--coredump-dir`), that `kernel_cleanup.sh` never names the running or the
newest kernel across stubbed apt, dnf and pacman, that `swap_setup.sh` creates
and removes a swapfile against a fixture fstab with stubbed swap tools, that
`sysctl_defaults.sh` can apply
and revert against a fake procfs without touching `/etc`, that
`config_backup.sh` writes a tar of `--paths` into `--dest` and honours
`--keep`, that `ssh_client_doctor.sh` grades modes under `--ssh-dir`, and
that `tls_expiry.sh` treats a committed expired PEM as a failure when
`openssl` is present (and as exit `2` when it is not).

Discovery is by `find`, two levels deep, so `systemd/` is covered as well.
A container has no user manager, so the timer can only be exercised through
`--print-only` — which is precisely why that flag exists: on the images that
ship `systemd-analyze`, printing the units also verifies them.

Image tags are pinned. Arch is rolling and Fedora moves quickly; an unpinned
base would let an upstream change redden an unrelated pull request.
