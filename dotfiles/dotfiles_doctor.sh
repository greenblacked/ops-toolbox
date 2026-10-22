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
# And it checks the exports four configs depend on: ripgrep and gitleaks read
# their config only through a variable, k9s and Homebrew on macOS only under
# XDG_CONFIG_HOME, and without them the tool falls back to its defaults with
# no error at all.
#
# Last, the untracked overlays the ssh and git configs push identity and
# per-client settings into, which is where things break: an ssh config that
# ssh rejects, plaintext host names in known_hosts despite HashKnownHosts,
# dead ControlMaster sockets, no commit identity, and a ~/.gitconfig that
# silently overrides the tracked git config on every key.
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
PLATFORM=""

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
  linked configs     no file that is a link into the repository holds a
                     credential (reported by file and line, never by value)
  credential files   the files that hold tokens (aws, gh, kube, docker,
                     terraform, netrc, argocd, jfrog, gcloud, azure) are not
                     readable or writable by group or other
  environment hooks  RIPGREP_CONFIG_PATH and GITLEAKS_CONFIG are exported and
                     lead to a file, and on macOS XDG_CONFIG_HOME names the
                     config directory, for each tool that is on PATH
  ssh                ssh accepts ~/.ssh/config, known_hosts holds no plaintext
                     host while HashKnownHosts is on, no stale ControlMaster
                     socket is left in ~/.ssh
  git                a commit identity is set (through config.local), and no
                     ~/.gitconfig overrides the installed git config

Usage:
  $(basename "$0") [--repo DIR] [--home DIR] [--config-home DIR] [--platform macos|linux]
                     [--fail-on warn|fail] [--quiet]

Options:
  --repo DIR         The dotfiles folder the links point into (default: the
                     folder this script sits in, when config/ and home/ are
                     beside it; otherwise the link check is skipped)
  --home DIR         Home directory to inspect (default: \$HOME); config/
                     targets are then looked for under DIR/.config
  --config-home DIR  Where config/ was installed (default: \$XDG_CONFIG_HOME,
                     or ~/.config)
  --platform NAME    macos or linux: override detection (used by the tests)
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
    --platform)       require_value "$1" "${2:-}"; PLATFORM="$2"; shift ;;
    --platform=*)     PLATFORM="${1#*=}"; require_value "--platform" "$PLATFORM" ;;
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
if [[ -z "$PLATFORM" ]]; then
  if [[ "$(uname -s)" == "Darwin" ]]; then PLATFORM="macos"; else PLATFORM="linux"; fi
fi
case "$PLATFORM" in
  macos|linux) ;;
  *) err "--platform must be macos or linux, got: $PLATFORM"; exit 3 ;;
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

# Follows a chain of symlinks by hand, since macOS has no readlink -f: each
# hop reads the link text (relative text is joined to the link's own
# directory), with a 40-hop limit so a loop cannot hang. Then the directory
# part is made physical with cd -P on the deepest directory that exists, so a
# target in a deleted source directory still resolves. Prints the physical
# path; fails on a loop or an unreachable directory. The same walk as
# physical_path() in install_dotfiles.sh, which this script cannot source:
# it is meant to work copied alone into a bin directory.
physical_path() {
  local p="$1" hops=0 t d leaf phys
  while [[ -L "$p" ]]; do
    hops=$((hops + 1))
    (( hops > 40 )) && return 1
    t="$(readlink "$p" 2>/dev/null)" || return 1
    [[ -n "$t" ]] || return 1
    case "$t" in
      /*) p="$t" ;;
      *)  p="${p%/*}/$t" ;;
    esac
  done
  d="${p%/*}"
  leaf="${p##*/}"
  while [[ -n "$d" && ! -d "$d" ]]; do
    leaf="${d##*/}/$leaf"
    d="${d%/*}"
  done
  [[ -n "$d" ]] || return 1
  phys="$(cd -P "$d" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s\n' "${phys%/}" "$leaf"
}

# A link is ours when its text starts with the repository's path AND it really
# resolves under it: "$REPO/config/../../../tmp/x" has the prefix but leads
# out, and its file would be read for credentials. A `..` segment in the text
# is refused outright (the installer never writes one); the rest is resolved
# physically, the whole chain. A link into a deleted source still counts.
links_into_repo() {
  local t phys
  t="$(link_target "$1")"
  under_repo "$t" || return 1
  case "$t/" in */../*) return 1 ;; esac
  phys="$(physical_path "$t")" || return 1
  [[ "$phys" == "$REPO"/* ]]
}

# Links in the places install_dotfiles.sh looks for its own, bounded so a
# large home is never walked: the config home three levels deep, the top of
# the home, each directory under home/ in the repository two levels deep, and
# each hidden directory at the top of the home two levels deep (the links of
# a source directory that was deleted). find -H follows a starting point that
# is itself a link, such as a linked ~/.config; nothing below it.
link_candidates() {
  local d
  if [[ -d "$CONFIG_DIR" ]]; then find -H "$CONFIG_DIR" -maxdepth 3 -type l 2>/dev/null; fi
  find -H "$HOME_DIR" -maxdepth 1 -type l 2>/dev/null
  while IFS= read -r d; do
    d="${d##*/}"
    if [[ -d "$HOME_DIR/$d" ]]; then find -H "$HOME_DIR/$d" -maxdepth 2 -type l 2>/dev/null; fi
  done < <(find "$REPO/home" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
  while IFS= read -r d; do
    find -H "$d" -maxdepth 2 -type l 2>/dev/null
  done < <(find "$HOME_DIR" -mindepth 1 -maxdepth 1 -type d -name '.*' 2>/dev/null)
  return 0
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

# Reports every credential shape in a file that is a link into the
# repository. $1 is the link, $2 its text (already known to resolve under the
# repository). Only line numbers and labels reach the report.
scan_linked() {
  local target="$1" t="$2" n label lrel
  lrel="${t#"$REPO"/}"
  [[ "$lrel" == "$t" ]] && lrel="${t#"$REPO_GIVEN"/}"
  while IFS=$'\t' read -r n label; do
    [[ -n "$n" ]] || continue
    fail "$target: $label at line $n, in a file that is a link into $REPO" \
      "remove the line, rotate the credential, then git -C $REPO diff -- $lrel must be clean"
  done < <(credential_lines "$target" | sort -n)
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
  local rel target t l scanned=0 orphans=0 tracked="" before="$FAIL_COUNT"
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    target="$(target_of "$rel")"
    tracked="$tracked$target"$'\n'
    [[ -L "$target" ]] || continue
    links_into_repo "$target" || continue
    t="$(link_target "$target")"
    if [[ ! -e "$target" ]]; then
      warn "$target links into $REPO, but $t does not exist" "rm $target  (its config was renamed or removed in the repository)"
      continue
    fi
    [[ -f "$target" ]] || continue
    scanned=$((scanned + 1))
    scan_linked "$target" "$t"
  done < <(cd "$REPO" && find ./config ./home -type f \
    -not -name .DS_Store -not -path '*/__pycache__/*' | sed 's|^\./||' | sort)

  # Links for a config that was renamed or deleted: the loop above starts
  # from the files that exist today and never sees them.
  while IFS= read -r l; do
    [[ -n "$l" ]] || continue
    case "$l" in *.backup-[0-9]*) continue ;; esac
    grep -Fxq -- "$l" <<<"$tracked" && continue
    links_into_repo "$l" || continue
    t="$(link_target "$l")"
    if [[ -e "$l" ]]; then
      # Still points at a file in the repository, which a renamed install
      # target left behind: the tool reads it, so it is scanned like any
      # other linked config.
      if [[ -f "$l" ]]; then
        scanned=$((scanned + 1))
        scan_linked "$l" "$t"
      fi
      continue
    fi
    orphans=$((orphans + 1))
    warn "$l links into $REPO, but $t does not exist" "rm $l  (its config was renamed or removed in the repository)"
  done < <(link_candidates | sort -u)

  if (( scanned == 0 && orphans == 0 )); then
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

# One exported path a config depends on, checked only when its tool is on
# PATH. Only an exported variable is visible here - the same visibility rg and
# gitleaks have - so an assignment the shell never exported is reported, as
# it should be. A path other than the installed one is allowed and said so.
check_path_hook() {
  local var="$1" value="$2" want="$3" tool="$4"
  if ! command -v "$tool" >/dev/null 2>&1; then
    skip "$var: $tool not installed"
    return 0
  fi
  if [[ -z "$value" ]]; then
    warn "$var is not exported: $tool will not read $want" "export $var=\"$want\""
  elif [[ ! -e "$value" ]]; then
    fail "$var points at $value, which does not exist" "export $var=\"$want\""
  elif [[ ! -f "$value" || ! -r "$value" ]]; then
    fail "$var points at $value, which is not a readable file" "export $var=\"$want\""
  else
    pass "$var points at $value"
    [[ "$value" == "$want" ]] || info "$var is not the installed $want; that is allowed"
  fi
  return 0
}

check_environment_hooks() {
  group "environment hooks"
  check_path_hook RIPGREP_CONFIG_PATH "${RIPGREP_CONFIG_PATH:-}" "$CONFIG_DIR/ripgrep/config" rg
  check_path_hook GITLEAKS_CONFIG "${GITLEAKS_CONFIG:-}" "$CONFIG_DIR/gitleaks/gitleaks.toml" gitleaks

  # On Linux both tools read ~/.config on their own. On macOS k9s reads
  # ~/Library/Application Support/k9s and brew reads brew.env only from
  # $XDG_CONFIG_HOME/homebrew, so the configs installed here are inert there
  # unless the variable names the directory they were installed into.
  local xdg="${XDG_CONFIG_HOME:-}"
  if [[ "$PLATFORM" != "macos" ]]; then
    skip "XDG_CONFIG_HOME: only needed on macOS"
  elif ! command -v k9s >/dev/null 2>&1 && ! command -v brew >/dev/null 2>&1; then
    skip "XDG_CONFIG_HOME: neither k9s nor brew installed"
  elif [[ -z "$xdg" ]]; then
    warn "XDG_CONFIG_HOME is not exported: k9s reads ~/Library/Application Support/k9s and brew reads no brew.env, not $CONFIG_DIR/k9s and $CONFIG_DIR/homebrew" \
      "export XDG_CONFIG_HOME=\"$CONFIG_DIR\"  (in ~/.zshenv, so a terminal opened from the Dock sees it too)"
  elif [[ "${xdg%/}" != "${CONFIG_DIR%/}" ]]; then
    warn "XDG_CONFIG_HOME is $xdg, but the configs were installed under $CONFIG_DIR" \
      "export XDG_CONFIG_HOME=\"$CONFIG_DIR\"  (or reinstall with --config-home $xdg)"
  else
    pass "XDG_CONFIG_HOME is $CONFIG_DIR"
  fi

  # An alias is a property of the interactive shell; no script can see one.
  if command -v trivy >/dev/null 2>&1; then
    info "trivy reads only ./trivy.yaml; its alias must name $CONFIG_DIR/trivy/trivy.yaml (a script cannot see shell aliases)"
  fi
  return 0
}

# Counts only: a host name never leaves awk. A line is an entry when it is
# neither blank nor a comment, and it is plaintext when its host field - the
# second after an @cert-authority or @revoked marker - is not |1|-hashed.
# shellcheck disable=SC2016  # $1 and $2 are awk fields
PLAINTEXT_HOSTS_AWK='
/^[ \t]*$/ || /^[ \t]*#/ { next }
{ f = $1; if (substr(f, 1, 1) == "@") f = $2; if (index(f, "|1|") != 1) n++ }
END { print n + 0 }
'

# The home directory OpenSSH itself uses for ~ and for relative Include paths
# is the passwd entry of the running account, not $HOME. Empty when it cannot
# be found (no getent and no dscl) or is the same as the inspected home.
passwd_home() {
  local u h=""
  u="$(id -un 2>/dev/null)" || return 0
  if command -v getent >/dev/null 2>&1; then
    h="$(getent passwd "$u" 2>/dev/null | cut -d: -f6)"
  elif command -v dscl >/dev/null 2>&1; then
    h="$(dscl . -read "/Users/$u" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory:[[:space:]]*//p')"
  fi
  h="${h%/}"
  [[ -n "$h" && "$h" != "$HOME_DIR" ]] && printf '%s\n' "$h"
  return 0
}

# Splits $1 into SSH_ARGS the way OpenSSH's argv_split does for a config
# line: whitespace separates, "..." and '...' group, a backslash escapes
# the next character, an unquoted # at the start of a word ends the line.
# Returns 1 on an unbalanced quote or a trailing backslash. Bash 3.2 safe.
SSH_ARGS=()
ssh_split_args() {
  local s="$1" i=0 n ch q="" cur="" have=0 bs=$'\\'
  n=${#s}
  SSH_ARGS=()
  while (( i < n )); do
    ch="${s:i:1}"
    if [[ -n "$q" ]]; then
      if [[ "$ch" == "$q" ]]; then
        q=""
      elif [[ "$ch" == "$bs" ]]; then
        i=$((i + 1))
        (( i < n )) || return 1
        ch="${s:i:1}"
        case "$ch" in
          '"' | "'" | "$bs") cur="$cur$ch" ;;
          *) cur="$cur\\$ch" ;;
        esac
      else
        cur="$cur$ch"
      fi
    else
      case "$ch" in
        ' ')
          if (( have )); then SSH_ARGS+=("$cur"); cur=""; have=0; fi
          ;;
        '"' | "'") q="$ch"; have=1 ;;
        "$bs")
          i=$((i + 1))
          (( i < n )) || return 1
          cur="$cur${s:i:1}"; have=1
          ;;
        '#')
          if (( have )); then cur="$cur#"; else break; fi
          ;;
        *) cur="$cur$ch"; have=1 ;;
      esac
    fi
    i=$((i + 1))
  done
  [[ -z "$q" ]] || return 1
  if (( have )); then SSH_ARGS+=("$cur"); fi
  return 0
}

# True when the config, or a file one of its Include lines pulls in, has a
# Match line with an exec criterion (also negated or quoted): ssh -G would run
# that command. Includes are followed (globs too; relative paths against
# ~/.ssh and ~ against the inspected home, $HOME and the passwd home, as
# OpenSSH reads the last) to OpenSSH's own limit of 16 levels. Reaching that
# limit, an Include loop, or an Include that cannot be resolved with
# confidence counts as a hit: the config is not known to be
# free of exec, so the caller skips the probe. Reads only; nothing is run.
ssh_config_runs_exec() {
  local file="$1" depth="${2:-0}" chain="${3:-}" line low rest w pat c f pw
  local -a words cands
  (( depth <= 16 )) || return 0
  case "$chain" in
    *$'\n'"$file"$'\n'*) return 0 ;;
  esac
  chain="$chain"$'\n'"$file"$'\n'
  [[ -r "$file" ]] || return 1
  pw="$(passwd_home)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    low="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]' | tr '\t=' '  ')"
    case "$low" in
      *[![:space:]]*) ;;
      *) continue ;;
    esac
    read -r -a words <<<"$low"
    case "${words[0]:-}" in
      match)
        (( ${#words[@]} > 1 )) || continue
        for w in "${words[@]:1}"; do
          [[ "$w" == '#'* ]] && break
          w="${w//[\"\']/}"
          w="${w#!}"
          [[ "$w" == exec ]] && return 0
        done
        ;;
      include)
        # The arguments are split the way OpenSSH splits them: double and
        # single quotes group (spaces stay), a backslash escapes, an
        # unquoted # starts a comment. Anything not understood with
        # confidence (unbalanced quote, a %-token or ${VAR} OpenSSH would
        # expand) counts as a hit, like the depth limit: the caller skips
        # the probe.
        rest="$(printf '%s' "$line" | tr '\t' ' ' | sed 's/^[[:space:]]*[A-Za-z]*[[:space:]]*=\{0,1\}[[:space:]]*//')"
        ssh_split_args "$rest" || return 0
        for pat in "${SSH_ARGS[@]+"${SSH_ARGS[@]}"}"; do
          # shellcheck disable=SC2016  # a literal ${, not an expansion
          case "$pat" in
            *%* | *'${'*) return 0 ;;
          esac
          cands=()
          case "$pat" in
            [~]/*)
              cands=("$HOME_DIR/${pat#??}" "${HOME:-$HOME_DIR}/${pat#??}")
              [[ -n "$pw" ]] && cands+=("$pw/${pat#??}")
              ;;
            /*) cands=("$pat") ;;
            *)
              cands=("$HOME_DIR/.ssh/$pat")
              [[ -n "$pw" ]] && cands+=("$pw/.ssh/$pat")
              ;;
          esac
          for c in "${cands[@]}"; do
            # compgen -G prints one match per line, so a space in the path
            # does not split it the way an unquoted expansion would.
            while IFS= read -r f; do
              [[ -f "$f" ]] || continue
              # A matched file that cannot be read cannot be shown free of
              # exec, so it is a hit too.
              [[ -r "$f" ]] || return 0
              ssh_config_runs_exec "$f" $((depth + 1)) "$chain" && return 0
            done < <(compgen -G "$c" 2>/dev/null)
          done
        done
        ;;
    esac
  done <"$file"
  return 1
}

# ssh -G resolves the config for a host without connecting and refuses on
# any line it cannot parse. HOME points ssh at the inspected home, but OpenSSH
# expands ~ in Include from the account's passwd entry, so under a --home that
# is not the real one the config.d files are not read; the main file is.
check_ssh() {
  group "ssh"
  local dir="$HOME_DIR/.ssh" cfg="$HOME_DIR/.ssh/config" gout first hk kh n
  if ! command -v ssh >/dev/null 2>&1; then
    skip "ssh: not installed"
    return 0
  fi
  if [[ ! -d "$dir" ]]; then
    skip "ssh: no $dir"
    return 0
  fi

  hk=""
  if [[ ! -f "$cfg" ]]; then
    skip "ssh config: no $cfg"
  elif ssh_config_runs_exec "$cfg"; then
    # ssh -G evaluates Match exec, i.e. runs the command: not read-only.
    warn "ssh config not validated: config uses Match exec, which ssh -G would run (or has an Include that could not be resolved)" \
      "$cfg (or a file it includes) has a Match line with exec, or an Include that could not be read with confidence; check it by hand"
  else
    # One run, stderr merged: on a failure the first line is ssh's message,
    # and the options are read from the output only on success.
    if gout="$(HOME="$HOME_DIR" ssh -G -F "$cfg" example.invalid 2>&1)"; then
      pass "ssh accepts $cfg"
      hk="$(awk '$1 == "hashknownhosts" { print $2; exit }' <<<"$gout")"
    else
      first="$(sed -n 1p <<<"$gout")"
      fail "ssh rejects $cfg" "${first:-ssh -G -F $cfg example.invalid exited non-zero}"
    fi
  fi

  kh="$dir/known_hosts"
  if [[ "$hk" != "yes" ]]; then
    skip "known_hosts: HashKnownHosts is not on in $cfg"
  elif [[ ! -f "$kh" ]]; then
    skip "known_hosts: no $kh"
  else
    n="$(awk "$PLAINTEXT_HOSTS_AWK" "$kh" 2>/dev/null)"
    if [[ "${n:-0}" -gt 0 ]]; then
      warn "$n plaintext host entries in known_hosts although HashKnownHosts is on" \
        "ssh-keygen -H -f $kh  (keeps $kh.old; then delete the .old file)"
    else
      pass "known_hosts holds no plaintext host"
    fi
  fi

  # ControlPath ~/.ssh/cm-%C with ControlPersist 10m: a socket older than a
  # day is a master that was killed rather than closed, and the next ssh to
  # that host fails with "Control socket connect: Connection refused". The
  # doctor finds them; it never connects to one or removes it.
  n="$(find "$dir" -maxdepth 1 -type s -name 'cm-*' -mmin +1440 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${n:-0}" -gt 0 ]]; then
    warn "$n ControlMaster socket(s) older than a day; ControlPersist is 10m, so unless a session has been open that long these are dead masters" \
      "rm $dir/cm-*  (or check one first: ssh -O check -S <socket> host)"
  else
    pass "no stale ControlMaster socket in $dir"
  fi
  return 0
}

# Every query reads the global scope as git would for the inspected home:
# HOME and XDG_CONFIG_HOME point at it and GIT_CONFIG_GLOBAL is dropped, so
# neither the caller's environment nor the real home decides the answer.
# --includes is required: --global alone does not follow include.path, and
# the identity lives in config.local. Only presence is reported, never a
# name or an address.
git_global() {
  env -u GIT_CONFIG_GLOBAL HOME="$HOME_DIR" XDG_CONFIG_HOME="$CONFIG_DIR" \
    git config --global --includes --get "$1" 2>/dev/null
}

check_git() {
  group "git"
  if ! command -v git >/dev/null 2>&1; then
    skip "git: not installed"
    return 0
  fi
  if [[ -n "$(git_global user.name)" && -n "$(git_global user.email)" ]]; then
    pass "a commit identity is set"
  else
    warn "no commit identity: user.name and user.email are not both set" \
      "git config --file $CONFIG_DIR/git/config.local user.name \"Your Name\""
  fi
  # Only meaningful once the tracked config is installed; without it a
  # ~/.gitconfig is simply where this user keeps their settings.
  if [[ ! -e "$CONFIG_DIR/git/config" ]]; then
    skip "gitconfig override: no $CONFIG_DIR/git/config installed"
  elif [[ -e "$HOME_DIR/.gitconfig" ]]; then
    warn "$HOME_DIR/.gitconfig exists: git reads it after $CONFIG_DIR/git/config, so it wins on every key and git config --global now writes there" \
      "move its contents to $CONFIG_DIR/git/config.local and delete it"
  else
    pass "no $HOME_DIR/.gitconfig overrides $CONFIG_DIR/git/config"
  fi
  return 0
}

# --- main ------------------------------------------------------------------
check_linked_configs
check_credential_files
check_environment_hooks
check_ssh
check_git

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
