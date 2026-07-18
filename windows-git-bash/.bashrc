# ~/.bashrc — Git Bash (MSYS2) on Windows
#
# Load order note: Git Bash starts a *login* shell for new terminal windows,
# which reads ~/.bash_profile (or ~/.profile), NOT ~/.bashrc, unless
# .bash_profile explicitly sources it. See .bash_profile in this folder.
#
# Safe to source more than once (no duplicate PATH entries, no duplicate
# ssh-agent processes across terminal tabs).

# Only continue for interactive shells (scripts sourcing this file otherwise
# don't need prompts/aliases and it avoids surprises under CI or `bash -c`).
case $- in
    *i*) ;;
      *) return ;;
esac

# ---------------------------------------------------------------------------
# Default working directory
# ---------------------------------------------------------------------------
# Personal convenience: land in a projects folder instead of $HOME on every
# new window. No-op (and harmless) on any machine where CODING_DIR doesn't
# exist, so it's safe to leave in even if you don't use this layout.
CODING_DIR="${CODING_DIR:-/d/Coding}"
if [ -d "$CODING_DIR" ]; then
    cd "$CODING_DIR" || true
fi
unset CODING_DIR

# ---------------------------------------------------------------------------
# History
# ---------------------------------------------------------------------------
HISTSIZE=10000
HISTFILESIZE=20000
# Ignore duplicate commands and lines starting with a space.
HISTCONTROL=ignoreboth:erasedups
# Append to the history file, don't overwrite it (matters when several Git
# Bash windows are open at once).
shopt -s histappend
# Persist history after every command instead of only at shell exit — the
# usual failure mode on Windows is closing a terminal window rather than
# typing `exit`, which otherwise loses that session's history entirely.
# Guarded so re-sourcing this file (e.g. via the `src` alias below) doesn't
# keep appending another copy onto PROMPT_COMMAND forever.
case "$PROMPT_COMMAND" in
    "history -a; history -c; history -r"*) ;;
    *) PROMPT_COMMAND="history -a; history -c; history -r${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;;
esac

# ---------------------------------------------------------------------------
# Shell behavior
# ---------------------------------------------------------------------------
# Fix the window size after every command (resizing a Windows terminal
# doesn't always trigger SIGWINCH the way it does on Linux/macOS).
shopt -s checkwinsize
# Recursive globbing with **.
shopt -s globstar 2>/dev/null
# Correct minor directory-name typos with `cd`.
shopt -s cdspell 2>/dev/null

# ---------------------------------------------------------------------------
# PATH hygiene
# ---------------------------------------------------------------------------
# Sourcing .bashrc more than once (e.g. from a nested shell) duplicates PATH
# entries over time. Dedup while preserving order.
dedup_path() {
    local -A seen
    local -a out
    local dir
    IFS=':' read -ra _entries <<< "$PATH"
    for dir in "${_entries[@]}"; do
        [[ -z $dir || -n ${seen[$dir]} ]] && continue
        seen[$dir]=1
        out+=("$dir")
    done
    IFS=':'
    PATH="${out[*]}"
    unset IFS
}
dedup_path

# ---------------------------------------------------------------------------
# ssh-agent: one persistent agent shared by every Git Bash window
# ---------------------------------------------------------------------------
# The naive version of this (spawn `ssh-agent -s` whenever one isn't visible
# in *this* shell) leaks a new background ssh-agent.exe per terminal, because
# each new shell fails the "is one already available" check and starts its
# own — the old ones are never reused or killed. Persisting the agent's PID
# and socket in a file lets every shell reconnect to the same agent instead.
SSH_ENV="$HOME/.ssh/agent.env"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"

start_ssh_agent() {
    ssh-agent -s > "$SSH_ENV"
    chmod 600 "$SSH_ENV"
    # shellcheck source=/dev/null
    source "$SSH_ENV" >/dev/null
}

if [ -f "$SSH_ENV" ]; then
    # shellcheck source=/dev/null
    source "$SSH_ENV" >/dev/null
fi

ssh-add -l >/dev/null 2>&1
ssh_add_status=$?
# Exit status 2 from `ssh-add -l` means "no agent reachable"; status 1 means
# "agent reachable but no keys loaded" — only spawn a new agent in the first
# case, otherwise reuse the one already running.
if [ "$ssh_add_status" -eq 2 ]; then
    start_ssh_agent
fi
unset ssh_add_status

# Load the key only if it isn't already loaded under this agent. Fingerprint
# lookup can itself fail (missing .pub file, unsupported key type) — treat
# that as "unknown", not "already loaded": an empty fingerprint would
# otherwise match `grep`'s empty-pattern-matches-everything behavior and
# silently skip loading a key that was never actually added.
if [ -f "$SSH_KEY" ]; then
    KEY_FINGERPRINT=$(ssh-keygen -lf "$SSH_KEY.pub" 2>/dev/null | awk '{print $2}')
    if [ -n "$KEY_FINGERPRINT" ]; then
        if ! ssh-add -l 2>/dev/null | grep -Fq "$KEY_FINGERPRINT"; then
            ssh-add "$SSH_KEY" 2>/dev/null
        fi
    else
        ssh-add "$SSH_KEY" 2>/dev/null
    fi
else
    printf 'ssh-agent: key not found: %s\n' "$SSH_KEY" >&2
fi
unset SSH_ENV SSH_KEY KEY_FINGERPRINT

# ---------------------------------------------------------------------------
# Prompt (user@host, cwd, git branch, exit-status-aware color)
# ---------------------------------------------------------------------------
__git_branch() {
    local ref
    # Single command substitution (no backslash line-continuation): a stray
    # CR from a CRLF-saved copy of this file silently breaks `\`-newline
    # continuations, which is exactly what happened the first time around.
    ref=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null) || return
    printf ' (%s)' "$ref"
}
# The line break below is a literal newline inside the quotes, not the `\n`
# prompt escape: this bash has a parser bug where a `$(...)` command
# substitution followed anywhere later in PS1 by the *decoded* `\n` escape
# throws "command substitution: ... syntax error near unexpected token `)'"
# on every prompt redraw. An actual embedded newline sidesteps the decode
# path that triggers it and renders identically.
PS1='\[\e[32m\]\u@\h\[\e[0m\] \[\e[34m\]\w\[\e[33m\]$(__git_branch)\[\e[0m\]
\$ '

# ---------------------------------------------------------------------------
# Editor & pager defaults
# ---------------------------------------------------------------------------
export EDITOR="${EDITOR:-vim}"
export VISUAL="$EDITOR"
# -R shows color escape codes instead of raw garbage; -F exits immediately if
# output fits on one screen (mimics `cat` for short output).
export LESS="-R -F -X"

# ---------------------------------------------------------------------------
# Aliases
# ---------------------------------------------------------------------------
alias ls='ls -F --color=auto --group-directories-first'
alias ll='ls -lAh'
alias la='ls -A'
alias grep='grep --color=auto'
alias ..='cd ..'
alias ...='cd ../..'
# Plain `clear` in Windows Terminal/ConHost only blanks the visible screen —
# scrolling up still shows everything. `\e[3J` also drops the scrollback, so
# `clear`/`cls`/`c` behave like cmd.exe's `cls`.
alias clear='command clear; printf "\e[3J"'
alias cls='clear'
alias c='clear'
# Reload this file without opening a new window.
alias src='source "$HOME/.bashrc"'
# `explorer .` from Git Bash needs the Windows path, not the MSYS one.
alias open='explorer.exe "$(pwd -W 2>/dev/null || pwd)"'

# ---------------------------------------------------------------------------
# Git & GitLab shortcuts
# ---------------------------------------------------------------------------
alias gs='git status -sb'
alias ga='git add'
alias gaa='git add --all'
alias gc='git commit -m'
alias gco='git checkout'
alias gb='git branch'
alias gp='git push'
alias gl='git pull'
alias gd='git diff'

# Open the current repo's remote (GitLab, GitHub, ...) in the default
# browser, converting an SSH remote (git@host:owner/repo.git) to https first.
# Usage: glopen [remote]   (defaults to "origin")
glopen() {
    local remote url host path
    remote="${1:-origin}"
    url=$(git remote get-url "$remote" 2>/dev/null) || {
        echo "glopen: no remote named '$remote' in this repo" >&2
        return 1
    }
    url=${url%.git}
    if [[ $url == git@*:* ]]; then
        host=${url#git@}
        host=${host%%:*}
        path=${url#*:}
        url="https://$host/$path"
    fi
    explorer.exe "$url" >/dev/null 2>&1
}

# Shortcuts for GitLab's official CLI (https://gitlab.com/gitlab-org/cli),
# only defined if `glab` is actually installed so they don't dangle otherwise.
if command -v glab >/dev/null 2>&1; then
    alias mrl='glab mr list'
    alias mrv='glab mr view --web'
    alias mrc='glab mr create --web'
    alias mrco='glab mr checkout'
    alias pipe='glab pipeline ci view'
    alias pipes='glab pipeline list --limit 10'
    alias issues='glab issue list'
fi

# ---------------------------------------------------------------------------
# Small utility functions
# ---------------------------------------------------------------------------
# Create a directory and cd into it in one step.
mkcd() { mkdir -p -- "$1" && cd -- "$1" || return; }

# Find files by name under the current directory without memorizing find(1) flags.
ff() { find . -iname "*${1}*" 2>/dev/null; }

# ---------------------------------------------------------------------------
# Local, machine-specific overrides (not committed — see .gitignore below)
# ---------------------------------------------------------------------------
# Put anything host-specific or secret (extra PATH entries, work-only
# aliases, tokens) in ~/.bashrc.local instead of editing this file, so a
# shared/dotfiles-repo copy of .bashrc stays generic.
if [ -f "$HOME/.bashrc.local" ]; then
    # shellcheck source=/dev/null
    source "$HOME/.bashrc.local"
fi
