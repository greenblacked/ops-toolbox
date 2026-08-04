# Linux Scripts

Bootstrap and maintenance for a Linux machine — the counterpart of
[`macos-initial-setup/`](../macos-initial-setup/), for servers and workstations
rather than a Mac.

**Targets:** Debian/Ubuntu (`apt`), Fedora/RHEL (`dnf`) and Arch (`pacman`).
Anything else exits `2` and says what it detected, the same way the macOS
scripts exit `2` off macOS.

| File | Purpose |
| --- | --- |
| [`install_devtools.sh`](install_devtools.sh) | Install Python, Go, Terraform, Helm and the DevOps CLIs |
| [`stay_fresh.sh`](stay_fresh.sh) | Recurring maintenance: upgrades, journal, caches, containers |
| [`hardening_audit.sh`](hardening_audit.sh) | Read-only security audit: sshd, accounts, network, file modes, updates |
| [`packages.sh`](packages.sh) | Capture and restore the explicitly-installed package set |
| [`bash_aliases.sh`](bash_aliases.sh) | Guarded aliases and helpers, sourced from `~/.bashrc` |
| [`tests/`](tests/) | Docker checks that **run** the scripts, across all three distros |

## Quick start

Everything that changes the machine previews first:

```bash
./stay_fresh.sh --dry-run
./install_devtools.sh --dry-run

./stay_fresh.sh --yes
./install_devtools.sh --yes --setup-shell
```

Capture what a machine has, commit it, rebuild elsewhere:

```bash
./packages.sh dump          # writes packages.<manager>.txt
./packages.sh diff          # what has drifted since
./packages.sh install --dry-run
./packages.sh install --yes
```

Aliases:

```bash
echo ". $PWD/bash_aliases.sh" >> ~/.bashrc
```

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
snap, then a report of whether a reboot is pending and how full `/` is.

Two things it deliberately does not do:

- **Volumes are never pruned.** `docker system prune -f` without `--volumes` is
  the whole point: this script must not be the reason a database disappears.
- **Held packages stay held.** `apt-get upgrade` respects holds where
  `dist-upgrade` would fight them.

A missing tool is a note, not a failure. `journalctl` is absent in a container
and `snap` on most servers; neither should turn a maintenance run red. A step
that runs and *fails* does count, and the script exits `1`.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success |
| `1` | One or more steps failed |
| `2` | Preflight failed — unsupported distribution |
| `3` | Invalid usage, or an install was requested without `--yes` |

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
requesting an install without `--yes` refuses, and that a missing optional tool
degrades to a warning instead of a failure.

Image tags are pinned. Arch is rolling and Fedora moves quickly; an unpinned
base would let an upstream change redden an unrelated pull request.
