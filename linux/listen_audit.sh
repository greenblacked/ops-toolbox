#!/usr/bin/env bash
# listen_audit.sh
# Read-only report of who owns each listening port, with optional baseline drift.
#
# net_doctor.sh prints the raw `ss -tuln` table and hardening_audit.sh counts
# the sockets bound to every interface. Neither says which process owns a
# port, whether it answers on loopback only or to the network, or whether the
# set changed since last week. This one does all three:
#
#   - by default it prints one row per listener — protocol, port, scope
#     (loopback, wildcard or a specific address), the owning process and the
#     addresses it is bound to — with IPv4/IPv6 twins of the same socket folded
#     into one row;
#   - --print writes the public listeners as a stable baseline (proto/port/
#     process, sorted, no pids and no date) to stdout, for you to redirect into
#     a file and commit;
#   - --baseline FILE and --allow PORTS compare the live public listeners with
#     what is expected, so "a new service started listening" becomes exit 1
#     from cron. A listener the baseline expects that is gone is a warning.
#
# The only command it runs is ss. It never writes the baseline itself: --print
# goes to stdout. Process names come from the kernel's comm field and are
# stripped of control characters before they are printed; a name ss cannot
# show (another user's socket, without root) is "?", and comparison then falls
# back to protocol and port for that row.
#
# Exit codes:
#   0   report printed, and no drift at or above --fail-on
#   1   drift at or above --fail-on (only with --baseline or --allow)
#   2   preflight failed (not Linux, or ss missing or failing)
#   3   bad CLI arguments: an unknown flag, a missing value, an unreadable
#       --baseline file or a bad line in it, or a bad port in --allow
set -u
set -o pipefail

PUBLIC_ONLY=0
PRINT=0
SHOW_ALL=0
BASELINE=""
ALLOW=""
FAIL_ON=""
QUIET=0

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
warn() { WARN_COUNT=$((WARN_COUNT + 1)); printf "  %s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$1"; [[ -n "${2:-}" ]] && printf "         %s%s%s\n" "$C_DIM" "$2" "$C_RESET"; return 0; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf "  %s[FAIL]%s %s\n" "$C_RED" "$C_RESET" "$1"; [[ -n "${2:-}" ]] && printf "         %s%s%s\n" "$C_DIM" "$2" "$C_RESET"; return 0; }
skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); (( QUIET )) || printf "  %s[skip]%s %s\n" "$C_DIM" "$C_RESET" "$1"; }
info() { (( QUIET )) || printf "  %s[info]%s %s\n" "$C_BLUE" "$C_RESET" "$1"; }
err()  { printf "%s[err ]%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; }

usage() {
  cat <<EOF
listen_audit.sh - read-only listening-port owners and baseline drift

Lists every listening TCP/UDP socket with its owning process and scope, and
compares the public ones with a baseline or an allow-list. Changes nothing;
--print writes the baseline to stdout, never to a file.

Usage:
  $(basename "$0") [--public-only] [--quiet]
  $(basename "$0") --print [--all] > listeners.baseline
  $(basename "$0") [--baseline FILE] [--allow PORT[,PORT...]] [--fail-on new|any|never]

Options:
  --public-only      Hide loopback listeners from the table
  --print            Print the public listeners as a baseline (proto/port/process) and exit
  --all              With --print or --baseline, include loopback listeners too
  --baseline FILE    Compare with FILE: one proto/port/process per line, # comments;
                     port may be a range (tcp/8000-8100/*), process * matches any
  --allow PORTS      Comma-separated ports or ranges allowed on any protocol
  --fail-on LEVEL    'new' (default with a baseline or allow-list): exit 1 on a new
                     listener; 'any': also on an expected one that is gone; 'never'
  --quiet            Print only warnings and failures
  --help, -h         Show this help

Exit codes: 0 no drift at or above --fail-on, 1 drift, 2 not Linux or no ss,
3 usage (including an unreadable --baseline or a bad port)
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

while (( $# > 0 )); do
  case "$1" in
    --public-only) PUBLIC_ONLY=1 ;;
    --print)       PRINT=1 ;;
    --all)         SHOW_ALL=1 ;;
    --baseline)    require_value "$1" "${2:-}"; BASELINE="$2"; shift ;;
    --baseline=*)  BASELINE="${1#*=}"; require_value "--baseline" "$BASELINE" ;;
    --allow)       require_value "$1" "${2:-}"; ALLOW="$2"; shift ;;
    --allow=*)     ALLOW="${1#*=}"; require_value "--allow" "$ALLOW" ;;
    --fail-on)     require_value "$1" "${2:-}"; FAIL_ON="$2"; shift ;;
    --fail-on=*)   FAIL_ON="${1#*=}"; require_value "--fail-on" "$FAIL_ON" ;;
    --quiet)       QUIET=1 ;;
    -h|--help)     usage; exit 0 ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

case "$FAIL_ON" in
  ""|new|any|never) ;;
  *) err "--fail-on must be new, any or never, got: $FAIL_ON"; exit 3 ;;
esac

# A port token is a number or a range, 1-65535 both ends, low end first.
# Prints "LO HI" for a good token; returns 1 for anything else.
port_range() {
  local tok="$1" lo hi
  [[ "$tok" =~ ^[0-9]+(-[0-9]+)?$ ]] || return 1
  lo="${tok%%-*}"
  hi="${tok##*-}"
  # Leading zeros would be read as octal in (( )); five digits is the most a
  # port can have, so anything longer is refused before arithmetic sees it.
  (( ${#lo} <= 5 && ${#hi} <= 5 )) || return 1
  lo=$((10#$lo))
  hi=$((10#$hi))
  (( lo >= 1 && hi <= 65535 && lo <= hi )) || return 1
  printf '%s %s\n' "$lo" "$hi"
}

# Entries, one per line: "E SOURCE PROTO LO HI PROCESS". SOURCE is base for a
# baseline line (expected, so a missing one is reported) and allow for an
# --allow port (permitted, never expected). Built and validated here, ahead of
# the Linux and ss preflight, so a bad file is a usage error everywhere.
ENTRIES=""
if [[ -n "$ALLOW" ]]; then
  IFS=',' read -r -a allow_items <<< "$ALLOW"
  n_allow=0
  for tok in "${allow_items[@]+"${allow_items[@]}"}"; do
    tok="$(printf '%s' "$tok" | tr -d '[:space:]')"
    [[ -n "$tok" ]] || continue
    if ! range="$(port_range "$tok")"; then
      err "--allow: not a port or port range between 1 and 65535: $tok"
      exit 3
    fi
    ENTRIES="${ENTRIES}E allow * ${range} *"$'\n'
    n_allow=$((n_allow + 1))
  done
  if (( n_allow == 0 )); then
    err "--allow named no port"
    exit 3
  fi
fi

if [[ -n "$BASELINE" ]]; then
  if [[ ! -f "$BASELINE" || ! -r "$BASELINE" ]]; then
    err "--baseline: not a readable file: $BASELINE"
    exit 3
  fi
  ln_no=0
  # The file is only ever read line by line here; nothing in it is evaluated
  # or handed to a command.
  while IFS= read -r line || [[ -n "$line" ]]; do
    ln_no=$((ln_no + 1))
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [[ -n "$line" ]] || continue
    proto="${line%%/*}"
    rest="${line#*/}"
    port_tok="${rest%%/*}"
    proc="${rest#*/}"
    if [[ "$line" != */*/* || -z "$proc" ]]; then
      err "--baseline $BASELINE line $ln_no: expected proto/port/process, got: $line"
      exit 3
    fi
    case "$proto" in
      tcp|udp|'*') ;;
      *) err "--baseline $BASELINE line $ln_no: protocol must be tcp, udp or *, got: $proto"; exit 3 ;;
    esac
    if ! range="$(port_range "$port_tok")"; then
      err "--baseline $BASELINE line $ln_no: not a port or port range between 1 and 65535: $port_tok"
      exit 3
    fi
    ENTRIES="${ENTRIES}E base ${proto} ${range} ${proc}"$'\n'
  done < "$BASELINE"
fi

COMPARE=0
[[ -n "$BASELINE" || -n "$ALLOW" ]] && COMPARE=1
[[ -n "$FAIL_ON" ]] || FAIL_ON="new"

# --help and every usage error are answered above, so they work anywhere.
if [[ "$(uname -s)" != "Linux" ]]; then
  err "this script targets Linux"
  exit 2
fi
if ! command -v ss >/dev/null 2>&1; then
  err "ss is required (iproute2), then rerun"
  exit 2
fi

group() { printf "\n%s== %s ==%s\n" "$C_BOLD" "$1" "$C_RESET"; }

# Control characters out of anything that came from a process name.
clean() { tr -d '\000-\010\013-\037'; }

# ss is run on its own so a failure stays visible: folded into the pipeline
# below, a refused ss would produce no rows, and no rows reads as "nothing is
# listening". -H is not used to drop the header; older iproute2 lacks it, so
# the parser skips the first line instead.
ss_out="$(ss -tulnp 2>/dev/null)"; ss_rc=$?
if (( ss_rc != 0 )); then
  err "ss -tulnp exited $ss_rc"
  exit 2
fi

# One row per listener: "PROTO PORT SCOPE PROCESS BIND". The local address is
# split at its last colon, which handles [::]:22, *:80 and 127.0.0.53%lo:53
# alike. A process name keeps letters, digits and _ . : @ + - only, so it is
# always one field here and one segment of a baseline line. IPv4 and IPv6
# twins of the same proto, port, process and scope fold into one row with both
# addresses in BIND.
ROWS="$(clean <<<"$ss_out" | awk '
  NR == 1 { next }
  NF < 5 { next }
  {
    proto = $1
    if (proto != "tcp" && proto != "udp") next
    local_addr = $5
    if (!match(local_addr, /:[^:]*$/)) next
    addr = substr(local_addr, 1, RSTART - 1)
    port = substr(local_addr, RSTART + 1)
    if (port !~ /^[0-9]+$/) next
    a = addr
    sub(/%.*/, "", a)
    gsub(/\[/, "", a)
    gsub(/\]/, "", a)
    if (a ~ /^127\./ || a == "::1" || a ~ /^::ffff:127\./) scope = "loopback"
    else if (a == "0.0.0.0" || a == "*" || a == "::") scope = "wildcard"
    else scope = "other"
    proc = "?"
    if (match($0, /users:\(\("[^"]*"/)) {
      proc = substr($0, RSTART + 9, RLENGTH - 10)
      gsub(/[^A-Za-z0-9_.:@+-]/, "_", proc)
      if (proc == "") proc = "?"
    }
    key = proto " " port " " scope " " proc
    if (key in bind) {
      if (index("," bind[key] ",", "," addr ",") == 0) bind[key] = bind[key] "," addr
    } else {
      bind[key] = addr
      order[++n] = key
    }
  }
  END { for (i = 1; i <= n; i++) print order[i], bind[order[i]] }
' | sort -k2,2n -k1,1 -k4,4)"

# --print: the baseline, and nothing else on stdout. No pid, no address, no
# date, sorted, so the same machine prints the same bytes twice.
if (( PRINT )); then
  printf '# listen_audit baseline: proto/port/process, one per line\n'
  printf '# generated by listen_audit.sh --print; * as process matches any\n'
  if [[ -n "$ROWS" ]]; then
    while read -r proto port scope proc _bind; do
      [[ -n "$proto" ]] || continue
      [[ "$scope" == "loopback" ]] && (( SHOW_ALL == 0 )) && continue
      printf '%s/%s/%s\n' "$proto" "$port" "$proc"
    done <<< "$ROWS" | sort -u -t/ -k2,2n -k1,1 -k3,3
  fi
  exit 0
fi

group "listeners"
total=0
public=0
loopback=0
hidden_public=0
if [[ -n "$ROWS" ]]; then
  (( QUIET )) || printf "  %-5s %-6s %-9s %-20s %s\n" "PROTO" "PORT" "SCOPE" "PROCESS" "BIND"
  while read -r proto port scope proc bind; do
    [[ -n "$proto" ]] || continue
    total=$((total + 1))
    if [[ "$scope" == "loopback" ]]; then
      loopback=$((loopback + 1))
      (( PUBLIC_ONLY )) && continue
    else
      public=$((public + 1))
      [[ "$proc" == "?" ]] && hidden_public=$((hidden_public + 1))
    fi
    (( QUIET )) || printf "  %-5s %-6s %-9s %-20s %s\n" "$proto" "$port" "$scope" "${proc:0:20}" "${bind:0:60}"
  done <<< "$ROWS"
fi
if (( total == 0 )); then
  info "no listening TCP/UDP sockets"
else
  info "$total listener(s): $public public, $loopback loopback"
fi
(( hidden_public > 0 )) && skip "process names need root: sudo ./listen_audit.sh"

if (( COMPARE )); then
  group "drift"
  live=""
  if [[ -n "$ROWS" ]]; then
    while read -r proto port scope proc _bind; do
      [[ -n "$proto" ]] || continue
      live="${live}L ${proto} ${port} ${scope} ${proc}"$'\n'
    done <<< "$ROWS"
  fi
  # NEW: a live listener (public, or any with --all) that no entry covers.
  # GONE: a single-port baseline entry that no live listener of any scope
  # answers; ranges and --allow ports are permissions, not expectations.
  # A process shown as "?" matches on protocol and port alone.
  drift="$(awk -v all="$SHOW_ALL" '
    function covers(j, i) {
      if (ep[j] != "*" && ep[j] != lp[i]) return 0
      if (lport[i] + 0 < elo[j] + 0 || lport[i] + 0 > ehi[j] + 0) return 0
      if (eproc[j] == "*" || eproc[j] == "?" || lproc[i] == "?" || eproc[j] == lproc[i]) return 1
      return 0
    }
    $1 == "E" { n++; es[n] = $2; ep[n] = $3; elo[n] = $4; ehi[n] = $5; eproc[n] = $6; next }
    $1 == "L" { m++; lp[m] = $2; lport[m] = $3; lscope[m] = $4; lproc[m] = $5; next }
    END {
      for (i = 1; i <= m; i++) {
        if (lscope[i] == "loopback" && all != 1) continue
        if (lproc[i] == "?") hidden = 1
        hit = 0
        for (j = 1; j <= n; j++) if (covers(j, i)) { hit = 1; break }
        if (!hit) print "NEW", lp[i], lport[i], lproc[i]
      }
      for (j = 1; j <= n; j++) {
        if (es[j] != "base" || elo[j] != ehi[j]) continue
        hit = 0
        for (i = 1; i <= m; i++) if (covers(j, i)) { hit = 1; break }
        if (!hit) print "GONE", ep[j], elo[j], eproc[j]
      }
      if (hidden) print "HIDDEN"
    }
  ' <<< "${ENTRIES}${live}")"
  new_n=0
  gone_n=0
  while read -r kind proto port proc; do
    case "$kind" in
      NEW)
        new_n=$((new_n + 1))
        fail "NEW listener $proto/$port ($proc)" "ss -tulnp | grep :$port"
        ;;
      GONE)
        gone_n=$((gone_n + 1))
        if [[ "$proc" == "*" || "$proc" == "?" ]]; then
          warn "expected listener $proto/$port is not listening" "ss -tulnp | grep :$port"
        else
          warn "expected listener $proto/$port ($proc) is not listening" "systemctl status $proc"
        fi
        ;;
      HIDDEN)
        info "some process names are hidden without root; those listeners were matched on protocol and port only"
        ;;
    esac
  done <<< "$drift"
  (( new_n == 0 )) && pass "no listener outside the baseline or allow-list"
  [[ -n "$BASELINE" ]] && (( gone_n == 0 )) && pass "every expected listener is listening"
fi

# --- summary ---------------------------------------------------------------
printf "\n%s== summary ==%s\n" "$C_BOLD" "$C_RESET"
printf "  %s%s pass%s  %s%s warn%s  %s%s fail%s  %s%s skip%s\n" \
  "$C_GREEN" "$PASS_COUNT" "$C_RESET" \
  "$C_YELLOW" "$WARN_COUNT" "$C_RESET" \
  "$C_RED" "$FAIL_COUNT" "$C_RESET" \
  "$C_DIM" "$SKIP_COUNT" "$C_RESET"
(( COMPARE )) || info "pin this set with --print > FILE, then check it with --baseline FILE"

if (( COMPARE )); then
  case "$FAIL_ON" in
    new) (( new_n > 0 )) && exit 1 ;;
    any) (( new_n + gone_n > 0 )) && exit 1 ;;
  esac
fi
exit 0
