# Dotfiles

Configuration for the tools already on a DevOps workstation — the ones
[`macos-initial-setup/install_apps.sh`](../macos-initial-setup/install_apps.sh)
and the Brewfile put there — and a script that links them into a home
directory. Every setting is commented with why it is there, and every section
below says where it was checked, because a dotfile copied from a gist is a
setting nobody can explain a year later.

Two trees. `config/` mirrors `~/.config` (`XDG_CONFIG_HOME`) and `home/`
mirrors `~` itself, for the tools that predate XDG — ssh, gpg, the AWS CLI,
Terraform, npm, Docker.

**Platform:** macOS 12+ and Linux. **Shell:** `bash` for the installer, which
stays Bash 3.2-clean like the macOS package; the configs are read by their
tools, not by a shell.

## Contents

- [Quick start](#quick-start)
- [What is deliberately not here](#what-is-deliberately-not-here)
- [`install_dotfiles.sh`](#install_dotfilessh)
- [Shell and terminal](#shell-and-terminal)
- [Git and GitHub](#git-and-github)
- [SSH and GnuPG](#ssh-and-gnupg)
- [Kubernetes](#kubernetes)
- [Cloud and infrastructure CLIs](#cloud-and-infrastructure-clis)
- [Security scanners](#security-scanners)
- [Package managers](#package-managers)
- [Tools with no config file](#tools-with-no-config-file)
- [Tests](#tests)

## Quick start

```bash
cd dotfiles

./install_dotfiles.sh --list        # every file, where it goes, link or copy
./install_dotfiles.sh --dry-run     # preview; writes nothing
./install_dotfiles.sh               # link everything that is not already there
./install_dotfiles.sh --status      # MATCH / DRIFT / MISSING / CONFLICT per file
```

A file that is already in the way is reported and left alone; `--force` moves
it to `NAME.backup-TIMESTAMP` first. `--only k9s --only git` limits any mode to
the tools named. `--uninstall` removes only the links the script made and the
copies that still match their source.

Three files hold personal or machine-specific values and are **not** shipped;
each config includes them if present and works without them:

| Create | For | Holds |
| --- | --- | --- |
| `~/.config/git/config.local` | git | `user.name`, `user.email`, `user.signingkey`, work `includeIf` blocks |
| `~/.ssh/config.d/*.conf` | ssh | per-host and per-bastion blocks |
| `~/.aws/credentials` or an `sso-session` in `~/.aws/config` | AWS CLI | keys, or the IAM Identity Center start URL |

## What is deliberately not here

- **Anything with a credential in it.** `~/.config/gh/hosts.yml`,
  `~/.aws/credentials`, `~/.config/argocd/config`, `~/.jfrog/`, `~/.chef/credentials`,
  `~/.docker/config.json`'s `auths` block, `~/.kube/config`. Each tool
  reads those from a file this package never touches, and the suite greps
  every tracked config for token shapes on every run.
- **`~/.zshrc`.** The aliases and shell options live in
  [`macos-initial-setup/zsh_aliases.zsh`](../macos-initial-setup/zsh_aliases.zsh)
  and [`linux/bash_aliases.sh`](../linux/bash_aliases.sh), sourced from a
  marked block that their own installers manage. The environment variables
  the configs here rely on are listed under each tool, and once in
  [Environment variables](#environment-variables) to paste.
- **Editor settings for Cursor, Sublime Text, Warp.** They sync through their
  own accounts and their settings files are rewritten on every change.
- **Whole directories.** Linking `~/.config/k9s` would put `clusters/` — the
  per-cluster view state k9s writes on every keystroke — into this repository.
  Each file is linked on its own instead.

## `install_dotfiles.sh`

Links `config/` under `$XDG_CONFIG_HOME` (default `~/.config`) and `home/`
under `~`, one file at a time.

```text
install_dotfiles.sh [--dry-run] [--force] [--only UNIT ...] [--home DIR] [--config-home DIR]
install_dotfiles.sh --status    [--only UNIT ...] [--home DIR] [--config-home DIR]
install_dotfiles.sh --uninstall [--dry-run] [--only UNIT ...] [--home DIR] [--config-home DIR]
install_dotfiles.sh --list
```

| Flag | Effect |
| --- | --- |
| `--dry-run` | Print each `mkdir`, `ln -s`, `cp` or `rm` in the indented `(dry-run)` form and the closing `dry-run complete; no changes written`. Nothing is written, not even a directory. |
| `--status` | One bare `STATE   path` line per file, the shape `windows/git-bash/install_dotfiles.sh` prints: `MATCH` (linked here, or an identical copy), `DRIFT` (a copy that has been edited), `MISSING`, `FOREIGN` (a link into this folder but to the wrong file), `CONFLICT` (an unrelated file, link or directory). Also checks that `~/.ssh` and `~/.gnupg` are mode `700` when a file in them is selected. Exit `4` if anything is not `MATCH`. |
| `--uninstall` | Remove links that point into this folder and copies that still equal their source. A `DRIFT` copy and a `CONFLICT` file are kept and reported. |
| `--list` | Every tracked file with its unit name, `link` or `copy`, and its target. Needs no home directory. |
| `--force` | Move a `CONFLICT`, `FOREIGN` or `DRIFT` file to `NAME.backup-YYYYmmdd-HHMMSS`, then install. The `.backup` is never removed, not even by `--uninstall`. |
| `--only UNIT` | Limit to one unit; repeatable or comma-separated. A unit is a tool directory under `config/` (`k9s`, `git`), a file's stem when it sits at the top (`starship`), or a dotfile under `home/` with its dot dropped (`ssh`, `gnupg`, `aws`, `terraformrc`). An unknown unit exits `3`. |
| `--home DIR` | Use `DIR` as the home directory. `config/` then goes under `DIR/.config` and `XDG_CONFIG_HOME` is ignored, because a caller pointing at another home wants everything under it; without `--home`, `XDG_CONFIG_HOME` is honoured. |
| `--config-home DIR` | Put `config/` under `DIR` instead. |
| `--quiet` | Suppress `[info]` and `[ ok ]` lines; warnings, errors and dry-run previews remain. |

**Link or copy.** Four files are copied rather than linked, because the tool
that owns them rewrites the whole file and would strip every comment out of
the tracked copy the first time it saved: `k9s` writes `config.yaml` on
every exit, `gh config set` rewrites `config.yml`, `aws configure` rewrites
`~/.aws/config`, and `docker login` rewrites `~/.docker/config.json`. Copies
are installed mode `600`. Everything else is a link, so an edit in the
repository is live immediately. `--list` shows which is which, and the suite
checks that the list agrees with the "Installed as a copy" sentences below.

**Private directories.** `~/.ssh` and `~/.gnupg` are set to mode `700` on
every install that selects a file in them, whether or not anything new was
installed, so a directory that drifted to `755` is repaired rather than only
reported: ssh refuses a config in a group-readable directory and gpg warns
on every invocation.

**Not the Git Bash installer.** `windows/git-bash/install_dotfiles.sh` shares
the name and the `.backup-TIMESTAMP` suffix but not the policy: it backs up
and replaces an existing file by default and reserves `--force` for a
line-ending override. This one refuses to touch an existing file unless
`--force` says so, because a config already in `~/.config` is more likely to
be deliberate than a stray `.bashrc` on a fresh Windows machine.

**Exit codes:** `0` success (for `--status`: everything matches); `1` a link
or copy could not be made; `2` preflight — `config/` or `home/` missing next to
the script, or no home directory; `3` usage; `4` something was left in place — a
conflict under install, or a non-`MATCH` under `--status`.

**Git and symlinks.** `git config --global` writes through the link into the
tracked `config/git/config`. That is what you want for a setting you mean to
keep; for `user.name`, `user.email` and a signing key, write to the local
file instead:

```bash
git config --file ~/.config/git/config.local user.name "Your Name"
git config --file ~/.config/git/config.local user.email "you@example.com"
```

[`git/set_git_profile.sh`](../git/set_git_profile.sh) uses `--global`, so
after running it, move the three `user.*` lines it wrote from
`config/git/config` into `config.local` before committing.

## Environment variables

Four of the configs are only found when the shell says where they are. Add
this block to `~/.zshenv` (not `~/.zshrc`: Homebrew must see it from a
GUI-launched terminal too) or to the marked block `install_aliases.sh`
manages on Linux:

```bash
export XDG_CONFIG_HOME="$HOME/.config"                       # homebrew, k9s on macOS
export RIPGREP_CONFIG_PATH="$HOME/.config/ripgrep/config"    # ripgrep reads no default path
export GITLEAKS_CONFIG="$HOME/.config/gitleaks/gitleaks.toml"
alias trivy='trivy --config "$HOME/.config/trivy/trivy.yaml"'  # trivy reads only ./trivy.yaml
```

Everything else — starship, kitty, alacritty, bat, ncdu, thefuck, nvim,
git, gh, grype, syft, pip, ssh, gpg, the AWS CLI, Terraform, npm, Docker —
reads its `~/.config` or `~` path with no help.

## Shell and terminal

### `~/.config/starship.toml`

The prompt is the last line of defence against running a command on the
wrong cluster, so the Kubernetes context is the first thing on it and any
context matching `prod` is red. Checked against `docs/config/README.md` of
starship 1.26.

| Setting | Why |
| --- | --- |
| Explicit `format` instead of `$all` | Order is predictable and modules not listed are never computed. |
| `command_timeout = 1000` | The default 500 ms silently drops `helm` and `terraform` version lookups on a cold cache. |
| `[kubernetes] disabled = false`, no `detect_*` | Off by default; on and always visible, because a hidden production context is worse than a longer prompt. `$namespace` is shown because the namespace is the usual "wrong cluster" mistake. |
| `[[kubernetes.contexts]]` | Regex aliases: `gke_project_zone_cluster` shows as `gke:cluster`, EKS ARNs as `eks:name@region`, and `.*prod.*` in bold red. `context_aliases` is deprecated; this is its replacement. |
| `[git_status]` with `${count}` | Counts instead of symbols, so the state is actionable without `git status`. Submodules are ignored because they are slow. |
| `[cmd_duration]` from 2 s, notification at 45 s | A plan or an upgrade finishing in a background window sends a desktop notification. |
| `[time]` on the right | Off by default; on, because an incident timeline needs it. |
| `[gcloud] detect_env_vars` | Shown only when a `CLOUDSDK_*` variable is set in this shell; otherwise the module is on in every directory. |
| `[aws]` with `$duration` | Profile, region and time left on temporary credentials; `expiration_symbol` when they are gone. |
| `[terraform]` workspace only | `$version` would run `terraform version`, which with many providers is slow; starship leaves it out for the same reason. |
| `pyenv_version_name = false` | A pyenv lookup on every prompt is slow. |

Glyphs assume a Nerd Font: `brew install --cask font-jetbrains-mono-nerd-font`,
which the terminal configs below also name. Without one, replace `󰌾`, `󱁢`,
`󰟓` and `󰎙` with plain text; `starship module kubernetes` tests a context
pattern without opening a new shell.

### `~/.config/alacritty/alacritty.toml`

TOML, as Alacritty has used since 0.13; keys checked against
`extra/man/alacritty.5.scd` of 0.17.

| Setting | Why |
| --- | --- |
| `[env] TERM = "xterm-256color"` | Alacritty's own terminfo is missing on most hosts you ssh into. |
| `[terminal] osc52 = "OnlyCopy"` | nvim and tmux over ssh may write the clipboard, never read it. |
| `option_as_alt = "Both"` | macOS only: Option is Alt, so Alt-b, Alt-f and Alt-. work in zsh and nvim. |
| `history = 100000` | The hard maximum; a long `kubectl logs` stays reachable. |
| `save_to_clipboard = true` | Select is copy, as on Linux. |
| Steady block cursor, `unfocused_hollow` | Easiest to find in a wall of output; hollow marks the inactive window. |
| Cmd-K, Cmd-F bindings | The Terminal.app habits; the default search chord clashes on macOS. |

Colours are not in this file. Import a theme from
[alacritty-theme](https://github.com/alacritty/alacritty-theme) with the
commented `general.import` line so a theme swap never touches the settings.

### `~/.config/kitty/kitty.conf`

Every option and default checked against `kitty/options/definition.py` of
kitty 0.48; the file reloads itself on save.

| Setting | Why |
| --- | --- |
| `scrollback_lines 100000` and a 64 MB pager history | The default 2000 lines is useless for logs or a plan. |
| `copy_on_select clipboard`, `clipboard_control` with `read-*-ask` | Select is copy; a program over ssh may write the clipboard but must ask to read it. |
| `paste_actions ... confirm` | Confirms a paste containing control characters — the "pasted text ran a command" class of bug. |
| `macos_option_as_alt left` | Left Option is Alt for zsh and nvim; right Option still types `€` and `~`. |
| `confirm_os_window_close -1` | With shell integration, asks before closing only when a command is still running — a port-forward, a watch. |
| `notify_on_cmd_finish unfocused 30` | Desktop notification when a command over 30 s finishes in another window. |
| `allow_remote_control socket-only` | `kitten @` works from scripts over the socket; a program on the TTY cannot drive the terminal. |
| `update_check_interval 0` | Homebrew keeps kitty current. |
| `term xterm-kitty` | The default, kept: on a host without the terminfo, use `kitten ssh host`. |

`kitten themes` writes `current-theme.conf`, which the last line includes;
missing is fine.

### `~/.config/bat/config`

One argument per line; `bat --config-file` prints the path, which is
`~/.config/bat/config` on macOS and Linux alike. The syntax names come from
`bat --list-languages`, and each mapping fills a gap bat's bundled syntaxes
leave: only a plain `Dockerfile` and `Jenkinsfile` are detected, only `*.tf`
for Terraform, and kubeconfig, Helm templates and Jinja-templated YAML have
no rule at all. `--theme=auto:system` follows the OS light/dark mode;
`--style` leaves the grid out because grid lines end up in every copy-paste
of YAML; `--paging=auto` with `less -RFX` keeps `bat f | kubectl apply -f -`
working.

### `~/.config/ripgrep/config`

Read only when `RIPGREP_CONFIG_PATH` names it. `--smart-case` gives `rg
configmap` the ConfigMaps and `rg ConfigMap` an exact match; `--hidden`
reaches `.github/workflows`, `.gitlab-ci.yml` and `.terraform.lock.hcl`,
with `.git/`, `node_modules/`, `.terraform/` and the lock files excluded by
name so it still holds outside a repository. `--max-columns=250` with a
preview stops a base64 blob in a Secret from flooding the terminal. The
`--type-add` lines define `terraform`, `helm`, `k8s`, `jenkins`, `gitlab`,
and the composite `iac` and `ci` for `-t` and `-T`; ripgrep ships none of
them. Flags on the command line override anything here.

### `~/.config/ncdu/config`

One option per line, every one in the `ncdu(1)` man page shared by the 1.x
and 2.x branches. `-x` stays on one filesystem, so `ncdu /` no longer walks
network mounts and every disk under `/Volumes`; `--exclude-caches` leaves
`CACHEDIR.TAG` directories out of the totals; `--confirm-quit` and
`--confirm-delete` because this is the tool people run as root; `-e` reads
mtimes so `m` sorts by age. Linux-only and macOS-only options are accepted
and ignored on the other platform.

### `~/.config/thefuck/settings.py`

Keeps `require_confirmation` — the corrected command may be `sudo rm` or a
force push — raises `wait_command` because kubectl and gcloud are slower than
the default 3 s allows, lists the cloud CLIs as slow commands, and excludes
the `rm_root`, `git_push_force` and `sudo` rules. thefuck has had no release
since 2022 and does not import on Python 3.12+; the header comment says how
to run it under 3.11 or swap it for pay-respects.

### `~/.config/nvim/init.lua`

One file, no plugin manager, nothing outside core Neovim 0.10+. The options
are the obvious ones — two-space indent, `smartcase`, persistent undo, no
swap files, system clipboard, live `:%s` preview — plus `exrc = false` so a
cloned repository can never auto-run its `.nvim.lua`, and `grepprg` set to
ripgrep so `:grep` honours the config above. The `vim.filetype.add` block
adds only what Neovim's own `filetype.lua` lacks: Helm templates (`*.tpl`
otherwise maps to smarty), `helmfile.yaml`, `.env.*` variants,
`Jenkinsfile.*`. `Jenkinsfile`, `*.tf`, `*.tfvars`, `*.hcl` and
`Dockerfile.*` are already built in. Neovim ships no syntax for
`terraform-vars` or `helm`, so those borrow `terraform` and `yaml`. Trailing
whitespace is highlighted and stripped on save except in Markdown, diffs and
commit messages, where it means something.

### `~/.config/homebrew/brew.env`

Read only when `XDG_CONFIG_HOME` is exported before `brew` runs. The
format, from `bin/brew`, is `KEY=value` exported verbatim: no quotes, no
`$HOME`, no `$(...)`. Every variable is in `docs/Manpage.md`.

| Setting | Why |
| --- | --- |
| `HOMEBREW_NO_ANALYTICS`, `HOMEBREW_NO_INSECURE_REDIRECT` | No telemetry; refuse an HTTPS-to-HTTP redirect on download. |
| `HOMEBREW_AUTO_UPDATE_SECS=604800` | Auto-update weekly instead of daily, so installs stop stalling on a fetch; `stay_fresh.sh` runs the real `brew update`. |
| `HOMEBREW_CLEANUP_MAX_AGE_DAYS=30` | Cached downloads older than 30 days go; the default 120 lets the cache reach tens of gigabytes. |
| `HOMEBREW_NO_INSTALL_UPGRADE` | `brew install foo` never silently upgrades a foo already there. |
| `HOMEBREW_NO_ENV_HINTS`, `HOMEBREW_DISPLAY_INSTALL_TIMES` | No hint lines; per-formula timings to spot a slow source build. |
| Not set: `HOMEBREW_CASK_OPTS=--require-sha` | Casks pinned to `:latest` ship without a checksum, and several in this repository's Brewfile are, so it would refuse them. |

A GitHub token raises API limits but goes in `~/.zshenv` from the keychain,
never in this file.

## Git and GitHub

### `~/.config/git/config`

Do not create `~/.gitconfig`: git reads it after this file, so it wins on
every key, and once it exists `git config --global` writes there instead of
here. Every key is in `Documentation/config/*.adoc` of git 2.45 or later.

| Setting | Why |
| --- | --- |
| `init.defaultBranch = main` | Every hosting service defaults to `main`. |
| `branch.sort = -committerdate`, `tag.sort = version:refname`, `column.ui = auto` | Newest branch first; `v1.10` after `v1.9`; columns on a terminal. |
| `diff.algorithm = histogram`, `colorMoved = plain`, `mnemonicPrefix` | Hunks a human would draw; a moved block in its own colour; `i/ w/ c/` prefixes. |
| `merge.conflictStyle = zdiff3` | The conflict marker shows the common ancestor too, with shared lines trimmed. |
| `rerere.enabled` and `autoupdate` | A conflict resolved once is replayed on every later rebase of the same hunks. |
| `pull.rebase = true` | No "Merge branch 'main' of origin" commits. |
| `fetch.prune`, `prunetags`, `all` | Deleted upstream branches and tags disappear locally; bare `git fetch` covers every remote (2.44+). |
| `push.autoSetupRemote`, `followTags` | The first push creates the upstream instead of asking for `-u`; annotated tags travel with it. |
| `rebase.autoSquash`, `autoStash`, `updateRefs` | `fixup!` commits fold in; a dirty tree is stashed and restored; stacked branches move with the rebase. |
| `commit.verbose` | The diff is in the editor while the message is written. |
| `core.untrackedCache` | Caches the untracked-file scan. `core.fsmonitor` is macOS and Windows only, so it goes in `config.local` there. |
| `help.autocorrect = prompt` | `git psuh` offers `git push` and waits for a yes. |
| `transfer.fsckObjects`, `credentialsInUrl = die` | Every received object is verified; a remote URL with a password in it is refused. |
| `include.path = config.local` | Identity, signing, credential helper and per-client `includeIf` blocks. Not tracked; missing is fine. The path is relative, so it resolves next to this file wherever the installer puts it. |

The commented block inside `[include]` is the template for `config.local`,
including SSH commit signing (`gpg.format = ssh`, `gpg.ssh.allowedSignersFile`),
`credential.helper = osxkeychain`, and the `url "git@github.com:" insteadOf`
rewrite that sends every HTTPS GitHub URL over SSH. That rewrite is in the
template rather than the tracked file on purpose: it applies to every tool
that shells out to git — `helm plugin install`, krew, `go install`, `pip` —
and on a machine whose SSH key is not yet registered on GitHub each of those
fails with "Permission denied". Add it once the key is.

### `~/.config/git/ignore`

Global excludes for machine, editor and tooling noise only: `.DS_Store`,
IDE directories, swap files, `.env` and `.envrc`, Terraform state and
`.terraform/`, Python caches. Two deliberate absences: `node_modules/`,
because hiding it globally hides a missing project rule and `git status`
stops warning; and `.terraform.lock.hcl`, which belongs in the repository.

### `~/.config/gh/config.yml`

Installed as a copy, because `gh config set` rewrites the file. Tokens are in
`hosts.yml` beside it, which is never tracked. `git_protocol: ssh` matches
the git rewrite above; `telemetry: disabled`; `pager: less -FRX`; and six
aliases — `co` (`pr checkout`), `pv` (`pr view --web`), `prs` (mine), `rv`
(waiting on my review), `ci` (`run watch`), `il` (issues assigned to me).
Keys and values from `internal/config/config.go` in `cli/cli`.

## SSH and GnuPG

### `~/.ssh/config`

The first value set for an option wins, so per-host blocks and the
`Include ~/.ssh/config.d/*` line come before `Host *`. Per-host blocks —
bastions, client environments, one key per organisation — go in
`config.d/`, which is never tracked. Every option is in `ssh_config(5)` of
OpenSSH 8.6 (macOS 12) or later; `UseKeychain` is Apple-only and guarded by
`IgnoreUnknown`.

| Setting | Why |
| --- | --- |
| `AddKeysToAgent yes`, `UseKeychain yes` | The key loads into the agent on first use, its passphrase from the Keychain on macOS. No `ssh-add` after a reboot. |
| `IdentitiesOnly yes` | Offer only the configured key. Stops "Too many authentication failures" and stops a server learning which other keys you carry. |
| `ServerAliveInterval 30`, `CountMax 3` | Keeps a session alive through NAT and VPN idle timeouts, and notices a dead one in under two minutes. |
| `ControlMaster auto`, `ControlPath ~/.ssh/cm-%C`, `ControlPersist 10m` | The second ssh, scp or rsync to a bastion is instant. `%C` hashes the connection so the socket name stays short; the socket lives in `~/.ssh`, so no extra directory is needed. Off for `github.com`, where git opens many short connections. |
| `HashKnownHosts yes` | A leaked `known_hosts` does not list every machine you have reached. |
| `StrictHostKeyChecking ask`, `UpdateHostKeys yes` | Ask about a new key, refuse a changed one, accept rotations announced over the authenticated connection. |
| `ForwardAgent no` | Per-host opt-in only. A forwarded agent lets root on that host sign as you. |
| `KexAlgorithms -...`, `Ciphers -...`, `MACs -...` | The `-` form trims the defaults rather than replacing them, so the list is right on every OpenSSH version. Gone: SHA-1 anywhere, non-ETM MACs, CBC ciphers, the NIST curves. A legacy appliance gets its own Host block. |

### `~/.gnupg/gpg.conf`

Based on `drduh/config`, each line checked against `doc/gpg.texi` of GnuPG
2.4. Algorithm preferences strongest first; SHA-512 for certification and
passphrase mangling, where the compiled-in default is still SHA-1;
`keyid-format 0xlong` because short IDs are trivially collidable;
`no-emit-version` and `no-comments` so armored output does not announce its
software; `require-cross-certification`; `no-symkey-cache`. The keyserver
is not here: gpg 2.x ignores it in this file with a warning.

### `~/.gnupg/gpg-agent.conf`

`default-cache-ttl 300` and `max-cache-ttl 1800`: the defaults keep a
passphrase for ten minutes after each use and two hours overall, which on a
laptop is long enough to walk away from. `pinentry-program` is deliberately
unset because the compiled-in default is the pinentry next to the gpg
binary, which for the Homebrew formula is the `pinentry` formula the
Brewfile installs; the comment shows the `pinentry-mac` line for a native
dialog. `enable-ssh-support` is unset because it conflicts with the macOS
ssh-agent and only pays off with keys on a smart card. Reload with
`gpgconf --kill gpg-agent`.

### `~/.gnupg/dirmngr.conf`

`keyserver hkps://keys.openpgp.org`. This is the only place a keyserver
belongs in GnuPG 2.x, and since 2.5.3 there is no default at all, so without
the line `gpg --recv-keys` has nowhere to go. keys.openpgp.org verifies
e-mail addresses before publishing, which is what ended the flood of fake
keys on the SKS pool.

The installer creates `~/.gnupg` and `~/.ssh` mode `700`; `--status`
reports when they are not.

## Kubernetes

### `~/.config/k9s/config.yaml`

Installed as a copy: k9s rewrites this file on every exit and would strip
the comments from a linked one. `--status` reports `DRIFT` once it has;
fold anything worth keeping back into the repository. On macOS k9s reads
`~/Library/Application Support/k9s` unless `XDG_CONFIG_HOME` is exported,
which is the first line of the environment block above; `k9s info` prints
the paths it resolved. Every key is validated against
`internal/config/json/schemas/k9s.json` upstream by the suite.

| Setting | Why |
| --- | --- |
| `liveViewAutoRefresh: false`, `refreshRate: 2` | Refresh on events and keypresses; periodic redraw adds API load on every open cluster. |
| `apiServerTimeout: 15s`, `maxConnRetry: 5` | The default is two minutes of frozen UI on a flaky VPN before k9s admits the API server is gone. |
| `noExitOnCtrlC: true` | Ctrl-C cancels a filter; it should not also close every open view. `:quit` works. |
| `skipLatestRevCheck: true` | No release check against GitHub from a tool holding cluster credentials. |
| `readOnly: false` here, `true` per context | Production contexts get `readOnly: true` in their own file at `~/.local/share/k9s/clusters/<cluster>/<context>/config.yaml`, so the block is where it matters. |
| `ui.logoless`, `splashless`, `reactive` | Six rows back; skins, plugins and aliases reload from disk on edit. |
| `imageScans.enable: false` | Pulls the Trivy database and scans every image in view; that is a job for CI. |
| `logger.tail: 200`, `showTime: true` | Enough history to see what came before the crash; timestamps for the incident timeline. |
| `shellPod.image: nicolaka/netshoot` | For the `nodeShell` feature gate, which stays off: netshoot carries tcpdump, dig and curl where busybox carries almost nothing. |

No skin is set. Drop one from
[the upstream `skins/` directory](https://github.com/derailed/k9s/tree/master/skins)
into `~/.config/k9s/skins/` and name it in `ui.skin`, or per context in the
file above.

### `~/.config/k9s/aliases.yaml`

Short names typed after `:` for the resources k9s does not abbreviate: the
RBAC kinds, `pdb`, `hpa`, `np`, Argo CD `app` and `appset`, Flux `hr` and
`ks`, cert-manager `cert`, and `dns`, which expands to the pod view in
`kube-system` filtered by `k8s-app=kube-dns` — the k9s 0.30+ form of an
alias as a full command.

### `~/.config/k9s/hotkeys.yaml`

`Shift-0` to `Shift-4` jump to pods, deployments, events, nodes and the
deployment xray from any view; `keepHistory: true` makes Esc return to where
you were.

### `~/.config/k9s/plugins.yaml`

Adapted from the upstream `plugins/` directory, each passing `--context
$CONTEXT` so a plugin can never act on a cluster other than the one on
screen. `Ctrl-Y` tails every pod matching the current filter with stern;
`Shift-D` attaches a debug container with an image and profile chosen from
a dropdown, marked `dangerous` and `confirm`; `Ctrl-X` decodes a Secret
with jq; `Shift-E` watches events for the selected object; `b` runs
`kubectl blame`; `g` on a namespace runs `kubectl get-all`. Each names the
tool it needs; a missing one fails on the key press and nothing else.

### `~/.kube/kuberc`

kubectl's own preferences file, beta since Kubernetes 1.34 and ignored by
older versions. It is the one file under `~/.kube` safe to track:
`~/.kube/config` holds credentials and stays out. Three aliases — `getj`
and `gety` for JSON and YAML output, `rmi` for a delete that asks first —
and nothing that changes what a plain command does, because defaults here
apply to scripts too.

The krew plugins the aliases and plugins above lean on:

```bash
kubectl krew install ctx ns neat tree view-secret who-can access-matrix \
  images resource-capacity stern get-all blame deprecations
```

## Cloud and infrastructure CLIs

### `~/.terraformrc`

Checked against the config-file page of the Terraform CLI docs. Nothing in
it is a credential: `terraform login` writes tokens to
`~/.terraform.d/credentials.tfrc.json`, which stays out of the repository.

| Setting | Why |
| --- | --- |
| `plugin_cache_dir` | One download of each provider shared by every working directory; the provider set for a GKE project is hundreds of megabytes per `init` without it. Terraform does not create the directory: `mkdir -p ~/.terraform.d/plugin-cache` once. |
| `disable_checkpoint = true` | No version and security-bulletin call to HashiCorp on every run; tfenv and Homebrew keep the binary current. |
| Not set: `plugin_cache_may_break_dependency_lock_file` | It lets `init` record only the local platform's hash in the lock file, and the next `init` on a Linux runner fails. Commit the lock file instead. |
| Commented `provider_installation` | The shape for a private mirror, when one exists. |

For CI, `TF_INPUT=0` and `TF_IN_AUTOMATION=1` in the pipeline environment;
for tfenv on Apple Silicon, `TFENV_ARCH=arm64`.

### `~/.aws/config`

Installed as a copy because `aws configure` rewrites it. Settings only, no
account IDs and no keys; `~/.aws/credentials` is never tracked, and an IAM
Identity Center session needs neither. Checked against
`awscli/topics/config-vars.rst`.

| Setting | Why |
| --- | --- |
| `cli_pager =` | Empty turns the v2 pager off. It is what stops `aws ... \| jq` and every CI job from hanging on `less`. |
| `output = json` | What scripts and jq expect; `--output table` for a human read. |
| `cli_auto_prompt = on-partial` | Completions only when a command is incomplete, so a full command still runs unattended. |
| `retry_mode = standard`, `max_attempts = 5` | The SDK-wide retry rules with a quota; five attempts ride out a throttling burst. The CLI default is still `legacy`. |

The commented blocks show the `[sso-session]` plus `[profile]` pair for
Identity Center and a `credential_process` profile for aws-vault or
1Password, so nothing static sits in `~/.aws/credentials` at all.

### `~/.docker/config.json`

Installed as a copy because every `docker login` rewrites it. It holds
only the keys that are safe to publish, from `cli/config/configfile/file.go`:
`credsStore: osxkeychain` so `docker login` secrets go to the Keychain and
the `auths` block stays empty; `detachKeys` moved off `Ctrl-p`, which is
shell history; `cliPluginsExtraDirs` pointing at where Homebrew installs
`docker-buildx` and `docker-compose`; a `psFormat` that fits a terminal; and
an `ll` alias. No `currentContext`: the CLI fails every command when the
named context does not exist, and OrbStack sets its own context on first
launch. On Linux change `credsStore` to `pass` or `secretservice`, because
the CLI fails `docker login` and private pulls when the named helper is not
on `PATH`. Docker's own docs say never to commit this file once it carries
`auths` or authenticated `proxies`; the copy in the home directory may, and
the tracked one never does.

## Security scanners

### `~/.config/trivy/trivy.yaml`

Trivy reads `./trivy.yaml` from the working directory and nothing else on
its own, hence the alias in the environment block; a project's own
`trivy.yaml` wins for that project. Nesting checked against the
config-file reference of Trivy 0.74. `severity` from `MEDIUM` up, because
the default list includes `UNKNOWN` and `LOW` and on a base image that is
hundreds of lines nobody reads; `exit-code: 1` so the same command is a
pre-push hook and a CI gate; `scan.scanners` adds `misconfig` for the
Kubernetes, Terraform and Dockerfile checks; `vulnerability.ignore-unfixed`
because an unfixable CVE is a fact about the base image, not a task;
`scan.disable-telemetry` and `skip-version-check`; `timeout: 10m` because the
first run downloads the database.

### `~/.config/grype/config.yaml`

Read after `./.grype.yaml` and `~/.grype.yaml`, keys from
`cmd/grype/cli/options/*.go`; `grype config` prints the effective result.
`fail-on-severity: high` exits 2 so the same command gates a pipeline;
`check-for-app-update: false`; `add-cpes-if-none` so third-party SBOMs
match; `db.validate-age` with a five-day ceiling, because scanning with a
stale database silently misses the last week's CVEs;
`require-update-check: false` so offline still scans with what it has.

### `~/.config/syft/config.yaml`

Same loader as grype, keys from `cmd/syft/internal/options/*.go`. Network
enrichment stays off (`enrich: []`) so an SBOM is reproducible from the
artefact alone; `node_modules` and `.git` are excluded;
`guess-unpinned-requirements: false` so a version is never invented for an
unpinned `requirements.txt` line.

### `~/.config/gitleaks/gitleaks.toml`

Reached through `GITLEAKS_CONFIG`; a repository's own `.gitleaks.toml`
takes precedence. Extends the built-in rules with `useDefault = true` and
disables none. Two allowlists: lock files and binary assets, which never
hold a rotatable secret and are what trips the generic entropy rule; and
obvious placeholders such as `changeme` and `REDACTED`. Checked against the
README and `config/gitleaks.toml` of gitleaks 8.30. Run it on every commit
through `git_hooks_install.sh` in the git package, or with pre-commit.

## Package managers

### `~/.npmrc`

Settings only; a registry token belongs in a file named by
`NPM_CONFIG_USERCONFIG` that is never tracked. `save-exact=true` writes
`1.2.3` instead of `^1.2.3`, so the manifest says what the lock file says;
`engine-strict=true` refuses a package whose `engines` rejects the current
Node; `audit-level=high`; `fund=false` and `update-notifier=false`. Keys from
`workspaces/config/lib/definitions/definitions.js` in `npm/cli`.

### `~/.config/pip/pip.conf`

`require-virtualenv = true` refuses to install into the system or
pyenv-global interpreter, so the environment that breaks is always one you
can delete (`PIP_REQUIRE_VIRTUALENV=false` overrides it once);
`disable-pip-version-check`; `timeout = 60`. On macOS pip looks in
`~/Library/Application Support/pip` first and falls back here only if that
directory does not exist, so never create it; `pip config debug` shows
which file won.

pnpm and Maven are deliberately not here. pnpm 11+ reads its settings from
`~/Library/Preferences/pnpm/config.yaml` on macOS, a path this layout does
not cover; Maven's `settings.xml` is mostly a mirror URL and encrypted
server credentials, both machine-specific.

## Tools with no config file

Checked so nobody goes looking: `yq`, `hyperfine`, `nmap` (`~/.nmap` is for
data files, not settings) and the `iperf3` client read no configuration
file. `jq` sources `~/.jq` as a module file if it exists. `jfrog-cli` keeps
server URLs and tokens in `~/.jfrog/jfrog-cli.conf.v6` and `argocd` in
`~/.config/argocd/config`; both are credential files and stay out. Helm is
driven by `HELM_*` environment variables and its `repositories.yaml` is
written by `helm repo add`. gcloud keeps credentials and settings together
under `~/.config/gcloud`, so its properties are set with `gcloud config
set` — `core/disable_usage_reporting true`,
`component_manager/disable_update_check true`, `survey/disable_prompts true`
— rather than tracked.

## Tests

`tests/run.sh` needs nothing but bash and git, so it runs everywhere the
static suite does; CI runs it as `Test / dotfiles`.

```bash
./dotfiles/tests/run.sh      # or: ./run-tests.sh dotfiles
```

The first half runs `install_dotfiles.sh` against a scratch home and asserts
what it promises: `--help` before preflight, exit `3` on a bad flag, a dry
run that leaves the home byte-identical, every tracked file installed as a
link into this folder or as a matching copy, `~/.ssh` and `~/.gnupg` mode
`700`, a second install that changes nothing, a foreign file left in place
with exit `4`, `--force` keeping a `.backup`, `--status` telling `MATCH`
from `DRIFT` and reporting a directory at a copy target as `CONFLICT`, a
drifted `~/.ssh` mode repaired by install, and an uninstall that removes
every link and matching copy, keeps the edited copy and the `.backup`. The
file table is read from `--list` rather than re-derived, and the run is
isolated from any `XDG_CONFIG_HOME` the shell exports.

The second half reads the tracked configs themselves: none is executable or
starts with a shebang; every TOML, YAML, JSON, Lua and Python file parses,
and the git, ssh, gpg, gpg-agent and dirmngr configs are accepted by their
own tools; every file has a heading in this README naming its installed
path; the files `--list` reports as copies are exactly the ones this README
says are installed as a copy; and nothing matches the common token shapes —
AWS keys, GitHub and GitLab tokens, Slack tokens, private key headers.
Parsers that are missing on the host are skipped with a note rather than
failed, so a verdict on the installer never depends on having Python or gpg
installed.
