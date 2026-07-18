# Windows Git Bash Dotfiles

A `.bashrc` / `.bash_profile` / `.aliases` set for Git Bash (MSYS2) on
Windows, built up from a minimal SSH-agent-loading snippet into a fuller set
of interactive-shell defaults. Safe to source more than once and safe to
drop into an existing `$HOME` — nothing here overwrites machine-specific
config, and secrets/local tweaks stay out of the committed files.

## What's here

| File | Purpose |
| --- | --- |
| `.bashrc` | Default working directory, history, prompt (with Git branch), PATH dedup, persistent `ssh-agent` with fingerprint-checked key loading, editor/pager defaults. Sources `.aliases` near the end. |
| `.bash_profile` | Sources `.bashrc`. Required because Git Bash opens new windows as **login** shells, which read `.bash_profile`/`.profile`, not `.bashrc`, by default. |
| `.aliases` | ~190 aliases and functions: Git, GitLab CLI (`glab`), Docker, Kubernetes, Terraform, Windows-style commands, navigation, safer file ops. Kept separate so it can be edited or swapped out without touching shell/environment setup in `.bashrc`. |

## Install

Git Bash's `$HOME` is usually `C:\Users\<you>` (check with `echo $HOME` inside
Git Bash — it can differ from the Windows profile folder if `HOME` is set in
the environment).

```bash
cp windows-git-bash/.bashrc windows-git-bash/.bash_profile windows-git-bash/.aliases "$HOME/"
```

If you already have a `~/.bashrc`, `~/.bash_profile`, or `~/.aliases`, diff
first and merge by hand instead of overwriting — in particular, keep
anything you have under a "local overrides" section, or move it into
`~/.bashrc.local` (see below).

Then open a new Git Bash window (or `source ~/.bash_profile` in the current
one) to pick up the changes.

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
  with a `[branch] ` prefix, push — **not** the same thing as
  [`../git/gacp.sh`](../git/gacp.sh): that script supports `--dry-run`/
  `--no-push` and doesn't prefix the message; this is the quick interactive
  shortcut), and `glopen [remote]` (opens the current repo's remote —
  GitLab, GitHub, anything — in your browser, converting an SSH remote to
  `https://` first; works without `glab` installed).
- **GitLab CLI (`glab`)** — `glmr*`, `gli*` (issues), `glpipe*`/`glci*`,
  `glrelease*`, `glvar*`, `glapi`, and functions `glmrcreate`/`glmrdraft`/
  `glpipeline`/`glrun` (all branch-aware: they read the current branch so
  you don't type it). This whole block is only defined **if `glab` is
  installed**, so none of it dangles as broken aliases otherwise.
- **Docker / Kubernetes / Terraform** — `d*`/`dc*`, `k`/`kg*`/`kd*`, `tf*`.
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

**`bash: command substitution: line N: syntax error near unexpected token `)'` /
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
   configured for CRLF still can.
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

## Requirements

| Requirement | Notes |
| --- | --- |
| **Git for Windows** | Ships MSYS2 Bash, `ssh-agent`, `ssh-add`, `ssh-keygen`. Tested against a current Git for Windows release. |
| **An SSH key** | Defaults to `~/.ssh/id_ed25519`; override by exporting `SSH_KEY=/path/to/key` before `.bashrc` runs, or edit the default in `.bashrc`. Missing key/`.pub` prints a message instead of failing silently. |
| **`CODING_DIR`** (optional) | Defaults to `/d/Coding`; if the directory exists, new shells `cd` there instead of staying in `$HOME`. No-op elsewhere — override via `CODING_DIR=/other/path` or delete the block in `.bashrc` if you don't want it. |
| **`$EDITOR`** | Defaults to `nano` (override by exporting `EDITOR` before `.bashrc` runs). `$VISUAL` and `$GIT_PAGER` follow. |

## Not covered here

- macOS shell setup lives in
  [`../macos-initial-setup/zsh_aliases.zsh`](../macos-initial-setup/zsh_aliases.zsh) —
  this folder is Windows/Git-Bash-specific.
- Git identity/profile management is in [`../git/`](../git/)
  (`set_git_profile.sh`, `git_whoami.sh`); this folder only sets shell
  defaults, not Git config.
- `default-git-bash/` next to this folder was an earlier personal draft;
  its content has been merged into `.bashrc`/`.aliases` here (naming
  collisions resolved — see git history/PR discussion for what changed and
  why). It's kept around as-is but superseded.
