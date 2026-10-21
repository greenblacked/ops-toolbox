#!/usr/bin/env bash
# net_doctor.sh
# Read-only "the network is wrong" report for a Mac.
#
# The macOS half of linux/net_doctor.sh: interfaces, the default route, DNS,
# listening sockets and an opt-in probe, read from scutil, route, ifconfig,
# lsof and dscacheutil instead of ip and /etc/resolv.conf. It adds the two
# traps a laptop that hops between office, home, VPN, Tailscale and WARP
# falls into on a Mac:
#
#   - split DNS. A VPN installs a resolver for its own domains only, so
#     corp names resolve and everything else does not, or the reverse.
#     /etc/resolv.conf shows none of it; `scutil --dns` does.
#   - the system proxy. Browsers follow System Settings; curl, git, brew and
#     kubectl read https_proxy and ignore the system setting entirely.
#
# It also lists /etc/hosts overrides, the VPN services and tunnels that are
# up, and whether this Mac's own hostname resolves (sudo and git stall for
# seconds when it does not).
#
# Read-only and local by default. The only network traffic is the explicit
# --probe: one DNS lookup and one TCP connection, capped at five seconds. No
# sudo, no log file, no change to a resolver or a proxy; every fix is printed.
#
# Exit codes:
#   0   the report ran (warnings do not change the exit code)
#   1   --strict and at least one warning
#   2   preflight failed (not macOS)
#   3   bad CLI arguments
set -u
set -o pipefail

QUIET=0
STRICT=0
SKIP_LISTEN=0
PROBE=""
HOSTS_FILE="/etc/hosts"

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
net_doctor.sh - read-only network report for a Mac

Describes interfaces, the default route, DNS (split and scoped resolvers),
the system proxy against the shell's proxy variables, VPN services and
tunnels, /etc/hosts overrides, listening sockets and an optional probe.
Changes nothing. For firewall findings, use hardening_audit.sh --only firewall.

Usage:
  $(basename "$0") [--probe HOST[:PORT]] [--skip-listen] [--hosts-file PATH] [--strict] [--quiet]

Options:
  --probe HOST[:PORT]  Resolve HOST and try one TCP connection to PORT
                       (default 443), capped at five seconds
  --skip-listen        Don't list listening TCP sockets
  --hosts-file PATH    Hosts file to read (default: /etc/hosts)
  --strict             Exit 1 when the report has any warning
  --quiet              Print only warnings and the summary
  --help, -h           Show this help

Sections: interfaces, routes, dns, proxy, vpn, hosts, listen, probe

Exit codes: 0 report printed, 1 --strict and a warning, 2 not macOS, 3 usage
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
    --probe)        require_value "$1" "${2:-}"; PROBE="$2"; shift ;;
    --probe=*)      PROBE="${1#*=}"; require_value "--probe" "$PROBE" ;;
    --hosts-file)   require_value "$1" "${2:-}"; HOSTS_FILE="$2"; shift ;;
    --hosts-file=*) HOSTS_FILE="${1#*=}"; require_value "--hosts-file" "$HOSTS_FILE" ;;
    --skip-listen)  SKIP_LISTEN=1 ;;
    --strict)       STRICT=1 ;;
    --quiet)        QUIET=1 ;;
    -h|--help)      usage; exit 0 ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

# HOST is a name or an IPv4 address; anything else would reach dscacheutil
# and nc as an argument, so it is refused here rather than quoted there.
PROBE_HOST=""
PROBE_PORT="443"
if [[ -n "$PROBE" ]]; then
  PROBE_HOST="${PROBE%%:*}"
  if [[ "$PROBE" == *:* ]]; then
    PROBE_PORT="${PROBE#*:}"
  fi
  if [[ ! "$PROBE_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
    err "--probe host must be a host name or an IPv4 address, got: $PROBE_HOST"
    exit 3
  fi
  if [[ ! "$PROBE_PORT" =~ ^[0-9]{1,5}$ ]] || (( 10#$PROBE_PORT < 1 || 10#$PROBE_PORT > 65535 )); then
    err "--probe port must be 1-65535, got: $PROBE_PORT"
    exit 3
  fi
  PROBE_PORT=$((10#$PROBE_PORT))
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  err "this script targets macOS"
  exit 2
fi

group() { printf "\n%s== %s ==%s\n" "$C_BOLD" "$1" "$C_RESET"; }
have()  { command -v "$1" >/dev/null 2>&1; }

# Text from the system and from the hosts file is data: control characters
# are stripped before it is printed.
clean() { printf '%s' "$1" | tr -d '\000-\037\177'; }

# macOS has no timeout(1). perl ships with it, and alarm survives exec, so
# the command runs as this one process and SIGALRM ends it on time.
with_timeout() {
  local secs="$1"
  shift
  if have perl; then
    perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"
  else
    "$@"
  fi
}

# --- interfaces ------------------------------------------------------------
# One record per interface: name|flags|first inet|status. Loopback is left
# out; utun tunnels are reported under vpn instead.
group "interfaces"
IFACES=""
if have ifconfig; then
  IFACES="$(ifconfig -a 2>/dev/null | awk '
    function flush() { if (name != "") print name "|" up "|" inet "|" status }
    /^[A-Za-z0-9]+:/ {
      flush()
      name = $1; sub(/:$/, "", name)
      up = ($0 ~ /<UP[,>]/) ? "up" : "down"
      inet = ""; status = ""
      next
    }
    /^[ \t]+inet / && inet == "" { inet = $2; next }
    /^[ \t]+status:/ { status = $2; next }
    END { flush() }')"
  active=0
  while IFS='|' read -r name up inet status; do
    [[ -n "$name" ]] || continue
    case "$name" in lo*|utun*) continue ;; esac
    [[ -n "$inet" || "$status" == "active" ]] || continue
    line="$(clean "$name") ${status:-$up}${inet:+ $(clean "$inet")}"
    if [[ -n "$inet" && "$up" == "up" ]]; then
      active=1
      ok "$line"
    else
      info "$line"
    fi
  done <<< "$IFACES"
  if (( active == 0 )); then
    warn "no active interface has an IPv4 address" "networksetup -listallhardwareports"
  fi
else
  skip "ifconfig not found"
fi

# --- routes ----------------------------------------------------------------
group "routes"
if have route; then
  rt="$(route -n get default 2>/dev/null)" || rt=""
  gw="$(awk '$1 == "gateway:" { print $2; exit }' <<< "$rt")"
  dev="$(awk '$1 == "interface:" { print $2; exit }' <<< "$rt")"
  if [[ -n "$dev" ]]; then
    ok "default via ${gw:-link} dev $(clean "$dev")"
  else
    warn "no default IPv4 route" \
         "check the active service: networksetup -listallnetworkservices"
  fi
  # IPv6 is reported, not graded: a v4-only network is common and not a fault.
  rt6="$(route -n get -inet6 default 2>/dev/null)" || rt6=""
  dev6="$(awk '$1 == "interface:" { print $2; exit }' <<< "$rt6")"
  if [[ -n "$dev6" ]]; then
    info "default IPv6 route via $(clean "$dev6")"
  else
    info "no default IPv6 route"
  fi
else
  skip "route not found"
fi

# --- dns -------------------------------------------------------------------
# scutil --dns lists the resolvers in order, then the scoped ones that apply
# to a single interface. Resolver #1 of the first list is the one most names
# go to; a later resolver carrying a "domain" line takes only that domain,
# which is how a VPN splits DNS. The mDNS resolvers macOS installs for .local
# and link-local have no nameserver and are left out.
group "dns"
if have scutil; then
  dns="$(scutil --dns 2>/dev/null | awk '
    function flush(   n, a, i) {
      if (cur != "" && rsec == "main") {
        if (cur == "1") {
          n = split(ns, a, ",")
          for (i = 1; i <= n; i++) print "primary " a[i]
        } else if (dom != "" && ns != "" && !mdns) {
          print "split " dom " " ns
        }
      }
      cur = ""; dom = ""; ns = ""; mdns = 0
    }
    /^DNS configuration \(for scoped queries\)/ { flush(); section = "scoped"; next }
    /^DNS configuration/ { flush(); section = "main"; next }
    /^resolver #/ {
      flush()
      cur = $2; sub(/^#/, "", cur)
      rsec = section
      if (section == "main") main++; else scoped++
      next
    }
    /^[ \t]+nameserver\[[0-9]+\][ \t]*:/ {
      v = $0; sub(/^[^:]*:[ \t]*/, "", v)
      ns = (ns == "" ? v : ns "," v)
      next
    }
    /^[ \t]+search domain\[[0-9]+\][ \t]*:/ {
      v = $0; sub(/^[^:]*:[ \t]*/, "", v)
      if (section == "main" && cur == "1") print "search " v
      next
    }
    /^[ \t]+domain[ \t]*:/ { v = $0; sub(/^[^:]*:[ \t]*/, "", v); dom = v; next }
    /^[ \t]+options[ \t]*:.*mdns/ { mdns = 1; next }
    END { flush(); print "count " main + 0; print "scoped " scoped + 0 }')"
  primary=""
  search=""
  count=0
  scoped=0
  while read -r kind a b; do
    case "$kind" in
      primary) primary="${primary:+$primary, }$(clean "$a")" ;;
      search)  search="${search:+$search }$(clean "$a")" ;;
      split)   info "split DNS: $(clean "$a") goes to $(clean "$b")" ;;
      count)   count="$a" ;;
      scoped)  scoped="$a" ;;
    esac
  done <<< "$dns"
  if [[ -n "$primary" ]]; then
    ok "primary resolver: $primary"
  else
    warn "the primary resolver has no nameserver" \
         "networksetup -getdnsservers Wi-Fi · or the VPN client took DNS and left nothing behind"
  fi
  [[ -n "$search" ]] && info "search domains: $search"
  info "$count resolver(s), $scoped scoped to one interface (scutil --dns)"
else
  skip "scutil not found"
fi

# sudo and git stall for seconds when the Mac's own hostname does not
# resolve. That is not a routing problem; it is a missing hosts line.
if have hostname && have dscacheutil; then
  hn="$(hostname 2>/dev/null)"
  if [[ "$hn" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
    hn_out="$(with_timeout 5 dscacheutil -q host -a name "$hn" 2>/dev/null)" || hn_out=""
    hn_ip="$(awk '$1 == "ip_address:" || $1 == "ipv6_address:" { print $2; exit }' <<< "$hn_out")"
    if [[ -n "$hn_ip" ]]; then
      ok "hostname $hn resolves to $(clean "$hn_ip")"
    else
      warn "hostname $hn does not resolve" \
           "sudo and git stall until it does: echo \"127.0.0.1 $hn\" | sudo tee -a /etc/hosts"
    fi
  fi
fi

# --- proxy -----------------------------------------------------------------
# Only enable flags and host:port are read from scutil --proxy. The shell's
# proxy variables are reported by name, never by value: a proxy URL can carry
# a user name and password.
group "proxy"
env_proxy=""
for var in https_proxy HTTPS_PROXY http_proxy HTTP_PROXY all_proxy ALL_PROXY; do
  case "$var" in
    https_proxy) val="${https_proxy:-}" ;;
    HTTPS_PROXY) val="${HTTPS_PROXY:-}" ;;
    http_proxy)  val="${http_proxy:-}" ;;
    HTTP_PROXY)  val="${HTTP_PROXY:-}" ;;
    all_proxy)   val="${all_proxy:-}" ;;
    ALL_PROXY)   val="${ALL_PROXY:-}" ;;
  esac
  [[ -n "$val" ]] && env_proxy="${env_proxy:+$env_proxy }$var"
done
env_https=0
case " $env_proxy " in *" https_proxy "*|*" HTTPS_PROXY "*) env_https=1 ;; esac

if have scutil; then
  px="$(scutil --proxy 2>/dev/null | awk '
    $1 ~ /^(HTTPEnable|HTTPProxy|HTTPPort|HTTPSEnable|HTTPSProxy|HTTPSPort|ProxyAutoConfigEnable)$/ && $2 == ":" {
      print $1 " " $3
    }')"
  http_on=0; https_on=0; pac_on=0; http_host=""; http_port=""; https_host=""; https_port=""
  while read -r key value; do
    case "$key" in
      HTTPEnable)            [[ "$value" == "1" ]] && http_on=1 ;;
      HTTPSEnable)           [[ "$value" == "1" ]] && https_on=1 ;;
      ProxyAutoConfigEnable) [[ "$value" == "1" ]] && pac_on=1 ;;
      HTTPProxy)             http_host="$(clean "$value")" ;;
      HTTPPort)              http_port="$(clean "$value")" ;;
      HTTPSProxy)            https_host="$(clean "$value")" ;;
      HTTPSPort)             https_port="$(clean "$value")" ;;
    esac
  done <<< "$px"
  sys=""
  (( https_on )) && sys="HTTPS ${https_host}:${https_port}"
  (( http_on )) && sys="${sys:+$sys, }HTTP ${http_host}:${http_port}"
  (( pac_on )) && sys="${sys:+$sys, }automatic configuration (PAC)"
  if [[ -n "$sys" ]]; then
    if (( env_https )); then
      ok "system proxy: $sys; the shell sets $env_proxy too"
    else
      target="${https_host:-$http_host}"
      port="${https_port:-$http_port}"
      if [[ -n "$target" && "$target" =~ ^[A-Za-z0-9.-]+$ && "$port" =~ ^[0-9]+$ ]]; then
        hint="export https_proxy=http://$target:$port http_proxy=http://$target:$port"
      else
        hint="export https_proxy to the proxy the PAC file selects"
      fi
      warn "system proxy is on ($sys): browsers use it, curl/git/brew/kubectl do not" "$hint"
    fi
  elif [[ -n "$env_proxy" ]]; then
    info "the shell sets $env_proxy but the system proxy is off: CLI tools use it, browsers do not"
  else
    ok "no system proxy and no proxy variables in this shell"
  fi
else
  skip "scutil not found"
fi

# --- vpn -------------------------------------------------------------------
# Connected VPN services from System Settings, and utun tunnels holding an
# IPv4 address, which is how Tailscale, WARP and IKEv2 clients show up.
group "vpn"
vpn_seen=0
if have scutil; then
  while IFS= read -r line; do
    [[ "$line" == *"(Connected)"* ]] || continue
    vpn_seen=1
    svc="$(sed -n 's/.*"\(.*\)".*/\1/p' <<< "$line")"
    info "VPN service connected: $(clean "${svc:-unnamed}")"
  done <<< "$(scutil --nc list 2>/dev/null)"
fi
while IFS='|' read -r name up inet status; do
  case "$name" in utun*) ;; *) continue ;; esac
  [[ -n "$inet" ]] || continue
  vpn_seen=1
  info "tunnel $(clean "$name") $(clean "$inet") (a VPN or overlay network)"
done <<< "$IFACES"
(( vpn_seen )) || info "no VPN service connected and no tunnel with an IPv4 address"

# --- hosts -----------------------------------------------------------------
# Every line beyond the stock localhost and broadcasthost entries overrides
# DNS for that name. They are listed, not judged: a 127.0.0.1 line is often a
# deliberate block, and sometimes the reason a name "resolves wrong".
group "hosts"
if [[ -r "$HOSTS_FILE" ]]; then
  custom=0
  listed=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    read -r addr names <<< "$line"
    [[ -n "$addr" && -n "$names" ]] || continue
    case "$addr $names" in
      "127.0.0.1 localhost"|"255.255.255.255 broadcasthost"|"::1 localhost"|"fe80::1%lo0 localhost") continue ;;
    esac
    custom=$((custom + 1))
    if (( custom <= 10 )); then
      listed="$listed$(clean "$addr $names")"$'\n'
    fi
  done < "$HOSTS_FILE"
  if (( custom == 0 )); then
    ok "no custom entries in $HOSTS_FILE"
  else
    entries="entries"
    (( custom == 1 )) && entries="entry"
    info "$custom custom $entries in $HOSTS_FILE override DNS"
    while IFS= read -r entry; do
      [[ -n "$entry" ]] && info "  $entry"
    done <<< "$listed"
    (( custom > 10 )) && info "  ... and $((custom - 10)) more"
  fi
else
  skip "$HOSTS_FILE unreadable"
fi

# --- listen ----------------------------------------------------------------
# This user's listening TCP sockets. Bound to loopback is local only; any
# other address is reachable from the network unless the firewall says no.
group "listen"
if (( SKIP_LISTEN )); then
  skip "listening sockets (--skip-listen)"
elif ! have lsof; then
  skip "lsof not found"
else
  listen="$(with_timeout 10 lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk '
    NR > 1 {
      name = $(NF - 1)
      if (name !~ /:[0-9]+$/) next
      port = name; sub(/^.*:/, "", port)
      addr = name; sub(/:[0-9]+$/, "", addr)
      scope = (addr ~ /^(127\.|\[::1\]|localhost)/) ? "loopback" : "network"
      key = $1 ":" port " " scope
      if (!(key in seen)) { seen[key] = 1; print $1 " " port " " addr " " scope }
    }')"
  n=0
  while read -r cmd port addr scope; do
    [[ -n "$cmd" ]] || continue
    n=$((n + 1))
    (( n <= 15 )) || continue
    if [[ "$scope" == "network" ]]; then
      info "$(clean "$cmd"):$port on $(clean "$addr") (reachable from the network)"
    else
      info "$(clean "$cmd"):$port on loopback"
    fi
  done <<< "$listen"
  if (( n == 0 )); then
    ok "no listening TCP sockets for this user"
  else
    ok "$n listening TCP socket(s) for this user"
    (( n > 15 )) && info "... and $((n - 15)) more: lsof -nP -iTCP -sTCP:LISTEN"
  fi
fi

# --- probe -----------------------------------------------------------------
if [[ -n "$PROBE_HOST" ]]; then
  group "probe"
  addr=""
  if have dscacheutil; then
    pr="$(with_timeout 5 dscacheutil -q host -a name "$PROBE_HOST" 2>/dev/null)" || pr=""
    addr="$(awk '$1 == "ip_address:" { print $2; exit }' <<< "$pr")"
    addr="$(clean "$addr")"
  fi
  if [[ "$PROBE_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    addr="$PROBE_HOST"
  fi
  if [[ -n "$addr" ]]; then
    ok "$PROBE_HOST resolves to $addr"
  else
    warn "could not resolve $PROBE_HOST" "dscacheutil -q host -a name $PROBE_HOST"
  fi
  if [[ -n "$addr" ]]; then
    if ! have nc; then
      skip "nc not found; not probing TCP"
    elif with_timeout 8 nc -z -G 5 "$addr" "$PROBE_PORT" >/dev/null 2>&1; then
      ok "$addr:$PROBE_PORT accepted a TCP connection"
    else
      warn "no TCP path to $addr:$PROBE_PORT" "repeat it with: nc -vz -G 5 $addr $PROBE_PORT"
    fi
  fi
fi

# --- summary ---------------------------------------------------------------
printf "\n%s== summary ==%s\n" "$C_BOLD" "$C_RESET"
printf "  %s%s ok%s  %s%s warn%s  %s%s skip%s\n" \
  "$C_GREEN" "$OK_COUNT" "$C_RESET" \
  "$C_YELLOW" "$WARN_COUNT" "$C_RESET" \
  "$C_DIM" "$SKIP_COUNT" "$C_RESET"
info "for firewall posture: hardening_audit.sh --only firewall,sharing"

if (( STRICT )) && (( WARN_COUNT > 0 )); then
  exit 1
fi
exit 0
