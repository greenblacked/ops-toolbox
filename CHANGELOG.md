# Changelog

All notable changes to this repository are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
releases will follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once there is a tag to hang a version on.

There is no tag yet, so nothing below carries a release number. The dated
sections are reconstructed from the merge commits in `git log` and are grouped
by the day each pull request landed on `master`; they are history, not releases.
The first tagged version will be cut from `[Unreleased]`, and from then on every
entry here belongs to a version.

## [Unreleased]

### Fixed

- The RouterOS version workflow pushed its bump branch with a
  `--force-with-lease` that could never fire. The bare form compares against the
  remote-tracking ref, and the step fetched that ref immediately before pushing,
  refreshing the lease to the current remote tip — so it behaved as a plain
  `--force` and would silently discard a fix hand-pushed onto the bot branch.
  The remote SHA is now read before any local work and passed to the lease
  explicitly.
- The RouterOS version workflow was scheduled at `0 3 * * 1,4`. Minute 0 is the
  contended slot that `chr.yml` was already moved off in #22, and the first
  scheduled run fired at 05:37 rather than 03:00. It now runs at 04:19, on an
  odd minute distinct from the nightly's.
- The root README described the nightly CHR suite as running at 03:00 UTC. It
  has run at 03:37 since #22 moved it off the contended slot; only the workflow
  comment was updated at the time.
- `mikrotik/pull_router_backups.sh` exited `0` when it could not reach the
  router at all. An unreachable host, a rejected key or SFTP switched off in
  IP → Services were indistinguishable from "no backups yet", so a cron job
  reported success while backups silently stopped. It now probes reachability
  first and separates *could not connect* (`2`) from *reached it but the
  transfer failed* (`1`) from *connected, nothing to pull yet* (`0`).
- `mikrotik/update_check.lua` compared installed and latest versions with `!=`,
  which only answers "are these different". Switching a router from the stable
  channel to long-term made `latest` older than `installed`, and the script
  announced it as an available update — advertising a downgrade. It now gates
  on RouterOS's own `status` verdict.
- `mikrotik/backup.lua` had no way to set the backup password except editing
  the tracked script, unlike every other secret in the package. It now reads a
  `BACKUP_PASSWORD` global, matching `tg_send.lua` and `ddns_update.lua`.
- `backup.lua`, `detect_internet.lua` and `update_check.lua` swallowed a failed
  Telegram send with a bare `on-error={}`. A notification that never arrives and
  leaves no log makes the whole package silently decorative; all three now log.
- Twelve RouterOS scripts were missing from `mikrotik/README.md`.
- `--dry-run` created a timestamped log file in five scripts, contradicting the
  first promise in `README.md`. Log creation is now guarded, and the path that
  *would* be written is printed instead.

### Changed

- Long-term RouterOS workflow runs are now explicitly check-only; attempts to
  use that channel for the canonical stable version bump fail clearly instead
  of silently reporting an older long-term release as current.
- RouterOS CHR compatibility was bumped from 7.22 to 7.23.3 after the full Docker integration suite passed.
- **The repository was renamed from `pretty-useful-scripts` to `ops-toolbox`.**
  GitHub redirects the old URLs, so existing clones and links keep working;
  run `git remote set-url origin` to stop git warning on every fetch. Creating
  a new repository under the old name would break those redirects permanently.
- `set_git_profile.sh` now stores profiles under
  `${XDG_CONFIG_HOME:-$HOME/.config}/ops-toolbox/git-profiles.conf`. Profiles
  saved under the old directory are still read when the new path does not
  exist, and `--show` prints the command to migrate them. Nothing has to be
  moved by hand, and nothing is moved automatically.
- `git_hooks_install.sh` backs foreign hooks up to `.hooks-install-backup`
  rather than `.pre-pus-backup`, which abbreviated the old repository name.
- The Go test module is now `github.com/greenblacked/ops-toolbox/test-env/go`,
  which also adds the owner segment the old path was missing.

### Added

- `windows/setup/stay_fresh.ps1` — the Windows counterpart of
  `linux/stay_fresh.sh` and `macos-initial-setup/stay_fresh.sh`, down to the
  exit codes: a winget source refresh and `upgrade --all`, `wsl --update`, and
  a pending-reboot and free-space report, with `-DryRun` printing the whole run
  before any of it happens. `--include-unknown` is passed deliberately —
  without it winget skips every package whose installed version it cannot read,
  which is the usual reason a machine reports itself up to date and is not.
  Microsoft Store apps are left alone on purpose: their agreements have to be
  accepted interactively, so an unattended run cannot honestly claim to have
  updated them, and the script prints the command that does instead.
- `windows/setup/workstation_doctor.ps1` — the Windows half of
  `macos-initial-setup/workstation_doctor.sh`. BitLocker, Defender, the
  pending-reboot flags, free space on `C:`, WSL and its distros, and the
  effective execution policy, all read-only, which makes it the safe first
  thing to run on a machine someone has just handed you. Every probe is
  best-effort, because `Get-BitLockerVolume` does not exist on Home editions
  and `Get-MpComputerStatus` is missing wherever Defender has been replaced:
  a probe that cannot answer says so and the report carries on rather than
  dying before the section you needed.
- `windows/git-bash/install_dotfiles.sh` — copies `.bashrc`, `.bash_profile`
  and `.aliases` into `$HOME`, with the two checks the README's plain `cp`
  cannot do for you. It backs up whatever it replaces under one timestamp per
  run, leaves a file that already matches the source alone, and refuses to
  install a source file carrying CRLF line endings — printing the `sed` that
  fixes it rather than rewriting a file you are about to live in. CRLF in the
  file being replaced is reported too; that is usually the answer to the
  broken-prompt syntax error in the troubleshooting section.
- `windows/setup/winget-packages.example.json` — a worked example of what
  `winget_bootstrap.ps1 export` writes, so the `import`/`diff` documentation
  can be read without a Windows machine to hand. The same part
  `Brewfile.example` plays next to `brewfile.sh`, and it is a valid import
  file: `import -DryRun -File .\winget-packages.example.json` works against it.
- `linux/systemd/stay_fresh_timer.sh` — the Linux counterpart of
  `macos-initial-setup/launchd/stay_fresh_agent.sh`: `install`, `uninstall`,
  `status` and `run-now` for a `systemd` user timer that runs `stay_fresh.sh`
  on a schedule. The generated units are checked with `systemd-analyze verify`
  before anything is written, the way the macOS script lints its plist, and
  `--print-only` renders them without installing. Like the timer itself, the
  unit has no terminal to answer a sudo prompt from, so it always passes
  `--yes --no-sudo`.
- `linux/tests/test_linux_scripts.sh` now discovers scripts two levels deep, so
  anything under `linux/systemd/` gets the same `bash -n`, `--help` and
  unknown-flag coverage as the top-level scripts without being listed by hand.
- `mikrotik/tests/test_lua_conventions.sh` — RouterOS script conventions checked
  without a router, so they run on the pull-request path rather than waiting for
  the nightly CHR suite. 14 of the 25 scripts had no test of any kind, and a
  batch of twelve had landed with neither tests nor a README entry.
- `test-env/static/check_conventions.sh` asserts "a dry run writes nothing"
  against the filesystem for every `--dry-run`-capable CLI, running each under
  a scratch `HOME` and `TMPDIR`. The previous check read the script's own
  "no changes written" output, which stayed green while files were created.
- `mikrotik/tests/test_pull_router_backups.sh` — exit-code contract driven with
  ssh/scp stubs, so it needs no Docker, network or router and runs on the
  pull-request path.
- `ROUTEROS_SHA256` in `mikrotik/tests/routeros-version.env`, checked during
  the CHR image build. The image boots as a kernel with the repository mounted
  and was previously validated only as "non-empty". Until a digest is recorded
  the build warns and proceeds, so adding the pin does not turn a working
  nightly red; a *wrong* digest is fatal. Record it with
  `mikrotik/tests/routeros_version.py record-hash`.
- `mikrotik/tests/routeros_version.py` and a twice-weekly/manual GitHub Actions
  workflow that detect official RouterOS releases, test the candidate CHR image
  in Docker, and open a version/documentation bump pull request only after the
  integration suite passes. Bot branches explicitly dispatch standard CI so
  required checks still run despite GitHub token recursion protection.
- `mikrotik/tests/routeros-version.env` as the canonical CHR compatibility
  version shared by the Docker build, test runner, and automated bump flow.
- `CHANGELOG.md` — this file.
- `CODE_OF_CONDUCT.md` — Contributor Covenant 2.1, reported through the same
  private route as a security issue.
- `docs/good-first-issues.md` — small, verified tasks for a first contribution,
  each naming the file to change and how to check the result.
- A **Why this exists** section in `README.md`.
- A **Repository settings** checklist in `CONTRIBUTING.md` for the settings a
  repository cannot set for itself.

## 2026-08-02

Closing the gaps: repository hygiene, honest CI, and two more packages (#13).

### Added

- `linux/` package: `install_devtools.sh`, `stay_fresh.sh`, `packages.sh`,
  `bash_aliases.sh`, and a Docker suite that **runs** them inside pinned Debian,
  Fedora and Arch images rather than only parsing them.
- `windows/setup/winget_bootstrap.ps1` — `export`/`check`/`import`/`diff` over
  the installed package list, mirroring `brewfile.sh`.
- `windows/tests/contract.ps1` — parse, comment-based help, preview-before-change
  and documented-flags-exist checks over the PowerShell scripts.
- `test-env/static/` — repository-wide convention checks that discover their own
  subjects through `test-env/lib/discover_clis.sh`, so a new script is covered by
  the commit that adds it.
- `git/git_prune_gone.sh`, `git/git_size_report.sh` and
  `git/git_signing_doctor.py`.
- `macos-initial-setup/macos_defaults.sh` — read-only by default, with
  `--apply` and `--revert`.
- `templates/` — working no-op Bash and PowerShell starting points, tracked so
  CI keeps them in step with the conventions.
- `LICENSE` (MIT), `CONTRIBUTING.md`, `SECURITY.md`, issue and pull-request
  templates, `.github/dependabot.yml`, `.editorconfig` and
  `PSScriptAnalyzerSettings.psd1`.
- `.github/workflows/chr.yml` — the RouterOS CHR suite, nightly and on demand,
  off the pull-request path.

### Changed

- `ci.yml` gained a `changes` job that maps a diff onto per-suite flags, pinned
  tool versions with asserted installs, SHA-pinned actions, and step-level rather
  than job-level skipping so required checks always report.
- `run-tests.sh` learned the `linux` and `windows` suites and moved the Docker
  preflight behind suite selection.
- ShellCheck coverage extended to the Git Bash dotfiles, which have no `.sh`
  extension and had gone unchecked.

## 2026-07-31

CI and hardening (#12).

### Added

- `run-tests.sh` — one entry point for every suite, printing a pass/fail/skip
  matrix, called by CI so a local run and a CI run mean the same thing.
- `test-env/python/` — stdlib `unittest` suites for the Python helpers, with no
  Docker, venv or network.
- `git/git_ssh_doctor.py` — read-only diagnosis of
  `Permission denied (publickey)`.
- `macos-initial-setup/brewfile.sh`, `macos-initial-setup/launchd/stay_fresh_agent.sh`
  and `macos-initial-setup/lib/workspace_scan.py`.
- `mikrotik/export_config.py` — pulls `/export` over ssh and versions it, with
  the volatile header stripped so only real changes show up as diffs.
- `pyproject.toml` for the ruff configuration.

## 2026-07-29

- `macos-initial-setup/stay_fresh.sh` learned to prune application caches (#10).

## 2026-07-20

The Windows package and the first CI workflow (#9).

### Added

- `windows/git-bash/` — `.bashrc`, `.bash_profile` and `.aliases`, with one
  shared `ssh-agent` across Git Bash windows instead of one leaked per terminal.
- `windows/wsl/wsl_manage.ps1` — distro list with real VHDX usage, dated `.tar`
  backups, `compact`/`sparse`, shutdown.
- `windows/cleanup/clean_disk_c.ps1` — dry-run-first disk cleanup with
  destructive steps behind opt-in flags.
- `.github/workflows/ci.yml`, `.gitattributes`, `.markdownlint-cli2.yaml` and
  `.yamllint.yml`.

## 2026-05-11

Git helpers, macOS housekeeping and more RouterOS scripts (#6).

### Added

- `git/` package — `gacp.sh`, `set_git_profile.sh`, `git_whoami.sh`,
  `git_status_summary.sh`, `git_sync_default.sh`, `git_cleanup_merged.sh`,
  `git_recent_branches.sh`, `git_repo_root.sh`, `git_diff_branch.sh`,
  `git_undo_last_commit.sh`, `git_amend_last.sh` and `git_aliases.zsh`, with a
  Docker suite that exercises them against temporary repositories and local bare
  remotes.
- `macos-initial-setup/tests/` — Docker static checks for the macOS scripts.
- `mikrotik/dhcp_lease_watch.lua`, `firewall_drift.lua`,
  `firewall_drift_baseline.lua`, `mac_allowlist_dhcp.lua` and
  `rogue_dns_check.lua`.

### Changed

- `macos-initial-setup/stay_fresh.sh` reworked around the labelled `run_cmd`
  dry-run mechanism.

## 2026-04-25

### Added

- `mikrotik/` package — `tg_send.lua`, `backup.lua`, `change_WIFI_pw.lua`,
  `health_check.lua`, `update_check.lua`, `wan_failover_notify.lua`,
  `detect_internet.lua`, `reboot-and-flush.lua`, plus the CHR-under-QEMU test
  harness (#5).

### Changed

- The macOS scripts moved out of the repository root into
  `macos-initial-setup/`, leaving room for the other platforms (#4).

## 2026-04-22

### Added

- `v1_stay_fresh.sh` — the earlier flag-free maintenance flow, kept for
  reference (#2).

### Removed

- `old_stay_fresh.sh`, superseded by `v1_stay_fresh.sh` (#2).

### Changed

- `install_apps.sh` gained a larger curated set, and the README was rewritten
  around installation and configuration (#2, #3).

## 2026-04-21

### Added

- First scripts: `install_apps.sh`, `install_devtools.sh`, `stay_fresh.sh` and
  `zsh_aliases.zsh`, for setting up and maintaining a macOS workstation (#1).
