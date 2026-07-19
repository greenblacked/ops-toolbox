# Pretty Useful Scripts

Helper scripts for setting up, maintaining, and working on the small set of
machines I touch regularly — currently macOS workstations and a MikroTik
router, plus everyday Git helpers. The repository is intentionally small:
each folder should be easy to inspect, safe to run more than once, and focused
on reducing repeat manual work.

**Targets:**

- Git repositories on macOS or Linux — scripts use `bash`; aliases use `zsh`.
- macOS 12+ (Apple Silicon and Intel) — scripts use `bash`, aliases use `zsh`.
- Windows 10/11 — Git Bash (MSYS2) dotfiles plus PowerShell 5+/7 scripts for
  WSL maintenance and disk cleanup.
- MikroTik RouterOS 7.22 — scripts are RouterOS scripting language (`.lua`
  extension is just for editor highlighting).

## Contents

- [What's here](#whats-here)
- [Quick start](#quick-start)
- [Script guidelines](#script-guidelines)
- [Git scripts at a glance](#git-scripts-at-a-glance)
- [macOS setup at a glance](#macos-setup-at-a-glance)
- [Windows at a glance](#windows-at-a-glance)
- [MikroTik scripts at a glance](#mikrotik-scripts-at-a-glance)
- [Testing (Docker)](#testing-docker)

## What's here

| Folder | Purpose |
| --- | --- |
| [`git/`](git/) | Git helper scripts for author profiles, quick add/commit/push flows, status summaries, branch cleanup, and local Docker-based checks. |
| [`macos-initial-setup/`](macos-initial-setup/) | Bootstrap a fresh macOS workstation, install common apps and developer tools, keep Homebrew/toolchains fresh, and load useful zsh aliases. |
| [`windows/`](windows/) | Windows dev machine: Git Bash dotfiles (`git-bash/`), WSL maintenance — backups and VHDX shrinking (`wsl/`), and safe disk C: cleanup with dry-run (`cleanup/`). |
| [`mikrotik/`](mikrotik/) | RouterOS 7.x scripts for backups, WiFi password rotation, WAN-state monitoring, health checks, and Telegram notifications. |

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

## Git scripts at a glance

The Git package is [`git/`](git/), tested in Docker against temporary local
repositories and local bare remotes:

- `gacp.sh` — stages all changes, commits with a required message, and pushes.
  Supports `--dry-run`, `--no-push`, and first-push options (`--remote`,
  `--branch`).
- `git_aliases.zsh` — defines `gacp` for zsh by pointing at `gacp.sh`.
- `set_git_profile.sh` — manages global `user.name` / `user.email`, plus
  named profiles stored under
  `${XDG_CONFIG_HOME:-$HOME/.config}/pretty-useful-scripts/git-profiles.conf`.
- `git_whoami.sh` — shows the effective Git identity for the current directory
  and the global fallback when it differs.
- `git_status_summary.sh` — prints branch, upstream, ahead/behind, and
  changed/staged/unstaged/untracked counts.
- `git_sync_default.sh` — fetches and fast-forwards the default branch; refuses
  to run with a dirty working tree and supports `--dry-run`.
- `git_cleanup_merged.sh` — deletes local branches already merged into a base
  branch; protects common branch names unless `--force` is passed.
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

See [`windows/README.md`](windows/README.md) and the per-folder READMEs for
install steps, the full alias breakdown, and PowerShell execution-policy
notes.

## MikroTik scripts at a glance

The MikroTik package is [`mikrotik/`](mikrotik/), verified against
**RouterOS 7.22**:

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

See [`mikrotik/README.md`](mikrotik/README.md) for installation, policy
flags, suggested scheduler entries, and RouterOS 7.22-specific gotchas
(TLS CAs, `:global` lifetime, `wifi` vs `wireless`, etc.).

## Testing (Docker)

Three folders ship **self-contained** Docker-based checks. You only need the
Docker Engine and Compose v2 on the host — no local Python, shellcheck, or
RouterOS install.

| Package | What runs | How |
| --- | --- | --- |
| [`git/`](git/) | **Static + behavior** checks for Git helper scripts (syntax, ShellCheck, `--help`, profile state, `gacp`, status, cleanup, recent branches, and sync against local temporary repos/remotes). | [`git/README.md#tests`](git/README.md#tests) — `./git/tests/run.sh` |
| [`macos-initial-setup/`](macos-initial-setup/) | **Static** checks on the bash scripts and `zsh_aliases.zsh` (syntax, ShellCheck, `--help`, Linux “macOS only” preflight, zsh can source aliases). Does **not** install apps or run Homebrew — the scripts are macOS-only. | [`macos-initial-setup/README.md#development--docker-checks`](macos-initial-setup/README.md#development--docker-checks) — `./macos-initial-setup/tests/run.sh` |
| [`mikrotik/`](mikrotik/) | **Integration** tests against a real **RouterOS 7.22 CHR** in QEMU, API-driven `pytest`. | [`mikrotik/tests/README.md`](mikrotik/tests/README.md) — `./mikrotik/tests/run.sh` |
