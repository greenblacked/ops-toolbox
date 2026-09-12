# MikroTik RouterOS scripts

[Ops Toolbox](../README.md) / **MikroTik RouterOS scripts**

A small collection of RouterOS 7.x scripts (verified against **RouterOS 7.24.2**)
for backups, WiFi rotation, monitoring and Telegram notifications. All scripts
live in `/system script` on the router and are run either manually or from
`/system scheduler`.

> The `.lua` extension is just for editor syntax highlighting — these are
> RouterOS scripts, not Lua. Paste the file contents into the *Source* field
> of a `/system script` entry on the router.

Writing or changing one? The conventions the convention suite enforces — the
`OpsToolboxPaused` guard, secrets read from `:global`, alerting on transitions
rather than every run, and never swallowing a failed notification — are
collected in [`CONTRIBUTING.md`](../CONTRIBUTING.md), together with how the
pinned CHR version and its digest are bumped.

## Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Scripts overview](#scripts-overview)
- [Installation](#installation)
- [Script details](#script-details)
- [Security action surface](#security-action-surface)
- [Docker integration tests (CHR 7.24.2)](#docker-integration-tests-chr-7242)
- [RouterOS 7.24.2 notes & gotchas](#routeros-7242-notes--gotchas)

## Requirements

| Requirement | Notes |
| --- | --- |
| **A router running RouterOS 7.x** | Verified against **RouterOS 7.24.2**, the version the integration suite pins in [`tests/routeros-version.env`](tests/routeros-version.env). Individual scripts note narrower floors where they have one — `change_WIFI_pw.lua` needs RouterOS 7.13+ for the WiFiWave2 path, `pull_router_backups.sh` needs the RouterOS 7+ SFTP server. |
| **Script policy** `read,write,policy,test,sensitive,ftp` | The policy set every `/system script` entry here is created with. `policy` is what lets a script read another script's source, `sensitive` covers the secrets, `ftp` covers `/tool fetch`. |
| **A Telegram bot token and chat ID** | Needed by `tg_send.lua`, and so by every script that alerts. Set them once as the `TgBotToken` / `TgChatId` globals rather than editing each script. (RouterOS 7.24 refuses an underscored `:global`, so the older `TG_BOT_TOKEN` / `TG_CHAT_ID` spelling is read by nothing — see the migration note below.) |
| **Bash 3.2 or newer** | Host-side only, for `print_schedulers.sh` and `pull_router_backups.sh`. The `/bin/bash` that ships on macOS is enough. |
| **Python 3.9+** | Host-side only, for `export_config.py` and `router_doctor.py`. Standard library only — no `pip install`, no venv, no `routeros-api`. |
| **OpenSSH `ssh` and `scp`** | Host-side only. `pull_router_backups.sh` checks for both up front and exits `2` rather than letting a missing binary look like a router with no backups. `export_config.py --commit` additionally needs `git`. |
| **Docker with the `compose` v2 plugin** | Optional, and only to run the integration suite in [`tests/`](tests/) against a real CHR instance. |

## Quick start

Nothing here is installed by a package manager. The `.lua` files are pasted into
`/system script` on the router by hand — [Installation](#installation) walks
through that — and the host-side helpers are run from a clone of this
repository. The two worth running first are read-only; paths below are from the
repository root, and the per-script sections further down invoke the same files
from inside this folder.

Before you touch a router, read the scheduler entries the `.lua` scripts are
meant to get. This contacts nothing at all and writes nothing:

```bash
./mikrotik/print_schedulers.sh
```

Installing a script and scheduling it are separate acts, and the second one
fails silently: a script nobody scheduled looks exactly like a script with
nothing to report. Once the scripts are in place, ask the router which of them
actually took:

```bash
./mikrotik/router_doctor.py --host 192.168.88.1
```

That is a read-only audit over ssh. It reports which of these scripts are in
`/system script`, which of them a `/system scheduler` entry really runs, whether
the globals they need are set, and whether a maintenance pause was left on —
then prints the command that fixes what it found. It never writes to the router,
and it asks for the *length* of `TgBotToken` and `TgChatId` rather than
their values, so no token crosses the wire.

## Scripts overview

> **On RouterOS 7.24, 16 of these 27 scripts do not run at all.** That release
> refuses to execute a script declaring a `:global` or `:local` whose name
> contains an underscore — it stops in the parser, so the script logs nothing
> and a scheduler entry that fires looks exactly like one with nothing to
> report. This is the quietest failure in the package: you install the script,
> schedule it, and never hear from it again.
>
> **Runs on 7.24:** `backup_file_cleanup.lua`, `backup_update_check.lua`,
> `cert_expiry_watch.lua`, `change_WIFI_pw.lua`, `detect_internet.lua`,
> `health_check.lua`, `netwatch_notify.lua`, `reboot-and-flush.lua`,
> `stay_fresh.lua`, `tg_send.lua`, `wireguard_watch.lua`.
>
> **Does not run on 7.24** (fine on 7.23 and earlier): `backup.lua`,
> `bandwidth_spike.lua`, `brute_force_block.lua`, `ddns_update.lua`,
> `dhcp_lease_watch.lua`, `firewall_drift.lua`, `firewall_drift_baseline.lua`,
> `latency_monitor.lua`, `mac_allowlist_dhcp.lua`, `rogue_dns_check.lua`,
> `traffic_quota.lua`, `update_check.lua`, `vpn_health.lua`,
> `wan_failover_notify.lua`, `wan_link_flap_notify.lua`,
> `wireless_client_watch.lua`.
>
> `backup_update_check.lua` is the 7.24 replacement for `update_check.lua`.
> The rest have no replacement yet; the integration suite marks each of them
> `xfail` on the 7.24.2 CHR rather than pretending they pass.

| File                            | Purpose                                                                 |
| ------------------------------- | ----------------------------------------------------------------------- |
| `tg_send.lua`                   | Generic Telegram text-message helper used by every other script.        |
| `backup.lua`                    | Dated, version-stamped backup + export; prunes the previous one.        |
| `change_WIFI_pw.lua`            | Rotates 2.4 GHz / 5 GHz WPA2 PSK and announces it via Telegram.         |
| `health_check.lua`              | CPU / RAM / disk / temperature watchdog with threshold alerts.          |
| `update_check.lua`              | Backs up, then notifies when a newer RouterOS version appears.          |
| `backup_update_check.lua`       | Same job, plainer; runs on RouterOS 7.24 where update_check will not.   |
| `stay_fresh.lua`                | Backs up, installs the update in a window, then the firmware. Reboots.  |
| `wan_failover_notify.lua`       | One-shot Telegram alert on built-in WAN-detect state transitions.       |
| `detect_internet.lua`           | Re-runs RouterOS WAN/LAN auto-detection (manual reset).                 |
| `reboot-and-flush.lua`          | Flushes DNS + connection tracking, then reboots. No pre-reboot ping.    |
| `dhcp_lease_watch.lua`          | Alerts on new MACs, duplicate hostnames, and lease churn.               |
| `firewall_drift.lua`            | Diffs current firewall rules against a saved baseline; alerts on drift. |
| `firewall_drift_baseline.lua`   | Manual helper that re-arms `firewall_drift` after intentional changes.  |
| `mac_allowlist_dhcp.lua`        | Flags (and optionally blocks) DHCP leases for non-allowlisted MACs.     |
| `rogue_dns_check.lua`           | Detects DNS upstream hijack and clients using non-approved resolvers.   |
| `backup_file_cleanup.lua`       | Prunes old backup/export files so flash does not silently fill up.      |
| `cert_expiry_watch.lua`         | Warns before a certificate expires, while there is still time to act.   |
| `ddns_update.lua`               | Pushes the current WAN address to Cloudflare DNS when it changes.       |
| `netwatch_notify.lua`           | Turns RouterOS netwatch up/down events into Telegram alerts.            |
| `wan_link_flap_notify.lua`      | Alerts on a WAN link flapping, which a plain up/down check misses.      |
| `latency_monitor.lua`           | Tracks RTT to chosen targets and alerts on sustained degradation.       |
| `bandwidth_spike.lua`           | Alerts when interface throughput jumps well above its recent norm.      |
| `traffic_quota.lua`             | Tracks monthly volume per interface and warns before a cap is hit.      |
| `brute_force_block.lua`         | Detects repeated auth failures and adds the source to a block list.     |
| `vpn_health.lua`                | Watches IPsec / OVPN / WireGuard sessions and alerts on state changes.  |
| `wireguard_watch.lua`           | Alerts when a WireGuard peer stops handshaking.                         |
| `wireless_client_watch.lua`     | Alerts on wireless clients joining, leaving, or with poor signal.       |
| `export_config.py`              | Host-side: exports `/export` over ssh and versions it in git.           |
| `print_schedulers.sh`           | Host-side: prints the `/system scheduler add` lines for these scripts.  |
| `router_doctor.py`              | Host-side: read-only audit of what is installed, scheduled and set.     |
| `pull_router_backups.sh`        | Host-side: pulls `backup-*` files off the router over SFTP/SCP.         |

## Installation

1. **Set up a Telegram bot** ([@BotFather](https://t.me/BotFather)), grab the
   token, and find your chat ID (e.g. message your bot then visit
   `https://api.telegram.org/bot<TOKEN>/getUpdates`).
2. Open Winbox / WebFig → **System → Scripts → Add (+)**.
3. For each `.lua` file in this folder:
   - Set **Name** to the filename without extension (e.g. `tg_send`, `backup`,
     `change_WIFI_pw`).
   - Tick **Policy:** `read,write,policy,test,sensitive,ftp` — `policy` is
     required to read other script sources via `[:parse [/system script get …
     source]]`, `sensitive` for secrets, `ftp` for `/tool fetch`.
   - Paste the script body into **Source** and save.
4. Edit `tg_send.lua` and replace the `BotToken` / `ChatID` placeholders with
   your real values, **or** create a tiny startup script that sets globals:

   ```routeros
   :global TgBotToken "123456:ABC...";
   :global TgChatId   "12345678";
   ```

   then add a Scheduler entry with `start-time=startup` pointing to it. The
   `tg_send` helper picks them up automatically.

   RouterOS 7.24 refuses `:global` names with an underscore, so the package
   helper no longer reads `TG_BOT_TOKEN` / `TG_CHAT_ID`.

   **On a router already upgraded to 7.24, the old values are gone** — not
   hidden, gone. Globals are runtime state, repopulated at boot by the startup
   script, and on 7.24 that script declares `TG_BOT_TOKEN` and so does not run
   at all. `/system script environment` has no row to copy from. Get the token
   from BotFather (or wherever you keep it), put it in `TgBotToken` /
   `TgChatId`, and **rewrite the startup script to the new names** — otherwise
   the next reboot leaves them unset again.

   **On 7.23, migrate before you upgrade.** This snippet copies the values for
   the current uptime:

   ```routeros
   :global TG_BOT_TOKEN;
   :global TG_CHAT_ID;
   :global TgBotToken $TG_BOT_TOKEN;
   :global TgChatId   $TG_CHAT_ID;
   ```

   It is **not** the whole migration. Globals do not survive a reboot, so the
   startup script has to be edited to the new names too — without that, the
   next restart restores the old pair and the helper falls back to its
   placeholders. `router_doctor.py` reports `TgBotToken is not set` when this
   has not been done, which is how you confirm the migration took.

5. Run `detect_internet` once if you plan to use `wan_failover_notify`. It
   enables `detect-interface-list=all`, which is the prerequisite for the
   per-interface `detect-internet-state` property to be populated.

### Fleet-wide maintenance pause

Every unattended `.lua` script checks the same boolean before it reads state,
sends an alert, or changes the router. Pause scheduled automation before
planned network or firewall work without disabling twenty scheduler entries
individually:

```routeros
:global OpsToolboxPaused true;
```

Resume normal operation explicitly afterwards:

```routeros
:global OpsToolboxPaused false;
```

The paused scripts return silently so short scheduler intervals do not flood
`/log`. Manual-only helpers remain available during maintenance: `tg_send`,
`detect_internet`, `change_WIFI_pw`, `firewall_drift_baseline`, and
`reboot-and-flush`. This lets an operator accept an intentional firewall
baseline or perform an explicit recovery action before resuming automation.
`router_doctor.py` reads the non-secret boolean and reports a warning while the
pause is active, including in JSON output.

RouterOS globals are both in-memory and user-scoped. This switch covers scripts
and schedulers owned by the same RouterOS user that sets it. A reboot clears
the pause and scheduled scripts resume; for multi-owner routers or maintenance
that must survive a reboot, disable the relevant schedulers instead (or set the
global for each owner from an explicit startup script).

### Suggested schedules

Add via **System → Scheduler** (use the same policy set as the scripts):

| Script                 | Trigger / interval                                                       |
| ---------------------- | ------------------------------------------------------------------------ |
| `backup`               | `1d` at `04:00:00`                                                       |
| `change_WIFI_pw`       | `30d` (or on demand)                                                     |
| `health_check`         | `5m`                                                                     |
| `update_check`         | `1d`                                                                     |
| `backup_update_check`  | `1d` — instead of `update_check`, not alongside it                       |
| `stay_fresh`           | `1d` inside its window (`04:20:00`) — `--update-script stay_fresh`       |
| `wan_failover_notify`  | `1m`                                                                     |
| `dhcp_lease_watch`     | `5m`                                                                     |
| `firewall_drift`       | `15m`                                                                    |
| `mac_allowlist_dhcp`   | `5m`                                                                     |
| `rogue_dns_check`      | `10m`                                                                    |
| `notify-boot` (inline) | `start-time=startup` — see [Reboot notifications](#reboot-notifications) |

`detect_internet`, `reboot-and-flush`, and `firewall_drift_baseline` are
intentionally manual / on-demand — don't schedule them.

[`print_schedulers.sh`](#print_schedulerssh) prints all of this as ready-to-paste
`/system scheduler add` commands, including the twelve scripts the table above
does not cover:

```bash
./print_schedulers.sh                          # review, then paste
./print_schedulers.sh --include-notify-boot    # with the startup notifier below
```

### Reboot notifications

`reboot-and-flush` does **not** Telegram before rebooting (the message would
race the reboot itself; see the script comment). The recommended pattern is a
one-shot startup notifier that fires once the router is back online:

```routeros
/system scheduler add name=notify-boot start-time=startup \
    policy=read,write,policy,test,sensitive,ftp \
    on-event=":delay 20s; :local S [:parse [/system script get tg_send source]]; \$S MessageText=(\"\\F0\\9F\\9F\\A2 <b>\" . [/system identity get name] . \":</b> back online\");"
```

The 20 s delay gives DHCP / WAN / DNS time to come up before `tg_send` tries
to reach Telegram.

## Script details

### `tg_send.lua`

Generic Telegram text-message helper. All other scripts call it via
`[:parse [/system script get tg_send source]]`. Posts to `sendMessage` with
HTML parse mode using `application/x-www-form-urlencoded`, retries up to 3×
on transient failures, and truncates messages above Telegram's 4096-char
limit. Reads `:global TgBotToken` / `:global TgChatId` if defined so
secrets can stay out of the script body. RouterOS 7.24 refuses underscore
names, so the old `TG_BOT_TOKEN` / `TG_CHAT_ID` globals are not read and cannot
be re-declared there — see the migration note above, which includes rewriting
the startup script.

### `backup.lua`

Creates a binary backup (`.backup`) and a config export (`.rsc`) and sends a
Telegram notification with the resulting filename. Optional binary-backup
encryption via `BackupPassword`. Sanitizes the date so non-ISO `date-format`
settings don't accidentally produce filenames with `/` (which would create
sub-folders on disk).

The name is `backup-<identity>-<date>-<installed-version>`, so a listing
answers which config, from when, and on which RouterOS version — the version
matters most on a rollback, because a `.backup` restored onto a different
release is not guaranteed to load.

`RemovePrevious` (default `true`, overridable with
`:global BACKUP_REMOVE_PREVIOUS false`) deletes every other `backup-*` file
once the new pair has been written, leaving exactly one generation on the
router. It runs only after a successful save — the failure path ends in
`:error` before it is reached — so a backup that failed never takes the last
good one with it.

One generation on a router is retention, not a backup policy. Keep
generations off the device with `pull_router_backups.sh`, and run it at least
as often as the backup runs, or the older ones are gone before it sees them.
With `RemovePrevious` off, files accumulate in `/file` and
`backup_file_cleanup.lua` (default retention 30 days; see
`print_schedulers.sh`) ages them out instead; running both is harmless, since
the age sweep finds nothing left to remove.

### `change_WIFI_pw.lua`

Generates fresh random passwords for the 2.4 GHz and 5 GHz security profiles
and announces the new credentials via Telegram. Uses the SCEP-OTP generator
when the certificate package supports it and falls back to `:rndnum`
otherwise. Set `UseWifiWave2` to `true` for routers using the new
`/interface wifi` (WiFiWave2) stack instead of the legacy
`/interface wireless`.

### `reboot-and-flush.lua`

Flushes DNS cache + connection tracking and reboots after a 1-second grace
period. Use sparingly — flushing connection tracking drops every active
session. Intentionally has no Telegram step; pair it with the `notify-boot`
scheduler entry above for a "back online" alert after each reboot.

### `detect_internet.lua`

Forces RouterOS to re-run its WAN/LAN role auto-detection by toggling
`detect-interface-list`. Helpful after ISP outages where interfaces stay
tagged `unknown`. Also enables detect-internet on **all** interfaces, which
is the prerequisite for `wan_failover_notify`.

### `health_check.lua`

Reads CPU / memory / disk / temperature, compares against thresholds (default
85 % / 85 % / 90 % / 75 °C) and only Telegrams when something is wrong.
Temperature lookup iterates `/system health` entries (`temperature`,
`cpu-temperature`, `board-temperature`) so it works across hardware lines.

### `update_check.lua`

Asks the official update server whether a newer RouterOS version exists on
your channel, and notifies once when one appears. Does **not** auto-install.

The verdict comes from RouterOS's own `status` field rather than from
`installed != latest`, because those strings also differ when `latest` is
*older* — switch a router from `stable` to `long-term` and a difference test
announces an upgrade to the release you just moved away from.

When an upgrade is offered it takes a `.backup` + `.rsc` pair first and names
the file in the same message, so the pre-upgrade snapshot exists by the time
anyone reads the notification instead of depending on them remembering. The
save is inline rather than a call out to the `backup` script, so a router
where only this script was pasted still gets a rollback point. The filename is
`backup-IDENTITY-DATE-VERSION-pre-upgrade`, and that version is the running
one — the release this file restores you to. It keeps the `backup-` prefix so
`pull_router_backups.sh` still collects it and `backup_file_cleanup.lua` still
ages it out. Encrypt it by setting `:global BACKUP_PASSWORD`, the same one
`backup.lua` reads; set `:global UPDATE_CHECK_BACKUP false` to only notify. A
failed backup does not suppress the update notification — the message says the
backup failed, which is louder than silence and is the state you most need to
know about before upgrading.

Once the new pair is written it deletes the older `backup-*` files, leaving one
generation, and says how many it removed. The removal sits inside the success
branch and after both writes, so a save that failed jumps to the error handler
and can never be the run that deletes the last good backup. Exclusion is by
name rather than by age: the files just written are known by name, everything
else matching the prefix is older by definition, and RouterOS script has no
sort. Everything starting with the new base name is kept, not just the two
exact names — `/export file=` writes through a `<name>.rsc.in_progress`
temporary and returns before the export finishes, so an exact-name test leaves
that file matching `^backup-`, excluded by neither name, and the sweep deletes
a half-written export. It reads the same `:global BACKUP_REMOVE_PREVIOUS` that
`backup.lua` does, because how many generations live on a router is one policy
and not two — set it `false` and both scripts keep every generation for
`backup_file_cleanup.lua` to age out at 30 days. The caveat from `backup.lua`
carries over: one generation means a corrupt backup is the only backup, so this
is retention on the router, not a backup policy.

That same message carries the firmware, board, architecture, uptime, CPU load,
memory and storage figures, because those are what you would go and look up
anyway before deciding whether to upgrade now or wait for the weekend. They
are read only on the branch that sends, so an ordinary quiet run stays a
handful of reads. RouterBOARD firmware is skipped on hardware that has none
(CHR, x86) rather than reported as `unknown`.

A quiet run — nothing to install — is a log line and no message, on purpose:
a router that says "nothing to do" every morning is the message that gets
muted, and the one that matters gets muted with it. Silence has its own cost,
though, because a router that never speaks looks exactly like one whose
scheduler quietly stopped. Where that ambiguity is worse than the noise, set
`:global UPDATE_CHECK_NOTIFY_UP_TO_DATE true` and every quiet run sends a short
heartbeat instead — installed, latest, channel and RouterOS's own verdict.
Opted into per router, never the default. It is worded "nothing to install"
rather than "up to date" because it also covers the channel-switch case, where
the versions differ and there is still nothing RouterOS will offer.

The channel is read and reported, never written. Setting it would mean the
script overriding a deliberate choice: a router parked on `long-term` moved to
`stable` on the next tick, then correctly told an upgrade is available — to a
release train somebody had specifically kept it off.

Completion is detected by polling `status` until it reaches a verdict, up to
about 65 seconds (`:global UPDATE_CHECK_MAX_WAIT` in five-second units, for a
slow or contended link), rather than waiting a fixed interval or waiting for
`latest-version` to fill. That field cannot be the signal: measured on the
7.24.2 CHR, issuing the check clears it at once, a good check refills it in
about a second, and a failed check leaves it empty, so a loop waiting for it to
fill hangs on a failure and a read after a fixed wait cannot tell mid-check
from failed. (This section used to say RouterOS kept the previous check's
value; the CHR says otherwise.)

A check that never completes sends its own message (`:global
UPDATE_CHECK_NOTIFY_FAILURE false` to disable). It only fires where the router
can still reach Telegram — DNS broken, the upgrade server refusing, a proxy in
the way — which is exactly the case where a router sits on an unpatched
release with nothing saying so. A fully offline router cannot report anything,
and no arrangement here changes that.

### `backup_update_check.lua`

The same job as `update_check.lua` in a plainer style, and the one to install
on RouterOS 7.24. That release refuses to execute a script declaring a
`:global` whose name contains an underscore — "expected end of command" at the
underscore, from the scheduler, from `:parse` and from `/system script run`
alike. The CHR suite had recorded that as a CHR quirk; a router on that release
failed `update_check.lua` identically, with "executing script failed" and not
one line of the script's own logging reaching the log. `update_check.lua`
declares six such names. This script declares none: its only globals are
`OpsToolboxPaused` and `RouterBackupPassword`.

The suite runs it end to end on the 7.24.2 CHR: once on the stable channel,
where it sends the heartbeat, and once with the channel patched to
`development`, where a newer build is usually offered and it writes the
`backup-IDENTITY-DATE-VERSION-pre-upgrade` pair and sends the full message.
The first hand run, on a 7.24.1 CHR, found a real newer release, wrote the
pair, pruned a seeded older generation and delivered the message. The backup and prune are the ones
described under `update_check.lua` above — same filename, same prefix so
`pull_router_backups.sh` and `backup_file_cleanup.lua` still see it, same rule
that the prune runs only after the pair is written, same prefix exclusion for
the `.rsc.in_progress` temporary.

The rest keeps the plain design where it was sound — a message on **every**
run rather than only on a transition, no `:global` knobs — and drops it where
the CHR showed it lying. The original waited a fixed 15 seconds and compared
`installed` with `latest`. Measured on a 7.24.2 CHR: issuing the check clears
`latest-version` at once, a good check refills it in about a second, and a
failed check leaves it empty with an `ERROR:` line in `status` — with the
update hosts unreachable, "ERROR: IPv4: server is not responding / IPv6: no
internet connection". The old comparison sent that empty field down the "not
required" branch, so a router whose DNS or outbound HTTPS broke reported
"update is not required" with a blank Latest every morning. So the script now
polls `status` until it settles — "finding out latest version..." while the
check runs, then "System is already up to date", "New version is available",
or the `ERROR:` line — bounded by `MaxWait` attempts of five seconds, and the
verdict is RouterOS's own, the same as `update_check.lua`. The sibling
scripts' comments used to say `latest-version` kept the previous check's
answer; the CHR says otherwise, and they now say what was measured.

Three messages, one per outcome. "Update is required" carries the backup, the
firmware state, the license level, the installed packages with their versions
(a disabled one marked, since it is upgraded with the rest), the board's health
readings where it has any, the resources an upgrade depends on, a changelog
link, and a **reboot impact** section: interfaces running, DHCP leases bound,
PPP sessions active and WireGuard peers, so the operator picks the moment
rather than learning who was on the router from the complaints. "Not required"
is the short daily heartbeat: versions, firmware, uptime, free storage. "Check
FAILED" names the reason — a timeout, an error from the server, or no version
reported — with the `status` line, the update `mode`, the NTP client state (the
check is HTTPS with certificate verification, so a clock far enough off fails
the handshake), the DNS servers, and the command to run by hand. A failed check
takes no backup and prunes nothing.

Two risk lines appear in any message only when there is something to say: the
number of `supout` crash dumps on the router, and the number of `critical` log
entries in the buffer with the last one's text. Every message carries the
`status` line and the router's clock at the time of the check. Text that did
not originate in the script — the status line, a log entry, the identity — is
HTML-escaped first, because Telegram rejects the whole message on one
unbalanced `<`.

Free storage is shown next to the size of the installed packages, which is
roughly what the upgrade downloads, and compared against a floor
(`MinFreeStorageMiB`, 16 by default, the floor `stay_fresh.lua` refuses to
install under). The floor suits routers with 128 MiB of flash or more. A 16 MB
flash router normally sits at 2 to 4 MiB free and upgrades anyway, so on those
set it to 0 or the heartbeat warns every day. A non-zero `bad-blocks` figure is
reported the same way, as a warning next to the number, because an upgrade is
a large write to that flash. The CHR reports no `bad-blocks` at all, and the
line is simply absent there.

Five settings at the top. `TgSendScript` names the Telegram helper, and it
defaults to `tg_send_new` — the operator's own copy — rather than the package's
`tg_send`, so a router that already has a working helper keeps using it. The
package helper now uses `TgBotToken` / `TgChatId` and runs on 7.24; point
`TgSendScript` at whatever helper the router actually has.
`updChannel` is `"stable"` by default and is **written** on every run, as the
original script did — a fleet meant to sit on one train gets a hand-switched
router put back before it is checked. Set it to `""` to leave the channel as
the router has it and only report it, which is `update_check.lua`'s stance. `RouterBackupPassword`, set from a `:global`
at boot, encrypts the binary backup. `MinFreeStorageMiB` is the storage floor
described above, and `MaxWait` the number of five-second attempts to wait for
the verdict. Install it **instead of** `update_check`,
not alongside it, or every update is reported twice.

### `stay_fresh.lua`

The RouterOS counterpart of the macOS and Linux `stay_fresh.sh`: the two
update checks above tell you a release is waiting and leave the install to
you; this one installs it. Every run checks the update server, and when
RouterOS's own verdict is that a newer release is available on the channel,
it takes the `backup-IDENTITY-DATE-VERSION-pre-upgrade` pair, prunes the older
`backup-*` generations, announces what it is about to do, and runs
`/system package update install`, which downloads the release and reboots. On
the run after that, when `/system routerboard` reports the firmware behind the
RouterOS it now runs, it upgrades the firmware and reboots once more — one
action per run, in the order MikroTik documents. Every run ends in a Telegram
message: installed, deferred, refused, or the one-line "fresh, nothing to
install" heartbeat, because a script that reboots routers should never be
silent about having run. Install it **instead of** `update_check` or
`backup_update_check`, not alongside them.

It declares no `:global` with an underscore in its name, for the reason under
`backup_update_check.lua`, so it runs on RouterOS 7.24; the CHR suite's
`test_script_add_remove_roundtrip` proves 7.24.1 accepts the source, and the
convention suite holds it to the invariants below. It looks for the Telegram
helper as `tg_send_new` first, the operator's copy that runs there, and falls
back to the package's `tg_send`, which runs on 7.24 too now that its globals
are `TgBotToken` / `TgChatId`, encoding
line breaks the way that helper's form body needs. With no helper resolved it
still checks and logs, and refuses to install or reboot: a router that reboots
without saying so is the failure it exists to avoid.

What stops it from rebooting a router it should not — each one a `:global`
set at boot, so a fleet is tuned from one startup script and the tracked file
is never edited per router:

| `:global`                 | Default | What it does                                                                                                      |
| ------------------------- | ------- | ----------------------------------------------------------------------------------------------------------------- |
| `StayFreshDryRun`         | `false` | `true`: check and report only. Run the first tick with this on and read the message before letting it act.        |
| `StayFreshWindowStart`    | `3`     | Local hour, inclusive. With the end, the only hours it will install or reboot in. Outside: "deferred".            |
| `StayFreshWindowEnd`      | `6`     | Local hour, exclusive. `3` and `6` is 03:00–05:59; start > end wraps past midnight; equal means always.           |
| `StayFreshInstall`        | `true`  | `false`: never install; the script becomes an update check with a backup, like `backup_update_check`.             |
| `StayFreshFirmware`       | `true`  | `false`: never touch the RouterBOARD firmware. Only when the bundled firmware is numerically newer; CHR/x86 skip. |
| `StayFreshRequireBackup`  | `true`  | Refuse the install when the pre-upgrade pair was not written. `false`: report the failed backup and install.      |
| `StayFreshRequireNotify`  | `true`  | Refuse to install or reboot when no Telegram helper resolved. `false` for a router with no Telegram at all.       |
| `StayFreshMinFreeMiB`     | `16`    | Free storage the install must find, checked before the download. A floor to tune, not a RouterOS figure; `0` off. |
| `StayFreshRemovePrevious` | `true`  | Prune older `backup-*` files after the new pair is written, leaving one generation.                               |
| `StayFreshMaxWait`        | `12`    | Polls of 5 s to wait for a verdict after a 5 s settle; about 65 s.                                                |
| `StayFreshTgSend`         | unset   | Name of the Telegram helper script, if it is neither `tg_send_new` nor `tg_send`.                                 |
| `RouterBackupPassword`    | unset   | Encrypts the binary backup; the same `:global` `backup_update_check` reads.                                       |

The verdict is `status`, never `installed != latest`, for the reason under
`update_check.lua`: switch a router from `stable` to `long-term` and the
strings differ while `latest` is *older*, and a script that installs on a
difference test downgrades the router. A check that errors or never
completes installs nothing and sends a message saying so rather than reading
as "nothing to install" — on 7.24.2 a failed check leaves `latest-version`
empty, and an empty field compared with `installed` would read as "differs,
nothing offered", the silence that looks like up to date and means the
opposite. The channel is read and reported, never written.

The backup and prune are the ones described under `update_check.lua`: same
filename, same `backup-` prefix so `pull_router_backups.sh` still collects the
pair and `backup_file_cleanup.lua` still ages it out, the prune only after
both files are written, the prefix exclusion for the `.rsc.in_progress`
temporary. What is new is that the install sits behind the backup: with
`StayFreshRequireBackup` on, a run whose backup failed sends "NOT installed,
nothing to roll back to" and stops. The install is announced *before* it
starts, with a five-second delay for the send to complete, because a message
sent after `/system package update install` never leaves the router; pair it
with the `notify-boot` scheduler entry under [Reboot
notifications](#reboot-notifications) for the "back online" half.

Recovery, if an upgrade goes wrong: the pre-upgrade pair is on the router and,
if `pull_router_backups.sh` runs, on your machine. Netinstall the previous
release and restore the `.backup` there, or restore the `.rsc` onto any
release with `/import`. The binary backup only restores onto the version it
was taken on, which is the version in its name.

Pause it with the fleet-wide `OpsToolboxPaused`, or set `StayFreshInstall`
and `StayFreshFirmware` to `false` at boot to keep the checks and the
heartbeat while planned work rules out a reboot.

### `wan_failover_notify.lua`

Polls the WAN interface's built-in `detect-internet-state` property and sends
a Telegram message **only on transitions** (e.g. `internet → no-link`). State
is held in `:global WAN_LAST_STATE` so consecutive runs stay quiet while the
state is unchanged. The global resets on reboot, which means the first run
after boot sends a single baseline notification.

Requires detect-internet to be enabled on the interface — run
`detect_internet.lua` once, or run:

```routeros
/interface detect-internet set detect-interface-list=all
```

Edit `WanInterface` at the top of the script if your WAN port isn't
`ether1`.

### `dhcp_lease_watch.lua`

Periodically scans `/ip dhcp-server lease` and alerts on three conditions:
new MACs not seen before (relative to `:global DHCP_KNOWN_MACS`), the same
hostname showing up under multiple MACs, and lease-count churn beyond
`ChurnThreshold` (default 10) since the previous run. The first run after
boot silently establishes the baseline. With `Enforce=true` (default), each
new MAC's lease IP is added to address-list `dhcp-watch-new` with a 1-day
timeout so you can pin a forward rule to it. Sticky `:global DHCP_DUPS_FLAG`
and `DHCP_CHURN_FLAG` suppress repeat alerts while the same condition
persists.

### `firewall_drift.lua`

Stores a signature string of every `/ip firewall filter` and `/ip firewall
nat` rule (`chain|action|src-address|dst-port|protocol|comment`) in
`:global FW_BASELINE` on first run, then alerts when later runs see
additions, removals, or a different ordering of rules whose comment contains
`#critical`. On drift the script also logs a marker entry into address-list
`fw-drift-events` (sentinel address `127.0.0.1`, 1-hour timeout) so the
router carries a router-side audit trail. Run `firewall_drift_baseline.lua`
after intentional firewall changes to clear the global; the next
`firewall_drift` run silently re-baselines.

### `firewall_drift_baseline.lua`

Manual helper. Sets `:global FW_BASELINE` to empty string. Does not touch
firewall rules. Run after intentional firewall edits before the next
scheduled `firewall_drift` run, otherwise the change will be reported as
drift.

### `mac_allowlist_dhcp.lua`

Iterates `/ip dhcp-server lease` and flags any lease whose MAC is not on the
allowlist. The allowlist comes from `:global MAC_ALLOWLIST` (delimited
string, e.g. `";aa:bb:..;cc:dd:..;"`) or from a per-lease comment containing
the literal substring `#allow`. With `Enforce=true` (default), unknown lease
IPs are tagged into address-list `dhcp-unknown` with a 1-day timeout. With
`BlockUnknown=true` (off by default), the script idempotently installs a
single `chain=forward action=drop` rule sourced from that list (the rule is
appended at the end of `/ip firewall filter` — review and move it manually
to the right position). Refuses to do anything if `MAC_ALLOWLIST` is empty,
to avoid accidentally locking every device out of an unconfigured router.
Re-alerts only when the set of unknown MACs changes between runs.

### `rogue_dns_check.lua`

Two checks per run. First, it `:resolve`s a control hostname (default
`one.one.one.one`, Cloudflare's anycast name for 1.1.1.1 / 1.0.0.1 —
`dns.cloudflare.com` resolves elsewhere and false-alarms on a healthy
resolver) and warns if the answer is not in `:global
DNS_EXPECTED` — a sign of upstream DNS hijack or a wrong/leaking resolver
config. Second, it walks `/ip firewall connection` for outbound
UDP/TCP `dst-port=53` flows whose destination is neither a router-self IP
nor an entry in `:global DNS_ALLOWED_RESOLVERS`, aggregates offenders by
source IP, and (with `Enforce=true`, default) tags those source IPs into
address-list `rogue-dns-clients` with a 1-hour timeout. Pair with a
documented filter rule to redirect or drop their port-53 traffic (see
[Security action surface](#security-action-surface) below).

### `export_config.py`

**Runs on your machine, not on the router** — it is the only file here that is
not a RouterOS script.

`firewall_drift.lua` compares the live firewall against a baseline maintained by
hand, so drift is only ever measured against whatever someone last remembered to
write down. This exports the real configuration and commits it, giving that
baseline actual history and turning any change — intended or not — into a diff.

```bash
./export_config.py --host 192.168.88.1
./export_config.py --host router.lan --identity ~/.ssh/keys/projects/mikrotik/mikrotik_rsa
./export_config.py --host router.lan --commit     # commit if it changed
./export_config.py --host router.lan --stdout     # print, write nothing
./export_config.py --host router.lan --diff       # compare live vs stored; write nothing
```

The connection flags are `--host` (the only required one), `--user` (default
`admin`), `--identity`, `--port` (22) and `--timeout` (60 s). Where the export
lands is `--out`, the output directory, and `--name`, the basename, which
defaults to the host.

`--stdout`, `--diff` and `--commit` are mutually exclusive and the script exits
`2` if you pass more than one. Two flags change the export itself:
`--no-normalise` keeps the volatile header that would otherwise make every run
differ, and `--show-sensitive` keeps the secrets that are stripped by default.
`--show-sensitive` with `--commit` is refused outright, also exit `2` — that
combination writes router credentials into git history.

Transport is ssh, so it needs **nothing installed**: no `routeros-api`, no pip,
no venv. (The suite in [`tests/`](tests/) uses the API because it drives the
router; this only reads.) Output lands in `config-history/<host>.rsc`.

The normalisation step is the point. `/export` stamps a header with the export
time and hardware identity, so two exports of an unchanged router differ — left
alone, every commit is noise and a real change is invisible among it. Only
provably volatile lines are stripped (timestamp, `software id`, `model`, `serial
number`); anything more would hide a genuine edit. Rule `comment=` values are
kept, since those are configuration rather than header. Pass `--no-normalise` to
see the raw export.

`--show-sensitive` together with `--commit` is **refused before the router is
contacted** — writing router secrets into git history is not something to do by
accident.

`--diff` fetches and normalises the live export, then prints a unified diff
against the configured output file without creating or changing that file.
`--stdout`, `--diff`, and `--commit` are intentionally mutually exclusive.

### `print_schedulers.sh`

**Runs on your machine, not on the router**, and contacts nothing at all: it
prints the `/system scheduler add` command for every script here that is meant
to run unattended — the eight intervals from the table above, and for the twelve
scripts that table omits, the interval named in each script's own header comment
— and you paste what you agree with.

Installing a script is the easy half. Scheduling it is where this package goes
quiet, because a script that was never scheduled looks exactly like a script
with nothing to report, and you find that out in the month you needed the
backup.

```bash
./print_schedulers.sh                        # read it, then paste it
./print_schedulers.sh --include-notify-boot  # add the startup notifier
./print_schedulers.sh --policy read,test     # a narrower policy set
./print_schedulers.sh --only backup          # generate one reviewed entry
./print_schedulers.sh --update-script stay_fresh  # which update script (default update_check)
./print_schedulers.sh --list                 # names accepted by --only
./print_schedulers.sh > schedulers.rsc       # keep it, diff it later
```

`update_check`, `backup_update_check` and `stay_fresh` do one job three ways
and must not be scheduled together, so only one is printed:
`--update-script NAME` chooses it, `update_check` by default.

The daily entries carry an explicit `start-time`, staggered across the small
hours: `interval=1d` on its own anchors to the moment the entry was created, so
a router rebuilt at 19:40 would take its nightly backup at 19:40. The manual
scripts — `tg_send`, `detect_internet`, `reboot-and-flush`,
`firewall_drift_baseline`, `change_WIFI_pw` — are never printed.

Everything it emits is valid RouterOS input, commentary included (the notes are
`#` comment lines, and the colour only appears on a terminal), so the output can
go into a file and be pasted from there.

### `router_doctor.py`

**Runs on your machine, not on the router.** Read-only, like the other
diagnostics in this repository: it asks a router over ssh which of these scripts
are in `/system script`, which of them a `/system scheduler` entry actually
runs, and whether the globals they need are set — then prints the command that
fixes what it found.

```bash
./router_doctor.py --host 192.168.88.1
./router_doctor.py --host router.lan --identity ~/.ssh/keys/projects/mikrotik/mikrotik_rsa
./router_doctor.py --host router.lan --port 2222
./router_doctor.py --host router.lan --format json
```

Secrets stay on the router. The check on `TgBotToken` and `TgChatId` asks
for the **length** of each secret global and never for the value, so no token crosses
the wire or reaches your terminal — the report can say `set` or `empty`, and
that is all it knows. The one value it reads is the non-secret boolean
`OpsToolboxPaused`, so a forgotten maintenance pause is visible.

Not installing a script is a choice — nobody wants `ddns_update` without
Cloudflare — so a missing one is reported as context rather than as a problem.
Three things are real findings: a scheduler that runs a script which is not
installed (it fails at every run, and only `/log` says so), a script installed
but scheduled nowhere, and a manual-only script somebody put on a timer.

Same connection flags as `export_config.py` (`--host`, `--user`, `--identity`,
`--port`). `--format json` returns installed script names, scheduler
names/intervals, controls, and structured findings. Free-form scheduler source
is deliberately omitted because an inline `on-event` can contain credentials.
It preserves the same exit semantics: `0` findings printed, `1` connected but
the probe failed, `2` could not connect, `4` nothing wrong.

### `pull_router_backups.sh`

**Runs on your machine, not on the router.** Copies the files `backup.lua`
creates — `backup-*.backup` and `backup-*.rsc` — off the router into a local
directory over SFTP/SCP.

```bash
./pull_router_backups.sh admin@192.168.88.1
./pull_router_backups.sh admin@router.lan ~/Archive/mikrotik-backups
./pull_router_backups.sh --port 2222 --identity ~/.ssh/router admin@router.lan
./pull_router_backups.sh --dry-run admin@router.lan ~/Archive/mikrotik-backups
./pull_router_backups.sh --timeout 30 admin@router.lan   # slow link or a WAN hop
```

`--timeout SECONDS` is the ssh connect timeout, 10 by default; a non-integer is
usage, exit `3`.

Needs RouterOS 7+ SFTP (**IP → Services**) and key-based ssh: `BatchMode=yes`
means it fails rather than prompting. It proves the router is reachable before
an empty result is allowed to mean "no backups yet", because those two used to
be indistinguishable — an unreachable host, a rejected key and SFTP switched off
all exited `0`, so a cron job reported success while backups had silently
stopped for months. `--dry-run` previews the exact SSH/SCP calls without
contacting the router or creating the destination. Exit codes: `0` files pulled or none exist yet, `1` reached
the router but the transfer failed, `2` could not reach it, `3` usage.

## Security action surface

The four security scripts above keep their actions on a small, reversible
surface so a noisy detector cannot brick the router:

| Address-list        | Populated by         | Purpose                                                    |
| ------------------- | -------------------- | ---------------------------------------------------------- |
| `dhcp-watch-new`    | `dhcp_lease_watch`   | New DHCP lease IPs (informational; tag for ad-hoc rules).  |
| `dhcp-unknown`      | `mac_allowlist_dhcp` | DHCP lease IPs whose MAC is not on the allowlist.          |
| `fw-drift-events`   | `firewall_drift`     | Sentinel marker `127.0.0.1` per drift event (audit trail). |
| `rogue-dns-clients` | `rogue_dns_check`    | Source IPs caught using non-approved DNS resolvers.        |

Optional filter rule templates (commented out on purpose — review first,
then apply if you want enforcement). All of them assume the lists above are
populated by the corresponding scheduled scripts:

```routeros
# Drop traffic from devices not on the MAC allowlist (mac_allowlist_dhcp).
/ip firewall filter add chain=forward action=drop \
    src-address-list=dhcp-unknown comment=mac-allowlist-block disabled=yes

# Redirect port-53 traffic from rogue clients to the router itself
# (rogue_dns_check). NAT entries that match are then DNAT'd onto 192.0.2.1.
/ip firewall nat add chain=dstnat action=dst-nat to-addresses=192.0.2.1 \
    protocol=udp dst-port=53 src-address-list=rogue-dns-clients \
    comment=rogue-dns-redirect disabled=yes

# Quarantine new DHCP devices from talking to the LAN until you
# acknowledge them (dhcp_lease_watch with Enforce=true).
/ip firewall filter add chain=forward action=drop \
    src-address-list=dhcp-watch-new comment=dhcp-watch-quarantine disabled=yes
```

To re-baseline the firewall drift detector after an intentional change,
either run `/system script run firewall_drift_baseline` from the terminal or
schedule it manually before applying the change.

## Docker integration tests (CHR 7.24.2)

To validate all scripts on **real RouterOS 7.24.2** inside Docker (QEMU + official CHR
image), use [`tests/README.md`](tests/README.md) and from the repo root run
`./mikrotik/tests/run.sh`. This is the closest practical “emulation” of your router:
MikroTik does not ship a standalone script interpreter, so the tests talk to a live
CH instance over the API.

The tested version is stored once in `tests/routeros-version.env`. GitHub checks
MikroTik's official release feed every Monday and Thursday, tests a newer CHR
image before changing files, and opens a version/documentation bump pull request
only after the complete integration suite passes. See
[`tests/README.md`](tests/README.md#release-checks-and-version-bumps) for local
candidate testing and the manual workflow controls.

The macOS setup scripts in this repo have a **separate** lightweight Docker
harness (syntax + ShellCheck only, no Homebrew) — see
[`macos-initial-setup/README.md`](../macos-initial-setup/README.md#development-docker-checks).

## RouterOS 7.24.2 notes & gotchas

- RouterOS scripts use `/` for paths and `:` for built-in commands
  (`:local`, `:if`, `:foreach`). `:interface ...` is **not** valid syntax —
  always `/interface ...`.
- `/tool fetch` requires the `ftp` policy, not just `read`.
- HTTPS fetches verify TLS certificates by default. If `tg_send` reports
  fetch failures, either import a CA bundle:

  ```routeros
  /tool fetch url=https://curl.se/ca/cacert.pem dst-path=cacert.pem
  /certificate import file-name=cacert.pem passphrase=""
  ```

  or, less securely, append `check-certificate=no` to the fetch command in
  `tg_send.lua`.
- Telegram message text uses URL-style escapes: `%0A` for newline, `%25` for a
  literal percent sign, `\F0\9F...` for emoji codepoints encoded as UTF-8 byte
  literals. When copy-pasting through editors, double-check those escape
  sequences survived. The percent one is easy to skip because it usually looks
  fine: `tg_send` posts the text as `application/x-www-form-urlencoded`, so a
  bare `%` is a truncated escape sequence, and whether that reaches Telegram as
  a percent sign or as a 400 is the decoder's choice rather than yours. It
  stops being cosmetic the moment the two characters after it happen to be hex
  digits, which silently produces a byte instead.
- `:global` variables persist across scheduler runs *within an uptime
  session*. They are cleared on reboot — `wan_failover_notify` relies on
  this and treats the first post-boot run as the baseline state.
- For `change_WIFI_pw` on RouterOS 7.13+: the new `wifi` (WiFiWave2) stack
  uses `/interface wifi security` with the property `passphrase`, not the
  legacy `/interface wireless security-profiles wpa2-pre-shared-key`. Toggle
  `UseWifiWave2` accordingly.
