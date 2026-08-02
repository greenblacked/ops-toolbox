# ---------------------------------------------------------------------------
# zsh_aliases.zsh
#
# A curated set of zsh aliases and small helper functions following best
# practices: safe defaults, human-friendly output, sensible git shortcuts,
# and handy macOS utilities.
#
# How to use:
#   1. Copy or symlink this file somewhere stable, e.g.:
#        ln -s "$PWD/zsh_aliases.zsh" "$HOME/.zsh_aliases.zsh"
#   2. Source it from your ~/.zshrc by adding:
#        [[ -f "$HOME/.zsh_aliases.zsh" ]] && source "$HOME/.zsh_aliases.zsh"
#   3. Reload your shell: `exec zsh` or `source ~/.zshrc`
#
# Notes:
#   - Aliases that depend on optional tools (eza, bat, fd, rg, etc.) are only
#     registered when those tools are available, so this file is safe to
#     source on any machine.
# ---------------------------------------------------------------------------

# ======= shell options (non-invasive, can be removed if undesired) =========
setopt NO_CASE_GLOB          # case-insensitive globbing
setopt EXTENDED_GLOB         # powerful pattern matching
setopt HIST_IGNORE_ALL_DUPS  # dedupe history
setopt HIST_IGNORE_SPACE     # commands starting with space are not recorded
setopt HIST_VERIFY           # don't immediately execute from history expansion
setopt SHARE_HISTORY         # share history between sessions
setopt AUTO_CD               # `cd` by typing directory name
setopt INTERACTIVE_COMMENTS  # allow `# comments` in interactive shell

HISTSIZE=50000
SAVEHIST=50000
HISTFILE="${HISTFILE:-$HOME/.zsh_history}"

# ================================ safety ===================================
# Prompt before overwriting / removing; opt-out with \cp, \mv, \rm.
alias cp='cp -i'
alias mv='mv -i'
alias rm='rm -i'
alias mkdir='mkdir -pv'

# ================================ navigation ===============================
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias .....='cd ../../../..'
alias -- -='cd -'
alias ~='cd ~'

# ================================ listing ==================================
# Prefer eza if available, otherwise fall back to ls with sensible defaults.
if command -v eza >/dev/null 2>&1; then
  alias ls='eza --group-directories-first --icons=auto'
  alias l='eza -lh --group-directories-first --icons=auto'
  alias ll='eza -lh --group-directories-first --icons=auto'
  alias la='eza -lah --group-directories-first --icons=auto'
  alias lt='eza --tree --level=2 --icons=auto'
else
  # macOS / BSD ls uses -G for color; GNU ls uses --color=auto.
  if ls --color=auto >/dev/null 2>&1; then
    alias ls='ls --color=auto --group-directories-first'
  else
    alias ls='ls -G'
  fi
  alias l='ls -lh'
  alias ll='ls -lh'
  alias la='ls -lah'
  alias lt='ls -lhtr'   # sort by time, oldest first
fi

# ================================ better tools =============================
command -v bat  >/dev/null 2>&1 && alias cat='bat --paging=never'
command -v fd   >/dev/null 2>&1 && alias find='fd'
command -v rg   >/dev/null 2>&1 && alias grep='rg'
command -v htop >/dev/null 2>&1 && alias top='htop'
command -v duf  >/dev/null 2>&1 && alias df='duf'
command -v dust >/dev/null 2>&1 && alias du='dust'

# Plain grep fallback with color if ripgrep isn't installed.
if ! command -v rg >/dev/null 2>&1; then
  alias grep='grep --color=auto'
  alias egrep='egrep --color=auto'
  alias fgrep='fgrep --color=auto'
fi

# ================================ convenience =============================
# Keep `h` free for Helm shortcuts below.
alias hh='history'
alias hist='history'
alias c='clear'
alias reload='exec zsh'
alias path='echo -e ${PATH//:/\\n}'
alias ports='lsof -i -P -n | grep LISTEN'
alias myip='curl -s https://api.ipify.org && echo'
alias localip="ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1"
alias week='date +%V'
alias now='date +"%Y-%m-%d %H:%M:%S"'

# Safer / readable defaults
alias df-h='df -h'
alias du-h='du -h -d 1'
alias ping='ping -c 5'
alias tree='tree -C'

# ================================ git =====================================
if command -v git >/dev/null 2>&1; then
  alias g='git'
  alias gs='git status -sb'
  alias gss='git status'
  alias ga='git add'
  alias gaa='git add --all'
  alias gc='git commit -v'
  alias gcm='git commit -v -m'
  alias gca='git commit -v --amend'
  alias gcan='git commit -v --amend --no-edit'
  alias gco='git checkout'
  alias gcb='git checkout -b'
  alias gsw='git switch'
  alias gswc='git switch -c'
  alias gb='git branch'
  alias gbd='git branch -d'
  alias gbD='git branch -D'
  alias gd='git diff'
  alias gds='git diff --staged'
  alias gl='git log --oneline --graph --decorate --all -n 30'
  alias gll='git log --graph --decorate --all'
  alias gp='git push'
  alias gpf='git push --force-with-lease'
  alias gpl='git pull --rebase --autostash'
  alias gf='git fetch --all --prune'
  alias gst='git stash'
  alias gstp='git stash pop'
  alias grh='git reset --hard'
  alias grs='git restore --staged'
  alias gcp='git cherry-pick'

  # Quick "git wip": stage all and create a throwaway commit
  gwip() { git add --all && git commit -m "wip: ${*:-checkpoint}"; }

  # Prune merged branches (skip main / master / current), BSD/GNU compatible.
  gprune() {
    local protected='^(main|master|HEAD)$'
    local branch
    git branch --merged \
      | grep -vE "(\*|${protected})" \
      | while IFS= read -r branch; do
          branch="${branch#"${branch%%[![:space:]]*}"}"
          [[ -z "$branch" ]] && continue
          git branch -d "$branch"
        done
  }
fi

# ================================ docker / orbstack ========================
if command -v docker >/dev/null 2>&1; then
  alias d='docker'
  alias dps='docker ps'
  alias dpsa='docker ps -a'
  alias di='docker images'
  alias dex='docker exec -it'
  alias dlogs='docker logs -f'
  alias dprune='docker system prune -af --volumes'
fi

if command -v docker-compose >/dev/null 2>&1 || docker compose version >/dev/null 2>&1; then
  alias dc='docker compose'
  alias dcu='docker compose up -d'
  alias dcd='docker compose down'
  alias dcl='docker compose logs -f'
  alias dcr='docker compose restart'
fi

# ================================ kubernetes ===============================
if command -v kubectl >/dev/null 2>&1; then
  alias k='kubectl'
  alias kg='kubectl get'
  alias kd='kubectl describe'
  alias kl='kubectl logs -f'
  alias kx='kubectl exec -it'
  alias kns='kubectl config set-context --current --namespace'
fi

# ================================ homebrew =================================
if command -v brew >/dev/null 2>&1; then
  alias brewup='brew update && brew upgrade && brew upgrade --cask --greedy && brew cleanup -s && brew autoremove'
  alias brewls='brew leaves'
  alias brewcls='brew list --cask'
fi

# ================================ python / pyenv ===========================
# pyenv manages multiple Python versions. Initializing it here makes the shims
# (python, pip, ...) available in every interactive shell.
if command -v pyenv >/dev/null 2>&1; then
  export PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"
  [[ -d "$PYENV_ROOT/bin" ]] && export PATH="$PYENV_ROOT/bin:$PATH"
  eval "$(pyenv init - zsh 2>/dev/null || pyenv init -)"
  command -v pyenv-virtualenv-init >/dev/null 2>&1 && \
    eval "$(pyenv virtualenv-init -)"
fi

if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
  alias py='python3'
  alias py2='python2'
  alias py3='python3'
  alias pipup='python3 -m pip install --upgrade pip setuptools wheel'
  # Create (or reuse) a .venv in the current directory and activate it.
  venv() {
    if [[ ! -d .venv ]]; then
      python3 -m venv .venv || return
    fi
    # shellcheck disable=SC1091
    source .venv/bin/activate
  }
  alias activate='source .venv/bin/activate 2>/dev/null || source venv/bin/activate'
  alias deactivate-venv='deactivate 2>/dev/null'
fi

# ================================ go / goenv ===============================
if command -v goenv >/dev/null 2>&1; then
  export GOENV_ROOT="${GOENV_ROOT:-$HOME/.goenv}"
  [[ -d "$GOENV_ROOT/bin" ]] && export PATH="$GOENV_ROOT/bin:$PATH"
  eval "$(goenv init - 2>/dev/null || true)"
fi

if command -v go >/dev/null 2>&1; then
  # Make `go install ...`-ed binaries available on PATH.
  export GOPATH="${GOPATH:-$HOME/go}"
  case ":$PATH:" in *":$GOPATH/bin:"*) ;; *) export PATH="$GOPATH/bin:$PATH" ;; esac

  alias gor='go run'
  alias gob='go build ./...'
  alias got='go test ./...'
  alias gotv='go test -v ./...'
  alias gotc='go test -cover ./...'
  alias gom='go mod tidy'
  alias gomd='go mod download'
  alias gofmt-all='gofmt -s -w .'
  alias govet='go vet ./...'
fi

# ================================ terraform / tfenv / tenv =================
if command -v terraform >/dev/null 2>&1; then
  alias tf='terraform'
  alias tfi='terraform init'
  alias tfiu='terraform init -upgrade'
  alias tfp='terraform plan'
  alias tfa='terraform apply'
  alias tfaa='terraform apply -auto-approve'
  alias tfd='terraform destroy'
  alias tff='terraform fmt -recursive'
  alias tfv='terraform validate'
  alias tfo='terraform output'
  alias tfs='terraform state'
  alias tfsl='terraform state list'
  alias tfw='terraform workspace'
  alias tfws='terraform workspace select'
  alias tfwl='terraform workspace list'
fi

# OpenTofu (drop-in terraform alternative) — nice to have when using tenv.
if command -v tofu >/dev/null 2>&1; then
  alias to='tofu'
  alias toi='tofu init'
  alias topl='tofu plan'
  alias toa='tofu apply'
fi

# ================================ helm =====================================
if command -v helm >/dev/null 2>&1; then
  alias h='helm'
  alias hls='helm list -A'
  alias hget='helm get'
  alias hhist='helm history'
  alias hin='helm install'
  alias hup='helm upgrade --install'
  alias hun='helm uninstall'
  alias hs='helm search repo'
  alias hru='helm repo update'
  alias htpl='helm template'
  # Only alias hdiff if the helm-diff plugin is actually installed.
  if helm plugin list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx diff; then
    alias hdiff='helm diff'
    alias hdiffu='helm diff upgrade'
  fi
fi

# ================================ custom scripts ===========================
# Resolve the directory this file lives in so the aliases keep working
# regardless of where the repo is cloned or symlinked.
_ZSH_ALIASES_DIR="${${(%):-%x}:A:h}"

if [[ -x "$_ZSH_ALIASES_DIR/stay_fresh.sh" ]]; then
  alias stay-fresh="$_ZSH_ALIASES_DIR/stay_fresh.sh"
  alias stayfresh="$_ZSH_ALIASES_DIR/stay_fresh.sh"
fi

if [[ -x "$_ZSH_ALIASES_DIR/install_apps.sh" ]]; then
  alias install-apps="$_ZSH_ALIASES_DIR/install_apps.sh"
fi

if [[ -x "$_ZSH_ALIASES_DIR/install_devtools.sh" ]]; then
  alias install-devtools="$_ZSH_ALIASES_DIR/install_devtools.sh"
fi

if [[ -x "$_ZSH_ALIASES_DIR/bootstrap_mac.sh" ]]; then
  alias bootstrap-mac="$_ZSH_ALIASES_DIR/bootstrap_mac.sh"
fi

# ================================ macOS ====================================
if [[ "$(uname -s)" == "Darwin" ]]; then
  # Show / hide hidden files in Finder
  alias showfiles='defaults write com.apple.finder AppleShowAllFiles YES && killall Finder'
  alias hidefiles='defaults write com.apple.finder AppleShowAllFiles NO && killall Finder'

  # Quick DNS / cache maintenance
  alias flushdns='sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder'
  alias purgemem='sudo purge'

  # Eject all mounted external disks
  alias ejectall="osascript -e 'tell application \"Finder\" to eject (every disk whose ejectable is true)'"

  # Lock the screen
  alias lock='pmset displaysleepnow'

  # Clipboard helpers
  alias pbj='pbpaste | jq .'   # pretty-print JSON from clipboard (needs jq)
fi

# ================================ functions ================================
# mkcd <dir>: make a directory and cd into it.
mkcd() {
  if [[ -z "${1:-}" ]]; then
    echo "usage: mkcd <dir>" >&2
    return 1
  fi
  mkdir -p -- "$1" && cd -- "$1"
}

# extract <archive>: handle the most common archive formats.
extract() {
  if [[ -z "${1:-}" || ! -f "$1" ]]; then
    echo "usage: extract <archive>" >&2
    return 1
  fi
  case "$1" in
    *.tar.bz2|*.tbz2) tar xvjf   "$1" ;;
    *.tar.gz|*.tgz)   tar xvzf   "$1" ;;
    *.tar.xz)         tar xvJf   "$1" ;;
    *.tar)            tar xvf    "$1" ;;
    *.bz2)            bunzip2    "$1" ;;
    *.gz)             gunzip     "$1" ;;
    *.xz)             unxz       "$1" ;;
    *.zip)            unzip      "$1" ;;
    *.rar)            unrar x    "$1" ;;
    *.7z)             7z x       "$1" ;;
    *.Z)              uncompress "$1" ;;
    *) echo "extract: unknown archive format: $1" >&2; return 1 ;;
  esac
}

# up <n>: cd up `n` directories (default 1).
up() {
  local n="${1:-1}"
  local path=""
  for ((i=0; i<n; i++)); do path+="../"; done
  cd "$path" || return
}

# mkbackup <file>: make a timestamped copy of a file.
mkbackup() {
  if [[ -z "${1:-}" || ! -e "$1" ]]; then
    echo "usage: mkbackup <file>" >&2
    return 1
  fi
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  cp -a -- "$1" "$1.bak.$ts" && echo "backed up to $1.bak.$ts"
}

# weather [city]: quick weather via wttr.in
weather() {
  local city="${1:-}"
  curl -s "https://wttr.in/${city}?format=3"
}
