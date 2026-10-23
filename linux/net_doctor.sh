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
SKIP_LINKS=0
PROBE_HOST=""

# Where interfaces and bonds are read from. Environment variables rather than
# flags, like RESOLV_CONF below: they exist so the suite can hand the links
# section a NIC with CRC errors, a half-duplex link or a bond with a dead
# slave, none of which a container has.
SYS_CLASS_NET="${SYS_CLASS_NET:-/sys/class/net}"
PROC_NET_BONDING="${PROC_NET_BONDING:-/proc/net/bonding}"

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
  $(basename "$0") [--probe HOST] [--skip-listen] [--skip-links] [--quiet]

Options:
  --probe HOST     Try to resolve and connect to HOST (default: no probe)
  --skip-listen    Don't list listening TCP/UDP sockets
  --skip-links     Don't read link counters, speed, bonds and the gateway's neighbour entry
  --quiet          Print only warnings
  --help, -h       Show this help

Sections: interfaces, routes, links, dns, listen, probe

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
    --skip-links)  SKIP_LINKS=1 ;;
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

# Interface names are directory names, which the kernel restricts less than a
# terminal would like; control characters go before one is printed.
clean() { tr -d '\000-\010\013-\037'; }

# --- interfaces ------------------------------------------------------------
group "interfaces"
if [[ -d "$SYS_CLASS_NET" ]]; then
  found=0
  for iface_path in "$SYS_CLASS_NET"/*; do
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
  (( found )) || skip "no non-loopback interfaces in $SYS_CLASS_NET"
else
  skip "$SYS_CLASS_NET unreadable"
fi

# --- routes ----------------------------------------------------------------
group "routes"
have_default=0
# The first default route's gateway and interface, kept for the links section
# (the gateway's neighbour entry and the uplink's MTU).
DEFAULT_GW=""
DEFAULT_IF=""
if have ip; then
  def="$(ip -4 route show default 2>/dev/null || true)"
  if [[ -n "$def" ]]; then
    have_default=1
    read -r DEFAULT_GW DEFAULT_IF <<< "$(awk 'NR == 1 {
      for (i = 1; i < NF; i++) { if ($i == "via") gw = $(i + 1); if ($i == "dev") dev = $(i + 1) }
      print (gw == "" ? "-" : gw), (dev == "" ? "-" : dev) }' <<<"$def")"
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
    if [[ -z "$DEFAULT_IF" ]]; then
      DEFAULT_GW="${gw:--}"
      DEFAULT_IF="$iface"
    fi
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

# --- links -----------------------------------------------------------------
# What makes "the network is slow or flaky" concrete, all readable from sysfs
# without a tool or root: error and drop counters, a link that negotiated half
# duplex or 100 Mb/s, carrier flaps, a bond running on one leg, and a default
# gateway that no longer answers ARP. Hardware checks apply to physical NICs
# only (those with a device link); veth, bridges, tunnels and WireGuard report
# -1 or nothing and are counted, not graded. ethtool appears only in hints.
group "links"
# A counter or a setting from sysfs, digits only. Virtual and down interfaces
# answer -1 or EINVAL, and those must not reach arithmetic under set -u.
sys_num() {
  local v=""
  [[ -r "$1" ]] && v="$(tr -d '[:space:]' 2>/dev/null < "$1")"
  [[ "$v" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$v"
}
human_count() {
  awk -v n="$1" 'BEGIN {
    if (n >= 1e9) printf "%.1fG", n / 1e9
    else if (n >= 1e6) printf "%.1fM", n / 1e6
    else if (n >= 1e3) printf "%.1fk", n / 1e3
    else printf "%d", n }'
}
if (( SKIP_LINKS )); then
  skip "link counters and negotiation (--skip-links)"
elif [[ ! -d "$SYS_CLASS_NET" ]]; then
  skip "$SYS_CLASS_NET unreadable"
else
  virtual_n=0
  for iface_path in "$SYS_CLASS_NET"/*; do
    [[ -e "$iface_path" ]] || continue
    iface="$(basename "$iface_path" | clean)"
    [[ "$iface" == "lo" ]] && continue
    oper="$(cat "$iface_path/operstate" 2>/dev/null || printf 'unknown')"
    mtu="$(sys_num "$iface_path/mtu" || true)"
    # The uplink's MTU, virtual or not: below 1500 is a tunnel or a PPPoE
    # path, which explains stalled large transfers without being a fault.
    if [[ "$iface" == "$DEFAULT_IF" && -n "$mtu" ]] && (( 10#$mtu < 1500 )); then
      info "$iface carries the default route with mtu $mtu (a tunnel or PPPoE path; large packets need PMTU discovery)"
    fi
    if [[ ! -e "$iface_path/device" ]]; then
      virtual_n=$((virtual_n + 1))
      continue
    fi

    # Since boot or driver load, so a burst last month still counts; the ratio
    # and the floor of 100 keep a quiet link's handful of drops out.
    errs=0
    for c in rx_errors tx_errors rx_dropped tx_dropped collisions; do
      v="$(sys_num "$iface_path/statistics/$c" || printf '0')"
      errs=$(( errs + 10#$v ))
    done
    rx_p="$(sys_num "$iface_path/statistics/rx_packets" || printf '0')"
    tx_p="$(sys_num "$iface_path/statistics/tx_packets" || printf '0')"
    pkts=$(( 10#$rx_p + 10#$tx_p ))
    crc="$(sys_num "$iface_path/statistics/rx_crc_errors" || printf '0')"
    fifo="$(sys_num "$iface_path/statistics/rx_fifo_errors" || printf '0')"
    verdict="$(awk -v e="$errs" -v p="$pkts" 'BEGIN { print (e >= 100 && e * 1000 > p) ? "warn" : "ok" }')"
    if [[ "$verdict" == "warn" ]]; then
      detail=""
      (( 10#$crc > 0 )) && detail=", $crc CRC"
      (( 10#$fifo > 0 )) && detail="$detail, $fifo FIFO overrun"
      warn "$iface has $errs RX/TX errors or drops in $(human_count "$pkts") packets$detail (since boot)" \
        "ethtool -S $iface | grep -iE 'err|drop'; check the cable, the switch port and the MTU"
    else
      ok "$iface: $errs errors or drops in $(human_count "$pkts") packets since boot"
    fi

    if [[ "$oper" == "up" ]]; then
      speed="$(sys_num "$iface_path/speed" 2>/dev/null || true)"
      duplex="$(tr -d '[:space:]' 2>/dev/null < "$iface_path/duplex" || true)"
      if [[ "$duplex" == "half" ]]; then
        warn "half duplex on $iface" "a duplex mismatch drops packets under load: ethtool $iface; ethtool -s $iface autoneg on"
      elif [[ -z "$speed" ]]; then
        info "$iface link speed unknown (the driver does not report it)"
      elif (( 10#$speed <= 100 )); then
        warn "$iface negotiated $speed Mb/s" "usually a bad cable or port on a gigabit link: ethtool $iface"
      else
        ok "$iface $speed Mb/s ${duplex:-unknown} duplex"
      fi
    fi

    flaps="$(sys_num "$iface_path/carrier_changes" || true)"
    if [[ -n "$flaps" ]]; then
      if [[ "$oper" == "up" ]] && (( 10#$flaps >= 10 )); then
        warn "$iface carrier changed $flaps times since boot" "journalctl -k -g 'Link is'"
      elif [[ "$oper" != "up" ]] && (( 10#$flaps > 0 )); then
        info "$iface is $oper after $flaps carrier change(s)"
      fi
    fi
  done
  (( virtual_n > 0 )) && info "$virtual_n virtual interface(s) not graded (no device behind them)"

  # A bond survives a dead leg silently; that is what it is for, and why
  # nobody notices until the second leg goes.
  if [[ -d "$PROC_NET_BONDING" ]]; then
    for bond_file in "$PROC_NET_BONDING"/*; do
      [[ -f "$bond_file" && -r "$bond_file" ]] || continue
      bond="$(basename "$bond_file" | clean)"
      bond_rows="$(clean < "$bond_file" | awk -F': ' '
        /^Currently Active Slave:/ && $2 == "None" { print "NOACTIVE -" }
        /^Slave Interface:/ { slave = $2; next }
        /^MII Status:/ && slave != "" { print ($2 == "up" ? "UP" : "DOWN"), slave; slave = "" }')"
      bond_up=0
      bond_bad=0
      while read -r state slave; do
        case "$state" in
          UP)       bond_up=$((bond_up + 1)) ;;
          DOWN)     bond_bad=$((bond_bad + 1)); warn "$bond slave $slave is down" "cat $bond_file; ip link show $slave" ;;
          NOACTIVE) bond_bad=$((bond_bad + 1)); warn "$bond has no active slave" "cat $bond_file" ;;
        esac
      done <<< "$bond_rows"
      (( bond_bad == 0 && bond_up > 0 )) && ok "$bond: $bond_up slave(s) up"
    done
  fi

  # The gateway's neighbour entry: FAILED or INCOMPLETE means ARP (or ND) is
  # going unanswered, which looks like a routing problem and is not one.
  if ! have ip; then
    skip "ip not installed; gateway neighbour not checked"
  elif [[ "$DEFAULT_GW" =~ ^[0-9.]+$ && "$DEFAULT_IF" =~ ^[A-Za-z0-9_.:@-]+$ ]]; then
    neigh="$(ip neigh show to "$DEFAULT_GW" dev "$DEFAULT_IF" 2>/dev/null | clean | head -n 1)"
    state="$(awk '{ print $NF }' <<<"$neigh")"
    case "$state" in
      FAILED|INCOMPLETE)
        warn "default gateway $DEFAULT_GW does not answer ARP/ND ($state)" "ping -c1 $DEFAULT_GW; ip neigh show dev $DEFAULT_IF"
        ;;
      REACHABLE|STALE|DELAY|PROBE|PERMANENT|NOARP)
        ok "gateway $DEFAULT_GW neighbour state $state"
        ;;
      "")
        info "no neighbour entry for $DEFAULT_GW yet (nothing has talked to the gateway)"
        ;;
      *)
        info "gateway $DEFAULT_GW neighbour state ${state:0:20}"
        ;;
    esac
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
