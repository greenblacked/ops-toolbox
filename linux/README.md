# Linux Scripts

Bootstrap and maintenance for a Linux machine — the counterpart of
[`macos-initial-setup/`](../macos-initial-setup/), for servers and workstations
rather than a Mac.

**Targets:** Debian/Ubuntu (`apt`), Fedora/RHEL (`dnf`) and Arch (`pacman`).
Anything else exits `2` and says what it detected, the same way the macOS
scripts exit `2` off macOS.

## Contents

- [Quick start](#quick-start)
- [Lifecycle: when to run what](#lifecycle-when-to-run-what)
- [Kali VM bootstrap](#kali-vm-bootstrap)
- [Two decisions worth knowing](#two-decisions-worth-knowing)
- [Distro detection](#distro-detection)
- [What `stay_fresh.sh` does](#what-stay_freshsh-does)
- [The two read-only reports](#the-two-read-only-reports)
- [`system_doctor.sh`](#system_doctorsh)
- [`systemd/stay_fresh_timer.sh`](#systemdstay_fresh_timersh)
- [`install_aliases.sh`](#install_aliasessh)
- [`schedule_report.sh`](#schedule_reportsh)
- [`disk_cleanup.sh`](#disk_cleanupsh)
- [`net_doctor.sh`](#net_doctorsh)
- [`sysctl_defaults.sh`](#sysctl_defaultssh)
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
| [`disk_cleanup.sh`](disk_cleanup.sh) | Free space now: age-filtered temp, opt-in trash/journal/caches/coredumps; never volumes |
| [`system_doctor.sh`](system_doctor.sh) | Read-only health report: disk, memory, clock, reboot, services, firewall, containers, load, taint |
| [`net_doctor.sh`](net_doctor.sh) | Read-only network report: interfaces, default IPv4/IPv6 route, DNS, listening sockets |
| [`hardening_audit.sh`](hardening_audit.sh) | Read-only security audit: sshd, accounts, network, file modes, host keys, updates, kernel controls |
| [`ssh_client_doctor.sh`](ssh_client_doctor.sh) | Read-only `~/.ssh` modes and IdentityFile paths; not `ssh -G` |
| [`tls_expiry.sh`](tls_expiry.sh) | Read-only leaf certificate expiry for named PEMs and hostnames |
| [`sysctl_defaults.sh`](sysctl_defaults.sh) | Report/apply/revert a short sysctl list (inotify watches, swappiness) |
| [`packages.sh`](packages.sh) | Capture and restore the explicitly-installed package set |
| [`config_backup.sh`](config_backup.sh) | Dated tar of selected paths (default `/etc`); never a restore |
| [`schedule_report.sh`](schedule_report.sh) | Read-only inventory of systemd timers and cron jobs |
| [`cloud-init/kali-vm-init.yaml`](cloud-init/kali-vm-init.yaml) | First-boot configuration for a Kali red/blue lab VM; see the [runbook](cloud-init/README.md) |
| [`bash_aliases.sh`](bash_aliases.sh) | Guarded aliases and helpers, sourced from `~/.bashrc` |
| [`install_aliases.sh`](install_aliases.sh) | Install or remove the `bash_aliases.sh` source block in `~/.bashrc` |
| [`systemd/stay_fresh_timer.sh`](systemd/stay_fresh_timer.sh) | Install a user timer so `stay_fresh.sh` runs on a schedule |
| [`tests/`](tests/) | Docker checks that **run** the scripts, across all three distros |

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
./system_doctor.sh          # is this machine well?
./net_doctor.sh             # is this machine reachable?
./hardening_audit.sh        # is this machine safe?
./ssh_client_doctor.sh      # is ~/.ssh something ssh will actually use?
./tls_expiry.sh --file /etc/ssl/private/example.pem
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
| **Diagnose** | `system_doctor.sh` | After bootstrap, or when something feels wrong | nothing — it only reads |
| **Diagnose** | `net_doctor.sh` | When "the network is wrong" | nothing — it only reads |
| **Diagnose** | `schedule_report.sh` | When something ran at 3am | nothing — it only reads |
| **Diagnose** | `hardening_audit.sh` | Before trusting a machine with anything | nothing — it only reads |
| **Diagnose** | `ssh_client_doctor.sh` | When `Permission denied (publickey)` and the key is on disk | nothing — it only reads |
| **Diagnose** | `tls_expiry.sh` | Monthly, or from cron | nothing — it only reads |

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

Each script reads `/etc/os-release` and maps `ID`/`ID_LIKE` onto a package
manager. The lookup is duplicated in each script rather than shared, for the
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
(pip, npm, yarn, go, `~/.cache`), trash, `docker`/`podman` prune, flatpak and
snap, then a report of whether a reboot is pending, whether processes are
still running old libraries (`needs-restarting` / `needrestart`, when
installed), and how full `/` is.

Two things it deliberately does not do:

- **Volumes are never pruned.** `docker system prune -f` without `--volumes` is
  the whole point: this script must not be the reason a database disappears.
- **Held packages stay held.** `apt-get upgrade` respects holds where
  `dist-upgrade` would fight them.

A missing tool is a note, not a failure. `journalctl` is absent in a container
and `snap` on most servers; neither should turn a maintenance run red. A step
that runs and *fails* does count, and the script exits `1`.

## The two read-only reports

`system_doctor.sh` and `hardening_audit.sh` both change nothing and both look at
some of the same subsystems, so it is worth being clear about which one you
want:

| | `system_doctor.sh` | `hardening_audit.sh` |
| --- | --- | --- |
| Question | Is this machine **well**? | Is this machine **safe**? |
| Output | A narrative report | Graded findings, each with its fix |
| Firewall | Says which one is in charge | Grades "none" as a finding |
| sshd | Says whether it is installed and running | Grades `PermitRootLogin`, password auth, empty passwords |
| Exit code | Always `0`; findings are to be read | `1` at or above `--fail-on`, so it can gate a pipeline |

The counterpart on the other side of the repository is
[`macos-initial-setup/workstation_doctor.sh`](../macos-initial-setup/workstation_doctor.sh)
and [`macos-initial-setup/hardening_audit.sh`](../macos-initial-setup/hardening_audit.sh),
which split the same way.

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
./systemd/stay_fresh_timer.sh install --dry-run            # the timer previews only
./systemd/stay_fresh_timer.sh install --print-only         # show the units, write nothing
./systemd/stay_fresh_timer.sh status
./systemd/stay_fresh_timer.sh run-now
./systemd/stay_fresh_timer.sh logs --lines 200
./systemd/stay_fresh_timer.sh uninstall
```

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
`stay_fresh.sh` still writes its own log under `$TMPDIR`.

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
`system-doctor`, `disk-cleanup`, …) and a `toolbox-help` function that
lists only the ones that are actually executable, the same pattern as
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
./sysctl_defaults.sh --apply --dry-run
sudo ./sysctl_defaults.sh --apply
sudo ./sysctl_defaults.sh --revert
```

`SYSCTL_D` and `PROC_SYS` are honoured so the apply path is testable
without writing into `/etc`. `--apply` without root exits `2`; preview
with `--dry-run` instead.

## `tls_expiry.sh`

The Linux counterpart of
[`mikrotik/cert_expiry_watch.lua`](../mikrotik/cert_expiry_watch.lua).
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
./config_backup.sh --yes --paths /etc/ssh,/etc/nginx --dest ~/ops-toolbox-backups --keep 5
```

A real run requires `--yes`. `--list` shows the newest archive (or a named
file) and writes nothing. `--keep 0` disables rotation. Archives land in
`~/ops-toolbox-backups` unless `--dest` says otherwise. `--paths` must be
absolute; `/` is refused.

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
| `1` | One or more steps failed, or a graded report (`hardening_audit.sh`, `tls_expiry.sh`, `ssh_client_doctor.sh`) found something at or above `--fail-on` |
| `2` | Preflight failed — unsupported distribution, not Linux, or no systemd user manager for the timer |
| `3` | Invalid usage, or an install was requested without `--yes` |

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
`openssl` is present (and as exit `2` when it is not).

Discovery is by `find`, two levels deep, so `systemd/` is covered as well.
A container has no user manager, so the timer can only be exercised through
`--print-only` — which is precisely why that flag exists: on the images that
ship `systemd-analyze`, printing the units also verifies them.

Image tags are pinned. Arch is rolling and Fedora moves quickly; an unpinned
base would let an upstream change redden an unrelated pull request.
