# Improvement plan

This is the working order for `ops-toolbox` after `master` at
`d524d447` (9 September 2026). It is not a backlog of ideas. Each item is
either already sitting in an open pull request, or is a gap the scripts and
CI already demonstrate.

The architectural rule does not change: a script still has to work when
copied on its own into `~/bin`. Shared libraries stay off the table.

## Current state

| Item | State |
| --- | --- |
| Default branch | `master` @ `d524d447` |
| Open pull request | [#33](https://github.com/greenblacked/ops-toolbox/pull/33) — mergeable, CI green including CHR |
| Releases / tags | none |
| Open issues | none |
| Packages | `git`, `macos-initial-setup`, `linux`, `windows`, `mikrotik`, `k8s-toolbox`, `dotfiles` |
| Dependabot | monthly grouped PRs for Actions and Dockerfiles |

[#33](https://github.com/greenblacked/ops-toolbox/pull/33) already carries the
next slice of product work: stay_fresh hardening and `--trend` on macOS,
power-aware scheduling, Linux Trash/`HOME`/`--home` fixes, a CI matrix derived
from `run-tests.sh --list`, `git/clone-repos.sh`, changelog fragments, and
`CODEOWNERS`. Treat that pull request as phase 0, not as a competing plan.

## Phase 0 — land what is already finished

1. Merge [#33](https://github.com/greenblacked/ops-toolbox/pull/33) to `master`.
   Do not open parallel stay_fresh or CI-matrix branches against current
   `master`; they will conflict with the fragments and the history.tsv column
   change.
2. Confirm the post-merge `master` CI run, including Lint, conventions, the
   Linux matrix, macOS native, Windows native, and CHR if the merge touches
   `mikrotik/`.
3. Delete remote branches that already lost their pull request. As of this
   writing that list is:

   ```text
   chore/deferred-review-cleanups
   claude/devops-tools-config-practices-6junj8
   docs/readme-consistency
   feat/ci-matrix-clone-repos-session-hook
   feat/dotfiles
   feat/git-clone-repos
   feat/session-start-hook
   feat/stay-fresh-macos-krew-snapshots
   feat/stay-fresh-timeouts-and-verdict-fixes
   feat/stay-fresh-user-logs-reports-slack
   fix/dry-run-snapshot-and-ci-gates
   fix/linux-stay-fresh-trash-log-home
   fix/macos-stay-fresh-protections
   ```

   Keep `feat/stay-fresh-downloads-agents-notify-when` only until #33 is on
   `master`. Then delete it too.

   `git/git_stale_branches.sh` and `git/git_cleanup_merged.sh` are the tools
   for this, not a one-off `git branch -D` list in chat.

## Phase 1 — first tag, so CHANGELOG.md can stop being the release

`CHANGELOG.md` is already larger than most of the packages. There is no tag,
so every dated section is reconstructed history rather than a release.

1. After #33 lands, cut `v0.1.0` from `master`.
2. Move `[Unreleased]` into that version section the same day.
3. Keep writing new work as `changelog.d/<type>/` fragments (introduced in
   #33). The assembled file is generated at tag time, not edited by every
   branch.
4. Document the tag command and the fragment layout in `CONTRIBUTING.md` so
   the next tag is mechanical.

Risk: tagging advertises a support surface this repository has explicitly
said it does not have (`SECURITY.md`). The tag is a snapshot, not a promise.
Keep the security policy wording as it is.

## Phase 2 — RouterOS 7.24 underscore names

This is the highest-severity remaining functional defect, and it is already
documented in the changelog.

RouterOS 7.24 rejects a `:global` whose name contains `_`. `backup.lua`,
`update_check.lua` and `tg_send.lua` still declare those names.
`backup_update_check.lua` and `stay_fresh.lua` were written around the bug;
the older three were not. CHR tests for the older two are xfail.

Do this as one pull request, not three:

1. Rename every underscored `:global` in the package to a RouterOS-legal
   name. Keep a one-release compatibility alias only where an operator's boot
   script already sets the old name (`TG_BOT_TOKEN` / `TG_CHAT_ID` are the
   ones that matter).
2. Flip the CHR xfails to real assertions on the same release pin.
3. Keep secrets out of script bodies. The rename is a name change, not a
   move of tokens into the files.

Validation: CHR suite on the PR path (`mikrotik/`, `run-tests.sh`, or
`chr.yml`). Rollback is the previous script source on the router; these are
pasted artefacts, so the PR README must say which `/system script` entries
to replace together.

## Phase 3 — stay_fresh is finished as a product, not as a file

`macos-initial-setup/stay_fresh.sh` is the file that keeps producing silent
delete bugs. #33 already closed a set of them (SIP, Electron `pgrep`, CloudStorage
workspaces, Docker `until=`, simulators, `TF_PLUGIN_CACHE_DIR`, empty `HOME`,
step timeouts). Do not split it into a library. Do these instead:

1. Retire `macos-initial-setup/v1_stay_fresh.sh` once nothing in the README
   or launchd agent still points at it. A second implementation of the same
   job is how the next audit misses a path.
2. Add a Windows counterpart only if a real machine needs it. The Windows
   package already has `cleanup/clean_disk_c.ps1` and WSL VHDX work; a third
   sweeper that reimplements macOS steps in PowerShell will drift. Prefer
   extending `clean_disk_c.ps1` with the same verdict / history / `--trend`
   shape over a new `stay_fresh.ps1`.
3. Do not add more cache targets without a regression test that fails first
   when the probe cannot answer. The #33 review record is the rule: a probe
   that cannot answer must not authorise a delete.

## Phase 4 — k8s-toolbox, one script at a time

The image, `run.sh`, `debug_pod.sh` and `kubectl_pod_diag.sh` are already at
the repository's quality bar. The gap is coverage of the questions that come
up on a GKE cluster after "which pods are unhappy".

Add standalone scripts, each with `--help`, `--dry-run` where anything would
change, and an exit `4` for nothing to report:

1. `kubectl_node_diag.sh` — Ready / pressure / taints / allocatable vs
   requested, read-only. `kubectl_pod_diag.sh` already prints pressure; this
   is the node-shaped version, not a copy of the pod one.
2. `gke_cluster_doctor.sh` — read-only: release channel, node-pool versions
   vs control plane, Workload Identity, private-cluster DNS, current quota
   errors from recent events. Prints the `gcloud` / `kubectl` command that
   would fix each finding. Never mutates the cluster.
3. Pin `stern` or `k9s` in `versions.env` only if they are used from the
   image in anger. Do not grow the image because the list looks short.

Keep the image unprivileged and the examples restricted. The debug variant
stays the place for `tcpdump` / `strace`.

## Phase 5 — CI cost and the 38 KB workflow

`.github/workflows/ci.yml` on `master` is ~38 KB. #33 already derives the
suite matrix from `run-tests.sh --list`, which removes one class of drift.
What is still worth doing, in this order:

1. Keep path filters. CHR already has them. Do not put the QEMU boot back on
   every pull request.
2. Split `ci.yml` only when a change to Lint starts conflicting with a change
   to the Linux matrix. One file is still easier to review than five half-
   duplicated ones.
3. Add gitleaks (or an equivalent secret scan) on pull requests, using the
   config already shipped in `dotfiles/config/gitleaks/`. That file currently
   configures a workstation; it does not gate the repository.
4. Leave artefact checksums in `.github/ci-tool-checksums.env`. A version
   bump without a digest bump must keep failing.

## Phase 6 — docs that the suites can keep true

The root README's per-package "at a glance" sections are unique prose, not
duplicates of the folder READMEs (#33 measured 0–6% overlap). Leave them.

Do:

1. Point the root README at this file once the plan is accepted, under
   Contributing / Testing, not in the opening paragraph.
2. Keep the README-drift check that #9 added. A new script without a row in
   its folder README should fail CI.
3. Stop restating agent-skill copy counts in `CONTRIBUTING.md`. The local
   skills directory is gitignored; the published rules live in that file.

## What not to do

- Do not extract `require_value()` or the colour helpers into `lib/`.
  `CONTRIBUTING.md` already records why, and the static suite already asserts
  the contract of every copy.
- Do not rewrite Git history to strip old attribution. New commits stay
  `Serhii Zolotov <zolotov.98@gmail.com>` and carry no co-author trailers.
- Do not add a framework to the test harnesses. The hand-rolled
  `ok` / `err` / `assert_eq` shape is the suite.
- Do not auto-install macOS or RouterOS updates. Reporting is the product;
  rebooting a machine or a router is the operator's decision.
- Do not open another mega-PR like #33. One concern per branch, with a
  changelog fragment, is how those five closed PRs stopped colliding.

## Suggested next three pull requests

After #33:

1. `chore/retire-stale-branches-and-tag-v0.1.0` — delete the leftover
   remotes, write the tagging steps into `CONTRIBUTING.md`, cut `v0.1.0`.
2. `fix/routeros-global-names` — underscore rename + CHR xfail flip.
3. `feat/k8s-node-diag` — `kubectl_node_diag.sh` and its suite rows only.

Each of those is mergeable on its own if the others stall.
