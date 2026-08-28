---
name: routeros-script-conventions
description: How the MikroTik RouterOS scripts in mikrotik/ are written and checked - the OpsToolboxPaused maintenance switch, secrets via :global instead of a script body, alerting on transitions rather than every run, tg_send wrapping, failing safe when unconfigured, and the convention suite plus the pinned CHR version workflow that verify them. Use this whenever you write or edit a .lua file under mikrotik/, or work on the RouterOS version pin, the CHR integration suite, or a router notification script.
---

# RouterOS scripts in this repository

The `.lua` extension is for editor highlighting only - these are RouterOS
scripting language, not Lua. They are pasted into a router's *Source* field one
at a time, which shapes every rule below.

## What `mikrotik/tests/test_lua_conventions.sh` enforces

That suite needs no router and runs on every pull request, so treat it as the
definition of done for a script change. It checks:

- **Balanced `{}` and `[]`.** RouterOS reports an unbalanced brace as a runtime
  parse failure on the device, which for a scheduled script means it silently
  never runs again.
- **The fleet-wide pause switch.** Every unattended script opens with the
  guard, so planned router work does not mean disabling twenty scheduler
  entries by hand and remembering every one afterwards:

  ```text
  :global OpsToolboxPaused;
  :if (([:typeof $OpsToolboxPaused] = "bool") and $OpsToolboxPaused) do={ :return ""; }
  ```

  Manual-only helpers must **not** carry it - an operator has to be able to
  baseline or recover during the maintenance window. `router_doctor.py` probes
  the switch so a forgotten pause stays visible without flooding the log on
  every tick.
- **A header comment on line one.** These are pasted with no filename
  attached, so the first line is the only thing telling the next person what
  the script does.
- **A failed notification is never silent.** `:do {...} on-error={}` around a
  `tg_send` call discards the failure entirely, and every alert the package
  exists to raise is lost. Silent handlers around *optional reads* are fine and
  deliberate - `/system health` on hardware with no sensors, `/ip ipsec` on a
  router with none - so the suite counts those and leaves the judgement to a
  human rather than inventing a rule people would contort code to satisfy.
- **Secrets have a `:global` override.** A script whose credential has no
  `:global` path leaves editing the script body as the only way to set it,
  which is how a live token ends up in a commit.
- **Documentation has not drifted** from the script set.

## The conventions the suite cannot check

- **Secrets never appear in a script body.** Read them from `:global` variables
  set once at boot, the way `mikrotik/tg_send.lua` overrides its placeholder
  `BotToken` / `ChatID` locals from `TG_BOT_TOKEN` and `TG_CHAT_ID`.
- **Send notifications through `tg_send`**, wrapped so a missing helper
  degrades to a log line instead of an error - `mikrotik/backup.lua` ends its
  send with `on-error={ :log warning "tg_send not available - skipping
  notification"; }`, and logs an error rather than nothing when the *failure*
  notification is the thing that could not be sent.
- **Alert on transitions, not on every run.** Keep the previous state in a
  `:global` and compare - `wan_failover_notify.lua` is the reference. A script
  that alerts every five minutes gets muted, which makes it worse than nothing.
- **First run establishes a baseline silently.** The exception is a global
  reset by reboot, where one baseline notification is intentional and the
  script says so in its header.
- **Always `:log` as well as notifying.** The router log is the source of
  truth; there is no host-side logfile for any of this.
- **Fail safe when unconfigured.** `mac_allowlist_dhcp.lua` refuses to act on
  an empty allowlist rather than blocking every client. Anything that deletes
  or blocks needs an equivalent floor, and that floor should be its first test.

## Version pinning and the CHR suite

`mikrotik/tests/routeros-version.env` holds `ROUTEROS_VERSION` and the
SHA-256 of MikroTik's published image. The digest is the point: `test -s` only
proved the download was non-empty, which a hijacked mirror or a TLS-terminating
proxy also satisfies. `run.sh` refuses to start without a digest rather than
falling back to an unverified download, so an empty line can only mean the pin
was lost.

```bash
mikrotik/tests/routeros_version.py record-hash   # record or refresh the digest
./run-tests.sh mikrotik                          # Docker + QEMU, minutes
```

The suite boots a real CHR under QEMU, so it is excluded from the default
`./run-tests.sh` selection and runs nightly. `.github/workflows/routeros-version.yml`
checks the release feed twice a week, tests the candidate against **its own**
digest rather than the current pin, and opens a `chore/routeros-VERSION` pull
request only after the integration suite passes. Two lessons are baked into it
and worth keeping: a release is listed in every channel it sits in, so matching
a feed title against one channel name breaks on the first multi-channel
release; and the pinned version must stay out of workflow files, or the bump
has to touch two places and will eventually touch one.
