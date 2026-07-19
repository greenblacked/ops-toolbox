# ~/.bash_profile — Git Bash on Windows
#
# Every new Git Bash window is a login shell, so it reads this file, not
# .bashrc. Without this, aliases/prompt/ssh-agent setup in .bashrc would
# silently never run for interactive terminals.
if [ -f "$HOME/.bashrc" ]; then
    # shellcheck source=/dev/null
    source "$HOME/.bashrc"
fi
