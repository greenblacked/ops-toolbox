# macOS Initial Setup

> Opinionated, idempotent shell scripts for provisioning and maintaining
> a macOS workstation.

This folder is the macOS setup package inside the broader helper-scripts
repository. It turns the normal "fresh Mac checklist" — install apps, wire
up language toolchains, keep caches and Homebrew under control — into a set
of small, composable scripts that are safe to run today, next month, and on
the next machine. Every change is previewable with `--dry-run`, logged to
`$TMPDIR`, and opt-out at a per-feature level.

**Platform:** macOS 12+ (Monterey through the current release) on Apple
Silicon and Intel. **Shell:** `bash` for scripts (`#!/usr/bin/env bash`),
`zsh` for the aliases file.

## Table of contents

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
| `launchd/stay_fresh_agent.sh` | Install a LaunchAgent so `stay_fresh.sh` runs on a schedule instead of when you remember. |
| `lib/workspace_scan.py` | Classifier used by `stay_fresh.sh` to decide which editor `workspaceStorage` entries are dead. Not run directly. |
| `zsh_aliases.zsh` | Optional interactive-shell aliases and helper functions. |
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
| **Logged** | Every non-trivial script writes a timestamped log to `$TMPDIR`. `--verbose` also streams to the terminal. |
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
| `--skip-formulae a,b,c` | Skip individual formula names (comma-separated). |
| `--gcloud-components a,b,c` | Override the default component set. |
| `--no-gcloud-components` | Install `gcloud` core only (no components). |
| `-h`, `--help` | Show the built-in help (lists every cask and formula). |

### Bundled cask applications

**General use:** `brave-browser`, `visual-studio-code`, `cursor`,
`orbstack`, `slack`, `zoom`, `telegram`, `spotify`.

**DevOps and platform engineering (GUI):** `iterm2`, `raycast`, `github`,
`lens`, `postman`, `drawio`, `wireshark-app`, `dbeaver-community`,
`google-chrome`, `1password`, `microsoft-teams`, `notion`, `tailscale-app`,
`cloudflare-warp`, `ngrok`, `rectangle`, `alt-tab`, `maccy`, `zed`,
`sublime-text`, `jetbrains-toolbox`, `fork`, `gitkraken`,
`azure-data-studio`, `postico`, `redisinsight`, `cyberduck`, `proxyman`,
`linear-linear`, `discord`.

Pass `--skip a,b,c` to omit casks your organization provisions elsewhere.
The `ngrok` cask installs a **binary only** (no `.app`).

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

1. Purge inactive memory (`sudo purge`).
2. Flush the DNS cache (`dscacheutil`, `mDNSResponder`).
3. Clear system caches (`/Library/Caches` and writable entries under
   `/System/Library/Caches`).
4. Clear user caches (`~/Library/Caches`, Logs, Saved State, Xcode
   DerivedData, and related paths).
5. Empty `~/.Trash`.
6. Clean developer-tool caches (`npm`, `yarn`, `pnpm`, `pip`, `gem`,
   `go`, `cargo`).
7. Prune Docker / OrbStack (containers, networks, volumes, builder
   cache, and **dangling images only** — tagged images are kept).
8. Clean Xcode extras (Archives, DeviceSupport, obsolete simulators).
9. Remove diagnostic and crash reports (user and system).
10. Update and upgrade Homebrew (formulae and casks), run `cleanup` and
    `autoremove`.
11. Run `mise self-update`, update plugins, and upgrade tools.
12. Update installed Helm plugins.
13. Run `gcloud components update`.
14. Report active versions of `pyenv`, `goenv`, `tfenv`, `tenv`, `helm`,
    and `gcloud`.

### Usage

```bash
./stay_fresh.sh                   # interactive, full run
./stay_fresh.sh --dry-run         # preview the plan
./stay_fresh.sh --yes --verbose   # non-interactive; stream output live
./stay_fresh.sh --brew-greedy     # also upgrade :latest / auto_updates casks
./stay_fresh.sh --no-sudo         # skip every step that requires sudo
./stay_fresh.sh --skip-devtools   # skip all dev-tool refresh steps at once
```

### Options

| Flag | Purpose |
| --- | --- |
| `--dry-run` | Show the plan; change nothing. |
| `-y`, `--yes` | Skip confirmation prompts. |
| `-v`, `--verbose` | Stream per-step output live. |
| `--no-sudo` | Skip `purge`, DNS flush, system caches, and system diagnostics. |
| `--brew-greedy` | Upgrade casks that self-update (`auto_updates true`, `:latest`). |
| `--skip-devtools` | Shorthand for `--skip-mise --skip-helm-plugins --skip-gcloud --skip-versions`. |
| `--skip-memory` | Skip the `sudo purge` step. |
| `--skip-dns` | Skip the DNS cache flush. |
| `--skip-syscaches` | Skip system-cache cleanup. |
| `--skip-usercaches` | Skip user-cache cleanup. |
| `--skip-trash` | Skip emptying `~/.Trash`. |
| `--skip-brew` | Skip Homebrew update/upgrade/cleanup. |
| `--skip-devcaches` | Skip `npm`/`yarn`/`pnpm`/`pip`/`gem`/`go`/`cargo` cache cleanup. |
| `--skip-docker` | Skip Docker / OrbStack prune. |
| `--skip-xcode` | Skip Xcode extras cleanup. |
| `--skip-diagnostics` | Skip diagnostic and crash-report cleanup. |
| `--skip-mise` | Skip `mise` update. |
| `--skip-helm-plugins` | Skip Helm plugin updates. |
| `--skip-gcloud` | Skip `gcloud components update`. |
| `--skip-versions` | Skip the final version report. |
| `-h`, `--help` | Show the built-in help. |

### Output

The script prints a per-step plan, runs each step with OK / WARN / FAIL
accounting, and closes with a summary that includes:

- Elapsed wall-clock time.
- `df` delta on `/`.
- Sum of per-step deltas (more precise than `df` alone).
- Which steps passed, warned, were skipped, or failed.
- Path to the full log file.

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Completed (possibly with warnings). |
| `1` | One or more steps hard-failed. |
| `2` | Preflight checks failed. |
| `3` | Invalid arguments. |

---

## `v1_stay_fresh.sh`

The original housekeeping sequence (previously shipped as
`old_stay_fresh.sh`), preserved for users who prefer the simpler flow.
It has been modernized to run stand-alone: there is no dependency on
`~/scripts/functions`, and the `step`/`next`/`try` reporting helpers are
inlined. Prefer `stay_fresh.sh` unless you specifically need this
minimal runner.

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
| `2` | Invalid arguments. |

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
```

Commit the resulting `Brewfile` and a new machine reproduces this one with
`./brewfile.sh install`.

`dump` refuses to overwrite an existing `Brewfile` without `--force`, pointing
you at `diff` first — otherwise a machine missing half your tools would quietly
erase the record of them. `install` passes `--no-upgrade`, so applying a
Brewfile never silently upgrades packages you did not ask about.

**Exit codes:** `0` success (for `check`: everything present) · `1` failed (for
`check`: something missing) · `2` preflight failed · `3` bad arguments.

---

## `launchd/stay_fresh_agent.sh`

Maintenance that depends on remembering to run it does not happen. This installs
a per-user LaunchAgent that runs `stay_fresh.sh` on a schedule.

```bash
./launchd/stay_fresh_agent.sh install                      # Mondays, 10:30
./launchd/stay_fresh_agent.sh install --weekday daily --hour 3
./launchd/stay_fresh_agent.sh install --dry-run            # agent previews only
./launchd/stay_fresh_agent.sh install --print-only         # show plist, install nothing
./launchd/stay_fresh_agent.sh status
./launchd/stay_fresh_agent.sh run-now
./launchd/stay_fresh_agent.sh uninstall
```

**The agent cannot use `sudo`, and that is not a limitation to work around.** A
LaunchAgent runs in your GUI login session with no terminal attached, so a
password prompt has nothing to prompt and would hang or fail silently. The agent
therefore always runs `--no-sudo --yes`, which means these steps are **skipped**
on every scheduled run:

- memory purge
- DNS flush
- system caches (`/Library/Caches`, `/System/Library/Caches`)
- system diagnostic and crash reports

Everything else — user caches, per-app caches, workspace storage, trash,
Homebrew, Docker, Xcode extras, dev-tool caches — runs normally. Run
`stay_fresh.sh` by hand when you want the root-owned steps too.

The agent is `ProcessType Background` with `LowPriorityIO` and `Nice 10`, so it
never competes with interactive work, and `StartCalendarIntervalRunMissed`
catches a run missed because the Mac was asleep — once, not once per missed
interval.

Logs go to `~/Library/Logs/stay_fresh/agent.{out,err}.log`.

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
| Modern replacements | `cat`→`bat`, `find`→`fd`, `grep`→`rg`, `top`→`htop`, `df`→`duf`, `du`→`dust`. |
| Git | `gs`, `gaa`, `gcm`, `gco`, `gcb`, `gp`, `gpl`, `gl`, plus `gwip` (stage + checkpoint) and `gprune` (delete merged branches). |
| Docker / Compose | `d`, `dps`, `dprune`, `dc`, `dcu`, `dcd`, `dcl`. |
| Kubernetes | `k`, `kg`, `kd`, `kl`, `kx`, `kns`. |
| Homebrew | `brewup` (`update` + `upgrade --greedy` + `cleanup` + `autoremove`). |
| Python | Auto-inits `pyenv` + `pyenv-virtualenv`; `venv` creates and activates a local `.venv`. |
| Go | Auto-inits `goenv`, adds `$GOPATH/bin` to `PATH`; `gor`, `gob`, `got`. |
| Terraform / OpenTofu / Helm | `tf*`, `to*`, `h*` shortcuts. |
| Script shortcuts | `stay-fresh`, `install-apps`, `install-devtools` when the scripts are present next to this file. |
| macOS helpers | `flushdns`, `purgemem`, `showfiles`/`hidefiles`, `lock`, `ejectall`, `localip`, `myip`, `pbj`. |
| Functions | `mkcd`, `extract`, `up N`, `mkbackup`, `weather [city]`. |

The `_ZSH_ALIASES_DIR` variable resolves the directory of this file, so
the script shortcuts keep working regardless of where the repository is
cloned. The file is designed to be read top to bottom — comment out
anything you do not want, or append your own additions at the end.

---

## Development: Docker checks

These scripts target macOS, but a **small Linux container** can still verify
syntax, ShellCheck, `--help`, the documented exit codes, and that
`zsh_aliases.zsh` sources cleanly in `zsh`. You need **Docker** with the
**Compose v2** plugin; nothing else on the host.

From the **repository root**:

```bash
./macos-initial-setup/tests/run.sh
```

Same thing without the wrapper:

```bash
docker compose -f macos-initial-setup/tests/docker-compose.yml run --rm tester
```

The `tester` image (`tests/tester/Dockerfile`) installs `bash`, `shellcheck`,
and `zsh`, mounts the repo read-only at `/repo`, and runs
`tests/test_macos_initial_setup.sh`.

| Check | Notes |
| --- | --- |
| `bash -n` | All `*.sh` in this directory. |
| ShellCheck | `--severity=error` for the bash scripts. Debian’s stock ShellCheck may not ship a `zsh` dialect — the harness then **skips** `zsh` ShellCheck but still **sources** `zsh_aliases.zsh` in `zsh`. |
| CLI | `--help` succeeds for `install_*.sh`, `stay_fresh.sh`, and `v1_stay_fresh.sh`; an unknown `install_apps.sh` flag returns exit **3** (before preflight). |
| Platform guard | On Linux, `install_apps.sh`, `install_devtools.sh`, and `stay_fresh.sh` exit **2** with a “macOS only” message even with `--dry-run` — preflight always runs first. |
| `zsh_aliases.zsh` | `zsh -f -c "source …"` must not error. |

This is **not** a substitute for `--dry-run` on a real Mac: there is no
Homebrew, no installs, and no execution of `stay_fresh` steps. For
RouterOS script integration tests in the same repository, see
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

### `stay_fresh.sh`

- Deletes cache contents (not the directories themselves) under
  `/Library/Caches`, writable entries of `/System/Library/Caches`,
  `~/Library/Caches`, Logs, Saved State, Xcode DerivedData, and related
  paths.
- Empties `~/.Trash`.
- Clears developer-tool caches (`npm`, `yarn`, `pnpm`, `pip`, `gem`,
  `go`, `cargo`).
- Prunes Docker resources when Docker is available:
  - Containers (`docker container prune -f`)
  - Networks (`docker network prune -f`)
  - Volumes (`docker volume prune -f`)
  - **Dangling images only** (`docker image prune -f`) — keeps tagged images
  - Builder cache (`docker builder prune -af`)
  - Skips pruning entirely when the active Docker context points to a non-local
    daemon (non-`unix://…` host), to avoid cleaning a remote engine by mistake.
- Upgrades Homebrew formulae and casks (greedy upgrade only with
  `--brew-greedy`).
- Updates `mise`, Helm plugins, and `gcloud` components when those
  tools are installed.
- Writes `/tmp/stay_fresh-YYYYMMDD-HHMMSS.log`.
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

The three top-level scripts request `sudo` only for the operations
below. They refuse to run as `root`, prompt once at the start, and
release the credential on exit.

| Script | Uses `sudo` for |
| --- | --- |
| `install_apps.sh` | Cask installs that require admin approval (Homebrew invokes `sudo` internally; the script itself does not escalate). |
| `install_devtools.sh` | Same as above, only via Homebrew where required. |
| `stay_fresh.sh` | `purge`, DNS flush, `/Library/Caches` cleanup, system diagnostic cleanup. Pass `--no-sudo` to skip all of these. |
| `v1_stay_fresh.sh` | `purge`. No way to opt out — use `stay_fresh.sh --no-sudo` instead. |
