# Ops Toolbox

[![CI](https://github.com/greenblacked/ops-toolbox/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/greenblacked/ops-toolbox/actions/workflows/ci.yml?query=branch%3Amaster)
[![RouterOS CHR](https://github.com/greenblacked/ops-toolbox/actions/workflows/chr.yml/badge.svg)](https://github.com/greenblacked/ops-toolbox/actions/workflows/chr.yml)
[![Security](https://github.com/greenblacked/ops-toolbox/actions/workflows/security.yml/badge.svg?branch=master)](https://github.com/greenblacked/ops-toolbox/actions/workflows/security.yml?query=branch%3Amaster)
[![Licence: MIT](https://img.shields.io/badge/licence-MIT-blue.svg)](LICENSE)
[![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Linux%20%7C%20Windows%20%7C%20RouterOS%20%7C%20Kubernetes-lightgrey.svg)](#whats-here)

Ops Toolbox is a personal collection of scripts and configuration for people
maintaining a few workstations, servers, Git repositories, routers and
Kubernetes clusters. It covers macOS, Windows, Linux and MikroTik RouterOS.
Start with the report or preview for your task below, then use that collection's
guide before applying changes. Each command below runs from the repository root.

## Quick start

You need Git to clone the repository and Bash for this first Git report. The
report reads the effective Git identity in the cloned repository; it does not
set one. Run the other collections only on their relevant platform.

```bash
git clone https://github.com/greenblacked/ops-toolbox.git
cd ops-toolbox
./git/git_whoami.sh
```

If an identity is missing, this report prints `<not set>` and still exits
successfully. The clone and report do not install software or change global
Git settings.

## What's here

Choose a task below. **Read-only** commands inspect or print information;
**preview** commands show a particular tool's planned action without applying
it. Inspect the output and the linked guide before using an apply, install,
cleanup or router command. These commands have different prerequisites and
exit codes, described in their guides.

| Task and platform | First command from the repository root | Full guide |
| --- | --- | --- |
| Check Git identity on macOS or Linux (Bash and Git) | `./git/git_whoami.sh` — read-only report | [Git helpers](git/README.md) |
| Check a macOS 12+ workstation (Bash; Intel or Apple Silicon) | `./macos-initial-setup/status.sh` — read-only report | [macOS setup](macos-initial-setup/README.md) |
| Check a Windows 10/11 workstation (PowerShell 5.1 or 7) | `.\windows\setup\status.ps1` — read-only report in PowerShell | [Windows overview](windows/README.md) and [setup](windows/setup/README.md) |
| Check a Debian/Ubuntu, Fedora/RHEL or Arch machine (Bash) | `./linux/status.sh` — read-only report | [Linux scripts](linux/README.md) |
| Plan MikroTik RouterOS scheduler entries (Bash on your computer) | `./mikrotik/features/print_schedulers.sh` — prints commands; no router contact | [RouterOS runbook](mikrotik/README.md) |
| Preview a Kubernetes toolbox image build (Bash) | `./k8s-toolbox/build.sh --dry-run` — prints the Docker buildx command; no build | [Kubernetes toolbox](k8s-toolbox/README.md) |
| See dotfile sources and destinations (Bash on macOS or Linux) | `./dotfiles/install_dotfiles.sh --list` — read-only listing | [Dotfiles](dotfiles/README.md) |

The MikroTik output is text to review before pasting into a router. Some
scripts remain incompatible with RouterOS 7.24; check the current
[per-script compatibility table](mikrotik/README.md#scripts-overview) first.
Kubernetes
cluster diagnosis is a separate action: `k8s-toolbox/kubectl_pod_diag.sh`
queries the **current kube context**, so check that context before running it.
The image build preview works without Docker; actually building or running the
image needs Docker. Git, Python, PowerShell, Docker, router access and cluster
credentials are needed only for the tasks that use them. See the package guide
for its remaining prerequisites.

Other repository directories are [`templates/`](templates/) for Bash and
PowerShell starting points and [`test-env/`](test-env/) for test runners and
fixtures. The main collections are:

| Folder | Use it for |
| --- | --- |
| [`git/`](git/) | Identity and repository reports; commit, sync, branch cleanup and hook helpers. |
| [`macos-initial-setup/`](macos-initial-setup/) | App and tool setup, maintenance, workstation reports and preferences. |
| [`windows/`](windows/) | [Git Bash configuration](windows/git-bash/README.md), [WSL management](windows/wsl/README.md), [disk cleanup](windows/cleanup/README.md) and [workstation setup](windows/setup/README.md). |
| [`linux/`](linux/) | Workstation and server reports, package/tool setup, maintenance, backups and [cloud-init](linux/cloud-init/README.md). |
| [`mikrotik/`](mikrotik/) | RouterOS scripts for backups, connectivity, updates, health checks and notifications; current CHR integration pin: RouterOS 7.24.5. |
| [`k8s-toolbox/`](k8s-toolbox/) | A Debian-based, GKE-oriented CLI image, build/run helpers and cluster diagnostics. |
| [`dotfiles/`](dotfiles/) | Tool configuration and a per-file link/copy installer with drift reporting. |

## From report to change

A report such as `linux/status.sh` reads local state. A preview such as
`k8s-toolbox/build.sh --dry-run` prints what **that command** would do; it
does not exercise the real build. An apply or install action changes the
machine, repository, router or cluster according to its own options. A
schedule runs a script at configured times; it does not by itself enforce a
network policy. For example, RouterOS `security_check.lua` only reports,
while other scripts can populate address-lists. Blocking or redirecting
matching traffic additionally requires an enabled firewall rule: see the
[security action surface](mikrotik/README.md#security-action-surface).
Each script's `--dry-run` has its own scope. Check its guide before moving
from a report or preview to a change.

For example, [macOS setup](macos-initial-setup/README.md) covers app and
developer tool installation, [Windows setup](windows/setup/README.md) covers
winget and Chocolatey, and the [MikroTik runbook](mikrotik/README.md) covers
router script installation, policies and scheduling. The
[MikroTik security reporting guide](mikrotik/SECURITY_REPORTING.md) explains
its security report. There is no single apply command for the whole toolbox.

The macOS `stay_fresh.sh` maintenance script needs its adjacent `lib/`
directory when copying it. It invokes companion programs including
`workspace_scan.py`, `npx_cache.py` and `large_storage.py`; it also calls other
helpers for selected steps. The [macOS guide](macos-initial-setup/README.md)
documents its steps and options.

### Execution policy note

On Windows, PowerShell may refuse to start a script under the current
execution policy. Check `Get-ExecutionPolicy -List` in PowerShell and follow
your organization's policy; the [Windows guide](windows/README.md) gives the
package commands. Changing execution policy is a separate system decision.

## Testing

From the repository root, `./run-tests.sh --help` shows the suites and their
requirements; `./run-tests.sh --list` prints the current suite inventory.
`./run-tests.sh` runs the default selection, and `./run-tests.sh all` also
includes the MikroTik CHR integration suite. Docker is required by the suites
that run containers, while static checks and some package checks run without
it. A local pass reflects the tools and platforms present on that machine:
read the result matrix for skips. See [test environments](test-env/README.md)
for suite setup and coverage.

The repository's [CI workflow](.github/workflows/ci.yml) runs checks on pull
requests and `master`; the separate [CHR workflow](.github/workflows/chr.yml)
exercises RouterOS integration. The [security workflow](.github/workflows/security.yml)
reports repository and workflow findings. These workflows have different
triggers and gates; their current definitions are the source of truth.

CI uses a `macos-15` runner for native macOS checks and a `windows-2025`
runner with `pwsh` for Windows contracts; Linux package tests run in Debian,
Fedora and Arch containers. The
[macOS test guide](macos-initial-setup/README.md#development-docker-checks)
also describes Linux container checks that do not run Homebrew on macOS.
These checks do not exercise every advertised OS release or Windows
PowerShell 5.1. The [RouterOS CHR guide](mikrotik/tests/README.md) describes
QEMU integration against the pinned image; it does not establish
compatibility with a particular installed router or verify real Telegram
delivery and firewall enforcement. Check behavior on the target platform
before relying on it.

## Documentation site

A browsable version of these guides is published at
<https://ops.szolotov.com>. It is built with MkDocs from the `docs/` folder
and `mkdocs.yml`, and served by a Cloudflare Worker (`worker/`). To preview it
locally:

```bash
python3 -m venv .venv
.venv/bin/pip install --require-hashes -r docs/requirements.txt
.venv/bin/mkdocs serve
```

How it is deployed is in
[docs/contributing/deployment.md](docs/contributing/deployment.md).

## Contributing

[Contributing](CONTRIBUTING.md) gives script conventions and the checklist for
new work. [Templates](templates/README.md) and the [roadmap](ROADMAP.md) help
scope changes. See the [code of conduct](CODE_OF_CONDUCT.md),
[security policy](SECURITY.md), [MIT licence](LICENSE) and
[changelog](CHANGELOG.md). Add changelog entries through
[changelog fragments](changelog.d/README.md).
