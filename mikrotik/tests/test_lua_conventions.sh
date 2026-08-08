#!/usr/bin/env bash
# Conventions for the RouterOS scripts, checked without a router.
#
# The CHR suite boots a real RouterOS under QEMU, which makes it slow enough to
# live on the nightly schedule rather than the pull-request path. The practical
# effect is that 14 of the 24 scripts here have never been exercised by
# anything, and a batch of twelve landed at once with no tests and no README
# entry. Nothing below needs a router, so all of it runs on every pull request.
#
# These are conventions, not behaviour: they cannot tell you a script works,
# only that it is not obviously broken and has not drifted from its docs. That
# is still the difference between "nobody has ever looked at this" and "this
# holds together".
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
README="$PKG/README.md"

failures=0
ok()  { echo "[ ok ] $*"; }
err() { echo "[fail] $*" >&2; failures=$((failures + 1)); }

scripts=()
while IFS= read -r f; do
  [ -n "$f" ] && scripts+=("$f")
done < <(find "$PKG" -maxdepth 1 -name '*.lua' -type f | sort)

if (( ${#scripts[@]} == 0 )); then
  echo "found no .lua scripts under $PKG — discovery is broken" >&2
  exit 1
fi
ok "discovered ${#scripts[@]} RouterOS scripts"

# --- balanced delimiters ---------------------------------------------------
# RouterOS reports an unbalanced brace as a runtime parse failure on the router,
# which for a scheduled script means it silently never runs.
for f in "${scripts[@]}"; do
  n="$(basename "$f")"
  ob="$(tr -cd '{' <"$f" | wc -c)"; cb="$(tr -cd '}' <"$f" | wc -c)"
  osb="$(tr -cd '[' <"$f" | wc -c)"; csb="$(tr -cd ']' <"$f" | wc -c)"
  if [[ "$ob" != "$cb" ]]; then
    err "$n has $ob '{' and $cb '}'"
  elif [[ "$osb" != "$csb" ]]; then
    err "$n has $osb '[' and $csb ']'"
  else
    ok "$n delimiters balanced"
  fi
done

# --- header comment --------------------------------------------------------
# These are pasted into a router's script editor with no filename attached, so
# the first line is the only thing telling the next person what it does.
for f in "${scripts[@]}"; do
  n="$(basename "$f")"
  if head -n 1 "$f" | grep -q '^#'; then
    ok "$n has a header comment"
  else
    err "$n does not open with a comment describing what it does"
  fi
done

# --- a failed notification is never silent ---------------------------------
# `:do {...} on-error={}` discards the failure entirely: no log, no alert.
#
# Only one shape of that is unambiguously wrong, and it is the one enforced
# here: swallowing a *notification*. If the tg_send call fails — the script is
# not installed, the token is wrong, the router has no route out — every alert
# this package exists to raise is lost, and nothing anywhere records it. The
# whole package silently becomes decorative.
#
# The rest are deliberately NOT failed. Most silent handlers in these scripts
# guard an optional read — `/system health` on hardware with no sensors,
# `/ip ipsec` on a router with no IPsec — where silence is correct and a log
# line would fire on every scheduled run forever. A purely syntactic check
# cannot tell those apart from a swallowed firewall change, so it reports the
# count and leaves the judgement to a human rather than inventing a rule that
# would push people to contort the code to satisfy it.
silent_sends=0
other_silent=0
for f in "${scripts[@]}"; do
  n="$(basename "$f")"
  # A silent handler within three lines after a tg_send invocation.
  bad="$(grep -n -A3 'Send MessageText\|/system script get tg_send' "$f" \
         | grep 'on-error={}' | wc -l)"
  count="$(grep -c 'on-error={}' "$f")"
  if (( bad > 0 )); then
    err "$n swallows a failed notification silently ($bad site(s)); log it instead"
    silent_sends=$((silent_sends + bad))
  fi
  other_silent=$((other_silent + count - bad))
done
(( silent_sends == 0 )) && ok "no notification failure is swallowed silently"
printf '[info] %d other silent on-error handlers guard optional reads — reviewed by hand, not enforced\n' \
  "$other_silent"

# --- secrets are overridable without editing the script --------------------
# The convention is that credentials live in :global variables set once at
# boot, never in a tracked file. A script whose secret has no :global path
# leaves editing the script body as the only option, which is how a live token
# ends up in a commit.
for f in "${scripts[@]}"; do
  n="$(basename "$f")"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    var="$(printf '%s' "$line" | sed -E 's/^[0-9]+::local +([A-Za-z_]+).*/\1/')"
    upper="$(printf '%s' "$var" | tr '[:lower:]' '[:upper:]')"
    if grep -qi ":global[^;]*$upper\|:set $var " "$f"; then
      ok "$n: $var can be set from a :global"
    else
      err "$n: $var has no :global override; editing the script is the only way to set it"
    fi
  done < <(grep -nE '^:local +[A-Za-z_]*(Password|Token|Secret|ApiKey|ChatID)' "$f")
done

# --- documentation has not drifted -----------------------------------------
# Both directions. A batch of twelve scripts once landed with neither tests nor
# a README entry; the forward check catches that. The reverse check catches a
# README that still advertises a script somebody deleted.
if [[ ! -f "$README" ]]; then
  err "expected $README"
else
  undocumented=0
  for f in "${scripts[@]}"; do
    n="$(basename "$f")"
    if ! grep -q "$n" "$README"; then
      err "$n is not mentioned in mikrotik/README.md"
      undocumented=$((undocumented + 1))
    fi
  done
  (( undocumented == 0 )) && ok "every script is documented in mikrotik/README.md"

  missing=0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [[ ! -f "$PKG/$name" ]]; then
      err "mikrotik/README.md refers to $name, which does not exist"
      missing=$((missing + 1))
    fi
  done < <(grep -oE '[a-zA-Z0-9_-]+\.lua' "$README" | sort -u)
  (( missing == 0 )) && ok "every script named in the README exists"
fi

# --- every unattended script has a scheduler line --------------------------
# The intervals live in print_schedulers.sh and nowhere else, so a new .lua that
# lands without a line there is a script somebody installs and that then never
# runs — the same drift the README check above exists for, with a quieter
# failure. The manual scripts are checked in the other direction: putting
# reboot-and-flush on a timer is a surprise nobody wants twice.
PRINTER="$PKG/print_schedulers.sh"
MANUAL_ONLY="tg_send detect_internet reboot-and-flush firewall_drift_baseline change_WIFI_pw"

is_manual() {
  local candidate="$1" name
  for name in $MANUAL_ONLY; do
    [ "$name" = "$candidate" ] && return 0
  done
  return 1
}

if [[ ! -x "$PRINTER" ]]; then
  err "expected an executable at $PRINTER"
else
  printed="$(NO_COLOR=1 "$PRINTER")"
  unscheduled=0
  for f in "${scripts[@]}"; do
    n="$(basename "$f" .lua)"
    # The trailing space matters: `name=backup ` must not match
    # `name=backup_file_cleanup `.
    if is_manual "$n"; then
      if grep -q "name=$n " <<<"$printed"; then
        err "$n is meant to be run by hand, but print_schedulers.sh schedules it"
        unscheduled=$((unscheduled + 1))
      fi
    elif ! grep -q "name=$n " <<<"$printed"; then
      err "$n has no /system scheduler line in print_schedulers.sh"
      unscheduled=$((unscheduled + 1))
    fi
  done
  (( unscheduled == 0 )) && ok "print_schedulers.sh covers every unattended script"
fi

# --- blocking scripts keep their fail-safe floor ---------------------------
# CONTRIBUTING.md: any script that deletes or blocks needs a floor, and that
# floor should be its first test. The behavioural tests live in the CHR suite;
# these string checks keep the floor itself from disappearing on the PR path.
if grep -q 'MaxFailures < 1' "$PKG/brute_force_block.lua" \
   && grep -q 'skipping (fail-safe)' "$PKG/brute_force_block.lua"; then
  ok "brute_force_block.lua refuses MaxFailures < 1"
else
  err "brute_force_block.lua is missing its MaxFailures < 1 fail-safe"
fi
if grep -q 'MAC_ALLOWLIST empty' "$PKG/mac_allowlist_dhcp.lua" \
   && grep -q 'fail-safe' "$PKG/mac_allowlist_dhcp.lua"; then
  ok "mac_allowlist_dhcp.lua refuses an empty allowlist"
else
  err "mac_allowlist_dhcp.lua is missing its empty-allowlist fail-safe"
fi

echo
if (( failures > 0 )); then
  echo "$failures RouterOS convention check(s) failed" >&2
  exit 1
fi
echo "=== all RouterOS convention checks passed (${#scripts[@]} scripts) ==="
exit 0
