# MikroTik RouterOS scripts

A small collection of RouterOS 7.x scripts (verified against **RouterOS 7.24.1**)
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

## Files at a glance

| File                            | Purpose                                                                 |
| ------------------------------- | ----------------------------------------------------------------------- |
| `tg_send.lua`                   | Generic Telegram text-message helper used by every other script.        |
| `backup.lua`                    | Dated, version-stamped backup + export; prunes the previous one.        |
| `change_WIFI_pw.lua`            | Rotates 2.4 GHz / 5 GHz WPA2 PSK and announces it via Telegram.         |
| `health_check.lua`              | CPU / RAM / disk / temperature watchdog with threshold alerts.          |
| `update_check.lua`              | Backs up, then notifies when a newer RouterOS version appears.          |
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
   :global TG_BOT_TOKEN "123456:ABC...";
   :global TG_CHAT_ID   "12345678";
   ```

   then add a Scheduler entry with `start-time=startup` pointing to it. The
   `tg_send` helper picks them up automatically.
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
limit. Reads `:global TG_BOT_TOKEN` / `:global TG_CHAT_ID` if defined so
secrets can stay out of the script body.

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

The channel is read and reported, never written. Setting it would mean the
script overriding a deliberate choice: a router parked on `long-term` moved to
`stable` on the next tick, then correctly told an upgrade is available — to a
release train somebody had specifically kept it off.

Completion is detected by polling `status` until it reaches a verdict, up to
about 65 seconds (`:global UPDATE_CHECK_MAX_WAIT` in five-second units, for a
slow or contended link), rather than waiting a fixed interval or waiting for
`latest-version` to fill. RouterOS keeps `latest-version` from the previous
check, so on every run after the first it is already populated the instant the
command is issued, and a loop waiting for it to fill exits immediately with
last week's answer.

A check that never completes sends its own message (`:global
UPDATE_CHECK_NOTIFY_FAILURE false` to disable). It only fires where the router
can still reach Telegram — DNS broken, the upgrade server refusing, a proxy in
the way — which is exactly the case where a router sits on an unpatched
release with nothing saying so. A fully offline router cannot report anything,
and no arrangement here changes that.

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
./print_schedulers.sh --list                 # names accepted by --only
./print_schedulers.sh > schedulers.rsc       # keep it, diff it later
```

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

Secrets stay on the router. The check on `TG_BOT_TOKEN` and `TG_CHAT_ID` asks
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

## Docker integration tests (CHR 7.24.1)

To validate all scripts on **real RouterOS 7.24.1** inside Docker (QEMU + official CHR
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
[`macos-initial-setup/README.md`](../macos-initial-setup/README.md#development--docker-checks).

## RouterOS 7.24.1 notes & gotchas

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
