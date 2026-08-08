#!/usr/bin/env bash
# install_devtools.sh
# Install a curated set of developer toolchains on macOS using best-practice
# version managers (so you can have multiple versions side-by-side):
#
#   Python     -> pyenv (+ pyenv-virtualenv), with build deps
#   Terraform  -> tfenv  (or --manager tenv for the modern tenv: tf/tofu/tg)
#   Go         -> goenv
#   Helm       -> Homebrew (+ optional plugins: helm-diff)
#
# Alternative unified manager:
#   --manager mise   -> use 'mise' (ex-rtx) for ALL of python/terraform/go,
#                        still installs helm via brew.
#
# This script is idempotent: re-running it upgrades tools in place.
# It will NOT modify your shell rc unless you pass --setup-shell.
#
# Usage:
#   ./install_devtools.sh [--dry-run] [--yes] [--verbose]
#                         [--manager native|tenv|mise]    (default: native)
#                         [--python-version X.Y.Z | latest-3 | skip]
#                         [--terraform-version X.Y.Z | latest | skip]
#                         [--go-version X.Y.Z | latest | skip]
#                         [--helm-version X.Y.Z | latest | skip]
#                         [--skip-python] [--skip-terraform]
#                         [--skip-go] [--skip-helm]
#                         [--helm-plugins a,b,c] [--no-helm-plugins]
#                         [--setup-shell]
#                         [--help]
#
# Exit codes:
#   0   everything installed / upgraded cleanly
#   1   one or more installs failed
#   2   preflight checks failed (not macOS, no internet, no brew, etc.)
#   3   bad CLI arguments

set -u
set -o pipefail

# ---------------------------------------------------------------------------
# output helpers (TTY-aware colors)
# ---------------------------------------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[1;31m'
  C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'
  C_BLUE=$'\033[1;34m'
  C_MAGENTA=$'\033[1;35m'
  C_CYAN=$'\033[1;36m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_MAGENTA='' C_CYAN=''
fi

bold()  { printf "%s%s%s\n" "$C_BOLD"    "$*" "$C_RESET"; }
info()  { printf "%s[info]%s %s\n"  "$C_BLUE"   "$C_RESET" "$*"; }
ok()    { printf "%s[ ok ]%s %s\n"  "$C_GREEN"  "$C_RESET" "$*"; }
warn()  { printf "%s[warn]%s %s\n"  "$C_YELLOW" "$C_RESET" "$*"; }
err()   { printf "%s[err ]%s %s\n"  "$C_RED"    "$C_RESET" "$*" 1>&2; }
step()  { printf "\n%s==>%s %s%s%s\n" "$C_CYAN" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
hr()    { printf "%s%s%s\n" "$C_DIM" "--------------------------------------------------------------" "$C_RESET"; }

# ---------------------------------------------------------------------------
# defaults / CLI parsing
# ---------------------------------------------------------------------------
DRY_RUN=0
ASSUME_YES=0
VERBOSE=0
SETUP_SHELL=0

MANAGER="native"          # native | tenv | mise

PYTHON_VERSION="latest"   # or explicit "3.12.5", or "skip"
TERRAFORM_VERSION="latest"
GO_VERSION="latest"
HELM_VERSION="latest"

SKIP_PYTHON=0
SKIP_TERRAFORM=0
SKIP_GO=0
SKIP_HELM=0

HELM_PLUGINS="helm-diff"
NO_HELM_PLUGINS=0

LOG_DIR="${TMPDIR:-/tmp}"
LOG_FILE="$LOG_DIR/install_devtools-$(date +%Y%m%d-%H%M%S).log"

# Build-time deps recommended by python-build / pyenv wiki.
PYENV_BUILD_DEPS=(openssl readline sqlite3 xz zlib tcl-tk)

# step accounting
INSTALLED=()
UPGRADED=()
SKIPPED=()
FAILED=()

usage() {
  cat <<EOF
${C_BOLD}install_devtools.sh${C_RESET} — install Python / Terraform / Go / Helm on macOS
using best-practice version managers (pyenv, tfenv, goenv, brew).

${C_BOLD}Usage:${C_RESET}
  $(basename "$0") [options]

${C_BOLD}General options:${C_RESET}
  --dry-run                 Show what would happen, install nothing
  --yes, -y                 Don't ask for confirmation
  --verbose, -v             Stream brew / builder output live (default: captured)
  --setup-shell             Append the needed init lines to ~/.zshrc (or ~/.bashrc)
  --help, -h                Show this help

${C_BOLD}Manager selection:${C_RESET}
  --manager native          pyenv + tfenv + goenv + brew helm  (default)
  --manager tenv            Use tenv (Terraform + OpenTofu + Terragrunt) instead of tfenv
  --manager mise            Use mise (ex-rtx) for python/terraform/go; helm via brew

${C_BOLD}Versions:${C_RESET}
  --python-version V        e.g. 3.12.5 | latest  (default: latest stable 3.x)
  --terraform-version V     e.g. 1.9.5  | latest
  --go-version V            e.g. 1.23.2 | latest
  --helm-version V          e.g. 3.16.1 | latest (brew-pinned installs not supported)

${C_BOLD}Skip flags:${C_RESET}
  --skip-python             Don't install Python / pyenv
  --skip-terraform          Don't install Terraform / tfenv|tenv
  --skip-go                 Don't install Go / goenv
  --skip-helm               Don't install Helm

${C_BOLD}Helm extras:${C_RESET}
  --helm-plugins a,b,c      Install these helm plugins (default: ${HELM_PLUGINS})
                            Known shorthands: helm-diff, helm-secrets, helm-git
  --no-helm-plugins         Don't install any helm plugins

Log file: $LOG_FILE
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --dry-run)                DRY_RUN=1 ;;
    -y|--yes)                 ASSUME_YES=1 ;;
    -v|--verbose)             VERBOSE=1 ;;
    --setup-shell)            SETUP_SHELL=1 ;;

    --manager)                shift; MANAGER="${1:-}" ;;
    --manager=*)              MANAGER="${1#*=}" ;;

    --python-version)         shift; PYTHON_VERSION="${1:-}" ;;
    --python-version=*)       PYTHON_VERSION="${1#*=}" ;;
    --terraform-version)      shift; TERRAFORM_VERSION="${1:-}" ;;
    --terraform-version=*)    TERRAFORM_VERSION="${1#*=}" ;;
    --go-version)             shift; GO_VERSION="${1:-}" ;;
    --go-version=*)           GO_VERSION="${1#*=}" ;;
    --helm-version)           shift; HELM_VERSION="${1:-}" ;;
    --helm-version=*)         HELM_VERSION="${1#*=}" ;;

    --skip-python)            SKIP_PYTHON=1 ;;
    --skip-terraform)         SKIP_TERRAFORM=1 ;;
    --skip-go)                SKIP_GO=1 ;;
    --skip-helm)              SKIP_HELM=1 ;;

    --helm-plugins)           shift; HELM_PLUGINS="${1:-}" ;;
    --helm-plugins=*)         HELM_PLUGINS="${1#*=}" ;;
    --no-helm-plugins)        NO_HELM_PLUGINS=1 ;;

    -h|--help)                usage; exit 0 ;;
    *) err "unknown option: $1"; echo; usage; exit 3 ;;
  esac
  shift
done

case "$MANAGER" in
  native|tenv|mise) ;;
  *) err "--manager must be one of: native | tenv | mise  (got: $MANAGER)"; exit 3 ;;
esac

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
run_logged() {
  # run_logged <logfile> <cmd...>
  local logfile="$1"; shift
  if (( VERBOSE )); then
    "$@" 2>&1 | tee -a "$logfile"
    return "${PIPESTATUS[0]}"
  else
    "$@" >>"$logfile" 2>&1
  fi
}

human_duration() {
  local s="$1"
  if (( s < 60 )); then
    printf "%ds" "$s"
  else
    printf "%dm%02ds" $((s/60)) $((s%60))
  fi
}

split_csv() {
  local csv="$1" out=() item
  [[ -z "$csv" ]] && return 0
  IFS=',' read -r -a arr <<< "$csv"
  for item in "${arr[@]}"; do
    item="$(printf '%s' "$item" | tr -d '[:space:]')"
    [[ -n "$item" ]] && out+=("$item")
  done
  printf '%s\n' "${out[@]}"
}

# Install (or upgrade) a single brew formula, quietly.
brew_ensure() {
  local pkg="$1"
  if brew list --versions "$pkg" >/dev/null 2>&1; then
    info "$pkg already installed — upgrading if needed"
    run_logged "$LOG_FILE" brew upgrade "$pkg" || \
      warn "'brew upgrade $pkg' had issues (see log, usually fine)"
  else
    info "installing $pkg via brew..."
    run_logged "$LOG_FILE" brew install "$pkg" \
      || { err "failed to install $pkg via brew"; return 1; }
  fi
}

# Resolve "latest" Python 3.x from pyenv's install list (stable, non-prerelease).
pyenv_latest_python() {
  pyenv install --list 2>/dev/null \
    | sed 's/^[[:space:]]*//' \
    | grep -E '^3\.[0-9]+\.[0-9]+$' \
    | tail -n1
}

# Resolve "latest" Go from goenv's install list.
goenv_latest_go() {
  goenv install --list 2>/dev/null \
    | sed 's/^[[:space:]]*//' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
    | tail -n1
}

# Append a block to a shell rc file if it isn't already present.
append_rc_block() {
  local rc="$1" marker="$2" block="$3"
  [[ -f "$rc" ]] || : > "$rc"
  if grep -q "$marker" "$rc" 2>/dev/null; then
    info "rc already contains '$marker' in $rc — leaving alone"
    return 0
  fi
  {
    printf '\n# %s (added by install_devtools.sh)\n' "$marker"
    printf '%s\n' "$block"
  } >> "$rc"
  ok "appended '$marker' block to $rc"
}

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------
bold "=== install_devtools: preflight checks ==="
# A dry run writes nothing — including this script's own log. Creating it
# unconditionally left one orphan per preview and contradicted the promise
# README.md makes. run_cmd() already skips the appends.
if (( DRY_RUN == 1 )); then
  info "  (dry-run) would write log: $C_DIM$LOG_FILE$C_RESET"
else
  mkdir -p "$LOG_DIR"
  : > "$LOG_FILE"
  echo "install_devtools.sh log - $(date)" >> "$LOG_FILE"
  info "log file: $C_DIM$LOG_FILE$C_RESET"
fi

# OS
if [[ "$(uname -s)" != "Darwin" ]]; then
  err "This script is for macOS only (detected: $(uname -s))."
  exit 2
fi
ok "macOS $(sw_vers -productVersion 2>/dev/null || echo '?') on $(uname -m)"

# not root
if [[ "$(id -u)" == "0" ]]; then
  err "Do NOT run this script as root. brew/pyenv refuse to run as root."
  exit 2
fi
ok "running as user: $(id -un)"

# internet
if curl -fsI --max-time 5 https://formulae.brew.sh/ >/dev/null 2>&1; then
  ok "internet reachable (formulae.brew.sh)"
else
  err "cannot reach formulae.brew.sh — check your network / VPN."
  exit 2
fi

# Xcode CLT (pyenv's python-build needs a compiler toolchain)
if xcode-select -p >/dev/null 2>&1; then
  ok "Xcode Command Line Tools: $(xcode-select -p)"
else
  warn "Xcode Command Line Tools not installed — triggering installer"
  if (( DRY_RUN == 0 )); then
    xcode-select --install || true
    err "Re-run this script once the CLT installer finishes."
    exit 2
  fi
fi

# Homebrew (we don't auto-install it here; install_apps.sh already does that).
if ! command -v brew >/dev/null 2>&1; then
  err "Homebrew not found. Install it first (or run ./install_apps.sh)."
  err "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
  exit 2
fi
BREW_PREFIX="$(brew --prefix)"
ok "$(brew --version | head -n1) (prefix: $BREW_PREFIX)"

# Ensure brew bin is on PATH for this run so we can use freshly-installed tools.
case ":$PATH:" in *":$BREW_PREFIX/bin:"*) ;; *) export PATH="$BREW_PREFIX/bin:$PATH" ;; esac

# Detect shell for --setup-shell.
RC_FILE=""
if [[ "${SHELL:-}" == */zsh ]]; then
  RC_FILE="$HOME/.zshrc"
elif [[ "${SHELL:-}" == */bash ]]; then
  RC_FILE="$HOME/.bashrc"
fi
if (( SETUP_SHELL )) && [[ -z "$RC_FILE" ]]; then
  warn "could not detect login shell from \$SHELL=${SHELL:-<unset>} — --setup-shell will be skipped"
  SETUP_SHELL=0
fi

# ---------------------------------------------------------------------------
# plan summary + confirmation
# ---------------------------------------------------------------------------
hr
bold "Plan:"
printf "  %-14s %s\n" "manager:"   "$MANAGER"
printf "  %-14s %s\n" "python:"    "$([[ $SKIP_PYTHON    == 1 ]] && echo SKIP || echo "install ($PYTHON_VERSION)")"
printf "  %-14s %s\n" "terraform:" "$([[ $SKIP_TERRAFORM == 1 ]] && echo SKIP || echo "install ($TERRAFORM_VERSION)")"
printf "  %-14s %s\n" "go:"        "$([[ $SKIP_GO        == 1 ]] && echo SKIP || echo "install ($GO_VERSION)")"
printf "  %-14s %s\n" "helm:"      "$([[ $SKIP_HELM      == 1 ]] && echo SKIP || echo "install ($HELM_VERSION)")"
printf "  %-14s %s\n" "setup-rc:"  "$([[ $SETUP_SHELL    == 1 ]] && echo "$RC_FILE" || echo "no (use --setup-shell to enable)")"
hr

if (( DRY_RUN )); then
  bold "Dry run — no changes will be made."
  exit 0
fi

if (( ASSUME_YES == 0 )) && [[ -t 0 ]]; then
  printf "%sProceed? [y/N]%s " "$C_BOLD" "$C_RESET"
  read -r answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) warn "aborted by user"; exit 0 ;;
  esac
fi

# One brew update for the whole run.
step "brew update"
run_logged "$LOG_FILE" brew update || warn "'brew update' failed — continuing (see log)"

START_ALL=$(date +%s)

# ---------------------------------------------------------------------------
# manager: mise (handles python, terraform, go in one go)
# ---------------------------------------------------------------------------
if [[ "$MANAGER" == "mise" ]]; then
  step "Installing mise (unified version manager)"
  if brew_ensure mise; then
    INSTALLED+=("mise")
  else
    FAILED+=("mise")
  fi

  # Make mise usable in this shell.
  if command -v mise >/dev/null 2>&1; then
    eval "$(mise activate bash 2>/dev/null || true)"
  fi

  mise_install() {
    # mise_install <tool> <version-spec>  (version-spec: latest | X.Y.Z)
    local tool="$1" ver="$2" label="$3"
    local t_start; t_start=$(date +%s)
    info "mise: installing $label@$ver"
    if run_logged "$LOG_FILE" mise use -g "${tool}@${ver}"; then
      ok "$label installed via mise [$(human_duration $(( $(date +%s) - t_start )))]"
      INSTALLED+=("$label (mise/$ver)")
    else
      err "mise failed to install $label@$ver — see $LOG_FILE"
      FAILED+=("$label (mise)")
    fi
  }

  (( SKIP_PYTHON    == 0 )) && mise_install python    "$PYTHON_VERSION"    "Python"
  (( SKIP_TERRAFORM == 0 )) && mise_install terraform "$TERRAFORM_VERSION" "Terraform"
  (( SKIP_GO        == 0 )) && mise_install go        "$GO_VERSION"        "Go"
fi

# ---------------------------------------------------------------------------
# Python via pyenv (only in 'native' / 'tenv' modes)
# ---------------------------------------------------------------------------
if [[ "$MANAGER" != "mise" ]] && (( SKIP_PYTHON == 0 )); then
  hr
  step "Python via pyenv"
  py_start=$(date +%s)

  # Build deps first — pyenv python-build needs these for a healthy build.
  info "ensuring Python build dependencies: ${PYENV_BUILD_DEPS[*]}"
  for dep in "${PYENV_BUILD_DEPS[@]}"; do
    brew_ensure "$dep" || warn "build dep '$dep' not ready — Python builds may fail"
  done

  brew_ensure pyenv           || FAILED+=("pyenv")
  brew_ensure pyenv-virtualenv || warn "pyenv-virtualenv not installed (optional)"

  if command -v pyenv >/dev/null 2>&1; then
    export PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"
    export PATH="$PYENV_ROOT/bin:$PATH"
    eval "$(pyenv init - 2>/dev/null || true)"

    # Resolve version.
    target_py="$PYTHON_VERSION"
    if [[ "$target_py" == "latest" ]]; then
      target_py="$(pyenv_latest_python)"
      [[ -z "$target_py" ]] && { err "could not determine latest Python via pyenv"; FAILED+=("Python (resolve latest)"); target_py=""; }
    fi

    if [[ -n "$target_py" ]]; then
      if pyenv versions --bare | grep -qx "$target_py"; then
        ok "Python $target_py already installed via pyenv"
        SKIPPED+=("Python $target_py")
      else
        info "building Python $target_py with pyenv (this can take a few minutes)..."
        # Flags recommended by the pyenv wiki for macOS + brew openssl/readline.
        ssl_prefix="$(brew --prefix openssl@3 2>/dev/null || true)"
        if [[ -n "$ssl_prefix" ]]; then
          export LDFLAGS="-L$ssl_prefix/lib ${LDFLAGS:-}"
          export CPPFLAGS="-I$ssl_prefix/include ${CPPFLAGS:-}"
        fi
        if run_logged "$LOG_FILE" pyenv install -s "$target_py"; then
          ok "Python $target_py installed"
          INSTALLED+=("Python $target_py")
        else
          err "pyenv install $target_py failed — see $LOG_FILE"
          FAILED+=("Python $target_py")
          target_py=""
        fi
      fi

      if [[ -n "$target_py" ]]; then
        info "setting pyenv global -> $target_py"
        if pyenv global "$target_py"; then
          ok "pyenv global = $target_py"
        else
          warn "could not set pyenv global"
        fi
      fi
    fi
  else
    err "pyenv not on PATH after install"
    FAILED+=("pyenv (PATH)")
  fi

  ok "python step done [$(human_duration $(( $(date +%s) - py_start )))]"
fi

# ---------------------------------------------------------------------------
# Terraform via tfenv / tenv (only in 'native' / 'tenv' modes)
# ---------------------------------------------------------------------------
if [[ "$MANAGER" != "mise" ]] && (( SKIP_TERRAFORM == 0 )); then
  hr
  step "Terraform via $([[ $MANAGER == tenv ]] && echo tenv || echo tfenv)"
  tf_start=$(date +%s)

  if [[ "$MANAGER" == "tenv" ]]; then
    # tenv is available on the 'tofuutils/tap' tap.
    if ! brew tap | grep -qx "tofuutils/tap"; then
      info "tapping tofuutils/tap for tenv..."
      run_logged "$LOG_FILE" brew tap tofuutils/tap || warn "failed to tap tofuutils/tap"
    fi
    brew_ensure tenv || FAILED+=("tenv")
    if command -v tenv >/dev/null 2>&1; then
      info "tenv: install Terraform $TERRAFORM_VERSION"
      if run_logged "$LOG_FILE" tenv terraform install "$TERRAFORM_VERSION"; then
        run_logged "$LOG_FILE" tenv terraform use "$TERRAFORM_VERSION" \
          || warn "tenv: could not 'use' Terraform $TERRAFORM_VERSION"
        ok "Terraform $TERRAFORM_VERSION installed via tenv"
        INSTALLED+=("Terraform $TERRAFORM_VERSION (tenv)")
      else
        err "tenv failed to install Terraform $TERRAFORM_VERSION"
        FAILED+=("Terraform (tenv)")
      fi
    fi
  else
    brew_ensure tfenv || FAILED+=("tfenv")
    if command -v tfenv >/dev/null 2>&1; then
      target_tf="$TERRAFORM_VERSION"
      info "tfenv install $target_tf"
      if run_logged "$LOG_FILE" tfenv install "$target_tf"; then
        # Resolve the concrete version tfenv just installed.
        resolved_tf="$(tfenv list 2>/dev/null | sed -n 's/^\*\{0,1\}[[:space:]]*\([0-9][0-9.]*\).*/\1/p' | head -n1)"
        [[ -z "$resolved_tf" ]] && resolved_tf="$target_tf"
        run_logged "$LOG_FILE" tfenv use "$resolved_tf" \
          || warn "tfenv: could not 'use' $resolved_tf"
        ok "Terraform $resolved_tf installed via tfenv"
        INSTALLED+=("Terraform $resolved_tf (tfenv)")
      else
        err "tfenv failed to install Terraform $target_tf — see $LOG_FILE"
        FAILED+=("Terraform (tfenv)")
      fi
    fi
  fi

  ok "terraform step done [$(human_duration $(( $(date +%s) - tf_start )))]"
fi

# ---------------------------------------------------------------------------
# Go via goenv (only in 'native' / 'tenv' modes)
# ---------------------------------------------------------------------------
if [[ "$MANAGER" != "mise" ]] && (( SKIP_GO == 0 )); then
  hr
  step "Go via goenv"
  go_start=$(date +%s)

  brew_ensure goenv || FAILED+=("goenv")

  if command -v goenv >/dev/null 2>&1; then
    export GOENV_ROOT="${GOENV_ROOT:-$HOME/.goenv}"
    export PATH="$GOENV_ROOT/bin:$PATH"
    eval "$(goenv init - 2>/dev/null || true)"

    target_go="$GO_VERSION"
    if [[ "$target_go" == "latest" ]]; then
      target_go="$(goenv_latest_go)"
      [[ -z "$target_go" ]] && { err "could not determine latest Go via goenv"; FAILED+=("Go (resolve latest)"); target_go=""; }
    fi

    if [[ -n "$target_go" ]]; then
      if goenv versions --bare | grep -qx "$target_go"; then
        ok "Go $target_go already installed via goenv"
        SKIPPED+=("Go $target_go")
      else
        info "goenv install $target_go (this downloads a pre-built SDK)..."
        if run_logged "$LOG_FILE" goenv install -s "$target_go"; then
          ok "Go $target_go installed"
          INSTALLED+=("Go $target_go")
        else
          err "goenv install $target_go failed — see $LOG_FILE"
          FAILED+=("Go $target_go")
          target_go=""
        fi
      fi

      if [[ -n "$target_go" ]]; then
        info "setting goenv global -> $target_go"
        if goenv global "$target_go"; then
          ok "goenv global = $target_go"
        else
          warn "could not set goenv global"
        fi
      fi
    fi
  else
    err "goenv not on PATH after install"
    FAILED+=("goenv (PATH)")
  fi

  ok "go step done [$(human_duration $(( $(date +%s) - go_start )))]"
fi

# ---------------------------------------------------------------------------
# Helm via brew (all modes)
# ---------------------------------------------------------------------------
if (( SKIP_HELM == 0 )); then
  hr
  step "Helm via brew"
  helm_start=$(date +%s)

  if [[ "$HELM_VERSION" != "latest" ]]; then
    warn "brew does not pin arbitrary Helm versions; installing the formula's latest."
    warn "if you need Helm $HELM_VERSION exactly, use mise: --manager mise --helm-version $HELM_VERSION"
  fi

  if brew_ensure helm; then
    helm_ver="$(helm version --short 2>/dev/null | sed -n 's/^v\{0,1\}\([^+]*\).*/\1/p' | head -n1)"
    ok "helm ${helm_ver:-installed}"
    INSTALLED+=("Helm${helm_ver:+ ($helm_ver)}")
  else
    FAILED+=("Helm")
  fi

  if (( NO_HELM_PLUGINS == 0 )) && command -v helm >/dev/null 2>&1 && [[ -n "$HELM_PLUGINS" ]]; then
    PLUGIN_URLS=(
      "helm-diff|https://github.com/databus23/helm-diff"
      "helm-secrets|https://github.com/jkroepke/helm-secrets"
      "helm-git|https://github.com/aslafy-z/helm-git"
    )
    for plugin in $(split_csv "$HELM_PLUGINS"); do
      url=""
      for entry in "${PLUGIN_URLS[@]}"; do
        name="${entry%%|*}"
        if [[ "$name" == "$plugin" ]]; then
          url="${entry#*|}"
          break
        fi
      done
      if [[ -z "$url" ]]; then
        # Allow the user to pass a raw URL directly.
        if [[ "$plugin" == http*://* ]]; then
          url="$plugin"
        else
          warn "unknown helm plugin shorthand '$plugin' — skipping"
          continue
        fi
      fi
      if helm plugin list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$(basename "$url" | sed 's/^helm-//')"; then
        ok "helm plugin '$plugin' already installed"
        continue
      fi
      info "installing helm plugin: $plugin ($url)"
      # Helm 4 requires --verify=false for plugins that don't publish signed
      # provenance (which is basically every community plugin today, including
      # helm-diff / helm-secrets / helm-git). Helm 3 accepts the flag too.
      if run_logged "$LOG_FILE" helm plugin install "$url" --verify=false; then
        ok "helm plugin '$plugin' installed"
        INSTALLED+=("helm plugin $plugin")
      else
        warn "helm plugin '$plugin' install failed — see log"
        FAILED+=("helm plugin $plugin")
      fi
    done
  fi

  ok "helm step done [$(human_duration $(( $(date +%s) - helm_start )))]"
fi

# ---------------------------------------------------------------------------
# optional: wire up shell rc
# ---------------------------------------------------------------------------
if (( SETUP_SHELL )); then
  hr
  step "Wiring up $RC_FILE"

  if [[ "$MANAGER" == "mise" ]]; then
    shell_name="$(basename "${SHELL:-zsh}")"
    append_rc_block "$RC_FILE" "mise activate" \
"eval \"\$(mise activate $shell_name)\""
  else
    if (( SKIP_PYTHON == 0 )); then
      append_rc_block "$RC_FILE" "pyenv init" \
'export PYENV_ROOT="$HOME/.pyenv"
[[ -d "$PYENV_ROOT/bin" ]] && export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init - zsh 2>/dev/null || pyenv init -)"
if command -v pyenv-virtualenv-init >/dev/null 2>&1; then
  eval "$(pyenv virtualenv-init -)"
fi'
    fi

    if (( SKIP_GO == 0 )); then
      append_rc_block "$RC_FILE" "goenv init" \
'export GOENV_ROOT="$HOME/.goenv"
[[ -d "$GOENV_ROOT/bin" ]] && export PATH="$GOENV_ROOT/bin:$PATH"
eval "$(goenv init - 2>/dev/null || true)"
export PATH="$GOROOT/bin:$PATH"
export PATH="$HOME/go/bin:$PATH"'
    fi

    if (( SKIP_TERRAFORM == 0 )); then
      if [[ "$MANAGER" == "tenv" ]]; then
        append_rc_block "$RC_FILE" "tenv shims" \
'export PATH="$HOME/.tenv/bin:$PATH"'
      else
        append_rc_block "$RC_FILE" "tfenv shims" \
'# tfenv installs shims under $(brew --prefix)/bin, already on PATH.
:'
      fi
    fi
  fi

  info "open a new shell (or 'source $RC_FILE') to pick up the changes."
fi

ELAPSED=$(( $(date +%s) - START_ALL ))

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
hr
bold "=== install_devtools: summary ==="
printf "  elapsed:   %s\n" "$(human_duration "$ELAPSED")"
printf "  installed: %s%d%s\n" "$C_GREEN" "${#INSTALLED[@]}" "$C_RESET"
printf "  upgraded:  %s%d%s\n" "$C_CYAN"  "${#UPGRADED[@]}"  "$C_RESET"
printf "  skipped:   %s%d%s\n" "$C_DIM"   "${#SKIPPED[@]}"   "$C_RESET"
printf "  failed:    %s%d%s\n" "$C_RED"   "${#FAILED[@]}"    "$C_RESET"

print_group() {
  local title="$1" color="$2"; shift 2
  (( $# == 0 )) && return 0
  printf "\n%s%s:%s\n" "$color" "$title" "$C_RESET"
  for item in "$@"; do printf "  - %s\n" "$item"; done
}

(( ${#INSTALLED[@]} > 0 )) && print_group "Installed" "$C_GREEN" "${INSTALLED[@]}"
(( ${#UPGRADED[@]}  > 0 )) && print_group "Upgraded"  "$C_CYAN"  "${UPGRADED[@]}"
(( ${#SKIPPED[@]}   > 0 )) && print_group "Skipped"   "$C_DIM"   "${SKIPPED[@]}"
(( ${#FAILED[@]}    > 0 )) && print_group "Failed"    "$C_RED"   "${FAILED[@]}"

echo
info "full log: $LOG_FILE"

if (( SETUP_SHELL == 0 )); then
  echo
  bold "Shell setup (add to $([[ -n "$RC_FILE" ]] && echo "$RC_FILE" || echo "~/.zshrc")):"
  if [[ "$MANAGER" == "mise" ]]; then
    cat <<'RC'
  eval "$(mise activate zsh)"     # or 'bash' if you use bash
RC
  else
    cat <<'RC'
  # --- pyenv ---
  export PYENV_ROOT="$HOME/.pyenv"
  [[ -d "$PYENV_ROOT/bin" ]] && export PATH="$PYENV_ROOT/bin:$PATH"
  eval "$(pyenv init - zsh 2>/dev/null || pyenv init -)"
  command -v pyenv-virtualenv-init >/dev/null 2>&1 && eval "$(pyenv virtualenv-init -)"

  # --- goenv ---
  export GOENV_ROOT="$HOME/.goenv"
  [[ -d "$GOENV_ROOT/bin" ]] && export PATH="$GOENV_ROOT/bin:$PATH"
  eval "$(goenv init -)"
  export PATH="$GOROOT/bin:$HOME/go/bin:$PATH"

  # --- terraform (tfenv shims live under $(brew --prefix)/bin, nothing to add) ---
RC
  fi
  info "or re-run with --setup-shell to have this script append it for you."
fi

if (( ${#FAILED[@]} > 0 )); then
  warn "Some steps failed. Inspect the log above for details."
  exit 1
fi

ok "All done — happy hacking!"
