# Security Policy

## Reporting a vulnerability

Open a [private security advisory](https://github.com/greenblacked/pretty-useful-scripts/security/advisories/new)
rather than a public issue. Please include the script, the command you ran, and
what happened.

There is no formal response window — this is a personal collection of helper
scripts, not a product.

## What matters most here

These scripts run with real privileges on real machines. The failure modes worth
reporting are:

- **A script that deletes more than it says it will.** Everything destructive is
  supposed to be reachable only through an explicit opt-in flag, and every
  `--dry-run` is supposed to write nothing at all.
- **A secret that ends up on disk or in a log.** Scripts log to
  `${TMPDIR:-/tmp}` and should never write credentials there.
- **A privilege escalation** — a script that acquires `sudo` or Administrator
  rights for a step that did not need them.

## Secrets and the MikroTik scripts

RouterOS scripts in [`mikrotik/`](mikrotik/) never contain credentials in the
script body. Bot tokens, chat IDs and upload credentials are read from
`:global` variables set once at boot, so the scripts stay copy-pasteable and
shareable — see [`mikrotik/tg_send.lua`](mikrotik/tg_send.lua) for the pattern.

If you are adapting these scripts, keep that split. A router configuration
export contains the source of every `/system script`, so a token pasted into a
script body ends up in every backup you take.

## Running these scripts safely

- Use `--dry-run` (or `-DryRun` on PowerShell) the first time you run anything
  on a machine you care about.
- Read the README in the folder before running scripts from it.
- These scripts are provided under the MIT licence, without warranty. You are
  running them on your own machines at your own risk.
