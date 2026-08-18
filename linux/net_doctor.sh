#!/usr/bin/env bash
# net_doctor.sh
# Read-only network report for a Linux machine.
#
# system_doctor.sh already says which host firewall is in charge and lists
# global addresses. This is the rest of the question you ask when "the network
# is wrong": default route, DNS, whether anything is listening, and (opt-in)
# whether a probe host answers. It changes nothing, and there is deliberately
# no exit code for a bad report — a missing default route is something to read,
# not a gate. Use hardening_audit.sh --only network when you want findings.
#
# Exit codes:
#   0   the report ran (warnings do not change the exit code)
#   2   preflight failed (not Linux)
#   3   bad CLI arguments
set -u
set -o pipefail

QUIET=0
SKIP_LISTEN=0
PROBE_HOST=""

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
fi

OK_COUNT=0
WARN_COUNT=0
SKIP_COUNT=0

ok()   { OK_COUNT=$((OK_COUNT + 1)); (( QUIET )) || printf "  %s[ ok ]%s %s\n" "$C_GREEN" "$C_RESET" "$1"; }
info() { (( QUIET )) || printf "  %s[info]%s %s\n" "$C_BLUE" "$C_RESET" "$1"; }
skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); (( QUIET )) || printf "  %s[skip]%s %s\n" "$C_DIM" "$C_RESET" "$1"; }
warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  printf "  %s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$1"
  [[ -n "${2:-}" ]] && printf "         %s%s%s\n" "$C_DIM" "$2" "$C_RESET"
  return 0
}
err()  { printf "%s[err ]%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; }

usage() {
  cat <<EOF
net_doctor.sh - read-only network report for a Linux machine

Describes routing, DNS, listening sockets and an optional connectivity probe.
Changes nothing. For firewall findings, use hardening_audit.sh --only network.

Usage:
  $(basename "$0") [--probe HOST] [--skip-listen] [--quiet]

Options:
  --probe HOST     Try to resolve and connect to HOST (default: no probe)
  --skip-listen    Don't list listening TCP/UDP sockets
  --quiet          Print only warnings
  --help, -h       Show this help

Sections: interfaces, routes, dns, listen, probe

Exit codes: 0 report printed, 2 not Linux, 3 usage
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
    --probe)       require_value "$1" "${2:-}"; PROBE_HOST="$2"; shift ;;
    --probe=*)     PROBE_HOST="${1#*=}"; require_value "--probe" "$PROBE_HOST" ;;
    --skip-listen) SKIP_LISTEN=1 ;;
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

if [[ "$(uname -s)" != "Linux" ]]; then
  err "this script targets Linux"
  exit 2
fi

group() { printf "\n%s== %s ==%s\n" "$C_BOLD" "$1" "$C_RESET"; }
have()  { command -v "$1" >/dev/null 2>&1; }

# --- interfaces ------------------------------------------------------------
group "interfaces"
if [[ -d /sys/class/net ]]; then
  found=0
  for iface_path in /sys/class/net/*; do
    [[ -e "$iface_path" ]] || continue
    iface="$(basename "$iface_path")"
    [[ "$iface" == "lo" ]] && continue
    found=1
    oper="unknown"
    [[ -r "$iface_path/operstate" ]] && oper="$(cat "$iface_path/operstate" 2>/dev/null || printf 'unknown')"
    mac=""
    [[ -r "$iface_path/address" ]] && mac="$(cat "$iface_path/address" 2>/dev/null || true)"
    addrs=""
    if have ip; then
      addrs="$(ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{ print $4 }' | tr '\n' ' ')"
    elif [[ -r /proc/net/fib_trie ]]; then
      addrs=""
    fi
    summary="$iface $oper"
    [[ -n "$addrs" ]] && summary="$summary $addrs"
    [[ -n "$mac" && "$mac" != "00:00:00:00:00:00" ]] && summary="$summary ($mac)"
    if [[ "$oper" == "up" || "$oper" == "unknown" ]]; then
      ok "$summary"
    else
      info "$summary"
    fi
  done
  (( found )) || skip "no non-loopback interfaces in /sys/class/net"
else
  skip "/sys/class/net unreadable"
fi

# --- routes ----------------------------------------------------------------
group "routes"
have_default=0
if have ip; then
  def="$(ip -4 route show default 2>/dev/null || true)"
  if [[ -n "$def" ]]; then
    have_default=1
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      ok "default: $line"
    done <<< "$def"
  fi
elif [[ -r /proc/net/route ]]; then
  # Destination 00000000 is the default route. Gateway bytes are little-endian
  # hex; print them dotted rather than leaving a hex blob in the report.
  while read -r iface dest gateway flags _rest; do
    [[ "$dest" == "00000000" ]] || continue
    [[ "$iface" == "Iface" ]] && continue
    have_default=1
    gw=""
    if [[ "$gateway" =~ ^[0-9A-Fa-f]{8}$ ]]; then
      gw="$(printf '%d.%d.%d.%d' \
        "$(( 0x${gateway:6:2} ))" "$(( 0x${gateway:4:2} ))" \
        "$(( 0x${gateway:2:2} ))" "$(( 0x${gateway:0:2} ))")"
    fi
    ok "default via ${gw:-$gateway} dev $iface"
  done < /proc/net/route
else
  skip "neither ip nor /proc/net/route is available"
fi
if (( have_default == 0 )); then
  warn "no default IPv4 route" "ip route · or this is a container with no uplink"
fi

# IPv6 is reported, not graded: a v4-only host is common and not a fault.
# A missing v4 default already warned above.
if have ip; then
  def6="$(ip -6 route show default 2>/dev/null || true)"
  if [[ -n "$def6" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      ok "default6: $line"
    done <<< "$def6"
  else
    info "no default IPv6 route"
  fi
fi

# --- dns -------------------------------------------------------------------
group "dns"
resolv="${RESOLV_CONF:-/etc/resolv.conf}"
if [[ -r "$resolv" ]]; then
  ns_count=0
  search=""
  stub=0
  while IFS= read -r line; do
    case "$line" in
      nameserver*)
        ns="${line#nameserver }"
        ns="${ns#nameserver	}"
        ns_count=$((ns_count + 1))
        if [[ "$ns" == "127.0.0.53" ]]; then
          stub=1
          info "nameserver $ns (systemd-resolved stub)"
        else
          ok "nameserver $ns"
        fi
        ;;
      search*)
        search="${line#search }"
        ;;
    esac
  done < "$resolv"
  [[ -n "$search" ]] && info "search $search"
  if (( ns_count == 0 )); then
    warn "no nameserver in $resolv" "echo 'nameserver 1.1.1.1' | sudo tee -a $resolv"
  fi
  if (( stub == 1 )) && have resolvectl; then
    info "query resolvectl status for the upstream resolvers behind 127.0.0.53"
  fi
else
  skip "$resolv unreadable"
fi

# sudo hangs for seconds when the local hostname does not resolve. That is
# not a routing problem; it is a missing /etc/hosts line, and it lasts for
# the life of the machine.
hn="$(uname -n 2>/dev/null || true)"
if [[ -n "$hn" ]]; then
  resolved_hn=""
  if have getent; then
    resolved_hn="$(getent hosts "$hn" 2>/dev/null | awk '{ print $1; exit }')"
  fi
  if [[ -z "$resolved_hn" && -r /etc/hosts ]]; then
    resolved_hn="$(awk -v h="$hn" '
      $1 ~ /^#/ { next }
      { for (i = 2; i <= NF; i++) if ($i == h) { print $1; exit } }
    ' /etc/hosts)"
  fi
  if [[ -n "$resolved_hn" ]]; then
    ok "hostname $hn resolves to $resolved_hn"
  else
    warn "hostname $hn does not resolve" "sudo delays follow: echo \"127.0.1.1 $hn\" | sudo tee -a /etc/hosts"
  fi
fi

# --- listen ----------------------------------------------------------------
group "listen"
if (( SKIP_LISTEN == 1 )); then
  skip "listening sockets (--skip-listen)"
elif have ss; then
  # ss -tuln is the usual "what is open" question. Count rather than dump a
  # wall of sockets; the command to see them is printed either way.
  listen_out="$(ss -tuln 2>/dev/null || true)"
  count="$(printf '%s\n' "$listen_out" | awk 'NR>1 && NF { c++ } END { print c+0 }')"
  if (( count == 0 )); then
    info "no listening TCP/UDP sockets"
  else
    ok "$count listening TCP/UDP socket(s)"
    printf '%s\n' "$listen_out" | awk 'NR==1 || NF { print "           " $0 }'
  fi
elif have netstat; then
  listen_out="$(netstat -tuln 2>/dev/null || true)"
  count="$(printf '%s\n' "$listen_out" | awk '/LISTEN|udp/ { c++ } END { print c+0 }')"
  ok "$count listening socket(s) (netstat)"
else
  skip "neither ss nor netstat is installed"
fi

# --- probe -----------------------------------------------------------------
group "probe"
if [[ -z "$PROBE_HOST" ]]; then
  skip "no probe host (pass --probe HOST)"
else
  resolved=""
  if have getent; then
    resolved="$(getent ahostsv4 "$PROBE_HOST" 2>/dev/null | awk '{ print $1; exit }')"
  fi
  if [[ -z "$resolved" ]] && have getent; then
    resolved="$(getent hosts "$PROBE_HOST" 2>/dev/null | awk '{ print $1; exit }')"
  fi
  if [[ -n "$resolved" ]]; then
    ok "$PROBE_HOST resolves to $resolved"
  else
    warn "could not resolve $PROBE_HOST" "getent ahostsv4 $PROBE_HOST"
  fi

  # TCP/443 is the least surprising "is there a path" check: ICMP is often
  # filtered, and a five-second timeout keeps a wedged network from hanging
  # the report. bash /dev/tcp is used so there is no extra binary to miss.
  if [[ -n "$resolved" ]]; then
    if ! have timeout; then
      skip "timeout(1) not installed; not probing TCP"
    elif timeout 5 bash -c "echo >/dev/tcp/${resolved}/443" 2>/dev/null; then
      ok "$resolved:443 accepted a TCP connection"
    elif timeout 5 bash -c "echo >/dev/tcp/${resolved}/80" 2>/dev/null; then
      ok "$resolved:80 accepted a TCP connection"
    else
      warn "no TCP path to $resolved on 443 or 80" \
        "may be expected in a container with no uplink"
    fi
  fi
fi

# --- summary ---------------------------------------------------------------
printf "\n%s== summary ==%s\n" "$C_BOLD" "$C_RESET"
printf "  %s%s ok%s  %s%s warn%s  %s%s skip%s\n" \
  "$C_GREEN" "$OK_COUNT" "$C_RESET" \
  "$C_YELLOW" "$WARN_COUNT" "$C_RESET" \
  "$C_DIM" "$SKIP_COUNT" "$C_RESET"
info "firewall posture is a separate report: ./hardening_audit.sh --only network"
exit 0
