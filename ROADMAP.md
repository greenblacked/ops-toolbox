# Improvement plan

[Ops Toolbox](README.md) / **Improvement plan**

Working order after `master` @ `e6c5573`. Measured against the tree, not
against a wish list. The copy-into-`~/bin` rule does not change.

This file was first written against `master` @ `d524d447` and lived on a branch
that was never merged, which is how most of it came true without anyone
crossing it off. Every claim below was re-checked against the current tree on
2026-09-16. When you act on one, re-check it rather than trusting the date.

## Contents

- [What is actually true](#what-is-actually-true)
- [Priority 1 — finish the RouterOS names](#priority-1--finish-the-routeros-names)
- [Priority 2 — cut the first tag](#priority-2--cut-the-first-tag)
- [Priority 3 — hold the stay_fresh freeze](#priority-3--hold-the-stay_fresh-freeze)
- [What not to do](#what-not-to-do)
- [Next pull requests](#next-pull-requests)

## What is actually true

- **The backlog this file opened with is merged.** #33 landed, and #40, #46,
  #47, #48 and #53 after it. Twenty-three pull requests are on `master`.
- `macos-initial-setup/stay_fresh.sh` is **4243 lines**. `linux/stay_fresh.sh`
  is 440 and `windows/setup/stay_fresh.ps1` is 276. There is still no missing
  Windows sweeper.
- `v1_stay_fresh.sh` is a documented preserved original, with suite exceptions
  by name. It is not leftover clutter.
- **RouterOS is still the open defect, and it is now a measured one.**
  Sixteen of the 28 `.lua` files declare a `:global` whose name contains an
  underscore, which 7.24 refuses to execute. What changed is that this is no
  longer silent: `mikrotik/README.md` opens with the count and carries a
  per-script compatibility list, `test_lua_conventions.sh` fails when that list
  and the scripts disagree, and the CHR cases are marked `xfail` rather than
  quietly skipped. The defect is contained and documented; it is not fixed.
- **Wave A is done.** `tg_send.lua` reads `TgBotToken` and `TgChatId`, so the
  notify path works on 7.24 and every rename after it is a script at a time.
- **Pin rot is watched.** `test-env/static/check_pin_age.sh` fails on
  `k8s-toolbox/versions.env`, `.github/ci-tool-checksums.env` and
  `mikrotik/tests/routeros-version.env` once they pass a documented threshold.
- `gke_cluster_doctor.sh` landed, read-only, as this file suggested.
- **There are still no tags.** `CHANGELOG.md` is ~2000 lines and there are 82
  fragments waiting under `changelog.d/`.

## Priority 1 — finish the RouterOS names

Still the only defect that makes scripts fail on the hardware the package
claims to support, and the twelve scripts that do run are the proof it is
worth finishing.

You cannot leave a compatibility `:global TG_BOT_TOKEN` in the script body.
The declaration itself is what 7.24 rejects, so dual-read inside one file is
impossible for the old names.

Wave A (`tg_send.lua`) is merged. What remains:

1. **Wave B — backup / update.** `backup.lua` and `update_check.lua`, or
   retire them in the README as 7.23-and-older and point 7.24 operators at
   `backup_update_check.lua` / `stay_fresh.lua`, both of which already run.
   Retiring is smaller and safer if you no longer have a pre-7.24 router.
2. **Wave C — watches.** One script per pull request, from the fourteen left:
   `wan_failover_notify`, `dhcp_lease_watch`, `traffic_quota`, `ddns_update`,
   `latency_monitor`, `rogue_dns_check`, `mac_allowlist_dhcp`,
   `bandwidth_spike`, `brute_force_block`, `firewall_drift`,
   `firewall_drift_baseline`, `vpn_health`, `wan_link_flap_notify`,
   `wireless_client_watch`. Each ships its own env-name mapping in the README
   and flips its own CHR case from `xfail` to passing.

Validation is CHR on the pull request path, and it is not optional: the whole
failure mode is a script that parses on your laptop and dies on the router.
Rollback on a router is paste-the-previous-source.

Do not flip every `xfail` in one commit. Flip the file you just made runnable.
The README count and the test that guards it move with each one.

## Priority 2 — cut the first tag

Now unblocked — the reason to defer it was #33, and #33 is five merges back.

1. Cut `v0.1.0`. `changelog.d/changelog.sh release` moves `[Unreleased]` and
   the 82 fragments under the version heading; keep writing fragments after.
2. Say in `SECURITY.md` that a tag is a snapshot, not a support contract. That
   file already says there is no response window; this is the sentence that
   stops a tag from implying one.
3. A repository with no releases reads as unmaintained however recent the
   commits are. The Releases checklist is in
   [`CONTRIBUTING.md`](CONTRIBUTING.md#repository-settings).

A tag is a repository setting and a release note, not a code change. It is the
owner's to cut.

## Priority 3 — hold the stay_fresh freeze

This is no longer a plan; it is a rule, and it lives in
[`CONTRIBUTING.md`](CONTRIBUTING.md#the-one-architectural-rule). Kept here so
the reason survives next to the file it constrains.

New cache targets need a regression test that fails first when the probe is
silent, missing, or localised. No new step without that test.

Do not extract helpers into `lib/`. Do not retire `v1_stay_fresh.sh` as a
cleanup. Do not add a fourth sweeper on Windows.

If the file has to grow, the sanctioned shape is the one
`macos-initial-setup/lib/workspace_scan.py` already uses: a substantial program
with its own tests, invoked as a subprocess by absolute path. Not
`source ./common.sh`.

## What not to do

- Do not put gitleaks ahead of the RouterOS names. The workstation config
  already lives in `dotfiles/config/gitleaks/`; wiring it into CI is a
  half-day, not the highest defect.
- Do not rewrite Git history.
- Do not auto-install macOS or RouterOS updates.
- Do not split `.github/workflows/ci.yml` because it is long. It already
  derives its suite matrix from `run-tests.sh --list`, so a new suite gets a
  job without the workflow being edited.
- Do not grow `.claude/hooks/` in this repository unless the hook is doing
  something CI cannot. The exception in `.gitignore` is already special
  casing, and a hook that CI could run instead is a check nobody else gets.
- Do not let this file rot again. A plan on an unmerged branch is a plan
  nobody reads; if a priority here is wrong, edit it or delete it.

## Next pull requests

1. `fix/routeros-backup-update-names` — Wave B, or the README matrix that
   retires those two scripts for 7.24.
2. `chore/v0.1.0` — the release move plus the `SECURITY.md` sentence.
3. Wave C, one script at a time, in the order you actually run them.
