#!/usr/bin/env bash
# hardening_audit.sh
# Read-only security audit of a Mac.
#
# The macOS half of linux/hardening_audit.sh, down to the flags and the exit
# codes. Same posture, too: it reports and never changes anything. There is no
# --apply and no --fix, because every finding below has a context where the
# "insecure" answer is the correct one — SIP disabled on a kernel-extension
# development machine, Remote Login on for a box you actually ssh into. A
# script that auto-hardened would be wrong often enough to be dangerous, so
# this one hands you the finding and the command, and you decide.
#
# It is the security half of a pair with workstation_doctor.sh, which reports
# the same machine's health. Where they overlap — FileVault, SIP, Gatekeeper —
# the doctor states what it found and this grades it.
#
# Checks are grouped; use --only to run a subset and --list-groups to see them.
#
# The secrets group looks at where the credentials on a DevOps laptop sit:
# whether a credential file is readable by other local users, and whether a
# secret is stored as plain text where a Keychain-backed alternative exists.
# It names the file and the class of finding, never a value.
#
# --json prints the same findings as one JSON object on stdout and nothing
# else, for an MDM extension attribute, a fleet check or a CI gate. The exit
# code is unchanged and part of the contract: read $? as well as the
# document. The schema is versioned ("schema": 1):
#
#   {"schema":1,"script":"hardening_audit.sh","host":"...","generated":"...Z",
#    "fail_on":"fail|warn","summary":{"pass":N,"warn":N,"fail":N,"skip":N},
#    "needs_root_hint":true|false,"findings":[{"group":"lock",
#    "verdict":"pass|warn|fail|skip","check":"...","fix":"..."|null}]}
#
# --quiet drops pass and skip records from findings; the summary still counts
# every check.
#
# Exit codes:
#   0   no findings at or above the failure threshold
#   1   one or more findings at or above the threshold
#   2   preflight checks failed
#   3   bad CLI arguments
set -u
set -o pipefail

ONLY=""
FAIL_ON="fail"
QUIET=0
JSON=0
FINDINGS=""
CUR_GROUP=""

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
fi
info() { printf "%s[info]%s %s\n" "$C_BLUE"   "$C_RESET" "$*"; }
err()  { printf "%s[err ]%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# A JSON string. Backslash and double quote are escaped, newline, tab and CR
# become spaces, and every other control character (ESC included) is dropped,
# so whatever a probe printed, the document stays valid. sed and tr only:
# jq and python are not on a stock Mac.
json_str() {
  printf '"%s"' "$(printf '%s' "$1" | tr '\n\t\r' '   ' | tr -d '\000-\037\177' \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
}

# Under --json every finding becomes a record instead of a line. --quiet keeps
# its meaning: pass and skip records are left out, the counters are not.
record() {
  (( JSON )) || return 0
  local verdict="$1" check="$2" fix="${3:-}" fix_json="null"
  if (( QUIET )) && [[ "$verdict" == "pass" || "$verdict" == "skip" ]]; then
    return 0
  fi
  [[ -n "$fix" ]] && fix_json="$(json_str "$fix")"
  FINDINGS="$FINDINGS${FINDINGS:+,}{\"group\":$(json_str "$CUR_GROUP"),\"verdict\":\"$verdict\",\"check\":$(json_str "$check"),\"fix\":$fix_json}"
  return 0
}

# A finding is one line: verdict, what was checked, and — when it is not a
# pass — what to do about it. The fix is printed rather than run.
pass() { PASS_COUNT=$((PASS_COUNT + 1)); record pass "$1"; (( QUIET || JSON )) || printf "  %s[pass]%s %s\n" "$C_GREEN" "$C_RESET" "$1"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); record warn "$1" "${2:-}"; (( JSON )) && return 0; printf "  %s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$1"; [[ -n "${2:-}" ]] && printf "         %s%s%s\n" "$C_DIM" "$2" "$C_RESET"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); record fail "$1" "${2:-}"; (( JSON )) && return 0; printf "  %s[FAIL]%s %s\n" "$C_RED" "$C_RESET" "$1"; [[ -n "${2:-}" ]] && printf "         %s%s%s\n" "$C_DIM" "$2" "$C_RESET"; }
skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); record skip "$1"; (( QUIET || JSON )) || printf "  %s[skip]%s %s\n" "$C_DIM" "$C_RESET" "$1"; }

usage() {
  cat <<EOF
hardening_audit.sh - read-only security audit of a Mac

Reports findings and the command that would fix each one. Changes nothing.

Usage:
  $(basename "$0") [--only GROUPS] [--fail-on warn|fail] [--quiet] [--json]

Options:
  --only GROUPS    Comma-separated subset (see --list-groups)
  --fail-on LEVEL  Exit 1 on 'fail' (default) or on 'warn' and above
  --quiet          Print only warnings and failures
  --json           Print one JSON object instead of the report; the exit
                   code is unchanged
  --list-groups    Print the group names and exit
  --help, -h       Show this help

Groups:
  sharing    Remote Login, Screen Sharing, File Sharing
  firewall   Application Firewall state and stealth mode
  updates    Automatic check, download and install of macOS updates
  disk       FileVault full-disk encryption
  lock       Password requirement after display sleep / screen saver
  sip        System Integrity Protection
  gatekeeper Gatekeeper assessments
  secrets    Credential files: permissions and plaintext tokens

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

ALL_GROUPS="sharing firewall updates disk lock sip gatekeeper secrets"

while (( $# > 0 )); do
  case "$1" in
    --only)      require_value "$1" "${2:-}"; shift; ONLY="$1" ;;
    --only=*)    ONLY="${1#*=}"; require_value "--only" "$ONLY" ;;
    --fail-on)   require_value "$1" "${2:-}"; shift; FAIL_ON="$1" ;;
    --fail-on=*) FAIL_ON="${1#*=}"; require_value "--fail-on" "$FAIL_ON" ;;
    --quiet)     QUIET=1 ;;
    --json)      JSON=1 ;;
    --list-groups) printf '%s\n' $ALL_GROUPS; exit 0 ;;
    -h|--help)   usage; exit 0 ;;
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

if [[ -n "$ONLY" ]]; then
  IFS=',' read -r -a requested <<< "$ONLY"
  for g in "${requested[@]}"; do
    case " $ALL_GROUPS " in
      *" $g "*) ;;
      *) err "unknown group: $g (see --list-groups)"; exit 3 ;;
    esac
  done
fi

# The document is for a parser, whatever stdout is attached to.
if (( JSON )); then
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
fi

# --help and --list-groups are handled above so they work anywhere; the checks
# themselves call macOS-only tools.
if [[ "$(uname -s)" != "Darwin" ]]; then
  err "this script targets macOS"
  exit 2
fi

want() {
  [[ -z "$ONLY" ]] && return 0
  case ",$ONLY," in *",$1,"*) return 0 ;; esac
  return 1
}

group() { CUR_GROUP="$1"; (( JSON )) || printf "\n%s== %s ==%s\n" "$C_BOLD" "$1" "$C_RESET"; }

# A managed preference (MDM, configuration profile) or a plain plist value.
# Prints nothing when the key is unset, which for most of these means "macOS
# default" rather than "off".
pref() {
  local domain="$1" key="$2"
  defaults read "$domain" "$key" 2>/dev/null || true
}

# Is anything listening on this port, on an address other than loopback?
#
# The supported way to ask whether Remote Login is on is `systemsetup
# -getremotelogin`, which needs root, and an audit you have to sudo is an audit
# nobody runs. netstat answers unprivileged, and for these three services the
# listening socket *is* the service. Loopback-only binds are excluded: an ssh
# tunnel endpoint on 127.0.0.1 is not File Sharing switched on.
port_state() {
  local port="$1" out
  command -v netstat >/dev/null 2>&1 || { printf 'unknown\n'; return; }
  out="$(netstat -an -p tcp 2>/dev/null | awk -v p="[.]${port}\$" '
    $NF == "LISTEN" && $4 ~ p {
      addr = $4
      sub(/[.][0-9]+$/, "", addr)
      if (addr == "127.0.0.1" || addr == "::1") next
      found = 1
    }
    END { print (found ? "on" : "off") }')"
  printf '%s\n' "${out:-unknown}"
}

# --- sharing ---------------------------------------------------------------
if want sharing; then
  group "sharing"

  # systemsetup is authoritative but root-only; fall back to the port probe so
  # the check still answers as a normal user.
  rl="$(systemsetup -getremotelogin 2>/dev/null || true)"
  case "$rl" in
    *"Remote Login: On"*)  remote_login="on" ;;
    *"Remote Login: Off"*) remote_login="off" ;;
    *)                     remote_login="$(port_state 22)" ;;
  esac
  case "$remote_login" in
    off) pass "Remote Login (ssh) is off" ;;
    on)  warn "Remote Login (ssh) is on" \
              "fine if you ssh into this Mac; otherwise: sudo systemsetup -setremotelogin off" ;;
    *)   skip "could not determine whether Remote Login is on" ;;
  esac

  case "$(port_state 5900)" in
    off) pass "Screen Sharing is off" ;;
    on)  warn "Screen Sharing is on (port 5900 is listening)" \
              "System Settings > General > Sharing > Screen Sharing" ;;
    *)   skip "could not determine whether Screen Sharing is on" ;;
  esac

  case "$(port_state 445)" in
    off) pass "File Sharing is off" ;;
    on)  warn "File Sharing is on (port 445 is listening)" \
              "System Settings > General > Sharing > File Sharing" ;;
    *)   skip "could not determine whether File Sharing is on" ;;
  esac
fi

# --- firewall --------------------------------------------------------------
if want firewall; then
  group "firewall"
  SOCKETFILTERFW=/usr/libexec/ApplicationFirewall/socketfilterfw
  if [[ ! -x "$SOCKETFILTERFW" ]]; then
    skip "socketfilterfw not present"
  else
    # Captured and then matched rather than piped into `grep -q`: grep -q stops
    # reading at its first match, the producer dies of SIGPIPE, and under
    # `set -o pipefail` the pipeline reports 141. A false all-clear is the worst
    # thing this script can print.
    state="$("$SOCKETFILTERFW" --getglobalstate 2>/dev/null || true)"
    case "$state" in
      *"State = 1"*|*"State = 2"*|*"enabled"*)
        pass "Application Firewall is on"
        stealth="$("$SOCKETFILTERFW" --getstealthmode 2>/dev/null || true)"
        case "$stealth" in
          *"mode is on"*|*"enabled"*)
            pass "stealth mode is on" ;;
          *"mode is off"*|*"disabled"*)
            warn "stealth mode is off" \
                 "the Mac answers pings and probes to closed ports: sudo $SOCKETFILTERFW --setstealthmode on" ;;
          *)
            skip "could not read stealth mode" ;;
        esac
        ;;
      *"State = 0"*|*"disabled"*)
        warn "Application Firewall is off" \
             "fine behind a network you control; otherwise: sudo $SOCKETFILTERFW --setglobalstate on"
        # Stealth mode is meaningless with the firewall off, so it is not
        # reported separately — one finding, not two.
        ;;
      *)
        skip "could not read the firewall state (needs root on some releases)" ;;
    esac
  fi
fi

# --- updates ---------------------------------------------------------------
if want updates; then
  group "updates"
  SU_DOMAIN=/Library/Preferences/com.apple.SoftwareUpdate

  # Unset means the macOS default, which is on for all of these. Saying so
  # beats reporting a machine that has never been touched as misconfigured.
  check_pref() {
    local key="$1" label="$2" hint="$3" value
    value="$(pref "$SU_DOMAIN" "$key")"
    case "$value" in
      1|true)  pass "$label is on" ;;
      0|false) warn "$label is off" "$hint" ;;
      "")      pass "$label is unset (macOS defaults to on)" ;;
      *)       skip "$label: unexpected value '$value'" ;;
    esac
  }

  check_pref AutomaticCheckEnabled "checking for updates" \
    "softwareupdate --schedule on"
  check_pref AutomaticDownload "downloading updates in the background" \
    "System Settings > General > Software Update > Automatic Updates"
  check_pref CriticalUpdateInstall "installing security responses and system files" \
    "this is the one that matters most: System Settings > General > Software Update > Automatic Updates"
  check_pref ConfigDataInstall "installing system data files (XProtect, MRT)" \
    "System Settings > General > Software Update > Automatic Updates"

  auto_macos="$(pref "$SU_DOMAIN" AutomaticallyInstallMacOSUpdates)"
  case "$auto_macos" in
    1|true)  pass "installing macOS updates automatically is on" ;;
    0|false) warn "macOS updates are not installed automatically" \
                  "deliberate on a machine you cannot have rebooting itself; otherwise turn it on" ;;
    *)       skip "automatic macOS update installation not configured explicitly" ;;
  esac

  # How long since the machine last managed to check. This is answered from a
  # local plist and contacts nothing.
  last="$(pref "$SU_DOMAIN" LastSuccessfulDate)"
  if [[ -z "$last" ]]; then
    skip "no record of a successful update check"
  else
    last_epoch="$(date -j -f '%Y-%m-%d %H:%M:%S %z' "$last" '+%s' 2>/dev/null || true)"
    if [[ -z "$last_epoch" ]]; then
      skip "could not parse the last update check ($last)"
    else
      days=$(( ( $(date '+%s') - last_epoch ) / 86400 ))
      if (( days > 30 )); then
        warn "last successful update check was ${days}d ago" "softwareupdate --list"
      else
        pass "last successful update check was ${days}d ago"
      fi
    fi
  fi
fi

# --- disk ------------------------------------------------------------------
if want disk; then
  group "disk"
  if ! command -v fdesetup >/dev/null 2>&1; then
    skip "fdesetup not present"
  else
    fv="$(fdesetup status 2>/dev/null || true)"
    case "$fv" in
      *"FileVault is On"*)
        pass "FileVault is on" ;;
      *"Deferred enablement appears to be active"*)
        warn "FileVault is deferred, not enabled" \
             "encryption starts at the next login and has not yet: sudo fdesetup status" ;;
      *"FileVault is Off"*)
        fail "FileVault is off" \
             "an unencrypted disk is readable by anyone holding the machine: sudo fdesetup enable" ;;
      *)
        skip "could not read FileVault status" ;;
    esac
  fi
fi

# --- screen lock ------------------------------------------------------------
if want lock; then
  group "lock"
  if ! command -v sysadminctl >/dev/null 2>&1; then
    skip "sysadminctl not present"
  else
    lock_state="$(sysadminctl -screenLock status 2>&1 || true)"
    lock_lower="$(printf '%s' "$lock_state" | tr '[:upper:]' '[:lower:]')"
    case "$lock_lower" in
      *"delay is immediate"*)
        pass "password is required immediately after display sleep or screen saver"
        ;;
      *"screenlock is off"*|*"screen lock is off"*|*"disabled"*)
        fail "screen lock password requirement is off" \
             "System Settings > Lock Screen > Require password after screen saver begins or display is turned off"
        ;;
      *"delay is "*)
        warn "screen lock has a non-immediate password-free delay ($lock_state)" \
             "set Require password to Immediately in System Settings > Lock Screen"
        ;;
      *)
        skip "could not determine the screen lock password delay"
        ;;
    esac
  fi
fi

# --- sip -------------------------------------------------------------------
if want sip; then
  group "sip"
  if ! command -v csrutil >/dev/null 2>&1; then
    skip "csrutil not present"
  else
    sip="$(csrutil status 2>/dev/null || true)"
    case "$sip" in
      *"status: enabled"*)
        pass "System Integrity Protection is enabled" ;;
      *"status: disabled"*)
        fail "System Integrity Protection is disabled" \
             "re-enable from Recovery (hold power at boot) with: csrutil enable" ;;
      *"unknown (Custom Configuration)"*|*"Custom Configuration"*)
        warn "System Integrity Protection is partially disabled" \
             "csrutil status lists which protections are off; re-enable from Recovery with: csrutil enable" ;;
      *)
        skip "could not read SIP status" ;;
    esac
  fi
fi

# --- gatekeeper ------------------------------------------------------------
if want gatekeeper; then
  group "gatekeeper"
  if ! command -v spctl >/dev/null 2>&1; then
    skip "spctl not present"
  else
    gk="$(spctl --status 2>/dev/null || true)"
    case "$gk" in
      *"assessments enabled"*)
        pass "Gatekeeper assessments are enabled" ;;
      *"assessments disabled"*)
        fail "Gatekeeper assessments are disabled" \
             "every downloaded app runs unchecked: sudo spctl --master-enable" ;;
      *)
        skip "could not read Gatekeeper status" ;;
    esac
  fi
fi

# --- secrets ---------------------------------------------------------------
if want secrets; then
  group "secrets"

  # Permission bits as octal, following a symlink to its target. BSD stat
  # answers on a Mac; GNU stat answers in the Linux test container. GNU
  # `stat -f` means --file-system and prints filesystem details on stdout as
  # well as failing, so each answer is accepted only when it looks like a mode.
  file_mode() {
    local m
    m="$(stat -L -f '%Lp' "$1" 2>/dev/null)"
    if [[ ! "$m" =~ ^[0-7]{3,4}$ ]]; then
      m="$(stat -L -c '%a' "$1" 2>/dev/null)"
    fi
    [[ "$m" =~ ^[0-7]{3,4}$ ]] || return 1
    printf '%s\n' "$m"
  }

  # Does an extended ACL on PATH let anyone but the owner read it? macOS
  # `ls -led` lists the entries under the mode line ("0: user:bob allow
  # read"). Where ls has no -e (GNU ls in the test container) or the file
  # has no ACL, the answer is no, silently. Only an allow entry with the
  # `read` right counts, and an entry naming the owner is the owner's own.
  acl_grants_other_read() {
    local listing
    listing="$(ls -leLd -- "$1" 2>/dev/null)" || return 1
    awk '
      NR == 1 { owner = $3; next }
      /^[[:space:]]*[0-9]+: / {
        line = $0
        sub(/^[[:space:]]*[0-9]+: /, "", line)
        i = index(line, " allow ")
        if (i == 0) next
        subject = substr(line, 1, i - 1)
        # "user:me inherited allow read": the inherited flag sits between
        # the subject and the verb and is not part of the name.
        sub(/ inherited$/, "", subject)
        n = split(substr(line, i + 7), perm, /[ ,]+/)
        hit = 0; inh = 0
        for (k = 1; k <= n; k++) {
          if (perm[k] == "only_inherit") inh = 1
          if (perm[k] == "read" && subject != ("user:" owner)) hit = 1
        }
        # only_inherit: the entry governs children, not this object.
        if (hit && !inh) found = 1
      }
      END { exit !found }
    ' <<<"$listing"
  }

  # Does FILE hold a line matching the extended regex? Yes or no and nothing
  # else: grep's output is discarded, so no secret leaves this function.
  file_has() { grep -qE -- "$2" "$1" 2>/dev/null; }

  # relative path|label|kind. Newline-separated rather than an associative
  # array, which Bash 3.2 does not have.
  # A Docker config holds a registry secret in "auth" (base64 password), or
  # in "identitytoken" / "registrytoken" (token-based logins).
  docker_cred_re='"(auth|identitytoken|registrytoken)"[[:space:]]*:[[:space:]]*"[^"]'

  SECRET_FILES='.aws/credentials|AWS credentials|aws
.kube/config|kubeconfig|kube
.docker/config.json|Docker config.json|docker
.netrc|.netrc|netrc
.npmrc|.npmrc|npmrc
.pypirc|.pypirc|pypirc
.git-credentials|.git-credentials|gitcred
.config/gh/hosts.yml|GitHub CLI hosts.yml|gh
.terraform.d/credentials.tfrc.json|Terraform Cloud credentials|tfc
.config/gcloud/application_default_credentials.json|gcloud application-default credentials|adc'

  if [[ -z "${HOME:-}" ]]; then
    skip "HOME is not set; credential files not checked"
  else
    found_secret_file=0
    while IFS='|' read -r rel label kind; do
      [[ -n "$rel" ]] || continue
      path="$HOME/$rel"
      # -f follows a symlink, so a linked file is checked at its target and
      # reported under the name it has in the home directory.
      [[ -f "$path" ]] || continue
      found_secret_file=1
      # shellcheck disable=SC2088  # a display path, never opened
      shown="~/$rel"

      # Docker's config.json and .npmrc are often 644 and harmless when they
      # hold no secret: with a credential store, or a token read from the
      # environment, there is nothing in them for another user to read.
      secret_free=0
      case "$kind" in
        docker)
          # A credsStore does not clear legacy "auth" entries left in the
          # same file: those are still base64 passwords on disk.
          file_has "$path" "$docker_cred_re" \
            || secret_free=1
          ;;
        npmrc)
          file_has "$path" '(_authToken|_auth|_password)[[:space:]]*=[[:space:]]*[^$[:space:]]' \
            || secret_free=1
          ;;
      esac

      mode="$(file_mode "$path")" || mode=""
      if [[ -z "$mode" ]]; then
        skip "could not read the mode of $shown"
      elif (( secret_free )); then
        :
      elif (( (8#$mode & 4) != 0 )); then
        fail "$label is readable by every local user ($shown, mode $mode)" "chmod 600 $path"
      elif (( (8#$mode & 32) != 0 )); then
        warn "$label is readable by its group ($shown, mode $mode)" "chmod 600 $path"
      elif acl_grants_other_read "$path"; then
        warn "$label has an ACL entry that lets another user read it ($shown, mode $mode)" \
             "chmod -N $path"
      else
        pass "$label is private to its owner ($shown, mode $mode)"
      fi

      case "$kind" in
        aws)
          if file_has "$path" '^[[:space:]]*aws_secret_access_key[[:space:]]*='; then
            warn "long-lived static AWS keys on disk ($shown)" \
                 "prefer short-lived credentials: aws configure sso, then aws sso login"
          else
            pass "$shown holds no static AWS keys"
          fi
          ;;
        docker)
          if file_has "$path" "$docker_cred_re"; then
            if file_has "$path" '"credsStore"[[:space:]]*:'; then
              warn "legacy registry credentials remain in config.json despite its credential store ($shown)" \
                   'docker logout each registry, then docker login again'
            else
              warn "registry credentials are base64 text in config.json ($shown)" \
                   'set "credsStore": "osxkeychain" in it and docker login again'
            fi
          elif file_has "$path" '"credsStore"[[:space:]]*:'; then
            pass "Docker config uses a credential store ($shown)"
          else
            pass "Docker config holds no registry passwords ($shown)"
          fi
          ;;
        npmrc)
          # A ${VAR} reference is resolved from the environment by npm; any
          # other value is the token itself.
          if file_has "$path" '(_authToken|_auth|_password)[[:space:]]*=[[:space:]]*[^$[:space:]]'; then
            # shellcheck disable=SC2016  # the ${...} is text for the reader
            warn "literal npm token in $shown" 'reference an environment variable instead: _authToken=${NPM_TOKEN}'
          else
            pass "$shown holds no literal npm token"
          fi
          ;;
        netrc)
          if file_has "$path" '(^|[[:space:]])password[[:space:]]'; then
            warn "plaintext password in $shown" \
                 "curl, git and ftp read it as is; move it to the Keychain or a credential helper"
          fi
          ;;
        gitcred)
          warn "plaintext git credentials in $shown" \
               "git config --global credential.helper osxkeychain, then delete $path"
          ;;
      esac
    done <<< "$SECRET_FILES"

    if (( found_secret_file == 0 )); then
      pass "no credential files found in the usual places"
    fi
  fi

  # credential.helper store is what writes ~/.git-credentials.
  if command -v git >/dev/null 2>&1; then
    helper="$(git config --global credential.helper 2>/dev/null || true)"
    case "$helper" in
      store|store\ *)
        warn "git stores credentials as plain text (credential.helper store)" \
             "git config --global credential.helper osxkeychain" ;;
      osxkeychain)
        pass "git keeps credentials in the Keychain (credential.helper osxkeychain)" ;;
      "")
        pass "no plaintext git credential helper configured" ;;
      *)
        pass "git uses a credential helper other than store" ;;
    esac
  else
    skip "git not present; credential.helper not checked"
  fi
fi

# --- summary ---------------------------------------------------------------
needs_root_hint=false
if (( SKIP_COUNT > 0 )) && [[ "$(id -u)" != "0" ]]; then
  needs_root_hint=true
fi

if (( JSON )); then
  printf '{"schema":1,"script":"hardening_audit.sh","host":%s,"generated":%s,"fail_on":"%s","summary":{"pass":%d,"warn":%d,"fail":%d,"skip":%d},"needs_root_hint":%s,"findings":[%s]}\n' \
    "$(json_str "$(uname -n 2>/dev/null)")" "$(json_str "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" \
    "$FAIL_ON" "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT" "$SKIP_COUNT" \
    "$needs_root_hint" "$FINDINGS"
else
  printf "\n%s== summary ==%s\n" "$C_BOLD" "$C_RESET"
  printf "  %s%s pass%s  %s%s warn%s  %s%s fail%s  %s%s skip%s\n" \
    "$C_GREEN" "$PASS_COUNT" "$C_RESET" \
    "$C_YELLOW" "$WARN_COUNT" "$C_RESET" \
    "$C_RED" "$FAIL_COUNT" "$C_RESET" \
    "$C_DIM" "$SKIP_COUNT" "$C_RESET"

  if [[ "$needs_root_hint" == "true" ]]; then
    info "some checks read more with root; rerun with sudo for the full picture"
  fi
fi

if [[ "$FAIL_ON" == "warn" ]] && (( WARN_COUNT + FAIL_COUNT > 0 )); then
  exit 1
fi
if (( FAIL_COUNT > 0 )); then
  exit 1
fi
exit 0
