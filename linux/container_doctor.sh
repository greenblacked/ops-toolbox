#!/usr/bin/env bash
# container_doctor.sh
# Read-only report on Docker or Podman containers that misbehave or fill disks.
#
# system_doctor.sh counts containers and prints `system df`, which is enough to
# know an engine is there. The things that actually page somebody are not in
# that count: a container in a restart loop, one the kernel OOM-killed, a
# failing healthcheck, a json-file log with no size cap quietly filling
# /var/lib/docker, a privileged container, or one with the engine socket
# mounted, which is root on the host by another name. This turns `ps` and one
# `inspect` per container into graded findings, each with the command to look
# closer or the change to make.
#
# It changes nothing. The only engine verbs it runs are info, ps, inspect,
# images and system df; every fix (update, a daemon.json edit) is printed, not
# run. Each engine call is bounded by timeout(1) when it exists, so a wedged
# daemon slows the report down instead of hanging it. Names and image strings
# come from the daemon, so control characters are stripped before they are
# printed.
#
# Like system_doctor.sh it reads rather than gates by default; --fail-on turns
# it into a check.
#
# Exit codes:
#   0   report printed, nothing at or above --fail-on (always, by default)
#   1   one or more findings at or above --fail-on
#   2   preflight failed (not Linux)
#   3   bad CLI arguments
#   4   --only selected nothing
set -u
set -o pipefail

ENGINE_WANTED="auto"
RESTART_THRESHOLD=3
LOG_WARN_MB=500
ONLY=""
FAIL_ON="never"
QUIET=0

# Where the Docker daemon's defaults live. An environment variable rather than
# a flag, like ETC_SSH in hardening_audit.sh: it exists so the suite can point
# the log-cap check at a fixture instead of the host's file.
DAEMON_JSON="${DOCKER_DAEMON_JSON:-/etc/docker/daemon.json}"

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

# A finding is one line: verdict, what was checked, and — when it is not a
# pass — what to do about it. The fix is printed rather than run.
pass() { PASS_COUNT=$((PASS_COUNT + 1)); (( QUIET )) || printf "  %s[pass]%s %s\n" "$C_GREEN" "$C_RESET" "$1"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); printf "  %s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$1"; [[ -n "${2:-}" ]] && printf "         %s%s%s\n" "$C_DIM" "$2" "$C_RESET"; return 0; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf "  %s[FAIL]%s %s\n" "$C_RED" "$C_RESET" "$1"; [[ -n "${2:-}" ]] && printf "         %s%s%s\n" "$C_DIM" "$2" "$C_RESET"; return 0; }
skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); (( QUIET )) || printf "  %s[skip]%s %s\n" "$C_DIM" "$C_RESET" "$1"; }
info() {
  (( QUIET )) && return 0
  printf "  %s[info]%s %s\n" "$C_BLUE" "$C_RESET" "$1"
  [[ -n "${2:-}" ]] && printf "         %s%s%s\n" "$C_DIM" "$2" "$C_RESET"
  return 0
}
err()  { printf "%s[err ]%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; }

usage() {
  cat <<EOF
container_doctor.sh - read-only Docker/Podman container report

Grades restart loops, OOM kills, failing healthchecks, privileged containers,
engine-socket mounts, missing memory limits and unbounded container logs.
Changes nothing: fixes are printed, never run.

Usage:
  $(basename "$0") [--engine docker|podman|auto] [--restart-threshold N]
                     [--log-warn-mb N] [--only GROUPS] [--list-groups]
                     [--fail-on warn|fail|never] [--quiet]

Options:
  --engine NAME            docker, podman, or auto: the first that answers (default: auto)
  --restart-threshold N    Warn at this many restarts, 1 or more (default: $RESTART_THRESHOLD)
  --log-warn-mb N          Fail on a container log this many MiB or larger (default: $LOG_WARN_MB)
  --only GROUPS            Comma-separated subset (see --list-groups)
  --list-groups            Print the group names and exit
  --fail-on LEVEL          Exit 1 on 'fail', on 'warn' and above, or 'never' (default)
  --quiet                  Print only warnings and failures
  --help, -h               Show this help

Groups:
  state      restart loops, OOM kills, unhealthy healthchecks, failed exits that will not restart
  security   privileged containers, engine socket mounts, host network, root user
  resources  running containers with no memory limit
  logs       json-file logs with no max-size, and logs larger than --log-warn-mb
  images     dangling images, containers on a latest or untagged image

Exit codes: 0 report printed, 1 findings at or above --fail-on, 2 not Linux,
3 usage, 4 --only selected nothing
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

ALL_GROUPS="state security resources logs images"

while (( $# > 0 )); do
  case "$1" in
    --engine)              require_value "$1" "${2:-}"; ENGINE_WANTED="$2"; shift ;;
    --engine=*)            ENGINE_WANTED="${1#*=}"; require_value "--engine" "$ENGINE_WANTED" ;;
    --restart-threshold)   require_value "$1" "${2:-}"; RESTART_THRESHOLD="$2"; shift ;;
    --restart-threshold=*) RESTART_THRESHOLD="${1#*=}"; require_value "--restart-threshold" "$RESTART_THRESHOLD" ;;
    --log-warn-mb)         require_value "$1" "${2:-}"; LOG_WARN_MB="$2"; shift ;;
    --log-warn-mb=*)       LOG_WARN_MB="${1#*=}"; require_value "--log-warn-mb" "$LOG_WARN_MB" ;;
    --only)                require_value "$1" "${2:-}"; ONLY="$2"; shift ;;
    --only=*)              ONLY="${1#*=}"; require_value "--only" "$ONLY" ;;
    --fail-on)             require_value "$1" "${2:-}"; FAIL_ON="$2"; shift ;;
    --fail-on=*)           FAIL_ON="${1#*=}"; require_value "--fail-on" "$FAIL_ON" ;;
    --list-groups)         printf '%s\n' $ALL_GROUPS; exit 0 ;;
    --quiet)               QUIET=1 ;;
    -h|--help)             usage; exit 0 ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

case "$ENGINE_WANTED" in
  docker|podman|auto) ;;
  *) err "--engine must be docker, podman or auto, got: $ENGINE_WANTED"; exit 3 ;;
esac
case "$FAIL_ON" in
  warn|fail|never) ;;
  *) err "--fail-on must be warn, fail or never, got: $FAIL_ON"; exit 3 ;;
esac
if ! [[ "$RESTART_THRESHOLD" =~ ^[0-9]+$ ]] || (( RESTART_THRESHOLD < 1 || RESTART_THRESHOLD > 100000 )); then
  err "--restart-threshold must be an integer of 1 or more, got: $RESTART_THRESHOLD"
  exit 3
fi
if ! [[ "$LOG_WARN_MB" =~ ^[0-9]+$ ]] || (( LOG_WARN_MB < 1 || LOG_WARN_MB > 1048576 )); then
  err "--log-warn-mb must be an integer between 1 and 1048576, got: $LOG_WARN_MB"
  exit 3
fi

SELECTED=","
if [[ -n "$ONLY" ]]; then
  IFS=',' read -r -a requested <<< "$ONLY"
  for g in "${requested[@]}"; do
    g="$(printf '%s' "$g" | tr -d '[:space:]')"
    [[ -n "$g" ]] || continue
    case " $ALL_GROUPS " in
      *" $g "*) SELECTED="$SELECTED$g," ;;
      *) err "unknown group: $g (see --list-groups)"; exit 3 ;;
    esac
  done
  if [[ "$SELECTED" == "," ]]; then
    err "--only selected nothing"
    exit 4
  fi
fi

want() {
  [[ -z "$ONLY" ]] && return 0
  case "$SELECTED" in *",$1,"*) return 0 ;; esac
  return 1
}

# --help and --list-groups are handled above so they work anywhere.
if [[ "$(uname -s)" != "Linux" ]]; then
  err "this script targets Linux"
  exit 2
fi

group() { printf "\n%s== %s ==%s\n" "$C_BOLD" "$1" "$C_RESET"; }
have()  { command -v "$1" >/dev/null 2>&1; }

# Daemon output is attacker-influenced (anyone who can start a container names
# it), so control characters go before anything is printed. Tab and newline
# survive: the inspect template below is tab-separated.
clean() { tr -d '\000-\010\013-\037'; }

# Duplicated from system_doctor.sh on purpose (see CONTRIBUTING.md).
human_bytes() {
  awk -v b="$1" 'BEGIN {
    if (b >= 1099511627776) printf "%.1fT", b / 1099511627776;
    else if (b >= 1073741824) printf "%.1fG", b / 1073741824;
    else if (b >= 1048576) printf "%.0fM", b / 1048576;
    else printf "%dK", b / 1024
  }'
}

ENGINE=""
# Every engine call goes through here: one verb from the read-only list, and a
# ten-second ceiling when timeout(1) is installed.
eng() {
  if have timeout; then
    timeout 10 "$ENGINE" "$@"
  else
    "$ENGINE" "$@"
  fi
}

# Up to five names, comma-separated, for an aggregated line.
first_five() {
  awk 'NF { c++ } NF && c <= 5 { printf "%s%s", (c > 1 ? ", " : ""), $0 } END { if (c > 5) printf ", ..." }'
}

# --- engine ----------------------------------------------------------------
group "engine"
candidates="docker podman"
[[ "$ENGINE_WANTED" == "auto" ]] || candidates="$ENGINE_WANTED"
installed=""
for e in $candidates; do
  have "$e" || continue
  installed="$installed $e"
  ENGINE="$e"
  if eng info >/dev/null 2>&1; then
    break
  fi
  ENGINE=""
done

if [[ -z "$installed" ]]; then
  if [[ "$ENGINE_WANTED" == "auto" ]]; then
    skip "neither docker nor podman is installed"
  else
    skip "$ENGINE_WANTED is not installed"
  fi
elif [[ -z "$ENGINE" ]]; then
  # Installed and unreachable is the interesting case: the daemon is down or
  # this user is not in the group, and both look like "no containers".
  for e in $installed; do
    warn "$e is installed but not reachable" "systemctl status $e · or your user may not be in the '$e' group"
  done
else
  version="$(eng version --format '{{.Server.Version}}' 2>/dev/null | clean | head -n 1)"
  info "$ENGINE${version:+ $version} answered"
fi

ROWS=""
T=$'\t'
if [[ -n "$ENGINE" ]]; then
  ids="$(eng ps -a --format '{{.ID}}' 2>/dev/null | clean)"; ps_rc=$?
  if (( ps_rc != 0 )); then
    skip "$ENGINE ps exited $ps_rc; containers not checked"
  else
    # One inspect per container, tab-separated. A field that can be empty is
    # given a "-": tab is whitespace to `read`, so two tabs in a row would
    # collapse and every later field would land in the wrong variable.
    TEMPLATE="{{.Name}}${T}{{.State.Status}}${T}{{.State.ExitCode}}${T}{{.RestartCount}}${T}{{.State.OOMKilled}}${T}"
    TEMPLATE="${TEMPLATE}{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}${T}{{.HostConfig.Privileged}}${T}"
    TEMPLATE="${TEMPLATE}{{if .HostConfig.NetworkMode}}{{.HostConfig.NetworkMode}}{{else}}-{{end}}${T}{{.HostConfig.Memory}}${T}"
    TEMPLATE="${TEMPLATE}{{if .HostConfig.RestartPolicy.Name}}{{.HostConfig.RestartPolicy.Name}}{{else}}-{{end}}${T}{{.HostConfig.RestartPolicy.MaximumRetryCount}}${T}"
    TEMPLATE="${TEMPLATE}{{if .Config.User}}{{.Config.User}}{{else}}-{{end}}${T}"
    TEMPLATE="${TEMPLATE}{{if .HostConfig.LogConfig.Type}}{{.HostConfig.LogConfig.Type}}{{else}}-{{end}}${T}"
    TEMPLATE="${TEMPLATE}{{json .HostConfig.LogConfig.Config}}${T}{{if .LogPath}}{{.LogPath}}{{else}}-{{end}}${T}"
    TEMPLATE="${TEMPLATE}{{.Config.Image}}${T}-{{range .Mounts}},{{.Source}}{{end}}"
    n_ids=0
    n_failed=0
    while IFS= read -r cid; do
      [[ "$cid" =~ ^[A-Za-z0-9]+$ ]] || continue
      n_ids=$((n_ids + 1))
      row="$(eng inspect --format "$TEMPLATE" "$cid" 2>/dev/null | clean | head -n 1)"
      if [[ -z "$row" ]]; then
        n_failed=$((n_failed + 1))
        continue
      fi
      ROWS="${ROWS}${row}"$'\n'
    done <<< "$ids"
    if (( n_ids == 0 )); then
      info "no containers"
    else
      info "$n_ids container(s)"
    fi
    (( n_failed == 0 )) || skip "$n_failed container(s) could not be inspected (removed meanwhile, or an engine too old for this template)"
  fi
fi

# Each group reads the same rows. A here-string rather than a pipe, so the
# counters the helpers increment survive the loop.
each_row() {
  [[ -n "$ROWS" ]] || return 0
  printf '%s' "$ROWS"
}

# --- state -----------------------------------------------------------------
if want state && [[ -n "$ENGINE" && -n "$ROWS" ]]; then
  group "state"
  state_findings=0
  while IFS="$T" read -r name status code restarts oom health priv netmode mem policy maxretry user logtype logcfg logpath image mounts; do
    [[ -n "$name" ]] || continue
    name="${name#/}"
    name="${name:0:64}"
    if [[ "$status" == "restarting" ]] || { [[ "$restarts" =~ ^[0-9]+$ ]] && (( restarts >= RESTART_THRESHOLD )); }; then
      warn "$name is restarting: $restarts restart(s), status $status" "$ENGINE logs --tail 50 $name"
      state_findings=$((state_findings + 1))
    fi
    if [[ "$oom" == "true" ]]; then
      fail "$name was OOM-killed" "raise the limit or fix the leak: $ENGINE update --memory <limit> --memory-swap <limit> $name"
      state_findings=$((state_findings + 1))
    fi
    if [[ "$health" == "unhealthy" ]]; then
      fail "$name healthcheck is unhealthy" "$ENGINE inspect --format '{{json .State.Health}}' $name"
      state_findings=$((state_findings + 1))
    fi
    if [[ "$status" == "exited" && "$code" =~ ^[0-9]+$ ]] && (( code != 0 )) && [[ "$policy" == "no" || "$policy" == "-" ]]; then
      warn "$name exited with code $code and has no restart policy" "$ENGINE logs --tail 50 $name"
      state_findings=$((state_findings + 1))
    fi
    # on-failure:N stops retrying after N restarts, and the container stays
    # down. A maximum of 0 means unlimited, which never runs out.
    if [[ "$status" == "exited" && "$code" =~ ^[0-9]+$ ]] && (( code != 0 )) && [[ "$policy" == "on-failure" ]] \
      && [[ "$maxretry" =~ ^[0-9]+$ && "$restarts" =~ ^[0-9]+$ ]] && (( 10#$maxretry > 0 && 10#$restarts >= 10#$maxretry )); then
      warn "$name exited with code $code after $restarts of $maxretry allowed restart(s); on-failure gave up" "$ENGINE logs --tail 50 $name"
      state_findings=$((state_findings + 1))
    fi
  done <<< "$(each_row)"
  (( state_findings == 0 )) && pass "no restart loops, OOM kills, unhealthy checks or failed exits"
fi

# --- security --------------------------------------------------------------
if want security && [[ -n "$ENGINE" && -n "$ROWS" ]]; then
  group "security"
  sec_findings=0
  host_net=""
  as_root=""
  while IFS="$T" read -r name status code restarts oom health priv netmode mem policy maxretry user logtype logcfg logpath image mounts; do
    [[ -n "$name" ]] || continue
    name="${name#/}"
    name="${name:0:64}"
    if [[ "$priv" == "true" ]]; then
      warn "$name runs privileged" "drop --privileged and grant only what it needs: --cap-add, --device"
      sec_findings=$((sec_findings + 1))
    fi
    # The engine socket mounted into a container is root on the host: anything
    # in it can start a privileged container that mounts /.
    sock=""
    IFS=',' read -r -a srcs <<< "${mounts#-}"
    for src in "${srcs[@]+"${srcs[@]}"}"; do
      case "$src" in
        */docker.sock|*/podman.sock) sock="$src"; break ;;
      esac
    done
    if [[ -n "$sock" ]]; then
      fail "$name mounts the engine socket $sock: root on the host" "remove the mount, or put a socket proxy in front that allows only the calls it needs"
      sec_findings=$((sec_findings + 1))
    fi
    [[ "$netmode" == "host" ]] && host_net="$host_net$name"$'\n'
    [[ "$status" == "running" && "$user" == "-" ]] && as_root="$as_root$name"$'\n'
  done <<< "$(each_row)"
  if [[ -n "$host_net" ]]; then
    info "$(grep -c . <<<"$host_net") container(s) share the host network: $(first_five <<<"$host_net")"
  fi
  if [[ -n "$as_root" ]]; then
    info "$(grep -c . <<<"$as_root") running container(s) set no USER and run as root: $(first_five <<<"$as_root")"
  fi
  (( sec_findings == 0 )) && pass "no privileged containers and no engine socket mounts"
fi

# --- resources -------------------------------------------------------------
if want resources && [[ -n "$ENGINE" && -n "$ROWS" ]]; then
  group "resources"
  unlimited=""
  running=0
  while IFS="$T" read -r name status code restarts oom health priv netmode mem policy maxretry user logtype logcfg logpath image mounts; do
    [[ -n "$name" && "$status" == "running" ]] || continue
    running=$((running + 1))
    [[ "$mem" == "0" ]] && unlimited="$unlimited${name#/}"$'\n'
  done <<< "$(each_row)"
  if (( running == 0 )); then
    info "no running containers"
  elif [[ -n "$unlimited" ]]; then
    info "$(grep -c . <<<"$unlimited") running container(s) have no memory limit: $(first_five <<<"$unlimited")" \
      "one leak can then take the host's memory: --memory, or mem_limit in compose"
  else
    pass "every running container has a memory limit"
  fi
fi

# --- logs ------------------------------------------------------------------
if want logs && [[ -n "$ENGINE" && -n "$ROWS" ]]; then
  group "logs"
  # The daemon default applies to containers created after it was set, and a
  # container's own log-opt wins over it. Only grepped, never written.
  daemon_capped=0
  if [[ "$ENGINE" == "docker" && -r "$DAEMON_JSON" ]] && grep -q '"max-size"' "$DAEMON_JSON" 2>/dev/null; then
    daemon_capped=1
  fi
  unbounded=""
  sized=0
  unreadable=0
  big=0
  limit_bytes=$(( LOG_WARN_MB * 1048576 ))
  while IFS="$T" read -r name status code restarts oom health priv netmode mem policy maxretry user logtype logcfg logpath image mounts; do
    [[ -n "$name" ]] || continue
    name="${name#/}"
    name="${name:0:64}"
    if [[ "$logtype" == "json-file" && "$logcfg" != *'"max-size"'* ]] && (( daemon_capped == 0 )); then
      unbounded="$unbounded$name"$'\n'
    fi
    [[ "$logpath" == "-" || -z "$logpath" ]] && continue
    if [[ ! -r "$logpath" ]]; then
      unreadable=$((unreadable + 1))
      continue
    fi
    size="$(stat -c %s -- "$logpath" 2>/dev/null || printf '')"
    [[ "$size" =~ ^[0-9]+$ ]] || continue
    sized=$((sized + 1))
    if (( size >= limit_bytes )); then
      big=$((big + 1))
      fail "$name log is $(human_bytes "$size") ($logpath)" "cap it with log-opts max-size; the space comes back when the container is recreated"
    fi
  done <<< "$(each_row)"
  if [[ -n "$unbounded" ]]; then
    warn "$(grep -c . <<<"$unbounded") container(s) write an unbounded json-file log: $(first_five <<<"$unbounded")" \
      "add to $DAEMON_JSON, then recreate them: \"log-opts\": {\"max-size\": \"10m\", \"max-file\": \"3\"}"
  else
    pass "no json-file log without a size cap"
  fi
  if (( unreadable > 0 )); then
    skip "rerun with sudo to size container logs ($unreadable not readable)"
  elif (( sized > 0 && big == 0 )); then
    pass "no container log at or above ${LOG_WARN_MB} MiB"
  fi
fi

# --- images ----------------------------------------------------------------
if want images && [[ -n "$ENGINE" ]]; then
  group "images"
  dangling="$(eng images -f dangling=true -q 2>/dev/null | grep -c . || true)"
  [[ "$dangling" =~ ^[0-9]+$ ]] || dangling=0
  if (( dangling > 0 )); then
    info "$dangling dangling image(s)"
  else
    pass "no dangling images"
  fi
  df_out="$(eng system df 2>/dev/null | clean)"
  img_row="$(awk '$1 == "Images" { $1 = ""; sub(/^ +/, ""); print; exit }' <<<"$df_out")"
  [[ -n "$img_row" ]] && info "images (total active size reclaimable): ${img_row:0:120}"

  # A floating tag means the next pull can change what runs without anyone
  # deciding to. A digest pin (@sha256:) is the opposite and is never counted.
  floating=""
  while IFS="$T" read -r name status code restarts oom health priv netmode mem policy maxretry user logtype logcfg logpath image mounts; do
    [[ -n "$name" && -n "$image" ]] || continue
    case "$image" in
      *@sha256:*) continue ;;
      sha256:*) floating="$floating${name#/}"$'\n'; continue ;;
    esac
    last="${image##*/}"
    if [[ "$last" != *:* || "${last##*:}" == "latest" ]]; then
      floating="$floating${name#/}"$'\n'
    fi
  done <<< "$(each_row)"
  if [[ -n "$floating" ]]; then
    info "$(grep -c . <<<"$floating") container(s) run a latest or untagged image: $(first_five <<<"$floating")" \
      "pin a version tag or a digest so a pull cannot change what runs"
  fi
fi

# --- summary ---------------------------------------------------------------
printf "\n%s== summary ==%s\n" "$C_BOLD" "$C_RESET"
printf "  %s%s pass%s  %s%s warn%s  %s%s fail%s  %s%s skip%s\n" \
  "$C_GREEN" "$PASS_COUNT" "$C_RESET" \
  "$C_YELLOW" "$WARN_COUNT" "$C_RESET" \
  "$C_RED" "$FAIL_COUNT" "$C_RESET" \
  "$C_DIM" "$SKIP_COUNT" "$C_RESET"
info "cleaning is a separate, previewed step: ./disk_cleanup.sh --dry-run --include-docker"

case "$FAIL_ON" in
  warn) (( WARN_COUNT + FAIL_COUNT > 0 )) && exit 1 ;;
  fail) (( FAIL_COUNT > 0 )) && exit 1 ;;
esac
exit 0
