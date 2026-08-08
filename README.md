# Ops Toolbox

[![CI](https://github.com/greenblacked/ops-toolbox/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/greenblacked/ops-toolbox/actions/workflows/ci.yml?query=branch%3Amaster)
[![RouterOS CHR](https://github.com/greenblacked/ops-toolbox/actions/workflows/chr.yml/badge.svg)](https://github.com/greenblacked/ops-toolbox/actions/workflows/chr.yml)
[![Licence: MIT](https://img.shields.io/badge/licence-MIT-blue.svg)](LICENSE)
[![ShellCheck](https://img.shields.io/badge/shellcheck-clean-brightgreen.svg)](CONTRIBUTING.md#bash-scripts)
[![PSScriptAnalyzer](https://img.shields.io/badge/PSScriptAnalyzer-clean-brightgreen.svg)](PSScriptAnalyzerSettings.psd1)
[![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Linux%20%7C%20Windows%20%7C%20RouterOS-lightgrey.svg)](#whats-here)
[![Test suites](https://img.shields.io/badge/test%20suites-7-blue.svg)](#testing)
[![Python](https://img.shields.io/badge/python-3.9-blue.svg)](https://github.com/greenblacked/ops-toolbox/blob/master/.github/workflows/ci.yml)
[![RouterOS](https://img.shields.io/badge/RouterOS-7.23.3-blue.svg)](mikrotik/README.md)

**CI** covers the git, macOS, Linux, Windows, Python and conventions suites on
every pull request, plus repo-wide ShellCheck, PSScriptAnalyzer, yamllint and
markdownlint. **RouterOS CHR** is separate because it boots a real router under
QEMU: it runs nightly rather than on the pull-request path, so a red badge
there does not necessarily mean a red pull request.

The two lint badges are static labels for the gates CI enforces, not live
results — the CI badge is the one that reflects the current state of `master`.

Helper scripts for setting up, maintaining, and working on the machines I touch
regularly — macOS workstations, Linux servers and workstations, a Windows dev
machine, and a MikroTik router, plus everyday Git helpers and a portable
Kubernetes toolbox. Each folder should be easy to inspect, safe to run more
than once, and focused on reducing repeat manual work.

Three rules hold everywhere, and the test suites enforce them:

- **`--help` works before anything else**, including on a machine the script
  refuses to run on. An unrecognised flag exits `3`.
- **A dry run writes nothing.** Anything that changes a machine supports
  `--dry-run` (or `-DryRun`), and anything destructive is behind an explicit
  opt-in flag.
- **Every script stands alone.** You can copy one file into `~/bin` — or paste
  one RouterOS script into a router — and it works, with no shared library to
  bring along. That is why some blocks are duplicated on purpose;
  [`CONTRIBUTING.md`](CONTRIBUTING.md) explains the trade-off.

**Targets:**

- Git repositories on macOS or Linux — scripts use `bash`; aliases use `zsh`.
- macOS 12+ (Apple Silicon and Intel) — scripts use `bash`, aliases use `zsh`.
- Windows 10/11 — Git Bash (MSYS2) dotfiles plus PowerShell 5+/7 scripts for
  WSL maintenance and disk cleanup.
- Linux servers and workstations — Debian/Ubuntu (`apt`), Fedora/RHEL (`dnf`)
  and Arch (`pacman`); scripts use `bash`.
- MikroTik RouterOS 7.23.3 — scripts are RouterOS scripting language (`.lua`
  extension is just for editor highlighting).

## Why this exists

Most personal script collections are read-only artefacts: you can look at one,
but running it on a machine you care about means reading it line by line first,
because nothing in it tells you what it is about to touch. This is the version
of that collection I was willing to hand to someone else. The three rules above
are the difference, and they are asserted by the test suites rather than
promised in prose — including a Linux suite that runs the scripts for real
inside pinned Debian, Fedora and Arch containers instead of only parsing them.
Because scripts are standalone, the useful unit is one file rather than the
whole repository: take `git_prune_gone.sh`, or one RouterOS script, and leave
the rest. It is aimed at people who look after a handful of machines by hand,
not at anyone shopping for a dotfiles framework to adopt.

## Contents

- [Why this exists](#why-this-exists)
- [What's here](#whats-here)
- [Quick start](#quick-start)
- [Script guidelines](#script-guidelines)
- [Git scripts at a glance](#git-scripts-at-a-glance)
- [macOS setup at a glance](#macos-setup-at-a-glance)
- [Windows at a glance](#windows-at-a-glance)
- [Linux at a glance](#linux-at-a-glance)
- [MikroTik scripts at a glance](#mikrotik-scripts-at-a-glance)
- [Testing](#testing)
- [Continuous integration](#continuous-integration)
- [Contributing](#contributing)

## What's here

| Folder | Purpose |
| --- | --- |
| [`git/`](git/) | Git helper scripts for author profiles, quick add/commit/push flows, status summaries, branch cleanup, and local Docker-based checks. |
| [`macos-initial-setup/`](macos-initial-setup/) | Bootstrap a fresh macOS workstation, install common apps and developer tools, keep Homebrew/toolchains fresh, and load useful zsh aliases. |
| [`windows/`](windows/) | Windows dev machine: Git Bash dotfiles (`git-bash/`), WSL maintenance — backups and VHDX shrinking (`wsl/`), and safe disk C: cleanup with dry-run (`cleanup/`). |
| [`linux/`](linux/) | Debian/Ubuntu, Fedora and Arch: install toolchains, keep a machine fresh, and capture/restore its package set. |
| [`mikrotik/`](mikrotik/) | RouterOS 7.x scripts for backups, WiFi password rotation, WAN-state monitoring, health checks, and Telegram notifications. |
| [`templates/`](templates/) | Starting points for a new Bash or PowerShell script. Working no-ops, checked by CI, so the conventions cannot drift away from them. |
| [`test-env/`](test-env/) | The suites that need no Docker: Python unit tests and the repo-wide convention checks. |

## Quick start

### macOS

For a new Mac, start with the macOS setup folder:

```bash
cd macos-initial-setup

./install_apps.sh     --dry-run --verbose
./install_devtools.sh --dry-run --verbose

./install_apps.sh
./install_devtools.sh --setup-shell
```

Use dry runs first when trying a script on a machine you care about. All
scripts in this repository are designed to be idempotent, but they still
install or clean real software when run without `--dry-run`.

### MikroTik

These are RouterOS scripts, not shell scripts — paste each file into the
*Source* field of a `/system script` entry on the router (Winbox / WebFig →
**System → Scripts → Add (+)**). Set up `tg_send` first with your Telegram
bot token, then schedule the rest via `/system scheduler`. The full runbook,
policy bits, and suggested cadence live in
[`mikrotik/README.md`](mikrotik/README.md).

### Windows

Git Bash dotfiles — drop into your home directory, then open a new window:

```bash
cp windows/git-bash/.bashrc windows/git-bash/.bash_profile windows/git-bash/.aliases "$HOME/"
```

If you already have either file, diff first and merge by hand — see
[`windows/git-bash/README.md`](windows/git-bash/README.md) for what changed
and why (mainly: one shared `ssh-agent` across windows instead of one leaked
per terminal).

Maintenance (PowerShell — both are read-only/dry-run in these forms):

```powershell
.\windows\cleanup\clean_disk_c.ps1 -DryRun   # what would cleanup free?
.\windows\wsl\wsl_manage.ps1 list            # WSL distros + real disk usage
```

### Git

Start with the Git helpers for day-to-day repository work:

```bash
cd git

./gacp.sh --dry-run -m "preview commit"
./git_status_summary.sh

./set_git_profile.sh --name "Sergey" --email "your@email.com"
```

Optional zsh alias:

```zsh
source "$PWD/git_aliases.zsh"
gacp "update scripts"
```

## Script guidelines

- Prefer `--dry-run` before changing the machine or repository when a script
  supports it.
- Read the README inside each folder before running scripts there.
- Keep scripts executable with `chmod +x path/to/script.sh` if your clone
  dropped the exec bits.
- Run scripts from their own folder unless that script documents otherwise.
- Expect macOS scripts to log details under `${TMPDIR:-/tmp}` when they
  perform non-trivial work.
- For MikroTik scripts, treat all changes through the router's own
  `/log print` and Telegram notifications — there is no host-side logfile.

Exit codes are consistent across the Bash and PowerShell scripts, so they can
be used from other automation: `0` success, `1` the work ran and some of it
failed, `2` wrong environment (not a git repo, not macOS), `3` invalid usage,
`4` nothing to do. Individual scripts may implement a subset and document it in
their own `--help`.

## Git scripts at a glance

The Git package is [`git/`](git/), tested in Docker against temporary local
repositories and local bare remotes:

- `gacp.sh` — stages all changes, commits with a required message, and pushes.
  Supports `--dry-run`, `--no-push`, and first-push options (`--remote`,
  `--branch`).
- `git_aliases.zsh` — defines `gacp` for zsh by pointing at `gacp.sh`.
- `set_git_profile.sh` — manages global `user.name` / `user.email`, plus
  named profiles stored under
  `${XDG_CONFIG_HOME:-$HOME/.config}/ops-toolbox/git-profiles.conf`.
- `git_whoami.sh` — shows the effective Git identity for the current directory
  and the global fallback when it differs.
- `git_status_summary.sh` — prints branch, upstream, ahead/behind, and
  changed/staged/unstaged/untracked counts.
- `git_sync_default.sh` — fetches and fast-forwards the default branch; refuses
  to run with a dirty working tree and supports `--dry-run`.
- `git_cleanup_merged.sh` — deletes local branches already merged into a base
  branch; protects common branch names unless `--force` is passed.
- `git_hooks_install.sh` — installs a pre-commit hook that refuses commits
  containing files over a size limit, leftover merge-conflict markers, or a
  private key. The hook body is embedded in the script rather than copied from
  a directory, so it keeps working after the script is gone. `status` reports
  whether it is installed and current; an existing unrelated hook is backed up
  rather than clobbered, and restored on `uninstall`.
- `git_prune_gone.sh` — deletes local branches whose upstream was deleted on
  the remote. This is the squash-merge case: a squash-merged branch leaves no
  merge commit, so `git_cleanup_merged.sh` never sees it, and on most projects
  that is most branches. Deletion is recoverable by design — every removal
  prints the commit it pointed at and the command to restore it.
- `git_size_report.sh` — read-only report of what is making the repository
  big, aggregated per path across all history rather than per object, since a
  sha alone tells you nothing about what to delete. `--fast` skips the history
  walk.
- `git_recent_branches.sh` — lists local branches by recent activity and can
  switch by list index.
- `git_repo_root.sh` — prints the repository root path for the current Git
  working tree.
- `git_diff_branch.sh` — shows the diff or diffstat for changes unique to the
  current branch since it diverged from `main` or `master`.
- `git_undo_last_commit.sh` — undoes the latest commit with `--soft` by
  default, with explicit options for `--mixed` and forced `--hard`.
- `git_amend_last.sh` — amends the previous commit with staged changes, or
  stages everything first with `--add-all`.
- `git_ssh_doctor.py` — explains `Permission denied (publickey)`. Takes the
  effective config from `ssh -G`, then reports what `ssh -G` cannot: `Include`
  globs that match only directories (which ssh skips without a word), keys with
  permissions ssh refuses, and an empty agent. `--test-auth` tries each
  discovered key against the host and prints the `Host` block that fixes it.
  Read-only — it never edits config or touches the agent.
- `git_signing_doctor.py` — explains `gpg failed to sign the data`, and the
  quieter failure where a commit signs fine but the forge still calls it
  Unverified. Covers all three backends (`openpgp`, `ssh`, `x509`) — it is not
  named for gpg because SSH signing is the one people are adopting, and nobody
  with `gpg.format=ssh` would run a script called gpg-something. Reports which
  config file each value came from, so a repo-local override beating your
  global one is visible. `--test-sign` attempts one real signature with
  pinentry disabled, so a passphrase-protected key fails instead of hanging.
  Read-only.

See [`git/README.md`](git/README.md) for command examples, exit-code
conventions, alias setup, and Docker test details.

## macOS setup at a glance

The macOS package is [`macos-initial-setup/`](macos-initial-setup/):

- `install_apps.sh` installs Homebrew if needed, then installs desktop apps,
  platform/DevOps CLI formulae, and Google Cloud SDK components.
- `install_devtools.sh` installs Python, Terraform, Go, Helm, and optional shell
  initialization using version managers.
- `stay_fresh.sh` handles recurring maintenance: caches, Homebrew upgrades,
  Docker/OrbStack cleanup, Xcode extras, Helm plugins, `gcloud`, and version
  reporting.
- `v1_stay_fresh.sh` is a legacy, flag-free minimal maintenance flow kept for
  reference; prefer `stay_fresh.sh` for new use.
- `brewfile.sh` captures the Homebrew state of a machine into a versioned
  `Brewfile` and restores it elsewhere — `dump`, `check`, `install`, and `diff`
  to see what `dump` would change before overwriting anything. The curated
  installers above are the intent; the Brewfile is the fact.
- `launchd/stay_fresh_agent.sh` installs a per-user LaunchAgent that runs
  `stay_fresh.sh` on a weekly or daily schedule. The agent has no terminal, so
  it cannot answer a sudo prompt and always runs `--no-sudo --yes`; the
  root-owned steps stay manual. `--print-only` shows the plist without
  installing it.
- `lib/workspace_scan.py` decides which VS Code / Cursor `workspaceStorage`
  entries belong to projects that are genuinely gone. Called by `stay_fresh.sh`
  via `/usr/bin/python3`; stdlib-only and unit-tested. It refuses to call an
  entry stale when its volume is not mounted, so an unplugged drive is never
  mistaken for a deleted project.
- `macos_defaults.sh` sets the system preferences worth changing on a new Mac
  (Finder, Dock, key repeat, screenshot location). **Read-only by default**:
  with no flags it prints current versus desired and writes nothing, `--apply`
  writes, and every apply captures the previous values so `--revert` can put
  them back. That default is deliberate — `defaults` keys are undocumented,
  move between releases, and a growing number are SIP/TCC-protected and
  silently do nothing while reporting success. Every row names the macOS
  version it was verified against.
- `zsh_aliases.zsh` provides guarded aliases and helper functions for daily
  shell work.

See [`macos-initial-setup/README.md`](macos-initial-setup/README.md) for the
full runbook and all options.

## Windows at a glance

The Windows package is [`windows/`](windows/):

- [`git-bash/`](windows/git-bash/) — `.bashrc` (persistent shared
  `ssh-agent` — one agent across every Git Bash window instead of one leaked
  per terminal — history, Git-aware prompt, PATH dedup), `.bash_profile`
  (sources `.bashrc`; Git Bash windows are login shells), and `.aliases`
  (~190 aliases/functions: Git, `glab` CLI when installed, Docker,
  Kubernetes, Terraform, WSL when installed, Windows-style commands, and
  `clear`/`cls`/`c` that also drop the scrollback).
- [`wsl/`](windows/wsl/) — `wsl_manage.ps1`: distro list with real VHDX
  disk usage, dated `.tar` backups, `compact`/`sparse` to reclaim the disk
  space WSL2 never returns on its own, shutdown.
- [`cleanup/`](windows/cleanup/) — `clean_disk_c.ps1`: frees C: space
  safely (aged temp files, WER, Delivery Optimization, thumbnails), with
  explicit opt-in flags for Recycle Bin, Windows Update cache, dev caches,
  and Docker. `-DryRun` reports sizes without deleting.
- [`setup/`](windows/setup/) — `winget_bootstrap.ps1`: the Windows
  counterpart of `brewfile.sh`, with the same `export`/`check`/`import`/`diff`
  verbs and the same exit codes. Captures the installed package list to a
  versioned JSON file so a machine can be rebuilt from it; `diff` shows what
  has drifted before you accept it, and `import -DryRun` lists what it would
  install.

See [`windows/README.md`](windows/README.md) and the per-folder READMEs for
install steps, the full alias breakdown, and PowerShell execution-policy
notes.

## Linux at a glance

The Linux package is [`linux/`](linux/), and it is the only one whose tests
**run** the scripts rather than only parsing them — the container is the target
OS, so behaviour is actually exercised across all three package managers:

- `install_devtools.sh` — Python, Go, Terraform, Helm and the DevOps CLIs.
  Defaults to `mise` rather than the distro, because the upstream instructions
  for these tools are `curl | bash` and this repository does not do that;
  `--manager distro` uses signed distribution packages instead and says plainly
  when a tool is not in the default repositories.
- `stay_fresh.sh` — upgrades honouring holds, journal vacuum, user caches,
  container prune (**never** volumes), flatpak/snap, and a reboot-pending
  report. A missing tool is a note; a step that runs and fails is an error.
- `hardening_audit.sh` — read-only security audit across sshd, accounts,
  listening sockets, file modes and update configuration. There is deliberately
  no `--apply`: every finding has a context where the insecure-looking answer is
  correct, so it prints the finding and the fixing command and leaves the
  decision to you. Reads the *effective* sshd config via `sshd -T` rather than
  grepping `sshd_config`, which gets the wrong answer when an `Include` overrides
  it.
- `packages.sh` — `dump`/`check`/`install`/`diff` over *explicitly installed*
  packages, the `brewfile.sh` counterpart. Only manual packages are recorded:
  capturing dependencies too produces a file that is huge, unstable across
  releases and useless for rebuilding.
- `bash_aliases.sh` — guarded aliases; every alias for a tool that may be
  absent is conditional, because an alias to a missing binary fails later, in
  the middle of something else.
- `systemd/stay_fresh_timer.sh` — installs a `systemd` **user** timer that runs
  `stay_fresh.sh` weekly or daily. It has no terminal, so it cannot answer a
  sudo prompt and always runs `--yes --no-sudo`; package upgrades and the
  journal vacuum stay manual. The units are checked with `systemd-analyze
  verify` before anything is written, and `--print-only` shows them without
  installing.

There is deliberately no `install_apps.sh`: Homebrew Cask has no Linux
equivalent worth mirroring. See [`linux/README.md`](linux/README.md).

## MikroTik scripts at a glance

The MikroTik package is [`mikrotik/`](mikrotik/), verified against
**RouterOS 7.23.3**:

- `tg_send.lua` — generic Telegram text helper used by every other script;
  reads `:global TG_BOT_TOKEN` / `TG_CHAT_ID` so secrets stay out of the
  script body, with retries and 4 KB truncation.
- `backup.lua` — daily binary + export backup; sends a Telegram confirmation
  with the resulting filename. Date-format-safe filenames.
- `change_WIFI_pw.lua` — rotates 2.4 GHz / 5 GHz WPA2 PSKs (legacy `wireless`
  or new `wifi`/WiFiWave2 stack) and posts the new credentials to Telegram.
- `health_check.lua` — CPU / RAM / disk / temperature watchdog; only alerts
  on threshold violations.
- `update_check.lua` — daily check against MikroTik's update server; pings
  Telegram once per new version.
- `wan_failover_notify.lua` — polls the built-in `detect-internet-state`
  property on the WAN interface and notifies only on transitions.
- `detect_internet.lua` — manual nudge that re-runs RouterOS WAN/LAN
  auto-detection (also enables it for `wan_failover_notify`).
- `reboot-and-flush.lua` — flushes DNS cache + connection tracking, then
  reboots. Pair with the README's optional `notify-boot` startup scheduler
  for a "back online" alert after each reboot.
- `dhcp_lease_watch.lua` — alerts on new MACs, duplicate hostnames, and
  lease churn; optionally tags new lease IPs into address-list
  `dhcp-watch-new`.
- `firewall_drift.lua` + `firewall_drift_baseline.lua` — snapshots
  `/ip firewall filter` and `nat` rule signatures and alerts on additions,
  removals, or critical-rule reordering; the helper script clears the
  baseline after intentional changes.
- `mac_allowlist_dhcp.lua` — flags (and optionally blocks via address-list
  plus filter rule) DHCP leases whose MAC is not on `:global MAC_ALLOWLIST`.
  Fail-safe: refuses to act when the allowlist is empty.
- `rogue_dns_check.lua` — verifies upstream DNS sanity and detects clients
  using non-approved DNS resolvers; tags offenders into
  `rogue-dns-clients`.
- `cert_expiry_watch.lua` — alerts when any non-disabled certificate is expired
  or expires within `WarnDays`. Schedule at most daily; the alert is not
  transition-gated, so a shorter interval repeats it.
- `wireguard_watch.lua` — alerts when the tunnel is down or a peer handshake
  goes stale, on the transition only, via `:global WGHEALTHLAST`.
- `wan_link_flap_notify.lua` — alerts on WAN link up/down at layer 1.
  Complements `wan_failover_notify.lua`, which watches
  `detect-internet-state`: a cable pulled out and an upstream outage are
  different events and this catches the first.
- `netwatch_notify.lua` — summarises `/tool netwatch` host status and alerts
  when the snapshot changes. First run records a baseline silently.
- `backup_file_cleanup.lua` — removes `backup-*` files older than
  `RetentionDays` from `/file`, so flash does not fill with stale
  `.backup`/`.rsc` pairs. Pair it with `backup.lua`, which creates them and
  prunes nothing.

Run from your machine rather than on the router:

- `pull_router_backups.sh` — copies `backup-*.backup` and `backup-*.rsc` off
  the router over SFTP/SCP into a local directory. Needs RouterOS 7+ SFTP and
  key-based SSH; `BatchMode=yes` means it fails rather than prompting.
- `export_config.py` — pulls `/export` over ssh and versions it in
  `config-history/`, so `firewall_drift.lua` has real history to diff against
  instead of a hand-maintained baseline. Strips the volatile export header
  (timestamp, serial, software id) so an unchanged router produces an identical
  file and only genuine changes appear as diffs. Needs no `routeros-api`, no
  pip, no venv. Refuses `--show-sensitive` together with `--commit`.

See [`mikrotik/README.md`](mikrotik/README.md) for installation, policy
flags, suggested scheduler entries, and RouterOS 7.23.3-specific gotchas
(TLS CAs, `:global` lifetime, `wifi` vs `wireless`, etc.).

## Testing

Run everything with one command:

```bash
./run-tests.sh            # git + macos + linux + python + static + windows  (the fast default)
./run-tests.sh all        # the above, plus the RouterOS CHR suite
./run-tests.sh macos      # a single suite
```

`run-tests.sh` delegates to the per-folder runners below rather than
reimplementing them, and prints a pass/fail/skip matrix. CI invokes this same
script, so a green run locally and a green run in CI mean the same thing.

Suites that need Docker say so in `./run-tests.sh --help`, and the Docker
preflight only runs when one of them is actually selected — so
`./run-tests.sh python static` works on a machine with no Docker at all.

| Package | What runs | How |
| --- | --- | --- |
| [`git/`](git/) | **Static + behavior** checks for Git helper scripts (syntax, ShellCheck, `--help`, profile state, `gacp`, status, cleanup, recent branches, and sync against local temporary repos/remotes). | [`git/README.md#tests`](git/README.md#tests) — `./git/tests/run.sh` |
| [`macos-initial-setup/`](macos-initial-setup/) | **Static** checks on the bash scripts and `zsh_aliases.zsh` (syntax, ShellCheck, `--help`, Linux “macOS only” preflight, zsh can source aliases), plus the presence and output contract of `lib/workspace_scan.py`. Does **not** install apps or run Homebrew — the scripts are macOS-only. | [`macos-initial-setup/README.md#development--docker-checks`](macos-initial-setup/README.md#development--docker-checks) — `./macos-initial-setup/tests/run.sh` |
| [`test-env/python/`](test-env/python/) | **Unit** tests for the Python helpers: workspaceStorage classification, ssh-config `Include` resolution, RouterOS export normalisation. Stdlib `unittest` — **no Docker, no venv, no network**. | `./test-env/python/run.sh` |
| [`test-env/static/`](test-env/static/) | **Convention** checks across the whole repository: the `--help` and unknown-flag contracts, shebangs, file modes, `.gitattributes` coverage, Bash 3.2 constructs, and the deliberately-duplicated blocks. Discovers its own subjects, so a new script is covered by the commit that adds it. **bash + git only.** | `./test-env/static/run.sh` |
| [`linux/`](linux/) | **Behavioural** checks that run the scripts inside pinned Debian, Fedora and Arch containers: detection picks the right package manager, an unsupported distro exits 2, `--dry-run` leaves the package count identical, and `packages.sh` round-trips through a real package database. | [`linux/README.md`](linux/README.md) — `./linux/tests/run.sh` |
| [`windows/`](windows/) | **Contract** checks on the PowerShell scripts: they parse, comment-based help is complete, anything that changes a machine can be previewed first, and every flag the READMEs document actually exists. Needs `pwsh`; skips itself cleanly without it. **No Docker.** | [`windows/README.md`](windows/README.md) — `./windows/tests/run.sh` |
| [`mikrotik/`](mikrotik/) | **Integration** tests against a real **RouterOS 7.23.3 CHR** in QEMU, API-driven `pytest`. Slow (QEMU boot); excluded from the default selection. | [`mikrotik/tests/README.md`](mikrotik/tests/README.md) — `./mikrotik/tests/run.sh` |

The three Docker suites are self-contained: you need only Docker Engine and
Compose v2 on the host — no local Python, shellcheck, or RouterOS install. The
Python and static suites deliberately need none of that either: the Python
modules are invoked by `/usr/bin/python3` on a bare macOS machine, and the
static checks have to keep working on a host where Docker is unavailable.

### Continuous integration

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs every suite except
the RouterOS one — through `run-tests.sh`, so the aggregator is exercised too
rather than being a convenience nobody tests.

| Job | What it proves | Runs on |
| --- | --- | --- |
| `Detect changes` | Which languages and suites a change actually touches. Fails open — anything it is unsure about runs everything. | every event |
| `Lint` | ShellCheck, PSScriptAnalyzer, yamllint, markdownlint | every event |
| `Test / git` | Git helpers against throwaway repos and bare remotes (Docker) | `git/` changes |
| `Test / macos` | Static checks on the macOS scripts (Docker) | `macos-initial-setup/` changes |
| `Test / linux` | The Linux scripts **executed** in a pinned Debian container | `linux/` changes |
| `Test / windows` | PowerShell contract checks under `pwsh` | `windows/` changes |
| `Test / python helpers` | 101 unit tests + `ruff`, pinned to Python 3.9 | Python changes |
| `Test / conventions` | The repo-wide contracts, on every change | always |

Nothing is skipped at the *job* level, only inside a job, so every job still
reports success and no required check can leave a pull request unmergeable.

The lint job covers every tracked file of each kind:

- `bash -n` and ShellCheck (`--severity=error -x --shell=bash`) over every
  `*.sh` **and** the Git Bash dotfiles, which have no `.sh` extension and so
  went unchecked for a long time. `--shell=bash` is required for them: with no
  shebang ShellCheck cannot detect the dialect.
- PSScriptAnalyzer over every `*.ps1`, gated at Error **and** Warning severity.
  Mirroring `--severity=error` literally would find almost nothing, since
  nearly every PowerShell rule is Warning. The one excluded rule and the reason
  for it are in
  [`PSScriptAnalyzerSettings.psd1`](PSScriptAnalyzerSettings.psd1).
- `yamllint` and `markdownlint`.

The Python job is pinned to 3.9 — the version `/usr/bin/python3` provides on
macOS — so 3.10+ syntax cannot slip into a helper that has to run there, and it
installs a pinned `ruff`, without which `test-env/python/run.sh` reports the
lint as "skipped" and still exits 0.

Every job writes the `run-tests.sh` pass/fail/skip matrix into the run summary,
so a verdict is one click away rather than buried in a log.

#### When CI runs

Branches follow the typed-prefix convention — `feat/`, `ci/`, `chore/`,
`fix/` — and each event owns exactly one path, so a change is built once:

- **`pull_request`** — every pull request, targeting `master` or another typed
  branch (stacked PRs). This is the main gate; it tests the *merge result*,
  which a branch push cannot.
- **`push`** — `master` only, where there is no pull request to do it.
- **`workflow_dispatch`** — on demand.

The tradeoff, stated plainly: **a typed branch with no pull request open gets no
CI.** Open the PR as a draft, or run the workflow manually, if you want a
verdict before review. This is what removed the old double-run, where an open
PR built everything twice — once for `push`, once for `pull_request`.

#### What CI runs

A `changes` job diffs the pull request against its base and turns the result
into per-language and per-suite flags, so a README-only change no longer builds
and boots the Docker suites. Two rules keep that safe:

- It **fails open.** No usable base diff, or a change under `.github/`, to
  `run-tests.sh`, or to `test-env/lib/` means "everything changed". A bug in the
  filter can only make CI do more work, never less.
- Jobs are **never skipped at the job level**, only at the step level. A job
  skipped by GitHub reports `skipped` rather than `success`, and a required
  status check that never reports leaves a pull request unmergeable forever.
  Every job name therefore always reports green, at the cost of roughly twenty
  seconds of runner start-up for a job with nothing to do.

The conventions suite has no filter at all: its subjects are the whole
repository, and it costs seconds.

#### Pinning and caching

Every tool CI installs is pinned to an exact version in the `env:` block at the
top of the workflow — ShellCheck, yamllint, ruff and PSScriptAnalyzer — and each
install asserts the version it got. ShellCheck and ruff come from their upstream
release tarballs rather than `apt`/`pipx`, which is both pinnable and faster
than an `apt-get update` that costs twenty seconds before it downloads
anything. The runner image is pinned too (`ubuntu-24.04`, not `ubuntu-latest`).

Actions are pinned to commit SHAs with the tag in a trailing comment, because a
tag is mutable and a SHA is what actually runs.
[`.github/dependabot.yml`](.github/dependabot.yml) re-resolves them monthly in a
single grouped pull request, so the pins stay current instead of rotting.

PSScriptAnalyzer — by far the slowest install, and the only one that has to come
from PowerShell Gallery — is cached against its pinned version.

[`.github/workflows/chr.yml`](.github/workflows/chr.yml) runs the pinned RouterOS
integration suite nightly at 03:37 UTC and on demand. It is kept off the
pull-request path because CHR is an x86_64 image under QEMU and first boot takes
minutes. The Linux runner has `/dev/kvm`, which
[`mikrotik/tests/run.sh`](mikrotik/tests/run.sh) detects and enables by layering
`docker-compose.kvm.yml` on top — a separate file because compose fails hard on
a device that does not exist, which would break the suite for everyone on macOS.

[`routeros-version.yml`](.github/workflows/routeros-version.yml) checks
MikroTik's official stable release feed every Monday and Thursday at 04:19 UTC,
and also supports manual runs with an explicit version or check-only mode.
Long-term releases can be exercised manually in check-only mode, but cannot
replace the canonical stable compatibility pin merely because their version is
lower.
A newer CHR image must boot and pass the complete MikroTik suite before the
workflow updates the version and documentation on a `chore/routeros-VERSION`
branch and opens a pull request. It never commits directly to `master`; an
existing open bump pull request is reused rather than duplicated. Because bot
events do not recursively start workflows, the version workflow explicitly
dispatches the standard CI workflow for the bump branch before opening its PR.

## Contributing

[`CONTRIBUTING.md`](CONTRIBUTING.md) documents the conventions every script
here follows, with the file and line that establishes each one — the `set`
dialect to use per package, the `--help` and exit-code contracts, the two
dry-run output grammars, the logging helpers, and why some blocks are
duplicated rather than shared.

The fastest start is to copy a template, which is a working script rather than
a sketch:

```bash
cp templates/new_script.sh git/git_my_helper.sh
chmod +x git/git_my_helper.sh
./run-tests.sh static
```

The static suite discovers scripts by role, so a new one is checked from its
first commit without being added to any list.

If you are looking for somewhere to start,
[`docs/good-first-issues.md`](docs/good-first-issues.md) lists small tasks that
each name the file to change and how to check the result.

Licensed under the [MIT licence](LICENSE). Security reporting is covered in
[`SECURITY.md`](SECURITY.md), behaviour in
[`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md), and what changed when in
[`CHANGELOG.md`](CHANGELOG.md).
