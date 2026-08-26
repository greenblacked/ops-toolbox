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
setopt EXTENDED_HISTORY      # record timestamps: "when did I run that apply"
setopt HIST_EXPIRE_DUPS_FIRST
setopt HIST_REDUCE_BLANKS

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
# Only tools that accept the same flags as what they replace are allowed to
# shadow it. fd and rg deliberately do not: `find . -name '*.log'` is an error
# under fd, and `grep -rn pattern dir` means something different under rg - so
# a command copied out of a runbook or an incident doc breaks on the machine
# that aliased them. Use fd and rg by their own names.
command -v bat  >/dev/null 2>&1 && alias cat='bat --paging=never'
command -v htop >/dev/null 2>&1 && alias top='htop'
command -v duf  >/dev/null 2>&1 && alias df='duf'
command -v dust >/dev/null 2>&1 && alias du='dust'

alias grep='grep --color=auto'
alias egrep='egrep --color=auto'
alias fgrep='fgrep --color=auto'

# ================================ convenience =============================
# Keep `h` free for Helm shortcuts below.
alias hh='history'
alias hist='history'
alias c='clear'
alias reload='exec zsh'
alias path='echo -e ${PATH//:/\\n}'
alias ports='lsof -i -P -n | grep LISTEN'
alias myip='curl -s https://api.ipify.org && echo'

# ipconfig is macOS-only; `ip route` is the Linux spelling. Without the split
# this alias was registered everywhere and failed everywhere but a Mac.
if [[ "$(uname -s)" == "Darwin" ]]; then
  alias localip='ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1'
else
  # The address is the token after "src"; its field number shifts depending on
  # whether the route has a via hop, so scan rather than count.
  localip() {
    ip -4 route get 1.1.1.1 2>/dev/null \
      | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}'
  }
fi

# The trailing space makes the next word eligible for alias expansion, so
# `sudo sc restart foo` and `watch kgp` work instead of "command not found".
alias sudo='sudo '
command -v watch >/dev/null 2>&1 && alias watch='watch '
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
  alias dstats='docker stats --no-stream'
  # Deliberately loud name: -af --volumes removes every stopped container,
  # every unused image and every unused volume, including data you meant to
  # keep. There is no undo.
  alias dprune='docker system prune -af --volumes'
  # Container IPs without remembering the Go template.
  dip() {
    docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$@"
  }
fi
command -v lazydocker >/dev/null 2>&1 && alias lzd='lazydocker'

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

  # The gets you type all day.
  alias kgp='kubectl get pods'
  alias kgpa='kubectl get pods -A'
  alias kgpw='kubectl get pods -o wide'
  alias kgs='kubectl get svc'
  alias kgd='kubectl get deploy'
  alias kgn='kubectl get nodes -o wide'
  alias kga='kubectl get all'

  alias kaf='kubectl apply -f'
  # Server-side dry run: the manifest is validated by the real admission
  # chain, which catches what a client-side parse cannot.
  alias kdry='kubectl apply --dry-run=server -f'
  alias kdelf='kubectl delete -f'

  alias kpf='kubectl port-forward'
  alias ktop='kubectl top pods'
  alias krr='kubectl rollout restart'
  alias krs='kubectl rollout status'
  # Events in the order things happened, which is never the default order.
  alias kev='kubectl get events --sort-by=.lastTimestamp'

  # kctx: show the current context, or switch to the one named.
  kctx() {
    if [[ -z "${1:-}" ]]; then
      kubectl config get-contexts
    else
      kubectl config use-context "$1"
    fi
  }
fi
command -v k9s >/dev/null 2>&1 && alias k9='k9s'

# ================================ aws ======================================
if command -v aws >/dev/null 2>&1; then
  # The first question on any misbehaving credential chain.
  alias aws-whoami='aws sts get-caller-identity'

  # awsp: show profiles, or export AWS_PROFILE for this shell.
  awsp() {
    if [[ -z "${1:-}" ]]; then
      aws configure list-profiles
      [[ -n "${AWS_PROFILE:-}" ]] && echo "current: $AWS_PROFILE"
    else
      export AWS_PROFILE="$1"
      echo "AWS_PROFILE=$AWS_PROFILE"
    fi
  }
fi

# ================================ ansible ==================================
if command -v ansible-playbook >/dev/null 2>&1; then
  alias ap='ansible-playbook'
  # Check mode with a diff is the plan step ansible does not foreground.
  alias apc='ansible-playbook --check --diff'
  alias av='ansible-vault'
  alias ainv='ansible-inventory --graph'
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
  alias tfsh='terraform state show'
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

if [[ -x "$_ZSH_ALIASES_DIR/workstation_doctor.sh" ]]; then
  alias workstation-doctor="$_ZSH_ALIASES_DIR/workstation_doctor.sh"
fi

if [[ -x "$_ZSH_ALIASES_DIR/hardening_audit.sh" ]]; then
  alias hardening-audit="$_ZSH_ALIASES_DIR/hardening_audit.sh"
fi

if [[ -x "$_ZSH_ALIASES_DIR/macos_defaults.sh" ]]; then
  alias macos-defaults="$_ZSH_ALIASES_DIR/macos_defaults.sh"
fi

if [[ -x "$_ZSH_ALIASES_DIR/brewfile.sh" ]]; then
  alias brewfile-sync="$_ZSH_ALIASES_DIR/brewfile.sh"
fi

if [[ -x "$_ZSH_ALIASES_DIR/launchd/stay_fresh_agent.sh" ]]; then
  alias stay-fresh-agent="$_ZSH_ALIASES_DIR/launchd/stay_fresh_agent.sh"
  alias stay-fresh-logs="$_ZSH_ALIASES_DIR/launchd/stay_fresh_agent.sh logs"
fi

# Discoverable command palette for the guarded repository shortcuts above.
# It reports only scripts that are executable in this checkout, so copying this
# aliases file without the rest of the package never advertises broken commands.
toolbox-help() {
  echo "macOS toolbox commands available in this checkout:"
  [[ -x "$_ZSH_ALIASES_DIR/install_apps.sh" ]] && \
    printf '  %-20s %s\n' install-apps 'install curated apps and CLIs'
  [[ -x "$_ZSH_ALIASES_DIR/install_devtools.sh" ]] && \
    printf '  %-20s %s\n' install-devtools 'install language and IaC toolchains'
  [[ -x "$_ZSH_ALIASES_DIR/stay_fresh.sh" ]] && \
    printf '  %-20s %s\n' stay-fresh 'run recurring workstation maintenance'
  [[ -x "$_ZSH_ALIASES_DIR/workstation_doctor.sh" ]] && \
    printf '  %-20s %s\n' workstation-doctor 'report workstation health'
  [[ -x "$_ZSH_ALIASES_DIR/hardening_audit.sh" ]] && \
    printf '  %-20s %s\n' hardening-audit 'audit security posture'
  [[ -x "$_ZSH_ALIASES_DIR/macos_defaults.sh" ]] && \
    printf '  %-20s %s\n' macos-defaults 'report/apply/revert preferences'
  [[ -x "$_ZSH_ALIASES_DIR/brewfile.sh" ]] && \
    printf '  %-20s %s\n' brewfile-sync 'capture or restore Homebrew state'
  [[ -x "$_ZSH_ALIASES_DIR/launchd/stay_fresh_agent.sh" ]] && {
    printf '  %-20s %s\n' stay-fresh-agent 'manage scheduled maintenance'
    printf '  %-20s %s\n' stay-fresh-logs 'inspect the latest scheduled-run log'
  }
}

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

# retry <n> <command...>: run a command up to n times with exponential backoff.
# The loop every ops shell ends up needing for a flaky endpoint or an API that
# has not converged yet. Returns the command's last exit code, so it composes:
#   retry 5 curl -fsS https://service/healthz
retry() {
  local attempts="${1:-}"
  if [[ ! "$attempts" == <1-> || $# -lt 2 ]]; then
    echo "usage: retry <attempts> <command...>" >&2
    return 2
  fi
  shift
  local n=1 delay=2 rc=0
  while true; do
    "$@" && return 0
    rc=$?
    if (( n >= attempts )); then
      echo "retry: failed after $attempts attempt(s): $*" >&2
      return $rc
    fi
    echo "retry: attempt $n/$attempts failed (exit $rc); sleeping ${delay}s" >&2
    sleep "$delay"
    (( n++, delay *= 2 ))
  done
}

# ================================ completion ===============================
# Give the short aliases the completion of the command they stand for - but
# only when the user's own zshrc has already run compinit. Forcing compinit
# from an aliases file would change completion behaviour they did not ask for.
if (( ${+functions[compdef]} )); then
  compdef k=kubectl 2>/dev/null
  compdef g=git 2>/dev/null
  compdef tf=terraform 2>/dev/null
  compdef h=helm 2>/dev/null
  compdef d=docker 2>/dev/null
fi
