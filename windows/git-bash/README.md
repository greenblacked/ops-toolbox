# Windows Git Bash dotfiles

[Ops Toolbox](../../README.md) / **Windows Git Bash dotfiles**

A `.bashrc` / `.bash_profile` / `.aliases` set for Git Bash (MSYS2) on
Windows, built up from a minimal SSH-agent-loading snippet into a fuller set
of interactive-shell defaults. Safe to source more than once and safe to
drop into an existing `$HOME` — nothing here overwrites machine-specific
config, and secrets/local tweaks stay out of the committed files.

## Contents

- [What's here](#whats-here)
- [Install](#install)
- [`gitbash_doctor.sh`](#gitbash_doctorsh)
- [Applying changes after editing](#applying-changes-after-editing)
- [What's in `.aliases`](#whats-in-aliases)
- [Key differences from a minimal SSH-agent-only `.bashrc`](#key-differences-from-a-minimal-ssh-agent-only-bashrc)
- [Troubleshooting](#troubleshooting)
- [Customizing without forking this file](#customizing-without-forking-this-file)
- [Requirements](#requirements)
- [Not covered here](#not-covered-here)

## What's here

| File | Purpose |
| --- | --- |
| `.bashrc` | Default working directory, history, prompt (with Git branch), PATH dedup, persistent `ssh-agent` with fingerprint-checked key loading, editor/pager defaults. Sources `.aliases` near the end. |
| `.bash_profile` | Sources `.bashrc`. Required because Git Bash opens new windows as **login** shells, which read `.bash_profile`/`.profile`, not `.bashrc`, by default. |
| `.aliases` | ~190 aliases and functions: Git, GitLab CLI (`glab`), Docker, Kubernetes, Terraform, Windows-style commands, navigation, safer file ops. Kept separate so it can be edited or swapped out without touching shell/environment setup in `.bashrc`. |
| `install_dotfiles.sh` | Copies the three files above into `$HOME`, backing up what was there and refusing to install anything with CRLF line endings. Lists, restores and prunes those backups. |
| `gitbash_doctor.sh` | Read-only check of the Git Bash environment around those files: CRLF or broken dotfiles, a stale `ssh-agent`, the wrong `ssh` on `PATH`, a OneDrive or spaced `HOME`, long paths, missing Git settings, the Store `python` stub. |

## Install

Git Bash's `$HOME` is usually `C:\Users\<you>` (check with `echo $HOME` inside
Git Bash — it can differ from the Windows profile folder if `HOME` is set in
the environment).

```bash
# From a Git Bash window, in a checkout of this repository:
./windows/git-bash/install_dotfiles.sh --dry-run
./windows/git-bash/install_dotfiles.sh --status
./windows/git-bash/install_dotfiles.sh --diff
./windows/git-bash/install_dotfiles.sh
```

Or copy them by hand, which is all the script does when nothing is in the way:

```bash
cp windows/git-bash/.bashrc windows/git-bash/.bash_profile windows/git-bash/.aliases "$HOME/"
```

If you already have a `~/.bashrc`, `~/.bash_profile`, or `~/.aliases`, diff
first and merge by hand instead of overwriting — in particular, keep
anything you have under a "local overrides" section, or move it into
`~/.bashrc.local` (see below). `install_dotfiles.sh --diff` is that diff: a
`-` line is something of yours the install would remove, a `+` line what it
would add. It prints to the terminal only, and your files can hold tokens,
which is one more reason they belong in `~/.bashrc.local`. The script keeps a timestamped backup of
anything it replaces, but a backup is not a merge.

Then open a new Git Bash window (or `source ~/.bash_profile` in the current
one) to pick up the changes.

### `install_dotfiles.sh`

The plain `cp` above has two failure modes that are only obvious after they
have bitten you: it overwrites an existing `~/.bashrc` with nothing kept, and
it will happily install a file with CRLF line endings — the corruption the
troubleshooting section below exists for. The script is the same copy with
those two checks in front of it.

| Option | Effect |
| --- | --- |
| `--dry-run` | Print what would be copied and backed up; write nothing |
| `--status` | Print `MATCH`, `DRIFT`, or `MISSING` per target; exit `4` on drift |
| `--diff` | The same report plus a unified diff (`installed:` against `repo:`) for each drifted target; writes nothing; exit `4` on drift |
| `--force` | Install even when a source file has CRLF line endings |
| `--source DIR` | Copy from `DIR` instead of the folder holding the script |
| `--home DIR` | Copy into `DIR` instead of `$HOME` |
| `--list-backups` | List the backup sets in the target directory, newest first; write nothing; exit `4` when there are none |
| `--restore STAMP` | Put back one backup set (a stamp from `--list-backups`, or `latest`), saving the files it replaces as a new set first; `--dry-run` previews it |
| `--prune-backups N` | Delete every backup set but the newest `N`; only previews unless `--yes` is given |
| `--yes` | Confirm the deletion `--prune-backups` previews |
| `-h`, `--help` | Show the help |

- **Backups are timestamped and share one stamp per run**, so a set taken
  together is obvious from the names: `.bashrc.backup-20250131-142530`.
- **A file that already matches the source is left alone.** Re-running is a
  no-op, not three new copies of identical files.
- **CRLF is refused, not fixed.** The script prints the `sed` command that
  fixes each offending file and exits `1`; `--force` installs them as they are.
  It refuses rather than converting because the file it would be rewriting is
  one you are about to live in, and silently editing your input is a worse
  habit than stopping.
- **CRLF in the file being replaced is reported, not refused.** That one is
  about to be overwritten by the LF copy anyway, so it only earns a warning —
  but it is usually the answer to "why has this shell been throwing a syntax
  error at me", and the backup preserves it exactly as it was.
- **`--source` is for the copied-alone case.** Dropped into `~/bin` on its own,
  the script has no dotfiles next to it; point `--source` at a checkout.

#### Rolling back

Every install leaves `<name>.backup-<stamp>` files in `$HOME`, and a bad
`.bashrc` is easiest to undo from a shell that still works, so the way back is
one command rather than three `cp` lines typed into a broken prompt:

```bash
./windows/git-bash/install_dotfiles.sh --list-backups
./windows/git-bash/install_dotfiles.sh --restore latest --dry-run
./windows/git-bash/install_dotfiles.sh --restore 20250131-142530
./windows/git-bash/install_dotfiles.sh --prune-backups 3 --yes
```

`--list-backups` prints one line per set, such as
`20250131-142530  .bashrc .aliases`, naming the files that set holds.
`--restore` first saves each file it is about to replace as a new backup set,
so a rollback can itself be rolled back (`--restore latest` again), leaves a
file that already matches alone, skips a destination that is a directory and
exits `1` after the rest of the set is back, and puts a backed-up symlink
back as a symlink rather than writing through it. `--prune-backups N`
keeps the newest `N` sets and deletes the rest, and only with `--yes`;
without it, or with `--dry-run`, it prints the `rm` it would run. Only
files named exactly
`<.bashrc|.bash_profile|.aliases>.backup-<YYYYmmdd-HHMMSS>` directly in the
target directory are ever listed, restored or deleted; something like
`.bashrc.backup-notes` is left alone. None of the three needs the source
files, so they work from a copy of the script with no checkout beside it.
They are separate modes: combining two, or `--status` with one, exits `3`.

Exit codes: `0` success/current, `1` CRLF line endings in a source file, or
a `--restore` that skipped a file because its destination is a directory
(the rest of the set is still restored), `2` wrong environment (no source
files, no target directory, or no `diff` on `PATH` for `--diff`), `3`
usage, `4` `--status` or `--diff` found at least one missing or different
target, or there are no backups to list or restore.

## `gitbash_doctor.sh`

Git Bash goes wrong in a few quiet, repeatable ways, and each one costs an hour
the first time: a dotfile saved with CRLF, an `agent.env` left pointing at an
agent that died with the last reboot, Windows' own OpenSSH ahead of Git's so
`ssh` cannot see the agent's keys, a `HOME` under OneDrive. `--status` above
only says whether the dotfiles match. This looks at the machine around them,
prints the command that fixes each finding, and changes nothing.

```bash
./windows/git-bash/gitbash_doctor.sh
./windows/git-bash/gitbash_doctor.sh --source ./windows/git-bash --fail-on warn
```

| Option | Effect |
| --- | --- |
| `--home DIR` | Inspect `DIR` instead of `$HOME` |
| `--source DIR` | Also compare the dotfiles with a checkout of this folder; a difference is a warning. Off by default: the script does not guess where the checkout is |
| `--ssh-key FILE` | The private key to check (default `~/.ssh/id_ed25519`, the one `.bashrc` loads) |
| `--fail-on warn\|fail` | Exit `1` on failures only (default) or on warnings too |
| `--quiet` | Print only warnings and failures |
| `-h`, `--help` | Show the help |

| Section | Checks |
| --- | --- |
| dotfiles | `.bashrc`, `.bash_profile`, `.aliases` present (fail), free of CR (fail, with the `sed` that fixes it) and parsing with `bash -n` (fail); `~/.bashrc.local` parses (fail), since `.bashrc` sources it on every start; with `--source`, a managed file the checkout lacks (fail, so an incomplete source cannot pass) and drift from the checkout (warn) |
| home | The Windows form of `HOME` from `cygpath -w`: a space or a non-ASCII character (warn), a OneDrive folder (warn: slow Git and SSH, and `~/.ssh` may be replicated) |
| ssh | `~/.ssh/agent.env` naming a process that is not running (warn; the next `.bashrc` start replaces it); `ssh-add -l` read the way `.bashrc` reads it, `2` meaning no agent (warn); the key and its `.pub` present (warn); a key that `ssh-keygen -y` opens with an empty passphrase (warn); a key `ssh-keygen -y` cannot open for any other reason than a passphrase, such as a malformed or unreadable file (fail; a key counts as protected only when `ssh-keygen` reports an incorrect passphrase or the file itself is marked encrypted); `ssh` resolving to `System32\OpenSSH` (warn: Windows' client cannot see this agent) |
| git | From `~/.gitconfig`: `core.longpaths` not `true` (warn), no `credential.helper` (warn), `safe.directory = *` (warn: it disables the ownership check), `user.name` or `user.email` unset (warn), `core.autocrlf = true` (info). The system Git config is consulted only for `core.longpaths` and `credential.helper`, which Git for Windows' installer can put there. Then `LongPathsEnabled` in the registry through `reg.exe query` (warn when it is not `1`) |
| path | Duplicate `PATH` entries (warn; `.bashrc`'s `dedup_path` should leave none), entries that are not a directory (info), `python` or `python3` resolving to a `WindowsApps` alias stub (warn) |
| tools | Whether `docker`, `kubectl`, `terraform` and `glab` are installed (info). `.aliases` defines each block only when its tool is there, so this explains a missing alias |

A probe whose tool is missing (`cygpath`, `reg.exe`, `ssh-keygen` off Windows)
is reported as `skip`, so the script also runs on Linux. It reads files and
runs `bash -n`, `cmp`, `kill -0`, `ssh-add -l`, `ssh-keygen -y`,
`git config --get`, `reg.exe query`, `cygpath` and `command -v`; it writes
nothing, starts or kills no agent, and never prints key material. There is no
`--dry-run` because there is nothing to preview.

Exit codes: `0` no finding at or above `--fail-on`, `1` one or more, `2` wrong
environment (`--home` or `--source` is not a directory), `3` usage.

## Applying changes after editing

Whenever you edit `~/.bashrc` (pulling an update from this repo, or your own
tweaks) you need to reload it in every **already-open** Git Bash window —
editing the file does nothing to a shell that already has it loaded. New
windows always pick up the latest file automatically, since they source it
fresh from `.bash_profile`.

In a window you want to update in place, either:

```bash
source ~/.bashrc
```

or, once this file's aliases are loaded, just:

```bash
src
```

(`src` is defined in `.bashrc` itself as a shortcut for the command above.)

If you instead edited `~/.bash_profile` — rare, since it only sources
`.bashrc` — `source ~/.bash_profile` also works and re-sources `.bashrc` as
part of it.

## What's in `.aliases`

Too many aliases to enumerate here — open the file directly, it's organized
under `# ---` section headers. By category:

- **Windows-style commands** — `e`/`open` (Explorer here), `codehere` (VS
  Code here), `notepad`, `pwdw` (Windows-style path), `copypwd`.
- **Navigation** — `..`/`.../..../.....`, `home`, `coding`/`sshdir` (reuse
  `$CODING_DIR` from `.bashrc`, see below), `mkcd`, `croot` (cd to repo
  root).
- **Listing/search** — `ls`/`ll`/`la`/`l`/`lt`/`lsize`, `grep`/`egrep`/`fgrep`,
  `ff` (find by filename), `ftext` (grep recursively, skipping `.git`/
  `node_modules`).
- **Shell config** — `clear`/`cls`/`cl`/`c` (also drop scrollback, see
  below), `src`/`reload`, `editaliases`/`editbashrc`/`editprofile`/`editssh`
  (open in Notepad), `path` (print `$PATH` one entry per line).
- **Git** — ~70 aliases (`gs`, `ga`/`gaa`, `gc`/`gcm`, `gd`, `gco`/`gcob`,
  `gsw*`, `gr*` (rebase), `gstash*`, `glog*`, ...) plus functions `gbranch`,
  `gnew`, `gpublish`, `gchanged`, `gupdatemain`, `gacp` (stage all, commit
  with a `[branch]` prefix, push — **not** the same thing as
  [`../../git/gacp.sh`](../../git/gacp.sh): that script supports `--dry-run`/
  `--no-push` and doesn't prefix the message; this is the quick interactive
  shortcut), and `glopen [remote]` (opens the current repo's remote —
  GitLab, GitHub, anything — in your browser, converting an SSH remote to
  `https://` first; works without `glab` installed).
- **GitLab CLI (`glab`)** — `glmr*`, `gli*` (issues), `glpipe*`/`glci*`,
  `glrelease*`, `glvar*`, `glapi`, and functions `glmrcreate`/`glmrdraft`/
  `glpipeline`/`glrun` (all branch-aware: they read the current branch so
  you don't type it). This whole block is only defined **if `glab` is
  installed**, so none of it dangles as broken aliases otherwise.
- **Docker / Kubernetes / Terraform** — `d*`/`dc*`, `k`/`kg*`/`kd*`, `tf*`;
  `kns` prints the current Kubernetes namespace and `kns NAME` changes it for
  the current context.
- **Where am I pointed?** — `ctx` prints one line per tool that is
  configured: the Kubernetes context and namespace, the AWS profile and
  region (with no `AWS_PROFILE` or exported keys, the `[default]` profile
  of `~/.aws/config` or `~/.aws/credentials`, honouring `AWS_CONFIG_FILE`
  and `AWS_SHARED_CREDENTIALS_FILE`, with the region from its `region` key;
  with `AWS_PROFILE` set and no `AWS_REGION`, the region of its
  `[profile NAME]` section), the gcloud project (`CLOUDSDK_CORE_PROJECT`,
  else the project of the configuration `CLOUDSDK_ACTIVE_CONFIG_NAME` or
  `active_config` names, read from `CLOUDSDK_CONFIG` or
  `%APPDATA%\gcloud`), the Terraform workspace (`TF_WORKSPACE`, else
  `environment` in `TF_DATA_DIR` or `.terraform` of the current directory,
  `default` when that directory has no such file), the Docker context
  (`DOCKER_CONTEXT`, else `DOCKER_HOST`, else the saved context in
  `DOCKER_CONFIG` or `~/.docker`), and the Git branch with its origin host.
  Run it before `tfaa`, `tfda` or `kdelete`, which act on whatever these
  point at. A value that looks like production (`prod`, `production` or
  `prd`, any case) ends in `!`, in red on a terminal; the `!` stays when
  colour is off (`NO_COLOR`, `ctx --plain`, or output piped to a log). It
  prints names only: exported AWS keys show as the word `static-keys`,
  never their value.
- **SSH** — `sshkeys`, `sshadd`/`sshremove` (reuse `$SSH_KEY` from
  `.bashrc`), `sshtestgithub`/`sshtestgitlab`.
- **Windows networking** — `ipconfig`, `flushdns`, `ports`, `listening`,
  `tasks`.
- **Safer file ops** — `rm`/`cp`/`mv` aliased to their `-i` (confirm-before-
  overwrite/delete) forms.

`$SSH_KEY` and `$CODING_DIR` are set in `.bashrc` but deliberately **not**
`unset` afterward (everything else internal to the ssh-agent/PATH setup is),
specifically so `.aliases` can reuse them instead of hardcoding the same
path twice.

## Key differences from a minimal SSH-agent-only `.bashrc`

A common Git Bash snippet just checks "is an agent visible in *this* shell"
and starts a new one if not:

```bash
if ! ssh-add -l >/dev/null 2>&1; then
    eval "$(ssh-agent -s)" >/dev/null
fi
```

That check fails in every new terminal, because `ssh-agent -s` output is only
`eval`'d into the current shell — it's never written anywhere another window
can find it. The result is one orphaned `ssh-agent.exe` process left running
per Git Bash window ever opened, none of them reachable from anywhere except
the shell that spawned them.

This version persists the agent's `SSH_AUTH_SOCK`/`SSH_AGENT_PID` to
`~/.ssh/agent.env` and has every new shell source that file first, so all
Git Bash windows share one agent and one set of loaded keys. It also
distinguishes "no agent running" (`ssh-add -l` exit status `2`, spawn a new
agent) from "agent running, no keys loaded yet" (exit status `1`, just load
the key) — the original snippet treated both the same way and could spawn a
redundant agent even when a perfectly good one was already reachable but
simply empty.

## Troubleshooting

**``bash: command substitution: line N: syntax error near unexpected token `)'`` /
`` `__git_branch)' ``, thrown on every prompt redraw.**

Two distinct causes have hit this exact error while developing this file —
worth knowing both if you see it again after editing `PS1` or `__git_branch`:

1. **CRLF line endings.** If `~/.bashrc` was ever saved by a Windows editor
   with CRLF endings (check with `file ~/.bashrc` — it'll say
   `with CRLF line terminators`), a stray `\r` silently breaks any
   backslash-newline line continuation (`cmd \`  followed by a new line):
   the backslash escapes the `\r`, not the newline, so the continuation
   fails. Fix: `sed -i 's/\r$//' ~/.bashrc ~/.bash_profile`, then open a new
   window. `.gitattributes` in the repo root now forces LF on these two
   files on checkout regardless of your `core.autocrlf` setting, so pulling
   from this repo shouldn't reintroduce it — but a save from an editor
   configured for CRLF still can, and so can a copy made through an IDE or a
   chat client. `install_dotfiles.sh` refuses to install a file in that state,
   which is the one part of this the plain `cp` cannot do for you.
2. **A `$(...)` followed later by the `\n` prompt escape.** Independent of
   the above, this Git Bash's bash has a prompt-decoding bug: if `PS1`
   contains a `$(command substitution)` and, anywhere after it in the same
   string, the literal two-character `\n` escape (not an actual newline —
   the escape sequence bash expands into one while rendering the prompt),
   every prompt redraw throws this exact error and the substitution's
   output is dropped. `.bashrc`'s `PS1` works around it by embedding a real
   newline character in the quoted string instead of writing `\n` — see the
   comment directly above the `PS1=` line. If you restructure the prompt,
   keep any `\n` *before* the last `$(...)` in the string, or use a literal
   embedded newline instead of typing `\n`.

If you hit this after copying the file some way other than the plain `cp`
above (through an IDE, clipboard, chat client, etc.), check for both: `file
~/.bashrc` for CRLF, and `grep -n 'PS1=' ~/.bashrc` to confirm the `PS1` line
matches what's in this repo.

## Customizing without forking this file

Put host-specific PATH entries, work-only aliases, tokens, or anything else
you don't want in version control into `~/.bashrc.local` — `.bashrc` sources
it automatically at the end if it exists, and it's plain `$HOME`, so it never
gets committed here.

That is also where to tell `ctx` what production looks like on your
accounts, as an extended regular expression matched in any case:

```bash
export CTX_DANGER_PATTERN='prod|prd|live|-p[0-9]+$'
```

## Requirements

| Requirement | Notes |
| --- | --- |
| **Git for Windows** | Ships MSYS2 Bash, `ssh-agent`, `ssh-add`, `ssh-keygen`. Tested against a current Git for Windows release. |
| **An SSH key** | Defaults to `~/.ssh/id_ed25519`; override by exporting `SSH_KEY=/path/to/key` before `.bashrc` runs, or edit the default in `.bashrc`. Missing key/`.pub` prints a message instead of failing silently. |
| **`CODING_DIR`** (optional) | Defaults to `/d/Coding`; if the directory exists, new shells `cd` there instead of staying in `$HOME`. No-op elsewhere — override via `CODING_DIR=/other/path` or delete the block in `.bashrc` if you don't want it. |
| **`$EDITOR`** | Defaults to `nano` (override by exporting `EDITOR` before `.bashrc` runs). `$VISUAL` and `$GIT_PAGER` follow. |

## Not covered here

- macOS shell setup lives in
  [`../../macos-initial-setup/zsh_aliases.zsh`](../../macos-initial-setup/zsh_aliases.zsh) —
  this folder is Windows/Git-Bash-specific.
- Git identity/profile management is in [`../../git/`](../../git/)
  (`set_git_profile.sh`, `git_whoami.sh`); this folder only sets shell
  defaults, not Git config.
- `default-git-bash/` next to this folder was an earlier personal draft;
  its content has been merged into `.bashrc`/`.aliases` here (naming
  collisions resolved — see git history/PR discussion for what changed and
  why). It's kept around as-is but superseded.
