#!/usr/bin/env bash
# install_devtools.sh
# Install developer toolchains on a Linux machine: Python, Go, Terraform, Helm,
# plus the DevOps CLIs worth having everywhere.
#
# The counterpart of macos-initial-setup/install_devtools.sh. One deliberate
# divergence, called out because it changes what the script trusts: on macOS the
# default is Homebrew, a package manager already on the machine. Linux has no
# equivalent for these tools — the "native" instructions are mostly
# `curl https://.../install.sh | bash`, a posture this repository takes nowhere
# else. So the default here is mise, one checksummed binary that manages all
# four toolchains. --manager distro uses the distribution's own packages where
# they exist, which is older but signed by the distro.
#
# Exit codes:
#   0   success
#   1   one or more installs failed
#   2   preflight checks failed
#   3   bad CLI arguments
set -u
set -o pipefail

DRY_RUN=0
ASSUME_YES=0
VERBOSE=0
MANAGER="mise"
SETUP_SHELL=0

SKIP_PYTHON=0
SKIP_GO=0
SKIP_TERRAFORM=0
SKIP_HELM=0
SKIP_CLIS=0

LOG_DIR="${TMPDIR:-/tmp}"
LOG_FILE="$LOG_DIR/linux_install_devtools-$(date +%Y%m%d-%H%M%S).log"

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'
  C_BLUE=$'\033[1;34m'; C_CYAN=$'\033[1;36m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''
fi
info() { printf "%s[info]%s %s\n" "$C_BLUE"   "$C_RESET" "$*"; }
ok()   { printf "%s[ ok ]%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf "%s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf "%s[err ]%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }

FAIL_COUNT=0

usage() {
  cat <<EOF
install_devtools.sh - install developer toolchains on Linux

Usage:
  $(basename "$0") [--dry-run] [--yes] [--verbose] [--manager mise|distro]
                          [--setup-shell] [--skip-* ...]

Options:
  --manager NAME    mise (default) or distro. mise manages Python/Go/Terraform/
                    Helm from one checksummed binary; distro uses the system
                    package manager, which is older but distro-signed.
  --dry-run         Print every command without running it
  --yes, -y         Do not prompt; required for anything that installs
  --verbose, -v     Stream command output instead of only logging it
  --setup-shell     Append the mise activation line to ~/.bashrc if absent
  --skip-python     Skip Python
  --skip-go         Skip Go
  --skip-terraform  Skip Terraform
  --skip-helm       Skip Helm
  --skip-clis       Skip the DevOps CLIs (git, jq, ripgrep, ...)
  --help, -h        Show this help

Log file: ${LOG_DIR}/linux_install_devtools-<timestamp>.log

Exit codes: 0 success, 1 install failures, 2 preflight failed, 3 usage
EOF
}

require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    printf "%s requires a value\n" "$option" >&2
    exit 3
  fi
}

# Duplicated in each linux/ script on purpose (see CONTRIBUTING.md). OS_RELEASE
# is honoured so the unsupported-distro path can actually be tested.
detect_pkg_mgr() {
  local os_release="${OS_RELEASE:-/etc/os-release}"
  local id="" id_like=""
  if [[ -r "$os_release" ]]; then
    id="$(sed -n 's/^ID=//p' "$os_release" | tr -d '"' | head -n 1)"
    id_like="$(sed -n 's/^ID_LIKE=//p' "$os_release" | tr -d '"' | head -n 1)"
  fi
  case " $id $id_like " in
    *" debian "*|*" ubuntu "*)             printf 'apt\n' ;;
    *" fedora "*|*" rhel "*|*" centos "*)  printf 'dnf\n' ;;
    *" arch "*|*" archlinux "*)            printf 'pacman\n' ;;
    *) printf 'unsupported:%s\n' "${id:-unknown}" ;;
  esac
}

while (( $# > 0 )); do
  case "$1" in
    --dry-run)        DRY_RUN=1 ;;
    --yes|-y)         ASSUME_YES=1 ;;
    --verbose|-v)     VERBOSE=1 ;;
    --setup-shell)    SETUP_SHELL=1 ;;
    --manager)        require_value "$1" "${2:-}"; shift; MANAGER="$1" ;;
    --manager=*)      MANAGER="${1#*=}"; require_value "--manager" "$MANAGER" ;;
    --skip-python)    SKIP_PYTHON=1 ;;
    --skip-go)        SKIP_GO=1 ;;
    --skip-terraform) SKIP_TERRAFORM=1 ;;
    --skip-helm)      SKIP_HELM=1 ;;
    --skip-clis)      SKIP_CLIS=1 ;;
    -h|--help)        usage; exit 0 ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

case "$MANAGER" in
  mise|distro) ;;
  *) err "--manager must be mise or distro, got: $MANAGER"; exit 3 ;;
esac

PKG_MGR="$(detect_pkg_mgr)"
case "$PKG_MGR" in
  unsupported:*)
    err "unsupported distribution: ${PKG_MGR#unsupported:} (need apt, dnf or pacman)"
    exit 2
    ;;
esac

# A dry run writes nothing — including this script's own log. Creating the
# file here unconditionally left one orphan in TMPDIR per preview and quietly
# contradicted the promise README.md makes. run_cmd() already skips the
# appends, so there was never anything in these files but the header.
if (( DRY_RUN == 1 )); then
  info "package manager: $PKG_MGR, toolchain manager: $MANAGER"
  info "dry-run: would write log: $C_DIM$LOG_FILE$C_RESET"
else
  : > "$LOG_FILE"
  printf 'linux install_devtools.sh log - %s\n' "$(date)" >> "$LOG_FILE"
  info "package manager: $PKG_MGR, toolchain manager: $MANAGER"
  info "log file: $C_DIM$LOG_FILE$C_RESET"
fi

SUDO=""
[[ "$(id -u)" == "0" ]] || SUDO="sudo"

step() { printf "\n%s== %s ==%s\n" "$C_BOLD" "$1" "$C_RESET"; }
have() { command -v "$1" >/dev/null 2>&1; }

run_cmd() {
  local label="$1"; shift
  if (( DRY_RUN == 1 )); then
    printf "  %s(dry-run)%s %s %s[%s]%s\n" "$C_DIM" "$C_RESET" "$*" "$C_DIM" "$label" "$C_RESET"
    return 0
  fi
  printf "  %s->%s %s\n" "$C_CYAN" "$C_RESET" "$label"
  echo "# $(date '+%H:%M:%S') [$label] >> $*" >> "$LOG_FILE"
  local rc
  if (( VERBOSE == 1 )); then
    "$@" 2>&1 | tee -a "$LOG_FILE"
    rc="${PIPESTATUS[0]}"
  else
    "$@" >>"$LOG_FILE" 2>&1
    rc=$?
  fi
  if (( rc != 0 )); then
    err "$label failed (exit $rc; see $LOG_FILE)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
  return 0
}

pkg_install() {
  case "$PKG_MGR" in
    apt)    run_cmd "install $*" $SUDO apt-get install --yes "$@" ;;
    dnf)    run_cmd "install $*" $SUDO dnf install -y "$@" ;;
    pacman) run_cmd "install $*" $SUDO pacman -S --needed --noconfirm "$@" ;;
  esac
}

if (( ASSUME_YES == 0 )) && (( DRY_RUN == 0 )); then
  err "this installs software; rerun with --yes, or --dry-run to preview"
  exit 3
fi

# --- base CLIs -------------------------------------------------------------
if (( SKIP_CLIS == 0 )); then
  step "DevOps CLIs"
  case "$PKG_MGR" in
    apt)    pkg_install git curl jq unzip ripgrep fd-find ;;
    dnf)    pkg_install git curl jq unzip ripgrep fd-find ;;
    pacman) pkg_install git curl jq unzip ripgrep fd ;;
  esac
else
  info "skipped: CLIs"
fi

# --- toolchains ------------------------------------------------------------
if [[ "$MANAGER" == "mise" ]]; then
  step "mise"
  if have mise; then
    ok "mise already installed"
  else
    case "$PKG_MGR" in
      pacman) pkg_install mise ;;
      *)
        # Deliberately not curl|bash: fetch, then run from a file so the
        # payload can be inspected and the download failing is a real error
        # rather than an empty pipe into a shell.
        if (( DRY_RUN == 1 )); then
          printf "  %s(dry-run)%s fetch https://mise.run and run it %s[install mise]%s\n" \
            "$C_DIM" "$C_RESET" "$C_DIM" "$C_RESET"
        else
          tmp="$(mktemp)"
          if curl -fsSL https://mise.run -o "$tmp"; then
            run_cmd "install mise" sh "$tmp"
          else
            err "could not download the mise installer"
            FAIL_COUNT=$((FAIL_COUNT + 1))
          fi
          rm -f "$tmp"
        fi
        ;;
    esac
  fi

  MISE="$(command -v mise || printf '%s\n' "$HOME/.local/bin/mise")"
  step "toolchains via mise"
  (( SKIP_PYTHON == 0 ))    && run_cmd "python latest"    "$MISE" use -g python@latest
  (( SKIP_GO == 0 ))        && run_cmd "go latest"        "$MISE" use -g go@latest
  (( SKIP_TERRAFORM == 0 )) && run_cmd "terraform latest" "$MISE" use -g terraform@latest
  (( SKIP_HELM == 0 ))      && run_cmd "helm latest"      "$MISE" use -g helm@latest

  if (( SETUP_SHELL == 1 )); then
    step "shell"
    rc_file="$HOME/.bashrc"
    line='eval "$(mise activate bash)"'
    if [[ -f "$rc_file" ]] && grep -Fq "mise activate" "$rc_file"; then
      ok "mise activation already in $rc_file"
    elif (( DRY_RUN == 1 )); then
      printf "  %s(dry-run)%s would append %s to %s\n" "$C_DIM" "$C_RESET" "$line" "$rc_file"
    else
      printf '\n# added by linux/install_devtools.sh\n%s\n' "$line" >> "$rc_file"
      ok "appended mise activation to $rc_file"
    fi
  fi
else
  step "toolchains via $PKG_MGR"
  # Distro packages only. Terraform and Helm are not in the default repos of
  # any of the three, and wiring up HashiCorp's and Helm's third-party repos is
  # a different decision from "install a package" — say so instead of doing it
  # quietly.
  case "$PKG_MGR" in
    apt)    (( SKIP_PYTHON == 0 )) && pkg_install python3 python3-pip python3-venv ;;
    dnf)    (( SKIP_PYTHON == 0 )) && pkg_install python3 python3-pip ;;
    pacman) (( SKIP_PYTHON == 0 )) && pkg_install python python-pip ;;
  esac
  # pkg_install always returns 0 (run_cmd records failures without aborting),
  # so a `go || golang` chain never reaches the fallback. Use the real package
  # name per distro instead.
  if (( SKIP_GO == 0 )); then
    case "$PKG_MGR" in
      apt)    pkg_install golang ;;
      dnf)    pkg_install golang ;;
      pacman) pkg_install go ;;
    esac
  fi
  for tool in terraform helm; do
    case "$tool" in
      terraform) (( SKIP_TERRAFORM == 1 )) && continue ;;
      helm)      (( SKIP_HELM == 1 )) && continue ;;
    esac
    if have "$tool"; then
      ok "$tool already installed"
    else
      warn "$tool is not in the default $PKG_MGR repositories"
      info "add the upstream repository yourself, or use --manager mise"
    fi
  done
fi

# --- report ----------------------------------------------------------------
step "versions"
for tool in git jq python3 go terraform helm mise; do
  if have "$tool"; then
    printf "  %-11s %s\n" "$tool" "$("$tool" --version 2>&1 | head -n 1)"
  else
    printf "  %-11s %s(not installed)%s\n" "$tool" "$C_DIM" "$C_RESET"
  fi
done

printf "\n"
if (( DRY_RUN == 1 )); then
  printf "dry-run complete; no changes written\n"
  exit 0
fi
info "full log: $LOG_FILE"
if (( FAIL_COUNT > 0 )); then
  err "$FAIL_COUNT step(s) failed"
  exit 1
fi
ok "done"
