#!/usr/bin/env bash
# ops_context.sh
# Which environment is this shell pointed at? One screen naming the current
# Kubernetes context and namespace, gcloud configuration, AWS profile,
# Terraform workspace, Docker context and GitHub CLI login.
#
# The outage this exists for is the right command against the wrong cluster,
# project, profile, workspace or daemon. zsh_aliases.zsh has switchers for
# some of these (kctx, kns, awsp); nothing reported all of them at once, and
# nothing could gate a command on "am I pointed at production". --warn-on
# does that:
#
#   ./ops_context.sh --warn-on prod,live --quiet && terraform apply
#
# Read-only and local. It reads config files and asks local CLI subcommands
# that answer from those files; nothing here contacts a network. It never
# opens ~/.aws/credentials and never prints a token or a key: for a secret
# set in the environment it names the variable, not the value. Every value
# taken from a config file is printed with control characters stripped, so a
# hostile kubeconfig cannot write terminal escapes through it.
#
# No log file. No sudo. Standalone — copy it into ~/bin.
#
# Usage:
#   ./ops_context.sh
#   ./ops_context.sh --only kube,aws
#   ./ops_context.sh --warn-on prod,live --quiet
#   ./ops_context.sh --list-tools
#
# Exit codes:
#   0   report printed and no --warn-on pattern matched
#   1   a --warn-on pattern matched, or --strict and any warning
#   2   not macOS, or HOME is not set
#   3   bad CLI arguments
#   4   --only selected nothing

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

ONLY=""
LIST_TOOLS=0
WARN_ON=""
DIR="."
STRICT=0
QUIET=0
WARNED=0
MATCHED=0

ALL_TOOLS="kube gcloud aws terraform docker gh"

usage() {
  cat <<EOF
${C_BOLD}ops_context.sh${C_RESET} — which environment is this shell pointed at?

Kubernetes context and namespace, gcloud configuration, AWS profile,
Terraform workspace, Docker context and GitHub CLI login, from local files
only. Read-only; never opens a credentials file or prints a token.

${C_BOLD}Usage:${C_RESET}
  $(basename "$0") [--only TOOLS] [--warn-on PATTERNS] [--dir DIR] [--strict] [--quiet]
  $(basename "$0") --list-tools

${C_BOLD}Options:${C_RESET}
  --only TOOLS        Comma-separated subset (see --list-tools)
  --warn-on PATTERNS  Comma-separated, case-insensitive substrings; a value
                      containing one is a warning and the exit code is 1
  --dir DIR           Where to look up the Terraform workspace (default: .)
  --strict            Exit 1 on any warning, not only on a --warn-on match
  --quiet             Print only warnings (silent means safe to continue)
  --list-tools        Print the tool ids and exit
  -h, --help          Show this help

${C_BOLD}Tools:${C_RESET}
  kube       kubectl current context, its namespace and cluster
  gcloud     active gcloud configuration: account, project, region
  aws        AWS profile, region, SSO session expiry, role and account
  terraform  Terraform workspace of --dir
  docker     Docker context and whether its daemon is remote
  gh         GitHub CLI hosts and logins

${C_BOLD}Example:${C_RESET}
  $(basename "$0") --warn-on prod,live --quiet && terraform apply

${C_BOLD}Exit codes:${C_RESET}
  0  report printed and no --warn-on pattern matched
  1  a --warn-on pattern matched, or --strict and any warning
  2  not macOS, or HOME is not set
  3  invalid arguments
  4  --only selected nothing
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

while (( $# > 0 )); do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    --list-tools) LIST_TOOLS=1 ;;
    --only)       require_value "$1" "${2:-}"; ONLY="$2"; shift ;;
    --only=*)     ONLY="${1#*=}"; require_value "--only" "$ONLY" ;;
    --warn-on)    require_value "$1" "${2:-}"; WARN_ON="$2"; shift ;;
    --warn-on=*)  WARN_ON="${1#*=}"; require_value "--warn-on" "$WARN_ON" ;;
    --dir)        require_value "$1" "${2:-}"; DIR="$2"; shift ;;
    --dir=*)      DIR="${1#*=}"; require_value "--dir" "$DIR" ;;
    --strict)     STRICT=1 ;;
    --quiet)      QUIET=1 ;;
    *)            err "unknown option: $1"; usage >&2; exit 3 ;;
  esac
  shift
done

if (( LIST_TOOLS )); then
  # shellcheck disable=SC2086  # the id list is split on purpose
  printf '%s\n' $ALL_TOOLS
  exit 0
fi

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Config values are data. Strip every control character, ESC included, so a
# context name cannot move the cursor or recolour the terminal.
clean() { printf '%s' "$1" | tr -d '\000-\037\177'; }

SELECTED=()
if [[ -n "$ONLY" ]]; then
  IFS=',' read -r -a items <<< "$ONLY"
  for raw in ${items[@]+"${items[@]}"}; do
    id="$(printf '%s' "$raw" | tr -d '[:space:]')"
    [[ -n "$id" ]] || continue
    case " $ALL_TOOLS " in
      *" $id "*) SELECTED+=("$id") ;;
      *) err "unknown tool in --only: $id (see --list-tools)"; exit 3 ;;
    esac
  done
  if (( ${#SELECTED[@]} == 0 )); then
    err "--only selected nothing"
    exit 4
  fi
else
  for id in $ALL_TOOLS; do
    SELECTED+=("$id")
  done
fi

PATTERNS=()
if [[ -n "$WARN_ON" ]]; then
  IFS=',' read -r -a items <<< "$WARN_ON"
  for raw in ${items[@]+"${items[@]}"}; do
    p="$(lower "$(clean "$raw")")"
    p="${p#"${p%%[![:space:]]*}"}"
    p="${p%"${p##*[![:space:]]}"}"
    [[ -n "$p" ]] && PATTERNS+=("$p")
  done
  if (( ${#PATTERNS[@]} == 0 )); then
    err "--warn-on has no pattern in it: $WARN_ON"
    exit 3
  fi
fi

if [[ ! -d "$DIR" ]]; then
  err "--dir is not a directory: $DIR"
  exit 3
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  err "this script targets macOS (detected: $(uname -s))"
  exit 2
fi

if [[ -z "${HOME:-}" ]]; then
  err "HOME is not set; the config files this reads live under it"
  exit 2
fi

want() {
  local needle="$1" s
  for s in "${SELECTED[@]}"; do
    [[ "$s" == "$needle" ]] && return 0
  done
  return 1
}

# One line per finding, in status.sh's grammar: the tool id padded to ten
# columns, then what it is pointed at.
row() {
  local level="$1" id="$2" msg="$3" line
  line="$(printf '%-10s %s' "$id" "$msg")"
  case "$level" in
    ok)   (( QUIET )) || ok "$line" ;;
    info) (( QUIET )) || info "$line" ;;
    warn) WARNED=1; warn "$line" ;;
  esac
}

# The first --warn-on pattern contained in any argument, or nothing.
first_match() {
  local v lv p
  (( ${#PATTERNS[@]} > 0 )) || return 0
  for v in "$@"; do
    [[ -n "$v" ]] || continue
    lv="$(lower "$v")"
    for p in "${PATTERNS[@]}"; do
      if [[ "$lv" == *"$p"* ]]; then
        printf '%s' "$p"
        return 0
      fi
    done
  done
}

# judge ID LEVEL TEXT VALUE...: print a row at LEVEL, unless one of the
# VALUES contains a --warn-on pattern. Then the row is a warning naming the
# pattern, and the run exits 1.
judge() {
  local id="$1" level="$2" text="$3" p
  shift 3
  p="$(first_match "$@")"
  if [[ -n "$p" ]]; then
    MATCHED=1
    row warn "$id" "$text (matches \"$p\")"
  else
    row "$level" "$id" "$text"
  fi
}

# Value of KEY in [SECTION] of an INI-style FILE (gcloud configurations and
# ~/.aws/config share the shape). Prints nothing when either is absent.
ini_get() {
  local file="$1" section="$2" key="$3"
  [[ -r "$file" ]] || return 0
  awk -v sec="$section" -v key="$key" '
    /^[ \t]*\[/ {
      cur = $0
      sub(/^[ \t]*\[[ \t]*/, "", cur)
      sub(/[ \t]*\][ \t\r]*$/, "", cur)
      next
    }
    cur == sec && index($0, "=") > 0 {
      k = substr($0, 1, index($0, "=") - 1)
      gsub(/[ \t]/, "", k)
      if (k != key) next
      v = substr($0, index($0, "=") + 1)
      sub(/^[ \t]+/, "", v)
      sub(/[ \t\r]+$/, "", v)
      print v
      exit
    }' "$file" 2>/dev/null
}

# A name that is safe to paste into a printed command.
plain_word() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }

if (( QUIET == 0 )); then
  printf "%s=== ops context ===%s\n" "$C_BOLD" "$C_RESET"
fi

# --- kube --------------------------------------------------------------------
# kubectl answers these from the kubeconfig alone (KUBECONFIG is honoured
# because kubectl honours it). Only names are asked for, never user entries.
if want kube; then
  if ! command -v kubectl >/dev/null 2>&1; then
    row info kube "kubectl is not installed"
  else
    ctx="$(clean "$(kubectl config current-context 2>/dev/null)")"
    if [[ -z "$ctx" ]]; then
      row info kube "no current context"
    else
      ns="$(clean "$(kubectl config view --minify --output 'jsonpath={..namespace}' 2>/dev/null)")"
      [[ -n "$ns" ]] || ns="default"
      cluster="$(clean "$(kubectl config view --minify --output 'jsonpath={.contexts[0].context.cluster}' 2>/dev/null)")"
      text="$ctx  ns=$ns"
      if [[ -n "$cluster" && "$cluster" != "$ctx" ]]; then
        text="$text  cluster=$cluster"
      fi
      judge kube ok "$text" "$ctx" "$ns" "$cluster"
    fi
  fi
fi

# --- gcloud ------------------------------------------------------------------
# Files only: starting the gcloud CLI costs a second or more of Python start-up
# and can try to refresh credentials. The active configuration is a file name
# under configurations/, so its name is validated before it is used in a path.
if want gcloud; then
  gdir="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}"
  gname="${CLOUDSDK_ACTIVE_CONFIG_NAME:-}"
  if [[ -z "$gname" && -r "$gdir/active_config" ]]; then
    gname="$(head -n 1 "$gdir/active_config" 2>/dev/null | tr -d '\r')"
  fi
  [[ -n "$gname" ]] || gname="default"
  if ! plain_word "$gname" || [[ "$gname" == .* ]]; then
    row warn gcloud "active configuration name is not valid: $(clean "$gname")"
  elif [[ ! -d "$gdir" ]]; then
    row info gcloud "no gcloud configuration ($gdir)"
  else
    gfile="$gdir/configurations/config_$gname"
    if [[ ! -r "$gfile" ]]; then
      row info gcloud "configuration $gname has no file ($gfile)"
    else
      gaccount="$(clean "$(ini_get "$gfile" core account)")"
      gproject="$(clean "$(ini_get "$gfile" core project)")"
      gregion="$(clean "$(ini_get "$gfile" compute region)")"
      text="config=$gname project=${gproject:-unset} account=${gaccount:-unset}"
      [[ -n "$gregion" ]] && text="$text region=$gregion"
      judge gcloud ok "$text" "$gname" "$gproject" "$gaccount"
    fi
  fi
fi

# --- aws ---------------------------------------------------------------------
# ~/.aws/config holds profile names, regions and role ARNs; ~/.aws/credentials
# holds secrets and is never opened. For an SSO profile the cached token's
# expiresAt is compared as text with the current UTC time: both are ISO-8601
# to the second, so the lexical order is the time order and no date parsing
# (which differs between BSD and GNU date) is needed.
if want aws; then
  aprofile="${AWS_PROFILE:-${AWS_DEFAULT_PROFILE:-default}}"
  aprofile="$(clean "$aprofile")"
  aconfig="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
  if [[ "$aprofile" == "default" ]]; then
    asection="default"
  else
    asection="profile $aprofile"
  fi
  astanza=0
  if [[ -r "$aconfig" ]] && grep -qF "[$asection]" "$aconfig" 2>/dev/null; then
    astanza=1
  fi
  aregion="$(clean "$(ini_get "$aconfig" "$asection" region)")"
  asso="$(clean "$(ini_get "$aconfig" "$asection" sso_session)")"
  asso_url="$(clean "$(ini_get "$aconfig" "$asection" sso_start_url)")"
  aaccount="$(clean "$(ini_get "$aconfig" "$asection" sso_account_id)")"
  arole="$(clean "$(ini_get "$aconfig" "$asection" role_arn)")"

  text="profile=$aprofile"
  [[ -n "$aregion" ]] && text="$text region=$aregion"
  [[ -n "$aaccount" ]] && text="$text account=$aaccount"
  [[ -n "$arole" ]] && text="$text role=$arole"
  if (( astanza )); then
    judge aws ok "$text" "$aprofile" "$arole" "$aaccount"
  elif [[ "$aprofile" == "default" ]]; then
    judge aws info "$text (no [default] stanza in $aconfig)" "$aprofile"
  else
    judge aws warn "$text (profile $aprofile is not in $aconfig)" "$aprofile"
  fi

  if [[ -n "$asso" || -n "$asso_url" ]]; then
    # The login that belongs to this profile is the cached token whose
    # startUrl is the profile's (or its sso-session's). Without a start URL
    # to match, the newest login is all there is, and the row says so.
    if [[ -z "$asso_url" && -n "$asso" ]]; then
      asso_url="$(clean "$(ini_get "$aconfig" "sso-session $asso" sso_start_url)")"
    fi
    newest=""
    scope_note=""
    [[ -z "$asso_url" ]] && scope_note=" (most recent login)"
    for f in "$HOME/.aws/sso/cache/"*.json; do
      [[ -f "$f" ]] || continue
      # The cache also holds client registrations, which carry an expiresAt
      # of their own; only a file with an access token is a login.
      grep -q '"accessToken"' "$f" 2>/dev/null || continue
      if [[ -n "$asso_url" ]]; then
        grep -qF "\"startUrl\": \"$asso_url\"" "$f" 2>/dev/null \
          || grep -qF "\"startUrl\":\"$asso_url\"" "$f" 2>/dev/null || continue
      fi
      if [[ -z "$newest" || "$f" -nt "$newest" ]]; then
        newest="$f"
      fi
    done
    login_hint="aws sso login"
    plain_word "$aprofile" && login_hint="aws sso login --profile $aprofile"
    if [[ -z "$newest" ]]; then
      row info aws "no cached SSO login  fix: $login_hint"
    else
      expires="$(sed -n 's/.*"expiresAt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$newest" 2>/dev/null | head -n 1)"
      expires="${expires:0:19}"
      now="$(date -u +%Y-%m-%dT%H:%M:%S)"
      if [[ ! "$expires" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
        row info aws "could not read the SSO session expiry"
      elif [[ "$expires" < "$now" ]]; then
        row warn aws "sso session expired at ${expires}Z${scope_note}  fix: $login_hint"
      else
        row ok aws "sso session valid until ${expires}Z${scope_note}"
      fi
    fi
  fi

  # Static keys in the environment win over every profile setting, so the
  # profile printed above is not what a CLI call would use.
  if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
    row warn aws "AWS_ACCESS_KEY_ID is set in the environment; static keys override profile $aprofile"
  fi
fi

# --- terraform ---------------------------------------------------------------
# The workspace is per working directory: TF_WORKSPACE overrides the file
# terraform init writes under .terraform/.
if want terraform; then
  tfdir="${DIR%/}"
  [[ -n "$tfdir" ]] || tfdir="/"
  has_tf=0
  if [[ -d "$tfdir/.terraform" ]]; then
    has_tf=1
  else
    for f in "$tfdir"/*.tf; do
      [[ -e "$f" ]] && { has_tf=1; break; }
    done
  fi
  if [[ -n "${TF_WORKSPACE:-}" ]]; then
    ws="$(clean "$TF_WORKSPACE")"
    judge terraform ok "workspace=$ws (TF_WORKSPACE)" "$ws"
  elif (( has_tf == 0 )); then
    row info terraform "no Terraform directory here ($tfdir)"
  else
    ws=""
    if [[ -r "$tfdir/.terraform/environment" ]]; then
      ws="$(clean "$(head -n 1 "$tfdir/.terraform/environment" 2>/dev/null)")"
    fi
    [[ -n "$ws" ]] || ws="default"
    judge terraform ok "workspace=$ws ($tfdir)" "$ws"
  fi
fi

# --- docker ------------------------------------------------------------------
# A context whose endpoint is not a local socket sends `docker system prune`
# and friends to somebody else's daemon. DOCKER_HOST overrides any context.
if want docker; then
  if [[ -n "${DOCKER_HOST:-}" ]]; then
    dhost="$(clean "$DOCKER_HOST")"
    case "$dhost" in
      unix://*) judge docker ok "DOCKER_HOST=$dhost" "$dhost" ;;
      *)        judge docker warn "remote Docker daemon: DOCKER_HOST=$dhost overrides every context" "$dhost" ;;
    esac
  elif ! command -v docker >/dev/null 2>&1; then
    row info docker "docker is not installed"
  else
    dctx="${DOCKER_CONTEXT:-}"
    [[ -n "$dctx" ]] || dctx="$(docker context show 2>/dev/null)"
    dctx="$(clean "$dctx")"
    if [[ -z "$dctx" ]]; then
      row info docker "no Docker context"
    else
      dhost="$(clean "$(docker context inspect "$dctx" --format '{{ (index .Endpoints "docker").Host }}' 2>/dev/null)")"
      case "$dhost" in
        unix://*|"")
          judge docker ok "context=$dctx${dhost:+  $dhost}" "$dctx" "$dhost" ;;
        *)
          judge docker warn "remote Docker daemon: context=$dctx  $dhost" "$dctx" "$dhost" ;;
      esac
    fi
  fi
fi

# --- gh ----------------------------------------------------------------------
# hosts.yml is read for host names and the user: line only; the token lines
# beside them are skipped by the parser and never printed.
if want gh; then
  ghdir="${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}"
  ghfile="$ghdir/hosts.yml"
  if [[ ! -r "$ghfile" ]]; then
    row info gh "no GitHub CLI login ($ghfile)"
  else
    logins="$(awk '
      /^[^ \t#][^:]*:[ \t\r]*$/ { host = $0; sub(/:[ \t\r]*$/, "", host); next }
      /^[ \t]+user:[ \t]*/ && host != "" {
        u = $0
        sub(/^[ \t]+user:[ \t]*/, "", u)
        gsub(/["\r]/, "", u)
        printf "%s%s as %s", sep, host, u
        sep = ", "
        host = ""
      }' "$ghfile" 2>/dev/null)"
    logins="$(clean "$logins")"
    if [[ -z "$logins" ]]; then
      row info gh "no logged-in host in $ghfile"
    else
      judge gh ok "$logins" "$logins"
    fi
  fi
  if [[ -n "${GH_TOKEN:-}" ]]; then
    row warn gh "GH_TOKEN is set in the environment; it overrides the stored login"
  fi
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    row warn gh "GITHUB_TOKEN is set in the environment; it overrides the stored login"
  fi
fi

if (( MATCHED )); then
  exit 1
fi
if (( STRICT )) && (( WARNED )); then
  exit 1
fi
exit 0
