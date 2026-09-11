# macOS initial setup

[Ops Toolbox](../README.md) / **macOS initial setup**

> Opinionated, idempotent shell scripts for provisioning and maintaining
> a macOS workstation.

This folder is the macOS setup package inside the broader helper-scripts
repository. It turns the normal "fresh Mac checklist" — install apps, wire
up language toolchains, keep caches and Homebrew under control — into a set
of small, composable scripts that are safe to run today, next month, and on
the next machine. Every change is previewable with `--dry-run`, logged to
`$TMPDIR`, and opt-out at a per-feature level.

The conventions these scripts follow — the `set -u` / `set -o pipefail`
dialect, Bash 3.2 only, the indented `(dry-run)` output grammar, and the
rule that a preview does not even create its own log file — are collected in
[`CONTRIBUTING.md`](../CONTRIBUTING.md).

**Platform:** macOS 12+ (Monterey through the current release) on Apple
Silicon and Intel. **Shell:** `bash` for scripts (`#!/usr/bin/env bash`),
`zsh` for the aliases file.

## Contents

- [TL;DR](#tldr)
- [Folder map](#folder-map)
- [Lifecycle: when to run what](#lifecycle-when-to-run-what)
- [Design principles](#design-principles)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [`install_apps.sh`](#install_appssh)
- [`install_devtools.sh`](#install_devtoolssh)
- [`stay_fresh.sh`](#stay_freshsh)
- [`v1_stay_fresh.sh`](#v1_stay_freshsh)
- [`brewfile.sh`](#brewfilesh)
- [`macos_defaults.sh`](#macos_defaultssh)
- [`workstation_doctor.sh`](#workstation_doctorsh)
- [`hardening_audit.sh`](#hardening_auditsh)
- [`launchd/stay_fresh_agent.sh`](#launchdstay_fresh_agentsh)
- [`zsh_aliases.zsh`](#zsh_aliaseszsh)
- [What this changes on your machine](#what-this-changes-on-your-machine)
- [Development: Docker checks](#development-docker-checks)

## TL;DR

For returning users. Every command is idempotent.

```bash
# First run on a new machine
./install_apps.sh                        # cask apps + DevOps CLIs + Google Cloud SDK
./install_devtools.sh --setup-shell      # Python, Terraform, Go, Helm

# Regular maintenance (weekly is a good cadence)
./stay_fresh.sh                          # purge, cleanup, upgrade, report
./stay_fresh.sh --dry-run                # preview without changes

# One-off previews
./install_apps.sh     --dry-run --verbose
./install_devtools.sh --dry-run --verbose
./install_apps.sh     --dry-run --only brave-browser --only-formulae jq,yq
./install_devtools.sh --dry-run --only terraform,helm

# Read the machine, change nothing
./workstation_doctor.sh                  # is this Mac well?
./hardening_audit.sh                     # is this Mac safe?
```

After linking `zsh_aliases.zsh`, the same three are available as
`install-apps`, `install-devtools`, and `stay-fresh`.

## Folder map

| File | Use it for |
| --- | --- |
| `install_apps.sh` | Day-one workstation apps, Homebrew casks/formulae, platform CLIs, and Google Cloud SDK. |
| `install_devtools.sh` | Language and infrastructure toolchains: Python, Terraform, Go, Helm, and version managers. |
| `stay_fresh.sh` | Recurring maintenance: cleanup, updates, cache pruning, and version reporting. |
| `v1_stay_fresh.sh` | Legacy minimal maintenance flow kept for reference and simple one-off runs. |
| `brewfile.sh` | Capture this machine's Homebrew state into a versioned `Brewfile`, and restore it on another machine. |
| `macos_defaults.sh` | Read-only preference drift report by default; explicitly apply selected settings or revert a validated backup. |
| `workstation_doctor.sh` | Read-only health report: is this Mac **well**? Security posture, disk, CLT, Homebrew, SSH, Time Machine, LaunchAgents. |
| `hardening_audit.sh` | Read-only security audit: is this Mac **safe**? Sharing, firewall, updates, FileVault, SIP, Gatekeeper — each finding with its fix. |
| `launchd/stay_fresh_agent.sh` | Install a LaunchAgent so `stay_fresh.sh` runs on a schedule instead of when you remember. |
| `lib/workspace_scan.py` | Classifier used by `stay_fresh.sh` to decide which editor `workspaceStorage` entries are dead. Not run directly. |
| `zsh_aliases.zsh` | Optional interactive-shell aliases and helper functions: git, docker, kubernetes (with server-side dry-run and completion for `k`), terraform, helm, aws profile switching, ansible, and a `retry` helper with exponential backoff. `find` and `grep` are deliberately never shadowed by `fd`/`rg` - the flags differ, and a command copied from a runbook has to work as written. |
| `tests/` | Docker-based **static** checks (ShellCheck, `bash -n`, CLI smoke tests). See [Development: Docker checks](#development-docker-checks). |

## Lifecycle: when to run what

The repository is organized around the life of a workstation. Each
script fills a distinct slot — understanding which slot matters more
than memorizing flags.

| Phase | Script | Typical cadence | What it touches |
| --- | --- | --- | --- |
| **Bootstrap** | `install_apps.sh` | Once per machine | `/Applications`, Homebrew Cask + formulae (e.g. `k9s`, `awscli`), Google Cloud SDK |
| **Bootstrap** | `install_devtools.sh` | Once per machine (+ version bumps) | `~/.pyenv`, `~/.goenv`, `$(brew --prefix)/bin`, optionally `~/.zshrc` |
| **Ambient** | `zsh_aliases.zsh` | Sourced on every interactive shell (after wiring into `~/.zshrc`) | Your shell only — no disk writes |
| **Recurring** | `stay_fresh.sh` | Weekly / on demand | Caches, Homebrew, Docker, Xcode, toolchains |
| **Configure** | `macos_defaults.sh` | Once, then after major macOS upgrades | Finder, Dock, keyboard and screenshot preferences; read-only unless `--apply`/`--revert` |
| **Diagnose** | `workstation_doctor.sh` | After bootstrap, or when something feels wrong | Nothing — it only reads |
| **Diagnose** | `hardening_audit.sh` | Before trusting a machine with anything | Nothing — it only reads |
| **Legacy** | `v1_stay_fresh.sh` | On demand | Minimal subset of the above; no flags |

The two bootstrap scripts are independent — you can run either one
first. `stay_fresh.sh` assumes Homebrew is installed but degrades
gracefully if optional tools (Docker, `mise`, `gcloud`, etc.) are
missing.

## Design principles

These are the invariants every script upholds. They explain why the
code looks the way it does.

| Principle | What it means in practice |
| --- | --- |
| **Idempotent** | Re-running a script upgrades in place. No duplicate installs, no appended shell-rc blocks, no runaway cache. |
| **Fail-soft** | One failing step never aborts the rest of the run. Missing tools are skipped with a note, not treated as errors. |
| **Dry-run first** | `--dry-run` is supported on every script that mutates state (except the explicitly minimal `v1_stay_fresh.sh`). No `sudo` prompt is triggered in dry-run. |
| **Logged** | The four long-running scripts — `install_apps.sh`, `install_devtools.sh`, `stay_fresh.sh`, `workstation_doctor.sh` — write a timestamped log to `$TMPDIR`. `--verbose` also streams to the terminal. `brewfile.sh`, `hardening_audit.sh`, `macos_defaults.sh` and `v1_stay_fresh.sh` write none. |
| **No hidden writes** | Shell rc files are modified only when you pass `--setup-shell`. Every such block is bracketed by markers so it can be found and removed. |
| **Opt-out, not opt-in** | `stay_fresh.sh` has a skip flag for every step. `install_apps.sh` honors `--only`/`--skip` for casks, `--skip-cli-ops` / `--skip-formulae` for CLI brew packages, and gcloud component flags. |
| **Sudo only when needed** | Scripts request `sudo` once at startup, keep it warm for the run, and release it on exit. Running as `root` is refused. |

## Requirements

- macOS 12 (Monterey) or newer, on Apple Silicon or Intel.
- Administrator password for a single interactive `sudo` prompt (used
  by `purge` and by Homebrew installs where applicable).
- Xcode Command Line Tools (`xcode-select --install`).
- At least 5 GB of free disk space on `/`.
- An active internet connection to `formulae.brew.sh` and GitHub.

`install_apps.sh` installs Homebrew automatically if it is missing.
The other scripts assume Homebrew is already on `PATH` — run
`install_apps.sh` first on a fresh machine, or install Homebrew
manually from <https://brew.sh>.

## Quick start

On a fresh machine:

```bash
git clone https://github.com/greenblacked/ops-toolbox.git
cd ops-toolbox/macos-initial-setup

./install_apps.sh     --dry-run --verbose
./install_devtools.sh --dry-run --verbose

./install_apps.sh                        # 1. cask apps + DevOps CLIs + Google Cloud SDK
./install_devtools.sh --setup-shell      # 2. language toolchains

ln -sfn "$PWD/zsh_aliases.zsh" "$HOME/.zsh_aliases.zsh"
grep -qsF '.zsh_aliases.zsh' ~/.zshrc \
  || echo '[[ -f "$HOME/.zsh_aliases.zsh" ]] && source "$HOME/.zsh_aliases.zsh"' \
       >> ~/.zshrc
exec zsh                                 # 3. reload shell with aliases + shims
```

The preflight output of `install_apps.sh` looks like this on a healthy
machine:

```text
=== install_apps: preflight checks ===
[info] log file: /tmp/install_apps-20260421-093014.log
[ok  ] macOS 14.5 (23F79) on arm64
[ok  ] bash 3.2.57(1)-release
[ok  ] running as user: szolotov
[ok  ] internet reachable (formulae.brew.sh)
[ok  ] Xcode Command Line Tools: /Library/Developer/CommandLineTools
[ok  ] free disk space: 184G on /
[ok  ] Homebrew 4.3.8 (prefix: /opt/homebrew)
```

If any preflight check fails, the script exits with code `2` and
prints a pointed message explaining what to fix.

---

## `install_apps.sh`

Installs desktop applications via Homebrew **Cask**, a batch of **CLI
formulae** for Kubernetes and platform work (including **`k9s`**), then
the Google Cloud SDK (`gcloud-cli`) with common components. Cask apps
already present in `/Applications` but not managed by Homebrew are
**adopted** (`brew install --cask --force`) so that future upgrades flow
through `brew` instead of each vendor's auto-updater.

### Usage

```bash
./install_apps.sh                        # full install (interactive)
./install_apps.sh --dry-run --verbose    # preview and stream details
./install_apps.sh --yes                  # non-interactive
```

### Options

| Flag | Purpose |
| --- | --- |
| `--dry-run` | Show the plan; change nothing. |
| `-y`, `--yes` | Skip confirmation prompts. |
| `-v`, `--verbose` | Stream `brew` output live (also runs `brew doctor` into the log). |
| `--only a,b,c` | Install only the listed casks. |
| `--skip a,b,c` | Install everything except the listed casks. |
| `--skip-upgrade` | Do not upgrade already-installed casks or formulae. |
| `--no-cleanup` | Skip `brew cleanup` at the end of the run. |
| `--skip-gcloud` | Omit the Google Cloud SDK entirely. |
| `--skip-cli-ops` | Skip the entire Homebrew **formula** batch (see below). |
| `--only-formulae a,b,c` | Operate on only the named formulae; unknown names fail before preflight. |
| `--skip-formulae a,b,c` | Skip individual formula names (comma-separated). |
| `--gcloud-components a,b,c` | Override the default component set. |
| `--no-gcloud-components` | Install `gcloud` core only (no components). |
| `-h`, `--help` | Show the built-in help (lists every cask and formula). |

### Bundled cask applications

**General use:** `brave-browser`, `visual-studio-code`, `orbstack`,
`slack`, `zoom`, `telegram`, `spotify`.

**DevOps and platform engineering (GUI):** `iterm2`, `raycast`, `github`,
`lens`, `postman`, `drawio`, `wireshark-app`, `dbeaver-community`,
`google-chrome`, `1password`, `microsoft-teams`, `notion`, `tailscale-app`,
`cloudflare-warp`, `ngrok`, `rectangle`, `alt-tab`, `maccy`, `zed`,
`sublime-text`, `jetbrains-toolbox`, `fork`, `gitkraken`,
`azure-data-studio`, `postico`, `redisinsight`, `cyberduck`, `proxyman`,
`linear-linear`, `discord`.

Pass `--skip a,b,c` to omit casks your organization provisions elsewhere.
The `ngrok` cask installs a **binary only** (no `.app`).

The cask and formula selectors are independent, so a small bootstrap can be
reviewed precisely before it runs:

```bash
./install_apps.sh --dry-run \
  --only brave-browser,visual-studio-code \
  --only-formulae jq,yq,k9s \
  --skip-gcloud
```

### Bundled CLI formulae (`brew install`)

Installed after the cask loop unless you pass `--skip-cli-ops`. Includes
**`k9s`**, **`stern`**, **`kubectx`**, **`kind`**, **`minikube`**, **`skaffold`**,
**`kustomize`**, **`helm`**, **`helmfile`**, **`krew`**, **`eksctl`**, **`argocd`**,
**`velero`**, **`cilium-cli`**, **`awscli`**, **`azure-cli`**, **`grpcurl`**,
**`terraform-docs`**, **`tflint`**, **`terragrunt`**, **`infracost`**, **`conftest`**,
**`opa`**, **`cosign`**, **`crane`**, **`dive`**, **`lazydocker`**, **`popeye`**,
**`kubescape`**, **`grype`**, **`trivy`**, **`jq`**, **`yq`**, **`httpie`**, **`hey`**,
**`vegeta`**.

Homebrew's core formula named **`flux`** is the Influx query language, not
Flux CD; for the Flux CD CLI use `brew install fluxcd/tap/flux` separately if
you need it. **`helm`** is also installed by `install_devtools.sh` — running
both scripts is safe (idempotent).

### Google Cloud SDK components

By default the script installs `gke-gcloud-auth-plugin` and `kubectl`.
It prefers `brew install <component>` and falls back to
`gcloud components install <component>` when the component is not
packaged as a Homebrew formula.

```bash
./install_apps.sh --gcloud-components gke-gcloud-auth-plugin,kubectl,beta
./install_apps.sh --no-gcloud-components
```

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Completed successfully. |
| `1` | One or more installs failed. |
| `2` | Preflight checks failed. |
| `3` | Invalid arguments. |

---

## `install_devtools.sh`

Installs developer toolchains using version managers so that multiple
versions can coexist on the same machine. The script requires Homebrew —
run `install_apps.sh` first on a fresh machine, or install Homebrew
manually.

### Which manager should I pick?

| `--manager` | Best for | Installs |
| --- | --- | --- |
| `native` *(default)* | Maximum ecosystem fidelity — each tool uses its canonical version manager. | `pyenv` + `tfenv` + `goenv` + Homebrew `helm` |
| `tenv` | Teams that also need OpenTofu or Terragrunt alongside Terraform. | `pyenv` + `tenv` + `goenv` + Homebrew `helm` |
| `mise` | A single binary for all language runtimes; fastest switching. | `mise` (Python, Terraform, Go) + Homebrew `helm` |

If you are unsure, `native` is the safest choice: each tool behaves
exactly as its upstream documentation expects.

### Usage

```bash
./install_devtools.sh                      # native managers, latest versions (interactive)
./install_devtools.sh --dry-run            # preview changes
./install_devtools.sh --yes --setup-shell  # non-interactive; wire ~/.zshrc
```

### Options

| Flag | Purpose |
| --- | --- |
| `--dry-run` | Show the plan; change nothing. |
| `-y`, `--yes` | Skip confirmation prompts. |
| `-v`, `--verbose` | Stream `brew`, `pyenv`, and builder output live. |
| `--setup-shell` | Append initialization lines to `~/.zshrc` or `~/.bashrc`. |
| `--only python,terraform,go,helm` | Install only the named tool groups. Cannot be mixed with individual `--skip-*` tool flags. |
| `--list-tools` | Print stable tool ids and exit without macOS preflight. |
| `--manager native\|tenv\|mise` | Select a manager stack (default: `native`). |
| `--python-version V` | Pin Python (default: latest stable 3.x). |
| `--terraform-version V` | Pin Terraform (default: latest). |
| `--go-version V` | Pin Go (default: latest). |
| `--helm-version V` | Pin Helm (default: latest from Homebrew). |
| `--skip-python` | Do not install Python. |
| `--skip-terraform` | Do not install Terraform. |
| `--skip-go` | Do not install Go. |
| `--skip-helm` | Do not install Helm. |
| `--helm-plugins a,b,c` | Override the plugin set (default: `helm-diff`). |
| `--no-helm-plugins` | Do not install any Helm plugins. |
| `-h`, `--help` | Show the built-in help. |

Known Helm plugin shorthands (`helm-diff`, `helm-secrets`, `helm-git`)
resolve to their canonical Git URLs; full `https://…` URLs are also
accepted.

`--only` scopes the existing workflow; it does not introduce a separate
installer path. For example, `--only terraform,helm` skips Python and Go in
the plan and in optional shell configuration while retaining all existing
version/manager flags for the selected tools.

When `--setup-shell` is omitted, the copyable shell guidance is scoped to the
selected tools as well. A Helm-only or native `tfenv` run reports that no shell
setup is required; `mise` activation is shown only when a selected language or
Terraform tool is actually managed by `mise`.

### Shell configuration

With `--setup-shell`, the script appends the required initialization
lines to `~/.zshrc` (or `~/.bashrc`). Each block is bracketed by a
marker comment so re-running is idempotent and the block can be located
and removed by hand:

- `pyenv init` + `pyenv virtualenv-init`
- `goenv init`
- `tenv` PATH shims (not needed for `tfenv`, which lives under
  `$(brew --prefix)/bin`)
- `eval "$(mise activate <shell>)"` when `--manager mise` is used

Without `--setup-shell`, the script prints the exact block to copy into
your shell configuration yourself.

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Completed successfully. |
| `1` | One or more installs failed. |
| `2` | Preflight checks failed. |
| `3` | Invalid arguments. |

---

## `stay_fresh.sh`

End-to-end macOS housekeeping. Each step is independent, measures the
disk space freed, and degrades gracefully when a tool is missing or a
path is protected by System Integrity Protection.

### Steps

In the order they run:

1. Optionally purge disk caches (`sudo purge`) for cold-cache troubleshooting;
   disabled unless `--purge-memory` is passed.
2. Flush the DNS cache (`dscacheutil`, `mDNSResponder`).
3. Clear system caches (`/Library/Caches`). `/System/Library/Caches` is left
   alone unless `csrutil` reports System Integrity Protection *positively*
   disabled **and** `--force-system-caches` is passed. With SIP on every entry
   there answers "Operation not permitted" even to root; when `csrutil` is
   missing, fails, or answers in a language the parse does not know, the
   status is *unknown*, which is not the same as off. Even with both
   conditions met the boot caches (`com.apple.dyld`,
   `com.apple.kernelcaches`, `com.apple.bootstamps`) are excluded: removing
   them buys a few megabytes and costs a long, alarming first boot while the
   kernel and dyld caches are rebuilt.
4. Clear user caches (`~/Library/Caches`, Saved State, Xcode
   DerivedData, and related paths). What macOS refuses is sorted before it
   is reported: entries the privacy controls or SIP protect (HomeKit,
   CloudKit, Safari, a dozen Apple services) are counted and kept without a
   warning, since no run can change that; an entry owned by another user,
   such as the root-owned directory Slack's updater leaves behind, is
   retried with sudo when a credential is already in hand and warned about
   otherwise, since that one a person can fix. The retry names exactly the
   entries `rm` refused; it never sweeps the whole directory as root, so the
   protected entries stay protected.
5. Clear **per-app caches** — the disposable data that lives outside
   `~/Library/Caches` and is therefore invisible to step 4: the
   Chromium-internal directories (`Cache`, `Code Cache`, `GPUCache`,
   `Service Worker`, `blob_storage`) that Electron apps keep under
   known Application Support roots, Spotify's `PersistentCache` (a streaming
   cache that routinely reaches several gigabytes and lives nowhere near
   `~/Library/Caches`), and downloaded extension `.vsix` archives.
   Cache roots for running applications are kept. "Running" is decided from
   the bundle's executable path (`/Visual Studio Code.app/Contents/MacOS/`),
   not from a process name: Electron apps run as `Electron`, `Code Helper` or
   a renderer, so a name match saw an open editor as idle and cleared the
   cache underneath it. Sandboxed-container caches, whose activity cannot be
   mapped reliably, are kept unless `--force-active-app-caches` is explicitly
   passed.
6. Clear **AI tool caches** for Codex, ChatGPT, Cursor, and Windsurf when the
   matching process is confirmed not running. If process state cannot be
   checked, the caches are kept. Only exact browser-cache directories, known
   macOS bundle caches, and `~/.codex/tmp` are removed. Credentials, settings, conversations/sessions,
   projects, extensions, Codex runtimes, and Ollama/downloaded models are kept.
7. Prune **stale workspace storage**. VS Code (stable and Insiders) keeps
   a `workspaceStorage` entry for every folder ever opened and never
   garbage-collects them. Only entries whose recorded path is genuinely gone
   are removed; remote workspaces and anything unparsable are kept. A path
   that is merely *unreachable* — on a volume that is not mounted, or under
   `~/Library/CloudStorage` where the provider has not materialised it — is
   classed unresolved and kept, so an unplugged external disk or a
   signed-out iCloud Drive does not cost you that project's editor state. The classification is done by
   [`lib/workspace_scan.py`](lib/workspace_scan.py), not by the shell.
8. Empty `~/.Trash`. The Trash sits behind the privacy controls: a terminal
   or agent without Full Disk Access cannot list it. An interactive run then
   asks Finder to empty it; a scheduled run says what to grant instead.
   Neither is a warning. Every other mounted volume's Trash is emptied too,
   except network shares (SMB, NFS, AFP, WebDAV), which are named and
   skipped: a share whose server went away blocks `find` for as long as the
   kernel retries, and a scheduled run has nobody to interrupt it.
9. Prune Docker / OrbStack (stopped containers older than 7 days, networks,
   builder cache, and **dangling images only** — tagged images are kept).
   The container age filter is deliberate: a bare `container prune` also
   removes the stopped container you exited five minutes ago and meant to
   `docker start` again. Unused volumes are
   kept unless `--prune-docker-volumes` is passed: volumes hold data, not
   cache, and a stopped project's database volume counts as "unused" the
   moment its container is removed.
10. Clean Xcode DeviceSupport. Unavailable simulators are only *reported*
   unless `--prune-unavailable-simulators` is passed: `simctl delete
   unavailable` also deletes every device whose runtime merely is not
   installed at this moment — a half-finished Xcode update marks them all
   unavailable — and with them the app data, databases and screenshots on
   those devices. Archives are kept unless an age threshold is explicitly set
   with `--prune-xcode-archives-days N`.
11. Remove diagnostic and crash reports (user, plus system with `sudo`).
12. Remove **old user logs**: files under `~/Library/Logs` older than 30 days.
    Every app, daemon and installer writes there and nothing prunes it, so a
    machine a few years old carries gigabytes of Homebrew, Docker, Adobe and
    IDE transcripts nobody will open. Directories stay, because an app whose
    log directory vanished may not recreate it; `DiagnosticReports` belongs
    to step 11 and `~/Library/Logs/stay_fresh` (the run history and kept
    logs) is left alone.
13. Report **old downloads**: top-level entries in `~/Downloads` untouched
    (by mtime) for 90 days, their total and the five largest. Installers,
    archives and one-off exports land there and nothing ever removes them.
    Reported only; `--prune-downloads-days N` removes entries untouched for
    `N` days, and a dry run lists exactly what would go. Hidden entries such
    as `.DS_Store` are never counted or removed.
14. Report **orphaned launch agents**: plists under `~/Library/LaunchAgents`,
    `/Library/LaunchAgents` and `/Library/LaunchDaemons` whose `Program` (or
    first `ProgramArguments` entry, or the script an interpreter is handed)
    no longer exists. Every tool that ever installed a background helper left
    one, and uninstalling the tool rarely removes it; launchd then retries a
    program that is gone at every login. Reported only;
    `--prune-orphan-agents` unloads and removes the user-level ones. The
    system-level ones are never touched, and the `sudo` command to remove
    them is printed. Binary plists are inspected through `plutil` on macOS.
15. Update and upgrade Homebrew formulae, then casks once when an interactive
    sudo-capable run permits them; run `cleanup -s` and `autoremove`. A stale
    git lock in the Homebrew repository makes `brew update` print "Already
    up-to-date" and exit 0 with the taps untouched, so the upgrade runs on
    the previous index; a lock older than five minutes with no git process
    running is removed, any other lock is named and the update counted as a
    warning. A cask or formula Homebrew has disabled, typically for failing
    the Gatekeeper check, stops being upgraded silently; each one is named
    with its reason. A `brew services` entry in `error` state, a daemon
    launchd has given up restarting, is named and reaches the verdict; it is
    not counted as a warning, because the run cannot fix it. An Intel
    Homebrew still installed at `/usr/local/Homebrew` on Apple silicon is
    named once, because this run maintains only the active prefix.
16. Clean developer-tool caches (`npm`, `yarn`, `pnpm`, `pip`, `uv`, `go`,
    kubectl's per-cluster discovery cache under `~/.kube/cache`, which
    kubectl rebuilds on the next call, and Terraform's provider plugin cache
    where one is configured; `~/.kube/config` and project `.terraform/`
    directories are not touched), remove gcloud's per-invocation log
    directories older than a week, and run `pre-commit gc`, which drops hook
    repositories no config points at. Old installed gem versions are package
    state, not cache, and are kept unless `--cleanup-old-gems` is explicit.
    Gradle's `~/.gradle/caches` and Maven's `~/.m2/repository` are named on
    every run and cleared only with `--prune-build-caches`: they are the
    largest thing under `HOME` on a JVM workstation, and the slowest to get
    back, because the next build downloads every dependency again.
17. Update installed Helm plugins.
18. Update installed [krew](https://krew.sigs.k8s.io/) plugins: refresh the
    index, then `kubectl krew upgrade` each plugin. krew itself is a Homebrew
    formula; the kubectl plugins it installs are not, and nothing else moves
    them.
19. Run `gcloud components update`.
20. Report active versions of `pyenv`, `goenv`, `tfenv`, `tenv`, `helm`,
    `kubectl` and its krew, `terraform`, `docker`, and `gcloud`.
21. Report **pending macOS and App Store updates**: `softwareupdate --list`,
    and `mas outdated` where [`mas`](https://github.com/mas-cli/mas) is
    installed. Read-only. Homebrew keeps what it manages fresh; the operating
    system and App Store apps were the two things this script said nothing
    about. It names what is pending and the command that installs it, and never
    installs anything itself, because a macOS update can reboot the machine.
    Pending updates are reported as information, not as a warning, so a
    scheduled `--fail-on-warn` run does not go red every morning between patch
    days; a query that fails (offline, not signed in to the App Store) is
    reported and does not count against the step either, for the same reason.
    Not probed under `--dry-run`: the catalogue scan is a system action that
    takes time on the network.
22. List **local Time Machine snapshots** (`tmutil listlocalsnapshots /`).
    APFS keeps every block a snapshot references, so a run can free gigabytes
    and `df` still not move; macOS thins the snapshots on its own only under
    disk pressure. Listing is read-only. `--thin-snapshots` deletes them with
    `sudo tmutil deletelocalsnapshots`; the backup disk is never touched, and
    `--no-sudo` demotes the flag to listing. So does a backup in progress
    (`tmutil status` reports `Running = 1`): a backup copies from the newest
    snapshot, and deleting it underneath makes the pass start over, so the
    snapshots are listed and the next run thins.
23. Print a **disk report**, opt-in (`--disk-report` or `--only disk-report`):
    the five largest entries under `~/Library/Caches`, `Application Support`,
    `Containers`, `Developer`, `Logs`, `~/.cache` and `~/Downloads`, plus the
    size of iPhone/iPad backups. Read-only, and off by default because `du`
    over a full home directory takes minutes.

Every real run then ends with a one-line verdict (`stay_fresh OK: freed 1.2G
in 4m10s`, then step counts, packages Homebrew upgraded, casks still outdated,
pending OS updates, snapshots, uptime), appends a row to
`~/Library/Logs/stay_fresh/history.tsv`, rewrites `last-run.json` next to it,
and sends a notification when asked (see `--notify`). `--history` prints the
last ten rows.

### Usage

```bash
./stay_fresh.sh                   # interactive, full run
./stay_fresh.sh --dry-run         # preview the plan
./stay_fresh.sh --yes --verbose   # non-interactive; stream output live
./stay_fresh.sh --brew-greedy     # also upgrade :latest / auto_updates casks
./stay_fresh.sh --no-sudo         # skip every step that requires sudo
./stay_fresh.sh --purge-memory     # explicit cold-cache troubleshooting
./stay_fresh.sh --only brew,versions
./stay_fresh.sh --only ai-caches  # clean AI caches, preserve sessions/models
./stay_fresh.sh --only helm-plugins,krew # refresh the plugins Homebrew does not manage
./stay_fresh.sh --prune-xcode-archives-days 90
./stay_fresh.sh --cleanup-old-gems # opt-in removal of old installed gem versions
./stay_fresh.sh --fail-on-warn     # useful for schedulers and monitoring
./stay_fresh.sh --skip-devtools   # skip all dev-tool refresh steps at once
./stay_fresh.sh --quick           # user-level cleanup only: no sudo, no brew, no reports
./stay_fresh.sh --reports         # the read-only subset: versions, OS updates, snapshots, downloads, launch agents, disk report
./stay_fresh.sh --prune-downloads-days 180 --dry-run # list what an old-downloads prune would remove
./stay_fresh.sh --prune-orphan-agents               # also remove orphaned user LaunchAgents
./stay_fresh.sh --prune-build-caches # also clear ~/.gradle/caches and ~/.m2/repository
./stay_fresh.sh --thin-snapshots  # also delete local Time Machine snapshots
./stay_fresh.sh --disk-report     # also list the largest entries under ~/Library etc.
./stay_fresh.sh --history         # the last ten runs: result, freed, duration
./stay_fresh.sh --yes --notify telegram   # verdict to Telegram (credentials: see below)
./stay_fresh.sh --yes --notify macos,slack # a banner and a Slack message
./stay_fresh.sh --yes --notify-when warn  # notify only when the run warned or failed
```

Telegram credentials come from `STAY_FRESH_TG_BOT_TOKEN` and
`STAY_FRESH_TG_CHAT_ID`, or from the login Keychain, which is the right place
for a scheduled run:

```bash
security add-generic-password -s stay_fresh-telegram -a bot-token -w '<bot token>'
security add-generic-password -s stay_fresh-telegram -a chat-id  -w '<chat id>'
```

The token is handed to `curl` as a config file on stdin, so it never appears
in `ps` output. Slack (`--notify slack`) posts to an incoming webhook whose
URL is the credential; it comes from `STAY_FRESH_SLACK_WEBHOOK` or the
Keychain, and travels the same way:

```bash
security add-generic-password -s stay_fresh-slack -a webhook -w 'https://hooks.slack.com/services/...'
```

macOS banners (`--notify macos`) go through `osascript` and need no setup;
`auto`, the default, picks `macos` when no terminal is attached and `none`
otherwise. `--notify` also takes a comma-separated list (`macos,slack`), and
`both` still means `macos,telegram`. A channel that cannot be reached is
reported on the terminal with the reason and never fails the run.

### Options

| Flag | Purpose |
| --- | --- |
| `--dry-run` | Show the plan; change nothing. |
| `-y`, `--yes` | Authorize a non-interactive real run and suppress supported command prompts. Required when stdin is not a TTY. |
| `-v`, `--verbose` | Stream per-step output live. |
| `--fail-on-warn` | Exit `1` when a step records a real warning; scheduled runs enable this. |
| `--step-timeout N` | Stop any one command inside a step after `N` seconds and count the step as warned (default `1800`; `0` disables; env `STAY_FRESH_STEP_TIMEOUT`). Interactive commands such as cask upgrades are never limited. |
| `--no-sudo` | Skip `purge`, DNS flush, system caches, system diagnostics, and Homebrew cask upgrades. |
| `--only STEP1,STEP2` | Run only named stable step ids; use `--list-steps`. Cannot be mixed with individual `--skip-*` flags. |
| `--quick` | Same as `--only user-caches,app-caches,ai-caches,workspace-storage,trash,user-logs,dev-caches`: everything a user can clear without sudo, Homebrew or the network. Never uses sudo, not even a credential another shell left warm. Cannot be mixed with `--only` or `--skip-*`. |
| `--reports` | Same as `--only versions,os-updates,snapshots,downloads,launch-agents,disk-report`: the read-only subset. Cannot be mixed with `--only`, `--quick`, `--skip-*`, `--thin-snapshots`, `--prune-downloads-days` or `--prune-orphan-agents`. |
| `--list-steps` | List every selectable step id and exit before preflight. |
| `--history` | Print the last ten rows of `~/Library/Logs/stay_fresh/history.tsv` and exit. |
| `--notify MODE` | `none`, `macos`, `telegram`, `slack`, `both` (`macos,telegram`), `auto` (default; env `STAY_FRESH_NOTIFY`), or a comma-separated list of channels. Sent after the summary of a real run, never under `--dry-run`. |
| `--notify-when WHEN` | `always` (default; env `STAY_FRESH_NOTIFY_WHEN`), `warn` (only a WARN or FAILED run) or `fail` (only a FAILED run). A withheld notification is said on the terminal. |
| `--brew-greedy` | Upgrade casks that self-update (`auto_updates true`, `:latest`). |
| `--skip-devtools` | Shorthand for `--skip-helm-plugins --skip-krew --skip-gcloud --skip-versions`. |
| `--purge-memory` | Opt into `sudo purge` for cold-cache troubleshooting. |
| `--skip-memory` | Keep purge disabled; compatibility flag matching the default. |
| `--skip-dns` | Skip the DNS cache flush. |
| `--skip-syscaches` | Skip system-cache cleanup. |
| `--force-system-caches` | Also clear `/System/Library/Caches`, and only then, and only when SIP is positively reported disabled. Boot caches stay. |
| `--skip-usercaches` | Skip user-cache cleanup. |
| `--skip-appcaches` | Skip per-app caches (step 5: Chromium/Electron directories, sandboxed containers, `.vsix`). |
| `--force-active-app-caches` | Also clear running known-app roots and generic sandbox-container caches. |
| `--skip-aicaches` | Skip Codex/ChatGPT/Cursor/Windsurf temporary-cache cleanup. |
| `--skip-workspacestorage` | Skip pruning stale VS Code workspace storage (step 7). |
| `--skip-trash` | Skip emptying `~/.Trash`. |
| `--skip-brew` | Skip Homebrew update/upgrade/cleanup. |
| `--skip-devcaches` | Skip `npm`/`yarn`/`pnpm`/`pip`/`uv`/`go`/kubectl cache cleanup. |
| `--cleanup-old-gems` | Also run `gem cleanup`, which uninstalls old versions from `GEM_HOME`; disabled by default because this changes installed packages. |
| `--prune-build-caches` | Also clear `~/.gradle/caches`, `~/.gradle/wrapper/dists` and `~/.m2/repository` (step 16); off by default because the next build downloads every dependency, and every wrapper distribution, again. |
| `--skip-docker` | Skip Docker / OrbStack prune. |
| `--prune-docker-volumes` | Also remove unused Docker volumes (kept by default — they hold data, not cache). |
| `--skip-xcode` | Skip Xcode extras cleanup. |
| `--prune-xcode-archives-days N` | Remove only `.xcarchive` bundles older than positive integer `N`; archives are otherwise kept. |
| `--prune-unavailable-simulators` | Run `simctl delete unavailable`; unavailable devices and their data are otherwise only reported. |
| `--trend` | Summarise the recorded runs and exit: whether free space is keeping up, which steps do the work, which are slowing down. Read-only. |
| `--skip-diagnostics` | Skip diagnostic and crash-report cleanup. |
| `--skip-user-logs` | Skip removing files under `~/Library/Logs` older than 30 days (step 12). |
| `--skip-downloads` | Skip the old-downloads report (step 13). |
| `--prune-downloads-days N` | Remove top-level `~/Downloads` entries untouched for positive integer `N` days (step 13); off by default, the report only names them. |
| `--skip-launch-agents` | Skip the orphaned-launch-agent report (step 14). |
| `--prune-orphan-agents` | Unload and remove orphaned plists under `~/Library/LaunchAgents` (step 14); system-level ones are only ever reported. |
| `--skip-helm-plugins` | Skip Helm plugin updates. |
| `--skip-krew` | Skip krew plugin updates (step 18). |
| `--skip-gcloud` | Skip `gcloud components update`. |
| `--skip-versions` | Skip the version report. |
| `--skip-os-updates` | Skip the pending macOS / App Store update report (step 21). |
| `--skip-snapshots` | Skip listing local Time Machine snapshots (step 22). |
| `--thin-snapshots` | Delete the local snapshots step 22 lists; needs sudo, listed only under `--no-sudo` or while a Time Machine backup is running. |
| `--disk-report` | Enable the read-only disk report (step 23). |
| `-h`, `--help` | Show the built-in help. |

`--only` is the safer interface for one-off work: it initializes every step as
skipped, then enables exactly the requested ids. The `memory` id remains
double-gated and is rejected unless `--purge-memory` is also present. Existing
skip flags remain unchanged for full maintenance runs.

Preflight can disable a step the machine cannot run — no Homebrew, no Docker
daemon, no Xcode data, or `--no-sudo` against a root-owned step. When that
happens to a step you named in `--only`, the run says which selection was lost
and why. If it takes out *every* id you asked for, the run stops with exit `2`
rather than reaching the summary having done nothing and reporting success;
`--dry-run` previews it as a warning instead, like every other preflight check.

The workspace classifier remains read-only when invoked directly. `--json`
lists individual classifications; `--summary` instead emits JSON counts and
best-effort byte totals for live, stale and unresolved entries:

```bash
./lib/workspace_scan.py \
  "$HOME/Library/Application Support/Code/User/workspaceStorage" --summary
```

Size traversal never follows symlinks and unreadable entries are ignored in
the conservative direction. The default internal stream consumed by
`stay_fresh.sh` NUL-delimits every field, so tabs and newlines in entry paths
cannot alter a cleanup target.

### Output

Only one real run per user can be active at a time; the lock records the
boot it was taken in, so one left by a run the last reboot ended is recognised
as stale even when its pid has been reused (a boot time that moved by
seconds is clock drift, not a reboot; only minutes count). Every command a
step runs is under `--step-timeout` (30 minutes by default), the daemon and
component-manager probes included: `brew update`, `softwareupdate --list`,
`docker info`, `gcloud`, `helm` and `krew` all talk to the network or a
daemon with no bound of their own, and one that hangs used to stall the
scheduled agent and turn every later run away at the lock. A stopped command
is reported with the limit and counts as a warning; one run through `sudo` is
stopped through `sudo` too. Ctrl-C stops the running command and ends the
run, releasing the lock. Every notifier call (the Keychain lookup, `osascript`,
`curl`) is under its own limit (`STAY_FRESH_NOTIFY_TIMEOUT`, 20 seconds), so a
locked keychain or a pending access prompt cannot hold a scheduled run open
after the work is done. The script prints a per-step plan, runs each step
with OK / WARN / FAIL accounting, and closes with a summary that includes:

- Elapsed wall-clock time.
- `df` delta on `/`.
- Sum of per-step deltas (more precise than `df` alone). Under `--dry-run`, a
  `would free` line instead: the sizes of everything the deletions would
  have removed, so the preview answers the question it is run for.
- Which steps passed, warned, were skipped, or failed. A step preflight
  disabled carries its reason, e.g. `Docker / OrbStack prune (the Docker
  daemon is unreachable)`.
- Path to the full log file when warnings or failures caused it to be retained.
- A one-line verdict and a detail line: `stay_fresh OK: freed 1.2G in 4m10s`,
  then `15 ok, 4 skipped; brew upgraded 3; 2 cask(s) still outdated; 1
  OS/App Store update(s) pending; 2 local snapshot(s) kept; up 12d 4h`. The
  same two lines are the notification and the `headline` / `detail` fields of
  `last-run.json`.

Two files under `~/Library/Logs/stay_fresh/` carry the verdict forward:
`history.tsv` gets one tab-separated row per real run (timestamp, result,
elapsed seconds, bytes freed, `df` delta, ok/warn/fail/skip counts, packages
upgraded, OS updates pending, kept log path) and keeps the last 500, and
`last-run.json` is rewritten each time for anything that wants the latest
state without parsing a log: a prompt segment, a status-bar widget, the
agent's `status`, which prints its headline and detail line. A notification
that cannot be sent is reported on the terminal with the reason, and the
clean run's log is discarded only after the notification has gone out.

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Completed (possibly with warnings). |
| `1` | One or more steps hard-failed, or a step warned under `--fail-on-warn`. |
| `2` | Preflight checks failed, another run is active, or a non-interactive real run omitted `--yes`. |
| `3` | Invalid arguments. |

---

## `v1_stay_fresh.sh`

The original housekeeping sequence (previously shipped as
`old_stay_fresh.sh`), preserved for users who prefer the simpler flow.
It has been modernized to run stand-alone: there is no dependency on
`~/scripts/functions`, and the `step`/`next`/`try` reporting helpers are
inlined. Prefer `stay_fresh.sh` unless you specifically need this
minimal runner.

This script is now explicitly **deprecated and behaviorally frozen**. It still
runs for compatibility, but its fixed cleanup includes Xcode Archives and it
will not gain new flags. New automation should use scoped
`stay_fresh.sh --only …` runs.

### Steps

1. Refresh Quick Look and Finder caches.
2. Purge inactive memory (`sudo purge`).
3. Clear history leftovers (`~/.lesshst`, `~/.mysql_history`).
4. Clear user caches (`~/Library/Caches`, Xcode Archives and
   DerivedData, `composer clearcache`).
5. Update Homebrew taps.
6. Upgrade Homebrew formulae.
7. Clean Homebrew caches (`brew cleanup --prune=3 -s`, remove
   `brew --cache`, `brew tap --repair`).
8. Update Terraform via `tfenv`.
9. Update Helm via the upstream `get-helm-3` installer.
10. Update Python via `pyenv` (3.x only).
11. Update Go via `gvm`.
12. Run `gcloud components update`.
13. Print the AWS CLI version.
14. Print free space on `/`.

The invoking user's home directory is resolved via `dscl` (using
`$SUDO_USER` or `id -un`), so cache paths still target the correct user
when the script is launched from a sanitized environment such as `sudo`
or `launchd`.

### Usage

```bash
./v1_stay_fresh.sh              # prompts once for sudo, then runs everything
./v1_stay_fresh.sh --help       # show the built-in help
```

The complete flag surface is `-h` / `--help`. There is no `--dry-run`,
`--yes`, `--no-sudo`, or skip flag — use `stay_fresh.sh` if any of those
are required. A failing step never aborts the remainder of the run.

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Completed normally, including `--help`. Per-step failures are reported in the output but do not change this. |
| `1` | Bootstrap failure: cannot determine a usable home directory. |
| `3` | Invalid arguments. |

If you need hard-fail semantics on per-step failures, use
`stay_fresh.sh` instead.

---

## `brewfile.sh`

`install_apps.sh` and `install_devtools.sh` install a list decided in advance —
the *intent*. `brewfile.sh` records what a machine actually has right now — the
*fact*. The two drift apart quietly: a formula installed by hand for one task is
invisible to the curated scripts and lost on the next machine.

```bash
./brewfile.sh dump              # write ./Brewfile from this machine
./brewfile.sh diff              # what would dump change? (writes nothing)
./brewfile.sh dump --force      # accept those changes
./brewfile.sh check             # is everything in the Brewfile installed?
./brewfile.sh install           # install whatever is missing
./brewfile.sh install --dry-run # list what install would add
./brewfile.sh cleanup           # preview installed items outside the Brewfile
./brewfile.sh cleanup --force   # remove that reviewed extra set
```

Commit the resulting `Brewfile` and a new machine reproduces this one with
`./brewfile.sh install`.

`dump` refuses to overwrite an existing `Brewfile` without `--force`, pointing
you at `diff` first — otherwise a machine missing half your tools would quietly
erase the record of them. `install` passes `--no-upgrade`, so applying a
Brewfile never silently upgrades packages you did not ask about.

`cleanup` provides the reverse reconciliation. Without `--force`, Homebrew
prints the packages that are not declared and the wrapper reports a successful
preview; nothing is removed. The explicit `--force` form performs Homebrew
Bundle cleanup, including Homebrew's documented global-trust-store
reconciliation, so review the preview before applying it. If `--dry-run` and
`--force` are supplied together, dry-run wins and removal remains disabled.

**Exit codes:** `0` success (for `check`: everything present) · `1` failed (for
`check`: something missing) · `2` preflight failed · `3` bad arguments.

---

## `macos_defaults.sh`

Reports macOS preference drift without changing anything. The built-in settings
cover Finder, Dock, keyboard and screenshots; every row records the macOS
generation on which it was verified. Applying is explicit and writes the
previous values to a backup before the first preference change.

```bash
./macos_defaults.sh
./macos_defaults.sh --only finder,dock
./macos_defaults.sh --apply --dry-run --only keyboard
./macos_defaults.sh --apply --backup-file "$HOME/Desktop/macos-defaults.before.txt"
./macos_defaults.sh --revert-from "$HOME/Desktop/macos-defaults.before.txt" --dry-run
./macos_defaults.sh --revert-from "$HOME/Desktop/macos-defaults.before.txt"
```

| Flag | Purpose |
| --- | --- |
| `--apply` | Write desired values after capturing their previous state. |
| `--revert` | Restore the newest default backup in `$TMPDIR`. |
| `--backup-file PATH` | With `--apply`, write a new backup at this explicit path; existing files are never overwritten. |
| `--revert-from PATH` | Restore this explicit backup rather than guessing the newest file. |
| `--dry-run` | Preview apply/revert commands without writes or UI restarts. |
| `--only GROUPS` | Scope the report or apply to comma-separated groups; rejected with revert mode. |
| `--restart-ui` | Restart Finder and Dock after a real successful change. |
| `--list-groups` | Print group ids and exit. |

Before any restore, the whole file is validated: it must be a user-owned,
non-symlink file with the script's backup header and at least one row, and every
domain/key/type and value shape must match the built-in settings catalogue.
This constrains what a restore can execute, but it does not authenticate who
created the file or prove its provenance. Inspect an explicitly supplied backup
before restoring it.

**Exit codes:** `0` success · `1` apply/revert or backup failure · `2` not
macOS · `3` bad arguments.

---

## `workstation_doctor.sh`

The safe first thing to run on a Mac — after a bootstrap to confirm it took, or
on a machine someone has just handed you. It reads and prints; nothing here
installs, upgrades or deletes, so there is no `--dry-run` because there is
nothing to preview.

It answers **is this Mac well?** For **is this Mac safe?**, see
[`hardening_audit.sh`](#hardening_auditsh) below. The two overlap on FileVault,
SIP and Gatekeeper and treat them differently on purpose: the doctor states
what it found, the audit grades it and prints the fix.

### Usage

```bash
./workstation_doctor.sh                     # the whole report
./workstation_doctor.sh --skip-brew-doctor  # 'brew doctor' is the slow part
./workstation_doctor.sh --verbose           # also log full command output
./workstation_doctor.sh --strict            # exit 1 if any warning is found
```

### What it reports

| Section | Contents |
| --- | --- |
| Preflight | macOS version, build and architecture. |
| Security | FileVault, Gatekeeper, SIP, and whether Rosetta is available on Apple Silicon. |
| Disk | Free space on `/`. |
| Xcode CLT | Selected path and the installed package version. |
| Homebrew | Version and prefix, then `brew doctor` unless skipped. |
| SSH | Public keys in `~/.ssh` and how many keys the agent holds. |
| Git identity | Global `user.name` and `user.email`. |
| Time Machine | `tmutil status`, the latest backup, and local APFS snapshot count. |
| Logs | Sizes of `~/Library/Logs`, its `DiagnosticReports`, and `/Library/Logs`. |
| LaunchAgents | The `.plist` files in `~/Library/LaunchAgents`. |
| Login items | Read through AppleScript, so it may prompt for Automation access. |

### Options

| Flag | Purpose |
| --- | --- |
| `-v`, `--verbose` | Log full command output to the log file. |
| `--skip-brew-doctor` | Skip `brew doctor`, comfortably the slowest check. |
| `--skip-login-items` | Skip the AppleScript login-item listing (it can prompt for Automation permission). |
| `--skip-time-machine` | Skip the Time Machine / `tmutil` section. |
| `--skip-log-sizes` | Skip the log and diagnostic size estimates. |
| `--skip-launchd` | Skip the LaunchAgents listing. |
| `--strict` | Preserve the report but exit `1` when one or more warnings were emitted. |
| `-h`, `--help` | Show the built-in help. |

The report is written to `$TMPDIR/workstation_doctor-YYYYMMDD-HHMMSS.log` as
well as to the terminal.

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | The report ran; by default, warnings do not change this. |
| `1` | `--strict` was requested and the report emitted warnings. |
| `2` | Preflight failed — not macOS, or running as `root`. |
| `3` | Invalid arguments. |

The Windows counterpart is
[`windows/setup/workstation_doctor.ps1`](../windows/setup/workstation_doctor.ps1)
and the Linux one is [`linux/system_doctor.sh`](../linux/system_doctor.sh).

---

## `hardening_audit.sh`

Read-only security audit, and the macOS half of
[`linux/hardening_audit.sh`](../linux/hardening_audit.sh) down to the flags and
the exit codes.

**There is no `--apply` and no `--fix`, deliberately.** Every finding it prints
has a context where the "insecure" answer is the correct one — SIP off on a
machine that develops kernel extensions, Remote Login on for a Mac you actually
`ssh` into. A script that hardened automatically would be wrong often enough to
be dangerous, so this one hands you the finding and the command and lets you
decide.

### Usage

```bash
./hardening_audit.sh                        # every group
./hardening_audit.sh --list-groups
./hardening_audit.sh --only firewall,disk,lock  # a subset
./hardening_audit.sh --quiet                # warnings and failures only
./hardening_audit.sh --fail-on warn         # exit 1 on a warning too
sudo ./hardening_audit.sh                   # a few probes read more as root
```

### Groups

| Group | Checks |
| --- | --- |
| `sharing` | Remote Login (ssh), Screen Sharing, File Sharing. |
| `firewall` | Application Firewall state, and stealth mode when it is on. |
| `updates` | Automatic check, download, security-response and macOS-update settings, plus how long since the last successful check. |
| `disk` | FileVault, including the deferred-enablement state that looks enabled and is not. |
| `lock` | Whether a password is required immediately after display sleep or the screen saver; an unlocked delay is graded. |
| `sip` | System Integrity Protection, including a partially-disabled custom configuration. |
| `gatekeeper` | Whether assessments are enabled. |

The `sharing` checks ask `netstat` which ports are listening rather than
`systemsetup`, which needs root: an audit you have to `sudo` is an audit nobody
runs. Loopback-only listeners are ignored, so an ssh tunnel endpoint on
`127.0.0.1` is not reported as File Sharing being switched on.

### Options

| Flag | Purpose |
| --- | --- |
| `--only GROUPS` | Comma-separated subset (see `--list-groups`). |
| `--fail-on LEVEL` | Exit `1` on `fail` (default) or on `warn` and above. |
| `--quiet` | Print only warnings and failures. |
| `--list-groups` | Print the group names and exit. |
| `-h`, `--help` | Show the built-in help. |

Every finding is one line — verdict, what was checked, and for anything that is
not a `pass`, the command that addresses it. A check that cannot answer says
`skip` rather than guessing: a false all-clear is the worst thing an audit can
print.

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Nothing at or above the failure threshold. |
| `1` | One or more findings at or above `--fail-on`. |
| `2` | Preflight failed — not macOS. |
| `3` | Invalid arguments. |

---

## `launchd/stay_fresh_agent.sh`

Maintenance that depends on remembering to run it does not happen. This installs
a per-user LaunchAgent that runs `stay_fresh.sh` on a schedule.

```bash
./launchd/stay_fresh_agent.sh install                      # Mondays, 10:30
./launchd/stay_fresh_agent.sh install --weekday daily --hour 3
./launchd/stay_fresh_agent.sh install --profile full       # original broad maintenance
./launchd/stay_fresh_agent.sh install --notify telegram    # verdict to Telegram after each run
./launchd/stay_fresh_agent.sh install --dry-run            # preview install only
./launchd/stay_fresh_agent.sh install --print-only         # show plist, install nothing
./launchd/stay_fresh_agent.sh status                       # plist, launchd state, last run's verdict
./launchd/stay_fresh_agent.sh run-now
./launchd/stay_fresh_agent.sh install --ignore-power        # every firing sweeps, battery or in use
./launchd/stay_fresh_agent.sh run-scheduled --ignore-power  # sweep even on battery
./launchd/stay_fresh_agent.sh logs --tail 120
./launchd/stay_fresh_agent.sh uninstall
```

The default `safe` profile runs only protected per-app and AI cache cleanup,
conservative stale-workspace cleanup, version reporting, and the read-only
reports: pending macOS / App Store updates, the local snapshot listing (never
thinning), old downloads and orphaned launch agents (both listed, never
removed). The reports are why a scheduled verdict is worth reading: a pending
OS update, a pile of local snapshots, a gigabyte of installers and a helper
launchd retries at every login are what a Mac accumulates without anyone
noticing. It does not empty Trash, prune Docker, remove broad
user/Xcode/developer caches or old logs, upgrade packages, or update plugins.
Pass `install --profile full` to retain the previous broad scheduled behavior.
`install --notify-when warn` keeps the channel quiet on a clean run.

**A scheduled run checks two things before it sweeps.** On battery it **defers
entirely**: a full sweep is minutes of `du` and `rm` plus a `brew upgrade`, and
that is somebody's afternoon spent without being asked — the next firing on
mains does the work. With somebody **at the keyboard** (any input in the last
five minutes) it runs the read-only reports instead of the sweep; deferring
outright would mean a machine in use at that hour every day never runs at all,
and the reports are the part worth having daily. Either decision is recorded in
the `last-scheduled` stamp and shown by `status`, so a deferral is never silent.
`--ignore-power` skips both checks. Pass it to `install` to bake it into the
plist, so every firing sweeps regardless, or to a single `run-scheduled`. It is
refused by the commands with no firing to un-guard (`status`, `run-now`, `logs`,
`uninstall`). Neither check applies to `run-now`, which is a person asking
deliberately, and a machine with no battery — or one where `pmset` and `ioreg`
cannot be read — takes the ordinary path.

A scheduled run keeps the ten newest transcripts in
`~/Library/Logs/stay_fresh/` and deletes the rest. `--dry-run` is exempt: it
writes its own transcript, so you can read what the firing would have done, and
deletes nothing.

**The agent cannot use `sudo`, and that is not a limitation to work around.** A
LaunchAgent runs in your GUI login session with no terminal attached, so a
password prompt has nothing to prompt and would hang or fail silently. The agent
therefore always runs `--no-sudo --yes`, which means these steps are **skipped**
on every scheduled run:

- memory purge
- DNS flush
- system caches (`/Library/Caches`, `/System/Library/Caches`)
- system diagnostic and crash reports

With `--profile full`, everything else — user caches, safe per-app caches,
workspace storage, trash, Homebrew formulae, Docker, Xcode extras, and dev-tool
caches — runs normally. Cask upgrades are skipped because they may invoke an
interactive sudo prompt. Run `stay_fresh.sh` by hand for root-owned steps and
casks.

Every scheduled run passes `--fail-on-warn`, so incomplete cleanup or a failed
update produces a non-zero launchd exit status instead of appearing healthy.
A scheduled run has no terminal, so `stay_fresh.sh`'s default `--notify auto`
posts a Notification Center banner with the verdict when it finishes; `install
--notify telegram` (or `slack`, `both`, `none`, or a list such as
`macos,slack`) is stored in the plist and passed through. Telegram credentials
and the Slack webhook belong in the login Keychain for this use (see the
`stay_fresh.sh` usage above), because the agent's environment carries only
`PATH`.

`status` also tells you when the job has stopped running, which is the failure
a schedule hides best: launchd still says loaded and the last verdict still
reads OK, the Mac was simply asleep every Monday at 10:30. Every real
scheduled run stamps `~/Library/Logs/stay_fresh/last-scheduled` with its time
and exit code; `status` measures from that stamp, or from the plist's
modification time when the job has never fired, takes the plist's schedule as
the yardstick (weekly when the plist carries a `Weekday`, daily otherwise),
and warns and exits `1` when more than twice that interval has passed.
`last-run.json` is not the measure, because a manual `stay-fresh --quick`
rewrites it and would hide a job that never fires. The `--notify` value is
checked by `stay_fresh.sh` itself at install time, so a list the scheduled run
would refuse is refused before the plist is written.
Install and replacement are transactional: a failed bootstrap restores the
previous plist and restarts the old job. `uninstall --dry-run` previews removal;
options that do not belong to a command are rejected with exit `3`.

The generated plist supplies a controlled PATH containing Apple system paths
and both Homebrew locations. The agent is `ProcessType Background` with
`LowPriorityIO` and `Nice 10`; `StartCalendarInterval` itself coalesces a
schedule missed while the Mac sleeps into one wake-time run. `run-now` refuses
to interrupt an execution already in progress.

Each invocation writes
`~/Library/Logs/stay_fresh/agent-<timestamp>-<pid>.log`; the ten newest logs are
kept. `logs` finds the newest timestamped file and prints its last 80 lines (or
the positive count passed through `--tail`) without starting, stopping, or
reloading the agent.

---

## `zsh_aliases.zsh`

A curated set of zsh aliases and helper functions. Every optional
dependency (`eza`, `bat`, `fd`, `rg`, `docker`, `kubectl`, `helm`,
`terraform`, `pyenv`, `goenv`, and so on) is guarded behind
`command -v`, so the file is safe to source on any machine regardless
of which tools are installed.

### Installation

```bash
ln -sfn "$PWD/zsh_aliases.zsh" "$HOME/.zsh_aliases.zsh"
grep -qsF '.zsh_aliases.zsh' ~/.zshrc \
  || echo '[[ -f "$HOME/.zsh_aliases.zsh" ]] && source "$HOME/.zsh_aliases.zsh"' \
       >> ~/.zshrc
exec zsh
```

Re-running the block is safe: `ln -sfn` overwrites the symlink in place,
and the `grep` guard ensures the `source` line is appended to `~/.zshrc`
only once.

### What you get

| Category | Highlights |
| --- | --- |
| Safety | `cp`, `mv`, `rm` default to `-i` (use `\rm` to bypass). |
| Navigation | `..`, `...`, `....`, `.....`, `-`, `~`, `mkcd`, `up N`. |
| Listing | `ls`, `l`, `ll`, `la`, `lt` prefer `eza` when available. |
| Modern replacements | `cat`→`bat`, `top`→`htop`, `df`→`duf`, `du`→`dust`. `fd` and `rg` keep their own names — they are never aliased over `find`/`grep` (the flags differ). |
| Git | `gs`, `gaa`, `gcm`, `gco`, `gcb`, `gp`, `gpl`, `gl`, plus `gwip` (stage + checkpoint) and `gprune` (delete merged branches). |
| Docker / Compose | `d`, `dps`, `dprune`, `dc`, `dcu`, `dcd`, `dcl`. |
| Kubernetes | `k`, `kg`, `kd`, `kl`, `kx`, `kns`. |
| Homebrew | `brewup` (`update` + `upgrade --greedy` + `cleanup` + `autoremove`). |
| Python | Auto-inits `pyenv` + `pyenv-virtualenv`; `venv` creates and activates a local `.venv`. |
| Go | Auto-inits `goenv`, adds `$GOPATH/bin` to `PATH`; `gor`, `gob`, `got`. |
| Terraform / OpenTofu / Helm | `tf*`, `to*`, `h*` shortcuts. |
| Script shortcuts | Guarded `stay-fresh`, installers, doctor, audit, defaults, Brewfile, agent and latest-agent-log commands. `stay-fresh` (and `stay_fresh.sh`) tab-completes its flags, the step ids after `--only` and the channels after `--notify`; both lists come from the script's own `--help` and `--list-steps`, so they cannot drift. Needs `compinit` to have run before this file is sourced. |
| macOS helpers | `flushdns`, `purgemem`, `showfiles`/`hidefiles`, `lock`, `ejectall`, `localip`, `myip`, `pbj`. |
| Functions | `toolbox-help`, `mkcd`, `extract`, `up N`, `mkbackup`, `weather [city]`. |

The `_ZSH_ALIASES_DIR` variable resolves the directory of this file, so
the script shortcuts keep working regardless of where the repository is
cloned. The file is designed to be read top to bottom — comment out
anything you do not want, or append your own additions at the end.
Run `toolbox-help` for a command palette generated from only the executable
scripts actually present in the checkout.

---

## Development: Docker checks

These scripts target macOS, but a **small Linux container** can still verify
syntax, ShellCheck, `--help`, the documented exit codes, that
`zsh_aliases.zsh` sources cleanly in `zsh`, and — with the host commands faked —
what each `stay_fresh.sh` step actually deletes and keeps. You need **Docker**
with the **Compose v2** plugin; nothing else on the host.

From the **repository root**:

```bash
./macos-initial-setup/tests/run.sh          # all three suites
./macos-initial-setup/tests/run.sh steps    # just one
```

Every suite runs even if an earlier one fails, so one invocation reports
everything that is broken. Without the wrapper:

```bash
docker compose -f macos-initial-setup/tests/docker-compose.yml run --rm -T tester
```

The `tester` image (`tests/tester/Dockerfile`) installs `bash`, `shellcheck`,
`zsh` and `python3`, mounts the repo read-only at `/repo`, and backs three
suites:

| Suite | File | Scope |
| --- | --- | --- |
| `tester` | `test_macos_initial_setup.sh` | Static checks and the CLI surface of every script: `--help`, argument rejection, plans, dry runs. |
| `steps` | `test_stay_fresh_steps.sh` | Each of the twenty-three `stay_fresh.sh` steps **executed for real** against a scratch `HOME` and faked host binaries. |
| `unprivileged` | `test_stay_fresh_unprivileged.sh` | The permission-denied branches, as uid 1000. Root can create any directory and delete any file, so these are unreachable in the other two. |

The `steps` suite fakes only the commands that identify the host or that the
step drives (`uname`, `pgrep`, `sudo`, `brew`, `docker`, `helm`, …). `find`,
`rm` and `du` are the real thing, so deletion is really deletion and the
assertions are about what survived. Two steps clear absolute system paths
(`/Library/Caches`, `/Library/Logs/DiagnosticReports`); in a disposable
container those are ours to destroy, and the suite **refuses to start** outside
one, because on a real Mac it would clear the caller's system caches.

A container is also the only place some of this is observable at all. It has no
controlling terminal — the state a launchd-scheduled run is in — and its
root-owned `/rootonly` and `/rootlocked` make `mkdir(2)` genuinely return
`EACCES`. Both cases caught bugs a macOS host would have hidden.

The subjects are **discovered** with `find`, two levels deep so `launchd/` is
covered, rather than listed in the harness. The list they replaced named four
scripts while the package grew to nine, so `brewfile.sh`, `macos_defaults.sh`,
`workstation_doctor.sh` and `launchd/stay_fresh_agent.sh` went unchecked here
for a long time — the drift that
[`test-env/lib/discover_clis.sh`](../test-env/lib/discover_clis.sh) was
written to stop. A new script is now covered by the commit that adds it.

| Check | Notes |
| --- | --- |
| `bash -n` | Every discovered `*.sh`. |
| ShellCheck | `--severity=error` for the bash scripts. Debian’s stock ShellCheck may not ship a `zsh` dialect — the harness then **skips** `zsh` ShellCheck but still **sources** `zsh_aliases.zsh` in `zsh`. |
| CLI | `--help` exits **0** and an unknown flag exits **3**, for every discovered script — both before any preflight check. |
| Platform guard | On Linux every script with a platform guard exits **2** with a “macOS only” message. `v1_stay_fresh.sh` is the one exception, and is skipped by name: it is the preserved original and has no guard. |
| `hardening_audit.sh` | `--list-groups` and group validation answer ahead of the macOS-only probes, the same ordering `--help` has to keep. |
| `zsh_aliases.zsh` | Not in the `--help` contract — it is sourced, not run — but it is ShellCheck'd and must `source` cleanly under `zsh -f`. |

This is **not** a substitute for `--dry-run` on a real Mac: there is no
Homebrew and no installs. The `steps` suite executes `stay_fresh.sh` against
faked host binaries, not against Apple APIs. For RouterOS script integration
tests in the same repository, see
[`mikrotik/tests/README.md`](../mikrotik/tests/README.md).

---

## What this changes on your machine

A plain-language audit trail of every side effect, grouped by the
script responsible. Everything below is reversible with standard
Homebrew / `pyenv` / `goenv` commands.

### `install_apps.sh`

- Installs Homebrew at `/opt/homebrew` (Apple Silicon) or `/usr/local`
  (Intel) if it is missing.
- Installs the casks listed under *Bundled applications*; existing
  unmanaged apps in `/Applications` are adopted into Homebrew.
- Installs the `gcloud-cli` cask and the components listed with
  `--gcloud-components`.
- Writes `/tmp/install_apps-YYYYMMDD-HHMMSS.log`.
- Runs `brew cleanup` at the end unless `--no-cleanup` is passed.
- Does **not** modify any shell configuration files.

### `install_devtools.sh`

- Installs the selected version manager(s): `pyenv`,
  `pyenv-virtualenv`, `tfenv` or `tenv`, `goenv`, and/or `mise` via
  Homebrew.
- Installs Python build dependencies:
  `openssl readline sqlite3 xz zlib tcl-tk`.
- Installs the pinned (or latest) versions of Python, Terraform, Go,
  and Helm under each manager's usual directory (`~/.pyenv`,
  `~/.goenv`, `$(brew --prefix)/bin`).
- Installs the configured Helm plugins (default: `helm-diff`).
- Appends one bracketed block per tool to `~/.zshrc` or `~/.bashrc`
  **only when `--setup-shell` is passed**. Each block is marked so it
  can be located and removed by hand.
- Writes `/tmp/install_devtools-YYYYMMDD-HHMMSS.log`.

### `brewfile.sh`

- `dump` replaces the selected Brewfile only with explicit `--force` when it
  already exists; `diff` and `check` never write it.
- `install` adds missing declared packages without upgrading existing ones.
- `cleanup` changes nothing by default; `cleanup --force` uninstalls packages
  outside the selected Brewfile and reconciles Homebrew's Bundle trust state.

### `macos_defaults.sh`

- The default report, `--list-groups`, and every `--dry-run` are read-only.
- A real `--apply` writes desired preferences only after creating a new backup;
  an explicit backup path is never overwritten.
- A real `--revert` writes only catalogue settings from a validated backup.
- Finder and Dock are restarted only when `--restart-ui` accompanies a real
  successful apply/revert.

### `stay_fresh.sh`

- Deletes cache contents (not the directories themselves) under
  `/Library/Caches`, `~/Library/Caches`, Saved State, Xcode DerivedData,
  and related paths. `/System/Library/Caches` is touched only when SIP is
  positively reported disabled *and* `--force-system-caches` is passed, and
  never the boot caches (`com.apple.dyld`, `com.apple.kernelcaches`,
  `com.apple.bootstamps`). An unknown SIP status is treated as on. Entries
  SIP or the privacy controls protect are kept and counted; entries owned by
  another user are retried with sudo when a credential is in hand.
- Deletes per-app cache contents outside `~/Library/Caches`: the
  Chromium-internal directories under known Application Support roots and
  downloaded `.vsix` archives. Running application roots are skipped;
  sandbox-container caches require `--force-active-app-caches`.
- Deletes exact disposable cache directories for idle Codex, ChatGPT, Cursor,
  and Windsurf installations, plus their known bundle caches and CLI
  temp roots. Active or unknown process state keeps the cache. It preserves
  credentials, settings, conversations/sessions, project state, extensions,
  Codex runtimes, and downloaded models.
- Keeps Xcode Archives by default. `--prune-xcode-archives-days N` removes only
  old `.xcarchive` bundles matching the explicit retention threshold.
- Keeps unavailable simulators and their data by default; deleting them needs
  `--prune-unavailable-simulators`.
- Removes VS Code `workspaceStorage` entries whose project folder is gone.
  Remote workspaces, unreadable entries, and paths on an unmounted volume or
  in unmaterialised `~/Library/CloudStorage` are left alone.
- Empties `~/.Trash`, through Finder when the shell lacks Full Disk Access
  and a person is present to answer the prompt.
- Clears developer-tool caches (`npm`, `yarn`, `pnpm`, `bun`, `pip`, `uv`,
  `go`), the contents of `~/.kube/cache`, `~/.minikube/cache` and Terraform's
  plugin cache, gcloud log directories older than a week, and unused
  pre-commit repositories. minikube's `machines/`, `profiles/` and `certs/`
  are the cluster and its credentials and are never touched; only the ISO and
  image cache it re-downloads on demand.
  `TF_PLUGIN_CACHE_DIR` is cleared only when it ends in `plugin-cache`; a
  variable pointed at a working directory, or at `$HOME`, is warned about
  and left untouched.
  Installed gem versions are kept unless `--cleanup-old-gems` is explicit.
- Queries `softwareupdate --list` and, when installed, `mas outdated`, and
  prints what is pending. Installs neither.
- Prunes Docker resources when Docker is available:
  - Containers stopped for more than 7 days
    (`docker container prune -f --filter until=168h`) — a bare prune would
    also take the container you stopped minutes ago
  - Networks (`docker network prune -f`)
  - Volumes only with `--prune-docker-volumes` — they hold data, and the
    LaunchAgent runs with `--yes`, so a default volume prune would delete a
    stopped project's database volume unattended
  - **Dangling images only** (`docker image prune -f`) — keeps tagged images
  - Builder cache (`docker builder prune -af`)
  - Skips pruning entirely when the active Docker context points to a non-local
    daemon (non-`unix://…` host), or when the endpoint cannot be resolved, to
    avoid cleaning a remote engine by mistake.
- Upgrades Homebrew formulae and casks (greedy upgrade only with
  `--brew-greedy`).
- Updates Helm plugins and `gcloud` components when those tools are
  installed.
- Refuses to run when `HOME` is unset, empty or not a directory (exit `2`):
  every path it clears is built from `HOME`, and an empty one resolves to
  system directories. `--help` and `--list-steps` work without one.
- Writes `$TMPDIR/stay_fresh-YYYYMMDD-HHMMSS.log` during the run. A
  clean run discards it; a run with warnings or failures keeps it under
  `~/Library/Logs/stay_fresh/`, pruned to the ten most recent. When
  `TMPDIR` cannot be written (a full disk is exactly when this script is
  run), the log and the scratch lists the sweeps need move to
  `~/Library/Logs/stay_fresh/`; when that fails too, the run goes ahead
  without a log and says so. Every `[warn]` and `[err ]` line is written to
  the log as well as to the terminal, timestamped — the kept log is read
  after a scheduled run, and it used to hold the command transcript but not
  the reason the run was kept. Nothing is opened until preflight passes, so
  a refused run (no `--yes` in a non-interactive shell, an unsupported OS)
  still writes nothing at all.
- Appends one row per real run to `~/Library/Logs/stay_fresh/history.tsv`
  and one row per step to `steps.tsv` beside it, and rewrites `last-run.json`.
  `--trend` reads them back; nothing else does. Sends a notification only when
  `--notify` (or `STAY_FRESH_NOTIFY`) asks for one, and reads the Telegram
  token from the environment or the `stay_fresh-telegram` Keychain items and
  the Slack webhook from the environment or the `stay_fresh-slack` item.
- Removes files under `~/Library/Logs` older than 30 days, except under
  `DiagnosticReports` and its own `stay_fresh` directory; directories stay.
- Clears `~/.gradle/caches` and `~/.m2/repository` only with
  `--prune-build-caches`.
- Reports old entries in `~/Downloads` and orphaned launchd plists; removes
  the former only with `--prune-downloads-days N` and the user-level latter
  only with `--prune-orphan-agents`. System-level plists are never touched.
- Empties the per-user Trash of every mounted volume (`/Volumes/*/.Trashes/<uid>`),
  not only `~/.Trash`.
- Deletes local Time Machine snapshots only with `--thin-snapshots`; by
  default it lists them.
- Does **not** modify any shell configuration files.

### `v1_stay_fresh.sh`

- Runs the subset of cleanup and toolchain updates listed in its
  *Steps* section.
- Deletes `~/.lesshst` and `~/.mysql_history` if present.
- Writes no log file by default; redirect yourself with `tee` if a
  transcript is needed:

  ```bash
  ./v1_stay_fresh.sh 2>&1 | tee /tmp/v1_stay_fresh.log
  ```

### `zsh_aliases.zsh`

- Affects interactive shells only. Sourcing the file adds aliases and
  functions to the current shell; it does not write anything to disk
  and does not modify system files.

### Privileged operations

These scripts request `sudo` only for the operations below. They prompt once
at the start and release the credential on exit.

Refusing to run as `root` is not universal: `install_apps.sh`,
`install_devtools.sh`, `stay_fresh.sh` and `workstation_doctor.sh` refuse.
`v1_stay_fresh.sh` does the opposite — it resolves `${SUDO_USER:-$(id -un)}`
and expects to be run under `sudo`. `hardening_audit.sh` has no check either
way and is meant to be run with `sudo` for the checks that need it.

| Script | Uses `sudo` for |
| --- | --- |
| `install_apps.sh` | Cask installs that require admin approval (Homebrew invokes `sudo` internally; the script itself does not escalate). |
| `install_devtools.sh` | Same as above, only via Homebrew where required. |
| `stay_fresh.sh` | `purge`, DNS flush, `/Library/Caches` cleanup, system diagnostic cleanup. Pass `--no-sudo` to skip all of these. |
| `v1_stay_fresh.sh` | `purge`. No way to opt out — use `stay_fresh.sh --no-sudo` instead. |
