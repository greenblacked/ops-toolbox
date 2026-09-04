#!/usr/bin/env bash
# Conventions for the RouterOS scripts, checked without a router.
#
# The CHR suite boots a real RouterOS under QEMU, which makes it slow enough to
# live on the nightly schedule rather than the pull-request path. The practical
# effect is that several scripts here have never been exercised by
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

# --- one maintenance switch pauses unattended automation -----------------
# Planned router work should not require disabling twenty scheduler entries by
# hand and then remembering every one afterwards. Manual-only helpers stay
# available so an operator can baseline or recover during the maintenance
# window. The doctor probes the switch explicitly so a forgotten pause remains
# visible without flooding RouterOS logs on every scheduler tick.
manual_only=' change_WIFI_pw.lua detect_internet.lua firewall_drift_baseline.lua reboot-and-flush.lua tg_send.lua '
pause_missing=0
for f in "${scripts[@]}"; do
  n="$(basename "$f")"
  if [[ "$manual_only" == *" $n "* ]]; then
    if grep -q '^:global OpsToolboxPaused;' "$f"; then
      err "$n manual helper must remain available while automation is paused"
      pause_missing=$((pause_missing + 1))
    else
      ok "$n remains manually available during a pause"
    fi
    continue
  fi
  if grep -q '^:global OpsToolboxPaused;' "$f" \
     && grep -q '\$OpsToolboxPaused.*:return' "$f"; then
    ok "$n honours OpsToolboxPaused"
  else
    err "$n lacks the fleet-wide OpsToolboxPaused guard"
    pause_missing=$((pause_missing + 1))
  fi
done
(( pause_missing == 0 )) && ok "every unattended RouterOS script has the maintenance guard"

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

  only_backup="$(NO_COLOR=1 "$PRINTER" --only backup)"
  if grep -q 'name=backup ' <<<"$only_backup" \
     && ! grep -q 'name=health_check ' <<<"$only_backup"; then
    ok "print_schedulers.sh --only scopes the generated schedule"
  else
    err "print_schedulers.sh --only backup emitted the wrong entries"
  fi

  listed="$(NO_COLOR=1 "$PRINTER" --list)"
  if grep -qx 'backup' <<<"$listed" && grep -qx 'cert_expiry_watch' <<<"$listed"; then
    ok "print_schedulers.sh --list exposes supported names"
  else
    err "print_schedulers.sh --list is incomplete"
  fi

  set +e
  NO_COLOR=1 "$PRINTER" --only definitely_missing >/dev/null 2>&1
  bad_only_rc=$?
  set -e
  if (( bad_only_rc == 3 )); then
    ok "print_schedulers.sh rejects an unknown --only name"
  else
    err "print_schedulers.sh unknown --only exited $bad_only_rc, expected 3"
  fi
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
# The tally stores ";IP:COUNT;". Looking up ";IP;" never matches an existing
# entry, so the counter stays at 1 and MaxFailures is never reached.
if grep -qF '";" . $ip . ":"' "$PKG/brute_force_block.lua"; then
  ok "brute_force_block.lua looks up tally entries as IP:COUNT"
else
  err "brute_force_block.lua tally lookup must include the colon before COUNT"
fi
if grep -q 'MAC_ALLOWLIST empty' "$PKG/mac_allowlist_dhcp.lua" \
   && grep -q 'fail-safe' "$PKG/mac_allowlist_dhcp.lua"; then
  ok "mac_allowlist_dhcp.lua refuses an empty allowlist"
else
  err "mac_allowlist_dhcp.lua is missing its empty-allowlist fail-safe"
fi

# --- HTTPS fetches verify TLS certificates ---------------------------------
# /tool fetch defaults check-certificate to no. A script that posts a bot or
# API token without enabling it will hand the secret to any MITM.
for f in "$PKG/tg_send.lua" "$PKG/ddns_update.lua"; do
  n="$(basename "$f")"
  if grep -q 'check-certificate=yes' "$f"; then
    ok "$n enables check-certificate on HTTPS fetch"
  else
    err "$n posts secrets over HTTPS without check-certificate=yes"
  fi
done

# --- defaults that must not false-alarm or ignore their own knobs ----------
if grep -qE ':local[[:space:]]+CtrlHost[[:space:]]+"one\.one\.one\.one"' "$PKG/rogue_dns_check.lua"; then
  ok "rogue_dns_check.lua uses one.one.one.one as the control hostname"
else
  err "rogue_dns_check.lua must default CtrlHost to one.one.one.one (not dns.cloudflare.com)"
fi
if grep -q 'RetentionDays \* 1d\|\$RetentionDays \* 1d' "$PKG/backup_file_cleanup.lua" \
   && grep -qF 'name~"^backup-"' "$PKG/backup_file_cleanup.lua"; then
  ok "backup_file_cleanup.lua honours RetentionDays and prefixes backup-"
else
  err "backup_file_cleanup.lua must use RetentionDays and a ^backup- prefix match"
fi
# update_check.lua writes the pre-upgrade pair itself rather than calling the
# backup script, so it is a second producer of these files and has to agree
# with the two consumers: pull_router_backups.sh globs backup-*, and
# backup_file_cleanup.lua ages out ^backup-. Rename the prefix here and the one
# backup taken at the moment it matters most is the one nothing ever collects
# and nothing ever deletes - a leak and a gap at once, both silent. $installed
# is what makes the name answer "restores to which version".
if grep -qF '("backup-" . $rawName' "$PKG/update_check.lua" \
   && grep -qF '$installed . "-pre-upgrade"' "$PKG/update_check.lua"; then
  ok "update_check.lua names its pre-upgrade backup backup-...-VERSION-pre-upgrade"
else
  err "update_check.lua must name the pre-upgrade pair backup-<identity>-<date>-<installed>-pre-upgrade"
fi
# The pruning is only safe because it cannot run unless the save it replaces
# succeeded. Ungate it and a router that failed to write a backup deletes the
# last good one on its way past - the two defects that have to coincide for a
# rollback to be impossible, in one edit.
if grep -qF ':if ($BackupOk and $RemovePrevious) do={' "$PKG/update_check.lua"; then
  ok "update_check.lua prunes previous backups only after a successful save"
else
  err "update_check.lua must gate previous-backup removal on the save having succeeded"
fi
if grep -qF '[:pick $now 0 7]' "$PKG/traffic_quota.lua" \
   && grep -qF ':set QUOTA_PREV_RX $rawRx;' "$PKG/traffic_quota.lua"; then
  ok "traffic_quota.lua parses ISO dates and baselines PREV on month rollover"
else
  err "traffic_quota.lua must parse yyyy-MM-dd and baseline PREV on rollover"
fi

echo
if (( failures > 0 )); then
  echo "$failures RouterOS convention check(s) failed" >&2
  exit 1
fi
echo "=== all RouterOS convention checks passed (${#scripts[@]} scripts) ==="
exit 0
