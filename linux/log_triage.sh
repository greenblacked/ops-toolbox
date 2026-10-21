#!/usr/bin/env bash
# log_triage.sh
# Read-only "what has been going wrong" report from a Linux machine's logs.
#
# system_doctor.sh answers "is this machine well" and shows at most twenty raw
# error lines since boot. The next question on a box someone hands you is a
# different one: what has been breaking, who is knocking, and what did the
# kernel complain about. This reads the journal (and the classic auth log when
# there is one) for a window, --since, and groups what it finds instead of
# dumping it:
#
#   kernel   the kernel's own distress signals, one counted line per class:
#            OOM kills, crashes, storage and filesystem errors, hung tasks,
#            hardware errors, link drops
#   units    which syslog identifiers logged the most error-level lines
#   auth     failed SSH logins grouped by source address, accepted logins,
#            failed sudo
#   repeats  the messages repeated most often, with numbers folded so one
#            message with a changing counter reads as one message
#
# Everything printed is bounded: a section prints a fixed number of lines
# whatever the log holds, so a hostile or runaway log cannot flood the
# terminal, and log text is stripped of control characters before it is
# printed, so an escape sequence planted in a log line (a username is enough)
# cannot drive the terminal reading the report. Passwords never reach the
# report: authentication lines are reduced to counts, source addresses and the
# first few invalid user names.
#
# It changes nothing and writes nothing: no log file, no sudo, no network.
#
# Exit codes:
#   0   the report ran (warnings do not change the exit code)
#   1   --fail-on warn, and at least one warning was printed
#   2   preflight failed (not Linux)
#   3   bad CLI arguments
#   4   --only selected nothing
set -u
set -o pipefail

SINCE="24 hours ago"
TOP_N=5
ONLY=""
FAIL_ON="never"
QUIET=0
LIST_SECTIONS=0

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
fi

OK_COUNT=0
WARN_COUNT=0
SKIP_COUNT=0

# Same helpers as system_doctor.sh: verdict, what was looked at, and — when it
# is not healthy — the command that shows you more on a dimmed second line.
ok()   { OK_COUNT=$((OK_COUNT + 1)); (( QUIET )) || printf "  %s[ ok ]%s %s\n" "$C_GREEN" "$C_RESET" "$1"; }
info() {
  (( QUIET )) && return 0
  printf "  %s[info]%s %s\n" "$C_BLUE" "$C_RESET" "$1"
  [[ -n "${2:-}" ]] && printf "         %s%s%s\n" "$C_DIM" "$2" "$C_RESET"
  return 0
}
skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); (( QUIET )) || printf "  %s[skip]%s %s\n" "$C_DIM" "$C_RESET" "$1"; }
warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  printf "  %s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$1"
  [[ -n "${2:-}" ]] && printf "         %s%s%s\n" "$C_DIM" "$2" "$C_RESET"
  return 0
}
err()  { printf "%s[err ]%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; }

# id|label
SECTIONS=(
  "kernel|OOM kills, crashes, storage, filesystem, hung task, hardware and link messages"
  "units|syslog identifiers with the most error-level lines"
  "auth|failed SSH logins by source, accepted logins, failed sudo"
  "repeats|the most repeated warning-level messages"
)

usage() {
  cat <<EOF
log_triage.sh - read-only summary of what went wrong in the logs

Groups the journal (and /var/log/auth.log or /var/log/secure) since a point
in time instead of dumping it. Changes nothing and writes nothing. For the
state of the machine rather than its history, use system_doctor.sh.

Usage:
  $(basename "$0") [--since WHEN] [--top N] [--only LIST] [--list-sections]
                [--fail-on warn|never] [--quiet]

Options:
  --since WHEN       Window start, as journalctl --since reads it
                     (default: "$SINCE"); letters, digits, spaces and : . + -
  --top N            Rows per ranked list, 1-50 (default: $TOP_N)
  --only LIST        Comma-separated sections (see --list-sections)
  --list-sections    Print the section ids and exit
  --fail-on LEVEL    Exit 1 on 'warn', or 'never' (default)
  --quiet            Print only warnings
  --help, -h         Show this help

Sections:
EOF
  local row
  for row in "${SECTIONS[@]}"; do
    printf "  %-9s %s\n" "${row%%|*}" "${row#*|}"
  done
  cat <<EOF

Environment: AUTH_LOG names the auth log file to read instead of the first
readable of /var/log/auth.log and /var/log/secure.

Exit codes: 0 report printed, 1 warnings with --fail-on warn, 2 not Linux,
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

while (( $# > 0 )); do
  case "$1" in
    --since)         require_value "$1" "${2:-}"; SINCE="$2"; shift ;;
    --since=*)       SINCE="${1#*=}"; require_value "--since" "$SINCE" ;;
    --top)           require_value "$1" "${2:-}"; TOP_N="$2"; shift ;;
    --top=*)         TOP_N="${1#*=}"; require_value "--top" "$TOP_N" ;;
    --only)          require_value "$1" "${2:-}"; ONLY="$2"; shift ;;
    --only=*)        ONLY="${1#*=}"; require_value "--only" "$ONLY" ;;
    --fail-on)       require_value "$1" "${2:-}"; FAIL_ON="$2"; shift ;;
    --fail-on=*)     FAIL_ON="${1#*=}"; require_value "--fail-on" "$FAIL_ON" ;;
    --list-sections) LIST_SECTIONS=1 ;;
    --quiet)         QUIET=1 ;;
    -h|--help)       usage; exit 0 ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

if (( LIST_SECTIONS )); then
  for row in "${SECTIONS[@]}"; do
    printf '%s\n' "${row%%|*}"
  done
  exit 0
fi

# --since is handed to journalctl as an argument, so it is held to an
# allow-list rather than trusted: a value starting with a dash would be read as
# another journalctl option, and nothing that journalctl's time syntax needs
# ("2 hours ago", "2026-10-01 08:00", "yesterday", "-1h" is the one form left
# out) contains a quote, a dollar or a slash.
since_re='^[A-Za-z0-9 :.+-]+$'
if [[ "$SINCE" == -* ]] || (( ${#SINCE} > 64 )) || ! [[ "$SINCE" =~ $since_re ]]; then
  err "--since must be at most 64 characters of letters, digits, spaces and : . + - and must not start with '-', got: $SINCE"
  exit 3
fi
if ! [[ "$TOP_N" =~ ^[0-9]+$ ]] || (( TOP_N < 1 || TOP_N > 50 )); then
  err "--top must be an integer between 1 and 50, got: $TOP_N"
  exit 3
fi
case "$FAIL_ON" in
  warn|never) ;;
  *) err "--fail-on must be warn or never, got: $FAIL_ON"; exit 3 ;;
esac

SELECTED=()
known=" "
for row in "${SECTIONS[@]}"; do
  known="$known ${row%%|*} "
done
if [[ -n "$ONLY" ]]; then
  IFS=',' read -r -a items <<< "$ONLY"
  for raw in "${items[@]}"; do
    id="$(printf '%s' "$raw" | tr -d '[:space:]')"
    [[ -n "$id" ]] || continue
    case "$known" in
      *" $id "*) SELECTED+=("$id") ;;
      *) err "unknown section in --only: $id (see --list-sections)"; exit 3 ;;
    esac
  done
  if (( ${#SELECTED[@]} == 0 )); then
    err "--only selected nothing"
    exit 4
  fi
else
  for row in "${SECTIONS[@]}"; do
    SELECTED+=("${row%%|*}")
  done
fi

want() {
  local needle="$1" s
  for s in "${SELECTED[@]}"; do
    [[ "$s" == "$needle" ]] && return 0
  done
  return 1
}

# --help and --list-sections are handled above so they work anywhere; the
# report itself reads Linux logs.
if [[ "$(uname -s)" != "Linux" ]]; then
  err "this script targets Linux"
  exit 2
fi

group() { printf "\n%s== %s ==%s\n" "$C_BOLD" "$1" "$C_RESET"; }
have()  { command -v "$1" >/dev/null 2>&1; }

# Log text is written by whoever can make a process log, which on most
# machines is anyone: `logger`, a username typed at the SSH prompt, a request
# path. Control characters are deleted before anything from a log is printed,
# so an ANSI escape in a log line stays inert text (tab and newline are kept).
clean() { tr -d '\000-\010\013-\037'; }

# A token copied from a log into a printed command must be something a shell
# reads as one plain word. Anything else is shown without a ready-made command,
# so a syslog identifier like $(...) can never become a hint someone pastes.
plain_token() { [[ "$1" =~ ^[A-Za-z0-9_.@-]+$ ]]; }

# --- sources ---------------------------------------------------------------
# journalctl prints "No journal files were found." on stderr when there is
# nothing to read (a container); that is "no journal", not "a quiet journal",
# and saying ok on it would be a false all-clear. Only stderr is captured so no
# log content is read by the probe. A user outside systemd-journal, adm and
# wheel sees only their own messages, which would also read as quiet.
JOURNAL="none"
if have journalctl; then
  jprobe="$(journalctl -n 1 --no-pager 2>&1 >/dev/null)"
  if [[ "$jprobe" == *"No journal files were found"* ]]; then
    JOURNAL="none"
  elif [[ "$(id -u)" == "0" ]]; then
    JOURNAL="ok"
  else
    case " $(id -nG 2>/dev/null) " in
      *" systemd-journal "*|*" adm "*|*" wheel "*) JOURNAL="ok" ;;
      *) JOURNAL="denied" ;;
    esac
  fi
fi
DENIED_MSG="journal not readable (add yourself to systemd-journal/adm or rerun with sudo)"

# Every journal read goes through here: the window, no pager, the short format
# the parsers below expect, and -q so journalctl's own notices are not parsed
# as log lines. The output is cleaned once, on the way in.
jread() {
  journalctl "$@" --since "$SINCE" --no-pager -o short -q 2>/dev/null | clean
}

# --- kernel ----------------------------------------------------------------
if want kernel; then
  group "kernel"
  kout=""
  ksrc=""
  if [[ "$JOURNAL" == "ok" ]]; then
    kout="$(jread -k)"; k_rc=$?
    if (( k_rc != 0 )); then
      skip "journalctl -k exited $k_rc (is --since \"$SINCE\" a time journalctl understands?)"
    else
      ksrc="journal"
    fi
  elif have dmesg; then
    # dmesg has no window of its own, so this is everything since boot; a
    # kernel with dmesg_restrict=1 refuses an unprivileged reader outright.
    kout="$(dmesg 2>/dev/null | clean)"; k_rc=$?
    if (( k_rc == 0 )) && [[ -n "$kout" ]]; then
      ksrc="dmesg"
      info "reading dmesg (since boot): the journal is $([[ "$JOURNAL" == "denied" ]] && printf 'not readable' || printf 'not available')"
    elif [[ "$JOURNAL" == "denied" ]]; then
      skip "$DENIED_MSG"
    else
      skip "no journal and dmesg is not readable (kernel.dmesg_restrict? rerun with sudo)"
    fi
  elif [[ "$JOURNAL" == "denied" ]]; then
    skip "$DENIED_MSG"
  else
    skip "neither journalctl nor dmesg is available"
  fi

  if [[ -n "$ksrc" ]]; then
    # label;pattern — one counted line per class. Patterns are extended,
    # case-insensitive regexes; the same text is offered back as the hint.
    kernel_classes=(
      "OOM;out of memory|oom-kill|killed process"
      "crash;segfault|general protection fault|traps:"
      "storage;blk_update_request|I/O error|Buffer I/O|nvme.*(timeout|reset)|ata[0-9.]+: .*(error|exception)"
      "filesystem;EXT4-fs error|XFS.*(error|corruption)|Remounting filesystem read-only|BTRFS.*error"
      "hung task;blocked for more than|soft lockup|hung task"
      "hardware;Machine check|mce:|Hardware Error|EDAC"
      "link down;Link is Down|NIC Link is Down"
    )
    k_found=0
    for row in "${kernel_classes[@]}"; do
      label="${row%%;*}"
      pattern="${row#*;}"
      n="$(grep -ciE -- "$pattern" <<<"$kout" || true)"
      [[ "$n" =~ ^[0-9]+$ ]] || n=0
      (( n > 0 )) || continue
      k_found=1
      first="$(grep -m 1 -iE -- "$pattern" <<<"$kout" || true)"
      if [[ "$ksrc" == "journal" ]]; then
        hint="journalctl -k --since \"$SINCE\" -g '$pattern'"
      else
        hint="dmesg | grep -iE '$pattern'"
      fi
      # A cable pulled once is a fact; the same link dropping five times in
      # the window is a finding.
      if [[ "$label" == "link down" ]] && (( n < 5 )); then
        info "$n $label message(s) in the kernel log" "$hint"
      else
        warn "$n $label message(s) in the kernel log" "$hint"
      fi
      (( QUIET )) || printf '           %s\n' "${first:0:160}"
    done
    if (( k_found == 0 )); then
      if [[ "$ksrc" == "journal" ]]; then
        ok "no kernel distress messages since $SINCE"
      else
        ok "no kernel distress messages since boot"
      fi
    fi
  fi
fi

# --- units -----------------------------------------------------------------
if want units; then
  group "units"
  if [[ "$JOURNAL" == "ok" ]]; then
    uout="$(jread -p err)"; u_rc=$?
    if (( u_rc != 0 )); then
      skip "journalctl -p err exited $u_rc"
    elif [[ -z "$uout" ]]; then
      ok "no error-level journal lines since $SINCE"
    else
      # -o short is "Mon DD HH:MM:SS host ident[pid]: message", so field 5 is
      # the identifier. sort reads to EOF; head only trims what sort produced.
      ranked="$(awk '{ id = $5; sub(/\[[0-9]*\]:?$/, "", id); sub(/:$/, "", id); if (id != "") print id }' <<<"$uout" \
        | sort | uniq -c | sort -rn | head -n "$TOP_N")"
      total="$(grep -c . <<<"$uout" || true)"
      info "$total error-level line(s) since $SINCE; top $TOP_N by identifier:"
      while read -r count ident; do
        [[ -n "${ident:-}" && "$count" =~ ^[0-9]+$ ]] || continue
        ident="${ident:0:64}"
        if (( count >= 50 )); then
          if plain_token "$ident"; then
            warn "$ident logged $count error line(s) since $SINCE" "journalctl -t $ident -p err --since \"$SINCE\""
          else
            warn "$ident logged $count error line(s) since $SINCE" "journalctl -p err --since \"$SINCE\""
          fi
        else
          info "$count  $ident"
        fi
      done <<< "$ranked"
    fi
  elif [[ "$JOURNAL" == "denied" ]]; then
    skip "$DENIED_MSG"
  else
    skip "no journal to rank identifiers from"
  fi
fi

# --- auth ------------------------------------------------------------------
if want auth; then
  group "auth"
  ssh_text=""
  sudo_text=""
  auth_src=""
  NL=$'\n'
  if [[ "$JOURNAL" == "ok" ]]; then
    # ssh is the Debian unit name, sshd everyone else's; sudo logs under its
    # own identifier rather than a unit.
    ssh_text="$(jread -u ssh -u sshd)"
    sudo_text="$(jread -t sudo)"
    auth_src="the journal"
  elif [[ "$JOURNAL" == "denied" ]]; then
    skip "$DENIED_MSG"
  fi

  # rsyslog copies the same sshd lines into auth.log that journald already
  # holds, so a file found by default is read only when the journal gave
  # nothing; reading both would count every attempt twice. A file named in
  # AUTH_LOG is read regardless, because someone asked for it. The file is
  # not windowed: it covers whatever the last rotation left in it.
  auth_file="${AUTH_LOG:-}"
  explicit_file=0
  if [[ -n "$auth_file" ]]; then
    explicit_file=1
  else
    for f in /var/log/auth.log /var/log/secure; do
      [[ -r "$f" ]] && { auth_file="$f"; break; }
    done
  fi
  if [[ -n "$auth_file" ]] && { (( explicit_file )) || [[ -z "$ssh_text$sudo_text" ]]; }; then
    if [[ -r "$auth_file" && -f "$auth_file" ]]; then
      ssh_text="${ssh_text}${ssh_text:+$NL}$(grep -E 'sshd' "$auth_file" 2>/dev/null | clean)"
      sudo_text="${sudo_text}${sudo_text:+$NL}$(grep -E 'sudo' "$auth_file" 2>/dev/null | clean)"
      auth_src="${auth_src:+$auth_src and }$auth_file (since its last rotation)"
    elif (( explicit_file )); then
      skip "auth log $auth_file is not a readable file"
    fi
  fi

  if [[ -z "$auth_src" ]]; then
    [[ "$JOURNAL" == "denied" ]] || skip "no journal and no readable auth log"
  else
    fail_re='Failed password|Invalid user|Failed publickey|authentication failure'
    failed="$(grep -cE "$fail_re" <<<"$ssh_text" || true)"
    [[ "$failed" =~ ^[0-9]+$ ]] || failed=0
    accepted="$(grep -c 'Accepted ' <<<"$ssh_text" || true)"
    [[ "$accepted" =~ ^[0-9]+$ ]] || accepted=0
    sudo_failed="$(grep -cE 'sudo.*(incorrect password attempts|authentication failure|NOT in sudoers)' <<<"$sudo_text" || true)"
    [[ "$sudo_failed" =~ ^[0-9]+$ ]] || sudo_failed=0

    sources="$(grep -E "$fail_re" <<<"$ssh_text" | awk '
      match($0, / from [0-9a-fA-F:.]+ port/) { print substr($0, RSTART + 6, RLENGTH - 11) }' \
      | sort | uniq -c | sort -rn | head -n "$TOP_N")"
    top_count="$(awk 'NR == 1 { print $1 }' <<<"$sources")"
    [[ "$top_count" =~ ^[0-9]+$ ]] || top_count=0

    info "read from $auth_src"
    if (( failed == 0 )); then
      ok "no failed SSH logins"
    elif (( failed >= 20 || top_count >= 10 )); then
      warn "$failed failed SSH login line(s)" "consider fail2ban or a firewall rule; see hardening_audit.sh --only ssh"
    else
      info "$failed failed SSH login line(s)"
    fi
    if [[ -n "$sources" ]]; then
      while read -r count src; do
        [[ -n "${src:-}" && "$count" =~ ^[0-9]+$ ]] || continue
        info "$count  from ${src:0:45}"
      done <<< "$sources"
    fi
    # Names only, never the rest of the line, and only three of them. A
    # password typed into the username prompt does land here; three names is
    # enough to recognise a dictionary run without making this a list of them.
    names="$(awk 'match($0, /[Ii]nvalid user [^ ]+ from/) { print substr($0, RSTART + 13, RLENGTH - 18) }' <<<"$ssh_text" \
      | awk '!seen[$0]++' | head -n 3 | tr '\n' ' ')"
    [[ -n "${names// /}" ]] && info "invalid user names tried include: ${names:0:120}"
    if (( accepted > 0 )); then
      ok "$accepted accepted SSH login(s)"
    fi
    if (( sudo_failed >= 5 )); then
      warn "$sudo_failed failed sudo attempt line(s)" "journalctl -t sudo --since \"$SINCE\""
    elif (( sudo_failed > 0 )); then
      info "$sudo_failed failed sudo attempt line(s)"
    else
      ok "no failed sudo attempts"
    fi
  fi
fi

# --- repeats ---------------------------------------------------------------
if want repeats; then
  group "repeats"
  if [[ "$JOURNAL" == "ok" ]]; then
    rout="$(jread -p warning)"; r_rc=$?
    if (( r_rc != 0 )); then
      skip "journalctl -p warning exited $r_rc"
    elif [[ -z "$rout" ]]; then
      ok "no warning-level journal lines since $SINCE"
    else
      # Drop the timestamp, host and pid, fold hex runs to H and digit runs to
      # N, so "worker 17 failed" and "worker 18 failed" count as one message.
      # Hex first: folding digits first would leave "0xNfNa" behind. Eight hex
      # characters is the floor so ordinary words are left alone.
      repeated="$(awk '{
          id = $5; sub(/\[[0-9]*\]:?$/, "", id); sub(/:$/, "", id)
          $1 = ""; $2 = ""; $3 = ""; $4 = ""; $5 = ""
          msg = $0; sub(/^ +/, "", msg)
          gsub(/0[xX][0-9a-fA-F]+/, "H", msg)
          gsub(/[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]+/, "H", msg)
          gsub(/[0-9]+/, "N", msg)
          print id ": " msg
        }' <<<"$rout" | sort | uniq -c | sort -rn | awk '$1 >= 2' | head -n "$TOP_N")"
      if [[ -z "$repeated" ]]; then
        ok "no message repeated since $SINCE"
      else
        info "most repeated warning-level messages since $SINCE:"
        while read -r count msg; do
          [[ -n "${msg:-}" && "$count" =~ ^[0-9]+$ ]] || continue
          info "${count}x  ${msg:0:160}"
        done <<< "$repeated"
      fi
    fi
  elif [[ "$JOURNAL" == "denied" ]]; then
    skip "$DENIED_MSG"
  else
    skip "no journal to count repeated messages in"
  fi
fi

# --- summary ---------------------------------------------------------------
printf "\n%s== summary ==%s\n" "$C_BOLD" "$C_RESET"
printf "  %s%s ok%s  %s%s warn%s  %s%s skip%s\n" \
  "$C_GREEN" "$OK_COUNT" "$C_RESET" \
  "$C_YELLOW" "$WARN_COUNT" "$C_RESET" \
  "$C_DIM" "$SKIP_COUNT" "$C_RESET"
info "service health is a separate report: ./system_doctor.sh"

if [[ "$FAIL_ON" == "warn" ]] && (( WARN_COUNT > 0 )); then
  exit 1
fi
exit 0
