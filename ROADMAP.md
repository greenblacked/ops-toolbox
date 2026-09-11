# Improvement plan

Working order after `master` @ `d524d447`. Measured against the tree, not
against a wish list. The copy-into-`~/bin` rule does not change.

## What is actually true

- [#33](https://github.com/greenblacked/ops-toolbox/pull/33) is mergeable and
  CI-green, including CHR. It is the next merge. Do not stack more stay_fresh
  work on current `master`.
- After #33, `macos-initial-setup/stay_fresh.sh` is **4000 lines**. Linux is
  436. Windows `setup/stay_fresh.ps1` already exists and is 217. There is no
  missing Windows sweeper.
- `v1_stay_fresh.sh` is a documented preserved original, with suite exceptions
  by name. It is not leftover clutter.
- RouterOS 7.24.2 is the verified pin. That release refuses to *execute* a
  script whose source declares a `:global` with `_` in the name. Eighteen of
  the `.lua` files still do that. Only `stay_fresh.lua` and
  `backup_update_check.lua` were written around the bug on purpose.
- Dependabot watches Actions and Dockerfiles. It does not watch
  `k8s-toolbox/versions.env`, `.github/ci-tool-checksums.env`, or the CHR
  RouterOS pin.
- There are no tags. `CHANGELOG.md` is already ~1700 lines on `master`.

## Priority 0 — merge #33

Merge it. Confirm the `master` CI run. Then delete leftover remotes that have
no open pull request. That is ten minutes of hygiene, not a workstream.

Do not open a second stay_fresh or CI-matrix branch against pre-#33 `master`.
The extra `history.tsv` column and the `changelog.d/` fragments will conflict.

## Priority 1 — RouterOS names, in waves, not one rename PR

This is the only remaining defect that makes scripts fail on the hardware the
package claims to support.

You cannot leave a compatibility `:global TG_BOT_TOKEN` in the script body.
The declaration itself is what 7.24 rejects. Dual-read inside the same file
is therefore impossible for the old names.

Do it in this order:

1. **Wave A — notify path.** `tg_send.lua` first. New names in the
   `stay_fresh.lua` style (`TgBotToken`, `TgChatId`). Document the mapping in
   `mikrotik/README.md`. Add a short terminal snippet that copies values from
   `/system script environment` old → new. Every other script that talks to
   Telegram is useless on 7.24 until this one runs.
2. **Wave B — backup / update.** `backup.lua` and `update_check.lua`, or
   retire them in the README as 7.23-and-older and point 7.24 operators at
   `backup_update_check.lua` / `stay_fresh.lua` only. Retiring is smaller and
   safer if you no longer have a pre-7.24 router.
3. **Wave C — watches.** One script per PR: `wan_failover_notify`,
   `dhcp_lease_watch`, `traffic_quota`, Cloudflare DDNS, and the rest. Each
   ships its own env-name mapping and a CHR assertion that the file `:parse`s
   on the pinned release.

Validation: CHR on the PR path. Rollback on a router is paste-the-previous-
source; replace `tg_send` and the caller in the same window so a running
scheduler does not call a helper that no longer shares names.

Do not flip every xfail in one commit. Flip the file you just made runnable.

## Priority 2 — freeze stay_fresh.sh feature growth

#33 already closed the dangerous class: a probe that cannot answer must not
authorise a delete. After it lands, new cache targets need a regression test
that fails first when the probe is silent, missing, or localised. No new step
without that test.

Do not extract helpers into `lib/`. Do not retire `v1_stay_fresh.sh` as a
cleanup. Do not add a fourth sweeper on Windows.

If the file has to grow, the sanctioned shape is the one
`workspace_scan.py` already uses: a substantial program with its own tests,
invoked as a subprocess by absolute path. Not `source ./common.sh`.

## Priority 3 — pin watchers, then a tag

A tag is useful once #33 is on `master`. It is not more urgent than a router
script that will not parse.

Before or with `v0.1.0`:

1. A scheduled job or Dependabot-adjacent check that fails when
   `versions.env`, `ci-tool-checksums.env`, or the CHR RouterOS pin is older
   than a documented threshold. Today those pins rot quietly.
2. Cut `v0.1.0`, move `[Unreleased]` into that section, keep writing fragments
   under `changelog.d/`.
3. Say in `SECURITY.md` that a tag is a snapshot, not a support contract.
   That file already says there is no response window; keep it.

## Priority 4 — k8s-toolbox only if you will run it this month

`kubectl_pod_diag.sh` already reports node pressure. A second node script is
not the gap. The useful next file, if any, is a **read-only**
`gke_cluster_doctor.sh`: release channel, node-pool vs control-plane skew,
Workload Identity, private-cluster DNS, recent quota events. It prints the
`gcloud`/`kubectl` command that would fix each finding and never mutates.

Do not add `stern` or `k9s` to the image because the list looks short.

## What not to do

- Do not split `ci.yml` because it is 900 lines. #33 already derives the suite
  matrix from `run-tests.sh --list`.
- Do not put gitleaks ahead of RouterOS names. The workstation config already
  lives in `dotfiles/config/gitleaks/`; wiring it into CI is a half-day, not
  the highest defect.
- Do not rewrite Git history.
- Do not auto-install macOS or RouterOS updates.
- Do not grow `.claude/hooks/` further in this repository unless the hook is
  doing something CI cannot. The exception in `.gitignore` is already special
  casing.

## Next three pull requests after #33

1. `fix/routeros-tg-send-names` — `tg_send.lua` + mapping + CHR parse test.
2. `docs/retire-or-keep-update-check` — explicit 7.24 vs older matrix in the
   MikroTik README, so operators stop pasting `update_check.lua` onto 7.24.
3. `chore/pin-age-and-v0.1.0` — pin age check, then the first tag.
