#!/usr/bin/env bash
# dotfiles_doctor.sh
# Read-only health report for the configs install_dotfiles.sh put in place.
#
# Most of those configs are links into this folder, and this folder is a
# public repository. A tool that writes a secret into its own config - `npm
# login` into ~/.npmrc, `pip config set` with a token in an index URL, a git
# url rewrite with a password in it - writes it straight into a tracked file,
# and nothing notices before `git add`. This script finds that on the
# workstation and names the file and the line, never the value, so its report
# is safe to paste into a ticket.
#
# It also checks that the credential files this package deliberately never
# tracks - ~/.aws/credentials, ~/.kube/config, gh hosts.yml and the rest - are
# private on the machine, which nothing else in this repository looks at.
#
# It changes nothing: every check is a read, and every fix is a command
# printed for you to run.
#
# Exit codes:
#   0   no finding at or above the --fail-on threshold
#   1   one or more findings at or above the threshold
#   2   preflight failed (no home directory, or --repo without config/ and home/)
#   3   bad CLI arguments
set -u
set -o pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FAIL_ON="fail"
QUIET=0
REPO_ARG=""
HOME_DIR="${HOME:-}"
HOME_GIVEN=0
CONFIG_DIR=""

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
fi

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); (( QUIET )) || printf "  %s[pass]%s %s\n" "$C_GREEN" "$C_RESET" "$1"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); printf "  %s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$1"; [[ -n "${2:-}" ]] && printf "         %s%s%s\n" "$C_DIM" "$2" "$C_RESET"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf "  %s[FAIL]%s %s\n" "$C_RED" "$C_RESET" "$1"; [[ -n "${2:-}" ]] && printf "         %s%s%s\n" "$C_DIM" "$2" "$C_RESET"; }
skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); (( QUIET )) || printf "  %s[skip]%s %s\n" "$C_DIM" "$C_RESET" "$1"; }
info() { (( QUIET )) || printf "  %s[info]%s %s\n" "$C_BLUE" "$C_RESET" "$1"; }
err()  { printf "%s[err ]%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; }

usage() {
  cat <<EOF
dotfiles_doctor.sh - read-only health report for the installed dotfiles

Checks the configs install_dotfiles.sh linked into a home directory. Changes
nothing: every finding comes with the command that fixes it, for you to run.

Checks:
  linked configs   no file that is a link into the repository holds a
                   credential (reported by file and line, never by value)
  credential files the files that hold tokens (aws, gh, kube, docker,
                   terraform, netrc, argocd, jfrog, gcloud, azure) are not
                   readable or writable by group or other

Usage:
  $(basename "$0") [--repo DIR] [--home DIR] [--config-home DIR] [--fail-on warn|fail] [--quiet]

Options:
  --repo DIR         The dotfiles folder the links point into (default: the
                     folder this script sits in, when config/ and home/ are
                     beside it; otherwise the link check is skipped)
  --home DIR         Home directory to inspect (default: \$HOME); config/
                     targets are then looked for under DIR/.config
  --config-home DIR  Where config/ was installed (default: \$XDG_CONFIG_HOME,
                     or ~/.config)
  --fail-on LEVEL    Exit 1 on 'fail' (default) or on 'warn' and above
  --quiet            Print only warnings and failures
  -h, --help         Show this help

Exit codes: 0 clean, 1 findings at or above --fail-on, 2 preflight, 3 usage
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

# --help is handled here, before any preflight check, so it keeps working on a
# machine this script would otherwise refuse to run on.
while (( $# > 0 )); do
  case "$1" in
    -h|--help)        usage; exit 0 ;;
    --quiet)          QUIET=1 ;;
    --repo)           require_value "$1" "${2:-}"; REPO_ARG="$2"; shift ;;
    --repo=*)         REPO_ARG="${1#*=}"; require_value "--repo" "$REPO_ARG" ;;
    --home)           require_value "$1" "${2:-}"; HOME_DIR="$2"; HOME_GIVEN=1; shift ;;
    --home=*)         HOME_DIR="${1#*=}"; require_value "--home" "$HOME_DIR"; HOME_GIVEN=1 ;;
    --config-home)    require_value "$1" "${2:-}"; CONFIG_DIR="$2"; shift ;;
    --config-home=*)  CONFIG_DIR="${1#*=}"; require_value "--config-home" "$CONFIG_DIR" ;;
    --fail-on)        require_value "$1" "${2:-}"; FAIL_ON="$2"; shift ;;
    --fail-on=*)      FAIL_ON="${1#*=}"; require_value "--fail-on" "$FAIL_ON" ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

case "$FAIL_ON" in
  warn|fail) ;;
  *) err "--fail-on must be warn or fail, got: $FAIL_ON"; exit 3 ;;
esac

# --- preflight -------------------------------------------------------------
if [[ -z "$HOME_DIR" ]]; then
  err "\$HOME is not set; pass --home DIR"
  exit 2
fi
if [[ ! -d "$HOME_DIR" ]]; then
  err "home directory does not exist: $HOME_DIR"
  exit 2
fi
# Strip a trailing slash so targets print and compare the same either way.
HOME_DIR="${HOME_DIR%/}"
[[ -n "$HOME_DIR" ]] || HOME_DIR="/"
if [[ -z "$CONFIG_DIR" ]]; then
  # The same precedence as install_dotfiles.sh: XDG_CONFIG_HOME applies to the
  # caller's own home only. A caller that points the script at another home
  # directory wants everything under it.
  if (( HOME_GIVEN == 0 )) && [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
    CONFIG_DIR="$XDG_CONFIG_HOME"
  else
    CONFIG_DIR="$HOME_DIR/.config"
  fi
fi
CONFIG_DIR="${CONFIG_DIR%/}"

# The repository the links point into. Copied alone into ~/bin this script
# has none beside it; the link check is then skipped and everything else
# still runs, which is the point of a script that works on its own.
REPO=""
REPO_GIVEN=""
if [[ -n "$REPO_ARG" ]]; then
  if [[ ! -d "$REPO_ARG/config" || ! -d "$REPO_ARG/home" ]]; then
    err "--repo $REPO_ARG has no config/ and home/ in it"
    exit 2
  fi
  REPO="$(cd -P "$REPO_ARG" && pwd)"
  REPO_GIVEN="${REPO_ARG%/}"
elif [[ -d "$SCRIPT_DIR/config" && -d "$SCRIPT_DIR/home" ]]; then
  REPO="$SCRIPT_DIR"
  REPO_GIVEN="$SCRIPT_DIR"
fi

# --- helpers ---------------------------------------------------------------
group() { printf "\n%s== %s ==%s\n" "$C_BOLD" "$1" "$C_RESET"; }

# The same mapping as target_of() in install_dotfiles.sh.
target_of() {
  case "$1" in
    config/*) printf '%s/%s\n' "$CONFIG_DIR" "${1#config/}" ;;
    home/*)   printf '%s/%s\n' "$HOME_DIR"   "${1#home/}" ;;
  esac
}

# GNU stat first: on Linux `stat -f` is the filesystem form and succeeds with
# the wrong answer, while `stat -c` on macOS fails and falls through. -L
# reports the file a link leads to, which is the file the tool reads.
mode_of() { stat -L -c '%a' "$1" 2>/dev/null || stat -L -f '%Lp' "$1" 2>/dev/null || true; }

# `readlink` without -f: macOS 12 has no -f, and the unresolved text is what
# the installer wrote.
link_target() { readlink "$1" 2>/dev/null || true; }

# A link text inside the repository, by its physical path (what the installer
# writes) or by the path it was named with on the command line.
under_repo() {
  [[ -n "$1" ]] || return 1
  [[ "$1" == "$REPO"/* || "$1" == "$REPO_GIVEN"/* ]]
}

# Lines of a keyed pattern only count when the line is not a comment: the
# tracked .npmrc explains in a comment why no _authToken line belongs in it.
# A line whose first non-blank character is # or ; never matches.
KEYED='^[[:space:]]*([^#;[:space:]].*)?'

# One `N<TAB>label` line per hit. Only grep's line number leaves this
# function; the matched text is cut off in the pipe and never stored.
scan_pattern() {
  local file="$1" label="$2" regex="$3" n
  while IFS= read -r n; do
    [[ -n "$n" ]] && printf '%s\t%s\n' "$n" "$label"
  done < <(grep -nE -- "$regex" "$file" 2>/dev/null | cut -d: -f1)
}

# Token shapes, on every line, comments included: a real key in a comment is
# still a leaked key. The same shapes the suite greps the tracked tree for.
credential_lines() {
  local f="$1"
  scan_pattern "$f" "AWS access key id"    'AKIA[0-9A-Z]{16}'
  scan_pattern "$f" "private key"          '-----BEGIN [A-Z ]*PRIVATE KEY'
  scan_pattern "$f" "GitHub token"         'ghp_[A-Za-z0-9]{20,}'
  scan_pattern "$f" "GitLab token"         'glpat-[A-Za-z0-9_-]{20,}'
  scan_pattern "$f" "Slack token"          'xox[baprs]-[A-Za-z0-9-]{10,}'
  scan_pattern "$f" "AWS secret key"       'aws_secret_access_key *='
  scan_pattern "$f" "gh oauth token"       'oauth_token: *[A-Za-z0-9]'
  # Keyed values. An npm auth value written as an environment reference
  # (`_authToken=${NPM_TOKEN}`) is the documented way to keep it out of the
  # file, so a value that starts with $ passes.
  scan_pattern "$f" "npm auth value"       "$KEYED"'(_auth(Token)?|_password)[[:space:]]*=[[:space:]]*"?[^$"[:space:]]'
  scan_pattern "$f" "password in a URL"    "$KEYED"'://[^/@[:space:]]+:[^/@[:space:]]+@'
  scan_pattern "$f" "JSON auth value"      "$KEYED"'"auth"[[:space:]]*:[[:space:]]*"[^"]+"'
}

# --- checks ----------------------------------------------------------------
# Every tracked file whose target is a link into the repository is read
# through that link. A copy-mode file (~/.docker/config.json) is not a link
# and may hold what its tool puts there; it never reaches the repository.
check_linked_configs() {
  group "linked configs"
  if [[ -z "$REPO" ]]; then
    skip "linked configs: no config/ and home/ beside this script"
    return
  fi
  local rel target t n label lrel scanned=0 before="$FAIL_COUNT"
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    target="$(target_of "$rel")"
    [[ -L "$target" ]] || continue
    t="$(link_target "$target")"
    under_repo "$t" || continue
    if [[ ! -e "$target" ]]; then
      warn "$target links into $REPO, but $t does not exist" "rm $target  (its config was renamed or removed in the repository)"
      continue
    fi
    [[ -f "$target" ]] || continue
    scanned=$((scanned + 1))
    lrel="${t#"$REPO"/}"
    [[ "$lrel" == "$t" ]] && lrel="${t#"$REPO_GIVEN"/}"
    while IFS=$'\t' read -r n label; do
      [[ -n "$n" ]] || continue
      fail "$target: $label at line $n, in a file that is a link into $REPO" \
        "remove the line, rotate the credential, then git -C $REPO diff -- $lrel must be clean"
    done < <(credential_lines "$target" | sort -n)
  done < <(cd "$REPO" && find ./config ./home -type f \
    -not -name .DS_Store -not -path '*/__pycache__/*' | sed 's|^\./||' | sort)

  if (( scanned == 0 )); then
    skip "linked configs: nothing in $HOME_DIR links into $REPO"
  elif (( FAIL_COUNT == before )); then
    pass "$scanned linked configs hold no credential"
  fi
}

# The credential files this package never tracks, by where each tool keeps
# them: a path under the home directory, or CFG/ for one under the config
# directory. ~/.ssh is left to linux/ssh_client_doctor.sh, which knows which
# of its files may be 644 and which may not.
CREDENTIAL_FILES=".aws/credentials CFG/gh/hosts.yml .kube/config .docker/config.json
.terraform.d/credentials.tfrc.json .netrc CFG/argocd/config .jfrog/jfrog-cli.conf.v6
CFG/gcloud/credentials.db CFG/gcloud/access_tokens.db .azure/accessTokens.json"

# Only stat: these files are never opened, so their contents cannot reach the
# report whatever they hold. A missing file is the normal case on a machine
# without that tool, so absent ones are counted, not listed.
check_credential_files() {
  group "credential files"
  local entry path mode total=0 absent=0 found
  for entry in $CREDENTIAL_FILES; do
    total=$((total + 1))
    case "$entry" in
      CFG/*) path="$CONFIG_DIR/${entry#CFG/}" ;;
      *)     path="$HOME_DIR/$entry" ;;
    esac
    if [[ ! -e "$path" ]]; then
      absent=$((absent + 1))
      continue
    fi
    mode="$(mode_of "$path")"
    if [[ ! "$mode" =~ ^[0-7]{3,4}$ ]]; then
      skip "$path: could not read its mode"
      continue
    fi
    found=0
    if (( 8#$mode & 022 )); then
      fail "$path mode $mode is writable by group or other" "chmod 600 $path"
      found=1
    elif (( 8#$mode & 044 )); then
      warn "$path mode $mode is readable by group or other" "chmod 600 $path"
      found=1
    elif (( 8#$mode & 011 )); then
      warn "$path mode $mode gives group or other access" "chmod 600 $path"
      found=1
    fi
    if [[ ! -O "$path" ]]; then
      warn "$path is owned by another user" "chown $(id -un) $path"
      found=1
    fi
    (( found )) || pass "$path mode $mode"
  done
  (( absent > 0 )) && skip "$absent of $total credential files not present"
  return 0
}

# --- main ------------------------------------------------------------------
check_linked_configs
check_credential_files

printf "\n%s%s pass%s, %s%s warn%s, %s%s fail%s, %s%s skip%s\n" \
  "$C_GREEN" "$PASS_COUNT" "$C_RESET" \
  "$C_YELLOW" "$WARN_COUNT" "$C_RESET" \
  "$C_RED" "$FAIL_COUNT" "$C_RESET" \
  "$C_DIM" "$SKIP_COUNT" "$C_RESET"

case "$FAIL_ON" in
  warn) (( FAIL_COUNT + WARN_COUNT > 0 )) && exit 1; exit 0 ;;
  fail) (( FAIL_COUNT > 0 )) && exit 1; exit 0 ;;
esac
exit 0
