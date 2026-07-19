# ~/.bashrc

# Stop processing for non-interactive shells
case $- in
    *i*) ;;
    *) return ;;
esac

# ============================================================
# History
# ============================================================

export HISTCONTROL=ignoreboth:erasedups
export HISTSIZE=10000
export HISTFILESIZE=20000

shopt -s histappend
shopt -s checkwinsize
shopt -s cdspell

# ============================================================
# Default applications
# ============================================================

export EDITOR="nano"
export VISUAL="nano"
export GIT_PAGER="less"
export LESS="-FRX"

# ============================================================
# PATH
# ============================================================

export PATH="$HOME/bin:$HOME/.local/bin:$PATH"

# ============================================================
# SSH agent
# ============================================================

export SSH_KEY="/d/Coding/ssh/ed25519"

# Start a new ssh-agent only when there is no working agent
if ! ssh-add -l >/dev/null 2>&1; then
    eval "$(ssh-agent -s)" >/dev/null
fi

# Load the SSH key only when it exists and is not already loaded
if [ -f "$SSH_KEY" ]; then
    SSH_KEY_FINGERPRINT=""

    if [ -f "${SSH_KEY}.pub" ]; then
        SSH_KEY_FINGERPRINT="$(
            ssh-keygen -lf "${SSH_KEY}.pub" 2>/dev/null |
            awk '{print $2}'
        )"
    fi

    if [ -n "$SSH_KEY_FINGERPRINT" ]; then
        if ! ssh-add -l 2>/dev/null | grep -Fq "$SSH_KEY_FINGERPRINT"; then
            ssh-add "$SSH_KEY"
        fi
    elif ! ssh-add -l >/dev/null 2>&1; then
        ssh-add "$SSH_KEY"
    fi
else
    printf 'SSH key not found: %s\n' "$SSH_KEY"
fi

# ============================================================
# Load aliases
# ============================================================

if [ -f "$HOME/.aliases" ]; then
    source "$HOME/.aliases"
fi

# ============================================================
# Default startup directory
# ============================================================

if [ -d "/d/Coding" ]; then
    cd "/d/Coding"
fi
