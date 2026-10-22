#!/usr/bin/env bash
# toolchain_check.sh
# Does this checkout's pinned Python, Terraform, Go and Node exist on this
# Mac, and is the pin the version that actually runs?
#
# install_devtools.sh installs pyenv, tfenv or tenv, goenv and mise side by
# side. That only pays off when each repository's pin file resolves to
# something installed, and today the way to find out is a failing
# `terraform init` or a shim error halfway through a task. This reads the pin
# files in one directory, asks the version managers what they have, and
# prints per tool: ok, not installed (with the command that installs it), or
# installed but not the active binary.
#
# Read-only. It never installs anything and never sources or evaluates a pin
# file: a pin is data, and a value that is not a plain version number is
# reported and never pasted into a printed command. The active-version probes
# run only for a pin that is installed, with every auto-install switch the
# managers have turned off, and `go version` runs with GOTOOLCHAIN=local, so
# no probe can download a toolchain.
#
# No log file. No sudo. Standalone — copy it into ~/bin.
#
# Usage:
#   ./toolchain_check.sh                # the current directory
#   ./toolchain_check.sh ~/src/infra    # or --dir ~/src/infra
#   ./toolchain_check.sh --strict       # an inactive pin is a failure too
#   ./toolchain_check.sh --list-pins
#
# Exit codes:
#   0   every pin is satisfied
#   1   a pinned version is not installed (or, with --strict, a warning)
#   2   not macOS
#   3   bad CLI arguments, or DIR is not a directory
#   4   no pin file in DIR

set -u
set -o pipefail

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_RED=$'\033[1;31m'
  C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'
  C_BLUE=$'\033[1;34m'
else
  C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''
fi

ok()   { printf "%s[ ok ]%s %s\n"  "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf "%s[warn]%s %s\n"  "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf "%s[err ]%s %s\n"  "$C_RED"    "$C_RESET" "$*" >&2; }
info() { printf "%s[info]%s %s\n"  "$C_BLUE"   "$C_RESET" "$*"; }

DIR=""
LIST_PINS=0
STRICT=0
QUIET=0
PINS_FOUND=0
MISSING=0
WARNED=0

PIN_FILES=".python-version .terraform-version .go-version go.mod .tool-versions .nvmrc .node-version"

usage() {
  cat <<EOF
${C_BOLD}toolchain_check.sh${C_RESET} — are this checkout's pinned toolchains installed and active?

Reads the pin files in one directory and asks pyenv, tfenv or tenv, goenv,
mise and node what is installed. Read-only: never installs, never evaluates
a pin file.

${C_BOLD}Usage:${C_RESET}
  $(basename "$0") [DIR | --dir DIR] [--strict] [--quiet]
  $(basename "$0") --list-pins

${C_BOLD}Options:${C_RESET}
  --dir DIR      Directory holding the pin files (default: .)
  --strict       Exit 1 on any warning, including a pin that is installed
                 but not the active binary
  --quiet        Print only warnings
  --list-pins    Print the pin file names this reads and exit
  -h, --help     Show this help

${C_BOLD}Pin files:${C_RESET}
  python     .python-version, .tool-versions (python)
  terraform  .terraform-version, .tool-versions (terraform)
  go         .go-version, go.mod (toolchain, else the go minimum),
             .tool-versions (golang)
  node       .nvmrc, .node-version, .tool-versions (nodejs); major only

${C_BOLD}Exit codes:${C_RESET}
  0  every pin is satisfied
  1  a pinned version is not installed (or, with --strict, any warning)
  2  not macOS
  3  invalid arguments, or DIR is not a directory
  4  no pin file in DIR
EOF
}

require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    err "$option requires a value"
    exit 3
  fi
}

set_dir() {
  if [[ -n "$DIR" ]]; then
    err "only one directory, got: $DIR and $1"
    exit 3
  fi
  DIR="$1"
}

while (( $# > 0 )); do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    --list-pins)  LIST_PINS=1 ;;
    --dir)        require_value "$1" "${2:-}"; set_dir "$2"; shift ;;
    --dir=*)      require_value "--dir" "${1#*=}"; set_dir "${1#*=}" ;;
    --strict)     STRICT=1 ;;
    --quiet)      QUIET=1 ;;
    -*)           err "unknown option: $1"; usage >&2; exit 3 ;;
    *)            set_dir "$1" ;;
  esac
  shift
done

if (( LIST_PINS )); then
  # shellcheck disable=SC2086  # the name list is split on purpose
  printf '%s\n' $PIN_FILES
  exit 0
fi

[[ -n "$DIR" ]] || DIR="."
if [[ ! -d "$DIR" ]]; then
  err "not a directory: $DIR"
  exit 3
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  err "this script targets macOS (detected: $(uname -s))"
  exit 2
fi

# Text from a pin file is data: control characters are stripped before it is
# printed anywhere.
clean() { printf '%s' "$1" | tr -d '\000-\037\177'; }

row() {
  local level="$1" id="$2" msg="$3" line
  line="$(printf '%-10s %s' "$id" "$msg")"
  case "$level" in
    ok)   (( QUIET )) || ok "$line" ;;
    info) (( QUIET )) || info "$line" ;;
    warn) WARNED=1; warn "$line" ;;
  esac
}

# A version that may be pasted into a printed command: digits, letters, dots
# and the few separators version strings use, never leading with a dash.
plain_version() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; }

# Is the version a prerelease (rc, beta, alpha, pre)?
is_prerelease() {
  local v
  v="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [[ "$v" =~ [0-9.+-](rc|beta|alpha|pre) ]]
}

# Prerelease rank and number of a version as "RANK NUMBER" (alpha < beta <
# pre < rc), so rc1 sorts below rc2; "0 0" when it is not a prerelease.
prerelease_key() {
  local v rank
  v="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  if [[ "$v" =~ [0-9.+-](rc|beta|alpha|pre)[.-]?([0-9]*) ]]; then
    case "${BASH_REMATCH[1]}" in
      alpha) rank=1 ;;
      beta)  rank=2 ;;
      pre)   rank=3 ;;
      *)     rank=4 ;;
    esac
    printf '%s %s\n' "$rank" "$((10#${BASH_REMATCH[2]:-0}))"
  else
    printf '0 0\n'
  fi
}

# ver_ge A B: is the dotted version A at least B? Compared numerically per
# component, so 1.10 is newer than 1.9; a missing component counts as 0. A
# prerelease (rc, beta, alpha, pre) is older than the same release, so 1.22rc1
# does not meet a 1.22.0 minimum, and rc1 is older than rc2; any other suffix
# is ignored.
ver_ge() {
  local i x y
  local IFS=.
  local -a pa pb
  read -r -a pa <<< "$1"
  read -r -a pb <<< "$2"
  for i in 0 1 2; do
    x="${pa[$i]:-0}"; y="${pb[$i]:-0}"
    x="${x%%[!0-9]*}"; y="${y%%[!0-9]*}"
    x="${x:-0}"; y="${y:-0}"
    if (( 10#$x > 10#$y )); then return 0; fi
    if (( 10#$x < 10#$y )); then return 1; fi
  done
  if is_prerelease "$1" || is_prerelease "$2"; then
    local ka kb ra na rb nb
    ka="$(prerelease_key "$1")"; kb="$(prerelease_key "$2")"
    ra="${ka% *}"; na="${ka#* }"; rb="${kb% *}"; nb="${kb#* }"
    # A release (rank 0) outranks every prerelease of it.
    (( ra == 0 )) && ra=9
    (( rb == 0 )) && rb=9
    if (( ra < rb )); then return 1; fi
    if (( ra == rb && na < nb )); then return 1; fi
  fi
  return 0
}

# Does an installed version satisfy the pin? exact: equal, or the pin is a
# prefix at a dot boundary (3.12 is met by 3.12.5); minimum: at least the pin;
# major: same leading number.
satisfies() {
  local have="$1" pin="$2" kind="$3"
  have="${have#v}"
  case "$kind" in
    exact)   [[ "$have" == "$pin" || "$have" == "$pin".* ]] ;;
    minimum) ver_ge "$have" "$pin" ;;
    major)   [[ "${have%%.*}" == "${pin%%.*}" ]] ;;
    *)       return 1 ;;
  esac
}

# First non-comment line of a pin file, CR and surrounding space removed.
first_line() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [[ -n "$line" ]]; then
      printf '%s\n' "$line"
      return 0
    fi
  done < "$1"
}

# The versions .tool-versions lists for the first of the given tool names.
tool_versions() {
  local file="$DIR/.tool-versions" line name rest t
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line%%#*}"
    name=""; rest=""
    read -r name rest <<< "$line"
    for t in "$@"; do
      if [[ "$name" == "$t" && -n "$rest" ]]; then
        printf '%s\n' "$rest"
        return 0
      fi
    done
  done < "$file"
}

# The go.mod pin: the toolchain line is an exact version; without one, the go
# line is the minimum the module accepts.
gomod_pin() {
  local file="$DIR/go.mod" v
  [[ -f "$file" ]] || return 0
  v="$(sed -n 's/^toolchain[[:space:]]\{1,\}go\([^[:space:]]*\).*/\1/p' "$file" | head -n 1 | tr -d '\r')"
  if [[ -n "$v" ]]; then
    printf 'exact %s\n' "$v"
    return 0
  fi
  v="$(sed -n 's/^go[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p' "$file" | head -n 1 | tr -d '\r')"
  [[ -n "$v" ]] && printf 'minimum %s\n' "$v"
  return 0
}

HAVE_MISE=0
command -v mise >/dev/null 2>&1 && HAVE_MISE=1

# Installed versions from a manager, one per line. tfenv marks the selected
# version with "*" and appends "(set by ...)"; both are stripped.
installed_versions() {
  case "$1" in
    pyenv) pyenv versions --bare 2>/dev/null ;;
    goenv) goenv versions --bare 2>/dev/null ;;
    tfenv) tfenv list 2>/dev/null | sed -e 's/^[[:space:]*]*//' -e 's/[[:space:]].*$//' ;;
    tenv)  tenv tf list 2>/dev/null | sed -e 's/^[[:space:]*]*//' -e 's/[[:space:]].*$//' ;;
  esac
}

# The version the shim or binary on PATH reports when run from DIR. Every
# auto-install switch is off and Terraform's update check is disabled, so a
# probe answers from what is already on disk.
active_version() {
  local out=""
  case "$1" in
    python)
      command -v python >/dev/null 2>&1 || return 0
      out="$(cd "$DIR" && python --version 2>&1 | head -n 1)"
      out="${out#Python }"
      ;;
    terraform)
      command -v terraform >/dev/null 2>&1 || return 0
      out="$(cd "$DIR" && CHECKPOINT_DISABLE=1 TFENV_AUTO_INSTALL=false \
        MISE_NOT_FOUND_AUTO_INSTALL=false terraform version 2>/dev/null | head -n 1)"
      out="${out#Terraform v}"
      ;;
    go)
      command -v go >/dev/null 2>&1 || return 0
      out="$(cd "$DIR" && GOTOOLCHAIN=local MISE_NOT_FOUND_AUTO_INSTALL=false \
        go version 2>/dev/null | head -n 1)"
      out="${out#go version go}"
      out="${out%% *}"
      ;;
    node)
      command -v node >/dev/null 2>&1 || return 0
      out="$(cd "$DIR" && MISE_NOT_FOUND_AUTO_INSTALL=false node --version 2>/dev/null | head -n 1)"
      out="${out#v}"
      ;;
  esac
  out="$(clean "$out")"
  plain_version "$out" && printf '%s\n' "$out"
  return 0
}

# The manager this tool is checked against on this Mac, or nothing.
manager_for() {
  case "$1" in
    python)    command -v pyenv >/dev/null 2>&1 && printf 'pyenv\n' ;;
    terraform)
      if command -v tfenv >/dev/null 2>&1; then printf 'tfenv\n'
      elif command -v tenv >/dev/null 2>&1; then printf 'tenv\n'
      fi
      ;;
    go)        command -v goenv >/dev/null 2>&1 && printf 'goenv\n' ;;
  esac
  return 0
}

# The command that installs VERSION of TOOL, for a pin already validated by
# plain_version.
install_hint() {
  local tool="$1" ver="$2" mgr="$3" src="$4"
  if (( HAVE_MISE )) && [[ "$src" == ".tool-versions" ]]; then
    printf 'mise install %s@%s' "$(mise_name "$tool")" "$ver"
    return 0
  fi
  case "$tool" in
    python)
      printf 'pyenv install %s   or: ./install_devtools.sh --only python --python-version %s' "$ver" "$ver" ;;
    terraform)
      if [[ "$mgr" == "tenv" ]]; then
        printf 'tenv tf install %s' "$ver"
      else
        printf 'tfenv install %s   or: ./install_devtools.sh --only terraform --terraform-version %s' "$ver" "$ver"
      fi
      ;;
    go)
      printf 'goenv install %s   or: ./install_devtools.sh --only go --go-version %s' "$ver" "$ver" ;;
    node)
      printf 'nvm install %s   or: mise install node@%s' "$ver" "$ver" ;;
  esac
}

mise_name() {
  case "$1" in
    python|terraform|go|node) printf '%s' "$1" ;;
  esac
}

# Every version a pin file lists, on one line: pyenv allows several, one per
# line or separated by whitespace, with # comments. Blank and comment-only
# lines are dropped.
all_versions() {
  local line out=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] && out="${out:+$out }$line"
  done < "$1"
  printf '%s\n' "$out"
}

# check_pin TOOL VERSION SOURCE KIND PROBE_ACTIVE
check_pin() {
  local tool="$1" raw="$2" src="$3" kind="$4" probe="$5"
  local ver mgr via="" have="" shown active bin
  ver="$(clean "$raw")"
  ver="${ver#v}"
  case "$ver" in
    system|latest|lts|lts/*|stable|node|"")
      row info "$tool" "pin '$ver' in $src names no version; not checked"
      return 0
      ;;
  esac
  if ! plain_version "$ver"; then
    row info "$tool" "pin in $src is not a plain version number; not checked"
    return 0
  fi
  shown="$ver"
  [[ "$kind" == "minimum" ]] && shown=">= $ver"

  if (( HAVE_MISE )) && mise where "$(mise_name "$tool")@$ver" >/dev/null 2>&1; then
    via="mise"
  fi
  mgr="$(manager_for "$tool")"
  if [[ -z "$via" && -n "$mgr" ]]; then
    while IFS= read -r have; do
      [[ -n "$have" ]] || continue
      if satisfies "$have" "$ver" "$kind"; then
        via="$mgr $(clean "$have")"
        break
      fi
    done <<< "$(installed_versions "$mgr")"
  fi
  # Without a manager, the binary on PATH is the only installation there is:
  # good enough for a go.mod minimum or a Node major, not for an exact pin.
  if [[ -z "$via" ]] && [[ "$kind" == "minimum" || "$kind" == "major" ]]; then
    active="$(active_version "$tool")"
    if [[ -n "$active" ]] && satisfies "$active" "$ver" "$kind"; then
      via="$tool $active on PATH"
    fi
  fi

  if [[ -n "$via" ]]; then
    row ok "$tool" "$shown   ($src, $via)"
  elif [[ -z "$mgr" && "$tool" != "node" ]] && (( HAVE_MISE == 0 )); then
    MISSING=1
    case "$tool" in
      python)    row warn "$tool" "$ver pinned in $src, but pyenv is not installed   fix: ./install_devtools.sh --only python" ;;
      terraform) row warn "$tool" "$ver pinned in $src, but neither tfenv nor tenv is installed   fix: ./install_devtools.sh --only terraform" ;;
      go)        row warn "$tool" "$ver pinned in $src, but goenv is not installed   fix: ./install_devtools.sh --only go" ;;
    esac
    return 0
  else
    MISSING=1
    row warn "$tool" "$shown not installed   fix: $(install_hint "$tool" "$ver" "$mgr" "$src")"
    return 0
  fi

  (( probe )) || return 0
  active="$(active_version "$tool")"
  [[ -n "$active" ]] || return 0
  if ! satisfies "$active" "$ver" "$kind"; then
    bin="$(command -v "$tool" 2>/dev/null)"
    row warn "$tool" "pin $ver is installed but the active binary is $active ($(clean "$bin")) - is the ${via%% *} shim ahead of it on PATH?"
  fi
}

# check_tool TOOL: find its pin, the first source wins, and check every
# version that source lists. Any later source is noted, not checked.
check_tool() {
  local tool="$1" src="" kind="exact" versions="" other="" v first=1 gm
  case "$tool" in
    python)
      if [[ -f "$DIR/.python-version" ]]; then
        src=".python-version"; versions="$(all_versions "$DIR/.python-version")"
        [[ -n "$(tool_versions python)" ]] && other=".tool-versions"
      else
        versions="$(tool_versions python)"; [[ -n "$versions" ]] && src=".tool-versions"
      fi
      ;;
    terraform)
      if [[ -f "$DIR/.terraform-version" ]]; then
        src=".terraform-version"; versions="$(first_line "$DIR/.terraform-version")"
        [[ -n "$(tool_versions terraform)" ]] && other=".tool-versions"
      else
        versions="$(tool_versions terraform)"; [[ -n "$versions" ]] && src=".tool-versions"
      fi
      ;;
    go)
      gm="$(gomod_pin)"
      if [[ -f "$DIR/.go-version" ]]; then
        src=".go-version"; versions="$(first_line "$DIR/.go-version")"
        [[ -n "$gm" ]] && other="go.mod"
      elif [[ -n "$gm" ]]; then
        src="go.mod"; kind="${gm%% *}"; versions="${gm#* }"
      else
        versions="$(tool_versions golang go)"; [[ -n "$versions" ]] && src=".tool-versions"
      fi
      [[ "$src" != ".tool-versions" && -n "$(tool_versions golang go)" ]] && other="${other:+$other, }.tool-versions"
      ;;
    node)
      if [[ -f "$DIR/.nvmrc" ]]; then
        src=".nvmrc"; versions="$(first_line "$DIR/.nvmrc")"
      elif [[ -f "$DIR/.node-version" ]]; then
        src=".node-version"; versions="$(first_line "$DIR/.node-version")"
      else
        versions="$(tool_versions nodejs node)"; [[ -n "$versions" ]] && src=".tool-versions"
      fi
      kind="major"
      ;;
  esac
  [[ -n "$src" ]] || return 0
  PINS_FOUND=$((PINS_FOUND + 1))
  if [[ -z "$versions" ]]; then
    row info "$tool" "$src is empty; not checked"
    return 0
  fi
  # Word-split on purpose: one line may list several versions. read -a does
  # it without globbing.
  local -a list
  read -r -a list <<< "$versions"
  for v in ${list[@]+"${list[@]}"}; do
    check_pin "$tool" "$v" "$src" "$kind" "$first"
    first=0
  done
  [[ -n "$other" ]] && row info "$tool" "also pinned in $other; $src is the one checked"
  return 0
}

if (( QUIET == 0 )); then
  printf "%s=== toolchain pins in %s ===%s\n" "$C_BOLD" "$(clean "$DIR")" "$C_RESET"
fi

for tool in python terraform go node; do
  check_tool "$tool"
done

if (( PINS_FOUND == 0 )); then
  (( QUIET )) || info "no pin file in $(clean "$DIR") (see --list-pins)"
  exit 4
fi
if (( MISSING )); then
  exit 1
fi
if (( STRICT )) && (( WARNED )); then
  exit 1
fi
exit 0
